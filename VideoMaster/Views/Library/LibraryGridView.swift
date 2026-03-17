import SwiftUI
import AppKit

struct ScrollbarEnabler: NSViewRepresentable {
    class Coordinator {
        var timer: Timer?
        weak var scrollView: NSScrollView?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard let sv = Self.findScrollView(from: view) else { return }
            context.coordinator.scrollView = sv
            Self.configureScroller(sv)
            context.coordinator.timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                if let sv = context.coordinator.scrollView {
                    Self.configureScroller(sv)
                }
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let sv = context.coordinator.scrollView {
            Self.configureScroller(sv)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.timer?.invalidate()
        coordinator.timer = nil
    }

    private static func findScrollView(from view: NSView) -> NSScrollView? {
        var current: NSView? = view
        while let v = current {
            if let sv = v as? NSScrollView { return sv }
            current = v.superview
        }
        return nil
    }

    private static func configureScroller(_ sv: NSScrollView) {
        sv.hasVerticalScroller = true
        sv.scrollerStyle = .overlay
        sv.verticalScroller?.alphaValue = 1.0
        sv.verticalScroller?.isHidden = false
        if let clipView = sv.contentView as? NSClipView {
            clipView.postsBoundsChangedNotifications = true
        }
        sv.flashScrollers()
    }
}

struct LibraryGridView: View {
    @Bindable var viewModel: LibraryViewModel
    let thumbnailService: ThumbnailService
    @State private var lastClickedIndex: Int?
    @State private var pendingDeleteIds: Set<String> = []
    @State private var showDeleteConfirmation = false
    @State private var filmstripVideo: Video?
    @FocusState private var isRenameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            gridSizeBar

