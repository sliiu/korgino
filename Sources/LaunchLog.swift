import AppKit
import Foundation
import os

/// 启动链路的逐行记录。
///
/// 「macOS 15 上只有 Dock 图标、菜单栏没有图标」这类问题只在别人的机器上出现，
/// 所以启动的每一步都落一行到磁盘：卡在哪一步，看最后一行就知道。
///
/// 文件：`~/Library/Logs/Korgino/launch.log`，超过 2 MB 时上一份改名 `launch.1.log`。
/// 统一日志：`log show --last 10m --predicate 'subsystem == "com.sliiu.Korgino"' --info`
///
/// 不要把设置值写进来：日志会被用户转给别人。
enum LaunchLog {
    static let startedAt = Date()

    private static let logger = Logger(subsystem: "com.sliiu.Korgino", category: "launch")
    private static let lock = NSLock()
    private static var didBegin = false
    private static var launched = false

    private static let directory = FileManager.default
        .urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Korgino", isDirectory: true)

    static var fileURL: URL { directory.appendingPathComponent("launch.log") }

    /// 一次启动的开头：环境、包版本、Info.plist 里的决定项，以及上一次运行的最后一行。
    /// 上一行是坏的（进程卡死或崩溃）时，那一行就是断点。
    static func begin() {
        guard !didBegin else { return }
        didBegin = true
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let previous = tail(of: fileURL)
        rotateIfNeeded()

        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let args = CommandLine.arguments.dropFirst().joined(separator: " ")
        write("""
        ===== launch pid=\(ProcessInfo.processInfo.processIdentifier) \
        version=\(version)(\(build)) bundle=\(bundle.bundlePath) \
        os=\(os.majorVersion).\(os.minorVersion).\(os.patchVersion) arch=\(arch) \
        LSUIElement=\(rawPlistValue("LSUIElement")) args=\(args.isEmpty ? "-" : args)
        """)
        if let previous { write("previous run ended with: \(previous)") }
        startWatchdog()
    }

    /// `applicationDidFinishLaunching` 走完才算启动成功。退出前没走到就记一行。
    static func markLaunched() {
        lock.lock()
        let already = launched
        launched = true
        lock.unlock()
        guard !already else { return }
        write("launch complete")
    }

    /// 主线程卡住时，应用窗口已经在了（Dock/启动动画结束），菜单栏却还没有图标，
    /// 而卡住的那一行永远等不到它的 `✓`。这条由后台线程在 10 秒后补上结论。
    private static func startWatchdog(after seconds: TimeInterval = 10) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) {
            lock.lock()
            let done = launched
            lock.unlock()
            guard !done else { return }
            write("WATCHDOG: applicationDidFinishLaunching has not completed after \(Int(seconds))s — main thread is blocked")
        }
    }

    static func log(_ message: String) {
        write(message)
    }

    /// 跑一段初始化并给它计时。先写 `→` 再执行：卡住时最后一行的箭头就是卡住的那一步。
    static func step<T>(_ name: String, _ body: () -> T) -> T {
        write("→ \(name)")
        let t0 = Date()
        let out = body()
        write("✓ \(name) \(ms(since: t0))")
        return out
    }

    static func ms(since t0: Date) -> String {
        String(format: "%.1fms", Date().timeIntervalSince(t0) * 1000)
    }

    static func policyName(_ p: NSApplication.ActivationPolicy) -> String {
        switch p {
        case .regular: return "regular"
        case .accessory: return "accessory"
        case .prohibited: return "prohibited"
        @unknown default: return "unknown(\(p.rawValue))"
        }
    }

    /// 状态栏项的真实状态。`variableLength` + 空图 + `.imageOnly` 会得到一个零宽、看不见的按钮；
    /// 进程活着、菜单栏上却没东西时，只能靠这些数值分辨是「没建」还是「建了但看不见」。
    static func statusItem(_ item: NSStatusItem?, label: String) {
        guard let item else {
            write("status[\(label)]: item=nil policy=\(policyName(NSApp.activationPolicy()))")
            return
        }
        let b = item.button
        let window = b?.window
        let frame = window?.frame ?? .zero
        let onScreen = !frame.isEmpty && NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
        write("""
        status[\(label)]: visible=\(item.isVisible) button=\(b != nil) \
        frame=\(fmt(b?.frame)) window=\(window != nil) windowVisible=\(window?.isVisible ?? false) \
        onScreen=\(onScreen) image=\(b?.image != nil) imageSize=\(fmt(b?.image?.size)) \
        title=\(b?.title ?? "") policy=\(policyName(NSApp.activationPolicy())) \
        screens=\(NSScreen.screens.count)
        """)
        if let size = b?.image?.size, size.width <= 0 || size.height <= 0 {
            write("status[\(label)]: WARNING image has zero size — the menu bar item is invisible")
        }
    }

    // MARK: - 落盘

    private static func write(_ message: String) {
        let elapsed = String(format: "+%.3fs", Date().timeIntervalSince(startedAt))
        let line = "[\(stamp()) \(elapsed) \(Thread.isMainThread ? "main" : "bg")] \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        if let data = line.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
        logger.info("\(line, privacy: .public)")
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func stamp() -> String { stampFormatter.string(from: Date()) }

    private static func rotateIfNeeded() {
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attrs?[.size] as? Int) ?? 0
        guard size > 2 * 1024 * 1024 else { return }
        let old = directory.appendingPathComponent("launch.1.log")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: fileURL, to: old)
    }

    /// 文件末尾最后一行非空内容，够判断上次停在哪。
    private static func tail(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > 4096 ? size - 4096 : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard let last = lines.last else { return nil }
        return String(last.suffix(400))
    }

    // MARK: - 环境

    private static var arch: String {
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }

    private static func rawPlistValue(_ key: String) -> String {
        guard let v = Bundle.main.object(forInfoDictionaryKey: key) else { return "missing" }
        return String(describing: v)
    }

    private static func fmt(_ r: CGRect?) -> String {
        guard let r else { return "-" }
        return String(format: "%.0f,%.0f %.0fx%.0f", r.origin.x, r.origin.y, r.width, r.height)
    }

    private static func fmt(_ s: NSSize?) -> String {
        guard let s else { return "-" }
        return String(format: "%.0fx%.0f", s.width, s.height)
    }
}
