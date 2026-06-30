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
    @State private var fullScreenController: FullscreenInlinePlayerWindowController?
    @State private var showListColumnsSheet = false
    @FocusState private var isSearchFocused: Bool

    /// Local presentation flag for the filters drawer (discrete).
    @State private var isFiltersDrawerOpen = false

    /// Interpolated 0...1 value that drives smooth height/offset animations for the drawer well.
    /// Using a CGFloat animated via withAnimation gives the view modifiers interpolated values
    /// each frame, so the drawer grows its height gradually instead of appearing full-size instantly,
    /// and the grid/list below is pushed at a matching rate.
    @State private var drawerReveal: CGFloat = 0

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

    /// Duration for the Curated Wall top filters drawer slide animation (open and close).
    /// A deliberate, visible slide — was previously too fast at 0.22s.
    private static let drawerAnimationDuration: Double = 0.38

    /// Reusable styled search field (cinematic blue focus ring, clear affordance).
    /// Used both in the regular nav bar and inline in the Curated Wall thin header.
    private var searchField: some View {
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
    }

    /// Thin header bar for Curated Wall: List/Wall toggle + inline search + count + Filters toggle.
    /// Matches the layout in the wireframe mock (search is inline in the same row as the mode selector and filter button).
    /// The same button opens *and* closes the top drawer. Icon and help update with state.
    private var curatedHeaderBar: some View {
        HStack(spacing: 8) {
            AppSegmentedControl(
                selection: Binding(
                    get: { vm.viewMode },
                    set: { newValue in
                        vm.viewMode = newValue
                        vm.savePreferences()
                    }
                ),
                items: [ViewMode.list, .grid]
            ) { mode in
                switch mode {
                case .list: Label("List", systemImage: "list.bullet")
                case .grid: Label("Wall", systemImage: "square.grid.2x2")
                }
            }
            .controlSize(.small)

            // Search is placed inline here (after the mode picker, before right-aligned actions)
            // to match the Curated Wall wireframe mockup.
            searchField

            Spacer()

            // Video count (light)
            Text("\(vm.filteredVideos.count) videos")
                .font(.system(size: 10))
                .foregroundStyle(Color.appTextTertiary)
                .monospacedDigit()
                .padding(.trailing, 4)

            // The single toggle for the top filters drawer.
            // Closed -> filter icon; Open -> close (X) icon. Always live filters, no Apply step.
            Button {
                // Just flip the model flag. The .onChange below will drive the slide animation
                // (offset + height) with the proper duration and a clean transaction.
                vm.isCuratedWallFiltersDrawerOpen.toggle()
            } label: {
                if vm.isCuratedWallFiltersDrawerOpen {
                    Image(systemName: "xmark.circle")
                } else {
                    Image(systemName: vm.hasActiveFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.appTextSecondary)
            .help(vm.isCuratedWallFiltersDrawerOpen
                  ? "Close filters (⌘⇧F)"
                  : "Show filters (⌘⇧F)")
            .keyboardShortcut("f", modifiers: [.command, .shift])
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(Color.appSurface.opacity(0.35))
    }

    /// The full browsing surface for the Curated Wall: header bar + optional top drawer + optional active pills + grid/list.
    /// Replaces the previous vertical split + bottom filter strip for this variant.
    private var wallBrowserPane: some View {
        VStack(spacing: 0) {
            curatedHeaderBar

            // Drawer well — the expanding slot directly under the thin header.
            // Goal: a clean, "wow" slide where the filter panel drops down from under the header
            // while smoothly pushing the grid/list below. No full pane flash, no "appears then pushes".
            //
            // How:
            // - The drawer is *always* laid out at its full height (stable layout, no mid-animation reflow of its sections/grids).
            // - We slide it into view with a changing offset: starts fully above the well, moves downward as the well opens.
            // - The well's own height grows from 0→320; because it's in the VStack, this reserves space and pushes the wall content down in lockstep.
            // - `.clipped()` hides the portion that is still "above" the visible well rect.
            // - Everything is driven from the single interpolated `drawerReveal` (0...1) so the visual slide and the layout push are perfectly synchronized.
            let reveal = drawerReveal
            let fullH: CGFloat = 320
            let shownH = fullH * reveal

            ZStack(alignment: .top) {
                CuratedWallFiltersDrawer(viewModel: vm)
                    .frame(height: fullH, alignment: .top)   // full layout (no squish/reflow)
                    .offset(y: shownH - fullH)               // -fullH (above, hidden) → 0 (fully visible in well)
                    .opacity(reveal)
            }
            .frame(height: shownH, alignment: .top)
            .clipped()
            .zIndex(1)   // ensure the sliding drawer draws above the grid/list during the push (prevents any "behind" flash)
            .animation(.easeInOut(duration: Self.drawerAnimationDuration), value: reveal)

            // Pills live in their own slot and only when the drawer is fully closed.
            // Use reveal so pills don't pop in while the drawer is still sliding away.
            if reveal < 0.001 && vm.hasActiveFilters {
                ActiveFilterPills(viewModel: vm)
                    .transition(.opacity)
            }

            if vm.viewMode == .grid {
                CuratedWallGrid(viewModel: vm, thumbnailService: thumbService)
            } else {
                LibraryListView(
                    viewModel: vm,
                    thumbnailService: thumbService,
                    scrollPositionRow: $listScrollPositionRow
                )
            }
        }
        // Animate the pane layout (grid/list position) in response to the reveal factor.
        // This makes the wall content rise/fall smoothly as the well above it changes height.
        .animation(.easeInOut(duration: Self.drawerAnimationDuration), value: drawerReveal)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Curated Wall layout (bold dedicated implementation)
            // Left: elegant gallery "Wall"  |  Right: focused Inspector
            // Matches the refined mockups as closely as we can get.
            ResizableBrowserDetailSplitView(
                layoutModeKey: vm.viewMode.rawValue,
                contentWidth: browsingSplitContentWidth,
                detailWidth: browsingSplitDetailWidth,
                contentID: "curatedWall",
                detailID: detailID,
                // Playback no longer reshapes the browser, so the wall never needs freezing during play.
                freezeContent: false,
                onSizesChanged: { browserW, detailW in
                    vm.updateCurrentLayoutWithSizes(sidebarWidth: nil, contentWidth: browserW, detailWidth: detailW)
                },
                content: {
                    // Curated Wall uses a top-descending live filters drawer instead of a persistent bottom strip.
                    // Drawer always starts closed; toggle via button or ⌘⇧F. Changes are live.
                    wallBrowserPane
                },
                detail: {
                    CuratedWallInspector(video: selectedVideo, viewModel: vm, thumbnailService: thumbService)
                }
            )
            .overlay {
                // The single resizable player: one surface anchored top-right, shown whenever
                // playback is active. Hidden while in true full-screen (the borderless window hosts
                // the same player instead). Floats above the wall/inspector (no freeze/resize).
                if vm.isPlayingInline, !vm.isPlayerFullScreen, let video = selectedVideo {
                    GeometryReader { geo in
                        FloatingPlayerPanel(video: video, viewModel: vm, available: geo.size)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    }
                }
            }
            .navigationTitle(navigationTitle)
            // Drive the shared player lifecycle from state, not from any view's appear/disappear, so
            // the panel can hide for full-screen without tearing down the player.
            .onChange(of: vm.isPlayingInline) { _, isOn in
                if isOn {
                    guard let v = selectedVideo else { vm.isPlayingInline = false; return }
                    let seek = vm.pendingFilmstripSeekSeconds ?? 0
                    vm.pendingFilmstripSeekSeconds = nil
                    vm.playback.start(video: v, at: seek)
                    // Apply the starting-size preference. `.lastSize` keeps the persisted size as-is;
                    // `.compact` is applied by the panel on appear (it knows the inspector footprint).
                    switch vm.playerStartPreference {
                    case .fullScreen: vm.isPlayerFullScreen = true
                    case .compact: vm.pendingApplyCompactSize = true
                    case .lastSize: break
                    }
                } else {
                    vm.isPlayerFullScreen = false
                    vm.playback.stop()
                }
            }
            // Enter/leave true full-screen by moving the *same* player into a borderless window.
            .onChange(of: vm.isPlayerFullScreen) { _, isFS in
                if isFS {
                    guard let player = vm.playback.player else { vm.isPlayerFullScreen = false; return }
                    let controller = FullscreenInlinePlayerWindowController()
                    fullScreenController = controller
                    controller.present(
                        player: player,
                        title: selectedVideo?.fileName ?? "",
                        startWindowInFullscreen: true,
                        subtitleTrack: vm.playback.subtitleTrack
                    ) {
                        vm.isPlayerFullScreen = false
                    }
                } else {
                    fullScreenController?.closeWindow()
                    fullScreenController = nil
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                vm.playback.persistPosition()
            }

            // Hidden for Curated Wall to keep the gallery + inspector clean (per mock aesthetic)
            // statusBar(vm: vm)
        }
        .task {
            vm.startObserving()
            // Curated Wall: always start with the top filters drawer closed (per spec).
            // Drawer state is intentionally not persisted. Set both directly (no animation on init).
            vm.isCuratedWallFiltersDrawerOpen = false
            isFiltersDrawerOpen = false
            drawerReveal = 0
        }
        .onChange(of: vm.isCuratedWallFiltersDrawerOpen) { _, newValue in
            // Animate the reveal factor. The well and drawer heights are driven from this CGFloat,
            // so we get smooth per-frame interpolated sizes instead of a full-height pop followed by a push.
            withAnimation(.easeInOut(duration: Self.drawerAnimationDuration)) {
                isFiltersDrawerOpen = newValue
                drawerReveal = newValue ? 1 : 0
            }
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

            // Reusable search (styled once, used here and inline in the Curated Wall header)
            searchField

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
                    Button(vm.isCuratedWallFiltersDrawerOpen ? "Close Filters" : "Open Filters") {
                        // Model flip only; .onChange drives the animated slide.
                        vm.isCuratedWallFiltersDrawerOpen.toggle()
                    }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
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
        // Space — play/pause (or start playback). Restart-from-beginning is the ⌘⌥R menu command
        // (Shift+Space proved unreliable: the Shift modifier doesn't reach this handler on Space).
        if event.keyCode == 49 {
            // A focused text field (e.g. Notes) wins so a space can be typed.
            if let first = NSApp.keyWindow?.firstResponder,
               first is NSTextView || first is NSTextField
            {
                return event
            }
            guard !lvm.isEditingText else { return event }
            if lvm.isPlayingInline {
                DispatchQueue.main.async { lvm.playback.togglePlayPause() }
                return nil
            }
            guard !lvm.selectedVideoIds.isEmpty else { return event }
            DispatchQueue.main.async { lvm.isPlayingInline = true }
            return nil
        }

        // ⌘⇧F — toggle the Curated Wall top filters drawer (live filters, always starts closed).
        // This is a fallback in addition to the .keyboardShortcut on the button.
        if event.modifierFlags.contains([.command, .shift]), event.keyCode == 3 /* 'f' */ {
            // Just set the flag; the onChange handler will start the slide animation with the right duration.
            DispatchQueue.main.async {
                lvm.isCuratedWallFiltersDrawerOpen.toggle()
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
