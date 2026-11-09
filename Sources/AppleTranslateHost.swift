import AppKit
import SwiftUI
import Translation

/// macOS 15 上没有 `TranslationSession(installedSource:target:)`——那是 26 才加的。
/// 15 的 session 只能从 SwiftUI 的 `.translationTask` 里拿到，所以这里支一个看不见的宿主窗口，
/// 让那个 modifier 把 session 交过来，翻完再拆掉。26 上 `Translator.apple` 直接建 session，不走这里。
///
/// 这层不依赖项目里的任何符号，好在 macOS 15 上单独编、单独验。
@MainActor
final class AppleTranslateHost {
    static let shared = AppleTranslateHost()

    private var windows: Set<NSWindow> = []

    func translate(
        _ text: String,
        from source: Locale.Language,
        to target: Locale.Language,
        timeout: TimeInterval = 20
    ) async throws -> String {
        let request = AppleTranslateRequest(text: text, source: source, target: target)
        let hosting = NSHostingView(rootView: AppleTranslateView(request: request))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        // Ordered front (the modifier only runs for a view that appeared) but parked well off every screen.
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFront(nil)
        windows.insert(window)
        defer {
            windows.remove(window)
            window.orderOut(nil)
            window.contentView = nil
        }
        return try await request.run(timeout: timeout)
    }
}

@MainActor
private final class AppleTranslateRequest {
    let text: String
    let source: Locale.Language
    let target: Locale.Language
    private var continuation: CheckedContinuation<String, Error>?
    private var finished = false

    init(text: String, source: Locale.Language, target: Locale.Language) {
        self.text = text
        self.source = source
        self.target = target
    }

    func run(timeout: TimeInterval) async throws -> String {
        let watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(timeout, 1) * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.finish(.failure(NSError(
                domain: "Korgino.AppleTranslate",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Apple 翻译没有响应"]
            )))
        }
        defer { watchdog.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func finish(_ result: Result<String, Error>) {
        guard !finished else { return }
        finished = true
        let waiting = continuation
        continuation = nil
        switch result {
        case .success(let text): waiting?.resume(returning: text)
        case .failure(let error): waiting?.resume(throwing: error)
        }
    }
}

private struct AppleTranslateView: View {
    let request: AppleTranslateRequest
    @State private var configuration: TranslationSession.Configuration?

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(configuration) { session in
                do {
                    let response = try await session.translate(request.text)
                    request.finish(.success(response.targetText))
                } catch {
                    request.finish(.failure(error))
                }
            }
            .onAppear {
                configuration = TranslationSession.Configuration(source: request.source, target: request.target)
            }
    }
}
