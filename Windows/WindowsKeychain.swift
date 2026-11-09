import Foundation
import WinSDK

enum WindowsKeychain {
    static func install() {
        Keychain.read = { get($0) }
        Keychain.write = { set($0, account: $1) }
        Keychain.remove = { delete($0) }
    }

    private static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let d = base.appendingPathComponent("Korgino", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private static func file(_ account: String) -> URL {
        let name = Data(account.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
        return dir.appendingPathComponent(name)
    }

    static func set(_ value: String, account: String) {
        let url = file(account)
        if value.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let protected = protect(Data(value.utf8)) else { return }
        try? protected.write(to: url, options: .atomic)
    }

    static func get(_ account: String) -> String? {
        guard let data = try? Data(contentsOf: file(account)),
              let plain = unprotect(data) else { return nil }
        return String(data: plain, encoding: .utf8)
    }

    static func delete(_ account: String) {
        try? FileManager.default.removeItem(at: file(account))
    }

    private static func protect(_ data: Data) -> Data? {
        var input = [UInt8](data)
        var output = DATA_BLOB()
        let ok = input.withUnsafeMutableBytes { raw -> Bool in
            var blob = DATA_BLOB(
                cbData: DWORD(raw.count),
                pbData: raw.bindMemory(to: BYTE.self).baseAddress
            )
            return CryptProtectData(&blob, nil, nil, nil, nil, DWORD(CRYPTPROTECT_UI_FORBIDDEN), &output)
        }
        guard ok, let ptr = output.pbData else { return nil }
        defer { LocalFree(ptr) }
        return Data(bytes: ptr, count: Int(output.cbData))
    }

    private static func unprotect(_ data: Data) -> Data? {
        var input = [UInt8](data)
        var output = DATA_BLOB()
        let ok = input.withUnsafeMutableBytes { raw -> Bool in
            var blob = DATA_BLOB(
                cbData: DWORD(raw.count),
                pbData: raw.bindMemory(to: BYTE.self).baseAddress
            )
            return CryptUnprotectData(&blob, nil, nil, nil, nil, DWORD(CRYPTPROTECT_UI_FORBIDDEN), &output)
        }
        guard ok, let ptr = output.pbData else { return nil }
        defer { LocalFree(ptr) }
        return Data(bytes: ptr, count: Int(output.cbData))
    }
}
