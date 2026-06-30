import AVKit
import AppKit
import SwiftUI

/// `AVPlayerView` subclass that intercepts **Shift+Space** for "restart from beginning". Plain Space
/// is left to AVPlayerView's native play/pause. AVPlayerView otherwise treats Shift+Space as plain
/// Space (ignoring the modifier), so without this it would just toggle play/pause.
final class KeyAwarePlayerView: AVPlayerView {
    var onRestartFromBeginning: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        // keyCode 49 = Space.
        if event.keyCode == 49, event.modifierFlags.contains(.shift) {
            onRestartFromBeginning?()
            return
        }
        super.keyDown(with: event)
    }
}

/// Hosts an `AVPlayer` in a floating-controls `AVPlayerView`. Used by every inline playback host
/// (inspector hero, overlay panel). Takes first responder while mounted so keyboard transport
/// (Space / Shift+Space) reaches it.
struct FloatingPlayerView: NSViewRepresentable {
    let player: AVPlayer
    var showsFullscreenButton: Bool = true
    var onRestartFromBeginning: (() -> Void)? = nil

    func makeNSView(context: Context) -> KeyAwarePlayerView {
        let view = KeyAwarePlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = showsFullscreenButton
        view.onRestartFromBeginning = onRestartFromBeginning
        // Grab keyboard focus once inserted so Space / Shift+Space reach the player.
        DispatchQueue.main.async { [weak view] in
            guard let view, let window = view.window else { return }
            if !(window.firstResponder is NSText) {
                window.makeFirstResponder(view)
            }
        }
        return view
    }

    func updateNSView(_ nsView: KeyAwarePlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
        nsView.showsFullScreenToggleButton = showsFullscreenButton
        nsView.onRestartFromBeginning = onRestartFromBeginning
    }
}
