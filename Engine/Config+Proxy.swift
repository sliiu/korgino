import Foundation

/// Proxy: part of AppConfig.
extension AppConfig {
    /// Typing a host or password publishes per keystroke; rebuild the session once typing pauses.
    /// 主文件里代理字段的 didSet 会调它。
    func notifyProxyChange() {
        guard proxyReady else { return }
        proxyReload?.cancel()
        let work = DispatchWorkItem { NetSession.reload() }
        proxyReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
}
