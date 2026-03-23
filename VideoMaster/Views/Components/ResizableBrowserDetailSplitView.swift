import AppKit
import SwiftUI

/// Two-column split: **browser** (list/grid + optional inner layout) | **detail**.
/// Same freeze/clipping behavior as `ResizableSplitView` for inline playback on the browser column.
struct ResizableBrowserDetailSplitView<Content: View, Detail: View>: NSViewRepresentable {
    /// When this changes (e.g. grid ↔ list), reset applied-width tracking so the correct mode’s saved width applies.
    let layoutModeKey: String
    let contentWidth: CGFloat
    let detailWidth: CGFloat
    let contentID: AnyHashable
    let detailID: AnyHashable
    let freezeContent: Bool
    let onSizesChanged: (CGFloat, CGFloat) -> Void
    let content: () -> Content
    let detail: () -> Detail

    func makeNSView(context: Context) -> NSSplitView {
        let splitView = NSSplitView()
        splitView.dividerStyle = .thin
        splitView.isVertical = true
        splitView.delegate = context.coordinator

        let contentHost = NSHostingView(rootView: content())
        let detailHost = NSHostingView(rootView: detail())

        detailHost.translatesAutoresizingMaskIntoConstraints = false

        let contentContainer = ClippingContainer()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentHost.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(contentHost)
        NSLayoutConstraint.activate([
            contentHost.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            contentHost.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            contentHost.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])

        splitView.addArrangedSubview(contentContainer)
        splitView.addArrangedSubview(detailHost)

        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)

        context.coordinator.splitView = splitView
        context.coordinator.contentContainer = contentContainer
        context.coordinator.onSizesChanged = onSizesChanged
        context.coordinator.lastContentID = contentID
        context.coordinator.lastDetailID = detailID
        context.coordinator.lastLayoutModeKey = layoutModeKey

