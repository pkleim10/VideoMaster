import AVKit
import SwiftUI

struct VideoDetailView: View {
    let video: Video
    let viewModel: LibraryViewModel
    let thumbnailService: ThumbnailService
    @State private var tags: [Tag] = []
    @State private var newTagName: String = ""
    @State private var isCreatingTag = false
    @State private var thumbnail: NSImage?
    @State private var isEditingName = false
    @State private var editedName: String = ""
    @State private var inlinePlayer: AVPlayer?
    private static let defaultDetailHeight: CGFloat = 330
    @State private var detailHeight: CGFloat = VideoDetailView.defaultDetailHeight

    var body: some View {
        GeometryReader { geo in
            let totalHeight = geo.size.height
            let handleHeight: CGFloat = 8
            let clampedDetailHeight = min(max(100, detailHeight), totalHeight - 100 - handleHeight)
            let thumbnailHeight = max(100, totalHeight - clampedDetailHeight - handleHeight)

            VStack(spacing: 0) {
                thumbnailSection(maxHeight: thumbnailHeight)
                    .frame(height: thumbnailHeight)
                    .padding(.horizontal)
                    .padding(.top)

                resizeHandle(totalHeight: totalHeight)

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        titleSection
                        Divider()
                        detailsAndAttributesRow
                    }
                    .padding(.horizontal)
                    .padding(.bottom)
                }
                .frame(height: clampedDetailHeight)
            }
        }
        .task(id: video.id) {
            stopInlinePlayback()
            viewModel.isPlayingInline = false
            isEditingName = false
            viewModel.isEditingText = false
            await loadData()
        }
    }

    private func resizeHandle(totalHeight: CGFloat) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 8)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let newHeight = detailHeight - value.translation.height
                        detailHeight = min(totalHeight - 108, max(100, newHeight))
                    }
            )
            .overlay {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.3))
                    .frame(width: 40, height: 4)
            }
    }

    // MARK: - Thumbnail + Inline Player

    private func thumbnailSection(maxHeight: CGFloat) -> some View {
        ZStack {
            if viewModel.isPlayingInline, let player = inlinePlayer {
                FloatingPlayerView(player: player)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.1))
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay {
                            Image(systemName: "film")
                                .font(.system(size: 48))
                                .foregroundStyle(.secondary)
                        }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: maxHeight)
        .onChange(of: viewModel.isPlayingInline) { _, isPlaying in
            if isPlaying {
                startInlinePlayback()
            } else {
                stopInlinePlayback()
            }
        }
        .onChange(of: viewModel.inlinePlayPauseToggle) { _, _ in
            guard let player = inlinePlayer else { return }
            if player.timeControlStatus == .playing {
                player.pause()
            } else {
                player.play()
            }
        }
    }

    private func startInlinePlayback() {
        let player = AVPlayer(url: video.url)
        inlinePlayer = player
        player.play()
        Task { await viewModel.recordPlay(for: video) }
    }

    private func stopInlinePlayback() {
        inlinePlayer?.pause()
        inlinePlayer = nil
    }

    // MARK: - Title

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isEditingName {
                TextField("File name", text: $editedName)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitRename() }
                    .onExitCommand { cancelRename() }
            } else {
                Text(video.fileName)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .onTapGesture {
                        editedName = video.fileName
                        isEditingName = true
                        viewModel.isEditingText = true
                    }
            }

            Text(video.filePath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)

            HStack(spacing: 12) {
                Button("Play Video") { playVideo() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                Button("Show in Finder") {
                    NSWorkspace.shared.selectFile(video.filePath, inFileViewerRootedAtPath: "")
                }
                .controlSize(.small)
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Details (left 2/3) + Rating & Tags (right 1/3)

    private var detailsAndAttributesRow: some View {
        HStack(alignment: .top, spacing: 20) {
            metadataSection
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            ratingAndTagsSection
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(idealWidth: 180)
        }
    }

    // MARK: - Metadata

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Details")
                .font(.headline)

            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                alignment: .leading, spacing: 10
            ) {
                MetadataRow(label: "Resolution", value: video.resolution ?? "Unknown")
                MetadataRow(
                    label: "Duration", value: video.formattedDuration ?? "Unknown"
                )
                MetadataRow(label: "File Size", value: video.formattedFileSize)
                MetadataRow(label: "Codec", value: video.codec ?? "Unknown")
                MetadataRow(
                    label: "Frame Rate",
                    value: video.frameRate.map { String(format: "%.2f fps", $0) } ?? "Unknown"
                )
                MetadataRow(
                    label: "Date Added",
                    value: video.dateAdded.formatted(date: .abbreviated, time: .shortened)
                )
                if let created = video.creationDate {
                    MetadataRow(
                        label: "Created",
                        value: created.formatted(date: .abbreviated, time: .shortened)
                    )
                }
                if let lastPlayed = video.lastPlayed {
                    MetadataRow(
                        label: "Last Played",
                        value: lastPlayed.formatted(date: .abbreviated, time: .shortened)
                    )
                }
                MetadataRow(label: "Play Count", value: "\(video.playCount)")
            }
        }
    }

    // MARK: - Rating + Tags (combined right column)

    private var ratingAndTagsSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Rating")
                    .font(.headline)
                RatingView(rating: video.rating, size: 20) { newRating in
                    Task {
                        await viewModel.updateRating(forVideos: selectedIds, rating: newRating)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Tags")
                    .font(.headline)

                if viewModel.tags.isEmpty {
                    Text("No tags yet — create one below")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    FlowLayout(spacing: 6) {
                        ForEach(viewModel.tags) { tag in
                            TagToggleChip(
                                tag: tag,
                                isActive: tags.contains(where: { $0.id == tag.id })
                            ) { isAdding in
                                Task {
                                    let selected = selectedIds
                                    if isAdding {
                                        await viewModel.addTag(tag.name, toVideos: selected)
                                    } else {
                                        await viewModel.removeTag(tag, fromVideos: selected)
                                    }
                                    tags = viewModel.tagsForVideos(selected)
                                }
                            }
                        }
                    }
                }

                Divider()

                if isCreatingTag {
                    HStack(spacing: 4) {
                        TextField("Tag name", text: $newTagName)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .onSubmit { addTag() }
                        Button(action: addTag) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                        .buttonStyle(.plain)
                        .disabled(newTagName.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button(action: { isCreatingTag = false; newTagName = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    Button(action: { isCreatingTag = true }) {
                        Label("New Tag", systemImage: "plus")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Actions

    private func commitRename() {
        let newName = editedName.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty, newName != video.fileName else {
            cancelRename()
            return
        }
        Task {
            if await viewModel.renameVideo(video, to: newName) != nil {
                isEditingName = false
                viewModel.isEditingText = false
            }
        }
    }

    private func cancelRename() {
        isEditingName = false
        viewModel.isEditingText = false
        editedName = ""
    }

    private func playVideo() {
        NSWorkspace.shared.open(video.url)
        Task {
            await viewModel.recordPlay(for: video)
        }
    }

    private func loadData() async {
        thumbnail = await thumbnailService.loadThumbnail(for: video.filePath)
        if thumbnail == nil {
            if let url = try? await thumbnailService.generateThumbnail(for: video) {
                thumbnail = NSImage(contentsOf: url)
            }
        }
        tags = viewModel.tagsForVideos(selectedIds)
    }

    private var selectedIds: Set<String> {
        let ids = viewModel.selectedVideoIds
        return ids.isEmpty ? [video.id] : ids
    }

    private func addTag() {
        let name = newTagName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        Task {
            let selected = selectedIds
            await viewModel.addTag(name, toVideos: selected)
            newTagName = ""
            isCreatingTag = false
            tags = viewModel.tagsForVideos(selected)
        }
    }

}

struct MetadataRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
        }
    }
}

struct FloatingPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}
