import AVKit
import AppKit
import SwiftUI

/// Self-contained inline player for the floating **overlay** mode (`viewModel.inlineOverlayActive`).
///
/// It mirrors `VideoDetailView`'s inline player — resume position, sidecar subtitles, resume banner, error
/// overlay, and the Space/Shift-Space control counters — but deliberately omits the fullscreen-window
/// routing: fullscreen-start takes precedence over overlay, so this view is only ever mounted when fullscreen
/// is off. It owns its own `AVPlayer` and `SubtitleTrack`, and the browser/detail layout underneath is never
/// resized or frozen, so the grid/list scroll position is preserved across playback.
struct OverlayInlinePlayerView: View {
    let video: Video
    @Bindable var viewModel: LibraryViewModel

    private var playback: InlinePlaybackController { viewModel.playback }

    var body: some View {
        ZStack(alignment: .top) {
            // Deep background so the framed player feels grounded inside the panel.
            Color.appBackground

            if let player = playback.player {
                // The actual player is framed to feel like a deliberate piece of media
                // rather than raw video bleeding to the edges of the panel.
                FloatingPlayerView(player: player, showsFullscreenButton: false,
                                   onRestartFromBeginning: { playback.restartFromBeginning() })
                    .appMediaFrame(cornerRadius: AppRadius.lg)
                    .padding(.horizontal, 10)
                    .padding(.top, 28)   // leave room for the compact header
                    .padding(.bottom, 10)

                SubtitleOverlayContainer(track: playback.subtitleTrack)

                if playback.didAutoResume, let resumeSecs = playback.resumedFromSeconds {
                    resumeOverlay(resumedFromSeconds: resumeSecs) {
                        playback.startAtBeginning()
                    }
                    .opacity(playback.resumeBannerOpacity)
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }

            // Minimal header bar — signals that this is a placed, first-class player panel
            // rather than video that just happens to be here.
            overlayHeader

            if let playerError = playback.playerError {
                errorOverlay(playerError)
            }
        }
        // Start/stop is driven by ContentView (from `isPlayingInline`), not this view's lifecycle, so
        // the panel can unmount/remount (e.g. entering/leaving full-screen) without tearing down the
        // player. This view is a pure renderer of the shared controller's state.
        .onChange(of: viewModel.fadeResumeBannerAutomatically) { _, enabled in
            playback.onFadeSettingChanged(enabled: enabled)
        }
        .onChange(of: viewModel.resumeBannerFadeDelaySeconds) { _, _ in playback.onFadeDelayChanged() }
    }

    // Very compact header that makes the overlay read as a deliberate floating player panel.
    private var overlayHeader: some View {
        HStack(spacing: 6) {
            Text(video.fileName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.appTextSecondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            Button {
                viewModel.isPlayingInline = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.appTextTertiary)
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Rectangle()
                .fill(Color.appSurface.opacity(0.92))
                .overlay(Rectangle().fill(Color.appDivider.opacity(0.6)).frame(height: 0.5), alignment: .bottom)
        )
    }

    // MARK: - Overlays

    private func resumeOverlay(resumedFromSeconds: Double, startAtBeginning: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Text("Resumed at \(formatTimestamp(resumedFromSeconds))")
                .font(.caption)
                .foregroundStyle(Color.appTextPrimary)
            Button("Start at beginning", action: startAtBeginning)
                .font(.caption)
                .buttonStyle(.borderedProminent)
                .tint(Color.appAccent)
                .controlSize(.small)
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.sm)
        .background(Material.appFloatingMaterial, in: RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .strokeBorder(Color.appAccent.opacity(0.35), lineWidth: 1)
        )
    }

    private func errorOverlay(_ message: String) -> some View {
        ZStack {
            Color.black.opacity(0.55)
            VStack(spacing: AppSpacing.lg) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.yellow)
                Text("Playback Failed")
                    .font(.headline)
                    .foregroundStyle(Color.appTextPrimary)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
                HStack(spacing: AppSpacing.md) {
                    Button("Open in External Player") {
                        playback.openInExternalPlayer(video)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.appAccent)
                    .controlSize(.small)
                    Button("Dismiss") {
                        playback.dismissError()
                        viewModel.isPlayingInline = false
                    }
                    .buttonStyle(.bordered)
                    .tint(Color.appAccent)
                    .controlSize(.small)
                }
            }
            .padding(AppSpacing.lg)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                    .fill(Material.appFloatingMaterial)
                    .background(Color.appSurface.opacity(0.7))
            )
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                    .stroke(Color.appAccent.opacity(0.25), lineWidth: 1)
            )
        }
    }

    private func formatTimestamp(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}
