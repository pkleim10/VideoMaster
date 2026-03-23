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
            if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                refreshSearchIfActive()
            } else {
                recomputeFilteredVideos()
            }
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
        didSet { debouncedSearch() }
    }
    var tableSortOrder: [KeyPathComparator<Video>] = [KeyPathComparator(\Video.dateAdded, order: .reverse)] {
        didSet {
            let oldSort = VideoSort.from(keyPath: oldValue.first?.keyPath ?? \Video.dateAdded)
            let newSort = VideoSort.from(keyPath: tableSortOrder.first?.keyPath ?? \Video.dateAdded)
            if oldSort != newSort, tableSortOrder.first?.order != .forward {
                tableSortOrder = newSort.comparators(ascending: true)
                return
            }
            guard oldSort != newSort || oldValue.first?.order != tableSortOrder.first?.order else { return }
            if selectedVideoIds.count > 1 {
                pendingScrollAfterSortId = nil
                selectedVideoIds = []
            } else if selectedVideoIds.count == 1 {
                pendingScrollAfterSortId = selectedVideoIds.first
            } else {
                pendingScrollAfterSortId = nil
            }
            recomputeFilteredVideos()
            savePreferences()
        }
    }
    var viewMode: ViewMode = .grid {
        didSet {
            guard !_applyingLayout else { return }
            updateCurrentLayoutFromLive()
        }
    }
    var gridSize: GridSize = .medium {
        didSet {
            guard !_applyingLayout else { return }
            updateCurrentLayoutFromLive()
        }
    }
    var sidebarFilter: SidebarFilter? = .all {
        didSet {
            recomputeFilteredVideos()
            if case .missing = sidebarFilter, !isRefreshingMissing {
                Task { await refreshMissingCount() }
            }
        }
    }
    var selectedTagIds: Set<Int64> = [] {
        didSet { recomputeFilteredVideos() }
    }
    var tagFilterMode: MatchMode = .all {
        didSet { recomputeFilteredVideos() }
    }
    var isScanning: Bool = false
    var scanProgress: String = ""
    var scanCurrent: Int = 0
    var scanTotal: Int = 0
    var selectedVideoIds: Set<String> = [] {
        didSet {
            if let pending = pendingSurpriseScrollVideoId {
                if selectedVideoIds.count != 1 || selectedVideoIds.first != pending {
                    pendingSurpriseScrollVideoId = nil
                }
            }
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
    /// Set before `isPlayingInline = true` on filmstrip tap; consumed when creating the inline player (Space leaves nil → start at 0).
    var pendingFilmstripSeekSeconds: Double?
    var pendingAutoPlay: Bool = false
    var inlinePlayPauseToggle: Int = 0
    var isEditingText: Bool = false
    var renamingVideoId: String?
    var renameText: String = ""
    var renamingTagId: Int64?
    var tagRenameText: String = ""
    var scrollToVideoId: String?
    /// Surprise Me: scroll browsing pane only after detail has finished (see `finishSurpriseScrollIfNeeded`).
    private(set) var pendingSurpriseScrollVideoId: String?
    var scrollToSelectedOnViewSwitch: Bool = false
    /// Set by renameVideo when sorted by name; consumed by applyFilteredVideos to scroll in same cycle as bump.
    var pendingScrollToAfterRename: String?
    /// Set when sort changes with exactly one selected row; consumed in `applyFilteredVideos` to scroll after reorder.
    private var pendingScrollAfterSortId: String?
    var pendingDeleteIds: Set<String> = []
    var showDeleteConfirmation: Bool = false

    var isSortedByName: Bool {
        guard let first = tableSortOrder.first else { return false }
        return VideoSort.from(keyPath: first.keyPath) == .name
    }

    private(set) var filteredVideos: [Video] = []
    private(set) var filteredVideosVersion: Int = 0
    var libraryCounts = LibraryCounts()
    private var cachedCollectionRules: [Int64: [CollectionRule]] = [:]
    private var collectionCountTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var ftsMatchIds: Set<String>?
    private var duplicateVideoIds: Set<String> = []
    private var missingVideoIds: Set<String> = []
    private(set) var missingCountScanned: Bool = false
    private(set) var isRefreshingMissing: Bool = false
    private var filterGeneration: Int = 0

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
    private static let detailPreviewMaxLongEdgeKey = "VideoMaster.detailPreviewMaxLongEdge"
    private static let autoAdjustVideoPaneKey = "VideoMaster.autoAdjustVideoPane"
    /// Legacy Int padding stepper; migrated once to boolean toggle.
    private static let legacyAutoAdjustVideoPanePaddingKey = "VideoMaster.autoAdjustVideoPanePadding"
    private static let browsingLayoutKey = "VideoMaster.browsingLayout"
    private static let playbackLayoutKey = "VideoMaster.playbackLayout"
    private static let filmstripRowsKey = "VideoMaster.filmstripRows"
    private static let filmstripColumnsKey = "VideoMaster.filmstripColumns"
    private static let lastAppliedFilmstripRowsKey = "VideoMaster.lastAppliedFilmstripRows"
    private static let lastAppliedFilmstripColumnsKey = "VideoMaster.lastAppliedFilmstripColumns"
    private static let surpriseMeAutoPlaysKey = "VideoMaster.surpriseMeAutoPlays"
    private static let recentlyAddedDaysKey = "VideoMaster.recentlyAddedDays"
    private static let recentlyPlayedDaysKey = "VideoMaster.recentlyPlayedDays"
    private static let topRatedMinRatingKey = "VideoMaster.topRatedMinRating"
    private static let showRecentlyAddedKey = "VideoMaster.showRecentlyAdded"
    private static let showRecentlyPlayedKey = "VideoMaster.showRecentlyPlayed"
    private static let showTopRatedKey = "VideoMaster.showTopRated"
    private static let showDuplicatesKey = "VideoMaster.showDuplicates"
    private static let showCorruptKey = "VideoMaster.showCorrupt"
    private static let showMissingKey = "VideoMaster.showMissing"
    private static let missingCountScannedKey = "VideoMaster.missingCountScanned"
    private static let missingVideoIdsKey = "VideoMaster.missingVideoIds"

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

    var recentlyAddedDays: Int = 7 {
        didSet {
            UserDefaults.standard.set(recentlyAddedDays, forKey: Self.recentlyAddedDaysKey)
            updateLibraryCounts()
            recomputeFilteredVideos()
        }
    }

    var recentlyPlayedDays: Int = 30 {
        didSet {
            UserDefaults.standard.set(recentlyPlayedDays, forKey: Self.recentlyPlayedDaysKey)
            updateLibraryCounts()
            recomputeFilteredVideos()
        }
    }

    var topRatedMinRating: Int = 4 {
        didSet {
            UserDefaults.standard.set(topRatedMinRating, forKey: Self.topRatedMinRatingKey)
            updateLibraryCounts()
            recomputeFilteredVideos()
        }
    }

    var showRecentlyAdded: Bool = true {
        didSet {
            UserDefaults.standard.set(showRecentlyAdded, forKey: Self.showRecentlyAddedKey)
            resetFilterIfHidden()
        }
    }

    var showRecentlyPlayed: Bool = true {
        didSet {
            UserDefaults.standard.set(showRecentlyPlayed, forKey: Self.showRecentlyPlayedKey)
            resetFilterIfHidden()
        }
    }

    var showTopRated: Bool = true {
        didSet {
            UserDefaults.standard.set(showTopRated, forKey: Self.showTopRatedKey)
            resetFilterIfHidden()
        }
    }

    var showDuplicates: Bool = true {
        didSet {
            UserDefaults.standard.set(showDuplicates, forKey: Self.showDuplicatesKey)
            resetFilterIfHidden()
        }
    }

    var showCorrupt: Bool = true {
        didSet {
            UserDefaults.standard.set(showCorrupt, forKey: Self.showCorruptKey)
            resetFilterIfHidden()
        }
    }

    var showMissing: Bool = true {
        didSet {
            UserDefaults.standard.set(showMissing, forKey: Self.showMissingKey)
            resetFilterIfHidden()
        }
    }

    private func resetFilterIfHidden() {
        switch sidebarFilter {
        case .recentlyAdded where !showRecentlyAdded,
             .recentlyPlayed where !showRecentlyPlayed,
             .topRated where !showTopRated,
             .duplicates where !showDuplicates,
             .corrupt where !showCorrupt,
             .missing where !showMissing:
            sidebarFilter = .all
        default:
            break
        }
    }

    var surpriseMeAutoPlays: Bool = true {
        didSet {
            UserDefaults.standard.set(surpriseMeAutoPlays, forKey: Self.surpriseMeAutoPlaysKey)
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

    private(set) var lastAppliedFilmstripRows: Int = 2
    private(set) var lastAppliedFilmstripColumns: Int = 4

    var filmstripLayoutChanged: Bool {
        defaultFilmstripRows != lastAppliedFilmstripRows || defaultFilmstripColumns != lastAppliedFilmstripColumns
    }

    var showThumbnailInDetail: Bool = true {
        didSet {
            UserDefaults.standard.set(showThumbnailInDetail, forKey: Self.showThumbnailInDetailKey)
        }
    }

    /// Long edge (px) for disk-backed hi-res still in the detail pane (`ThumbnailService`); not the 400px grid thumb.
    var detailPreviewMaxLongEdge: Int = 1080 {
        didSet {
            UserDefaults.standard.set(detailPreviewMaxLongEdge, forKey: Self.detailPreviewMaxLongEdgeKey)
        }
    }

    /// When true, the horizontal splitter between preview and metadata is adjusted so the thumbnail or filmstrip fits (no extra spacing).
    var autoAdjustVideoPane: Bool = false {
        didSet {
            UserDefaults.standard.set(autoAdjustVideoPane, forKey: Self.autoAdjustVideoPaneKey)
        }
    }

    // MARK: - Layout (browsing vs playback)

    var browsingLayout: LayoutParams = .browsingDefaults() {
        didSet { saveLayout(.browsing) }
    }

    var playbackLayout: LayoutParams? = nil {
        didSet { saveLayout(.playback) }
    }

    private var _applyingLayout = false

    /// Layout to use for the current mode. Playback uses browsing until user customizes during playback.
    var effectiveLayout: LayoutParams {
        if isPlayingInline {
            return playbackLayout ?? browsingLayout
        }
        return browsingLayout
    }

    var effectiveDetailHeight: CGFloat { CGFloat(effectiveLayout.detailVideoHeight) }
    var effectiveDetailWidth: CGFloat { CGFloat(effectiveLayout.detailColumnWidth(for: viewMode)) }
    var effectiveContentWidth: CGFloat { CGFloat(effectiveLayout.contentColumnWidth(for: viewMode)) }
    var effectiveSidebarWidth: CGFloat { CGFloat(effectiveLayout.sidebarWidth) }

    var columnCustomization = TableColumnCustomization<Video>() {
        didSet {
            guard !_applyingLayout else { return }
            updateCurrentLayoutFromLive()
        }
    }

    private enum LayoutMode { case browsing, playback }
    private var layoutSaveTask: DispatchWorkItem?

    private func saveLayout(_ mode: LayoutMode) {
        layoutSaveTask?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let layout: LayoutParams
            switch mode {
            case .browsing: layout = self.browsingLayout
            case .playback: guard let p = self.playbackLayout else { return }; layout = p
            }
            Self.encodeLayoutToUserDefaults(layout, mode: mode)
        }
        layoutSaveTask = work
        // Next run loop coalesces rapid updates; no delay so quit-after-drag still persists.
        DispatchQueue.main.async(execute: work)
    }

    /// Writes layout JSON immediately (used when split views report sizes; does not rely on `didSet` / debounce).
    private static func encodeLayoutToUserDefaults(_ layout: LayoutParams, mode: LayoutMode) {
        let safe = layout.sanitized()
        guard let data = try? JSONEncoder().encode(safe) else { return }
        let key = mode == .browsing ? browsingLayoutKey : playbackLayoutKey
        UserDefaults.standard.set(data, forKey: key)
    }

    /// Apply a layout to the live UI properties. Call when switching modes.
    /// When preserveViewModeAndGridSize is true (e.g. switching to playback), keeps current viewMode and gridSize
    /// so the user stays in grid/list as they were, while applying sizes and sidebar from the layout.
    func applyLayout(_ layout: LayoutParams, preserveViewModeAndGridSize: Bool = false) {
        _applyingLayout = true
        defer { _applyingLayout = false }
        if !preserveViewModeAndGridSize {
            if let mode = ViewMode(rawValue: layout.viewMode) { viewMode = mode }
            if let size = GridSize(rawValue: layout.gridSize) { gridSize = size }
            if let data = layout.columnCustomizationData,
               let saved = try? JSONDecoder().decode(TableColumnCustomization<Video>.self, from: data)
            {
                columnCustomization = saved
            }
        }
    }

    /// Persist current live values (view mode, grid size, sidebar, columns) to the active mode's layout.
    func updateCurrentLayoutFromLive() {
        let base = effectiveLayout
        let colData = try? JSONEncoder().encode(columnCustomization)
        let layout = LayoutParams(
            sidebarWidth: base.sidebarWidth,
            contentWidthGrid: base.contentWidthGrid,
            detailWidthGrid: base.detailWidthGrid,
            contentWidthList: base.contentWidthList,
            detailWidthList: base.detailWidthList,
            browserTopPaneHeightGrid: base.browserTopPaneHeightGrid,
            browserTopPaneHeightList: base.browserTopPaneHeightList,
            detailVideoHeight: base.detailVideoHeight,
            columnCustomizationData: colData,
            viewMode: viewMode.rawValue,
            gridSize: gridSize.rawValue
        )
        let safe = layout.sanitized()
        if isPlayingInline {
            playbackLayout = safe
        } else {
            browsingLayout = safe
        }
    }

    /// Update layout with new size values from resize gestures. Call when user drags a divider.
    func updateCurrentLayoutWithSizes(
        sidebarWidth: CGFloat? = nil,
        contentWidth: CGFloat? = nil,
        detailWidth: CGFloat? = nil,
        browserTopPaneHeight: CGFloat? = nil,
        detailVideoHeight: CGFloat? = nil
    ) {
        let base = effectiveLayout
        var updated = LayoutParams.from(playback: base)
        if let w = sidebarWidth { updated.sidebarWidth = Double(w) }
        if let w = contentWidth {
            switch viewMode {
            case .grid: updated.contentWidthGrid = Double(w)
            case .list: updated.contentWidthList = Double(w)
            }
        }
        if let w = detailWidth {
            switch viewMode {
            case .grid: updated.detailWidthGrid = Double(w)
            case .list: updated.detailWidthList = Double(w)
            }
        }
        if let h = browserTopPaneHeight {
            switch viewMode {
            case .grid: updated.browserTopPaneHeightGrid = Double(h)
            case .list: updated.browserTopPaneHeightList = Double(h)
            }
        }
        if let h = detailVideoHeight { updated.detailVideoHeight = Double(h) }
        let fixed = updated.sanitized()
        if isPlayingInline {
            playbackLayout = fixed
            Self.encodeLayoutToUserDefaults(fixed, mode: .playback)
        } else {
            browsingLayout = fixed
            // Always persist split sizes immediately (Observable may coalesce equal structs; didSet save is async).
            Self.encodeLayoutToUserDefaults(fixed, mode: .browsing)
        }
    }

    func savePreferences() {
        let defaults = UserDefaults.standard
        if let first = tableSortOrder.first {
            let sort = VideoSort.from(keyPath: first.keyPath)
            defaults.set(sort.rawValue, forKey: Self.sortColumnKey)
            defaults.set(first.order == .forward, forKey: Self.sortAscendingKey)
        }
    }

    private func loadPreferences() {
        let defaults = UserDefaults.standard
        if let sortRaw = defaults.string(forKey: Self.sortColumnKey),
           let sort = VideoSort(rawValue: sortRaw)
        {
            let ascending = defaults.bool(forKey: Self.sortAscendingKey)
            tableSortOrder = sort.comparators(ascending: ascending)
        }
        excludeCorrupt = defaults.bool(forKey: Self.excludeCorruptKey)
        confirmDeletions = defaults.object(forKey: Self.confirmDeletionsKey) as? Bool ?? true
        surpriseMeAutoPlays = defaults.object(forKey: Self.surpriseMeAutoPlaysKey) as? Bool ?? true
        if let rows = defaults.object(forKey: Self.filmstripRowsKey) as? Int, rows > 0 {
            defaultFilmstripRows = rows
        }
        if let cols = defaults.object(forKey: Self.filmstripColumnsKey) as? Int, cols > 0 {
            defaultFilmstripColumns = cols
        }
        if let rows = defaults.object(forKey: Self.lastAppliedFilmstripRowsKey) as? Int, rows > 0 {
            lastAppliedFilmstripRows = rows
        } else {
            lastAppliedFilmstripRows = defaultFilmstripRows
        }
        if let cols = defaults.object(forKey: Self.lastAppliedFilmstripColumnsKey) as? Int, cols > 0 {
            lastAppliedFilmstripColumns = cols
        } else {
            lastAppliedFilmstripColumns = defaultFilmstripColumns
        }
        if let days = defaults.object(forKey: Self.recentlyAddedDaysKey) as? Int, days > 0 {
            recentlyAddedDays = days
        }
        if let days = defaults.object(forKey: Self.recentlyPlayedDaysKey) as? Int, days > 0 {
            recentlyPlayedDays = days
        }
        if let rating = defaults.object(forKey: Self.topRatedMinRatingKey) as? Int, rating >= 1 {
            topRatedMinRating = rating
        }
        if let v = defaults.object(forKey: Self.showRecentlyAddedKey) as? Bool { showRecentlyAdded = v }
        if let v = defaults.object(forKey: Self.showRecentlyPlayedKey) as? Bool { showRecentlyPlayed = v }
        if let v = defaults.object(forKey: Self.showTopRatedKey) as? Bool { showTopRated = v }
        if let v = defaults.object(forKey: Self.showDuplicatesKey) as? Bool { showDuplicates = v }
        if let v = defaults.object(forKey: Self.showCorruptKey) as? Bool { showCorrupt = v }
        if let v = defaults.object(forKey: Self.showMissingKey) as? Bool { showMissing = v }
        if let v = defaults.object(forKey: Self.missingCountScannedKey) as? Bool { missingCountScanned = v }
        if let ids = defaults.stringArray(forKey: Self.missingVideoIdsKey) { missingVideoIds = Set(ids) }
        if defaults.object(forKey: Self.showThumbnailInDetailKey) != nil {
            showThumbnailInDetail = defaults.bool(forKey: Self.showThumbnailInDetailKey)
        }
        if let edge = defaults.object(forKey: Self.detailPreviewMaxLongEdgeKey) as? Int,
           ThumbnailService.detailPreviewLongEdgeChoices.contains(edge)
        {
            detailPreviewMaxLongEdge = edge
        }
        if defaults.object(forKey: Self.autoAdjustVideoPaneKey) != nil {
            autoAdjustVideoPane = defaults.bool(forKey: Self.autoAdjustVideoPaneKey)
        } else if let pad = defaults.object(forKey: Self.legacyAutoAdjustVideoPanePaddingKey) as? Int {
            autoAdjustVideoPane = pad > 0
            defaults.removeObject(forKey: Self.legacyAutoAdjustVideoPanePaddingKey)
            defaults.set(autoAdjustVideoPane, forKey: Self.autoAdjustVideoPaneKey)
        }

        // Load layouts (with migration from legacy keys)
        if let data = defaults.data(forKey: Self.browsingLayoutKey),
           let layout = try? JSONDecoder().decode(LayoutParams.self, from: data)
        {
            browsingLayout = layout.sanitized()
        } else {
            // Migrate from legacy keys
            var migrated = LayoutParams.browsingDefaults()
            if let h = defaults.object(forKey: "VideoMaster.detailHeight") as? Double, h > 0 {
                migrated.detailVideoHeight = h
            }
            if let w = defaults.object(forKey: "VideoMaster.detailWidth") as? Double, w > 0 {
                migrated.detailWidthGrid = w
                migrated.detailWidthList = w
            }
            if let data = defaults.data(forKey: "VideoMaster.columnCustomization"),
               let _ = try? JSONDecoder().decode(TableColumnCustomization<Video>.self, from: data)
            {
                migrated.columnCustomizationData = data
            }
            if let modeRaw = defaults.string(forKey: Self.viewModeKey),
               let _ = ViewMode(rawValue: modeRaw) { migrated.viewMode = modeRaw }
            if let sizeRaw = defaults.string(forKey: Self.gridSizeKey),
               let _ = GridSize(rawValue: sizeRaw) { migrated.gridSize = sizeRaw }
            browsingLayout = migrated.sanitized()
        }
        if let data = defaults.data(forKey: Self.playbackLayoutKey),
           let layout = try? JSONDecoder().decode(LayoutParams.self, from: data)
        {
            playbackLayout = layout.sanitized()
        } else {
            // Migrate playback from legacy when-playing keys
            let h = defaults.object(forKey: "VideoMaster.detailHeightWhenPlaying") as? Double
            let w = defaults.object(forKey: "VideoMaster.detailWidthWhenPlaying") as? Double
            if h != nil || w != nil {
                var p = LayoutParams.from(playback: browsingLayout)
                if let h = h, h > 0 { p.detailVideoHeight = h }
                if let w = w, w > 0 {
                    p.detailWidthGrid = w
                    p.detailWidthList = w
                }
                playbackLayout = p.sanitized()
            }
        }
        applyLayout(browsingLayout)
    }

    func startObserving() {
        observationTask?.cancel()

        observationTask = Task { [dbPool] in
            let observation = ValueObservation.tracking { db in
                try Video.order(Column("dateAdded").desc).fetchAll(db)
            }
            do {
                for try await videos in observation.values(in: dbPool) {
                    await MainActor.run {
                        self.videos = videos
                    }
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

    // MARK: - FTS5 Search

    /// Refreshes ftsMatchIds when videos change (e.g. after rename) so search results stay correct.
    private func refreshSearchIfActive() {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        searchTask?.cancel()
        searchTask = Task {
            do {
                let results = try await videoRepo.search(trimmed)
                guard !Task.isCancelled else { return }
                ftsMatchIds = Set(results.map(\.id))
            } catch {
                guard !Task.isCancelled else { return }
                ftsMatchIds = nil
            }
            recomputeFilteredVideos()
        }
    }

    private func debouncedSearch() {
        searchTask?.cancel()
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            ftsMatchIds = nil
            recomputeFilteredVideos()
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            do {
                let results = try await videoRepo.search(trimmed)
                guard !Task.isCancelled else { return }
                ftsMatchIds = Set(results.map(\.id))
            } catch {
                guard !Task.isCancelled else { return }
                ftsMatchIds = nil
            }
            recomputeFilteredVideos()
        }
    }

    // MARK: - Cached Filter/Sort

    private static func isCorrupt(_ video: Video) -> Bool {
        video.duration == nil && video.width == nil && video.height == nil
    }

    private func recomputeFilteredVideos() {
        filterGeneration += 1
        let gen = filterGeneration
        let snapshot = FilterSnapshot(
            videos: videos,
            tagsByVideoId: tagsByVideoId,
            cachedCollectionRules: cachedCollectionRules,
            sidebarFilter: sidebarFilter,
            selectedTagIds: selectedTagIds,
            tagFilterMode: tagFilterMode,
            tableSortOrder: tableSortOrder,
            excludeCorrupt: excludeCorrupt,
            searchText: searchText,
            ftsMatchIds: ftsMatchIds,
            duplicateVideoIds: duplicateVideoIds,
            missingVideoIds: missingVideoIds,
            recentlyAddedDays: recentlyAddedDays,
            recentlyPlayedDays: recentlyPlayedDays,
            topRatedMinRating: topRatedMinRating
        )
        let repo = collectionRepo

        Task.detached(priority: .userInitiated) {
            let result = Self.computeFilteredResult(snapshot: snapshot, collectionRepo: repo)
            await MainActor.run {
                guard gen == self.filterGeneration else { return }
                self.applyFilteredVideos(result.videos)
                self.tagCounts = result.tagCounts
            }
        }
    }

    private struct FilterSnapshot {
        let videos: [Video]
        let tagsByVideoId: [Int64: [Tag]]
        let cachedCollectionRules: [Int64: [CollectionRule]]
        let sidebarFilter: SidebarFilter?
        let selectedTagIds: Set<Int64>
        let tagFilterMode: MatchMode
        let tableSortOrder: [KeyPathComparator<Video>]
        let excludeCorrupt: Bool
        let searchText: String
        let ftsMatchIds: Set<String>?
        let duplicateVideoIds: Set<String>
        let missingVideoIds: Set<String>
        let recentlyAddedDays: Int
        let recentlyPlayedDays: Int
        let topRatedMinRating: Int
    }

    private nonisolated static func computeFilteredResult(snapshot: FilterSnapshot, collectionRepo: CollectionRepository) -> (videos: [Video], tagCounts: [Int64: Int]) {
        func isCorrupt(_ video: Video) -> Bool {
            video.duration == nil && video.width == nil && video.height == nil
        }
        var baseResult = snapshot.videos
        let isSearching = !snapshot.searchText.isEmpty
        let isCorruptFilter = snapshot.sidebarFilter == .corrupt

        if snapshot.excludeCorrupt && !isCorruptFilter && !isSearching {
            baseResult = baseResult.filter { !isCorrupt($0) }
        }

        if isSearching, let matchIds = snapshot.ftsMatchIds {
            baseResult = baseResult.filter { matchIds.contains($0.id) }
        }

        switch snapshot.sidebarFilter {
        case .recentlyAdded:
            let cutoff = Calendar.current.date(byAdding: .day, value: -snapshot.recentlyAddedDays, to: Date()) ?? Date()
            baseResult = baseResult.filter { $0.dateAdded >= cutoff }
        case .recentlyPlayed:
            let cutoff = Calendar.current.date(byAdding: .day, value: -snapshot.recentlyPlayedDays, to: Date()) ?? Date()
            baseResult = baseResult.filter { ($0.lastPlayed ?? .distantPast) >= cutoff }
        case .topRated:
            baseResult = baseResult.filter { $0.rating >= snapshot.topRatedMinRating }
        case .duplicates:
            baseResult = baseResult.filter { snapshot.duplicateVideoIds.contains($0.id) }
        case .corrupt:
            baseResult = baseResult.filter { isCorrupt($0) }
        case .missing:
            baseResult = baseResult.filter { snapshot.missingVideoIds.contains($0.id) }
        case .rating(let stars):
            baseResult = baseResult.filter { $0.rating == stars }
        case .collection(let collection):
            guard let collectionId = collection.id else {
                return ([], [:])
            }
            let rules = snapshot.cachedCollectionRules[collectionId] ?? []
            if rules.isEmpty {
                return ([], [:])
            }
            baseResult = baseResult.filter { video in
                collectionRepo.matchesRules(
                    video: video,
                    rules: rules,
                    tags: snapshot.tagsByVideoId[video.databaseId ?? -1] ?? [],
                    mode: collection.matchMode
                )
            }
        default:
            break
        }

        let tagCounts = computeTagCounts(snapshot: snapshot, baseVideos: baseResult)

        var result = baseResult
        if !snapshot.selectedTagIds.isEmpty {
            result = result.filter { video in
                let videoTagIds = Set((snapshot.tagsByVideoId[video.databaseId ?? -1] ?? []).compactMap(\.id))
                switch snapshot.tagFilterMode {
                case .all: return snapshot.selectedTagIds.isSubset(of: videoTagIds)
                case .any: return !snapshot.selectedTagIds.isDisjoint(with: videoTagIds)
                }
            }
        }

        if snapshot.sidebarFilter == .recentlyPlayed {
            result = result.sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
        } else {
            result.sort(using: snapshot.tableSortOrder)
        }
        return (result, tagCounts)
    }

    private nonisolated static func computeTagCounts(snapshot: FilterSnapshot, baseVideos: [Video]) -> [Int64: Int] {
        let baseIds = Set(baseVideos.compactMap(\.databaseId))
        var counts: [Int64: Int] = [:]
        for (videoId, tags) in snapshot.tagsByVideoId {
            guard baseIds.contains(videoId) else { continue }
            for tag in tags {
                guard let tagId = tag.id else { continue }
                counts[tagId, default: 0] += 1
            }
        }
        return counts
    }

    private func applyFilteredVideos(_ newValue: [Video]) {
        // Bump `.id(filteredVideosVersion)` / `contentID` only when the **set** of rows changes — not on pure
        // **reorder** (e.g. column sort). Reorder used to compare full `databaseId` arrays → always "changed" →
        // full grid teardown + every `.task` thumbnail re-fired → multi‑second stalls on large libraries.
        let oldSet = Set(filteredVideos.map(\.id))
        let newSet = Set(newValue.map(\.id))
        let structureChanged = oldSet != newSet
        filteredVideos = newValue
        if structureChanged {
            filteredVideosVersion &+= 1
            if let id = pendingScrollToAfterRename, newValue.contains(where: { $0.id == id }) {
                pendingScrollToAfterRename = nil
                scrollToVideoId = id
                selectedVideoIds = [id]
                lastSelectedVideoId = id
            }
            let validIds = Set(newValue.map(\.id))
            let pruned = selectedVideoIds.intersection(validIds)
            if pruned != selectedVideoIds {
                selectedVideoIds = pruned
            }
        } else if pendingScrollToAfterRename != nil {
            pendingScrollToAfterRename = nil
        }

        if let sortScrollId = pendingScrollAfterSortId {
            pendingScrollAfterSortId = nil
            if newValue.contains(where: { $0.id == sortScrollId }) {
                scrollToVideoId = sortScrollId
            }
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
        let addedCutoff = Calendar.current.date(byAdding: .day, value: -recentlyAddedDays, to: Date()) ?? Date()
        let playedCutoff = Calendar.current.date(byAdding: .day, value: -recentlyPlayedDays, to: Date()) ?? Date()

        typealias DupKey = String
        var buckets: [DupKey: [String]] = [:]
        for video in videos {
            let isCorrupt = Self.isCorrupt(video)
            if isCorrupt { corrupt += 1 }
            let skip = excludeCorrupt && isCorrupt
            if !skip {
                allCount += 1
                if video.dateAdded >= addedCutoff { recentlyAdded += 1 }
                if (video.lastPlayed ?? .distantPast) >= playedCutoff { recentlyPlayed += 1 }
                if video.rating >= topRatedMinRating { topRated += 1 }
                if video.rating > 0 {
                    byRating[video.rating, default: 0] += 1
                }
                if let duration = video.duration {
                    let key = "\(video.fileSize)_\(Int(duration))"
                    buckets[key, default: []].append(video.id)
                }
            }
        }

        var dupIds = Set<String>()
        for ids in buckets.values where ids.count > 1 {
            dupIds.formUnion(ids)
        }
        duplicateVideoIds = dupIds

        libraryCounts = LibraryCounts(
            all: allCount,
            recentlyAdded: recentlyAdded,
            recentlyPlayed: recentlyPlayed,
            topRated: topRated,
            duplicates: dupIds.count,
            corrupt: corrupt,
            missing: missingCountScanned ? missingVideoIds.count : 0,
            byRating: byRating
        )
    }

    private func updateTagCounts() {
        let baseVideos = baseVideosForPrimaryFilter()
        var counts: [Int64: Int] = [:]
        let baseIds = Set(baseVideos.compactMap(\.databaseId))
        for (videoId, tags) in tagsByVideoId {
            guard baseIds.contains(videoId) else { continue }
            for tag in tags {
                guard let tagId = tag.id else { continue }
                counts[tagId, default: 0] += 1
            }
        }
        tagCounts = counts
    }

    /// Videos after applying primary filter (library/collection), before tag filter.
    private func baseVideosForPrimaryFilter() -> [Video] {
        var result = videos
        let isCorruptFilter = sidebarFilter == .corrupt
        if excludeCorrupt && !isCorruptFilter && searchText.isEmpty {
            result = result.filter { !Self.isCorrupt($0) }
        }
        if !searchText.isEmpty, let matchIds = ftsMatchIds {
            result = result.filter { matchIds.contains($0.id) }
        }
        switch sidebarFilter {
        case .recentlyAdded:
            let cutoff = Calendar.current.date(byAdding: .day, value: -recentlyAddedDays, to: Date()) ?? Date()
            result = result.filter { $0.dateAdded >= cutoff }
        case .recentlyPlayed:
            let cutoff = Calendar.current.date(byAdding: .day, value: -recentlyPlayedDays, to: Date()) ?? Date()
            result = result.filter { ($0.lastPlayed ?? .distantPast) >= cutoff }
        case .topRated:
            result = result.filter { $0.rating >= topRatedMinRating }
        case .duplicates:
            result = result.filter { duplicateVideoIds.contains($0.id) }
        case .corrupt:
            result = result.filter { Self.isCorrupt($0) }
        case .missing:
            result = result.filter { missingVideoIds.contains($0.id) }
        case .rating(let stars):
            result = result.filter { $0.rating == stars }
        case .collection(let collection):
            guard let collectionId = collection.id else { return [] }
            let rules = cachedCollectionRules[collectionId] ?? []
            if rules.isEmpty { return [] }
            result = result.filter { video in
                collectionRepo.matchesRules(
                    video: video,
                    rules: rules,
                    tags: tagsByVideoId[video.databaseId ?? -1] ?? [],
                    mode: collection.matchMode
                )
            }
        default:
            break
        }
        return result
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

    func importDroppedFiles(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }

        let videoUrls = urls.filter { $0.isVideoFile }
        guard !videoUrls.isEmpty else { return }

        let parentFolders = Set(videoUrls.map { $0.deletingLastPathComponent() })
        for folder in parentFolders {
            let path = folder.path
            let alreadySaved = (try? await dataSourceRepo.exists(folderPath: path)) ?? false
            if !alreadySaved {
                let source = DataSource(
                    folderPath: path,
                    name: folder.lastPathComponent,
                    dateAdded: Date()
                )
                try? await dataSourceRepo.insert(source)
            }
        }

        isScanning = true
        scanProgress = "Importing dropped files..."
        stopObserving()

        for await update in await scanner.scanFiles(videoUrls) {
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

    /// Picks a random video from the current filtered list and selects it. Scroll is deferred until
    /// `VideoDetailView` finishes loading/generating the filmstrip (`finishSurpriseScrollIfNeeded`).
    func surpriseMePickRandom() {
        guard let random = filteredVideos.randomElement() else { return }
        selectedVideoIds = [random.id]
        lastSelectedVideoId = random.id
        pendingAutoPlay = surpriseMeAutoPlays
        pendingSurpriseScrollVideoId = random.id
    }

    /// Schedules grid/list scroll after a short delay so playback and input are not blocked by LazyVGrid/layout work.
    func finishSurpriseScrollIfNeeded(for videoId: String) {
        guard pendingSurpriseScrollVideoId == videoId,
              lastSelectedVideoId == videoId
        else { return }
        pendingSurpriseScrollVideoId = nil
        let id = videoId
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard lastSelectedVideoId == id else { return }
            scrollToVideoId = id
        }
    }

    /// Grid keyboard navigation: move selection along `filteredVideos` (same order as list). List relies on `Table` arrow handling.
    func navigateFilteredVideoStep(_ step: Int) {
        guard step != 0 else { return }
        let videos = filteredVideos
        guard !videos.isEmpty else { return }
        let currentId = lastSelectedVideoId ?? selectedVideoIds.first
        let currentIndex: Int
        if let id = currentId, let idx = videos.firstIndex(where: { $0.id == id }) {
            currentIndex = idx
        } else if step > 0 {
            currentIndex = -1
        } else {
            currentIndex = videos.count
        }
        let next = currentIndex + step
        guard next >= 0, next < videos.count else { return }
        let newId = videos[next].id
        selectedVideoIds = [newId]
        scrollToVideoId = newId
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
            thumbnailService.migrateCacheKey(from: video.filePath, to: newFilePath)
            if selectedVideoIds.contains(video.filePath) {
                selectedVideoIds.remove(video.filePath)
                selectedVideoIds.insert(newFilePath)
            }
            if isSortedByName {
                pendingScrollToAfterRename = newFilePath
            }
            return newFilePath
        } catch {
            print("Rename failed: \(error)")
            return nil
        }
    }

    func refreshMissingCount() async {
        guard !isRefreshingMissing else { return }
        isRefreshingMissing = true
        defer { isRefreshingMissing = false }
        let snapshot = videos
        let missIds = await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            return Set(snapshot.filter { !fm.fileExists(atPath: $0.filePath) }.map(\.id))
        }.value
        missingVideoIds = missIds
        missingCountScanned = true
        UserDefaults.standard.set(true, forKey: Self.missingCountScannedKey)
        UserDefaults.standard.set(Array(missIds), forKey: Self.missingVideoIdsKey)
        libraryCounts = LibraryCounts(
            all: libraryCounts.all,
            recentlyAdded: libraryCounts.recentlyAdded,
            recentlyPlayed: libraryCounts.recentlyPlayed,
            topRated: libraryCounts.topRated,
            duplicates: libraryCounts.duplicates,
            corrupt: libraryCounts.corrupt,
            missing: missIds.count,
            byRating: libraryCounts.byRating
        )
        recomputeFilteredVideos()
    }

    func clearFilmstripCacheAndMarkApplied() async {
        thumbnailService.deleteAllFilmstrips()
        if let selectedId = lastSelectedVideoId ?? selectedVideoIds.first,
           let video = videos.first(where: { $0.filePath == selectedId })
        {
            _ = try? await thumbnailService.generateFilmstrip(
                for: video,
                rows: defaultFilmstripRows,
                columns: defaultFilmstripColumns
            )
        }
        lastAppliedFilmstripRows = defaultFilmstripRows
        lastAppliedFilmstripColumns = defaultFilmstripColumns
        UserDefaults.standard.set(lastAppliedFilmstripRows, forKey: Self.lastAppliedFilmstripRowsKey)
        UserDefaults.standard.set(lastAppliedFilmstripColumns, forKey: Self.lastAppliedFilmstripColumnsKey)
        filmstripRefreshId &+= 1
    }

    private func updateMissingAfterRemove(_ ids: Set<String>) {
        guard missingCountScanned, !ids.isEmpty else { return }
        missingVideoIds.subtract(ids)
        UserDefaults.standard.set(Array(missingVideoIds), forKey: Self.missingVideoIdsKey)
        libraryCounts = LibraryCounts(
            all: libraryCounts.all,
            recentlyAdded: libraryCounts.recentlyAdded,
            recentlyPlayed: libraryCounts.recentlyPlayed,
            topRated: libraryCounts.topRated,
            duplicates: libraryCounts.duplicates,
            corrupt: libraryCounts.corrupt,
            missing: missingVideoIds.count,
            byRating: libraryCounts.byRating
        )
        recomputeFilteredVideos()
    }

    func deleteVideos(_ ids: Set<String>) async {
        let orderedIds = filteredVideos.map(\.id)
        for filePath in ids {
            if let video = videos.first(where: { $0.filePath == filePath }) {
                try? await videoRepo.delete(video)
                var resultingURL: NSURL?
                try? FileManager.default.trashItem(at: video.url, resultingItemURL: &resultingURL)
            }
        }
        selectedVideoIds.subtract(ids)
        applySelectionAfterDeletionIfNeeded(orderedIdsBeforeDeletion: orderedIds, removedIds: ids)
        updateMissingAfterRemove(ids)
    }

    func removeVideosFromLibrary(_ ids: Set<String>) async {
        guard !ids.isEmpty else { return }
        let orderedIds = filteredVideos.map(\.id)
        stopObserving()
        for filePath in ids {
            if let video = videos.first(where: { $0.filePath == filePath }) {
                try? await videoRepo.delete(video)
            }
        }
        selectedVideoIds.subtract(ids)
        applySelectionAfterDeletionIfNeeded(orderedIdsBeforeDeletion: orderedIds, removedIds: ids)
        updateMissingAfterRemove(ids)
        await refreshAfterScan()
    }

    /// When deletion clears the selection, select the next row in the pre-deletion list order (or the previous if the last row was removed). List and grid both use `filteredVideos` order.
    private func applySelectionAfterDeletionIfNeeded(orderedIdsBeforeDeletion ordered: [String], removedIds: Set<String>) {
        guard selectedVideoIds.isEmpty, !removedIds.isEmpty else { return }
        guard let next = Self.successorIdAfterRemoving(fromOrderedIds: ordered, removedIds: removedIds) else { return }
        selectedVideoIds = [next]
        lastSelectedVideoId = next
        scrollToVideoId = next
    }

    private static func successorIdAfterRemoving(fromOrderedIds ordered: [String], removedIds: Set<String>) -> String? {
        guard !ordered.isEmpty, !removedIds.isEmpty else { return nil }
        guard let firstRemovedIdx = ordered.firstIndex(where: { removedIds.contains($0) }) else { return nil }
        if let after = ordered[(firstRemovedIdx + 1)...].first(where: { !removedIds.contains($0) }) {
            return after
        }
        if let before = ordered[..<firstRemovedIdx].last(where: { !removedIds.contains($0) }) {
            return before
        }
        return nil
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

    func clearTagFilters() {
        selectedTagIds = []
    }

    func deleteTag(_ tag: Tag) async {
        guard let tagId = tag.id else { return }
        selectedTagIds.remove(tagId)
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
