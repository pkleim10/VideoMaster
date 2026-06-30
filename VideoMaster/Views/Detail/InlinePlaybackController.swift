import AVKit
import AppKit
import Foundation
import SwiftUI

/// The single inline-playback engine, shared by every playback mode (detail-pane hero, floating
/// overlay, and full-screen window). It owns the `AVPlayer` and `SubtitleTrack` and centralizes the
/// behavior that must be identical in every mode:
///
/// - `isPlayable` preflight + missing-file detection, and `AVPlayerItem.status` error surfacing
/// - resume-position load on start **and save on stop** (`PlaybackPositionStore`)
/// - the "Resumed at … / Start at beginning" banner (+ optional auto-fade)
/// - sidecar `.srt` subtitle discovery and attachment
/// - `recordPlay`
/// - Space / Shift-Space (play-pause / restart) intents
///
/// Owned by `LibraryViewModel` (`viewModel.playback`) so a single player instance backs all hosts.
/// Host views are thin: they render `player` / `subtitleTrack` / banner / error state and forward the
/// lifecycle calls below.
@MainActor
@Observable
final class InlinePlaybackController {
    @ObservationIgnored private unowned let viewModel: LibraryViewModel

    // Rendered by host views.
    private(set) var player: AVPlayer?
    let subtitleTrack = SubtitleTrack()
    private(set) var didAutoResume = false
    private(set) var resumedFromSeconds: Double?
    var resumeBannerOpacity: Double = 1
    private(set) var playerError: String?
    private(set) var currentVideo: Video?

    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var resumeBannerFadeTask: Task<Void, Never>?

    init(viewModel: LibraryViewModel) {
        self.viewModel = viewModel
    }

    // MARK: - Lifecycle

    /// Begin playback of `video`. `seconds == 0` lets the saved resume position apply (with banner);
    /// `seconds > 0` is an explicit seek (filmstrip click / Shift-Space) that suppresses resume.
    func start(video: Video, at seconds: Double) {
        currentVideo = video
        playerError = nil
        statusTask?.cancel()
        discoverSidecarSubtitles(for: video)

        statusTask = Task { @MainActor in
            // Pre-flight: ask AVFoundation whether it can play this file before creating the player,
            // so unsupported formats are rejected immediately rather than showing a blank player.
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
                // Precise seek (zero tolerance) so a filmstrip click lands on the clicked frame
                // instead of snapping to the nearest keyframe.
                newPlayer.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                               toleranceBefore: .zero, toleranceAfter: .zero) { _ in newPlayer.play() }
            } else {
                cancelResumeBannerFadeTask()
                resumeBannerOpacity = 1
                didAutoResume = false
                resumedFromSeconds = nil
                newPlayer.play()
            }
            Task { await viewModel.recordPlay(for: video) }

            // Status monitoring: catch load failures that slip past the isPlayable check
            // (e.g. files that report playable but have an undecodable codec inside).
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

    /// Tear down the player, persisting the current position so the next play can resume.
    func stop() {
        statusTask?.cancel()
        statusTask = nil
        persistPosition()
        cancelResumeBannerFadeTask()
        resumeBannerOpacity = 1
        subtitleTrack.detach()
        player?.pause()
        player = nil
    }

    // MARK: - Intents

    func togglePlayPause() {
        guard let player else { return }
        if player.timeControlStatus == .playing { player.pause() } else { player.play() }
    }

    func restartFromBeginning() {
        guard let player else { return }
        cancelResumeBannerFadeTask()
        didAutoResume = false
        resumedFromSeconds = nil
        resumeBannerOpacity = 1
        if let video = currentVideo { PlaybackPositionStore.clear(filePath: video.filePath) }
        player.pause()
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak player] _ in
            player?.play()
        }
    }

    /// Resume-banner "Start at beginning": clear the saved position and seek to 0.
    func startAtBeginning() {
        guard let player, let video = currentVideo else { return }
        cancelResumeBannerFadeTask()
        resumeBannerOpacity = 1
        didAutoResume = false
        resumedFromSeconds = nil
        PlaybackPositionStore.clear(filePath: video.filePath)
        player.seek(to: .zero) { _ in player.play() }
    }

    func dismissError() {
        playerError = nil
    }

    func openInExternalPlayer(_ video: Video) {
        playerError = nil
        NSWorkspace.shared.open(video.url)
        Task { await viewModel.recordPlay(for: video) }
    }

    // MARK: - Resume banner fade settings

    func onFadeSettingChanged(enabled: Bool) {
        if !enabled {
            cancelResumeBannerFadeTask()
            resumeBannerOpacity = 1
        } else if didAutoResume {
            scheduleResumeBannerFadeIfNeeded()
        }
    }

    func onFadeDelayChanged() {
        if didAutoResume, viewModel.fadeResumeBannerAutomatically {
            scheduleResumeBannerFadeIfNeeded()
        }
    }

    // MARK: - Persistence

    func persistPosition() {
        guard let player, let video = currentVideo else { return }
        let seconds = player.currentTime().seconds
        guard seconds.isFinite, seconds > 0 else { return }
        PlaybackPositionStore.saveSeconds(seconds, filePath: video.filePath)
    }

    // MARK: - Internals

    private func discoverSidecarSubtitles(for video: Video) {
        let videoPath = video.filePath
        if let srt = SubtitleTrack.findSidecarSRT(for: video.url) {
            _ = subtitleTrack.load(from: srt)
            Task { await viewModel.setHasSubtitles(videoPath: videoPath, hasSubtitles: true) }
        } else {
            subtitleTrack.unload()
            Task { await viewModel.setHasSubtitles(videoPath: videoPath, hasSubtitles: false) }
        }
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
}
