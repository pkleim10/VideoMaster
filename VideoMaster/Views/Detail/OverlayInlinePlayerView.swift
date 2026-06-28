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

    @State private var player: AVPlayer?
    @State private var subtitleTrack = SubtitleTrack()
    @State private var didAutoResume = false
    @State private var resumedFromSeconds: Double?
    @State private var resumeBannerOpacity: Double = 1
    @State private var resumeBannerFadeTask: Task<Void, Never>?
    @State private var playerError: String?
    @State private var statusTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .top) {
            // Deep background so the framed player feels grounded inside the panel.
            Color.appBackground

            if let player {
                // The actual player is framed to feel like a deliberate piece of media
                // rather than raw video bleeding to the edges of the panel.
                FloatingPlayerView(player: player, showsFullscreenButton: false)
                    .appMediaFrame(cornerRadius: AppRadius.lg)
                    .padding(.horizontal, 10)
                    .padding(.top, 28)   // leave room for the compact header
                    .padding(.bottom, 10)

                SubtitleOverlayContainer(track: subtitleTrack)

                if didAutoResume, let resumeSecs = resumedFromSeconds {
                    resumeOverlay(resumedFromSeconds: resumeSecs) {
                        cancelResumeBannerFadeTask()
                        resumeBannerOpacity = 1
                        didAutoResume = false
                        resumedFromSeconds = nil
                        PlaybackPositionStore.clear(filePath: video.filePath)
                        player.seek(to: .zero) { _ in player.play() }
                    }
                    .opacity(resumeBannerOpacity)
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }

            // Minimal header bar — signals that this is a placed, first-class player panel
            // rather than video that just happens to be here.
            overlayHeader

            if let playerError {
                errorOverlay(playerError)
            }
        }
        .task(id: video.id) {
            discoverSidecarSubtitles()
            let seek = viewModel.pendingFilmstripSeekSeconds ?? 0
            viewModel.pendingFilmstripSeekSeconds = nil
            startPlayback(at: seek)
        }
        .onChange(of: viewModel.inlinePlayPauseToggle) { _, _ in
            guard let player else { return }
            if player.timeControlStatus == .playing { player.pause() } else { player.play() }
        }
        .onChange(of: viewModel.inlineRestartFromBeginning) { _, _ in
            guard let player else { return }
            cancelResumeBannerFadeTask()
            didAutoResume = false
            resumedFromSeconds = nil
            resumeBannerOpacity = 1
            PlaybackPositionStore.clear(filePath: video.filePath)
            player.seek(to: .zero) { _ in player.play() }
        }
        .onChange(of: viewModel.fadeResumeBannerAutomatically) { _, enabled in
            if !enabled {
                cancelResumeBannerFadeTask()
                resumeBannerOpacity = 1
            } else if didAutoResume {
                scheduleResumeBannerFadeIfNeeded()
            }
        }
        .onChange(of: viewModel.resumeBannerFadeDelaySeconds) { _, _ in
            if didAutoResume, viewModel.fadeResumeBannerAutomatically {
                scheduleResumeBannerFadeIfNeeded()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            persistPositionIfPossible()
        }
        .onDisappear {
            stopPlayback()
            viewModel.pendingFilmstripSeekSeconds = nil
        }
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

    // MARK: - Playback lifecycle (no fullscreen routing — see type doc)

    private func startPlayback(at seconds: Double) {
        playerError = nil
        statusTask?.cancel()
        statusTask = Task { @MainActor in
            let asset = AVURLAsset(url: video.url)
            let playable = (try? await asset.load(.isPlayable)) ?? false
            guard !Task.isCancelled else { return }
            guard playable else {
                if FileManager.default.fileExists(atPath: video.filePath) {
                    let ext = video.url.pathExtension.uppercased()
                    playerError = ext.isEmpty
                        ? "This file cannot be played by the built-in player."
                        : "\(ext) files cannot be played by the built-in player."
                } else {
                    playerError = "The file could not be found. The drive may not be mounted."
                }
                viewModel.isPlayingInline = false
                return
            }

            let newPlayer = AVPlayer(url: video.url)
            player = newPlayer
            subtitleTrack.attach(to: newPlayer)

            let resumeSeconds: Double? = {
                guard seconds == 0 else { return nil }
                guard let s = PlaybackPositionStore.loadSeconds(filePath: video.filePath) else { return nil }
                guard s >= 1.0 else { return nil }
                if let duration = video.duration, duration > 0, s >= duration - 5.0 { return nil }
                return s
            }()
            if let resumeSeconds {
                resumeBannerOpacity = 1
                didAutoResume = true
                resumedFromSeconds = resumeSeconds
                newPlayer.seek(to: CMTime(seconds: resumeSeconds, preferredTimescale: 600)) { _ in newPlayer.play() }
                scheduleResumeBannerFadeIfNeeded()
            } else if seconds > 0 {
                cancelResumeBannerFadeTask()
                resumeBannerOpacity = 1
                didAutoResume = false
                resumedFromSeconds = nil
                newPlayer.seek(to: CMTime(seconds: seconds, preferredTimescale: 600)) { _ in newPlayer.play() }
            } else {
                cancelResumeBannerFadeTask()
                resumeBannerOpacity = 1
                didAutoResume = false
                resumedFromSeconds = nil
                newPlayer.play()
            }
            Task { await viewModel.recordPlay(for: video) }

            guard let item = newPlayer.currentItem else { return }
            for await status in item.publisher(for: \AVPlayerItem.status).values {
                guard !Task.isCancelled else { return }
                if status == .failed {
                    playerError = item.error?.localizedDescription ?? "The file could not be opened for playback."
                    viewModel.isPlayingInline = false
                    return
                } else if status == .readyToPlay {
                    return
                }
            }
        }
    }

    private func stopPlayback() {
        statusTask?.cancel()
        statusTask = nil
        persistPositionIfPossible()
        cancelResumeBannerFadeTask()
        resumeBannerOpacity = 1
        subtitleTrack.detach()
        player?.pause()
        player = nil
    }

    private func persistPositionIfPossible() {
        guard let player else { return }
        let seconds = player.currentTime().seconds
        guard seconds.isFinite, seconds > 0 else { return }
        PlaybackPositionStore.saveSeconds(seconds, filePath: video.filePath)
    }

    private func cancelResumeBannerFadeTask() {
        resumeBannerFadeTask?.cancel()
        resumeBannerFadeTask = nil
    }

    private func scheduleResumeBannerFadeIfNeeded() {
        cancelResumeBannerFadeTask()
        guard viewModel.fadeResumeBannerAutomatically else { return }
        let delay = max(1, viewModel.resumeBannerFadeDelaySeconds)
        resumeBannerFadeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.35)) { resumeBannerOpacity = 0 }
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            didAutoResume = false
            resumedFromSeconds = nil
            resumeBannerOpacity = 1
        }
    }

    private func discoverSidecarSubtitles() {
        let videoPath = video.filePath
        if let srt = SubtitleTrack.findSidecarSRT(for: video.url) {
            subtitleTrack.load(from: srt)
            Task { await viewModel.setHasSubtitles(videoPath: videoPath, hasSubtitles: true) }
        } else {
            subtitleTrack.unload()
            Task { await viewModel.setHasSubtitles(videoPath: videoPath, hasSubtitles: false) }
        }
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
                        playerError = nil
                        NSWorkspace.shared.open(video.url)
                        Task { await viewModel.recordPlay(for: video) }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.appAccent)
                    .controlSize(.small)
                    Button("Dismiss") {
                        playerError = nil
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
