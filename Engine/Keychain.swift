import Foundation

enum Keychain {
    nonisolated(unsafe) static var read: (String) -> String? = { _ in nil }
    nonisolated(unsafe) static var write: (String, String) -> Void = { _, _ in }
    nonisolated(unsafe) static var remove: (String) -> Void = { _ in }

    static func get(_ account: String) -> String? { read(account) }
    static func set(_ value: String, account: String) { write(value, account) }
    static func delete(_ account: String) { remove(account) }
}
