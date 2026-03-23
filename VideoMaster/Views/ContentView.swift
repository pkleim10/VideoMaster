import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if !appState.hasLibrary {
            LandingView()
                .frame(minWidth: 900, minHeight: 600)
        } else if let vm = appState.libraryViewModel {
            LibraryContentView(vm: vm, thumbService: appState.thumbnailService)
        }
    }
}

private struct LibraryContentView: View {
    /// Required so `browsingLayout` changes invalidate `NSViewRepresentable` and apply saved split positions.
    @Bindable var vm: LibraryViewModel
    let thumbService: ThumbnailService
    /// Persists across content host rootView replacements (playback/browsing switch, layout changes).
    @State private var gridScrollPositionId: String?
    @State private var listScrollPositionRow: Int?
    /// Must remove when the view goes away; repeated `onAppear` without removal stacks monitors and breaks handling.
    @State private var keyDownMonitor: Any?
    @State private var isFilterStripHovered = false
    /// Screen rect of the filter strip (for upward-exit detection).
    @State private var filterStripScreenFrame: CGRect = .zero
    /// When collapse-unhover is on: true only after leaving the strip by moving up into the list/grid.
    @State private var filterStripCollapsedByUpwardExit = false

    private var navigationTitle: String {
        let name = DatabaseExportImport.activeLibraryDisplayName
        if name.isEmpty || name == "VideoMaster" { return "VideoMaster" }
        return "VideoMaster — \(name)"
    }

    private var detailID: String {
        vm.lastSelectedVideoId ?? ""
    }

    /// Identity for the bottom filter strip hosting view (collections/tags counts).
    private var filterStripHostID: String {
        "\(vm.sidebarFilter.hashValue)-\(vm.collections.count)-\(vm.tags.count)-\(vm.libraryCounts.all)-\(vm.showRecentlyAdded)-\(vm.showRecentlyPlayed)-\(vm.showTopRated)-\(vm.showDuplicates)-\(vm.showCorrupt)-\(vm.showMissing)"
    }

    /// Column targets for the split view always follow browsing layout so toggling playback
    /// does not change effective widths (avoids a layout pulse / grid jump before freeze).
    private var browsingSplitContentWidth: CGFloat {
        CGFloat(vm.browsingLayout.contentColumnWidth(for: vm.viewMode))
    }
    private var browsingSplitDetailWidth: CGFloat {
        CGFloat(vm.browsingLayout.detailColumnWidth(for: vm.viewMode))
    }
    private var browsingSplitTopPaneHeight: CGFloat {
        CGFloat(vm.browsingLayout.browserTopPaneHeight(for: vm.viewMode))
    }

    /// Use saved splitter height unless collapse mode is on and the user left upward (thin strip) or hasn’t re-entered.
    private var expandFilterStripToSavedHeight: Bool {
        if !vm.collapseFilterStripWhenUnhovered { return true }
        return isFilterStripHovered || !filterStripCollapsedByUpwardExit
    }

