import SwiftUI

/// The single resizable player surface (single-player redesign, see
/// `Playback_Redesign_Plan_2026-06-30.md`). Anchored to the window's top-right corner; the lower-left
/// handle resizes it (top + right edges stay pinned) between a compact minimum and the available
/// content area. Size is committed to `viewModel.playerFloatingSize` on release (persisted).
///
/// Hosts the shared `InlinePlaybackController` via `OverlayInlinePlayerView`.
struct FloatingPlayerPanel: View {
    let video: Video
    @Bindable var viewModel: LibraryViewModel
    /// Size of the content area this panel floats in (from the caller's GeometryReader), used to clamp.
    let available: CGSize

    @State private var dragSize: CGSize?
    @State private var dragStartSize: CGSize?

    private let minSize = CGSize(width: 320, height: 200)
    private let outerPadding: CGFloat = 12

    private var maxSize: CGSize {
        CGSize(width: max(minSize.width, available.width - outerPadding * 2),
               height: max(minSize.height, available.height - outerPadding * 2))
    }

    private func clamp(_ s: CGSize) -> CGSize {
        CGSize(width: min(max(s.width, minSize.width), maxSize.width),
               height: min(max(s.height, minSize.height), maxSize.height))
    }

    private var size: CGSize { clamp(dragSize ?? viewModel.playerFloatingSize) }

    var body: some View {
        OverlayInlinePlayerView(video: video, viewModel: viewModel)
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                    .stroke(Color.appAccent.opacity(0.3), lineWidth: 1)
            )
            .overlay(alignment: .bottomTrailing) { presets }
            .overlay(alignment: .bottomLeading) { resizeHandle }
            .shadow(color: .black.opacity(0.45), radius: 18, x: 0, y: 8)
            .padding(outerPadding)
    }

    // Quick size presets (small / medium / large fractions of the available width).
    private var presets: some View {
        HStack(spacing: 4) {
            presetButton("S", fraction: 0.45)
            presetButton("M", fraction: 0.66)
            presetButton("L", fraction: 0.92)
        }
        .padding(8)
    }

    private func presetButton(_ label: String, fraction: CGFloat) -> some View {
        Button(label) {
            let w = (available.width - outerPadding * 2) * fraction
            // ~16:9 video plus the compact header strip.
            let h = w * 9.0 / 16.0 + 28
            viewModel.playerFloatingSize = clamp(CGSize(width: w, height: h))
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(Color.appTextSecondary)
        .buttonStyle(.plain)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Color.appSurface.opacity(0.85), in: Capsule())
    }

    private var resizeHandle: some View {
        Image(systemName: "arrow.up.right.and.arrow.down.left")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Color.appTextSecondary)
            .padding(6)
            .background(Color.appSurface.opacity(0.85), in: Circle())
            .padding(8)
            .contentShape(Rectangle())
            .gesture(
                // Measure in the global space: the handle moves as the panel resizes, so a `.local`
                // translation would feed back on itself and jitter. Round to whole points to avoid
                // sub-pixel thrash of the live-resizing player layer.
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let base = dragStartSize ?? viewModel.playerFloatingSize
                        if dragStartSize == nil { dragStartSize = base }
                        // Top-right anchored: drag the handle left to widen, down to grow taller.
                        let proposed = CGSize(width: (base.width - value.translation.width).rounded(),
                                              height: (base.height + value.translation.height).rounded())
                        dragSize = clamp(proposed)
                    }
                    .onEnded { _ in
                        if let s = dragSize { viewModel.playerFloatingSize = s }
                        dragSize = nil
                        dragStartSize = nil
                    }
            )
            .help("Drag to resize")
    }
}
