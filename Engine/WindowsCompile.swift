#if !os(macOS)
import Foundation

enum Pro {
    static let freeSimultaneous = ProLimits.freeSimultaneous
    static var unlocked: Bool {
        #if KORGI_DEV
        // 缺省跟 Mac 侧一致：开发开关没写过时按免费档跑。
        if UserDefaults.standard.object(forKey: "korgi.devPro") as? Bool ?? false { return true }
        #endif
        return false
    }
}

struct MaskDeclined: LocalizedError, Sendable {
    var errorDescription: String? { "\u{5df2}\u{53d6}\u{6d88}" }
}

enum MaskSendConfirm {
    @MainActor
    static func ask(masked: String, original: String, hits: [MaskHit], destination: String) throws -> MaskChoice {
        .masked
    }
}

extension AppearanceMode {
    func apply() {}
}

extension Translator {
    static func apple(_: String, from: String, to: String) async throws -> String {
        throw TErr(L("Apple 翻译不可用"))
    }
}
#endif
