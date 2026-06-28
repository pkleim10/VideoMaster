import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if !appState.hasLibrary {
            LandingView()
                .frame(minWidth: 900, minHeight: 600)
                .appDesignSystem()
        } else if let vm = appState.libraryViewModel {
            LibraryContentView(vm: vm, thumbService: appState.thumbnailService)
                .appDesignSystem()   // Injects VideoMaster design tokens + theme
        }
    }
}

private struct LibraryContentView: View {
    /// Required so `browsingLayout` changes invalidate `NSViewRepresentable` and apply saved split positions.
    @Bindable var vm: LibraryViewModel
    let thumbService: ThumbnailService
    /// Persists across content host rootView replacements (playback/browsing switch, layout changes).
    @State private var listScrollPositionRow: Int?
    /// Must remove when the view goes away; repeated `onAppear` without removal stacks monitors and breaks handling.
    @State private var keyDownMonitor: Any?
    @State private var showListColumnsSheet = false
    @FocusState private var isSearchFocused: Bool

    /// The video shown in the detail pane / overlay (primary selection). Shared by `detailContent` and the overlay.
    private var selectedVideo: Video? {
        guard let id = vm.lastSelectedVideoId ?? vm.selectedVideoIds.first else { return nil }
        return vm.filteredVideos.first(where: { $0.id == id })
    }

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
        "\(vm.sidebarFilter.hashValue)-\(vm.collections.count)-\(vm.tags.count)-\(vm.libraryCounts.all)-\(vm.showRecentlyAdded)-\(vm.showRecentlyPlayed)-\(vm.showTopRated)-\(vm.showDuplicates)-\(vm.showCorrupt)-\(vm.showMissing)-\(vm.showRecentlyConverted)-\(vm.libraryCounts.recentlyConverted)"
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
                freezeContent: vm.inlinePlaybackReshapesBrowser,
                onSizesChanged: { browserW, detailW in
                    vm.updateCurrentLayoutWithSizes(sidebarWidth: nil, contentWidth: browserW, detailWidth: detailW)
                },
                content: {
                    ResizableVerticalSplitView(
                        layoutModeKey: vm.viewMode.rawValue,
                        topPaneHeight: browsingSplitTopPaneHeight,
                        topID: vm.viewMode.rawValue,
                        bottomID: filterStripHostID,
                        expandFilterStrip: vm.showFilterStrip,
                        onTopHeightChanged: { h in
                            vm.updateCurrentLayoutWithSizes(browserTopPaneHeight: h)
                        },
                        top: { libraryContent },
                        bottom: {
                            BottomFilterColumnsView(viewModel: vm)
                        }
                    )
                },
                detail: { detailContent }
            )
            .overlay {
                // Floating overlay player: covers only its trailing panel, leaving the browser/detail beneath
                // untouched (no freeze/resize → grid scroll preserved). Shown only in overlay playback mode.
                if vm.inlineOverlayActive, vm.isPlayingInline, let video = selectedVideo {
                    GeometryReader { geo in
                        OverlayPlayerPanel(video: video, viewModel: vm, totalWidth: geo.size.width)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    }
                }
            }
            .navigationTitle(navigationTitle)

            statusBar(vm: vm)
        }
        .task { vm.startObserving() }
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

    private var libraryContent: some View {
        VStack(spacing: 0) {
            libraryNavBar
            contentBody
        }
    }

    /// Inline bar directly above the list/grid: the List/Grid mode picker plus the top/bottom/page scroll
    /// controls. Each scroll button hosts its keyboard shortcut; the per-view `ScrollCommandHandler` scrolls.
    private var libraryNavBar: some View {
        HStack(spacing: 8) {
            AppSegmentedControl(
                selection: Binding(
                    get: { vm.viewMode },
                    set: { newValue in
                        vm.viewMode = newValue
                        vm.savePreferences()
                        if !vm.selectedVideoIds.isEmpty {
                            vm.scrollToSelectedOnViewSwitch = true
                        }
                    }
                ),
                items: [ViewMode.list, .grid]
            ) { mode in
                switch mode {
                case .list:
                    Label("List", systemImage: "list.bullet")
                case .grid:
                    Label("Grid", systemImage: "square.grid.2x2")
                }
            }

            if vm.viewMode == .grid {
                AppSegmentedControl(
                    selection: Binding(
                        get: { vm.gridSize },
                        set: { newValue in
                            vm.gridSize = newValue
                            vm.savePreferences()
                        }
                    ),
                    items: GridSize.allCases
                ) { size in
                    Text(size.label)
                }
                .help("Thumbnail size")
            }

            if vm.viewMode == .list {
                Button {
                    showListColumnsSheet = true
                } label: {
                    Label("Columns", systemImage: "tablecells")
                }
                .labelStyle(.iconOnly)
                .appNavBarButton()
                .help("Choose which columns appear in list view")
            }

            SortMenuButton(viewModel: vm)
                .appNavBarButton()
                .fixedSize()

            // Custom search field (replaces stock .searchable for full Cinematic Blue styling)
            HStack(spacing: AppSpacing.xs) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Color.appTextTertiary)
                    .font(.callout)
                TextField("Search videos", text: $vm.searchText)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Color.appTextPrimary)
                    .tint(Color.appAccent)
                    .focused($isSearchFocused)
                if !vm.searchText.isEmpty {
                    Button {
                        vm.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.appTextTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, AppSpacing.sm)
            .padding(.vertical, 4)
            .background(Color.appSurface.opacity(0.65))
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                    .stroke(isSearchFocused ? Color.appAccent.opacity(0.55) : Color.appAccent.opacity(0.18), lineWidth: isSearchFocused ? 1.5 : 1)
            )
            .frame(minWidth: 160, idealWidth: 220)

            Spacer()

            HStack(spacing: 4) {
                Button { vm.issueScrollCommand(.top) } label: {
                    Image(systemName: "arrow.up.to.line")
                }
                .help("Go to top (⌘↑)")
                .keyboardShortcut(.upArrow, modifiers: .command)

                Button { vm.issueScrollCommand(.pageUp) } label: {
                    Image(systemName: "chevron.up")
                }
                .help("Page up (⌥↑)")
                .keyboardShortcut(.upArrow, modifiers: .option)

                Button { vm.issueScrollCommand(.pageDown) } label: {
                    Image(systemName: "chevron.down")
                }
                .help("Page down (⌥↓)")
                .keyboardShortcut(.downArrow, modifiers: .option)

                Button { vm.issueScrollCommand(.bottom) } label: {
                    Image(systemName: "arrow.down.to.line")
                }
                .help("Go to bottom (⌘↓)")
                .keyboardShortcut(.downArrow, modifiers: .command)
            }
            .buttonStyle(.plain)
            .padding(4)
            .background(Color.appSurface.opacity(0.65))
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                    .stroke(Color.appAccent.opacity(0.25), lineWidth: 1)
            )
            .disabled(vm.filteredVideos.isEmpty)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .fill(Material.appSubtleGlass)
                .background(Color.appSurface.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .stroke(Color.appAccent.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
    }

    @ViewBuilder
    private var contentBody: some View {
        Group {
            if vm.viewMode == .grid {
                LibraryGridView(
                    viewModel: vm,
                    thumbnailService: thumbService
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
                        .tint(Color.appAccent)
                        .help("Add a folder of videos to your library")

                        Button(action: { Task { await vm.importNew() } }) {
                            Label("Import New", systemImage: "arrow.down.circle")
                        }
                        .tint(Color.appAccent)
                        .disabled(vm.isScanning)
                        .help("Scan data sources for new video files")

                        Button(action: {
                            vm.surpriseMePickRandom()
                        }) {
                            Label("Surprise Me!", systemImage: "exclamationmark.circle.fill")
                        }
                        .tint(Color.appAccent)
                        .disabled(vm.filteredVideos.isEmpty)
                        .help("Random video: filmstrip in detail first, then scroll list/grid to the selection")

                        AppSegmentedControl(
                            selection: Binding(
                                get: { vm.inlinePlaybackMode },
                                set: { vm.setInlinePlaybackMode($0) }
                            ),
                            items: InlinePlaybackMode.allCases
                        ) { mode in
                            switch mode {
                            case .detailPane:
                                Label("Detail Pane", systemImage: "rectangle.righthalf.inset.filled")
                            case .overlay:
                                Label("Overlay", systemImage: "pip")
                            case .fullScreen:
                                Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                            }
                        }
                        .labelStyle(.iconOnly)
                    }
                }
                .sheet(isPresented: $showListColumnsSheet) {
                    NavigationStack {
                        Form {
                            Section {
                                ListColumnsSettingsContent(viewModel: vm)
                            } header: {
                                Text("List view columns")
                            } footer: {
                                Text("Name is always shown. Up to 16 custom columns at once (alphabetical). Reorder and resize columns using the table header.")
                            }
                        }
                        .formStyle(.grouped)
                        .navigationTitle("List columns")
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showListColumnsSheet = false }
                            }
                        }
                        .frame(minWidth: 420, minHeight: 360)
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
                .overlay {
                    if vm.videos.isEmpty && !vm.isScanning {
                        emptyStateView
                    }
                }
                .frame(minWidth: 80)
                .contextMenu {
                    Button(vm.showFilterStrip ? "Collapse Filter Strip" : "Expand Filter Strip") {
                        vm.showFilterStrip.toggle()
                    }
                }
    }

    @ViewBuilder
    private var detailContent: some View {
        Group {
            if let video = selectedVideo {
                VideoDetailView(video: video, viewModel: vm, thumbnailService: thumbService)
            } else {
                VStack(spacing: AppSpacing.lg) {
                    Image(systemName: "film")
                        .font(.system(size: 48))
                        .foregroundStyle(Color.appTextTertiary)

                    VStack(spacing: AppSpacing.xs) {
                        Text("Select a video")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(Color.appTextPrimary)
                        Text("Choose one from the library to view details and controls")
                            .font(.callout)
                            .foregroundStyle(Color.appTextSecondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(AppSpacing.xxl)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                        .fill(Material.appSubtleGlass)
                        .background(Color.appSurface.opacity(0.65))
                )
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                        .stroke(Color.appAccent.opacity(0.12), lineWidth: 1)
                )
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
        // Space key — play/pause; Shift+Space — restart from beginning
        if event.keyCode == 49 {
            if let first = NSApp.keyWindow?.firstResponder,
               first is NSTextView || first is NSTextField
            {
                return event
            }
            guard !lvm.isEditingText, !lvm.selectedVideoIds.isEmpty else { return event }
            let isShift = event.modifierFlags.contains(.shift)
            DispatchQueue.main.async {
                if isShift {
                    lvm.inlineRestartFromBeginning += 1
                } else if lvm.isPlayingInline {
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
        VStack(spacing: AppSpacing.xl) {
            Image(systemName: "film.stack")
                .font(.system(size: 56))
                .foregroundStyle(Color.appTextTertiary)

            VStack(spacing: AppSpacing.sm) {
                Text("No Videos")
                    .font(.title)
                    .foregroundStyle(Color.appTextPrimary)
                Text("Add a folder to scan for video files")
                    .foregroundStyle(Color.appTextSecondary)
            }

            Button("Add Folder") {
                vm.showFolderPicker()
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.appAccent)
            .controlSize(.large)
        }
        .padding(AppSpacing.xxl)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                .fill(Material.appSubtleGlass)
                .background(Color.appSurface.opacity(0.7))
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                .stroke(Color.appAccent.opacity(0.12), lineWidth: 1)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func statusBar(vm: LibraryViewModel) -> some View {
        let itemCount = vm.filteredVideos.count
        let selectedCount = vm.selectedVideoIds.count

        return HStack(spacing: 0) {
            Text("\(itemCount) \(itemCount == 1 ? "item" : "items")")
                .font(.caption)
                .foregroundStyle(Color.appTextSecondary)

            if selectedCount > 0 {
                Text("  ·  \(selectedCount) selected")
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
            }

            Spacer()

            if vm.isScanning && vm.scanTotal > 0 {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(Color.appAccent)
                    Text("Importing \(vm.scanCurrent)/\(vm.scanTotal)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(Color.appTextSecondary)
                    ProgressView(
                        value: Double(vm.scanCurrent),
                        total: Double(vm.scanTotal)
                    )
                    .tint(Color.appAccent)
                    .frame(width: 120)
                }
            } else if vm.isConverting {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(Color.appAccent)
                    Text(vm.conversionProgress)
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                }
            } else if vm.isMoving {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(Color.appAccent)
                    Text(vm.moveProgress)
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                }
            } else if !vm.scanProgress.isEmpty {
                Text(vm.scanProgress)
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color.appSurface.opacity(0.55))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.appDivider)
                .frame(height: 0.5)
        }
    }
}

/// Trailing floating player panel + its left-edge resize splitter. The drag updates **local** state and only
/// commits to `viewModel.overlayPlayerWidth` on release — so dragging never mutates the view model per frame
/// (which would re-render the whole content view / split view and cause flicker).
private struct OverlayPlayerPanel: View {
    let video: Video
    @Bindable var viewModel: LibraryViewModel
    let totalWidth: CGFloat

    /// Live width while dragging; `nil` when not dragging (panel uses the persisted model width).
    @State private var dragWidth: CGFloat?
    @State private var dragStartWidth: CGFloat?

    private var maxWidth: CGFloat { max(240, totalWidth - 160) }
    private var width: CGFloat { min(max(240, dragWidth ?? viewModel.overlayPlayerWidth), maxWidth) }

    var body: some View {
        HStack(spacing: 0) {
            splitter
            OverlayInlinePlayerView(video: video, viewModel: viewModel)
                .frame(width: width)
        }
        .frame(maxHeight: .infinity)
        // Intentional floating panel treatment: rich themed surface + rounded leading edge.
        // We deliberately avoid heavy shadows / full materials here because they re-rasterize
        // during live width drags and cause jitter. The visual weight comes from surface color,
        // rounded corners, and a deliberate accent splitter instead.
        .background(
            Color.appSurface
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: AppRadius.xl,
                        bottomLeadingRadius: AppRadius.xl,
                        bottomTrailingRadius: 0,
                        topTrailingRadius: 0
                    )
                )
        )
        .overlay(
            // Very subtle outer definition so the panel feels like a placed object.
            UnevenRoundedRectangle(
                topLeadingRadius: AppRadius.xl,
                bottomLeadingRadius: AppRadius.xl,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0
            )
            .stroke(Color.appAccent.opacity(0.16), lineWidth: 1)
        )
        .onChange(of: totalWidth) { _, w in
            // Persisted width can exceed a shrunken window — clamp it (infrequent, not per-frame).
            let m = max(240, w - 160)
            if viewModel.overlayPlayerWidth > m { viewModel.overlayPlayerWidth = m }
        }
    }

    private var splitter: some View {
        // Deliberate, visible grip that makes the overlay feel like an adjustable cinematic panel
        // rather than a generic divider.
        ZStack {
            // Hit area
            Rectangle()
                .fill(Color.clear)
                .frame(width: 10)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())

            // Accent-tinted separator line + subtle grip affordance
            VStack(spacing: 3) {
                Capsule()
                    .fill(Color.appAccent.opacity(0.55))
                    .frame(width: 3, height: 14)
                Capsule()
                    .fill(Color.appAccent.opacity(0.35))
                    .frame(width: 3, height: 14)
                Capsule()
                    .fill(Color.appAccent.opacity(0.55))
                    .frame(width: 3, height: 14)
            }
            .frame(width: 10)
        }
        .frame(width: 10)
        .frame(maxHeight: .infinity)
        .onHover { hovering in
            if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .gesture(
            // `.global` space: the splitter view itself moves left as the panel widens, so a `.local`
            // translation is measured against a moving origin — the divider drifts from the cursor and
            // oscillates (jitter). Global space gives a true, stable mouse delta.
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStartWidth ?? viewModel.overlayPlayerWidth
                    if dragStartWidth == nil { dragStartWidth = start }
                    // translation is cumulative from drag start; drag left → wider player.
                    dragWidth = min(max(240, start - value.translation.width), maxWidth)
                }
                .onEnded { _ in
                    if let w = dragWidth { viewModel.overlayPlayerWidth = w }  // single commit + persist
                    dragWidth = nil
                    dragStartWidth = nil
                }
        )
    }
}
