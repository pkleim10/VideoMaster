import AppKit
import AVFoundation
import AVKit

/// Hosts inline playback in a separate window so the main library window stays normal.
/// Edge-to-edge mode uses a borderless window at `NSScreen.frame` (no `toggleFullScreen` space animation).
final class FullscreenInlinePlayerWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let playerView = AVPlayerView()
    private var onEnded: (() -> Void)?
    private var didEnd = false
    private var keyDownMonitor: Any?
    private var savedPresentationOptions: NSApplication.PresentationOptions = []
    private var didApplyPresentationOptions = false

    func present(player: AVPlayer, title: String, startWindowInFullscreen: Bool, onEnded: @escaping () -> Void) {
        self.onEnded = onEnded

        playerView.player = player
        playerView.controlsStyle = .floating
        // Edge-to-edge already fills the display; hide to avoid a second fullscreen mode.
        playerView.showsFullScreenToggleButton = !startWindowInFullscreen

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

        let closeButton = makeCloseButton()
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(closeButton)
        NSLayoutConstraint.activate([
            closeButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            closeButton.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
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
        b.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")
        b.imagePosition = .imageOnly
        b.isBordered = false
        b.target = self
        b.action = #selector(closeButtonTapped)
        b.toolTip = "Close"
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
        playerView.player?.pause()
        playerView.player = nil
        window?.delegate = nil
        window = nil
        onEnded?()
        onEnded = nil
    }

    func windowWillClose(_ notification: Notification) {
        finishEndedIfNeeded()
    }
}
