import SwiftUI

struct AsyncThumbnailView: View {
    let filePath: String
    let thumbnailService: ThumbnailService
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(Color.secondary.opacity(0.08))
                    .overlay {
                        Image(systemName: "film")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .task(id: filePath) {
            image = thumbnailService.loadThumbnail(for: filePath)
        }
    }
}
