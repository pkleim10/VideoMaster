import SwiftUI
import AppKit

struct ScrollbarEnabler: NSViewRepresentable {
    class Coordinator {
        weak var scrollView: NSScrollView?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard let sv = Self.findScrollView(from: view) else { return }
            context.coordinator.scrollView = sv
            Self.applyScrollerPolicy(sv)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let sv = context.coordinator.scrollView {
            Self.applyScrollerPolicy(sv)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.scrollView = nil
    }

    private static func findScrollView(from view: NSView) -> NSScrollView? {
        var current: NSView? = view
        while let v = current {
            if let sv = v as? NSScrollView { return sv }
            current = v.superview
        }
        return nil
    }

    /// Sets scroller visibility only. **Do not** call `flashScrollers()` here — on large `LazyVGrid`
    /// documents it forces layout and was making wheel/track scrolling multi‑second hitchy.
    private static func applyScrollerPolicy(_ sv: NSScrollView) {
        sv.hasVerticalScroller = true
        sv.scrollerStyle = .overlay
        sv.verticalScroller?.alphaValue = 1.0
        sv.verticalScroller?.isHidden = false
        if let clipView = sv.contentView as? NSClipView {
            clipView.postsBoundsChangedNotifications = true
        }
    }
}

struct LibraryGridView: View {
    @Bindable var viewModel: LibraryViewModel
    let thumbnailService: ThumbnailService
    @Binding var scrollPositionId: String?
    /// Anchor for shift‑range selection (id avoids `ForEach(Array(enumerated()))` on 10k+ libraries).
    @State private var lastClickedVideoId: String?
    @State private var filmstripVideo: Video?
    @FocusState private var isRenameFocused: Bool
    /// So ↑/↓ go through SwiftUI’s key pipeline (same as list `Table`) instead of AppKit’s scroll view only.
    @FocusState private var gridArrowKeyFocused: Bool

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
                            ForEach(viewModel.filteredVideos) { video in
                                let renamingRow = viewModel.renamingVideoId == video.id
                                VideoGridCell(
                                    video: video,
                                    isSelected: viewModel.selectedVideoIds.contains(video.id),
                                    isRenaming: renamingRow,
                                    renameText: renamingRow ? $viewModel.renameText : .constant(""),
                                    gridSize: viewModel.gridSize,
                                    videoRepo: viewModel.videoRepo,
                                    thumbnailService: thumbnailService,
                                    renameFocus: $isRenameFocused,
                                    onCommitRename: { commitRename(video) },
                                    onCancelRename: cancelRename,
                                    onRenameEditingChanged: { viewModel.isEditingText = $0 }
                                )
                                .background(Color.clear.id(video.id))
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) {
                                    playVideo(video)
                                }
                                .onTapGesture {
                                    handleClick(video: video)
                                }
                                .contextMenu {
                                    videoContextMenu(video)
                                }
                            }
                        }
                        .padding(padding)
                        .scrollTargetLayout()
                        .background(ScrollbarEnabler())
                    }
                    .scrollPosition(id: $scrollPositionId, anchor: .center)
                    .onChange(of: viewModel.scrollToVideoId, initial: true) { _, targetId in
                        guard let id = targetId else { return }
                        viewModel.scrollToVideoId = nil
                        guard viewModel.filteredVideos.contains(where: { $0.id == id }) else { return }
                        // Defer so detail/playback stay responsive; `scrollTo` matches real layout (unlike AppKit estimates).
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(120))
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
        }
        .id(viewModel.filteredVideosVersion)
        .focusable()
        .focused($gridArrowKeyFocused)
        .onKeyPress(.upArrow) {
            guard !viewModel.isEditingText else { return .ignored }
            viewModel.navigateFilteredVideoStep(-1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard !viewModel.isEditingText else { return .ignored }
            viewModel.navigateFilteredVideoStep(1)
            return .handled
        }
        .onAppear {
            if viewModel.scrollToSelectedOnViewSwitch, let id = viewModel.selectedVideoIds.first {
                viewModel.scrollToSelectedOnViewSwitch = false
                scrollPositionId = id
            }
            // Become key target after layout so arrow keys aren’t only handled by NSScrollView.
            DispatchQueue.main.async {
                gridArrowKeyFocused = true
            }
        }
        .onChange(of: viewModel.renamingVideoId) { _, id in
            if id != nil {
                gridArrowKeyFocused = false
                DispatchQueue.main.async {
                    isRenameFocused = true
                }
            } else {
                DispatchQueue.main.async {
                    gridArrowKeyFocused = true
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
            "Delete \(viewModel.pendingDeleteIds.count == 1 ? "Video" : "\(viewModel.pendingDeleteIds.count) Videos")",
            isPresented: $viewModel.showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                let ids = viewModel.pendingDeleteIds
                viewModel.pendingDeleteIds = []
                Task { await viewModel.deleteVideos(ids) }
            }
            Button("Cancel", role: .cancel) {
                viewModel.pendingDeleteIds = []
            }
        } message: {
            if viewModel.pendingDeleteIds.count == 1 {
                Text("The file will be moved to Trash.")
            } else {
                Text("\(viewModel.pendingDeleteIds.count) files will be moved to Trash.")
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

    private func handleClick(video: Video) {
        gridArrowKeyFocused = true
        let flags = NSEvent.modifierFlags
        let videos = viewModel.filteredVideos
        if flags.contains(.command) {
            if viewModel.selectedVideoIds.contains(video.id) {
                viewModel.selectedVideoIds.remove(video.id)
            } else {
                viewModel.selectedVideoIds.insert(video.id)
            }
            lastClickedVideoId = video.id
        } else if flags.contains(.shift),
                  let anchorId = lastClickedVideoId,
                  let anchorIdx = videos.firstIndex(where: { $0.id == anchorId }),
                  let idx = videos.firstIndex(where: { $0.id == video.id })
        {
            let range = min(anchorIdx, idx)...max(anchorIdx, idx)
            let ids = range.map { videos[$0].id }
            viewModel.selectedVideoIds = Set(ids)
        } else {
            viewModel.selectedVideoIds = [video.id]
            lastClickedVideoId = video.id
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
            _ = await viewModel.renameVideo(video, to: newName)
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
        Button("Play in External Player") { playVideo(video) }
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
        Button("Rename") {
            viewModel.renameText = video.fileName
            viewModel.renamingVideoId = video.id
        }
        Divider()
        Button("Modify Filmstrip\u{2026}") {
            filmstripVideo = video
        }
        Divider()
        Button("Remove from Library") {
            Task { await viewModel.removeVideosFromLibrary([video.id]) }
        }
        Button("Delete Video…", role: .destructive) {
            let ids: Set<String> = [video.id]
            if viewModel.confirmDeletions {
                viewModel.pendingDeleteIds = ids
                viewModel.showDeleteConfirmation = true
            } else {
                Task { await viewModel.deleteVideos(ids) }
            }
        }
    }
}

/// P2: no `@Bindable LibraryViewModel` — avoids fan-out invalidation across thousands of cells when
/// unrelated VM properties change (toolbar, scan progress, detail, etc.).
struct VideoGridCell: View {
    let video: Video
    let isSelected: Bool
    let isRenaming: Bool
    @Binding var renameText: String
    let gridSize: GridSize
    let videoRepo: VideoRepository
    let thumbnailService: ThumbnailService
    var renameFocus: FocusState<Bool>.Binding
    var onCommitRename: () -> Void
    var onCancelRename: () -> Void
    var onRenameEditingChanged: (Bool) -> Void
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
                if isRenaming {
                    TextField("", text: $renameText)
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
                            onRenameEditingChanged(true)
                        }
                        .onDisappear {
                            onRenameEditingChanged(false)
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
        if let cached = thumbnailService.loadThumbnail(for: video.filePath) {
            thumbnail = cached
            return
        }
        do {
            let url = try await thumbnailService.generateThumbnail(for: video)
            thumbnail = NSImage(contentsOf: url)
            if let dbId = video.databaseId {
                let repo = videoRepo
                let path = url.path
                Task {
                    try? await repo.updateThumbnailPath(videoId: dbId, path: path)
                }
            }
        } catch {
            // Thumbnail generation failed; placeholder stays
        }
    }
}
