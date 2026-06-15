import AppKit
import SwiftUI

/// Drives the `NSScrollView` backing the grid or list in response to `LibraryViewModel.scrollCommand`
/// (top / bottom / page up / page down). Operates directly on the clip view so it works identically for
/// the SwiftUI `ScrollView` (grid) and the `Table`'s scroll view (list), independent of selection — this
/// keeps the existing fast scrollbar "rip" untouched while adding explicit jump controls.
struct ScrollCommandHandler: NSViewRepresentable {
    enum Mode { case grid, list }
    let command: LibraryViewModel.ScrollCommand?
    let mode: Mode

    final class Coordinator {
        var lastToken: Int = 0
    }

    func makeCoordinator() -> Coordinator {
        let c = Coordinator()
        // Adopt the current token so a freshly mounted handler (e.g. after a grid/list switch) does not
        // replay the most recent command on appear.
        c.lastToken = command?.token ?? 0
        return c
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let command, command.token != context.coordinator.lastToken else { return }
        context.coordinator.lastToken = command.token
        let kind = command.kind
        let mode = self.mode
        // Defer so any pending layout (version bump, column changes) settles before we read viewport metrics.
        DispatchQueue.main.async { [weak nsView] in
            guard let nsView, let scrollView = Self.locateScrollView(from: nsView, mode: mode) else { return }
            Self.apply(kind, to: scrollView)
        }
    }

    // MARK: - Scrolling

    private static func apply(_ kind: LibraryViewModel.ScrollCommand.Kind, to scrollView: NSScrollView) {
        let clip = scrollView.contentView
        let insets = scrollView.contentInsets
        let clipH = clip.bounds.height
        let docHeight = scrollView.documentView?.bounds.height ?? clipH
        // With a top content inset (e.g. content scrolling under the titlebar) the true top scroll position
        // is `-insets.top`, not 0 — scrolling to 0 stops a fraction of a row short. Account for insets at
        // both ends, and size a page off the *visible* height (clip minus insets).
        let minY = -insets.top
        let maxY = max(minY, docHeight + insets.bottom - clipH)
        let visibleH = max(0, clipH - insets.top - insets.bottom)
        // Overlap ~one row's worth so content at the seam stays visible across a page jump.
        let page = visibleH * 0.9
        var y = clip.bounds.origin.y

        switch kind {
        case .top: y = minY
        case .bottom: y = maxY
        case .pageUp: y = max(minY, y - page)
        case .pageDown: y = min(maxY, y + page)
        }

        let target = NSPoint(x: clip.bounds.origin.x, y: y)
        clip.scroll(to: target)
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: - Locating the scroll view

    private static func locateScrollView(from view: NSView, mode: Mode) -> NSScrollView? {
        switch mode {
        case .grid:
            // The handler sits inside the grid's scroll document; walk up to the enclosing scroll view.
            var current: NSView? = view.superview
            while let v = current {
                if let sv = v as? NSScrollView { return sv }
                current = v.superview
            }
            return nil
        case .list:
            // The handler is a sibling of the Table; find the table with the most rows (the video list,
            // not the sidebar) and use its enclosing scroll view.
            guard let content = view.window?.contentView else { return nil }
            return tableWithMostRows(in: content)?.enclosingScrollView
        }
    }

    private static func tableWithMostRows(in view: NSView) -> NSTableView? {
        var best: NSTableView?
        var bestRows = -1
        func search(_ v: NSView) {
            if let tv = v as? NSTableView, tv.numberOfRows > bestRows {
                best = tv
                bestRows = tv.numberOfRows
            }
            for sub in v.subviews { search(sub) }
        }
        search(view)
        return best
    }
}