    var body: some View {
        VStack(spacing: 0) {
            // Browser column = list/grid + bottom filter columns; detail = right pane.
            // Persists via `LayoutParams` (content/detail widths + `browserTopPaneHeight{Grid,List}`).
            ResizableBrowserDetailSplitView(
                layoutModeKey: vm.viewMode.rawValue,
                contentWidth: browsingSplitContentWidth,
                detailWidth: browsingSplitDetailWidth,
                contentID: "browserShell",
                detailID: detailID,
                freezeContent: vm.isPlayingInline,
                onSizesChanged: { browserW, detailW in
                    vm.updateCurrentLayoutWithSizes(sidebarWidth: nil, contentWidth: browserW, detailWidth: detailW)
                },
                content: {
                    ResizableVerticalSplitView(
                        layoutModeKey: vm.viewMode.rawValue,
                        topPaneHeight: browsingSplitTopPaneHeight,
                        topID: vm.viewMode.rawValue,
                        bottomID: filterStripHostID,
                        collapseFilterStripWhenUnhovered: vm.collapseFilterStripWhenUnhovered,
                        expandFilterStripToSavedHeight: expandFilterStripToSavedHeight,
                        onTopHeightChanged: { h in
                            vm.updateCurrentLayoutWithSizes(browserTopPaneHeight: h)
                        },
                        top: { libraryContent },
                        bottom: {
                            BottomFilterColumnsView(viewModel: vm)
                                .background {
                                    FilterStripScreenFrameReader(screenFrame: $filterStripScreenFrame)
                                }
                                .onHover { inside in
                                    if inside {
                                        isFilterStripHovered = true
                                        filterStripCollapsedByUpwardExit = false
                                    } else {
                                        isFilterStripHovered = false
                                        guard vm.collapseFilterStripWhenUnhovered else { return }
                                        let p = NSEvent.mouseLocation
                                        let f = filterStripScreenFrame
                                        guard f.width > 1, f.height > 1 else {
                                            filterStripCollapsedByUpwardExit = false
                                            return
                                        }
                                        // Screen coords: Y increases upward. Above strip top → moved into list/grid.
                                        if p.y > f.maxY {
                                            filterStripCollapsedByUpwardExit = true
                                        } else {
                                            filterStripCollapsedByUpwardExit = false
                                        }
                                    }
                                }
                        }
                    )
                },
                detail: { detailContent }
            )
            .navigationTitle(navigationTitle)

            statusBar(vm: vm)
        }
        .task { vm.startObserving() }
        .onChange(of: vm.collapseFilterStripWhenUnhovered) { _, enabled in
            if !enabled { filterStripCollapsedByUpwardExit = false }
        }
        .onAppear {
            guard keyDownMonitor == nil else { return }
            let lvm = vm
            keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                Self.processLibraryKeyDown(event, lvm: lvm)
            }
        }
        .onDisappear {
            if let m = keyDownMonitor {
                NSEvent.removeMonitor(m)
                keyDownMonitor = nil
            }
        }
    }

    @ViewBuilder
    private var libraryContent: some View {
        Group {
            if vm.viewMode == .grid {
                LibraryGridView(
                    viewModel: vm,
                    thumbnailService: thumbService,
                    scrollPositionId: $gridScrollPositionId
                )
            } else {
                LibraryListView(
                    viewModel: vm,
                    thumbnailService: thumbService,
                    scrollPositionRow: $listScrollPositionRow
                )
            }
        }
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    guard !providers.isEmpty else { return true }
                    let group = DispatchGroup()
                    var urls: [URL] = []
                    let lock = NSLock()
                    for provider in providers {
                        group.enter()
                        _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                            defer { group.leave() }
                            if let data = data,
                               let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                               let url = URL(string: path)
                            {
                                lock.lock()
                                urls.append(url)
                                lock.unlock()
                            }
                        }
                    }
                    group.notify(queue: .main) {
                        Task { await vm.importDroppedFiles(urls) }
                    }
                    return true
                }
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button(action: { vm.showFolderPicker() }) {
                            Label("Add Folder", systemImage: "folder.badge.plus")
                        }
                        .help("Add a folder of videos to your library")

                        Button(action: { Task { await vm.importNew() } }) {
                            Label("Import New", systemImage: "arrow.down.circle")
                        }
                        .disabled(vm.isScanning)
                        .help("Scan data sources for new video files")

                        Picker("View Mode", selection: Binding(
                            get: { vm.viewMode },
                            set: { newValue in
                                vm.viewMode = newValue
                                vm.savePreferences()
                                if !vm.selectedVideoIds.isEmpty {
                                    vm.scrollToSelectedOnViewSwitch = true
                                }
                            }
                        )) {
                            Label("List", systemImage: "list.bullet")
                                .tag(ViewMode.list)
                            Label("Grid", systemImage: "square.grid.2x2")
                                .tag(ViewMode.grid)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 80)

                        Button(action: {
                            vm.surpriseMePickRandom()
                        }) {
                            Label("Surprise Me!", systemImage: "exclamationmark.circle.fill")
                        }
                        .disabled(vm.filteredVideos.isEmpty)
                        .help("Random video: filmstrip in detail first, then scroll list/grid to the selection")

                        SortMenuButton(viewModel: vm)
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        if case .missing = vm.sidebarFilter {
                            Button(action: { Task { await vm.refreshMissingCount() } }) {
                                Label("Scan for missing files", systemImage: "magnifyingglass")
                            }
                            .disabled(vm.isRefreshingMissing)
                            .help("Scan for missing files")
                        }
                    }
                }
                .searchable(text: Binding(get: { vm.searchText }, set: { vm.searchText = $0 }), prompt: "Search videos")
                .overlay {
                    if vm.videos.isEmpty && !vm.isScanning {
                        emptyStateView
                    }
                }
                .frame(minWidth: 80)
    }

    @ViewBuilder
    private var detailContent: some View {
        Group {
            if let selectedId = vm.lastSelectedVideoId ?? vm.selectedVideoIds.first,
               let video = vm.filteredVideos.first(where: { $0.id == selectedId })
            {
                VideoDetailView(video: video, viewModel: vm, thumbnailService: thumbService)
            } else {
                Text("Select a video")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 200)
    }

    /// Returns `nil` to consume the key event (do not deliver to the app).
    private static func processLibraryKeyDown(_ event: NSEvent, lvm: LibraryViewModel) -> NSEvent? {
        // Enter key (without modifiers) — start inline rename in list or grid mode
        if event.keyCode == 36, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [], !lvm.isEditingText {
            if (lvm.viewMode == .list || lvm.viewMode == .grid),
               lvm.selectedVideoIds.count == 1,
               let videoId = lvm.selectedVideoIds.first,
               let video = lvm.filteredVideos.first(where: { $0.id == videoId })
            {
                DispatchQueue.main.async {
                    lvm.renameText = video.fileName
                    lvm.renamingVideoId = videoId
                }
                return nil
            }
            return event
        }
        // Escape key — cancel rename or stop playback
        if event.keyCode == 53 {
            if lvm.renamingTagId != nil {
                DispatchQueue.main.async {
                    lvm.renamingTagId = nil
                    lvm.tagRenameText = ""
                    lvm.isEditingText = false
                }
                return nil
            }
            if lvm.renamingVideoId != nil {
                DispatchQueue.main.async {
                    lvm.renamingVideoId = nil
                    lvm.renameText = ""
                }
                return nil
            }
            if lvm.isPlayingInline {
                DispatchQueue.main.async {
                    lvm.isPlayingInline = false
                }
                return nil
            }
            return event
        }
        // Space key — play/pause (but not when typing in search or other text fields)
        if event.keyCode == 49 {
            if let first = NSApp.keyWindow?.firstResponder,
               first is NSTextView || first is NSTextField
            {
                return event
            }
            guard !lvm.isEditingText, !lvm.selectedVideoIds.isEmpty else { return event }
            DispatchQueue.main.async {
                if lvm.isPlayingInline {
                    lvm.inlinePlayPauseToggle += 1
                } else {
                    lvm.isPlayingInline = true
                }
            }
            return nil
        }
        // Grid ↑/↓ selection is handled by `LibraryGridView` (`.focusable` + `.onKeyPress`) so keys reach
        // the same SwiftUI focus system as the scroll view; local monitors are unreliable here.
        return event
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "film.stack")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("No Videos")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("Add a folder to scan for video files")
                .foregroundStyle(.tertiary)
            Button("Add Folder") {
                vm.showFolderPicker()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func statusBar(vm: LibraryViewModel) -> some View {
        let itemCount = vm.filteredVideos.count
        let selectedCount = vm.selectedVideoIds.count

        return HStack(spacing: 0) {
            Text("\(itemCount) \(itemCount == 1 ? "item" : "items")")
                .font(.caption)
                .foregroundStyle(.secondary)

            if selectedCount > 0 {
                Text("  ·  \(selectedCount) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if vm.isScanning && vm.scanTotal > 0 {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Importing \(vm.scanCurrent)/\(vm.scanTotal)")
                        .font(.caption)
                        .monospacedDigit()
                    ProgressView(
                        value: Double(vm.scanCurrent),
                        total: Double(vm.scanTotal)
                    )
                    .frame(width: 120)
                }
            } else if !vm.scanProgress.isEmpty {
                Text(vm.scanProgress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

// MARK: - Filter strip screen frame (upward exit detection)

/// Reports the filter strip’s bounds in **screen** coordinates (matches `NSEvent.mouseLocation`).
private struct FilterStripScreenFrameReader: NSViewRepresentable {
    @Binding var screenFrame: CGRect

    func makeNSView(context: Context) -> NSView {
        FilterStripFrameReportingView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let v = nsView as? FilterStripFrameReportingView else { return }
        let binding = $screenFrame
        v.onFrameChange = { [weak v] in
            guard let v, let win = v.window else { return }
            let r = win.convertToScreen(v.convert(v.bounds, to: nil))
            DispatchQueue.main.async {
                binding.wrappedValue = r
            }
        }
        v.onFrameChange?()
    }
}

private final class FilterStripFrameReportingView: NSView {
    var onFrameChange: (() -> Void)?

    override func layout() {
        super.layout()
        onFrameChange?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onFrameChange?()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onFrameChange?()
    }
}