        return splitView
    }

    func updateNSView(_ splitView: NSSplitView, context: Context) {
        context.coordinator.onSizesChanged = onSizesChanged
        let coord = context.coordinator

        coord.syncLayoutModeKey(layoutModeKey)

        let subviews = splitView.arrangedSubviews
        guard subviews.count >= 2 else { return }

        // Freeze / unfreeze browser column during inline playback
        if freezeContent, let container = coord.contentContainer, !container.isFrozen {
            splitView.layoutSubtreeIfNeeded()
            container.layoutSubtreeIfNeeded()
            if let hosted = container.subviews.first {
                hosted.layoutSubtreeIfNeeded()
            }
            // Width to restore on exit (pre-playback column size), before any playback divider snap.
            coord.browsingDividerPosition = subviews[0].frame.width
            // Match exit path: apply saved playback divider synchronously, then freeze — avoids
            // freeze-then-async setPosition (two visible steps when entering play mode).
            let totalW = splitView.bounds.width
            if totalW > 0, let savedBrowser = coord.playbackDividerPositions?.browser {
                let clamped = min(max(savedBrowser, 80), totalW - 200)
                coord.isProgrammaticResize = true
                splitView.setPosition(clamped, ofDividerAt: 0)
                coord.isProgrammaticResize = false
                splitView.layoutSubtreeIfNeeded()
                container.layoutSubtreeIfNeeded()
                if let hosted = container.subviews.first {
                    hosted.layoutSubtreeIfNeeded()
                }
            }
            container.freeze()
        } else if !freezeContent, let container = coord.contentContainer, container.isFrozen {
            // Restore the browsing column width synchronously when possible, and sync
            // `lastAppliedContentWidthFromModel` so `applyModelBrowserWidthIfNeeded` below
            // does not issue a second `setPosition` (avoids visible jerk on exit play mode).
            let savedWidth = coord.browsingDividerPosition
            let totalW = splitView.bounds.width
            if let savedWidth {
                if totalW > 0 {
                    coord.restoreBrowserDividerAfterUnfreeze(savedWidth: savedWidth, totalWidth: totalW, splitView: splitView)
                } else {
                    DispatchQueue.main.async { [weak coord, weak splitView] in
                        guard let coord, let splitView else { return }
                        splitView.layoutSubtreeIfNeeded()
                        let tw = splitView.bounds.width
                        guard tw > 0 else { return }
                        coord.restoreBrowserDividerAfterUnfreeze(savedWidth: savedWidth, totalWidth: tw, splitView: splitView)
                    }
                }
            }
            container.unfreeze()
            coord.browsingDividerPosition = nil
        }

        if !freezeContent {
            if let container = subviews[0] as? ClippingContainer,
               let contentHost = container.subviews.first as? NSHostingView<Content>
            {
                if coord.lastContentID != contentID {
                    coord.lastContentID = contentID
                }
                contentHost.rootView = content()
            }
        }
        if let detailHost = subviews[1] as? NSHostingView<Detail>, coord.lastDetailID != detailID {
            coord.lastDetailID = detailID
            detailHost.rootView = detail()
        }

        guard !freezeContent else { return }

        let totalWidth = splitView.bounds.width
        if totalWidth <= 0 {
            DispatchQueue.main.async { [weak coord, weak splitView] in
                guard let coord, let splitView else { return }
                splitView.layoutSubtreeIfNeeded()
                let tw = splitView.bounds.width
                guard tw > 0 else { return }
                coord.applyModelBrowserWidthIfNeeded(
                    contentWidth: contentWidth,
                    totalWidth: tw,
                    splitView: splitView
                )
            }
            return
        }

        // Only move the divider when the *model* changed (initial layout, prefs load, or successful drag save).
        // Do NOT fight the live split when current frame ≠ model but the model hasn't updated yet (avoids snapping back).
        coord.applyModelBrowserWidthIfNeeded(
            contentWidth: contentWidth,
            totalWidth: totalWidth,
            splitView: splitView
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, NSSplitViewDelegate {
        weak var splitView: NSSplitView?
        fileprivate weak var contentContainer: ClippingContainer?
        var onSizesChanged: ((CGFloat, CGFloat) -> Void)?
        var lastContentID: AnyHashable?
        var lastDetailID: AnyHashable?
        var lastLayoutModeKey: String?
        var isProgrammaticResize = false
        /// Last `contentWidth` we applied from `LayoutParams` (avoids reverting user drags when the model lags).
        fileprivate var lastAppliedContentWidthFromModel: CGFloat?
        /// After first `setPosition` from saved layout; until then, ignore `splitViewDidResizeSubviews` so default 50/50 layout doesn't persist over loaded `LayoutParams`.
        private var hasAppliedInitialBrowserWidth = false
        var browsingDividerPosition: CGFloat?
        var playbackDividerPositions: (browser: CGFloat, detail: CGFloat)? = {
            let defaults = UserDefaults.standard
            let b = defaults.double(forKey: "playbackDividerSidebar")
            let d = defaults.double(forKey: "playbackDividerContent")
            guard b > 0, d > 0 else { return nil }
            return (CGFloat(b), CGFloat(d))
        }()

        func splitViewDidResizeSubviews(_ notification: Notification) {
            guard !isProgrammaticResize else { return }
            guard let sv = notification.object as? NSSplitView, sv.arrangedSubviews.count >= 2 else { return }
            let subviews = sv.arrangedSubviews
            let browserW = subviews[0].frame.width
            let detailW = subviews[1].frame.width
            if contentContainer?.isFrozen == true {
                playbackDividerPositions = (browserW, detailW)
                UserDefaults.standard.set(Double(browserW), forKey: "playbackDividerSidebar")
                UserDefaults.standard.set(Double(detailW), forKey: "playbackDividerContent")
                return
            }
            guard hasAppliedInitialBrowserWidth else { return }
            let finite = browserW.isFinite && detailW.isFinite
            let reasonable = browserW < 8000 && detailW < 8000
            if finite, reasonable, browserW > 40, detailW > 40 {
                onSizesChanged?(browserW, detailW)
            }
        }

        func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt index: Int) -> CGFloat {
            switch index {
            case 0: return 80
            default: return proposedMinimumPosition
            }
        }

        func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt index: Int) -> CGFloat {
            let total = splitView.bounds.width
            switch index {
            case 0: return total - 200
            default: return proposedMaximumPosition
            }
        }

        fileprivate func syncLayoutModeKey(_ key: String) {
            if lastLayoutModeKey != key {
                lastLayoutModeKey = key
                lastAppliedContentWidthFromModel = nil
                hasAppliedInitialBrowserWidth = false
            }
        }

        /// After unfreezing the browser column, apply the saved divider width once and mark the
        /// model-applied width so we don't immediately fight it with `applyModelBrowserWidthIfNeeded`.
        fileprivate func restoreBrowserDividerAfterUnfreeze(
            savedWidth: CGFloat,
            totalWidth: CGFloat,
            splitView: NSSplitView
        ) {
            let clamped = min(max(savedWidth, 80), totalWidth - 200)
            lastAppliedContentWidthFromModel = clamped
            isProgrammaticResize = true
            splitView.setPosition(clamped, ofDividerAt: 0)
            isProgrammaticResize = false
            hasAppliedInitialBrowserWidth = true
        }

        /// Applies divider position from saved layout only when the model width actually changed.
        fileprivate func applyModelBrowserWidthIfNeeded(
            contentWidth: CGFloat,
            totalWidth: CGFloat,
            splitView: NSSplitView
        ) {
            let clamped = min(max(contentWidth, 80), totalWidth - 200)
            let shouldApply: Bool
            if let prev = lastAppliedContentWidthFromModel {
                shouldApply = abs(prev - clamped) > 0.5
            } else {
                shouldApply = true
            }
            guard shouldApply else { return }
            lastAppliedContentWidthFromModel = clamped
            isProgrammaticResize = true
            splitView.setPosition(clamped, ofDividerAt: 0)
            isProgrammaticResize = false
            hasAppliedInitialBrowserWidth = true
        }
    }
}
