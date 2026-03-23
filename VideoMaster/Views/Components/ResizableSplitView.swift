import AppKit
import SwiftUI

/// A 3-column split view (sidebar | content | detail) with programmatically controllable divider positions.
/// During playback the content pane is frozen at its current width and clipped by the split view container.
struct ResizableSplitView<Sidebar: View, Content: View, Detail: View>: NSViewRepresentable {
    let sidebarWidth: CGFloat
    let contentWidth: CGFloat
    let detailWidth: CGFloat
    let sidebarID: AnyHashable
    let contentID: AnyHashable
    let detailID: AnyHashable
    let freezeContent: Bool
    let onSizesChanged: (CGFloat, CGFloat, CGFloat) -> Void
    let sidebar: () -> Sidebar
    let content: () -> Content
    let detail: () -> Detail

    func makeNSView(context: Context) -> NSSplitView {
        let splitView = NSSplitView()
        splitView.dividerStyle = .thin
        splitView.isVertical = true
        splitView.delegate = context.coordinator

        let sidebarHost = NSHostingView(rootView: sidebar())
        let contentHost = NSHostingView(rootView: content())
        let detailHost = NSHostingView(rootView: detail())

        sidebarHost.translatesAutoresizingMaskIntoConstraints = false
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

        splitView.addArrangedSubview(sidebarHost)
        splitView.addArrangedSubview(contentContainer)
        splitView.addArrangedSubview(detailHost)

        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 2)

        context.coordinator.splitView = splitView
        context.coordinator.contentContainer = contentContainer
        context.coordinator.onSizesChanged = onSizesChanged
        context.coordinator.lastSidebarID = sidebarID
        context.coordinator.lastContentID = contentID
        context.coordinator.lastDetailID = detailID

        return splitView
    }

    func updateNSView(_ splitView: NSSplitView, context: Context) {
        context.coordinator.onSizesChanged = onSizesChanged
        let coord = context.coordinator

        let subviews = splitView.arrangedSubviews
        guard subviews.count >= 3 else { return }

        // Manage freeze/unfreeze transitions
        if freezeContent, let container = coord.contentContainer, !container.isFrozen {
            splitView.layoutSubtreeIfNeeded()
            container.layoutSubtreeIfNeeded()
            if let hosted = container.subviews.first {
                hosted.layoutSubtreeIfNeeded()
            }
            coord.browsingDividerPositions = (subviews[0].frame.width, subviews[1].frame.width)
            container.freeze()
            // Move dividers to remembered playback positions after layout settles
            if let (savedSidebar, savedContent) = coord.playbackDividerPositions {
                DispatchQueue.main.async { [weak coord, weak splitView] in
                    guard let coord, let splitView else { return }
                    coord.isProgrammaticResize = true
                    splitView.setPosition(savedSidebar, ofDividerAt: 0)
                    splitView.setPosition(savedSidebar + savedContent, ofDividerAt: 1)
                    coord.isProgrammaticResize = false
                }
            }
        } else if !freezeContent, let container = coord.contentContainer, container.isFrozen {
            container.unfreeze()
            // Restore divider positions to browsing state after layout settles
            if let (savedSidebar, savedContent) = coord.browsingDividerPositions {
                DispatchQueue.main.async { [weak coord, weak splitView] in
                    guard let coord, let splitView else { return }
                    coord.isProgrammaticResize = true
                    splitView.setPosition(savedSidebar, ofDividerAt: 0)
                    splitView.setPosition(savedSidebar + savedContent, ofDividerAt: 1)
                    coord.isProgrammaticResize = false
                }
            }
            coord.browsingDividerPositions = nil
        }

        // Sidebar and content rootViews are not updated while frozen.
        if !freezeContent {
            if let sidebarHost = subviews[0] as? NSHostingView<Sidebar>, coord.lastSidebarID != sidebarID {
                coord.lastSidebarID = sidebarID
                sidebarHost.rootView = sidebar()
            }
            if let container = subviews[1] as? ClippingContainer,
               let contentHost = container.subviews.first as? NSHostingView<Content>,
               coord.lastContentID != contentID
            {
                coord.lastContentID = contentID
                contentHost.rootView = content()
            }
        }
        // Detail always updates (player controls etc.)
        if let detailHost = subviews[2] as? NSHostingView<Detail>, coord.lastDetailID != detailID {
            coord.lastDetailID = detailID
            detailHost.rootView = detail()
        }

        // Only move dividers when not frozen
        guard !freezeContent else { return }

        let totalWidth = splitView.bounds.width
        guard totalWidth > 0 else { return }

        let s = min(max(sidebarWidth, 120), totalWidth - 200)
        let c = min(max(contentWidth, 80), totalWidth - s - 200)

        let currentSidebar = subviews[0].frame.width
        let currentContent = subviews[1].frame.width

        if abs(currentSidebar - s) > 2 || abs(currentContent - c) > 2 {
            coord.isProgrammaticResize = true
            splitView.setPosition(s, ofDividerAt: 0)
            splitView.setPosition(s + c, ofDividerAt: 1)
            coord.isProgrammaticResize = false
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, NSSplitViewDelegate {
        weak var splitView: NSSplitView?
        fileprivate weak var contentContainer: ClippingContainer?
        var onSizesChanged: ((CGFloat, CGFloat, CGFloat) -> Void)?
        var lastSidebarID: AnyHashable?
        var lastContentID: AnyHashable?
        var lastDetailID: AnyHashable?
        var isProgrammaticResize = false
        /// Saved divider positions when entering playback, restored on RTB.
        var browsingDividerPositions: (CGFloat, CGFloat)?
        /// Remembered playback divider positions (user-dragged during playback). Persisted via UserDefaults.
        var playbackDividerPositions: (CGFloat, CGFloat)? = {
            let defaults = UserDefaults.standard
            let s = defaults.double(forKey: "playbackDividerSidebar")
            let c = defaults.double(forKey: "playbackDividerContent")
            guard s > 0, c > 0 else { return nil }
            return (CGFloat(s), CGFloat(c))
        }()

        func splitViewDidResizeSubviews(_ notification: Notification) {
            guard !isProgrammaticResize else { return }
            guard let sv = notification.object as? NSSplitView, sv.arrangedSubviews.count >= 3 else { return }
            let subviews = sv.arrangedSubviews
            let sidebarW = subviews[0].frame.width
            let contentW = subviews[1].frame.width
            let detailW = subviews[2].frame.width
            if contentContainer?.isFrozen == true {
                // During playback: remember divider positions for next playback session
                playbackDividerPositions = (sidebarW, contentW)
                UserDefaults.standard.set(Double(sidebarW), forKey: "playbackDividerSidebar")
                UserDefaults.standard.set(Double(contentW), forKey: "playbackDividerContent")
                return
            }
            let finite = sidebarW.isFinite && contentW.isFinite && detailW.isFinite
            let reasonable = sidebarW < 8000 && contentW < 8000 && detailW < 8000
            if finite, reasonable, sidebarW > 80, contentW > 50, detailW > 100 {
                onSizesChanged?(sidebarW, contentW, detailW)
            }
        }

        func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt index: Int) -> CGFloat {
            switch index {
            case 0: return 120
            case 1: return splitView.arrangedSubviews[0].frame.width + 80
            default: return proposedMinimumPosition
            }
        }

        func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt index: Int) -> CGFloat {
            let total = splitView.bounds.width
            switch index {
            case 0: return total - 200
            case 1: return total - 200
            default: return proposedMaximumPosition
            }
        }
    }
}
