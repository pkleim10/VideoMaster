import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        let vm = appState.libraryViewModel
        let thumbService = appState.thumbnailService

        @Bindable var bindableVM = vm

        VStack(spacing: 0) {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                SidebarView(viewModel: vm)
            } content: {
                Group {
                    if vm.viewMode == .grid {
                        LibraryGridView(viewModel: vm, thumbnailService: thumbService)
                    } else {
                        LibraryListView(viewModel: vm, thumbnailService: thumbService)
                    }
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
                            guard let random = vm.filteredVideos.randomElement() else { return }
                            vm.selectedVideoIds = [random.id]
                            vm.lastSelectedVideoId = random.id
                            vm.scrollToVideoId = random.id
                            vm.pendingAutoPlay = true
                        }) {
                            Label("Surprise Me!", systemImage: "exclamationmark.circle.fill")
                        }
                        .disabled(vm.filteredVideos.isEmpty)
                        .help("Play a random video from the current list")

                        SortMenuButton(viewModel: vm)
                    }
                }
                .searchable(text: $bindableVM.searchText, prompt: "Search videos")
                .overlay {
                    if vm.videos.isEmpty && !vm.isScanning {
                        emptyStateView
                    }
                }
            } detail: {
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
            .navigationSplitViewStyle(.balanced)

            statusBar
        }
        .task {
            vm.startObserving()
        }
        .onAppear {
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let lvm = appState.libraryViewModel
                // Enter key — start inline rename in list or grid mode
                if event.keyCode == 36, !lvm.isEditingText {
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
                // Space key — play/pause
                if event.keyCode == 49 {
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
                appState.libraryViewModel.showFolderPicker()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusBar: some View {
        let vm = appState.libraryViewModel
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
