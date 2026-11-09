import CryptoKit
import Foundation
import IOKit

// 公证包的直接购买：钥匙、3 台 Mac 名额、有网时再对一次。见 docs/adr/0062。
// 收款和名额登记都在应用之外的支付系统里。这里只留接口，不接具体渠道。

enum LicenseEndpoint {
    /// 支付系统的根地址。留空 = 还没接，填钥匙和补发都会提示尚未接入。
    static let base = ""
    /// 付款页。留空 = 购买按钮停着。付款时必填邮箱。
    static let purchasePage = ""

    static var baseURL: URL? { base.isEmpty ? nil : URL(string: base) }
    static var purchaseURL: URL? { purchasePage.isEmpty ? nil : URL(string: purchasePage) }
}

enum LicenseVerdict: Equatable {
    /// 钥匙有效，这台在名额里。
    case valid
    /// 退款或作废。
    case revoked
    /// 这台已经不在名额里：被第 4 台挤掉，或自己让出过。
    case displaced
    case unknownKey
}

enum LicenseFailure: Error {
    /// 连不上，或系统停了一阵。和「这台已经不在名额里」是两回事，只保持上次的结果。
    case unreachable
    case notConfigured
    case rejected
}

protocol LicenseBackend {
    var isConfigured: Bool { get }
    func activate(key: String, machine: String) async throws -> LicenseVerdict
    func verify(key: String, machine: String) async throws -> LicenseVerdict
    /// 幂等：这台已经不在名额里也回成功。
    func release(key: String, machine: String) async throws
    /// 这个邮箱上的每一把都发。买没买过都回成功。
    func reissue(email: String) async throws
}

/// POST {base}/v1/{activate|verify|release|reissue}，JSON 进、JSON 出。
/// activate / verify 回 {"status":"valid|revoked|displaced|unknown"}。
/// 200 以外：429 和 5xx 当作连不上，其余当作被拒。
struct HTTPLicenseBackend: LicenseBackend {
    var isConfigured: Bool { LicenseEndpoint.baseURL != nil }

    func activate(key: String, machine: String) async throws -> LicenseVerdict {
        try verdict(try await post("activate", ["key": key, "machine": machine]))
    }

    func verify(key: String, machine: String) async throws -> LicenseVerdict {
        try verdict(try await post("verify", ["key": key, "machine": machine]))
    }

    func release(key: String, machine: String) async throws {
        _ = try await post("release", ["key": key, "machine": machine])
    }

    func reissue(email: String) async throws {
        _ = try await post("reissue", ["email": email])
    }

    private func verdict(_ data: Data) throws -> LicenseVerdict {
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        switch obj?["status"] as? String {
        case "valid": return .valid
        case "revoked": return .revoked
        case "displaced": return .displaced
        case "unknown": return .unknownKey
        default: throw LicenseFailure.unreachable
        }
    }

