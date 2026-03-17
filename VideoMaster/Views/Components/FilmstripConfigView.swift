import SwiftUI

struct FilmstripConfigView: View {
    let video: Video
    let thumbnailService: ThumbnailService
    let onComplete: (NSImage) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var rows: Int = 2
    @State private var columns: Int = 4
    @State private var isGenerating = false

    private var totalFrames: Int { rows * columns }

    var body: some View {
        VStack(spacing: 16) {
            Text("Modify Filmstrip")
                .font(.headline)

            Text(video.fileName)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(spacing: 24) {
                VStack(spacing: 6) {
                    Text("Rows")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Stepper(value: $rows, in: 1...6) {
                        Text("\(rows)")
                            .font(.title3)
                            .fontWeight(.medium)
                            .monospacedDigit()
                            .frame(width: 30, alignment: .center)
                    }
                }

                VStack(spacing: 6) {
                    Text("Columns")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Stepper(value: $columns, in: 1...8) {
                        Text("\(columns)")
                            .font(.title3)
                            .fontWeight(.medium)
                            .monospacedDigit()
                            .frame(width: 30, alignment: .center)
                    }
                }
            }

            Text("\(totalFrames) frames")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Generate") { generate() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isGenerating)
            }

            if isGenerating {
                ProgressView("Generating filmstrip...")
                    .controlSize(.small)
            }
        }
        .padding(20)
        .frame(width: 300)
    }

    private func generate() {
        isGenerating = true
        Task {
            if let image = try? await thumbnailService.regenerateFilmstrip(
                for: video, rows: rows, columns: columns
            ) {
                onComplete(image)
            }
            dismiss()
        }
    }
}
