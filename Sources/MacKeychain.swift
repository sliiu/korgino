import Foundation
import Security

enum MacKeychain {
    static func install() {
        Keychain.read = { get($0) }
        Keychain.write = { set($0, account: $1) }
        Keychain.remove = { delete($0) }
    }

    private static let service = "com.sliiu.Korgino"
    /// 旧名字留下的钥匙串服务。读到就搬进新服务，写完删掉旧的。
    private static let korgiTranslateService = "com.sliiu.KorgiTranslate"
    private static let legacyService = "com.pax.KorgiTranslate"

    static func set(_ value: String, account: String) {
        let data = Data(value.utf8)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
        guard !value.isEmpty else { return }
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        SecItemAdd(add as CFDictionary, nil)
        // Drop legacy copy once written to new service.
        delete(account, service: legacyService)
        delete(account, service: korgiTranslateService)
    }

    static func get(_ account: String) -> String? {
        if let v = get(account, service: service) { return v }
        for old in [korgiTranslateService, legacyService] {
            if let v = get(account, service: old) {
                set(v, account: account)
                return v
            }
        }
        return nil
    }

    static func delete(_ account: String) {
        delete(account, service: service)
        delete(account, service: legacyService)
        delete(account, service: korgiTranslateService)
    }

    private static func get(_ account: String, service svc: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: svc,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    private static func delete(_ account: String, service svc: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: svc,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
    }
}
