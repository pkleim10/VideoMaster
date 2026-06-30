import AppKit
import AVFoundation
import AVKit
import SwiftUI

/// Hosts inline playback in a separate window so the main library window stays normal.
/// Edge-to-edge mode uses a borderless window at `NSScreen.frame` (no `toggleFullScreen` space animation).
final class FullscreenInlinePlayerWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let playerView = AVPlayerView()
    /// Hosting view that renders the Netflix-style subtitle overlay on top of `playerView`.
    /// Created lazily in `present(...)` so the SwiftUI view observes the provided `SubtitleTrack`.
    private var subtitleHost: NSHostingView<SubtitleOverlayContainer>?
    private var onEnded: (() -> Void)?
    private var didEnd = false
    private var keyDownMonitor: Any?
    private var savedPresentationOptions: NSApplication.PresentationOptions = []
    private var didApplyPresentationOptions = false

    func present(
        player: AVPlayer,
        title: String,
        startWindowInFullscreen: Bool,
        subtitleTrack: SubtitleTrack,
        onEnded: @escaping () -> Void
    ) {
        self.onEnded = onEnded

        playerView.player = player
        playerView.controlsStyle = .floating
        // Edge-to-edge already fills the display; hide to avoid a second fullscreen mode.
        playerView.showsFullScreenToggleButton = !startWindowInFullscreen

        let host = NSHostingView(rootView: SubtitleOverlayContainer(track: subtitleTrack))
        host.translatesAutoresizingMaskIntoConstraints = false
        // Overlay is hit-testing-disabled inside the SwiftUI view itself; clicks still reach AVPlayerView controls.
        self.subtitleHost = host

        if startWindowInFullscreen {
            presentEdgeToEdge(title: title)
        } else {
            presentTitledWindow(title: title)
        }
    }

    private func presentEdgeToEdge(title: String) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            presentTitledWindow(title: title)
            return
        }

        let frame = screen.frame
        let content = NSView(frame: NSRect(origin: .zero, size: frame.size))
        playerView.frame = content.bounds
        playerView.autoresizingMask = [.width, .height]
        content.addSubview(playerView)

        // Subtitle overlay is layered above the player view but below the close button,
        // so the close button remains clickable even when a cue is visible.
        if let host = subtitleHost {
            content.addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                host.topAnchor.constraint(equalTo: content.topAnchor),
                host.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }

        let closeButton = makeCloseButton()
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(closeButton)
        NSLayoutConstraint.activate([
            // Bottom-right, matching the windowed panel's full-screen button placement.
            closeButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            closeButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            closeButton.widthAnchor.constraint(equalToConstant: 28),
            closeButton.heightAnchor.constraint(equalToConstant: 28),
        ])

        let w = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        w.title = title
        w.contentView = content
        w.delegate = self
        w.isReleasedWhenClosed = false
        w.isOpaque = true
        w.backgroundColor = .black
        w.isMovable = false
        w.setFrame(frame, display: true)
        window = w
        w.makeKeyAndOrderFront(nil)

        savedPresentationOptions = NSApplication.shared.presentationOptions
        NSApplication.shared.presentationOptions = [.hideMenuBar, .hideDock]
        didApplyPresentationOptions = true

        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard self.window?.isKeyWindow == true else { return event }
            if event.keyCode == 53 {
                self.closeWindow()
                return nil
            }
            return event
        }
    }

    /// Titled window (e.g. fallback or if `startWindowInFullscreen` is false).
    private func presentTitledWindow(title: String) {
        playerView.showsFullScreenToggleButton = true
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
        playerView.frame = content.bounds
        playerView.autoresizingMask = [.width, .height]
        content.addSubview(playerView)

        if let host = subtitleHost {
            content.addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                host.topAnchor.constraint(equalTo: content.topAnchor),
                host.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }

        let w = NSWindow(
            contentRect: content.bounds,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.title = title
        w.contentView = content
        w.delegate = self
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
    }

    private func makeCloseButton() -> NSButton {
        let b = NSButton()
        b.bezelStyle = .accessoryBarAction
        // This returns to the windowed player (playback continues), so it reads as "exit full screen"
        // rather than "close/stop".
        b.image = NSImage(systemSymbolName: "arrow.down.right.and.arrow.up.left",
                          accessibilityDescription: "Exit Full Screen")
        b.imagePosition = .imageOnly
        b.isBordered = false
        b.target = self
        b.action = #selector(closeButtonTapped)
        b.toolTip = "Exit Full Screen (Esc)"
        b.contentTintColor = .labelColor
        return b
    }

    @objc private func closeButtonTapped() {
        closeWindow()
    }

    /// Closes the window and tears down the player; `onEnded` runs from `windowWillClose`.
    func closeWindow() {
        guard window != nil else {
            finishEndedIfNeeded()
            return
        }
        window?.close()
    }

    private func finishEndedIfNeeded() {
        guard !didEnd else { return }
        didEnd = true
        if didApplyPresentationOptions {
            NSApplication.shared.presentationOptions = savedPresentationOptions
            didApplyPresentationOptions = false
        }
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
            self.keyDownMonitor = nil
        }
        // Detach the player from this window's view *without pausing* — the AVPlayer is owned by the
        // shared InlinePlaybackController and carries on playing back in the in-window panel.
        playerView.player = nil
        subtitleHost?.removeFromSuperview()
        subtitleHost = nil
        window?.delegate = nil
        window = nil
        onEnded?()
        onEnded = nil
    }

    func windowWillClose(_ notification: Notification) {
        finishEndedIfNeeded()
    }
}
