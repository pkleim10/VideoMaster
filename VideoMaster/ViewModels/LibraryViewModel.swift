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
    var tagCounts: [Int64: Int] = [:]
    var tagsByVideoId: [Int64: [Tag]] = [:] {
        didSet {
            recomputeFilteredVideos()
            updateTagCounts()
        }
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
    var isPlayingInline: Bool = false
    var inlinePlayPauseToggle: Int = 0
    var isEditingText: Bool = false

    private(set) var filteredVideos: [Video] = []
    private(set) var filteredVideosVersion: Int = 0
    var libraryCounts = LibraryCounts()
    private var cachedCollectionRules: [Int64: [CollectionRule]] = [:]
    private var collectionCountTask: Task<Void, Never>?

    let dbPool: DatabasePool
    let videoRepo: VideoRepository
    let tagRepo: TagRepository
    let collectionRepo: CollectionRepository
    let dataSourceRepo: DataSourceRepository
    let thumbnailService: ThumbnailService
    private let scanner: LibraryScanner
    private var observationTask: Task<Void, Never>?

    init(dbPool: DatabasePool, thumbnailService: ThumbnailService) {
        self.dbPool = dbPool
        self.videoRepo = VideoRepository(dbPool: dbPool)
        self.tagRepo = TagRepository(dbPool: dbPool)
        self.collectionRepo = CollectionRepository(dbPool: dbPool)
        self.dataSourceRepo = DataSourceRepository(dbPool: dbPool)
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
        case .rating(let stars):
            result = result.filter { $0.rating == stars }
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
        case .tag(let tag):
            guard let tagId = tag.id else {
                applyFilteredVideos([])
                return
            }
            result = result.filter { video in
                let videoTags = tagsByVideoId[video.databaseId ?? -1] ?? []
                return videoTags.contains { $0.id == tagId }
            }
        default:
            break
        }

        result.sort(using: tableSortOrder)
        applyFilteredVideos(result)
    }

    private func applyFilteredVideos(_ newValue: [Video]) {
        let orderChanged = newValue.map(\.id) != filteredVideos.map(\.id)
        filteredVideos = newValue
        if orderChanged {
            filteredVideosVersion &+= 1
        }
    }

    // MARK: - Library Counts

    private func updateLibraryCounts() {
        var recentlyAdded = 0
        var recentlyPlayed = 0
        var topRated = 0
        var byRating: [Int: Int] = [:]
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        for video in videos {
            if video.dateAdded >= cutoff { recentlyAdded += 1 }
            if video.lastPlayed != nil { recentlyPlayed += 1 }
            if video.rating >= 4 { topRated += 1 }
            if video.rating > 0 {
                byRating[video.rating, default: 0] += 1
            }
        }
        libraryCounts = LibraryCounts(
            all: videos.count,
            recentlyAdded: recentlyAdded,
            recentlyPlayed: recentlyPlayed,
            topRated: topRated,
            byRating: byRating
        )
    }

    private func updateTagCounts() {
        var counts: [Int64: Int] = [:]
        for tags in tagsByVideoId.values {
            for tag in tags {
                guard let tagId = tag.id else { continue }
                counts[tagId, default: 0] += 1
            }
        }
        tagCounts = counts
    }

    // MARK: - Actions

    func importNew() async {
        let dataSources = (try? await dataSourceRepo.fetchAll()) ?? []
        guard !dataSources.isEmpty else {
            scanProgress = "No data sources — add a folder first"
            Task {
                try? await Task.sleep(for: .seconds(3))
                if scanProgress.starts(with: "No data sources") { scanProgress = "" }
            }
            return
        }

        isScanning = true
        scanProgress = "Checking for new files..."
        stopObserving()

        let knownPaths = (try? await videoRepo.fetchAllFilePaths()) ?? []
        let folders = dataSources.map(\.url)

        for await update in await scanner.scanForNewFiles(folders: folders, knownPaths: knownPaths) {
            switch update {
            case .started(let total):
                scanTotal = total
                scanCurrent = 0
                if total == 0 {
                    scanProgress = "No new files found"
                } else {
                    scanProgress = "Found \(total) new video files"
                }
            case .progress(let current, let total, _):
                scanCurrent = current
                scanTotal = total
            case .completed:
                if scanTotal == 0 {
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        if scanProgress == "No new files found" { scanProgress = "" }
                    }
                } else {
                    scanProgress = ""
                }
                isScanning = false
                await refreshAfterScan()
            case .error(let message):
                scanProgress = "Error: \(message)"
                isScanning = false
                startObserving()
            }
        }
    }

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
        stopObserving()

        let path = url.path
        let alreadySaved = (try? await dataSourceRepo.exists(folderPath: path)) ?? false
        if !alreadySaved {
            let source = DataSource(
                folderPath: path,
                name: url.lastPathComponent,
                dateAdded: Date()
            )
            try? await dataSourceRepo.insert(source)
        }

        for await update in await scanner.scan(folder: url) {
            switch update {
            case .started(let total):
                scanTotal = total
                scanCurrent = 0
            case .progress(let current, let total, _):
                scanCurrent = current
                scanTotal = total
            case .completed:
                scanProgress = ""
                isScanning = false
                await refreshAfterScan()
            case .error(let message):
                scanProgress = "Error: \(message)"
                isScanning = false
                startObserving()
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

    func updateRating(forVideos videoIds: Set<String>, rating: Int) async {
        let dbIds = videoIds.compactMap { filePath in
            videos.first(where: { $0.filePath == filePath })?.databaseId
        }
        guard !dbIds.isEmpty else { return }

        if dbIds.count == 1 {
            try? await videoRepo.updateRating(videoId: dbIds[0], rating: rating)
        } else {
            stopObserving()
            try? await videoRepo.updateRating(videoIds: dbIds, rating: rating)
            videos = (try? await videoRepo.fetchAll()) ?? []
            startObserving()
        }
    }

    func renameVideo(_ video: Video, to newName: String) async -> String? {
        guard let dbId = video.databaseId else { return nil }

        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let oldURL = video.url
        let newURL = oldURL.deletingLastPathComponent().appendingPathComponent(trimmed)
        let newFilePath = newURL.path

        guard !FileManager.default.fileExists(atPath: newFilePath) else {
            print("Rename failed: file already exists at \(newFilePath)")
            return nil
        }

        do {
            try FileManager.default.moveItem(at: oldURL, to: newURL)
            try await videoRepo.renameVideo(videoId: dbId, newFilePath: newFilePath, newFileName: trimmed)
            await thumbnailService.migrateCacheKey(from: video.filePath, to: newFilePath)
            if selectedVideoIds.contains(video.filePath) {
                selectedVideoIds.remove(video.filePath)
                selectedVideoIds.insert(newFilePath)
            }
            return newFilePath
        } catch {
            print("Rename failed: \(error)")
            return nil
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
                await reloadTagState()
            }
        } catch {
            print("Failed to add tag: \(error)")
        }
    }

    func addTag(_ name: String, toVideos videoIds: Set<String>) async {
        do {
            let tag = try await tagRepo.findOrCreate(name: name)
            guard let tagId = tag.id else { return }
            for filePath in videoIds {
                if let video = videos.first(where: { $0.filePath == filePath }),
                   let dbId = video.databaseId
                {
                    try? await tagRepo.addTag(tagId, to: dbId)
                }
            }
            await reloadTagState()
        } catch {
            print("Failed to add tag: \(error)")
        }
    }

    func removeTag(_ tag: Tag, from video: Video) async {
        guard let videoId = video.databaseId, let tagId = tag.id else { return }
        do {
            try await tagRepo.removeTag(tagId, from: videoId)
            await reloadTagState()
        } catch {
            print("Failed to remove tag: \(error)")
        }
    }

    func removeTag(_ tag: Tag, fromVideos videoIds: Set<String>) async {
        guard let tagId = tag.id else { return }
        for filePath in videoIds {
            if let video = videos.first(where: { $0.filePath == filePath }),
               let dbId = video.databaseId
            {
                try? await tagRepo.removeTag(tagId, from: dbId)
            }
        }
        await reloadTagState()
    }

    private func reloadTagState() async {
        await loadTags()
        await refreshTagsByVideoId()
    }

    func tagsForVideos(_ videoIds: Set<String>) -> [Tag] {
        guard let firstId = videoIds.first,
              let firstVideo = videos.first(where: { $0.filePath == firstId }),
              let firstDbId = firstVideo.databaseId
        else { return [] }

        var commonTagIds = Set((tagsByVideoId[firstDbId] ?? []).compactMap(\.id))
        for filePath in videoIds.dropFirst() {
            if let video = videos.first(where: { $0.filePath == filePath }),
               let dbId = video.databaseId
            {
                let videoTagIds = Set((tagsByVideoId[dbId] ?? []).compactMap(\.id))
                commonTagIds.formIntersection(videoTagIds)
            }
        }
        return tags.filter { commonTagIds.contains($0.id ?? -1) }
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

    private func refreshAfterScan() async {
        videos = (try? await videoRepo.fetchAll()) ?? []
        await loadTags()
        await refreshTagsByVideoId()
        await refreshCollectionCounts()
        startObserving()
    }
}
