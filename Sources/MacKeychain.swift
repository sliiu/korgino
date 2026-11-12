import Foundation
import Security

enum MacKeychain {
    static func install() {
        Keychain.read = { get($0) }
        Keychain.write = { set($0, account: $1) }
        Keychain.remove = { delete($0) }
        Keychain.prime = { prime($0) }
        Keychain.isPrimed = { isPrimed }
        SecretsHost.afterApply = { ms, accounts, failed in
            MainActor.assumeIsolated { DirectLicense.shared.reloadRecordIfNeeded() }
            let note = failed.isEmpty ? "" : ", \(failed) 条没读到，稍后重试"
            LaunchLog.log("✓ keychain prime \(Int(ms))ms (\(accounts) accounts\(note))")
        }
    }

    private static let service = "com.sliiu.Korgino"
    /// 旧名字留下的钥匙串服务。读到就搬进新服务，写完删掉旧的。
    private static let korgiTranslateService = "com.sliiu.KorgiTranslate"
    private static let legacyService = "com.pax.KorgiTranslate"

    // MARK: - 内存缓存
    //
    // 钥匙串读在主线程上会卡住启动：读一条没授权过的条目，macOS 先弹授权框，
    // 而 `SecItemCopyMatching` 就停在那里等用户点。原来 `AppConfig.init` 里一次读 18 条，
    // 全在主线程，窗口要等这些读完才画得出来（实测重装后 71.7 秒 ~ 无限）。
    //
    // 现在启动时只在后台线程 `prime` 一遍，结果留在缓存里；之后所有读写都走缓存，
    // 主线程不再直接调 `SecItem*`。

    private static let lock = NSLock()
    /// 读写缓存。`nil` 表示「读过，确实没有」，和「没读过」是两回事。
    private static var cache: [String: String?] = [:]
    private static var _isPrimed = false

    /// 启动那一轮读完了没有。没读完之前，界面上所有密钥都是空的。
    static var isPrimed: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isPrimed
    }

    /// 在后台线程把一批账号一次性读进缓存。这是唯一会弹授权框的地方——
    /// 弹的时候主线程已经在画界面了，不再被挡住。
    ///
    /// 返回没读到的账号。读失败（钥匙串锁着、用户点了拒绝、等太久）不能当成「没有」：
    /// 当成空值的话，就绪不变式会把配好的供应商关掉并写进偏好，等于替用户删配置。
    @discardableResult
    static func prime(_ accounts: [String]) -> [String] {
        var failed: [String] = []
        for account in accounts {
            lock.lock()
            let known = cache.keys.contains(account)
            lock.unlock()
            guard !known else { continue }
            switch readRaw(account) {
            case .found(let v): remember(account, v)
            case .absent: remember(account, nil)
            case .failed: failed.append(account)
            }
        }
        lock.lock()
        _isPrimed = true
        lock.unlock()
        return failed
    }

    static func set(_ value: String, account: String) {
        lock.lock()
        let known = cache.keys.contains(account)
        let old = cache[account] ?? nil
        lock.unlock()

        // 值没变就不写。启动时把读出来的密钥赋回 `@Published` 属性会触发 didSet，
        // 那里原本每条都要 SecItemDelete + SecItemAdd 一遍，重写得平白多弹框。
        if known, (old ?? "") == value { return }

        writeThrough(value, account: account)
        remember(account, value.isEmpty ? nil : value)
    }

    static func get(_ account: String) -> String? {
        lock.lock()
        if cache.keys.contains(account) {
            let hit = cache[account] ?? nil
            lock.unlock()
            return hit
        }
        let primed = _isPrimed
        lock.unlock()

        // 预读还没回来时先当没有。启动早期主线程上的读绝不能停在这里等授权框，
        // 那是把整台机器卡住的读法。预读结束后才允许现读——那时的账号都是
        // 本进程自己写进去的，ACL 对得上，不会弹框。
        guard primed else { return nil }

        switch readRaw(account) {
        case .found(let v): remember(account, v); return v
        case .absent: remember(account, nil); return nil
        case .failed: return nil      // 不记进缓存，下次还会再试
        }
    }

    static func delete(_ account: String) {
        delete(account, service: service)
        delete(account, service: legacyService)
        delete(account, service: korgiTranslateService)
        remember(account, nil)
    }

    // MARK: - 真正碰钥匙串的部分

    private enum ReadResult {
        case found(String)
        /// 读成功了，条目确实不存在。
        case absent
        /// 没读成。和「不存在」必须分开。
        case failed
    }

    private static func remember(_ account: String, _ value: String?) {
        lock.lock()
        cache[account] = value
        lock.unlock()
    }

    private static func readRaw(_ account: String) -> ReadResult {
        switch readOne(account, service: service) {
        case .found(let v): return .found(v)
        case .failed: return .failed
        case .absent: break
        }
        for old in [korgiTranslateService, legacyService] {
            switch readOne(account, service: old) {
            case .found(let v):
                writeThrough(v, account: account)
                return .found(v)
            case .failed: return .failed
            case .absent: continue
            }
        }
        return .absent
    }

    private static func writeThrough(_ value: String, account: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
        guard !value.isEmpty else { return }
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        SecItemAdd(add as CFDictionary, nil)
        // Drop legacy copy once written to new service.
        delete(account, service: legacyService)
        delete(account, service: korgiTranslateService)
    }

    private static func readOne(_ account: String, service svc: String) -> ReadResult {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: svc,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return .absent }
        guard status == errSecSuccess,
              let data = out as? Data,
              let s = String(data: data, encoding: .utf8) else { return .failed }
        return .found(s)
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
