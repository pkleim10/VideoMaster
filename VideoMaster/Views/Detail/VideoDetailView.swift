import SwiftUI

struct VideoDetailView: View {
    let video: Video
    let viewModel: LibraryViewModel
    let thumbnailService: ThumbnailService
    @State private var tags: [Tag] = []
    @State private var newTagName: String = ""
    @State private var thumbnail: NSImage?
    @State private var showPlayer = false

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    thumbnailSection(maxHeight: geo.size.height * 0.6)
                    titleSection
                    Divider()
                    detailsAndAttributesRow
                }
                .padding()
            }
        }
        .task(id: video.id) {
            await loadData()
        }
        .sheet(isPresented: $showPlayer) {
            VideoPlayerView(url: video.url)
                .frame(minWidth: 640, minHeight: 480)
        }
    }

    // MARK: - Thumbnail + Play

    private func thumbnailSection(maxHeight: CGFloat) -> some View {
        ZStack {
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

            Button(action: playVideo) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.3), radius: 8)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: maxHeight)
    }

    // MARK: - Title

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(video.fileName)
                .font(.title2)
                .fontWeight(.semibold)
                .textSelection(.enabled)

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
                        await viewModel.updateRating(for: video, rating: newRating)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Tags")
                    .font(.headline)

                FlowLayout(spacing: 6) {
                    ForEach(tags) { tag in
                        TagChip(tag: tag) {
                            Task {
                                await viewModel.removeTag(tag, from: video)
                                tags = await viewModel.tagsForVideo(video)
                            }
                        }
                    }
                }

                HStack {
                    TextField("Add tag...", text: $newTagName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addTag() }
                    Button("Add", action: addTag)
                        .disabled(newTagName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    // MARK: - Actions

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
        tags = await viewModel.tagsForVideo(video)
    }

    private func addTag() {
        let name = newTagName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        Task {
            await viewModel.addTag(name, to: video)
            newTagName = ""
            tags = await viewModel.tagsForVideo(video)
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
