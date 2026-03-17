import SwiftUI

struct FilmstripConfigView: View {
    let video: Video
    let thumbnailService: ThumbnailService
    var defaultRows: Int = 2
    var defaultColumns: Int = 4
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
                compactStepper("Rows", value: $rows, range: 1...6)
                compactStepper("Columns", value: $columns, range: 1...8)
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
        .onAppear {
            rows = defaultRows
            columns = defaultColumns
        }
    }

    private func compactStepper(_ label: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        VStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 0) {
                Button {
                    if value.wrappedValue > range.lowerBound { value.wrappedValue -= 1 }
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .disabled(value.wrappedValue <= range.lowerBound)

                Text("\(value.wrappedValue)")
                    .font(.title3)
                    .fontWeight(.medium)
                    .monospacedDigit()
                    .frame(width: 30, alignment: .center)

                Button {
                    if value.wrappedValue < range.upperBound { value.wrappedValue += 1 }
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .disabled(value.wrappedValue >= range.upperBound)
            }
        }
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
