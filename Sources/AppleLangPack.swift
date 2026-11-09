import AppKit
import SwiftUI
import Translation

/// Opens System Settings › General › Language & Region (Translation Languages),
/// and optionally presents Apple's TranslationSession.prepareTranslation() sheet.
enum AppleLangPack {
    static let settingsURLs: [String] = [
        "x-apple.systempreferences:com.apple.Localization-Settings.extension",
        "x-apple.systempreferences:com.apple.Localization-Settings",
        "x-apple.systempreferences:com.apple.preference.general",
    ]

    @MainActor
    static func openSystemSettings() {
        for s in settingsURLs {
            if let u = URL(string: s), NSWorkspace.shared.open(u) { return }
        }
    }

    @MainActor
    static func presentDownloadPrompt(source: String = "en", target: String = "zh-Hans", force: Bool = false) {
        DownloadHost.shared.present(source: source, target: target, force: force)
    }

    @MainActor
    static func relocalize() {
        DownloadHost.shared.relocalize()
    }
}

@MainActor
private final class DownloadHost {
    static let shared = DownloadHost()
    private var window: NSWindow?
    private var closeWatch: NSObjectProtocol?
    private var quietUntil = Date.distantPast
    private var prepareStarted = false
    private var prepareAttempts = 0

    func present(source: String, target: String, force: Bool) {
        if let window {
            if window.isVisible {
                if force {
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
                return
            }
            if let closeWatch { NotificationCenter.default.removeObserver(closeWatch) }
            closeWatch = nil
            window.orderOut(nil)
            self.window = nil
        }
        let now = Date()
        if !force, now < quietUntil { return }
        quietUntil = now.addingTimeInterval(120)
        prepareStarted = false
        prepareAttempts = 0
        let root = ApplePrepareView(sourceID: source, targetID: target) { [weak self] in
            self?.window?.orderOut(nil)
            self?.window = nil
        }
        let hosting = NSHostingView(rootView: root)
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = L("下载 Apple 翻译语言包")
        w.contentView = hosting
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.hidesOnDeactivate = false
        w.center()
        window = w
        closeWatch = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: w,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, self.window === note.object as? NSWindow else { return }
                self.window = nil
            }
        }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func claimPrepare() -> Bool {
        if prepareStarted || prepareAttempts >= 2 { return false }
        prepareStarted = true
        prepareAttempts += 1
        return true
    }

    func abandonPrepare() {
        prepareStarted = false
    }

    func relocalize() {
        window?.title = L("下载 Apple 翻译语言包")
    }
}

private struct ApplePrepareView: View {
    let sourceID: String
    let targetID: String
    var onDone: () -> Void
    @ObservedObject private var lang = AppConfig.shared
    @State private var configuration: TranslationSession.Configuration?
    @State private var status = L("正在检查语言包…")

    var body: some View {
        let _ = lang.appLanguage
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Color.accentColor)
                Text(status)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(L("打开系统设置")) { AppleLangPack.openSystemSettings() }
                Button(L("完成")) { onDone() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
        .translationTask(configuration) { session in
            let go = await MainActor.run { DownloadHost.shared.claimPrepare() }
            guard go else { return }
            do {
                try await session.prepareTranslation()
                await MainActor.run { status = L("语言包已就绪（或已弹出系统下载提示）") }
            } catch is CancellationError {
                await MainActor.run { DownloadHost.shared.abandonPrepare() }
            } catch {
                await MainActor.run {
                    status = String(format: L("请到系统设置 › 通用 › 语言与地区 › 翻译语言 下载「中文(简体)」和「English」。\n%@"), String(describing: error.localizedDescription))
                }
            }
        }
        .onAppear {
            configuration = TranslationSession.Configuration(
                source: Locale.Language(identifier: sourceID),
                target: Locale.Language(identifier: targetID)
            )
        }
    }
}
