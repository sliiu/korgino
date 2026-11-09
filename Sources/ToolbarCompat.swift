import SwiftUI

/// `sharedBackgroundVisibility` 是 macOS 26 才有的工具栏修饰符，而部署目标要照顾更老的系统。
/// 26 上照旧隐藏共享背景；更老的系统本来就没有这层背景，原样返回即可。
extension ToolbarContent {
    @ToolbarContentBuilder
    func korgiHideToolbarBackground() -> some ToolbarContent {
        if #available(macOS 26.0, *) {
            self.sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}