            GeometryReader { geo in
                let padding: CGFloat = 16
                let availableWidth = geo.size.width - padding * 2
                let cols = viewModel.gridSize.columns(for: availableWidth)

                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVGrid(columns: cols, spacing: viewModel.gridSize.gridSpacing) {
                            ForEach(Array(viewModel.filteredVideos.enumerated()), id: \.element.id) { index, video in
                                VideoGridCell(
                                    video: video,
                                    isSelected: viewModel.selectedVideoIds.contains(video.id),
                                    gridSize: viewModel.gridSize,
                                    viewModel: viewModel,
                                    thumbnailService: thumbnailService,
                                    renameFocus: $isRenameFocused,
                                    onCommitRename: { commitRename(video) },
                                    onCancelRename: cancelRename
                                )
                                .background(Color.clear.id(video.id))
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) {
                                    playVideo(video)
                                }
                                .onTapGesture {
                                    handleClick(video: video, index: index)
                                }
                                .contextMenu {
                                    videoContextMenu(video)
                                }
                            }
                        }
                        .padding(padding)
                        .background(ScrollbarEnabler())
                    }
                    .onChange(of: viewModel.scrollToVideoId) { _, targetId in
                        guard let id = targetId else { return }
                        viewModel.scrollToVideoId = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
        }
        .id(viewModel.filteredVideosVersion)
        .onAppear {
            if viewModel.scrollToSelectedOnViewSwitch, let id = viewModel.selectedVideoIds.first {
                viewModel.scrollToSelectedOnViewSwitch = false
                viewModel.scrollToVideoId = id
            }
        }
        .onChange(of: viewModel.renamingVideoId) { _, _ in
            if viewModel.renamingVideoId != nil {
                DispatchQueue.main.async {
                    isRenameFocused = true
                }
            }
        }
        .sheet(item: $filmstripVideo) { video in
            FilmstripConfigView(
                video: video,
                thumbnailService: thumbnailService,
                defaultRows: viewModel.defaultFilmstripRows,
                defaultColumns: viewModel.defaultFilmstripColumns
            ) { _ in
                viewModel.filmstripRefreshId &+= 1
            }
        }
        .confirmationDialog(
            "Delete \(pendingDeleteIds.count == 1 ? "Video" : "\(pendingDeleteIds.count) Videos")",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                let ids = pendingDeleteIds
                pendingDeleteIds = []
                Task { await viewModel.deleteVideos(ids) }
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteIds = []
            }
        } message: {
            if pendingDeleteIds.count == 1 {
                Text("This will permanently delete the file from disk. This action cannot be undone.")
            } else {
                Text("This will permanently delete \(pendingDeleteIds.count) files from disk. This action cannot be undone.")
            }
        }
    }

    private var gridSizeBar: some View {
        HStack {
            Spacer()
            Picker("", selection: $viewModel.gridSize) {
                ForEach(GridSize.allCases, id: \.self) { size in
                    Text(size.label).tag(size)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 100)
            .onChange(of: viewModel.gridSize) {
                viewModel.savePreferences()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func handleClick(video: Video, index: Int) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if viewModel.selectedVideoIds.contains(video.id) {
                viewModel.selectedVideoIds.remove(video.id)
            } else {
                viewModel.selectedVideoIds.insert(video.id)
            }
            lastClickedIndex = index
        } else if flags.contains(.shift), let anchor = lastClickedIndex {
            let range = min(anchor, index)...max(anchor, index)
            let ids = range.map { viewModel.filteredVideos[$0].id }
            viewModel.selectedVideoIds = Set(ids)
        } else {
            viewModel.selectedVideoIds = [video.id]
            lastClickedIndex = index
        }
    }

    private func commitRename(_ video: Video) {
        let newName = viewModel.renameText.trimmingCharacters(in: .whitespaces)
        viewModel.renamingVideoId = nil
        guard !newName.isEmpty, newName != video.fileName else {
            viewModel.renameText = ""
            return
        }
        Task {
            if let newPath = await viewModel.renameVideo(video, to: newName),
               viewModel.isSortedByName
            {
                viewModel.scrollToVideoId = newPath
            }
            viewModel.renameText = ""
        }
    }

    private func cancelRename() {
        viewModel.renamingVideoId = nil
        viewModel.renameText = ""
    }

    private func playVideo(_ video: Video) {
        NSWorkspace.shared.open(video.url)
        Task {
            await viewModel.recordPlay(for: video)
        }
    }

    @ViewBuilder
    private func videoContextMenu(_ video: Video) -> some View {
        Button("Play") { playVideo(video) }
        Button("Show in Finder") {
            NSWorkspace.shared.selectFile(video.filePath, inFileViewerRootedAtPath: "")
        }
        Menu("Open With") {
            let appURLs = NSWorkspace.shared.urlsForApplications(toOpen: video.url)
            ForEach(appURLs, id: \.self) { appURL in
                Button(appURL.deletingPathExtension().lastPathComponent) {
                    NSWorkspace.shared.open(
                        [video.url],
                        withApplicationAt: appURL,
                        configuration: NSWorkspace.OpenConfiguration()
                    )
                    Task { await viewModel.recordPlay(for: video) }
                }
            }
        }
        Divider()
        Button("Modify Filmstrip...") {
            filmstripVideo = video
        }
        Divider()
        Button("Remove from Library") {
            Task { await viewModel.removeVideosFromLibrary([video.id]) }
        }
        Button("Delete Video…", role: .destructive) {
            let ids: Set<String> = [video.id]
            if viewModel.confirmDeletions {
                pendingDeleteIds = ids
                showDeleteConfirmation = true
            } else {
                Task { await viewModel.deleteVideos(ids) }
            }
        }
    }
}

struct VideoGridCell: View {
    let video: Video
    let isSelected: Bool
    let gridSize: GridSize
    @Bindable var viewModel: LibraryViewModel
    let thumbnailService: ThumbnailService
    var renameFocus: FocusState<Bool>.Binding
    var onCommitRename: () -> Void
    var onCancelRename: () -> Void
    @State private var thumbnail: NSImage?
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: gridSize == .small ? 4 : 8) {
            ZStack(alignment: .bottomTrailing) {
                Color.clear
                    .frame(height: gridSize.thumbnailHeight)
                    .overlay {
                        thumbnailImage
                    }
                    .clipShape(RoundedRectangle(cornerRadius: gridSize == .small ? 4 : 8))

                if let duration = video.formattedDuration {
                    Text(duration)
                        .font(gridSize == .small ? .system(size: 9) : .caption2)
                        .fontWeight(.medium)
                        .monospacedDigit()
                        .padding(.horizontal, gridSize == .small ? 3 : 6)
                        .padding(.vertical, gridSize == .small ? 1 : 2)
                        .background(.black.opacity(0.75))
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .padding(gridSize == .small ? 3 : 6)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                if viewModel.renamingVideoId == video.id {
                    TextField("", text: $viewModel.renameText)
                        .textFieldStyle(.plain)
                        .font(gridSize == .small ? .system(size: 10) : .caption)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color(nsColor: .textBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(Color.accentColor, lineWidth: 2)
                        )
                        .focused(renameFocus)
                        .onSubmit { onCommitRename() }
                        .onExitCommand { onCancelRename() }
                        .onAppear {
                            viewModel.isEditingText = true
                        }
                        .onDisappear {
                            viewModel.isEditingText = false
                        }
                } else {
                    Text(video.fileName)
                        .font(gridSize == .small ? .system(size: 10) : .caption)
                        .fontWeight(.medium)
                        .lineLimit(gridSize == .small ? 1 : 2)
                }

                if gridSize != .small {
                    HStack(spacing: 6) {
                        if let res = video.resolutionLabel {
                            Text(res)
                                .font(.caption2)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.15))
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                        Text(video.formattedFileSize)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if video.rating > 0 {
                            HStack(spacing: 1) {
                                ForEach(0..<video.rating, id: \.self) { _ in
                                    Image(systemName: "star.fill")
                                        .font(.system(size: 8))
                                        .foregroundColor(.yellow)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(gridSize == .small ? 4 : 8)
        .background(
            RoundedRectangle(cornerRadius: gridSize == .small ? 6 : 10)
                .fill(
                    isSelected
                        ? Color.accentColor.opacity(0.2)
                        : (isHovering ? Color.primary.opacity(0.04) : Color.clear)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: gridSize == .small ? 6 : 10)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .onHover { hovering in
            isHovering = hovering
        }
        .task(id: video.filePath) {
            await loadThumbnail()
        }
    }

    @ViewBuilder
    private var thumbnailImage: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Rectangle()
                .fill(Color.secondary.opacity(0.1))
                .overlay {
                    Image(systemName: "film")
                        .font(gridSize == .small ? .caption : .title2)
                        .foregroundStyle(.secondary)
                }
        }
    }

    private func loadThumbnail() async {
        if let cached = await thumbnailService.loadThumbnail(for: video.filePath) {
            thumbnail = cached
            return
        }
        do {
            let url = try await thumbnailService.generateThumbnail(for: video)
            thumbnail = NSImage(contentsOf: url)
            if let dbId = video.databaseId {
                try? await viewModel.videoRepo.updateThumbnailPath(
                    videoId: dbId, path: url.path
                )
            }
        } catch {
            // Thumbnail generation failed; placeholder stays
        }
    }
}
