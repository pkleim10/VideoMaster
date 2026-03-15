import AppKit
import Foundation
import GRDB

@MainActor
@Observable
final class LibraryViewModel {
    var videos: [Video] = [] {
        didSet {
            updateLibraryCounts()
            recomputeFilteredVideos()
            scheduleCollectionCountRefresh()
        }
    }
    var tags: [Tag] = []
    var collections: [VideoCollection] = []
    var collectionCounts: [Int64: Int] = [:]
    var tagsByVideoId: [Int64: [Tag]] = [:] {
        didSet { recomputeFilteredVideos() }
    }
    var searchText: String = "" {
        didSet { recomputeFilteredVideos() }
    }
    var tableSortOrder: [KeyPathComparator<Video>] = [KeyPathComparator(\Video.dateAdded, order: .reverse)] {
        didSet { recomputeFilteredVideos() }
    }
    var viewMode: ViewMode = .grid
    var sidebarFilter: SidebarFilter? = .all {
        didSet { recomputeFilteredVideos() }
    }
    var isScanning: Bool = false
    var scanProgress: String = ""
    var scanCurrent: Int = 0
    var scanTotal: Int = 0
    var selectedVideoIds: Set<String> = []

    private(set) var filteredVideos: [Video] = []
    private(set) var filteredVideosVersion: Int = 0
    var libraryCounts = LibraryCounts()
    private var cachedCollectionRules: [Int64: [CollectionRule]] = [:]
    private var collectionCountTask: Task<Void, Never>?

    let dbPool: DatabasePool
    let videoRepo: VideoRepository
    let tagRepo: TagRepository
    let collectionRepo: CollectionRepository
    let thumbnailService: ThumbnailService
    private let scanner: LibraryScanner
    private var observationTask: Task<Void, Never>?

    init(dbPool: DatabasePool, thumbnailService: ThumbnailService) {
        self.dbPool = dbPool
        self.videoRepo = VideoRepository(dbPool: dbPool)
        self.tagRepo = TagRepository(dbPool: dbPool)
        self.collectionRepo = CollectionRepository(dbPool: dbPool)
        self.thumbnailService = thumbnailService
        self.scanner = LibraryScanner(dbPool: dbPool, thumbnailService: thumbnailService)
        loadPreferences()
    }

    // MARK: - Preferences Persistence

    private static let viewModeKey = "VideoMaster.viewMode"
    private static let sortColumnKey = "VideoMaster.sortColumn"
    private static let sortAscendingKey = "VideoMaster.sortAscending"

    func savePreferences() {
        let defaults = UserDefaults.standard
        defaults.set(viewMode.rawValue, forKey: Self.viewModeKey)
        if let first = tableSortOrder.first {
            let sort = VideoSort.from(keyPath: first.keyPath)
            defaults.set(sort.rawValue, forKey: Self.sortColumnKey)
            defaults.set(first.order == .forward, forKey: Self.sortAscendingKey)
        }
    }

    private func loadPreferences() {
        let defaults = UserDefaults.standard
        if let modeRaw = defaults.string(forKey: Self.viewModeKey),
           let mode = ViewMode(rawValue: modeRaw)
        {
            viewMode = mode
        }
        if let sortRaw = defaults.string(forKey: Self.sortColumnKey),
           let sort = VideoSort(rawValue: sortRaw)
        {
            let ascending = defaults.bool(forKey: Self.sortAscendingKey)
            tableSortOrder = sort.comparators(ascending: ascending)
        }
    }

    func startObserving() {
        observationTask?.cancel()

        observationTask = Task { [dbPool] in
            let observation = ValueObservation.tracking { db in
                try Video.order(Column("dateAdded").desc).fetchAll(db)
            }
            do {
                for try await videos in observation.values(in: dbPool) {
                    self.videos = videos
                }
            } catch {
                if !Task.isCancelled {
                    print("Video observation error: \(error)")
                }
            }
        }

        Task {
            await loadTags()
            await loadCollections()
        }
    }

    func stopObserving() {
        observationTask?.cancel()
        observationTask = nil
    }

    // MARK: - Cached Filter/Sort

    private func recomputeFilteredVideos() {
        var result = videos

        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter { $0.fileName.lowercased().contains(query) }
        }

        switch sidebarFilter {
        case .recentlyAdded:
            let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
            result = result.filter { $0.dateAdded >= cutoff }
        case .recentlyPlayed:
            result = result.filter { $0.lastPlayed != nil }
                .sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
            applyFilteredVideos(result)
            return
        case .topRated:
            result = result.filter { $0.rating >= 4 }
        case .collection(let collection):
            guard let collectionId = collection.id else {
                applyFilteredVideos([])
                return
            }
            let rules = cachedCollectionRules[collectionId] ?? []
            if rules.isEmpty {
                applyFilteredVideos([])
                return
            }
            result = result.filter { video in
                collectionRepo.matchesAllRules(
                    video: video,
                    rules: rules,
                    tags: tagsByVideoId[video.databaseId ?? -1] ?? []
                )
            }
        default:
            break
        }

