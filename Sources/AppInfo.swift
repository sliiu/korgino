import AppKit
import Foundation

enum AppInfo {
    static var shortVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
            ?? "0"
    }

    static var build: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
            ?? (Bundle.main.infoDictionary?["CFBundleVersion"] as? String)
            ?? "0"
    }

    static var menuVersion: String { "v\(shortVersion)" }

    static var fullVersion: String { "\(shortVersion) (\(build))" }

    /// GitHub Releases source for the direct channel. Empty = local stub.
    static let githubReleasesRepo = "sliiu/korgino"

    static var releasesPageURL: URL? {
        let repo = githubReleasesRepo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repo.isEmpty else { return nil }
        return URL(string: "https://github.com/\(repo)/releases")
    }

    static let xProfileURL = URL(string: "https://x.com/irvinglove0302")!

    static var weChatQR: NSImage? {
        guard let url = Bundle.main.url(forResource: "WeChatQR", withExtension: "jpg") else { return nil }
        return NSImage(contentsOf: url)
    }
}

@MainActor
enum UpdateChecker {
    enum Outcome {
        case upToDate(current: String)
        case available(latest: String, current: String, pageURL: URL?)
        case unavailable(reason: String, current: String)
    }

    static func check() async -> Outcome {
        let current = AppInfo.shortVersion
        guard Pro.channel == .direct else {
            return .unavailable(reason: L("商店包的更新只走 App Store。"), current: current)
        }
        let repo = AppInfo.githubReleasesRepo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repo.isEmpty else {
            return .unavailable(
                reason: L("尚未配置在线更新源。当前为本地安装版本，发布到 GitHub Releases 后即可自动检查。"),
                current: current
            )
        }
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            return .unavailable(reason: L("更新地址无效。"), current: current)
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Korgino/\(current)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                if code == 404 {
                    return .unavailable(reason: L("未找到发布版本（仓库尚无 Release）。"), current: current)
                }
                return .unavailable(reason: String(format: L("检查更新失败（HTTP %@）。"), String(describing: code)), current: current)
            }
            let tag = ((json["tag_name"] as? String) ?? "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            guard !tag.isEmpty else {
                return .unavailable(reason: L("无法解析最新版本号。"), current: current)
            }
            if compareVersions(tag, current) > 0 {
                let html = json["html_url"] as? String
                return .available(
                    latest: tag,
                    current: current,
                    pageURL: html.flatMap(URL.init(string:)) ?? AppInfo.releasesPageURL
                )
            }
            return .upToDate(current: current)
        } catch {
            return .unavailable(reason: String(format: L("网络错误：%@"), String(describing: error.localizedDescription)), current: current)
        }
    }

    /// Present a standard alert for the outcome.
    static func presentResult(_ outcome: Outcome, from window: NSWindow? = nil) {
        let alert = NSAlert()
        switch outcome {
        case .upToDate(let current):
            alert.messageText = L("已是最新版本")
            alert.informativeText = String(format: L("当前版本 %@。"), String(describing: current))
            alert.addButton(withTitle: L("好"))
        case .available(let latest, let current, let pageURL):
            alert.messageText = String(format: L("发现新版本 %@"), String(describing: latest))
            alert.informativeText = String(format: L("当前版本 %@。可前往发布页下载更新。"), String(describing: current))
            alert.addButton(withTitle: L("打开发布页"))
            alert.addButton(withTitle: L("稍后"))
            let resp = run(alert, window: window)
            if resp == .alertFirstButtonReturn, let pageURL {
                NSWorkspace.shared.open(pageURL)
            }
            return
        case .unavailable(let reason, let current):
            alert.messageText = L("检查更新")
            alert.informativeText = String(format: L("当前版本 %@。\n\n%@"), String(describing: current), String(describing: reason))
            if AppInfo.releasesPageURL != nil {
                alert.addButton(withTitle: L("打开发布页"))
                alert.addButton(withTitle: L("好"))
                let resp = run(alert, window: window)
                if resp == .alertFirstButtonReturn, let u = AppInfo.releasesPageURL {
                    NSWorkspace.shared.open(u)
                }
                return
            }
            alert.addButton(withTitle: L("好"))
        }
        _ = run(alert, window: window)
    }

    static func showAbout(from window: NSWindow? = nil) {
        let alert = NSAlert()
        alert.messageText = "Korgino"
        alert.informativeText = String(format: L("版本 %@\n\n划词 / OCR / 文件翻译\n⌘, 打开偏好设置"), AppInfo.fullVersion)
        alert.addButton(withTitle: L("好"))
        _ = run(alert, window: window)
    }

    private static func run(_ alert: NSAlert, window: NSWindow?) -> NSApplication.ModalResponse {
        if let window, window.isVisible {
            return alert.runModal() // sheet would need beginSheet; keep simple modal
        }
        return alert.runModal()
    }

    /// Compare dotted version strings. Returns >0 if a > b.
    private static func compareVersions(_ a: String, _ b: String) -> Int {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        let n = max(pa.count, pb.count)
        for i in 0..<n {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y ? 1 : -1 }
        }
        return 0
    }
}
