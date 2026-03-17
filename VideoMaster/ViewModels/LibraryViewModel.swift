import AppKit
import Foundation
import GRDB
import SwiftUI

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
    var gridSize: GridSize = .medium
    var sidebarFilter: SidebarFilter? = .all {
        didSet {
            if sidebarFilter != .tags {
                selectedTagIds = []
            }
            recomputeFilteredVideos()
        }
    }
    var selectedTagIds: Set<Int64> = [] {
        didSet { if sidebarFilter == .tags { recomputeFilteredVideos() } }
    }
    var tagFilterMode: MatchMode = .all {
        didSet { if sidebarFilter == .tags { recomputeFilteredVideos() } }
    }
    var isScanning: Bool = false
    var scanProgress: String = ""
    var scanCurrent: Int = 0
    var scanTotal: Int = 0
    var selectedVideoIds: Set<String> = [] {
        didSet {
            let added = selectedVideoIds.subtracting(oldValue)
            if let newId = added.first {
                lastSelectedVideoId = newId
            } else if !selectedVideoIds.isEmpty, !selectedVideoIds.contains(lastSelectedVideoId ?? "") {
                lastSelectedVideoId = selectedVideoIds.first
            } else if selectedVideoIds.isEmpty {
                lastSelectedVideoId = nil
            }
        }
    }
    var lastSelectedVideoId: String?
    var filmstripRefreshId: Int = 0
    var isPlayingInline: Bool = false
    var pendingAutoPlay: Bool = false
    var inlinePlayPauseToggle: Int = 0
    var isEditingText: Bool = false
    var renamingVideoId: String?
    var renameText: String = ""
    var scrollToVideoId: String?
    var scrollToSelectedOnViewSwitch: Bool = false

    var isSortedByName: Bool {
        guard let first = tableSortOrder.first else { return false }
        return VideoSort.from(keyPath: first.keyPath) == .name
    }

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
    private static let gridSizeKey = "VideoMaster.gridSize"
    private static let sortColumnKey = "VideoMaster.sortColumn"
    private static let sortAscendingKey = "VideoMaster.sortAscending"
    private static let excludeCorruptKey = "VideoMaster.excludeCorrupt"
    private static let confirmDeletionsKey = "VideoMaster.confirmDeletions"
    private static let showThumbnailInDetailKey = "VideoMaster.showThumbnailInDetail"
    private static let detailHeightKey = "VideoMaster.detailHeight"
    private static let sidebarExpandedKey = "VideoMaster.sidebarExpanded"
    private static let columnCustomizationKey = "VideoMaster.columnCustomization"
    private static let filmstripRowsKey = "VideoMaster.filmstripRows"
    private static let filmstripColumnsKey = "VideoMaster.filmstripColumns"

    var excludeCorrupt: Bool = false {
        didSet {
            UserDefaults.standard.set(excludeCorrupt, forKey: Self.excludeCorruptKey)
            updateLibraryCounts()
            recomputeFilteredVideos()
            scheduleCollectionCountRefresh()
        }
    }

    var confirmDeletions: Bool = true {
        didSet {
            UserDefaults.standard.set(confirmDeletions, forKey: Self.confirmDeletionsKey)
        }
    }

    var defaultFilmstripRows: Int = 2 {
        didSet {
            UserDefaults.standard.set(defaultFilmstripRows, forKey: Self.filmstripRowsKey)
        }
    }

    var defaultFilmstripColumns: Int = 4 {
        didSet {
            UserDefaults.standard.set(defaultFilmstripColumns, forKey: Self.filmstripColumnsKey)
        }
    }

    var showThumbnailInDetail: Bool = true {
        didSet {
            UserDefaults.standard.set(showThumbnailInDetail, forKey: Self.showThumbnailInDetailKey)
        }
    }

    var detailHeight: CGFloat = 336 {
        didSet {
            UserDefaults.standard.set(Double(detailHeight), forKey: Self.detailHeightKey)
        }
    }

    var columnCustomization = TableColumnCustomization<Video>() {
        didSet { saveColumnCustomization() }
    }

    private func saveColumnCustomization() {
        guard let data = try? JSONEncoder().encode(columnCustomization) else { return }
        UserDefaults.standard.set(data, forKey: Self.columnCustomizationKey)
    }

    var isLibraryExpanded: Bool = true { didSet { saveSidebarExpanded() } }
    var isCollectionsExpanded: Bool = true { didSet { saveSidebarExpanded() } }
    var isRatingExpanded: Bool = true { didSet { saveSidebarExpanded() } }
    var isTagsExpanded: Bool = true { didSet { saveSidebarExpanded() } }

    private func saveSidebarExpanded() {
        let state: [String: Bool] = [
            "library": isLibraryExpanded,
            "collections": isCollectionsExpanded,
            "rating": isRatingExpanded,
            "tags": isTagsExpanded,
        ]
        UserDefaults.standard.set(state, forKey: Self.sidebarExpandedKey)
    }

    func savePreferences() {
        let defaults = UserDefaults.standard
        defaults.set(viewMode.rawValue, forKey: Self.viewModeKey)
        defaults.set(gridSize.rawValue, forKey: Self.gridSizeKey)
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
        if let sizeRaw = defaults.string(forKey: Self.gridSizeKey),
           let size = GridSize(rawValue: sizeRaw)
        {
            gridSize = size
        }
        if let sortRaw = defaults.string(forKey: Self.sortColumnKey),
           let sort = VideoSort(rawValue: sortRaw)
        {
            let ascending = defaults.bool(forKey: Self.sortAscendingKey)
            tableSortOrder = sort.comparators(ascending: ascending)
        }
        excludeCorrupt = defaults.bool(forKey: Self.excludeCorruptKey)
        confirmDeletions = defaults.object(forKey: Self.confirmDeletionsKey) as? Bool ?? true
        if let rows = defaults.object(forKey: Self.filmstripRowsKey) as? Int, rows > 0 {
            defaultFilmstripRows = rows
        }
        if let cols = defaults.object(forKey: Self.filmstripColumnsKey) as? Int, cols > 0 {
            defaultFilmstripColumns = cols
        }
        if defaults.object(forKey: Self.showThumbnailInDetailKey) != nil {
            showThumbnailInDetail = defaults.bool(forKey: Self.showThumbnailInDetailKey)
        }

        if let h = defaults.object(forKey: Self.detailHeightKey) as? Double, h > 0 {
            detailHeight = CGFloat(h)
        }
        if let state = defaults.dictionary(forKey: Self.sidebarExpandedKey) as? [String: Bool] {
            isLibraryExpanded = state["library"] ?? true
            isCollectionsExpanded = state["collections"] ?? true
            isRatingExpanded = state["rating"] ?? true
            isTagsExpanded = state["tags"] ?? true
        }
        if let data = defaults.data(forKey: Self.columnCustomizationKey),
           let saved = try? JSONDecoder().decode(TableColumnCustomization<Video>.self, from: data)
        {
            columnCustomization = saved
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

    private static func isCorrupt(_ video: Video) -> Bool {
        video.duration == nil && video.width == nil && video.height == nil
    }

    private func recomputeFilteredVideos() {
        var result = videos

        let isSearching = !searchText.isEmpty
        let isCorruptFilter = sidebarFilter == .corrupt

        if excludeCorrupt && !isCorruptFilter && !isSearching {
            result = result.filter { !Self.isCorrupt($0) }
        }

        if isSearching {
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
        case .corrupt:
            result = result.filter { Self.isCorrupt($0) }
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
                collectionRepo.matchesRules(
                    video: video,
                    rules: rules,
                    tags: tagsByVideoId[video.databaseId ?? -1] ?? [],
                    mode: collection.matchMode
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
        case .tags:
            if selectedTagIds.isEmpty {
                applyFilteredVideos([])
                return
            }
            result = result.filter { video in
                let videoTagIds = Set((tagsByVideoId[video.databaseId ?? -1] ?? []).compactMap(\.id))
                switch tagFilterMode {
                case .all:
                    return selectedTagIds.isSubset(of: videoTagIds)
                case .any:
                    return !selectedTagIds.isDisjoint(with: videoTagIds)
                }
            }
        default:
            break
        }

        result.sort(using: tableSortOrder)
        applyFilteredVideos(result)
    }

    private func applyFilteredVideos(_ newValue: [Video]) {
        let oldCount = filteredVideos.count
        let newCount = newValue.count
        let oldIds = Set(filteredVideos.map(\.id))
        let newIds = Set(newValue.map(\.id))
        filteredVideos = newValue
        let hasNewItems = !newIds.subtracting(oldIds).isEmpty && newCount > oldCount
        if hasNewItems {
            filteredVideosVersion &+= 1
        }
    }

    // MARK: - Library Counts

    private func updateLibraryCounts() {
        var allCount = 0
        var recentlyAdded = 0
        var recentlyPlayed = 0
        var topRated = 0
        var corrupt = 0
        var byRating: [Int: Int] = [:]
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        for video in videos {
            let isCorrupt = Self.isCorrupt(video)
            if isCorrupt { corrupt += 1 }
            let skip = excludeCorrupt && isCorrupt
            if !skip {
                allCount += 1
                if video.dateAdded >= cutoff { recentlyAdded += 1 }
                if video.lastPlayed != nil { recentlyPlayed += 1 }
                if video.rating >= 4 { topRated += 1 }
                if video.rating > 0 {
                    byRating[video.rating, default: 0] += 1
                }
            }
        }
        libraryCounts = LibraryCounts(
            all: allCount,
            recentlyAdded: recentlyAdded,
            recentlyPlayed: recentlyPlayed,
            topRated: topRated,
            corrupt: corrupt,
            byRating: byRating
        )
    }

    private func updateTagCounts() {
        var counts: [Int64: Int] = [:]
        let excludedVideoIds: Set<Int64> = excludeCorrupt
            ? Set(videos.filter { Self.isCorrupt($0) }.compactMap(\.databaseId))
            : []
        for (videoId, tags) in tagsByVideoId {
            if excludedVideoIds.contains(videoId) { continue }
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

    func applyRating(to videoIds: Set<String>, rating: Int) {
        var updated = videos
        for filePath in videoIds {
            if let idx = updated.firstIndex(where: { $0.filePath == filePath }) {
                updated[idx].rating = rating
            }
        }
        videos = updated
    }

    func persistRating(for videoIds: Set<String>, rating: Int) async {
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
                try? FileManager.default.removeItem(at: video.url)
            }
        }
        selectedVideoIds.subtract(ids)
    }

    func removeVideosFromLibrary(_ ids: Set<String>) async {
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

    func createTag(_ name: String) async {
        do {
            _ = try await tagRepo.findOrCreate(name: name)
            await reloadTagState()
        } catch {
            print("Failed to create tag: \(error)")
        }
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

    func renameTag(_ tag: Tag, to newName: String) async {
        guard let tagId = tag.id, !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            try await tagRepo.rename(tagId, to: newName)
            await loadTags()
        } catch {
            print("Failed to rename tag: \(error)")
        }
    }

    func deleteTag(_ tag: Tag) async {
        guard let tagId = tag.id else { return }
        selectedTagIds.remove(tagId)
        if selectedTagIds.isEmpty && sidebarFilter == .tags {
            sidebarFilter = .all
        }
        do {
            try await tagRepo.delete(tagId)
            await reloadTagState()
        } catch {
            print("Failed to delete tag: \(error)")
        }
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
        let baseVideos = excludeCorrupt ? videos.filter { !Self.isCorrupt($0) } : videos
        let currentTags = tagsByVideoId
        let allRules = cachedCollectionRules
        var counts: [Int64: Int] = [:]
        for collection in collections {
            guard let id = collection.id else { continue }
            let rules = allRules[id] ?? []
            if rules.isEmpty { continue }
            counts[id] = baseVideos.filter { video in
                collectionRepo.matchesRules(
                    video: video,
                    rules: rules,
                    tags: currentTags[video.databaseId ?? -1] ?? [],
                    mode: collection.matchMode
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
