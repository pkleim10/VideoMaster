import AppKit

/// Container that clips its hosted view. When frozen, the hosted view keeps a fixed width
/// regardless of how the container is resized by the split view, producing a clipping effect.
final class ClippingContainer: NSView {
    private(set) var isFrozen = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        clipsToBounds = true
    }

    func freeze() {
        guard !isFrozen, let hosted = subviews.first else { return }
        isFrozen = true
        let w = hosted.frame.width
        hosted.translatesAutoresizingMaskIntoConstraints = true
        hosted.autoresizingMask = [.height]
        hosted.frame = NSRect(x: 0, y: 0, width: w, height: bounds.height)
    }

    func unfreeze() {
        guard isFrozen, let hosted = subviews.first else { return }
        isFrozen = false
        hosted.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hosted.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosted.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosted.topAnchor.constraint(equalTo: topAnchor),
            hosted.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        if isFrozen, let hosted = subviews.first {
            hosted.frame.size.height = bounds.height
        } else {
            super.resizeSubviews(withOldSize: oldSize)
        }
    }
}
