import AppKit

/// 浮层摆放共用的小工具。
///
/// 划词浮层、插件条、快捷翻译都用同一套换算和收边规则，以前各写一遍。
/// 这里只收「几何」和「出现」两件事；每块浮层自己决定贴哪、往上还是往下。
enum OverlayPlacement {
    /// 辅助功能坐标（主屏左上角为原点、y 向下）换成 AppKit 的屏幕坐标（左下角为原点、y 向上）。
    static func onScreen(_ axRect: CGRect, primary: NSRect? = nil) -> NSRect {
        let base = primary ?? NSScreen.screens.first?.frame ?? .zero
        return NSRect(
            x: axRect.minX,
            y: base.maxY - axRect.maxY,
            width: axRect.width,
            height: axRect.height
        )
    }

    /// 这块矩形落在哪块屏幕上。跨屏时挑第一块真正相交的。
    static func screen(containing rect: NSRect) -> NSScreen? {
        NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main
    }

    /// 把窗口框推进屏幕可用区。原本就放得下时一动不动。
    static func keepInsideScreen(_ frame: inout NSRect, visible: NSRect) {
        if frame.minY < visible.minY { frame.origin.y = visible.minY }
        if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - frame.height }
        if frame.maxX > visible.maxX { frame.origin.x = visible.maxX - frame.width }
        if frame.minX < visible.minX { frame.origin.x = visible.minX }
    }

    /// 0.12 秒淡入。两块浮层用同一个时长，切换时才不显得一下一下地跳。
    static func fadeIn(_ panel: NSWindow) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }
}
