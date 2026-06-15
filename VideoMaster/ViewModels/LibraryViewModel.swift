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
            scheduleListCustomMetadataRefresh()
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
    /// Per-star rating filter (1...5); independent of `sidebarFilter`, like `selectedTagIds`.
    var selectedRatingStars: Set<Int> = [] {
        didSet { recomputeFilteredVideos() }
    }
    var ffmpegUserPath: String = "" {
        didSet { UserDefaults.standard.set(ffmpegUserPath, forKey: Self.ffmpegPathKey) }
    }

    /// The ffmpeg binary to use: user-configured path first, then standard Homebrew/system locations.
    var resolvedFFmpegPath: String? {
        if !ffmpegUserPath.isEmpty {
            return FileManager.default.isExecutableFile(atPath: ffmpegUserPath) ? ffmpegUserPath : nil
        }
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private var thumbnailsSettled: Bool = true

    var isScanning: Bool = false {
        didSet {
            if isScanning && !oldValue {
                thumbnailsSettled = false
            } else if !isScanning && oldValue {
                startThumbnailSettlingTask()
            }
        }
    }
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
    var isPlayingInline: Bool = false {
        didSet {
            // Leaving playback: restore list `Table` column widths from saved JSON *before* flushing live state.
            // If we `updateCurrentLayoutFromLive()` first, SwiftUI may have already reset `columnCustomization`
            // to defaults — that snapshot would overwrite `browsingLayout` and defeat re-apply.
            if oldValue, !isPlayingInline {
                reapplyListColumnCustomizationAfterPlaybackExit()
                if viewMode != .list {
                    updateCurrentLayoutFromLive()
                }
            }
        }
    }
    /// Set before `isPlayingInline = true` on filmstrip tap; consumed when creating the inline player (Space leaves nil → start at 0).
    var pendingFilmstripSeekSeconds: Double?
    var pendingAutoPlay: Bool = false
    var inlinePlayPauseToggle: Int = 0
    var inlineRestartFromBeginning: Int = 0
    var isEditingText: Bool = false
    var renamingVideoId: String?
    var renameText: String = ""
    var renamingTagId: Int64?
    var tagRenameText: String = ""
    var scrollToVideoId: String?
    /// Surprise Me: scroll browsing pane only after detail has finished (see `finishSurpriseScrollIfNeeded`).
    private(set) var pendingSurpriseScrollVideoId: String?
    var scrollToSelectedOnViewSwitch: Bool = false

    /// Imperative top/bottom/page scroll requests from the list/grid nav bar. The token de-dupes so the
    /// handler fires once per press and ignores its own replays on view re-mount / SwiftUI re-render.
    struct ScrollCommand: Equatable {
        enum Kind: Equatable {
            case top, bottom, pageUp, pageDown
            /// Jump so row `index` of `total` rows is centered — used to restore the selection on a
            /// List→Grid switch without SwiftUI instantiating every intermediate cell (the ~6s freeze).
            case toRow(index: Int, total: Int)
        }
        let token: Int
        let kind: Kind
    }
    private(set) var scrollCommand: ScrollCommand?
    private var scrollCommandToken: Int = 0

    func issueScrollCommand(_ kind: ScrollCommand.Kind) {
        scrollCommandToken += 1
        scrollCommand = ScrollCommand(token: scrollCommandToken, kind: kind)
    }

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
        Task { await refreshListCustomMetadataCacheIfNeeded() }
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
    private static let playInlineStartsFullscreenKey = "VideoMaster.playInlineStartsFullscreen"
    private static let fadeResumeBannerAutomaticallyKey = "VideoMaster.fadeResumeBannerAutomatically"
    private static let resumeBannerFadeDelaySecondsKey = "VideoMaster.resumeBannerFadeDelaySeconds"
    private static let recentlyAddedDaysKey = "VideoMaster.recentlyAddedDays"
    private static let recentlyPlayedDaysKey = "VideoMaster.recentlyPlayedDays"
    private static let topRatedMinRatingKey = "VideoMaster.topRatedMinRating"
    private static let showRecentlyAddedKey = "VideoMaster.showRecentlyAdded"
    private static let showRecentlyPlayedKey = "VideoMaster.showRecentlyPlayed"
    private static let showTopRatedKey = "VideoMaster.showTopRated"
    private static let showDuplicatesKey = "VideoMaster.showDuplicates"
    private static let showCorruptKey = "VideoMaster.showCorrupt"
    private static let showMissingKey = "VideoMaster.showMissing"
    private static let showRecentlyConvertedKey = "VideoMaster.showRecentlyConverted"
    private static let recentlyConvertedEntriesKey = "VideoMaster.recentlyConvertedEntries"
    private static let showFilterStripKey = "VideoMaster.showFilterStrip"
    private static let ffmpegPathKey = "VideoMaster.ffmpegPath"
    private static let customMetadataFieldDefinitionsKey = "VideoMaster.customMetadataFieldDefinitions"
    private static let missingCountScannedKey = "VideoMaster.missingCountScanned"
    private static let missingVideoIdsKey = "VideoMaster.missingVideoIds"
    private static let listColumnPreferencesKey = "VideoMaster.listColumnPreferences"

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

    var showRecentlyConverted: Bool = true {
        didSet {
            UserDefaults.standard.set(showRecentlyConverted, forKey: Self.showRecentlyConvertedKey)
            resetFilterIfHidden()
        }
    }

    // Tracks videos re-encoded in the last 30 days; persisted to UserDefaults as JSON.
    private struct ConvertedEntry: Codable {
        var path: String
        var date: Date
    }
    private var recentlyConvertedEntries: [ConvertedEntry] = []

    var isConverting: Bool = false
    var conversionProgress: String = ""
    private var conversionQueue: [(video: Video, ffmpegPath: String)] = []
    var isMoving: Bool = false
    var moveProgress: String = ""

    private func resetFilterIfHidden() {
        switch sidebarFilter {
        case .recentlyAdded where !showRecentlyAdded,
             .recentlyPlayed where !showRecentlyPlayed,
             .topRated where !showTopRated,
             .duplicates where !showDuplicates,
             .corrupt where !showCorrupt,
             .missing where !showMissing,
             .recentlyConverted where !showRecentlyConverted:
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

    /// When true, inline playback (detail pane / filmstrip) opens in a separate window and enters full screen immediately. Does not affect "Play Video" opening the default external app.
    var playInlineStartsFullscreen: Bool = false {
        didSet {
            UserDefaults.standard.set(playInlineStartsFullscreen, forKey: Self.playInlineStartsFullscreenKey)
        }
    }

    /// When true, the “Resumed at … / Start at beginning” banner in inline playback fades out after `resumeBannerFadeDelaySeconds`.
    var fadeResumeBannerAutomatically: Bool = false {
        didSet {
            UserDefaults.standard.set(fadeResumeBannerAutomatically, forKey: Self.fadeResumeBannerAutomaticallyKey)
        }
    }

    /// Delay before the resume banner begins its fade (seconds). Clamped 1…120 when set.
    var resumeBannerFadeDelaySeconds: Int = 5 {
        didSet {
            let clamped = min(max(resumeBannerFadeDelaySeconds, 1), 120)
            if clamped != resumeBannerFadeDelaySeconds {
                resumeBannerFadeDelaySeconds = clamped
            } else {
                UserDefaults.standard.set(clamped, forKey: Self.resumeBannerFadeDelaySecondsKey)
            }
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

    /// When false, the bottom filter strip collapses to zero height (splitter remains); saved splitter height is unchanged. Expand/collapse from the View menu (⌘⌥B), context menu, or the list/grid or filter strip.
    var showFilterStrip: Bool = true {
        didSet {
            UserDefaults.standard.set(showFilterStrip, forKey: Self.showFilterStripKey)
        }
    }

    /// Schema for per-video custom metadata (Settings UI only until values are wired in the library UI).
    var customMetadataFieldDefinitions: [CustomMetadataFieldDefinition] = [] {
        didSet {
            saveCustomMetadataFieldDefinitions()
        }
    }

    /// Which standard/custom columns appear in list view (Name is always shown).
    var listColumnPreferences: ListColumnPreferences = .default {
        didSet {
            guard !_loadingListColumnPreferences else { return }
            saveListColumnPreferences()
            scheduleListCustomMetadataRefresh()
        }
    }

    /// Cached custom metadata for list cells, keyed by `Video.databaseId` then field UUID.
    private(set) var listCustomMetadataByVideoId: [Int64: [UUID: String]] = [:]

    private var _loadingListColumnPreferences = false
    private var listCustomMetadataRefreshTask: Task<Void, Never>?

    func isStandardListColumnVisible(_ id: String) -> Bool {
        listColumnPreferences.visibleStandardColumnIDs.contains(id)
    }

    func setStandardListColumnVisible(_ id: String, visible: Bool) {
        guard ListColumnPreferences.optionalStandardColumnIDs.contains(id) else { return }
        var p = listColumnPreferences
        if visible {
            p.visibleStandardColumnIDs.insert(id)
        } else {
            p.visibleStandardColumnIDs.remove(id)
        }
        listColumnPreferences = p
    }

    func setCustomListFieldVisible(fieldId: UUID, visible: Bool) {
        var p = listColumnPreferences
        if visible {
            p.visibleCustomFieldIDs.insert(fieldId)
        } else {
            p.visibleCustomFieldIDs.remove(fieldId)
        }
        listColumnPreferences = p
    }

    func isCustomListFieldVisible(_ fieldId: UUID) -> Bool {
        listColumnPreferences.visibleCustomFieldIDs.contains(fieldId)
    }

    /// Custom columns shown in list view (alphabetical; at most 16 — SwiftUI `Table` column builder limit).
    var visibleCustomFieldsForList: [CustomMetadataFieldDefinition] {
        let visible = listColumnPreferences.visibleCustomFieldIDs
        return Array(
            customMetadataFieldDefinitions
                .filter { visible.contains($0.id) && $0.valueType != .text }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .prefix(16)
        )
    }

    func listCustomFieldDisplay(for video: Video, field: CustomMetadataFieldDefinition) -> String {
        guard let vid = video.databaseId,
              let raw = listCustomMetadataByVideoId[vid]?[field.id]
        else {
            return "—"
        }
        return ListCustomMetadataCellFormatter.display(raw: raw, valueType: field.valueType)
    }

    /// Bumps `Table` identity when visible column set changes.
    var listColumnConfigurationSignature: String {
        let s = listColumnPreferences.visibleStandardColumnIDs.sorted().joined(separator: ",")
        let c = listColumnPreferences.visibleCustomFieldIDs.map(\.uuidString).sorted().joined(separator: ",")
        return "\(s)|\(c)"
    }

    private func saveListColumnPreferences() {
        guard let data = try? JSONEncoder().encode(listColumnPreferences) else { return }
        UserDefaults.standard.set(data, forKey: Self.listColumnPreferencesKey)
    }

    private func scheduleListCustomMetadataRefresh() {
        listCustomMetadataRefreshTask?.cancel()
        listCustomMetadataRefreshTask = Task { @MainActor in
            await refreshListCustomMetadataCacheIfNeeded()
        }
    }

    private func refreshListCustomMetadataCacheIfNeeded() async {
        guard !listColumnPreferences.visibleCustomFieldIDs.isEmpty else {
            listCustomMetadataByVideoId = [:]
            return
        }
        let ids = videos.compactMap(\.databaseId)
        guard !ids.isEmpty else {
            listCustomMetadataByVideoId = [:]
            return
        }
        do {
            let raw = try await videoRepo.fetchCustomMetadata(forVideoIds: ids)
            var result: [Int64: [UUID: String]] = [:]
            for (vid, fields) in raw {
                var m: [UUID: String] = [:]
                for (k, v) in fields {
                    if let u = UUID(uuidString: k) { m[u] = v }
                }
                result[vid] = m
            }
            listCustomMetadataByVideoId = result
        } catch {
            listCustomMetadataByVideoId = [:]
        }
    }

    private func mergeListCustomMetadataCache(videoId: Int64, fieldId: UUID, value: String) {
        guard listColumnPreferences.visibleCustomFieldIDs.contains(fieldId) else { return }
        var inner = listCustomMetadataByVideoId[videoId] ?? [:]
        inner[fieldId] = value
        listCustomMetadataByVideoId[videoId] = inner
    }

    func addCustomMetadataField() {
        let n = customMetadataFieldDefinitions.count + 1
        customMetadataFieldDefinitions.append(
            CustomMetadataFieldDefinition(name: "Field \(n)", valueType: .string)
        )
    }

    func removeCustomMetadataFields(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        customMetadataFieldDefinitions.removeAll { ids.contains($0.id) }
        var p = listColumnPreferences
        p.visibleCustomFieldIDs.subtract(ids)
        listColumnPreferences = p
    }

    func updateCustomMetadataFieldName(id: UUID, name: String) {
        guard let i = customMetadataFieldDefinitions.firstIndex(where: { $0.id == id }) else { return }
        customMetadataFieldDefinitions[i].name = name
    }

    func updateCustomMetadataFieldType(id: UUID, valueType: CustomMetadataValueType) {
        guard let i = customMetadataFieldDefinitions.firstIndex(where: { $0.id == id }) else { return }
        customMetadataFieldDefinitions[i].valueType = valueType
    }

    private func saveCustomMetadataFieldDefinitions() {
        guard let data = try? JSONEncoder().encode(customMetadataFieldDefinitions) else { return }
        UserDefaults.standard.set(data, forKey: Self.customMetadataFieldDefinitionsKey)
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

    /// Re-applies list `Table` column widths after inline playback (SwiftUI can reset widths when the browser column unfreezes).
    func reapplyListColumnCustomizationAfterPlaybackExit() {
        guard viewMode == .list else { return }
        let blob: Data
        if let p = playbackLayout, let d = p.columnCustomizationData, !d.isEmpty {
            blob = d
        } else if let d = browsingLayout.columnCustomizationData, !d.isEmpty {
            blob = d
        } else {
            return
        }
        guard let saved = try? JSONDecoder().decode(TableColumnCustomization<Video>.self, from: blob) else { return }
        _applyingLayout = true
        columnCustomization = saved
        _applyingLayout = false
        updateCurrentLayoutFromLive()
    }

    /// Persist current live values (view mode, grid size, sidebar, columns) to the active mode's layout.
    func updateCurrentLayoutFromLive() {
        let base = effectiveLayout
        let colData = (try? JSONEncoder().encode(columnCustomization)) ?? base.columnCustomizationData
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
        // Always carry live table column widths; `base` may have stale columnCustomizationData
        // (e.g. browsing snapshot from before playback while list was customized during playback).
        updated.columnCustomizationData = (try? JSONEncoder().encode(columnCustomization)) ?? base.columnCustomizationData
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
        if defaults.object(forKey: Self.playInlineStartsFullscreenKey) != nil {
            playInlineStartsFullscreen = defaults.bool(forKey: Self.playInlineStartsFullscreenKey)
        }
        if defaults.object(forKey: Self.fadeResumeBannerAutomaticallyKey) != nil {
            fadeResumeBannerAutomatically = defaults.bool(forKey: Self.fadeResumeBannerAutomaticallyKey)
        }
        if let sec = defaults.object(forKey: Self.resumeBannerFadeDelaySecondsKey) as? Int, sec >= 1 {
            resumeBannerFadeDelaySeconds = min(sec, 120)
        }
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
        if let v = defaults.string(forKey: Self.ffmpegPathKey) { ffmpegUserPath = v }
        if let v = defaults.object(forKey: Self.showMissingKey) as? Bool { showMissing = v }
        if let v = defaults.object(forKey: Self.showRecentlyConvertedKey) as? Bool { showRecentlyConverted = v }
        if let data = defaults.data(forKey: Self.recentlyConvertedEntriesKey),
           let decoded = try? JSONDecoder().decode([ConvertedEntry].self, from: data)
        {
            recentlyConvertedEntries = decoded
        }
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
        if defaults.object(forKey: Self.showFilterStripKey) != nil {
            showFilterStrip = defaults.bool(forKey: Self.showFilterStripKey)
        }
        if let data = defaults.data(forKey: Self.customMetadataFieldDefinitionsKey),
           let decoded = try? JSONDecoder().decode([CustomMetadataFieldDefinition].self, from: data)
        {
            customMetadataFieldDefinitions = decoded
        }

        _loadingListColumnPreferences = true
        if let data = defaults.data(forKey: Self.listColumnPreferencesKey),
           let decoded = try? JSONDecoder().decode(ListColumnPreferences.self, from: data)
        {
            listColumnPreferences = decoded.sanitized(
                knownCustomFieldIds: Set(customMetadataFieldDefinitions.map(\.id))
            )
        } else {
            listColumnPreferences = .default
        }
        _loadingListColumnPreferences = false

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

    private static func isCorrupt(_ video: Video, thumbnailsSettled: Bool) -> Bool {
        video.duration == nil && video.width == nil && video.height == nil
            || (thumbnailsSettled && video.thumbnailPath == nil)
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
            selectedRatingStars: selectedRatingStars,
            tableSortOrder: tableSortOrder,
            excludeCorrupt: excludeCorrupt,
            thumbnailsSettled: thumbnailsSettled,
            searchText: searchText,
            ftsMatchIds: ftsMatchIds,
            duplicateVideoIds: duplicateVideoIds,
            missingVideoIds: missingVideoIds,
            recentlyAddedDays: recentlyAddedDays,
            recentlyPlayedDays: recentlyPlayedDays,
            topRatedMinRating: topRatedMinRating,
            recentlyConvertedDates: recentlyConvertedEntries.reduce(into: [:]) { dict, e in dict[e.path] = e.date }
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
        let selectedRatingStars: Set<Int>
        let tableSortOrder: [KeyPathComparator<Video>]
        let excludeCorrupt: Bool
        let thumbnailsSettled: Bool
        let searchText: String
        let ftsMatchIds: Set<String>?
        let duplicateVideoIds: Set<String>
        let missingVideoIds: Set<String>
        let recentlyAddedDays: Int
        let recentlyPlayedDays: Int
        let topRatedMinRating: Int
        let recentlyConvertedDates: [String: Date]
    }

    /// Multiple star levels are OR’d: video is included if its rating is in the selected set.
    private nonisolated static func applyRatingFilter(selectedStars: Set<Int>, base: [Video]) -> [Video] {
        guard !selectedStars.isEmpty else { return base }
        return base.filter { selectedStars.contains($0.rating) }
    }

    /// Concrete, fast replacement for `result.sort(using: [KeyPathComparator])`. The KeyPathComparator path
    /// boxes values and dynamically resolves the key path on every comparison — ~200ms for 12k items even on
    /// a trivial Date sort. Comparing concrete fields directly is ~10–20× faster. Mirrors
    /// `VideoSort.comparators(ascending:)`; `.name` uses `localizedStandardCompare` to match the natural/
    /// localized ordering of the Table column's String comparator.
    private nonisolated static func sortByTableOrder(_ videos: [Video], comparators: [KeyPathComparator<Video>]) -> [Video] {
        let first = comparators.first
        let sort = VideoSort.from(keyPath: first?.keyPath ?? \Video.dateAdded)
        let descending = (first?.order ?? .reverse) == .reverse
        var result = videos
        switch sort {
        case .name:
            result.sort { a, b in
                let r = a.fileName.localizedStandardCompare(b.fileName)
                return descending ? r == .orderedDescending : r == .orderedAscending
            }
        case .dateAdded:
            result.sort { descending ? $0.dateAdded > $1.dateAdded : $0.dateAdded < $1.dateAdded }
        case .duration:
            result.sort { descending ? $0.sortableDuration > $1.sortableDuration : $0.sortableDuration < $1.sortableDuration }
        case .fileSize:
            result.sort { descending ? $0.fileSize > $1.fileSize : $0.fileSize < $1.fileSize }
        case .rating:
            result.sort { descending ? $0.rating > $1.rating : $0.rating < $1.rating }
        case .resolution:
            result.sort { a, b in
                if a.sortableResolutionHeight != b.sortableResolutionHeight {
                    return descending
                        ? a.sortableResolutionHeight > b.sortableResolutionHeight
                        : a.sortableResolutionHeight < b.sortableResolutionHeight
                }
                return descending
                    ? a.sortablePixelCount > b.sortablePixelCount
                    : a.sortablePixelCount < b.sortablePixelCount
            }
        }
        return result
    }

    private nonisolated static func computeFilteredResult(snapshot: FilterSnapshot, collectionRepo: CollectionRepository) -> (videos: [Video], tagCounts: [Int64: Int]) {
        func isCorrupt(_ video: Video) -> Bool {
            video.duration == nil && video.width == nil && video.height == nil
                || (snapshot.thumbnailsSettled && video.thumbnailPath == nil)
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
        case .recentlyConverted:
            baseResult = baseResult.filter { snapshot.recentlyConvertedDates[$0.filePath] != nil }
        case .collection(let collection):
            guard let collectionId = collection.id else {
                return ([], [:])
            }
            let rules = snapshot.cachedCollectionRules[collectionId] ?? []
            if rules.isEmpty {
                return ([], [:])
            }
            let matcher = collectionRepo.compile(rules: rules, mode: collection.matchMode)
            baseResult = baseResult.filter { video in
                matcher.matches(video, tags: snapshot.tagsByVideoId[video.databaseId ?? -1] ?? [])
            }
        default:
            break
        }

        baseResult = Self.applyRatingFilter(selectedStars: snapshot.selectedRatingStars, base: baseResult)

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
        } else if snapshot.sidebarFilter == .recentlyConverted {
            result = result.sorted {
                (snapshot.recentlyConvertedDates[$0.filePath] ?? .distantPast) >
                (snapshot.recentlyConvertedDates[$1.filePath] ?? .distantPast)
            }
        } else {
            result = Self.sortByTableOrder(result, comparators: snapshot.tableSortOrder)
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

        // When the visible row *set* changes (e.g. clearing search restores the full library) selection
        // can stay valid while the grid/list viewport is unrelated — scroll the primary selection into view.
        // Skipped when rename/sort handling above already queued a scroll (`scrollToVideoId` non-nil).
        if structureChanged, scrollToVideoId == nil,
           let id = lastSelectedVideoId ?? selectedVideoIds.first,
           !selectedVideoIds.isEmpty,
           selectedVideoIds.contains(id),
           newValue.contains(where: { $0.id == id })
        {
            scrollToVideoId = id
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
        let convertedPaths = Set(recentlyConvertedEntries.map(\.path))

        typealias DupKey = String
        var buckets: [DupKey: [String]] = [:]
        for video in videos {
            let isCorrupt = Self.isCorrupt(video, thumbnailsSettled: thumbnailsSettled)
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

        let recentlyConverted = videos.filter { convertedPaths.contains($0.filePath) }.count

        libraryCounts = LibraryCounts(
            all: allCount,
            recentlyAdded: recentlyAdded,
            recentlyPlayed: recentlyPlayed,
            topRated: topRated,
            duplicates: dupIds.count,
            corrupt: corrupt,
            missing: missingCountScanned ? missingVideoIds.count : 0,
            recentlyConverted: recentlyConverted,
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

    /// Videos after applying library/collection sidebar filter and per-star rating filter, before tag filter.
    private func baseVideosForPrimaryFilter() -> [Video] {
        var result = videos
        let isCorruptFilter = sidebarFilter == .corrupt
        if excludeCorrupt && !isCorruptFilter && searchText.isEmpty {
            result = result.filter { !Self.isCorrupt($0, thumbnailsSettled: thumbnailsSettled) }
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
            result = result.filter { Self.isCorrupt($0, thumbnailsSettled: thumbnailsSettled) }
        case .missing:
            result = result.filter { missingVideoIds.contains($0.id) }
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
        result = Self.applyRatingFilter(selectedStars: selectedRatingStars, base: result)
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

    /// Rescans videos in the **current filtered list** for a sidecar `.srt` file and updates the
    /// `hasSubtitles` flag accordingly (search, tags, collections, sidebar filters, etc. all narrow scope).
    /// Disk I/O is chunked and dispatched off the main actor so the UI remains responsive; progress is
    /// reported via `scanCurrent` / `scanTotal` / `scanProgress`.
    func scanForSubtitles() async {
        guard !isScanning else { return }
        guard !filteredVideos.isEmpty else {
            let message = videos.isEmpty ? "No videos to scan" : "No videos match the current filter"
            scanProgress = message
            Task { [message] in
                try? await Task.sleep(for: .seconds(2))
                if scanProgress == message { scanProgress = "" }
            }
            return
        }

        // Snapshot inputs once — only videos with a DB id can be updated.
        struct Row: Sendable {
            let dbId: Int64
            let filePath: String
            let had: Bool
        }
        let snapshot: [Row] = filteredVideos.compactMap { v in
            guard let id = v.databaseId else { return nil }
            return Row(dbId: id, filePath: v.filePath, had: v.hasSubtitles)
        }
        let total = snapshot.count

        isScanning = true
        stopObserving()
        scanTotal = total
        scanCurrent = 0
        scanProgress = "Scanning \(total) video\(total == 1 ? "" : "s") for subtitles…"

        // Process in chunks on a background task so the UI can keep drawing progress.
        let chunkSize = 200
        var updates: [(videoId: Int64, hasSubtitles: Bool)] = []
        var index = 0
        while index < snapshot.count {
            let end = min(index + chunkSize, snapshot.count)
            let chunk = Array(snapshot[index..<end])
            let chunkUpdates: [(Int64, Bool)] = await Task.detached(priority: .userInitiated) {
                var out: [(Int64, Bool)] = []
                out.reserveCapacity(chunk.count)
                for row in chunk {
                    let url = URL(fileURLWithPath: row.filePath)
                    let hasNow = SubtitleTrack.findSidecarSRT(for: url) != nil
                    if hasNow != row.had {
                        out.append((row.dbId, hasNow))
                    }
                }
                return out
            }.value
            updates.append(contentsOf: chunkUpdates.map { ($0.0, $0.1) })
            index = end
            scanCurrent = index
        }

        let added = updates.reduce(0) { $0 + ($1.hasSubtitles ? 1 : 0) }
        let removed = updates.count - added

        if !updates.isEmpty {
            try? await videoRepo.updateHasSubtitles(updates: updates)
            videos = (try? await videoRepo.fetchAll()) ?? videos
            // `applyFilteredVideos` only bumps `filteredVideosVersion` when the **set** of rows
            // changes — so a subtitle-only edit leaves the list/grid `.id(...)` unchanged and
            // SwiftUI reuses stale `Video` values. Force a version bump so both views remount
            // with the refreshed `hasSubtitles` flag.
            filteredVideosVersion &+= 1
        }
        startObserving()
        isScanning = false

        let summary: String
        switch (added, removed) {
        case (0, 0):
            summary = "No subtitle changes found"
        case (let a, 0):
            summary = "Found subtitles for \(a) video\(a == 1 ? "" : "s")"
        case (0, let r):
            summary = "Cleared subtitles flag on \(r) video\(r == 1 ? "" : "s")"
        case (let a, let r):
            summary = "Added \(a), cleared \(r)"
        }
        scanProgress = summary
        Task { [summary] in
            try? await Task.sleep(for: .seconds(4))
            if scanProgress == summary { scanProgress = "" }
        }
    }

    /// Sets the `hasSubtitles` flag in-memory and persists to the DB. No-op if the flag already matches,
    /// so repeated calls (e.g. from the detail pane on every selection) are free.
    /// Re-extracts metadata for a video that appears corrupt. Called when the user views a
    /// corrupt video in the detail pane — covers files repaired externally (e.g. via ffmpeg)
    /// that now have valid metadata but whose DB record still shows nil fields.
    func refreshMetadataIfCorrupt(for video: Video) async {
        guard isCorrupt(video) else { return }
        let metadata = await MetadataExtractor().extract(from: video.url)
        guard metadata.duration != nil || metadata.width != nil else { return }
        guard let idx = videos.firstIndex(where: { $0.filePath == video.filePath }) else { return }
        var updated = videos
        updated[idx].duration = metadata.duration
        updated[idx].width = metadata.width
        updated[idx].height = metadata.height
        if let codec = metadata.codec { updated[idx].codec = codec }
        if let frameRate = metadata.frameRate { updated[idx].frameRate = frameRate }
        let updatedVideo = updated[idx]
        videos = updated
        try? await videoRepo.update(updatedVideo)

        if updatedVideo.thumbnailPath == nil,
           let thumbURL = try? await thumbnailService.generateThumbnail(for: updatedVideo) {
            await setThumbnailPath(videoPath: updatedVideo.filePath, url: thumbURL)
        }
    }

    private func isCorrupt(_ video: Video) -> Bool {
        Self.isCorrupt(video, thumbnailsSettled: thumbnailsSettled)
    }

    func setThumbnailPath(videoPath: String, url: URL) async {
        guard let idx = videos.firstIndex(where: { $0.filePath == videoPath }) else { return }
        var updated = videos
        updated[idx].thumbnailPath = url.path
        let dbId = updated[idx].databaseId
        videos = updated
        if let dbId {
            try? await videoRepo.updateThumbnailPath(videoId: dbId, path: url.path)
        }
    }

    func setHasSubtitles(videoPath: String, hasSubtitles: Bool) async {
        guard let idx = videos.firstIndex(where: { $0.filePath == videoPath }) else { return }
        guard videos[idx].hasSubtitles != hasSubtitles else { return }
        // Mutate a local copy first so the `didSet` observer on `videos` fires exactly once.
        var updated = videos
        updated[idx].hasSubtitles = hasSubtitles
        let dbId = updated[idx].databaseId
        videos = updated
        if let dbId {
            try? await videoRepo.updateHasSubtitles(videoId: dbId, hasSubtitles: hasSubtitles)
        }
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

    /// Per-field merged string; `nil` means selected videos disagree (show “Various”).
    func mergedCustomMetadata(forVideoPaths paths: [String]) async -> [UUID: String?] {
        let defs = customMetadataFieldDefinitions
        guard !defs.isEmpty else { return [:] }
        let dbIds = paths.compactMap { path in
            videos.first(where: { $0.filePath == path })?.databaseId
        }
        guard !dbIds.isEmpty else {
            return Dictionary(uniqueKeysWithValues: defs.map { ($0.id, nil as String?) })
        }

        var perVideo: [[String: String]] = []
        for dbId in dbIds {
            let row = (try? await videoRepo.fetchCustomMetadata(forVideoId: dbId)) ?? [:]
            perVideo.append(row)
        }

        var out: [UUID: String?] = [:]
        for def in defs {
            let key = def.id.uuidString
            let vals = perVideo.map { $0[key] ?? "" }
            if Set(vals).count == 1 {
                out[def.id] = vals.first
            } else {
                out[def.id] = nil
            }
        }
        return out
    }

    func persistCustomMetadata(fieldId: UUID, value: String, forVideoPaths paths: Set<String>) async {
        let dbIds = paths.compactMap { path in
            videos.first(where: { $0.filePath == path })?.databaseId
        }
        guard !dbIds.isEmpty else { return }
        try? await videoRepo.upsertCustomMetadata(videoIds: dbIds, fieldId: fieldId, value: value)
        for id in dbIds {
            mergeListCustomMetadataCache(videoId: id, fieldId: fieldId, value: value)
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

    func moveVideos(_ videosToMove: [Video], to destinationFolder: URL) async {
        isMoving = true
        defer { isMoving = false; moveProgress = "" }
        let total = videosToMove.count
        for (index, video) in videosToMove.enumerated() {
            let name = video.fileName
            let remaining = total - index - 1
            moveProgress = remaining > 0
                ? "Moving '\(name)'… (\(remaining) remaining)"
                : "Moving '\(name)'…"
            let newURL = destinationFolder.appendingPathComponent(name)
            if newURL == video.url { continue }
            guard !FileManager.default.fileExists(atPath: newURL.path) else {
                moveProgress = "Skipped '\(name)': file already exists at destination"
                try? await Task.sleep(for: .seconds(2))
                continue
            }
            do {
                try FileManager.default.moveItem(at: video.url, to: newURL)
            } catch {
                moveProgress = "Failed to move '\(name)': \(error.localizedDescription)"
                try? await Task.sleep(for: .seconds(2))
                continue
            }
            guard let dbId = video.databaseId else { continue }
            do {
                try await videoRepo.renameVideo(videoId: dbId, newFilePath: newURL.path, newFileName: name)
            } catch {
                try? FileManager.default.moveItem(at: newURL, to: video.url)
                moveProgress = "Failed to update library for '\(name)'"
                try? await Task.sleep(for: .seconds(2))
                continue
            }
            thumbnailService.migrateCacheKey(from: video.filePath, to: newURL.path)
            if selectedVideoIds.contains(video.filePath) {
                selectedVideoIds.remove(video.filePath)
                selectedVideoIds.insert(newURL.path)
            }
            if lastSelectedVideoId == video.filePath {
                lastSelectedVideoId = newURL.path
            }
        }
    }

    func videoConvertedToMP4(_ video: Video, newPath: String) async {
        guard let dbId = video.databaseId else { return }
        let newURL = URL(fileURLWithPath: newPath)
        let newFileName = newURL.lastPathComponent

        do {
            try await videoRepo.renameVideo(videoId: dbId, newFilePath: newPath, newFileName: newFileName)
        } catch {
            print("videoConvertedToMP4 DB update failed: \(error)")
            return
        }

        if selectedVideoIds.contains(video.filePath) {
            selectedVideoIds.remove(video.filePath)
            selectedVideoIds.insert(newPath)
        }
        if lastSelectedVideoId == video.filePath {
            lastSelectedVideoId = newPath
        }

        // Look up by DB id, not filePath: GRDB's observation may have already updated
        // the in-memory path (e.g. wmv→mp4) before we reach this line.
        guard let idx = videos.firstIndex(where: { $0.databaseId == dbId }) else { return }
        var updated = videos
        updated[idx].filePath = newPath
        updated[idx].fileName = newFileName
        updated[idx].thumbnailPath = nil
        if let size = (try? newURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
            updated[idx].fileSize = Int64(size)
        }

        let metadata = await MetadataExtractor().extract(from: newURL)
        if let duration = metadata.duration { updated[idx].duration = duration }
        if let width = metadata.width { updated[idx].width = width }
        if let height = metadata.height { updated[idx].height = height }
        if let codec = metadata.codec { updated[idx].codec = codec }
        if let frameRate = metadata.frameRate { updated[idx].frameRate = frameRate }

        let updatedVideo = updated[idx]
        videos = updated
        try? await videoRepo.update(updatedVideo)

        if let thumbURL = try? await thumbnailService.generateThumbnail(for: updatedVideo) {
            await setThumbnailPath(videoPath: newPath, url: thumbURL)
        }

        if selectedVideoIds.contains(newPath) {
            filmstripRefreshId &+= 1
        }
    }

    func reencodeVideo(_ video: Video, ffmpegPath: String) {
        conversionQueue.append((video: video, ffmpegPath: ffmpegPath))
        updateConversionProgress()
        if !isConverting {
            isConverting = true
            Task { await drainConversionQueue() }
        }
    }

    private func updateConversionProgress() {
        guard !conversionQueue.isEmpty else { return }
        let name = conversionQueue[0].video.fileName
        let remaining = conversionQueue.count - 1
        conversionProgress = remaining > 0
            ? "Re-encoding '\(name)'… (\(remaining) remaining)"
            : "Re-encoding '\(name)'…"
    }

    private func drainConversionQueue() async {
        isConverting = true
        defer {
            isConverting = false
            conversionProgress = ""
        }

        recentlyConvertedEntries = []
        if let data = try? JSONEncoder().encode(recentlyConvertedEntries) {
            UserDefaults.standard.set(data, forKey: Self.recentlyConvertedEntriesKey)
        }
        updateLibraryCounts()
        recomputeFilteredVideos()

        while !conversionQueue.isEmpty {
            let job = conversionQueue[0]
            updateConversionProgress()
            await performReencode(video: job.video, ffmpegPath: job.ffmpegPath)
            conversionQueue.removeFirst()
        }
    }

    private func performReencode(video: Video, ffmpegPath: String) async {
        let videoURL = URL(fileURLWithPath: video.filePath)
        let stem = videoURL.deletingPathExtension().lastPathComponent
        let ext = videoURL.pathExtension
        let dir = videoURL.deletingLastPathComponent().path
        let backupName = ext.isEmpty ? "\(stem)_original" : "\(stem)_original.\(ext)"
        let backupURL = URL(fileURLWithPath: (dir as NSString).appendingPathComponent(backupName))
        let outputURL = URL(fileURLWithPath: (dir as NSString).appendingPathComponent("\(stem).mp4"))
        let fm = FileManager.default

        guard !fm.fileExists(atPath: backupURL.path) else {
            conversionProgress = "Skipped '\(video.fileName)': backup already exists"
            try? await Task.sleep(for: .seconds(3))
            return
        }
        if outputURL.path != video.filePath, fm.fileExists(atPath: outputURL.path) {
            conversionProgress = "Skipped '\(video.fileName)': output already exists"
            try? await Task.sleep(for: .seconds(3))
            return
        }

        do {
            try fm.moveItem(at: videoURL, to: backupURL)
        } catch {
            conversionProgress = "Failed to rename '\(video.fileName)': \(error.localizedDescription)"
            try? await Task.sleep(for: .seconds(4))
            return
        }

        let duration = video.duration
        let name = video.fileName
        let progressPipe = Pipe()

        // Read ffmpeg's -progress output and update the status bar with a percentage.
        // Falls back to a plain spinner message when duration is unknown.
        let progressTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let handle = progressPipe.fileHandleForReading
            var buffer = ""
            while true {
                let data = handle.availableData
                guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { break }
                buffer += chunk
                var lines = buffer.components(separatedBy: "\n")
                buffer = lines.removeLast()
                for line in lines {
                    guard line.hasPrefix("out_time_ms="),
                          let us = Double(line.dropFirst("out_time_ms=".count)),
                          let dur = duration, dur > 0
                    else { continue }
                    let pct = min(99, Int(us / (dur * 1_000_000) * 100))
                    await MainActor.run { [weak self] in
                        self?.conversionProgress = "Re-encoding '\(name)'… \(pct)%"
                    }
                }
            }
        }

        let exitCode = await Task.detached(priority: .userInitiated) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: ffmpegPath)
            proc.arguments = ["-i", backupURL.path, "-c:v", "libx264", "-c:a", "aac",
                              "-movflags", "+faststart", "-y", "-progress", "pipe:1", outputURL.path]
            proc.standardOutput = progressPipe
            proc.standardError = FileHandle.nullDevice
            return await withCheckedContinuation { continuation in
                proc.terminationHandler = { p in continuation.resume(returning: p.terminationStatus) }
                guard (try? proc.run()) != nil else {
                    continuation.resume(returning: Int32(-1))
                    return
                }
            }
        }.value

        // Wait for the progress reader to drain the pipe before continuing.
        await progressTask.value

        if exitCode == 0 {
            try? fm.trashItem(at: backupURL, resultingItemURL: nil)
            await videoConvertedToMP4(video, newPath: outputURL.path)
            addRecentlyConverted(path: outputURL.path)
        } else {
            // Delete ffmpeg's partial/0-byte output before restoring. Skip when re-encoding
            // in place (source already .mp4), where outputURL == the file we're restoring.
            if outputURL.path != video.filePath {
                try? fm.removeItem(at: outputURL)
            }
            // Restore original
            try? fm.moveItem(at: backupURL, to: videoURL)
            conversionProgress = "Re-encoding failed for '\(video.fileName)'"
            try? await Task.sleep(for: .seconds(4))
        }
    }

    private func addRecentlyConverted(path: String) {
        recentlyConvertedEntries.append(ConvertedEntry(path: path, date: Date()))
        if let data = try? JSONEncoder().encode(recentlyConvertedEntries) {
            UserDefaults.standard.set(data, forKey: Self.recentlyConvertedEntriesKey)
        }
        updateLibraryCounts()
        recomputeFilteredVideos()
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

    /// True when the filter strip’s per-star rating filter is active.
    var isRatingFilterActive: Bool {
        !selectedRatingStars.isEmpty
    }

    /// Clears the per-star rating filter (filter strip → Rating).
    func clearRatingFilter() {
        selectedRatingStars = []
    }

    /// Clears tag filters and the per-star rating filter (View menu **⌘⌥C**).
    func clearFilters() {
        clearTagFilters()
        clearRatingFilter()
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
        // Snapshot main-actor state, then compute the O(videos × collections × rules) loop off the main
        // actor — it was a ~180ms main-thread stall at 12k. Result is assigned back on the main actor.
        let baseVideos = excludeCorrupt ? videos.filter { !Self.isCorrupt($0, thumbnailsSettled: thumbnailsSettled) } : videos
        let currentTags = tagsByVideoId
        let allRules = cachedCollectionRules
        let cols = collections
        let repo = collectionRepo

        let counts = await Task.detached(priority: .utility) {
            var counts: [Int64: Int] = [:]
            for collection in cols {
                guard let id = collection.id else { continue }
                let rules = allRules[id] ?? []
                if rules.isEmpty { continue }
                let matcher = repo.compile(rules: rules, mode: collection.matchMode)
                counts[id] = baseVideos.filter { video in
                    matcher.matches(video, tags: currentTags[video.databaseId ?? -1] ?? [])
                }.count
            }
            return counts
        }.value

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

    private func startThumbnailSettlingTask() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            while self.thumbnailService.hasPendingThumbnails {
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard !self.thumbnailsSettled else { return }
            self.thumbnailsSettled = true
            self.recomputeFilteredVideos()
            self.updateLibraryCounts()
        }
    }

    private func refreshAfterScan() async {
        videos = (try? await videoRepo.fetchAll()) ?? []
        await loadTags()
        await refreshTagsByVideoId()
        await refreshCollectionCounts()
        startObserving()
    }
}
