import Translation

extension Translator {
    static func apple(_ text: String, from s: String, to t: String) async throws -> String {
        let src = Locale.Language(identifier: s)
        let tgt = Locale.Language(identifier: t)
        let status = await LanguageAvailability().status(from: src, to: tgt)
        switch status {
        case .installed: break
        case .supported:
            await MainActor.run {
                AppleLangPack.presentDownloadPrompt(source: s, target: t)
            }
            throw TErr(String(format: L("Apple 语言包未下载（%@→%@）。已打开下载入口：系统设置 › 通用 › 语言与地区 › 翻译语言"), String(describing: s), String(describing: t)),
                       applePackMissing: true)
        case .unsupported: throw TErr(String(format: L("Apple 翻译不支持 %@→%@"), String(describing: s), String(describing: t)))
        @unknown default: throw TErr(L("Apple 翻译状态未知"))
        }
        if #available(macOS 26.0, *) {
            let session = TranslationSession(installedSource: src, target: tgt)
            return try await apple26(session, text: text, timeout: 20)
        }
        // 15 没有现成的 session 构造器，只能借 SwiftUI 的 .translationTask 拿一个。
        return try await AppleTranslateHost.shared.translate(text, from: src, to: tgt)
    }

    /// macOS 26 的 `translate` 没有超时，服务卡住就永远不返回，浮层一直转圈。
    /// 和 15 那条路径一样按 20 秒算：超了就抛，让这一家单独报错，别拖住整次翻译。
    ///
    /// 不用 TaskGroup：group 结束前会等所有子任务，而卡住的 `translate` 不响应取消，
    /// group 一样等不回来。这里让两边抢着写同一个结果，谁先到用谁，另一边写空。
    private static func apple26(
        _ session: TranslationSession,
        text: String,
        timeout: TimeInterval
    ) async throws -> String {
        let box = AppleOnceBox()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                box.set(continuation)
                Task {
                    do {
                        box.finish(.success(try await session.translate(text).targetText))
                    } catch {
                        box.finish(.failure(error))
                    }
                }
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(max(timeout, 1) * 1_000_000_000))
                    box.finish(.failure(TErr(String(format: L("超时（%@s）"), String(Int(timeout))))))
                }
            }
        }, onCancel: {
            box.finish(.failure(CancellationError()))
        })
    }
}

/// 两边抢一个续体，只放第一个通过。
private final class AppleOnceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    /// 已经有结果了。取消可能比 `set` 先到，那时续体还没挂上，得记下来等它挂上立刻放行。
    private var closed: Result<String, Error>?

    func set(_ c: CheckedContinuation<String, Error>) {
        lock.lock()
        if let done = closed {
            lock.unlock()
            resume(c, with: done)
            return
        }
        continuation = c
        lock.unlock()
    }

    func finish(_ result: Result<String, Error>) {
        lock.lock()
        guard closed == nil else { lock.unlock(); return }
        closed = result
        let waiting = continuation
        continuation = nil
        lock.unlock()
        if let waiting { resume(waiting, with: result) }
    }

    private func resume(_ c: CheckedContinuation<String, Error>, with result: Result<String, Error>) {
        switch result {
        case .success(let text): c.resume(returning: text)
        case .failure(let error): c.resume(throwing: error)
        }
    }
}
