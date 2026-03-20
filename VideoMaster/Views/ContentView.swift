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
    let vm: LibraryViewModel
    let thumbService: ThumbnailService
    /// Persists across content host rootView replacements (playback/browsing switch, layout changes).
    @State private var gridScrollPositionId: String?
    @State private var listScrollPositionRow: Int?

    private var navigationTitle: String {
        let name = DatabaseExportImport.activeLibraryDisplayName
        if name.isEmpty || name == "VideoMaster" { return "VideoMaster" }
        return "VideoMaster — \(name)"
    }

    private var sidebarID: String {
        "\(vm.sidebarFilter.hashValue)-\(vm.isLibraryExpanded)-\(vm.isCollectionsExpanded)-\(vm.isRatingExpanded)-\(vm.isTagsExpanded)-\(vm.collections.count)-\(vm.tags.count)-\(vm.libraryCounts.all)-\(vm.showRecentlyAdded)-\(vm.showRecentlyPlayed)-\(vm.showTopRated)-\(vm.showDuplicates)-\(vm.showCorrupt)-\(vm.showMissing)"
    }

    private var detailID: String {
        vm.lastSelectedVideoId ?? ""
    }

    /// Column targets for the split view always follow browsing layout so toggling playback
    /// does not change effective widths (avoids a layout pulse / grid jump before freeze).
    private var browsingSplitSidebarWidth: CGFloat { CGFloat(vm.browsingLayout.sidebarWidth) }
    private var browsingSplitContentWidth: CGFloat { CGFloat(vm.browsingLayout.contentWidth) }
    private var browsingSplitDetailWidth: CGFloat { CGFloat(vm.browsingLayout.detailWidth) }

    var body: some View {
        VStack(spacing: 0) {
            ResizableSplitView(
                sidebarWidth: browsingSplitSidebarWidth,
                contentWidth: browsingSplitContentWidth,
                detailWidth: browsingSplitDetailWidth,
                sidebarID: sidebarID,
                // Include filteredVideosVersion so toolbar/search state updates when the list loads or filters change.
                // (NSHostingView rootView is only replaced when contentID changes; see ResizableSplitView.)
                contentID: "\(vm.viewMode.rawValue)-\(vm.videos.isEmpty)-\(vm.filteredVideosVersion)",
                detailID: detailID,
                freezeContent: vm.isPlayingInline,
                onSizesChanged: { s, c, d in
                    vm.updateCurrentLayoutWithSizes(sidebarWidth: s, contentWidth: c, detailWidth: d)
                },
                sidebar: { SidebarView(viewModel: vm).frame(minWidth: 120) },
                content: { libraryContent },
                detail: { detailContent }
            )
            .navigationTitle(navigationTitle)

            statusBar(vm: vm)
        }
        .task { vm.startObserving() }
        .onAppear { installKeyMonitor(vm: vm) }
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
                            Label("Grid", systemImage: "square.grid.2x2")
                                .tag(ViewMode.grid)
                            Label("List", systemImage: "list.bullet")
                                .tag(ViewMode.list)
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

    private func installKeyMonitor(vm: LibraryViewModel) {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let lvm = vm
                // Enter key (without modifiers) — start inline rename in list or grid mode
                if event.keyCode == 36, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [], !lvm.isEditingText {
                    if (lvm.viewMode == .list || lvm.viewMode == .grid),
                       lvm.selectedVideoIds.count == 1,
                       let videoId = lvm.selectedVideoIds.first,
                       let video = lvm.filteredVideos.first(where: { $0.id == videoId })
                    {
                        Task { @MainActor in
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
                        Task { @MainActor in
                            lvm.renamingTagId = nil
                            lvm.tagRenameText = ""
                            lvm.isEditingText = false
                        }
                        return nil
                    }
                    if lvm.renamingVideoId != nil {
                        Task { @MainActor in
                            lvm.renamingVideoId = nil
                            lvm.renameText = ""
                        }
                        return nil
                    }
                    if lvm.isPlayingInline {
                        Task { @MainActor in
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
                    Task { @MainActor in
                        if lvm.isPlayingInline {
                            lvm.inlinePlayPauseToggle += 1
                        } else {
                            lvm.isPlayingInline = true
                        }
                    }
                    return nil
                }
                return event
            }
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

