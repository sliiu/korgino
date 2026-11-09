import AppKit
import StoreKit
import SwiftUI

@MainActor
final class Pro: ObservableObject {
    static let shared = Pro()
    nonisolated static let productID = "com.sliiu.Korgino.pro"
    nonisolated static let trialID = "com.sliiu.Korgino.trial"
    nonisolated static let trialDays = 14
    /// 免费档的额度在 Engine/ProLimits，Windows 共用同一套数字。
    nonisolated static let freeHistoryLimit = ProLimits.freeHistoryLimit
    nonisolated static let freeSimultaneous = ProLimits.freeSimultaneous
    /// 免费档单份文件的原文上限，按 UTF-16 字符数算，中文一个字算一个。
    nonisolated static let freeFileCharacters = ProLimits.freeFileCharacters
    /// 免费档一份媒体字幕的时长上限。
    nonisolated static let freeMediaSeconds: TimeInterval = ProLimits.freeMediaSeconds

    nonisolated(unsafe) private static var purchasedFlag = false
    nonisolated(unsafe) private static var trialEndFlag: Date?

    /// 测试包把 Pro 开到 2026-12-31 当天结束（本机时区）。过了回免费档，购买仍照旧。见 docs/adr/0070。
    #if KORGI_TEST_PRO
    nonisolated static let testAccessEnds: Date = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal.date(from: DateComponents(year: 2027, month: 1, day: 1)) ?? .distantPast
    }()
    nonisolated static var testAccessOpen: Bool { Date() < testAccessEnds }
    #else
    nonisolated static var testAccessOpen: Bool { false }
    #endif

    nonisolated static var unlocked: Bool {
        #if KORGI_DEV
        if UserDefaults.standard.object(forKey: "korgi.devPro") as? Bool ?? true { return true }
        #endif
        if testAccessOpen { return true }
        return purchasedFlag || (trialEndFlag ?? .distantPast) > Date()
    }

    @Published private(set) var purchased = false
    @Published private(set) var trialEnd: Date?
    @Published private(set) var products: [String: Product] = [:]
    @Published private(set) var busy = false
    #if KORGI_DEV
    /// 开发版默认当作已购买。关掉后按免费档跑，看免费用户看到的样子。
    @Published var devUnlocked = UserDefaults.standard.object(forKey: "korgi.devPro") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(devUnlocked, forKey: "korgi.devPro")
            entitlementsChanged()
        }
    }
    #endif
    private var updates: Task<Void, Never>?

    var trialDaysLeft: Int? {
        guard let trialEnd, trialEnd > Date() else { return nil }
        return Int((trialEnd.timeIntervalSinceNow / 86400).rounded(.up))
    }

    enum Channel { case store, direct }

    /// 商店包编译时带 KORGI_STORE，公证包不带。两份各认各的购买，见 docs/adr/0062。
    nonisolated static var channel: Channel {
        #if KORGI_STORE
        return .store
        #else
        return .direct
        #endif
    }

    /// 公证包：钥匙状态变化时由 DirectLicense 调用。商店包不认钥匙。
    func applyDirect(purchased bought: Bool) {
        guard Self.channel == .direct else { return }
        let changed = Self.purchasedFlag != bought
        Self.purchasedFlag = bought
        purchased = bought
        if changed { entitlementsChanged() }
    }

    func start() {
        guard Self.channel == .store else {
            DirectLicense.shared.start()
            return
        }
        updates = Task {
            for await result in Transaction.updates {
                if case .verified(let t) = result { await t.finish() }
                await refresh()
            }
        }
        Task {
            await refresh()
            let list = (try? await Product.products(for: [Self.productID, Self.trialID])) ?? []
            products = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
        }
    }

    func refresh() async {
        var bought = false
        var end: Date?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let t) = result, t.revocationDate == nil else { continue }
            switch t.productID {
            case Self.productID:
                bought = true
            case Self.trialID:
                end = Calendar.current.date(byAdding: .day, value: Self.trialDays, to: t.originalPurchaseDate)
            default:
                break
            }
        }
        let changed = Self.purchasedFlag != bought || Self.trialEndFlag != end
        Self.purchasedFlag = bought
        Self.trialEndFlag = end
        purchased = bought
        trialEnd = end
        if changed { entitlementsChanged() }
    }

    /// 已暂停的翻译服务和识别引擎随 Pro 状态出现或恢复，用到它们的窗口要重新列一遍。
    nonisolated static let changed = Notification.Name("Korgino.proChanged")

    private func entitlementsChanged() {
        AppConfig.shared.objectWillChange.send()
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    func purchase(_ id: String) async {
        guard let product = products[id] else { return }
        busy = true
        defer { busy = false }
        if case .success(let result) = try? await product.purchase(),
           case .verified(let t) = result {
            await t.finish()
        }
        await refresh()
    }

    func restore() async {
        busy = true
        defer { busy = false }
        try? await AppStore.sync()
        await refresh()
    }

    @discardableResult
    func require() -> Bool {
        if Self.unlocked { return true }
        showOffer()
        return false
    }

    func showOffer() {
        PreferencesController.shared.show(tab: .about)
    }
}

/// 受限的地方旁边那个小标签。点了去关于页的 Pro 状态卡。
struct ProBadge: View {
    var help: String = ""

    var body: some View {
        Button {
            Pro.shared.showOffer()
        } label: {
            Text("Pro")
                .font(Theme.TypeScale.micro)
                .padding(.horizontal, 6)
                .padding(.vertical, 1.5)
                .foregroundStyle(Color.accentColor)
                .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help.isEmpty ? L("需要 Pro") : help)
        .accessibilityLabel(Text(help.isEmpty ? L("需要 Pro") : help))
    }
}
