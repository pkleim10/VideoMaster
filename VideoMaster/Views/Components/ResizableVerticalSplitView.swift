import AppKit
import SwiftUI

/// Vertical stack split: **top** (list/grid) | **bottom** (filter strip). Divider is horizontal.
/// Heights persist via `LayoutParams.browserTopPaneHeight{Grid,List}` → `updateCurrentLayoutWithSizes(browserTopPaneHeight:)`.
struct ResizableVerticalSplitView<Top: View, Bottom: View>: NSViewRepresentable {
    /// When this changes (e.g. grid ↔ list), reset applied-height tracking so the correct mode’s saved height applies.
    let layoutModeKey: String
    let topPaneHeight: CGFloat
    let topID: AnyHashable
    let bottomID: AnyHashable
    let onTopHeightChanged: (CGFloat) -> Void
    let top: () -> Top
    let bottom: () -> Bottom

    func makeNSView(context: Context) -> NSSplitView {
        let splitView = NSSplitView()
        splitView.dividerStyle = .thin
        splitView.isVertical = false
        splitView.delegate = context.coordinator

        let topHost = NSHostingView(rootView: top())
        let bottomHost = NSHostingView(rootView: bottom())

        topHost.translatesAutoresizingMaskIntoConstraints = false
        bottomHost.translatesAutoresizingMaskIntoConstraints = false

        splitView.addArrangedSubview(topHost)
        splitView.addArrangedSubview(bottomHost)

        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)

        context.coordinator.splitView = splitView
        context.coordinator.onTopHeightChanged = onTopHeightChanged
        context.coordinator.lastTopID = topID
        context.coordinator.lastBottomID = bottomID
        context.coordinator.lastLayoutModeKey = layoutModeKey

        return splitView
    }

    func updateNSView(_ splitView: NSSplitView, context: Context) {
        context.coordinator.onTopHeightChanged = onTopHeightChanged
        let coord = context.coordinator

        coord.syncLayoutModeKey(layoutModeKey)

        let subviews = splitView.arrangedSubviews
        guard subviews.count >= 2 else { return }

        if let topHost = subviews[0] as? NSHostingView<Top> {
            if coord.lastTopID != topID {
                coord.lastTopID = topID
            }
            topHost.rootView = top()
        }
        if let bottomHost = subviews[1] as? NSHostingView<Bottom> {
            if coord.lastBottomID != bottomID {
                coord.lastBottomID = bottomID
            }
            bottomHost.rootView = bottom()
        }

        let totalHeight = splitView.bounds.height
        if totalHeight <= 0 {
            DispatchQueue.main.async { [weak coord, weak splitView] in
                guard let coord, let splitView else { return }
                splitView.layoutSubtreeIfNeeded()
                let th = splitView.bounds.height
                guard th > 0 else { return }
                coord.applyModelTopHeightIfNeeded(
                    topPaneHeight: topPaneHeight,
                    totalHeight: th,
                    splitView: splitView
                )
            }
            return
        }

        coord.applyModelTopHeightIfNeeded(
            topPaneHeight: topPaneHeight,
            totalHeight: totalHeight,
            splitView: splitView
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, NSSplitViewDelegate {
        weak var splitView: NSSplitView?
        var onTopHeightChanged: ((CGFloat) -> Void)?
        var lastTopID: AnyHashable?
        var lastBottomID: AnyHashable?
        var lastLayoutModeKey: String?
        var isProgrammaticResize = false
        /// Last `topPaneHeight` we applied from `LayoutParams` (avoids fighting user drags).
        fileprivate var lastAppliedTopPaneHeightFromModel: CGFloat?

        /// After first `setPosition` from saved layout; until then, ignore spurious resize notifications on launch.
        private var hasAppliedInitialTopHeight = false

        fileprivate func syncLayoutModeKey(_ key: String) {
            if lastLayoutModeKey != key {
                lastLayoutModeKey = key
                lastAppliedTopPaneHeightFromModel = nil
                hasAppliedInitialTopHeight = false
            }
        }

        func splitViewDidResizeSubviews(_ notification: Notification) {
            guard !isProgrammaticResize else { return }
            guard let sv = notification.object as? NSSplitView, sv.arrangedSubviews.count >= 2 else { return }
            let topH = sv.arrangedSubviews[0].frame.height
            let bottomH = sv.arrangedSubviews[1].frame.height
            let total = sv.bounds.height
            guard hasAppliedInitialTopHeight else { return }
            let finite = topH.isFinite && bottomH.isFinite
            let reasonable = topH < 8000 && bottomH < 8000
            if finite, reasonable, total > 0, topH > 40, bottomH > 24 {
                onTopHeightChanged?(topH)
            }
        }

        func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt index: Int) -> CGFloat {
            switch index {
            case 0: return 100
            default: return proposedMinimumPosition
            }
        }

        func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt index: Int) -> CGFloat {
            let total = splitView.bounds.height
            switch index {
            case 0: return total - 80
            default: return proposedMaximumPosition
            }
        }

        fileprivate func applyModelTopHeightIfNeeded(
            topPaneHeight: CGFloat,
            totalHeight: CGFloat,
            splitView: NSSplitView
        ) {
            let clamped = min(max(topPaneHeight, 100), totalHeight - 80)
            let shouldApply: Bool
            if let prev = lastAppliedTopPaneHeightFromModel {
                shouldApply = abs(prev - clamped) > 0.5
            } else {
                shouldApply = true
            }
            guard shouldApply else { return }
            lastAppliedTopPaneHeightFromModel = clamped
            isProgrammaticResize = true
            splitView.setPosition(clamped, ofDividerAt: 0)
            isProgrammaticResize = false
            hasAppliedInitialTopHeight = true
        }
    }
}
