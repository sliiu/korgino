import AppKit
import SwiftUI

/// App-wide chrome: thin overlay scrollbars on every window / scroll view.
enum UIChrome {
    private static var observing = false
    private static var lastSweep = Date.distantPast

    static func apply() {
        startObservingWindowsIfNeeded()
        thinAllWindows()
    }

    private static func startObservingWindowsIfNeeded() {
        guard !observing else { return }
        observing = true
        let nc = NotificationCenter.default
        for name in [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSApplication.didBecomeActiveNotification,
        ] {
            nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                thinAllWindows()
            }
        }
        nc.addObserver(forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, queue: .main) { _ in
            DispatchQueue.main.async { thinAllWindows() }
        }
        nc.addObserver(forName: NSWindow.didUpdateNotification, object: nil, queue: .main) { note in
            guard Date().timeIntervalSince(lastSweep) > 0.5, let w = note.object as? NSWindow else { return }
            lastSweep = Date()
            thin(in: w.contentView)
        }
    }

    static func thinAllWindows() {
        for w in NSApp.windows {
            thin(in: w.contentView)
        }
    }

    static func thin(in root: NSView?) {
        guard let root else { return }
        if let scroll = root as? NSScrollView {
            configure(scroll)
        }
        for sub in root.subviews {
            thin(in: sub)
        }
    }

    static func configure(_ scroll: NSScrollView) {
        if scroll.identifier == menuScrollerID {
            pinMenuScroller(scroll)
            return
        }
        if scroll.scrollerStyle != .overlay { scroll.scrollerStyle = .overlay }
        if !scroll.autohidesScrollers { scroll.autohidesScrollers = true }
        for s in [scroll.verticalScroller, scroll.horizontalScroller].compactMap({ $0 }) {
            if s.controlSize != .mini { s.controlSize = .mini }
            if s.scrollerStyle != .overlay { s.scrollerStyle = .overlay }
        }
    }

    static let menuScrollerID = NSUserInterfaceItemIdentifier("korgi.menuScroll")

    /// 长菜单的滚动条一直在。系统 overlay 不滚就消失，这里用细的旧式滚动条。
    static func pinMenuScroller(_ scroll: NSScrollView) {
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = false
        scroll.scrollerStyle = .legacy
        scroll.drawsBackground = false
        if let bar = scroll.verticalScroller {
            if bar.controlSize != .mini { bar.controlSize = .mini }
            if bar.scrollerStyle != .legacy { bar.scrollerStyle = .legacy }
            if bar.alphaValue != 1 { bar.alphaValue = 1 }
        }
    }
}

/// 标出菜单自己的滚动视图，免得全局把滚动条改成悬停才出现。
/// 包一层 View 才能放进 background / overlay：NSViewRepresentable 直接当背景用，编译器配不上。
struct MenuScrollAnchor: View {
    var pinned: Bool

    var body: some View {
        MenuScrollBar(pinned: pinned)
    }
}

private struct MenuScrollBar: NSViewRepresentable {
    var pinned: Bool

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.pinned = pinned
        guard !context.coordinator.scheduled else { return }
        context.coordinator.scheduled = true
        DispatchQueue.main.async {
            context.coordinator.scheduled = false
            guard nsView.window != nil, let scroll = nsView.enclosingScrollView else { return }
            if context.coordinator.pinned {
                scroll.identifier = UIChrome.menuScrollerID
                UIChrome.pinMenuScroller(scroll)
            } else if scroll.identifier == UIChrome.menuScrollerID {
                scroll.identifier = nil
                UIChrome.configure(scroll)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var pinned = false
        var scheduled = false
    }
}
