import SwiftUI

struct LibraryGridView: View {
    let viewModel: LibraryViewModel
    let thumbnailService: ThumbnailService

    private let columns = [
        GridItem(.adaptive(minimum: 200, maximum: 300), spacing: 16)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(viewModel.filteredVideos) { video in
                    VideoGridCell(
                        video: video,
                        isSelected: viewModel.selectedVideoIds.contains(video.id),
                        viewModel: viewModel,
                        thumbnailService: thumbnailService
                    )
                    .onTapGesture(count: 2) {
                        playVideo(video)
                    }
                    .onTapGesture {
                        viewModel.selectedVideoIds = [video.id]
                    }
                    .contextMenu {
                        videoContextMenu(video)
                    }
                }
            }
            .padding()
        }
        .id(viewModel.filteredVideosVersion)
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
        Divider()
        Button("Remove from Library", role: .destructive) {
            Task {
                await viewModel.deleteVideos([video.id])
            }
        }
    }
}

struct VideoGridCell: View {
    let video: Video
    let isSelected: Bool
    let viewModel: LibraryViewModel
    let thumbnailService: ThumbnailService
    @State private var thumbnail: NSImage?
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                thumbnailImage
                    .frame(height: 160)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                if let duration = video.formattedDuration {
                    Text(duration)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .monospacedDigit()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.75))
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .padding(6)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(video.fileName)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(2)

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
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(
                    isSelected
                        ? Color.accentColor.opacity(0.2)
                        : (isHovering ? Color.primary.opacity(0.04) : Color.clear)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
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
                        .font(.title2)
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
