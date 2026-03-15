import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        let vm = appState.libraryViewModel
        let thumbService = appState.thumbnailService

        @Bindable var bindableVM = vm

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

                    Picker("View Mode", selection: Binding(
                        get: { vm.viewMode },
                        set: { vm.viewMode = $0; vm.savePreferences() }
                    )) {
                        Label("Grid", systemImage: "square.grid.2x2")
                            .tag(ViewMode.grid)
                        Label("List", systemImage: "list.bullet")
                            .tag(ViewMode.list)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 80)

                    SortMenuButton(viewModel: vm)
                }
            }
            .searchable(text: $bindableVM.searchText, prompt: "Search videos")
            .overlay {
                if vm.videos.isEmpty && !vm.isScanning {
                    emptyStateView
                }
            }
            .overlay(alignment: .bottom) {
                if vm.isScanning {
                    scanProgressView
                }
            }
        } detail: {
            if let selectedId = vm.selectedVideoIds.first,
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
        .task {
            vm.startObserving()
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

    private var scanProgressView: some View {
        let vm = appState.libraryViewModel
        return HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text(vm.scanProgress)
                .font(.caption)
                .lineLimit(1)
            if vm.scanTotal > 0 {
                ProgressView(
                    value: Double(vm.scanCurrent),
                    total: Double(vm.scanTotal)
                )
                .frame(width: 120)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(.bottom, 16)
    }
}