        result.sort(using: tableSortOrder)
        applyFilteredVideos(result)
    }

    private func applyFilteredVideos(_ newValue: [Video]) {
        guard newValue != filteredVideos else { return }
        filteredVideos = newValue
        filteredVideosVersion &+= 1
    }

    // MARK: - Library Counts

    private func updateLibraryCounts() {
        var recentlyAdded = 0
        var recentlyPlayed = 0
        var topRated = 0
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        for video in videos {
            if video.dateAdded >= cutoff { recentlyAdded += 1 }
            if video.lastPlayed != nil { recentlyPlayed += 1 }
            if video.rating >= 4 { topRated += 1 }
        }
        libraryCounts = LibraryCounts(
            all: videos.count,
            recentlyAdded: recentlyAdded,
            recentlyPlayed: recentlyPlayed,
            topRated: topRated
        )
    }

    // MARK: - Actions

    func showFolderPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Select folders containing video files"
        panel.prompt = "Scan"

        if panel.runModal() == .OK {
            for url in panel.urls {
                Task { await scanFolder(url) }
            }
        }
    }

    func scanFolder(_ url: URL) async {
        isScanning = true
        scanProgress = "Scanning..."

        for await update in await scanner.scan(folder: url) {
            switch update {
            case .started(let total):
                scanTotal = total
                scanCurrent = 0
                scanProgress = "Found \(total) video files"
            case .progress(let current, let total, let fileName):
                scanCurrent = current
                scanTotal = total
                scanProgress = "Processing \(current)/\(total): \(fileName)"
            case .completed:
                scanProgress = ""
                isScanning = false
                await loadTags()
            case .error(let message):
                scanProgress = "Error: \(message)"
                isScanning = false
            }
        }
    }

    func updateRating(for video: Video, rating: Int) async {
        guard let id = video.databaseId else { return }
        do {
            try await videoRepo.updateRating(videoId: id, rating: rating)
        } catch {
            print("Failed to update rating: \(error)")
        }
    }

    func deleteVideos(_ ids: Set<String>) async {
        for filePath in ids {
            if let video = videos.first(where: { $0.filePath == filePath }) {
                try? await videoRepo.delete(video)
            }
        }
        selectedVideoIds.subtract(ids)
    }

    func recordPlay(for video: Video) async {
        guard let id = video.databaseId else { return }
        try? await videoRepo.recordPlay(videoId: id)
    }

    func addTag(_ name: String, to video: Video) async {
        guard let videoId = video.databaseId else { return }
        do {
            let tag = try await tagRepo.findOrCreate(name: name)
            if let tagId = tag.id {
                try await tagRepo.addTag(tagId, to: videoId)
                await loadTags()
            }
        } catch {
            print("Failed to add tag: \(error)")
        }
    }

    func removeTag(_ tag: Tag, from video: Video) async {
        guard let videoId = video.databaseId, let tagId = tag.id else { return }
        do {
            try await tagRepo.removeTag(tagId, from: videoId)
            await loadTags()
        } catch {
            print("Failed to remove tag: \(error)")
        }
    }

    func tagsForVideo(_ video: Video) async -> [Tag] {
        guard let videoId = video.databaseId else { return [] }
        return (try? await tagRepo.fetchTags(for: videoId)) ?? []
    }

    private func loadTags() async {
        tags = (try? await tagRepo.fetchAll()) ?? []
    }

    // MARK: - Collections

    func loadCollections() async {
        collections = (try? await collectionRepo.fetchAll()) ?? []
        cachedCollectionRules = (try? await collectionRepo.fetchAllRulesGrouped()) ?? [:]
        await refreshTagsByVideoId()
        await refreshCollectionCounts()
        recomputeFilteredVideos()
    }

    private func scheduleCollectionCountRefresh() {
        collectionCountTask?.cancel()
        collectionCountTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            await refreshCollectionCounts()
        }
    }

    func refreshCollectionCounts() async {
        let currentVideos = videos
        let currentTags = tagsByVideoId
        let allRules = cachedCollectionRules
        var counts: [Int64: Int] = [:]
        for collection in collections {
            guard let id = collection.id else { continue }
            let rules = allRules[id] ?? []
            if rules.isEmpty { continue }
            counts[id] = currentVideos.filter { video in
                collectionRepo.matchesAllRules(
                    video: video,
                    rules: rules,
                    tags: currentTags[video.databaseId ?? -1] ?? []
                )
            }.count
        }
        collectionCounts = counts
    }

    func deleteCollection(_ collection: VideoCollection) async {
        try? await collectionRepo.delete(collection)
        if case .collection(let selected) = sidebarFilter, selected == collection {
            sidebarFilter = .all
        }
        await loadCollections()
    }

    private func refreshTagsByVideoId() async {
        tagsByVideoId = (try? await tagRepo.fetchAllVideoTags()) ?? [:]
    }
}
