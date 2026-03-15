import SwiftUI

struct LibraryListView: View {
    @Bindable var viewModel: LibraryViewModel
    let thumbnailService: ThumbnailService

    var body: some View {
        Table(
            viewModel.filteredVideos,
            selection: $viewModel.selectedVideoIds,
            sortOrder: Binding(
                get: { viewModel.tableSortOrder },
                set: { newValue in
                    withAnimation(nil) {
                        viewModel.tableSortOrder = newValue
                    }
                    viewModel.savePreferences()
                }
            )
        ) {
            TableColumn("Name", value: \.fileName) { video in
                HStack(spacing: 8) {
                    AsyncThumbnailView(
                        filePath: video.filePath, thumbnailService: thumbnailService
                    )
                    .frame(width: 56, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    Text(video.fileName)
                        .lineLimit(1)
                }
            }
            .width(min: 200, ideal: 350)

            TableColumn("Duration", value: \.sortableDuration) { video in
                Text(video.formattedDuration ?? "—")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 80)

            TableColumn("Resolution", value: \.sortablePixelCount) { video in
                if let label = video.resolutionLabel {
                    Text(label)
                        .foregroundStyle(.secondary)
                } else {
                    Text("—")
                        .foregroundStyle(.tertiary)
                }
            }
            .width(min: 60, ideal: 80)

            TableColumn("Size", value: \.fileSize) { video in
                Text(video.formattedFileSize)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 80)

            TableColumn("Rating", value: \.rating) { video in
                RatingView(rating: video.rating, size: 10) { newRating in
                    Task {
                        await viewModel.updateRating(for: video, rating: newRating)
                    }
                }
            }
            .width(min: 70, ideal: 90)

            TableColumn("Date Added", value: \.dateAdded) { video in
                Text(video.dateAdded, style: .date)
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 100)
        }
        .id(viewModel.filteredVideosVersion)
        .contextMenu(forSelectionType: Video.ID.self) { ids in
            if let filePath = ids.first,
               let video = viewModel.filteredVideos.first(where: { $0.id == filePath })
            {
                Button("Play") {
                    NSWorkspace.shared.open(video.url)
                    Task { await viewModel.recordPlay(for: video) }
                }
                Button("Show in Finder") {
                    NSWorkspace.shared.selectFile(
                        video.filePath, inFileViewerRootedAtPath: ""
                    )
                }
                Divider()
                Button("Remove from Library", role: .destructive) {
                    Task {
                        await viewModel.deleteVideos(ids)
                    }
                }
            }
        } primaryAction: { ids in
            if let filePath = ids.first,
               let video = viewModel.filteredVideos.first(where: { $0.id == filePath })
            {
                NSWorkspace.shared.open(video.url)
                Task { await viewModel.recordPlay(for: video) }
            }
        }
    }
}
