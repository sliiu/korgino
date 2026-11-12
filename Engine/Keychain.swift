import Foundation

enum Keychain {
    nonisolated(unsafe) static var read: (String) -> String? = { _ in nil }
    nonisolated(unsafe) static var write: (String, String) -> Void = { _, _ in }
    nonisolated(unsafe) static var remove: (String) -> Void = { _ in }
    /// 后台批量预读。返回没读到的账号（和「确实没有」不是一回事）。
    /// 没接钥匙串的平台（Windows 构建）保持空实现。
    nonisolated(unsafe) static var prime: ([String]) -> [String] = { _ in [] }
    /// 预读结束没有。没有钥匙串的平台恒为 true，读不读都当已就绪。
    nonisolated(unsafe) static var isPrimed: () -> Bool = { true }

    static func get(_ account: String) -> String? { read(account) }
    static func set(_ value: String, account: String) { write(value, account) }
    static func delete(_ account: String) { remove(account) }
}

/// 密钥回填完之后要做的应用层事（补读许可证、记账日志）。
/// Engine 不能直接引用 Mac 侧的类型，由 `MacKeychain.install()` 接上。
enum SecretsHost {
    /// 参数：读用了多少毫秒、读了多少个账号、哪些没读到。
    nonisolated(unsafe) static var afterApply: ((_ ms: Double, _ accounts: Int, _ failed: [String]) -> Void)?
}