    private func post(_ path: String, _ body: [String: String]) async throws -> Data {
        guard let base = LicenseEndpoint.baseURL else { throw LicenseFailure.notConfigured }
        var req = URLRequest(url: base.appendingPathComponent("v1/" + path), timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        var result: (Data, URLResponse)
        do {
            result = try await NetSession.data(for: req)
        } catch {
            throw LicenseFailure.unreachable
        }
        let code = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
        if code == 200 { return result.0 }
        if code == 429 || code >= 500 || code == 0 { throw LicenseFailure.unreachable }
        throw LicenseFailure.rejected
    }
}

/// 这台电脑的标识：硬件 UUID 加盐哈希，原值不出本机。重装系统不变，换电脑才变。
enum MachineID {
    static let current: String? = {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        guard let raw = IORegistryEntryCreateCFProperty(svc, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String else { return nil }
        let digest = SHA256.hash(data: Data(("Korgino|" + raw).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }()
}

struct LicenseRecord: Codable, Equatable {
    enum Standing: String, Codable { case active, displaced, revoked }
    var key: String
    /// 本机第一次填入这把钥匙的时间。同一台再填不变。
    var firstFilled: Date
    var standing: Standing
    /// 没网时先记下要让出；完成前仍算已购买。
    var releasePending = false
    var lastChecked: Date?
}

@MainActor
final class DirectLicense: ObservableObject {
    static let shared = DirectLicense()
    private static let account = "directLicense"

    @Published private(set) var record: LicenseRecord?
    @Published private(set) var busy = false
    @Published private(set) var note: String?
    private let backend: LicenseBackend

    init(backend: LicenseBackend = HTTPLicenseBackend()) {
        self.backend = backend
        record = Self.load()
    }

    /// 已购买：钥匙有效且这台在名额里。让出完成前（releasePending）仍算。
    var isActive: Bool { record?.standing == .active }
    var isConfigured: Bool { backend.isConfigured }

    /// 启动时调用。先按本机记录定状态，再静默对一次；不弹窗。
    func start() {
        Pro.shared.applyDirect(purchased: isActive)
        Task { await recheck() }
    }

    /// 有网时再对一次。退款、作废、名额被让出，在这里失效；连不上保持上次的结果。
    func recheck() async {
        guard var rec = record, rec.standing == .active, backend.isConfigured,
              let machine = MachineID.current else { return }
        if rec.releasePending {
            do {
                try await backend.release(key: rec.key, machine: machine)
                clear()
            } catch {}
            return
        }
        do {
            switch try await backend.verify(key: rec.key, machine: machine) {
            case .valid: rec.lastChecked = Date()
            case .revoked, .unknownKey: rec.standing = .revoked
            case .displaced: rec.standing = .displaced
            }
            save(rec)
        } catch {}
    }

    func enter(key raw: String) async {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !busy else { return }
        guard backend.isConfigured else {
            note = L("尚未接入支付系统，现在填不了钥匙。")
            return
        }
        guard let machine = MachineID.current else {
            note = L("读不到这台电脑的标识，填不了钥匙。")
            return
        }
        busy = true
        defer { busy = false }
        do {
            switch try await backend.activate(key: key, machine: machine) {
            case .valid:
                let same = record.flatMap { $0.key == key && $0.standing == .active ? $0 : nil }
                save(LicenseRecord(key: key, firstFilled: same?.firstFilled ?? Date(), standing: .active, releasePending: false, lastChecked: Date()))
                note = nil
            case .displaced:
                note = L("这台不在这把钥匙的名额里。")
            case .revoked, .unknownKey:
                note = L("这把钥匙无效，或已经退款。")
            }
        } catch LicenseFailure.unreachable {
            note = L("现在连不上系统，稍后再填。")
        } catch {
            note = L("填入失败，请检查钥匙。")
        }
    }

    /// 只让出自己，不停别的电脑。有网当时就让出；没网先记着，连上后自动完成。
    func release() async {
        guard var rec = record, rec.standing == .active, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            guard let machine = MachineID.current else { throw LicenseFailure.unreachable }
            try await backend.release(key: rec.key, machine: machine)
            clear()
            note = L("这台已让出名额。")
        } catch {
            rec.releasePending = true
            save(rec)
            note = L("现在连不上系统。这台先记着要让出，连上后自动完成；在那之前仍算已购买。")
        }
    }

    /// 补发：不论这个邮箱买没买过，都是同一句话。
    func reissue(email raw: String) async {
        let email = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.contains("@") else {
            note = L("请填付款时用的邮箱。")
            return
        }
        guard backend.isConfigured else {
            note = L("尚未接入支付系统，现在补发不了。")
            return
        }
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await backend.reissue(email: email)
        } catch LicenseFailure.unreachable {
            note = L("现在连不上系统，稍后再试。")
            return
        } catch {}
        note = L("如果这个邮箱买过，钥匙会发到那里。")
    }

    func dismissNote() { note = nil }

    private static func load() -> LicenseRecord? {
        guard let s = MacKeychain.get(account), let d = s.data(using: .utf8) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(LicenseRecord.self, from: d)
    }

    private func save(_ rec: LicenseRecord) {
        record = rec
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(rec), let s = String(data: d, encoding: .utf8) {
            MacKeychain.set(s, account: Self.account)
        }
        Pro.shared.applyDirect(purchased: isActive)
    }

    private func clear() {
        record = nil
        MacKeychain.delete(Self.account)
        Pro.shared.applyDirect(purchased: false)
    }
}
