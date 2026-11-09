import AppKit

/// 浮层和工具栏共用的 `NSPanel` 配置。
///
/// 这几块面板都是「不抢焦点、跟着所有桌面、透明底」，但以前每个文件各写一遍，
/// 参数慢慢就有了细微差别。这里只收公共的那几项；标题、尺寸、内容视图和
/// 定位留在调用点，因为每块面板的摆放规则不同。
@MainActor
enum OverlayPanel {
    enum Style {
        /// 划词插件条这类悬浮条：不透明度透明、阴影靠内容自己。
        case floating
        /// 实时字幕、沉浸字幕：更低的窗口层级，不抢焦点。
        case caption
        /// 置顶、带阴影、可拖动的沉浸字幕。
        case immersive
    }

    static func make(
        contentRect: NSRect,
        style: Style,
        content: NSView,
        deferCreation: Bool = false
    ) -> NSPanel {
        let made = NSPanel(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: deferCreation
        )
        made.isReleasedWhenClosed = false
        made.hidesOnDeactivate = false
        made.isOpaque = false
        made.backgroundColor = .clear
        switch style {
        case .floating:
            made.level = .floating
            made.hasShadow = false
            made.isMovable = false
            made.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
            made.becomesKeyOnlyIfNeeded = true
        case .caption:
            made.level = .floating
            made.hasShadow = true
            made.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        case .immersive:
            made.level = NSWindow.Level(Int(CGWindowLevelForKey(.statusWindow)))
            made.hasShadow = true
            made.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            made.isFloatingPanel = true
            made.becomesKeyOnlyIfNeeded = true
            made.isMovableByWindowBackground = true
            made.acceptsMouseMovedEvents = true
        }
        made.contentView = content
        return made
    }
}
