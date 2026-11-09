import Foundation

/// 本机数据目录：`~/Library/Application Support/Korgino`。
///
/// 旧名字留下的目录在第一次读的时候整个搬过来：`KorgiTranslate`（上一代名字）
/// 和 `SelectTranslate`（更早）。搬的是整个目录，里面的相对结构不变，所以
/// 历史、收藏、会议录音、声纹模型都跟着走。
enum AppPaths {
    /// `~/Library/Application Support/Korgino`
    static var appSupport: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let current = base.appendingPathComponent("Korgino", isDirectory: true)
        migrateIfNeeded(base: base, current: current, fm: fm)
        try? fm.createDirectory(at: current, withIntermediateDirectories: true)
        return current
    }

    /// 新名字、上一代名字、最早的名字，按新到旧。
    private static let formerNames = ["KorgiTranslate", "SelectTranslate"]

    private static func migrateIfNeeded(base: URL, current: URL, fm: FileManager) {
        guard !fm.fileExists(atPath: current.path) else { return }
        for name in formerNames {
            let old = base.appendingPathComponent(name, isDirectory: true)
            guard fm.fileExists(atPath: old.path) else { continue }
            // 同一个卷上，这一步是改名，不复制内容。
            if (try? fm.moveItem(at: old, to: current)) != nil { return }
        }
    }
}
