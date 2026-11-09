import AppKit

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
        if scroll.scrollerStyle != .overlay { scroll.scrollerStyle = .overlay }
        if !scroll.autohidesScrollers { scroll.autohidesScrollers = true }
        for s in [scroll.verticalScroller, scroll.horizontalScroller].compactMap({ $0 }) {
            if s.controlSize != .mini { s.controlSize = .mini }
            if s.scrollerStyle != .overlay { s.scrollerStyle = .overlay }
        }
    }
}
