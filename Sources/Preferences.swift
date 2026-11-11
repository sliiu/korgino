import AppKit
import SwiftUI
import ServiceManagement
import ApplicationServices
import AVFoundation
import CoreGraphics
import Speech
import Translation
import UniformTypeIdentifiers

enum PreferencesTab: String, CaseIterable, Identifiable, Hashable {
    case common, shortcuts, account
    case providers, recognition, dictionary, plugins, apps, privacy, network
    case voice
    /// 菜单「关于」和购买入口还用这个名字进来。侧栏不列它，打开就落到账号页。
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .common: return L("常用")
        case .shortcuts: return L("快捷键")
        case .account: return L("账号与 Pro")
        case .providers: return L("翻译服务与 AI")
        case .recognition: return L("识别、朗读与 OCR")
        case .dictionary: return L("词典")
        case .plugins: return L("划词插件")
        case .apps: return L("按应用设置")
        case .privacy: return L("脱敏")
        case .network: return L("网络与权限")
        case .voice: return L("语音")
        case .about: return L("账号与 Pro")
        }
    }

    /// 页顶那一句，说这页管什么。
    var blurb: String {
        switch self {
        case .common: return L("平时改得最多的几项")
        case .shortcuts: return L("点键帽录新组合，需含 ⌃ ⌥ ⇧ ⌘ 之一")
        case .account: return L("购买、钥匙和版本")
        case .providers: return L("填好密钥才能打开；打开的服务会出现在「各功能用哪几家」里")
        case .recognition: return L("听、读、看图用哪家")
        case .dictionary: return L("查词用哪几家")
        case .plugins: return L("插件条上放什么")
        case .apps: return L("某个应用里换服务、换语言或关掉某种触发")
        case .privacy: return L("这台 Mac 上留下的始终是原文")
        case .network: return L("连网方式和系统授权")
        case .voice: return L("按住 Fn 说话，松开结束。按住时再按别的键就取消。")
        case .about: return L("购买、钥匙和版本")
        }
    }

    /// 侧栏上半，常用三页。
    static let primary: [PreferencesTab] = [.common, .shortcuts, .account]
    /// 侧栏「高级」下面的七页。语音不在设置里，它在主窗口「更多」下面。
    static let advanced: [PreferencesTab] = [.providers, .recognition, .dictionary, .plugins, .apps, .privacy, .network]

    /// 旧的顶部分页。菜单「关于」和购买入口还用 `.about` 这个名字进来，落到账号页。
    static func migrated(_ raw: String) -> PreferencesTab? {
        switch raw {
        case "general": return .common
        case "providers": return .providers
        case "recognition": return .recognition
        case "features": return .common
        case "privacy": return .privacy
        case "permissions": return .network
        case "about": return .account
        default: return nil
        }
    }
}

/// 设置窗口当前停在哪一页。侧栏点哪一页，内容区换哪一页。
@MainActor
final class PreferencesTabs: ObservableObject {
    @Published var tab: PreferencesTab = .common
    @Published var epoch = 0
}

@MainActor
final class PreferencesController: NSObject {
    static let shared = PreferencesController()

    /// 设置在主窗口里。原来的独立窗口入口都转到这里。
    func show() {
        show(tab: .common)
    }

    func show(tab: PreferencesTab) {
        MainWindowController.shared.showSettings(tab: tab)
    }

    /// 语音在主窗口侧栏「更多」下面，不再进设置。
    func showVoice() {
        MainWindowController.shared.show(page: .voice)
    }

    func close() {
        MainWindowController.shared.model.showingSettings = false
    }

    func relocalize() {
        MainWindowController.shared.relocalize()
    }
}

/// 「登录时打开」。用 `SMAppService.mainApp` 注册，开关读 service 的 status，不读 UserDefaults。
/// 这台 SDK（MacOSX 27.2）的 `SMAppService.h` 里，主应用登录项没有要求额外的 entitlement。
@MainActor
enum LoginItem {
    static var isOn: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ on: Bool) -> String? {
        let service = SMAppService.mainApp
        if on {
            if service.status == .enabled { return nil }
            do {
                try service.register()
            } catch {
                return error.localizedDescription
            }
            if service.status == .requiresApproval {
                return L("系统要求先在「系统设置 › 通用 › 登录项」里允许 Korgino")
            }
            return nil
        }
        if service.status == .notRegistered { return nil }
        do {
            try service.unregister()
        } catch {
            return error.localizedDescription
        }
        return nil
    }
}

private enum ProviderSheet: String, Identifiable {
    case ai, asr, tts
    var id: String { rawValue }
}

/// 填写块里控件贴右的那一列。输入框、输入框加按钮、主机加端口都是这个宽。
enum SettingsMetrics {
    static let controlWidth: CGFloat = SettingsChrome.controlWidth
}

private struct SettingsFieldWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    var settingsFieldWidth: CGFloat? {
        get { self[SettingsFieldWidthKey.self] }
        set { self[SettingsFieldWidthKey.self] = newValue }
    }
}

/// 填写块里的输入框：贴右，宽 300。有标签时走左标签右控件；说明跟在控件下面。
private struct SettingsField<Content: View>: View {
    @Environment(\.settingsFieldWidth) private var width
    var title: String? = nil
    var note: String? = nil
    var showsDivider = true
    @ViewBuilder var content: () -> Content

    var body: some View {
        if let width {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 8) {
                    if let title {
                        Text(title)
                            .font(Theme.TypeScale.body)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Spacer(minLength: 0)
                    }
                    content()
                        .frame(width: width, alignment: .trailing)
                }
                .frame(minHeight: SettingsChrome.rowMinHeight)
                if let note, !note.isEmpty {
                    Text(note)
                        .font(Theme.TypeScale.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: width, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.top, -4)
                        .padding(.bottom, 8)
                }
            }
            .overlay(alignment: .top) {
                if showsDivider {
                    Rectangle().fill(Theme.hairline).frame(height: 0.5)
                }
            }
        } else {
            content()
        }
    }
}

private struct ContactIcon: View {
    enum Kind { case x, wechat }

    var kind: Kind

    var body: some View {
        Canvas { context, size in
            let scale = size.width / 24
            switch kind {
            case .x:
                context.fill(
                    Self.xMark.applying(CGAffineTransform(scaleX: scale, y: scale)),
                    with: .foreground,
                    style: FillStyle(eoFill: true)
                )
            case .wechat:
                context.fill(
                    Self.wechat.applying(CGAffineTransform(scaleX: scale, y: scale)),
                    with: .foreground,
                    style: FillStyle(eoFill: true)
                )
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }

    private static let wechat = Path(SVGMark.path(wechatD))

    /// WeChat mark, 24×24, even-odd so the eyes stay holes.
    private static let wechatD = "M8.691 2.188C3.891 2.188 0 5.476 0 9.53c0 2.212 1.17 4.203 3.002 5.55a.59.59 0 0 1 .213.665l-.39 1.48c-.019.07-.048.141-.048.213c0 .163.13.295.295.295a.326.326 0 0 0 .167-.054l1.903-1.114a.864.864 0 0 1 .717-.098a10.16 10.16 0 0 0 2.837.403c.276 0 .543-.027.811-.05c-.857-2.578.157-4.972 1.932-6.446c1.703-1.415 3.882-1.98 5.853-1.838c-.576-3.583-4.196-6.348-8.596-6.348zM5.785 5.991c.642 0 1.162.529 1.162 1.18a1.17 1.17 0 0 1-1.162 1.178A1.17 1.17 0 0 1 4.623 7.17c0-.651.52-1.18 1.162-1.18zm5.813 0c.642 0 1.162.529 1.162 1.18a1.17 1.17 0 0 1-1.162 1.178a1.17 1.17 0 0 1-1.162-1.178c0-.651.52-1.18 1.162-1.18zm5.34 2.867c-1.797-.052-3.746.512-5.28 1.786c-1.72 1.428-2.687 3.72-1.78 6.22c.942 2.453 3.666 4.229 6.884 4.229c.826 0 1.622-.12 2.361-.336a.722.722 0 0 1 .598.082l1.584.926a.272.272 0 0 0 .14.047c.134 0 .24-.111.24-.247c0-.06-.023-.12-.038-.177l-.327-1.233a.582.582 0 0 1-.023-.156a.49.49 0 0 1 .201-.398C23.024 18.48 24 16.82 24 14.98c0-3.21-2.931-5.837-6.656-6.088V8.89c-.135-.01-.269-.027-.407-.03zm-2.53 3.274c.535 0 .969.44.969.982a.976.976 0 0 1-.969.983a.976.976 0 0 1-.969-.983c0-.542.434-.982.97-.982zm4.844 0c.535 0 .969.44.969.982a.976.976 0 0 1-.969.983a.976.976 0 0 1-.969-.983c0-.542.434-.982.969-.982z"

    /// X logo, 24×24, even-odd so the inner quad is a hole.
    private static var xMark: Path {
        var path = Path()
        path.move(to: CGPoint(x: 18.244, y: 2.25))
        path.addLine(to: CGPoint(x: 21.552, y: 2.25))
        path.addLine(to: CGPoint(x: 14.325, y: 10.51))
        path.addLine(to: CGPoint(x: 22.827, y: 21.75))
        path.addLine(to: CGPoint(x: 16.17, y: 21.75))
        path.addLine(to: CGPoint(x: 11.456, y: 15.519))
        path.addLine(to: CGPoint(x: 6.055, y: 21.75))
        path.addLine(to: CGPoint(x: 2.744, y: 21.75))
        path.addLine(to: CGPoint(x: 10.469, y: 12.915))
        path.addLine(to: CGPoint(x: 1.254, y: 2.25))
        path.addLine(to: CGPoint(x: 8.08, y: 2.25))
        path.addLine(to: CGPoint(x: 12.333, y: 7.872))
        path.closeSubpath()
        path.move(to: CGPoint(x: 17.083, y: 19.77))
        path.addLine(to: CGPoint(x: 18.916, y: 19.77))
        path.addLine(to: CGPoint(x: 7.084, y: 4.126))
        path.addLine(to: CGPoint(x: 5.117, y: 4.126))
        path.closeSubpath()
        return path
    }

}

/// SVG path for the WeChat mark. Even-odd fill leaves the eyes open.
private enum SVGMark {
    static func path(_ d: String) -> CGPath {
        let chars = Array(d)
        var i = 0
        var command: Character = " "
        var cx: CGFloat = 0, cy: CGFloat = 0
        var sx: CGFloat = 0, sy: CGFloat = 0
        let path = CGMutablePath()

        func skip() {
            while i < chars.count, chars[i] == "," || chars[i].isWhitespace { i += 1 }
        }
        func number() -> CGFloat {
            skip()
            let start = i
            if i < chars.count, chars[i] == "+" || chars[i] == "-" { i += 1 }
            var dot = false
            while i < chars.count {
                let c = chars[i]
                if c.isNumber { i += 1; continue }
                if c == ".", !dot { dot = true; i += 1; continue }
                break
            }
            return CGFloat(Double(String(chars[start..<i])) ?? 0)
        }
        func addArc(rx0: CGFloat, ry0: CGFloat, angle: CGFloat, large: Bool, sweep: Bool, x: CGFloat, y: CGFloat) {
            var rx = abs(rx0), ry = abs(ry0)
            let end = CGPoint(x: x, y: y)
            let from = CGPoint(x: cx, y: cy)
            if rx < 0.00001 || ry < 0.00001 || hypot(from.x - end.x, from.y - end.y) < 0.00001 {
                path.addLine(to: end)
                cx = end.x
                cy = end.y
                return
            }
            let phi = angle * .pi / 180
            let cosPhi = cos(phi), sinPhi = sin(phi)
            let dx = (from.x - end.x) / 2, dy = (from.y - end.y) / 2
            let x1p = cosPhi * dx + sinPhi * dy
            let y1p = -sinPhi * dx + cosPhi * dy
            let lam = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
            if lam > 1 {
                let s = sqrt(lam)
                rx *= s
                ry *= s
            }
            let sign: CGFloat = (large == sweep) ? -1 : 1
            let num = max(0, rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p)
            let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
            let coef = sign * sqrt(den == 0 ? 0 : num / den)
            let cxp = coef * (rx * y1p / ry)
            let cyp = coef * (-ry * x1p / rx)
            let centerX = cosPhi * cxp - sinPhi * cyp + (from.x + end.x) / 2
            let centerY = sinPhi * cxp + cosPhi * cyp + (from.y + end.y) / 2
            func ang(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
                let dot = ux * vx + uy * vy
                let len = sqrt(ux * ux + uy * uy) * sqrt(vx * vx + vy * vy)
                guard len > 0 else { return 0 }
                var a = acos(min(1, max(-1, dot / len)))
                if ux * vy - uy * vx < 0 { a = -a }
                return a
            }
            let theta1 = ang(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
            var delta = ang((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
            if !sweep, delta > 0 { delta -= 2 * .pi }
            else if sweep, delta < 0 { delta += 2 * .pi }
            let n = max(1, Int(ceil(abs(delta) / (.pi / 2))))
            let step = delta / CGFloat(n)
            for seg in 0..<n {
                let t1 = theta1 + CGFloat(seg) * step
                let t2 = t1 + step
                let half = tan(step / 2)
                let alpha = sin(step) * (sqrt(4 + 3 * half * half) - 1) / 3
                func pt(_ t: CGFloat) -> CGPoint {
                    let px = rx * cos(t), py = ry * sin(t)
                    return CGPoint(x: cosPhi * px - sinPhi * py + centerX, y: sinPhi * px + cosPhi * py + centerY)
                }
                func deriv(_ t: CGFloat) -> CGPoint {
                    let px = -rx * sin(t), py = ry * cos(t)
                    return CGPoint(x: cosPhi * px - sinPhi * py, y: sinPhi * px + cosPhi * py)
                }
                let p1 = pt(t1), p2 = pt(t2)
                let d1 = deriv(t1), d2 = deriv(t2)
                path.addCurve(
                    to: p2,
                    control1: CGPoint(x: p1.x + alpha * d1.x, y: p1.y + alpha * d1.y),
                    control2: CGPoint(x: p2.x - alpha * d2.x, y: p2.y - alpha * d2.y)
                )
            }
            cx = end.x
            cy = end.y
        }

        while i < chars.count {
            skip()
            if i >= chars.count { break }
            if chars[i].isLetter {
                command = chars[i]
                i += 1
            }
            let rel = command.isLowercase
            switch command.lowercased() {
            case "m":
                let x = number(), y = number()
                cx = rel ? cx + x : x
                cy = rel ? cy + y : y
                path.move(to: CGPoint(x: cx, y: cy))
                sx = cx
                sy = cy
                command = rel ? "l" : "L"
            case "l":
                let x = number(), y = number()
                cx = rel ? cx + x : x
                cy = rel ? cy + y : y
                path.addLine(to: CGPoint(x: cx, y: cy))
            case "h":
                let x = number()
                cx = rel ? cx + x : x
                path.addLine(to: CGPoint(x: cx, y: cy))
            case "v":
                let y = number()
                cy = rel ? cy + y : y
                path.addLine(to: CGPoint(x: cx, y: cy))
            case "c":
                let x1 = number(), y1 = number(), x2 = number(), y2 = number(), x = number(), y = number()
                let c1 = CGPoint(x: rel ? cx + x1 : x1, y: rel ? cy + y1 : y1)
                let c2 = CGPoint(x: rel ? cx + x2 : x2, y: rel ? cy + y2 : y2)
                let end = CGPoint(x: rel ? cx + x : x, y: rel ? cy + y : y)
                path.addCurve(to: end, control1: c1, control2: c2)
                cx = end.x
                cy = end.y
            case "a":
                let rx = number(), ry = number(), ang = number()
                let large = number() != 0, sweep = number() != 0
                let x = number(), y = number()
                addArc(rx0: rx, ry0: ry, angle: ang, large: large, sweep: sweep, x: rel ? cx + x : x, y: rel ? cy + y : y)
            case "z":
                path.closeSubpath()
                cx = sx
                cy = sy
            default:
                i += 1
            }
        }
        return path
    }
}

/// 主窗口侧栏换成设置目录：返回、常用三页、高级七页。点返回回到之前的页。
struct SettingsSidebar: View {
    @Binding var tab: PreferencesTab
    var onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Button(action: onBack) {
                HStack(spacing: 6) {
                    BackChevron()
                    Text(L("返回"))
                        .font(Theme.TypeScale.label)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 6)
            .help(L("回到之前的页"))

            ForEach(PreferencesTab.primary) { item in
                SidebarRow(title: item.title, selected: tab == item) {
                    tab = item
                }
            }

            SidebarGroupLabel(title: L("高级"))

            ForEach(PreferencesTab.advanced) { item in
                SidebarRow(title: item.title, selected: tab == item) {
                    tab = item
                }
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 10)
        .padding(.top, 44)
        .padding(.bottom, 10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebarFill)
    }
}

/// 设置的一页。侧栏在主窗口里，这里只画右边。
struct PreferencesDetail: View {
    var tab: PreferencesTab
    @StateObject private var tabs = PreferencesTabs()
    @EnvironmentObject private var config: AppConfig

    var body: some View {
        PreferencesPane(tabs: tabs, showsRail: false)
            .environmentObject(config)
            .onAppear { tabs.tab = tab }
            .onChange(of: tab) { _, next in tabs.tab = next }
    }
}

struct PreferencesPane: View {
    @ObservedObject var tabs: PreferencesTabs
    /// 主窗口自己有侧栏时，这里不再画一份设置目录。
    var showsRail = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var tab: PreferencesTab { tabs.tab }

    @EnvironmentObject var config: AppConfig
    @State private var testOutcomes: [ProviderOutcome] = []
    @State private var testDirection: String = ""
    @State private var testing = false
    @State private var axTrusted = AXIsProcessTrusted()
    @State private var screenTrusted = CGPreflightScreenCaptureAccess()
    @State private var listenTrusted = CGPreflightListenEventAccess()
    @State private var micTrusted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var speechTrusted = SFSpeechRecognizer.authorizationStatus() == .authorized
    @State private var launchAtLogin = LoginItem.isOn
    @State private var launchAtLoginError: String?
    @State private var applePackStatus = L("检查中…")
    @State private var providerSheet: ProviderSheet?
    @State private var expandedAIIds: Set<String> = []
    @State private var expandedASRIds: Set<String> = []
    @State private var expandedTTSIds: Set<String> = []
    @State private var checkingUpdate = false
    @ObservedObject private var license = DirectLicense.shared
    @State private var keyInput = ""
    @State private var emailInput = ""
    @State private var showReissue = false
    @State private var showThanks = false
    @State private var showWeChatQR = false
    @State private var asrTermDraft = ""
    @State private var openBuiltin: Set<String> = []
    @State private var showMoreBuiltin = false
    @State private var openOCR: Set<String> = []
    @State private var hoveredOCR: String?
    @State private var hoveredBuiltin: String?
    @State private var showMoreIdentity = false
    @State private var showMoreDevice = false
    @State private var openMask: Set<UUID> = []
    @State private var maskProbe = ""
    @ObservedObject private var plugins = SelectionPluginStore.shared
    @ObservedObject private var pro = Pro.shared
    @ObservedObject private var media = MediaCaptionsController.shared
    @ObservedObject private var file = FileTranslateController.shared

    var body: some View {
        split
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.windowFill)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: tab)
            .sheet(item: $providerSheet) { sheet in
                switch sheet {
                case .ai:
                    AddProviderSheet(isPresented: Binding(
                        get: { providerSheet == .ai },
                        set: { if !$0 { providerSheet = nil } }
                    )) { preset in
                        let idx = config.addProvider(from: preset)
                        expandedAIIds.insert(config.aiProfiles[idx].id)
                    }
                    .environmentObject(config)
                    .controlSize(.small)
                case .asr:
                    AddASRSheet(isPresented: Binding(
                        get: { providerSheet == .asr },
                        set: { if !$0 { providerSheet = nil } }
                    )) { preset in
                        let idx = config.addASR(from: preset)
                        expandedASRIds.insert(config.asrProfiles[idx].id)
                    }
                    .environmentObject(config)
                    .controlSize(.small)
                case .tts:
                    AddTTSSheet(isPresented: Binding(
                        get: { providerSheet == .tts },
                        set: { if !$0 { providerSheet = nil } }
                    )) { preset in
                        let idx = config.addTTS(from: preset)
                        expandedTTSIds.insert(config.ttsProfiles[idx].id)
                    }
                    .environmentObject(config)
                    .controlSize(.small)
                }
            }
            .onAppear {
                refreshPermissions()
                refreshApplePackStatus()
            }
            .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
                refreshPermissions()
            }
            .controlSize(.small)
    }

    private var split: some View {
        let _ = tabs.epoch
        return HStack(alignment: .top, spacing: 0) {
            if showsRail {
                SettingsSidebar(tab: $tabs.tab) {
                    PreferencesController.shared.close()
                }
                .frame(width: 180)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Theme.windowFill)
        }
    }

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                pageHeader
                pageBody
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal, 26)
            .padding(.top, 26)
            .padding(.bottom, 26)
        }
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(tab.title)
                .font(Theme.TypeScale.title)
            Text(tab.blurb)
                .font(Theme.TypeScale.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var pageBody: some View {
        switch tab {
        case .common: commonPage
        case .shortcuts: shortcutsPage
        case .account: accountPage
        case .providers: providersPage
        case .recognition: recognitionPage
        case .dictionary: dictionaryPage
        case .plugins: pluginsPage
        case .apps: appsPage
        case .privacy: privacyPage
        case .network: networkPage
        case .voice: EmptyView()
        case .about: accountPage
        }
    }

    // MARK: - 常用

    /// 常用只留这 12 行。其余设置在高级里。
    private var commonPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsGroup(L("语言")) {
                settingsRow(L("母语"), detail: L("用来读译文的语言")) {
                    languageMenu(selection: $config.nativeLanguage)
                }
                settingsRow(L("目标语言"), detail: L("原文是母语时译成这种")) {
                    languageMenu(selection: $config.targetLanguage)
                }
            }
            settingsGroup(L("翻译")) {
                settingsRow(L("翻译服务")) {
                    commonServiceMenu
                }
                if let note = commonServiceDivergence {
                    divergenceNote(note) {
                        tabs.tab = .providers
                    }
                }
                settingsRow(L("划词后显示插件条")) {
                    Toggle("", isOn: Binding(
                        get: { plugins.isOn },
                        set: { plugins.isOn = $0 }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
                settingsRow(
                    L("连按空格快捷翻译"),
                    detail: L("在输入框里连按三下空格，把刚打的字换成译文")
                ) {
                    Toggle("", isOn: Binding(
                        get: { config.isFeatureEnabled(.quickTranslate) },
                        set: { config.setFeatureEnabled($0, for: .quickTranslate) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
            }
            settingsGroup(L("实时与会议")) {
                settingsRow(L("识别")) {
                    let choices = config.liveASRChoices()
                    let id = config.resolvedLiveAsr()
                    MenuChip(
                        title: choices.first { $0.id == id }?.name ?? L("Apple 语音分析"),
                        options: choices.map(\.id),
                        label: { choice in choices.first { $0.id == choice }?.name ?? choice },
                        isSelected: { $0 == id },
                        select: { config.setDefaultAsr($0, live: true) }
                    )
                }
                settingsRow(L("翻译")) {
                    let targets = config.catalogTargets()
                    MenuChip(
                        title: liveTranslateName,
                        options: targets.map(\.id),
                        label: { id in targets.first { $0.id == id }?.displayName ?? id },
                        isSelected: { $0 == config.storedTranslateIDs(.live).first },
                        select: { config.setTranslateIDs([$0], .live) }
                    )
                }
            }
            settingsGroup(L("外观与启动")) {
                settingsRow(L("外观")) {
                    MenuChip(
                        title: config.appearance.title,
                        options: AppearanceMode.allCases,
                        label: { $0.title },
                        isSelected: { $0 == config.appearance },
                        select: { config.appearance = $0 }
                    )
                }
                settingsRow(L("浮层透明度")) {
                    Slider(value: $config.panelOpacity, in: 0.35...1)
                        .frame(width: 180)
                        .controlSize(.small)
                }
                settingsRow(L("界面语言")) {
                    MenuChip(
                        title: config.appLanguage.title,
                        options: AppLanguage.allCases,
                        label: { $0.title },
                        isSelected: { $0 == config.appLanguage },
                        select: { config.appLanguage = $0 }
                    )
                }
                settingsRow(L("登录时打开")) {
                    Toggle("", isOn: launchAtLoginBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                if let launchAtLoginError {
                    ErrorLine(text: launchAtLoginError)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                }
            }
            HStack {
                Spacer(minLength: 0)
                Button(L("重新看引导")) { Onboarding.replay() }
                    .buttonStyle(.plain)
                    .font(Theme.TypeScale.body)
                    .foregroundStyle(Theme.accent)
            }
        }
    }

    /// 常用那一行写进划词、剪贴板、截图、文件各自名单的第一家。
    private var commonServiceMenu: some View {
        let targets = config.catalogTargets()
        let current = config.storedTranslateIDs(.select).first
        return MenuChip(
            title: commonServiceName,
            options: targets.map(\.id),
            label: { id in targets.first { $0.id == id }?.displayName ?? id },
            isSelected: { $0 == current },
            select: { setCommonService($0) }
        )
    }

    private var commonServiceName: String {
        let id = config.storedTranslateIDs(.select).first
            ?? config.catalogTargets().first?.id
        return config.catalogTargets().first { $0.id == id }?.displayName ?? L("Google (免费)")
    }

    private var liveTranslateName: String {
        let id = config.storedTranslateIDs(.live).first ?? ""
        if id.isEmpty { return config.catalogTargets().first?.displayName ?? L("Google (免费)") }
        return config.catalogTargets().first { $0.id == id }?.displayName ?? pausedName(id)
    }

    private func setCommonService(_ id: String) {
        for use: TranslateUse in [.select, .clipboard, .ocr, .file] {
            var ids = config.storedTranslateIDs(use)
            ids.removeAll { $0 == id }
            ids.insert(id, at: 0)
            config.setTranslateIDs(ids, use)
        }
    }

    /// 划词、剪贴板、截图、文件的第一家跟常用那一行不一样时，点了跳到高级。
    private var commonServiceDivergence: String? {
        let primary = config.storedTranslateIDs(.select).first
        let uses: [(use: TranslateUse, label: String)] = [
            (.clipboard, L("剪贴板")),
            (.ocr, L("截图")),
            (.file, L("文件")),
        ]
        let drifted = uses.filter { item in
            let first = config.storedTranslateIDs(item.use).first
            return first != primary && !(first == nil && primary == nil)
        }
        guard !drifted.isEmpty else { return nil }
        return drifted.map { item in
            let id = config.storedTranslateIDs(item.use).first ?? ""
            let name = config.catalogTargets().first { $0.id == id }?.displayName ?? pausedName(id)
            return "\(item.label) \(name)"
        }.joined(separator: "、")
    }

    private func languageMenu(selection: Binding<TargetLanguage>) -> some View {
        MenuChip(
            title: selection.wrappedValue.menuTitle,
            options: TargetLanguage.specific,
            label: { $0.menuTitle },
            isSelected: { $0 == selection.wrappedValue },
            select: { selection.wrappedValue = $0 }
        )
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { on in
                launchAtLoginError = LoginItem.set(on)
                launchAtLogin = LoginItem.isOn
            }
        )
    }

    // MARK: - 快捷键

    private var shortcutsPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsGroup(L("主窗口")) {
                hotkeyRow(.openMain, spec: $config.hotkeyOpenMain)
            }
            settingsGroup(L("翻译")) {
                hotkeyRow(.select, spec: $config.hotkeySelect)
                hotkeyRow(.clipboard, spec: $config.hotkeyClipboard)
                hotkeyRow(.ocr, spec: $config.hotkeyOCR)
                hotkeyRow(.file, spec: $config.hotkeyFile)
            }
            settingsGroup(L("快捷翻译")) {
                settingsRow(L("触发")) {
                    PillSegmented(
                        selection: Binding(
                            get: { config.hotkeyQuick.isBareSpace },
                            set: { bare in
                                if bare {
                                    config.setHotkey(.quickTranslateDefault, for: .quickTranslate)
                                } else if config.hotkeyQuick.isBareSpace {
                                    config.setHotkey(
                                        HotkeySpec(keyCode: HotkeySpec.Key.space, carbonModifiers: 2048),
                                        for: .quickTranslate
                                    )
                                }
                            }
                        ),
                        options: [(true, L("连按三下空格")), (false, L("组合键"))]
                    )
                }
                if !config.hotkeyQuick.isBareSpace {
                    hotkeyRow(.quickTranslate, spec: $config.hotkeyQuick)
                }
                hotkeyRow(.quickUndo, spec: $config.hotkeyQuickUndo)
            }
            settingsGroup(L("实时与会议")) {
                hotkeyRow(.liveCaptions, spec: $config.hotkeyLiveCaptions)
                hotkeyRow(.mediaCaptions, spec: $config.hotkeyMediaCaptions)
            }
            settingsGroup(L("查词和记录")) {
                hotkeyRow(.dictionary, spec: $config.hotkeyDictionary)
                hotkeyRow(.history, spec: $config.hotkeyHistory)
            }
            HStack {
                Spacer(minLength: 0)
                Button(L("恢复默认快捷键")) {
                    config.resetHotkeysToDefaults()
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: - 账号与 Pro

    private var accountPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            accountStatusCard
            accountKeyBlock
            settingsGroup(L("免费版和 Pro")) {
                planCompareRow(L("划词翻译、快捷翻译、截图、剪贴板"), L("都能用"))
                planCompareRow(L("同时开几家翻译"), L("免费 1 家 · Pro 不限"))
                planCompareRow(L("文件翻译"), L("免费 5000 字以内 · Pro 不限"))
                planCompareRow(L("继续对话、这次换模型"), "Pro")
            }
            #if KORGI_DEV
            settingsGroup(L("开发")) {
                settingsRow(L("按免费版运行"), detail: L("只在开发版里出现")) {
                    Toggle("", isOn: Binding(get: { !pro.devUnlocked }, set: { pro.devUnlocked = !$0 }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }
            #endif
            settingsGroup(L("关于")) {
                settingsRow(L("版本")) {
                    HStack(spacing: 8) {
                        Text(String(describing: AppInfo.fullVersion))
                            .font(Theme.TypeScale.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        PageButton(title: checkingUpdate ? L("检查中…") : L("检查更新…")) {
                            checkingUpdate = true
                            Task {
                                let outcome = await UpdateChecker.check()
                                checkingUpdate = false
                                UpdateChecker.presentResult(outcome)
                            }
                        }
                        .disabled(checkingUpdate)
                    }
                }
                settingsRow(L("联系")) {
                    HStack(spacing: 8) {
                        Text(L("微信扫码添加企业微信"))
                            .font(Theme.TypeScale.caption)
                            .foregroundStyle(.secondary)
                        Button {
                            showWeChatQR.toggle()
                        } label: {
                            ContactIcon(kind: .wechat)
                        }
                        .buttonStyle(.plain)
                        .help(L("微信"))
                        Button {
                            NSWorkspace.shared.open(AppInfo.xProfileURL)
                        } label: {
                            ContactIcon(kind: .x)
                        }
                        .buttonStyle(.plain)
                        .help("X")
                    }
                }
                if showWeChatQR, let image = AppInfo.weChatQR {
                    VStack(spacing: 6) {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.none)
                            .frame(width: 168, height: 168)
                        Text(L("扫码添加企业微信"))
                            .font(Theme.TypeScale.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                Button {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                        showThanks.toggle()
                    }
                } label: {
                    HStack {
                        Text(L("致谢"))
                            .font(Theme.TypeScale.body)
                            .foregroundStyle(.primary)
                        KIconView(.chevR, size: 9)
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(showThanks ? 90 : 0))
                        Spacer(minLength: 8)
                        Text(L("声纹模型、开源组件、服务商标识"))
                            .font(Theme.TypeScale.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 38)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if showThanks {
                    thanksBlock
                        .padding(.horizontal, 14)
                        .padding(.bottom, 10)
                }
            }
        }
    }

    private var accountStatusCard: some View {
        HStack(alignment: .center, spacing: 14) {
            // 效果图状态卡的图标是 40 磅底、圆角 8、强调色 12%，里面一颗四角星。
            KIconView(.spark, size: 20)
                .foregroundStyle(Theme.accent)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.accent.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(accountHeadline)
                    .font(Theme.TypeScale.reading)
                    .fontWeight(.semibold)
                Text(accountSubline)
                    .font(Theme.TypeScale.label)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if !pro.purchased && !Pro.testAccessOpen {
                if Pro.channel == .store {
                    PageButton(title: pro.products[Pro.productID].map { String(format: L("购买 Pro（%@）"), $0.displayPrice) } ?? L("购买 Pro"), primary: true) {
                        Task { await pro.purchase(Pro.productID) }
                    }
                    .disabled(pro.busy || pro.products[Pro.productID] == nil)
                } else {
                    PageButton(title: L("购买 Pro"), primary: true) {
                        if let url = LicenseEndpoint.purchaseURL { NSWorkspace.shared.open(url) }
                    }
                    .disabled(LicenseEndpoint.purchaseURL == nil)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(Theme.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 0.5)
        )
    }

    private var accountHeadline: String {
        #if KORGI_DEV
        if pro.devUnlocked { return L("开发版，当作已购买") }
        #endif
        if pro.purchased { return L("已购买") }
        if Pro.testAccessOpen { return L("Pro 试用中") }
        if let days = pro.trialDaysLeft { return String(format: L("试用中，剩余 %@ 天"), String(days)) }
        return L("免费版")
    }

    private var accountSubline: String {
        if Pro.testAccessOpen { return L("到 2026-12-31。之后回到免费版，免费版的功能照常能用。") }
        if pro.purchased {
            return Pro.channel == .direct
                ? L("一把钥匙最多用在 3 台 Mac 上。")
                : L("一次购买，之后一直可用。")
        }
        if Pro.channel == .direct {
            switch license.record?.standing {
            case .displaced: return L("这台已让出名额，现在是免费版")
            case .revoked: return L("钥匙已失效，现在是免费版")
            default: break
            }
        }
        if pro.trialEnd != nil { return L("试用已结束，现在是免费版") }
        return Pro.channel == .store
            ? L("一次购买，之后一直可用。先试用 14 天也行，试用结束不会自动扣费。")
            : L("一次购买，之后一直可用。一把钥匙最多用在 3 台 Mac 上。")
    }

    @ViewBuilder
    private var accountKeyBlock: some View {
        if Pro.channel == .store && !pro.purchased && !Pro.testAccessOpen {
            settingsGroup(L("购买")) {
                settingsRow(L("试用")) {
                    if pro.trialEnd == nil {
                        PageButton(title: String(format: L("免费试用 %@ 天"), String(Pro.trialDays))) {
                            Task { await pro.purchase(Pro.trialID) }
                        }
                        .disabled(pro.busy || pro.products[Pro.trialID] == nil)
                    } else {
                        Text(L("试用已用过"))
                            .font(Theme.TypeScale.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                settingsRow(L("已经买过")) {
                    PageButton(title: L("恢复购买")) {
                        Task { await pro.restore() }
                    }
                    .disabled(pro.busy)
                }
                if pro.products[Pro.productID] == nil {
                    Text(L("这一份不是从 App Store 装的，现在买不了 Pro。上面免费版的功能都能用。"))
                        .font(Theme.TypeScale.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 10)
                }
            }
        } else if Pro.channel == .direct && !pro.purchased && !Pro.testAccessOpen {
            settingsGroup(L("钥匙")) {
                // 效果图里钥匙输入框 252，加页按钮之后整列仍是 300。
                fieldRow(L("钥匙")) {
                    HStack(spacing: 8) {
                        TextField("", text: $keyInput, prompt: Text("KORG-XXXX-XXXX-XXXX"))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 252)
                        PageButton(title: L("填入")) {
                            let k = keyInput
                            Task {
                                await license.enter(key: k)
                                if license.isActive { keyInput = "" }
                            }
                        }
                        .disabled(license.busy || keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                Button { showReissue.toggle() } label: {
                    HStack(spacing: 4) {
                        Text(L("忘了钥匙？"))
                        ChromeChevron()
                            .rotationEffect(.degrees(showReissue ? 180 : 0))
                    }
                    .font(Theme.TypeScale.label)
                    .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 38)
                if showReissue {
                    fieldRow(L("付款时用的邮箱")) {
                        HStack(spacing: 8) {
                            TextField("", text: $emailInput, prompt: Text("name@example.com"))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 252)
                            PageButton(title: L("发回")) {
                                let e = emailInput
                                Task { await license.reissue(email: e) }
                            }
                            .disabled(license.busy || emailInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
                if let note = license.note {
                    Text(note)
                        .font(Theme.TypeScale.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                }
                if !license.isConfigured {
                    Text(L("尚未接入支付系统，现在买不了 Pro。上面免费版的功能都能用。"))
                        .font(Theme.TypeScale.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                }
            }
        } else if Pro.channel == .direct && pro.purchased {
            settingsGroup(L("钥匙")) {
                if let rec = license.record {
                    settingsRow(L("钥匙")) {
                        Text("…" + String(rec.key.suffix(4)))
                            .font(Theme.TypeScale.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        PageButton(title: L("让出这台的名额")) {
                            Task { await license.release() }
                        }
                        .disabled(license.busy)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 38)
                    if rec.releasePending {
                        Text(L("这台先记着要让出，连上系统后自动完成；在那之前仍算已购买。"))
                            .font(Theme.TypeScale.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 8)
                    }
                }
                if let note = license.note {
                    Text(note)
                        .font(Theme.TypeScale.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                }
                Text(L("让出后这台变回免费版，名额空给别的 Mac。只让出这一台，不影响其他电脑。"))
                    .font(Theme.TypeScale.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
        }
    }

    private func planCompareRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(Theme.TypeScale.body)
                .foregroundStyle(.primary)
            Spacer(minLength: 12)
            Text(value)
                .font(Theme.TypeScale.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 38)
    }

    private var thanksBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("声纹模型"))
                .font(Theme.TypeScale.labelMedium)
            Text(L("WeSpeaker ResNet34-LM，在 VoxCeleb 上训练，CC BY 4.0。由 wquguru/cicada 转成 Core ML 并重新量化（Apache-2.0）。"))
                .font(Theme.TypeScale.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Link("WeSpeaker", destination: URL(string: "https://github.com/wenet-e2e/wespeaker")!)
                Link("CC BY 4.0", destination: URL(string: "https://creativecommons.org/licenses/by/4.0/")!)
                Link("wquguru/cicada", destination: URL(string: "https://github.com/wquguru/cicada")!)
                Link("Apache-2.0", destination: URL(string: "https://www.apache.org/licenses/LICENSE-2.0")!)
            }
            .font(Theme.TypeScale.caption)
            Text(L("开源组件"))
                .font(Theme.TypeScale.labelMedium)
                .padding(.top, 6)
            Text(L("界面、网络与音频处理只用系统自带的框架，不含第三方库。声纹部分用了 wquguru/cicada 的 Apache-2.0 代码（已改成 Swift 并接入本应用），许可全文和改动说明随应用附在 Resources/LICENSES 与 THIRD-PARTY-NOTICES.md。"))
                .font(Theme.TypeScale.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(L("各服务商的名称与标识归各自所有者，这里只用来标示正在连接的服务，与它们无从属或背书关系。"))
                .font(Theme.TypeScale.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 脱敏

    private var privacyPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsGroup("") {
                settingsRow(L("发出前先让我确认"), detail: L("命中脱敏规则时，先显示将要发出的内容")) {
                    Toggle("", isOn: confirmBeforeSendBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }
            settingsGroup(L("身份和账号")) {
                maskSwitch(L("密钥"), L("API key、私钥、JWT 和密码"), $config.maskPrefs.secrets)
                maskSwitch(L("邮箱"), L("跳过 example.com 和 git 地址"), $config.maskPrefs.email)
                maskSwitch(L("手机号"), L("大陆手机号"), $config.maskPrefs.phone)
                maskSwitch(L("身份证"), L("校验过的号码"), $config.maskPrefs.idCard)
                maskSwitch(L("银行卡"), L("校验过的卡号"), $config.maskPrefs.bankCard)
                maskSwitch(L("护照号"), L("写在护照或 passport 后面的"), $config.maskPrefs.passport)
                maskSwitch(L("生日"), L("写在生日或 birthday 后面，且早于一年前"), $config.maskPrefs.birthday)
                Button {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { showMoreIdentity.toggle() }
                } label: {
                    Text(showMoreIdentity ? L("收起") : L("显示更多：社会安全号、IBAN"))
                        .font(Theme.TypeScale.body)
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 38)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if showMoreIdentity {
                    maskSwitch(L("社会安全号"), L("美国社会安全号"), $config.maskPrefs.ssn)
                    maskSwitch(L("IBAN"), L("校验过的国际账号"), $config.maskPrefs.iban)
                }
            }
            settingsGroup(L("设备和网络")) {
                maskSwitch(L("用户名和主机名"), L("命令行提示符、ssh，以及单独一行的用户名或主机名"), $config.maskPrefs.userHost)
                maskSwitch(L("主目录用户名"), L("/Users 或 /home 里的名字"), $config.maskPrefs.home)
                maskSwitch(L("公网 IP"), L("不含内网、本机和公共 DNS"), $config.maskPrefs.ip)
                Button {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { showMoreDevice.toggle() }
                } label: {
                    Text(showMoreDevice ? L("收起") : L("显示更多：MAC 地址、序列号、云存储桶"))
                        .font(Theme.TypeScale.body)
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 38)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if showMoreDevice {
                    maskSwitch(L("MAC 地址"), L("网卡地址"), $config.maskPrefs.mac)
                    maskSwitch(L("序列号"), L("写在序列号或 S/N 后面的"), $config.maskPrefs.serial)
                    maskSwitch(L("云存储桶"), L("s3、oss 这类地址"), $config.maskPrefs.bucket)
                }
            }
            settingsGroup(L("自定义")) {
                ForEach($config.maskPrefs.entries) { $entry in
                    customEntry($entry)
                }
                Button {
                    let entry = MaskEntry()
                    config.maskPrefs.entries.append(entry)
                    openMask.insert(entry.id)
                } label: {
                    Label(L("新增一条"), systemImage: "plus")
                        .font(Theme.TypeScale.body)
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 38)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Text(L("按字面时英文词两边要断开。写错的正则跳过，不拦发送。"))
                .font(Theme.TypeScale.caption)
                .foregroundStyle(.secondary)
                .padding(.top, -10)
        }
    }

    /// 发出前确认。没有旧字段，这一轮只存，发送流程还是原来的确认窗。
    private var confirmBeforeSendBinding: Binding<Bool> {
        Binding(
            get: { UserDefaults.standard.object(forKey: ConfigKeys.maskConfirmBeforeSend) as? Bool ?? true },
            set: { UserDefaults.standard.set($0, forKey: ConfigKeys.maskConfirmBeforeSend) }
        )
    }

    private func customEntry(_ entry: Binding<MaskEntry>) -> some View {
        let entryID = entry.wrappedValue.id
        let open = openMask.contains(entryID)
        let title = entry.wrappedValue.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                if open { openMask.remove(entryID) } else { openMask.insert(entryID) }
            } label: {
                HStack(spacing: 8) {
                    Text(title.isEmpty ? L("新规则") : title)
                        .font(Theme.TypeScale.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(entry.wrappedValue.kind == .regex ? L("正则") : L("按字面"))
                        .font(Theme.TypeScale.caption)
                        .foregroundStyle(.secondary)
                    KIconView(.chevR, size: 9)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Toggle("", isOn: Binding(
                        get: { !entry.wrappedValue.pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
                        set: { _ in }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(true)
                    .allowsHitTesting(false)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 38)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                fillBlock {
                    fieldRow(L("找什么")) {
                        TextField(
                            "",
                            text: entry.pattern,
                            prompt: Text(entry.wrappedValue.kind == .literal ? L("要脱敏的词") : L("正则"))
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: SettingsMetrics.controlWidth)
                    }
                    fieldRow(L("方式")) {
                        PillSegmented(
                            selection: entry.kind,
                            options: [(MaskEntry.Kind.literal, L("按字面")), (.regex, L("正则"))]
                        )
                    }
                    fieldRow(L("替换成")) {
                        TextField("", text: entry.replacement, prompt: Text(L("留空用占位符")))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: SettingsMetrics.controlWidth)
                    }
                    fieldRow(L("不区分大小写")) {
                        Toggle("", isOn: entry.ignoreCase)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                    fieldRow(L("试一下")) {
                        VStack(alignment: .trailing, spacing: 4) {
                            TextField("", text: $maskProbe, prompt: Text(L("贴一段看看命中")))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: SettingsMetrics.controlWidth)
                            Text(maskProbeResult(entry.wrappedValue))
                                .font(Theme.TypeScale.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: SettingsMetrics.controlWidth, alignment: .leading)
                        }
                    }
                    if let problem = entry.wrappedValue.problem {
                        ErrorLine(text: L(problem))
                            .padding(.horizontal, 12)
                            .padding(.bottom, 6)
                    }
                    HStack {
                        Button(L("删除")) {
                            config.maskPrefs.entries.removeAll { $0.id == entryID }
                            openMask.remove(entryID)
                        }
                        .buttonStyle(.plain)
                        .font(Theme.TypeScale.body)
                        .foregroundStyle(Theme.danger)
                        Spacer(minLength: 8)
                        Button(L("收起")) { openMask.remove(entryID) }
                            .controlSize(.small)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private func maskProbeResult(_ entry: MaskEntry) -> String {
        let sample = maskProbe.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sample.isEmpty else { return "" }
        if let problem = entry.problem { return L(problem) }
        if entry.kind == .literal {
            guard let word = entry.literal else { return L("至少两个字") }
            return sample.localizedCaseInsensitiveContains(word) || sample.contains(word)
                ? L("这段里有")
                : L("这段里没有")
        }
        guard let regex = entry.regex() else { return L("正则写错了") }
        let range = NSRange(sample.startIndex..<sample.endIndex, in: sample)
        let hit = regex.firstMatch(in: sample, options: [], range: range) != nil
        return hit ? L("这段里有") : L("这段里没有")
    }

    /// 标题已经过 `L()`，好让本地化检查看得见这些词。
    private func maskSwitch(_ title: String, _ detail: String, _ isOn: Binding<Bool>) -> some View {
        settingsRow(title, detail: detail) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    // MARK: - 网络与权限

    private var networkPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsGroup(L("网络代理")) {
                fieldRow(L("代理")) {
                    PillSegmented(
                        selection: $config.proxyMode,
                        options: [
                            (ProxyMode.system, L("跟随系统")),
                            (.off, L("不用")),
                            (.custom, L("手动")),
                        ]
                    )
                }
                if config.proxyMode == .custom {
                    fillBlock {
                        fieldRow(L("类型")) {
                            PillSegmented(
                                selection: $config.proxyType,
                                options: ProxyType.allCases.map { ($0, $0 == .http ? "HTTP" : "SOCKS5") }
                            )
                        }
                        fieldRow(L("主机和端口")) {
                            HStack(spacing: 8) {
                                TextField("", text: $config.proxyHost, prompt: Text("127.0.0.1"))
                                    .textFieldStyle(.roundedBorder)
                                TextField("", value: $config.proxyPort, format: .number.grouping(.never))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 72)
                            }
                            .frame(width: SettingsMetrics.controlWidth)
                        }
                        fieldRow(L("用户名")) {
                            TextField("", text: $config.proxyUsername, prompt: Text(L("可选")))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: SettingsMetrics.controlWidth)
                        }
                        fieldRow(L("密码")) {
                            SecureField("", text: $config.proxyPassword, prompt: Text(L("可选")))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: SettingsMetrics.controlWidth)
                        }
                    }
                }
            }
            Text(L("国内访问 Google 免费翻译通常需要代理。"))
                .font(Theme.TypeScale.caption)
                .foregroundStyle(.secondary)
                .padding(.top, -10)

            settingsGroup(L("权限")) {
                permissionRow(
                    title: L("辅助功能"),
                    feature: L("划词翻译读取并写回到别的应用里选中的文字"),
                    trusted: axTrusted
                ) {
                    Onboarding.showPermissions(focus: .accessibility)
                }
                permissionRow(
                    title: L("屏幕录制"),
                    feature: L("截图翻译框选屏幕；实时字幕听系统声音"),
                    trusted: screenTrusted
                ) {
                    Onboarding.showPermissions(focus: .screenCapture)
                }
                permissionRow(
                    title: L("输入监视"),
                    feature: L("连按空格快捷翻译、按住 Fn 说话"),
                    trusted: listenTrusted
                ) {
                    Onboarding.showPermissions(focus: .inputMonitoring)
                }
                permissionRow(
                    title: L("麦克风"),
                    feature: L("实时字幕的麦克风、语音"),
                    trusted: micTrusted
                ) {
                    Onboarding.showPermissions(focus: .microphone)
                }
                permissionRow(
                    title: L("语音识别"),
                    feature: L("Apple 语音识别"),
                    trusted: speechTrusted
                ) {
                    Onboarding.showPermissions(focus: .speech)
                }
            }
            HStack {
                Spacer(minLength: 0)
                Button(L("刷新状态")) { refreshPermissions() }
                    .buttonStyle(.plain)
                    .font(Theme.TypeScale.body)
                    .foregroundStyle(Theme.accent)
            }
        }
    }

    // MARK: - 翻译服务与 AI

    private var providersPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsGroup(L("各功能用哪几家")) {
                useLine(L("划词翻译"), .select)
                useLine(L("翻译剪贴板"), .clipboard)
                useLine(L("截图翻译"), .ocr)
                useLine(L("文件翻译"), .file)
            }
            Text(L("第一家是默认。免费版每个功能 1 家。"))
                .font(Theme.TypeScale.caption)
                .foregroundStyle(.secondary)
                .padding(.top, -10)

            settingsGroup(L("翻译服务")) {
                ForEach(featuredProviders) { p in
                    providerRow(p)
                }
                if !moreProviders.isEmpty {
                    Button {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                            showMoreBuiltin.toggle()
                        }
                    } label: {
                        Text(showMoreBuiltin
                             ? L("收起")
                             : String(format: L("显示更多：%@"), moreProviders.map(\.displayName).joined(separator: "、")))
                            .font(Theme.TypeScale.body)
                            .foregroundStyle(Theme.accent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 38)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if showMoreBuiltin {
                        ForEach(moreProviders) { p in
                            providerRow(p)
                        }
                    }
                }
            }

            settingsGroup(L("AI")) {
                HStack {
                    Spacer(minLength: 0)
                    Button(L("导入…")) { importAI() }
                        .buttonStyle(.plain)
                        .font(Theme.TypeScale.body)
                        .foregroundStyle(Theme.accent)
                    Button(L("导出…")) { exportAI() }
                        .buttonStyle(.plain)
                        .font(Theme.TypeScale.body)
                        .foregroundStyle(Theme.accent)
                        .disabled(config.aiProfiles.isEmpty)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 32)
                if config.aiProfiles.isEmpty {
                    Text(L("还没有 AI 提供商。点「添加提供商…」选一个预设即可。"))
                        .font(Theme.TypeScale.body)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 6)
                }
                ForEach(Array(config.aiProfiles.enumerated()), id: \.element.id) { idx, profile in
                    aiProviderRow(idx: idx, profile: profile)
                }
                Button {
                    providerSheet = .ai
                } label: {
                    Label(L("添加提供商…"), systemImage: "plus")
                        .font(Theme.TypeScale.body)
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 38)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Text(L("导出不含 API Key。"))
                .font(Theme.TypeScale.caption)
                .foregroundStyle(.secondary)
                .padding(.top, -10)

            settingsGroup(L("翻译的细节")) {
                settingsRow(L("同语润色"), detail: L("原文已经是要译成的语言时，轻改措辞并保持结构")) {
                    Toggle("", isOn: $config.polishSameLanguage)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                settingsRow(L("文件翻译用的模型")) {
                    let profiles = config.aiProfiles.filter { config.isAIOn($0) }
                    let current = profiles.first { $0.id == config.fileAIProfileID }
                    MenuChip(
                        title: current?.name ?? L("自动（第一个可用）"),
                        options: [""] + profiles.map(\.id),
                        label: { id in
                            guard !id.isEmpty else { return L("自动（第一个可用）") }
                            guard let profile = profiles.first(where: { $0.id == id }) else { return id }
                            return config.isPaused("ai:\(profile.id)")
                                ? String(format: L("%@（已暂停，先用第一个可用的）"), profile.name)
                                : profile.name
                        },
                        isSelected: { $0 == config.fileAIProfileID },
                        select: { config.fileAIProfileID = $0 }
                    )
                }
                settingsRow(L("扫描件整页交给视觉模型"), detail: L("数字版 PDF 仍抽文字。看不了图的模型会退回识别。")) {
                    Toggle("", isOn: $file.directVision)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }
            if !Pro.unlocked {
                HStack(spacing: 6) {
                    Text(L("免费版单份原文 5000 字符以内，中文一个字算一个。"))
                        .font(Theme.TypeScale.caption)
                        .foregroundStyle(.secondary)
                }
            }

            settingsGroup(L("测试")) {
                HStack {
                    Text(L("给已开的服务发一句 hello world"))
                        .font(Theme.TypeScale.body)
                    Spacer(minLength: 8)
                    if testing {
                        ProgressView().controlSize(.small)
                    }
                    Button(testing ? L("测试中…") : L("测试")) {
                        runTest()
                    }
                    .controlSize(.small)
                    .disabled(testing)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 38)
                if !testDirection.isEmpty {
                    Text(testDirection)
                        .font(Theme.TypeScale.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                }
                ForEach(Array(testOutcomes.enumerated()), id: \.element.id) { _, outcome in
                    testResultCard(outcome)
                        .padding(.horizontal, 14)
                }
                if !testOutcomes.isEmpty && !testing {
                    HStack {
                        Spacer(minLength: 0)
                        Button(L("清除")) {
                            testOutcomes = []
                            testDirection = ""
                        }
                        .buttonStyle(.plain)
                        .font(Theme.TypeScale.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                }
            }
        }
    }

    /// 常用的几家摊开。其余折在「显示更多」里。
    private var featuredProviders: [ProviderID] {
        [.googleFree, .deepl, .microsoft, .baidu, .youdao, .apple]
    }

    private var moreProviders: [ProviderID] {
        ProviderID.allCases.filter { !featuredProviders.contains($0) }
    }

    private func useLine(_ title: String, _ use: TranslateUse) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 12) {
                Text(title)
                    .font(Theme.TypeScale.body)
                Spacer(minLength: 8)
                providerTags(use)
            }
            if providerAtCap(use) {
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    Text(config.translateCap(use) == 1 ? L("免费版只用默认一家") : L("免费版最多同时两家"))
                        .font(Theme.TypeScale.caption)
                        .foregroundStyle(Theme.attention)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(minHeight: SettingsChrome.rowMinHeight)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
        }
    }

    // MARK: - 识别、朗读与 OCR

    private var recognitionPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsGroup(L("语音识别")) {
                asrBuiltInRow(
                    title: L("Apple 语音分析"),
                    detail: L("系统语音模型，实时和媒体都能用"),
                    on: Binding(get: { config.asrAnalyzerEnabled }, set: { config.setASRAnalyzer($0) }),
                    isDefault: config.resolvedLiveAsr() == "analyzer"
                )
                asrBuiltInRow(
                    title: L("Apple 语音"),
                    detail: L("旧引擎"),
                    on: Binding(get: { config.asrAppleEnabled }, set: { config.setASRApple($0) }),
                    isDefault: config.resolvedLiveAsr() == "apple"
                )
                if config.asrAppleEnabled {
                    settingsRow(L("优先本机识别"), detail: L("本机没识别出字时再走网络")) {
                        Toggle("", isOn: $config.asrAppleOnDevice)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                }
                ForEach(Array(config.asrProfiles.enumerated()), id: \.element.id) { idx, profile in
                    asrProfileRow(idx: idx, profile: profile)
                }
                Button {
                    providerSheet = .asr
                } label: {
                    Label(L("添加识别服务…"), systemImage: "plus")
                        .font(Theme.TypeScale.body)
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 38)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Text(L("实时字幕和媒体字幕的识别下拉只列出打开的这些。"))
                .font(Theme.TypeScale.caption)
                .foregroundStyle(.secondary)
                .padding(.top, -10)

            settingsGroup(L("媒体字幕")) {
                settingsRow(L("默认识别")) {
                    let choices = config.mediaASRChoices()
                    let id = config.resolvedMediaAsr()
                    MenuChip(
                        title: choices.first { $0.id == id }?.name ?? L("Apple 语音分析"),
                        options: choices.map(\.id),
                        label: { choice in choices.first { $0.id == choice }?.name ?? choice },
                        isSelected: { $0 == id },
                        select: { config.setDefaultAsr($0, live: false) }
                    )
                }
                settingsRow(L("默认翻译")) {
                    let targets = config.catalogTargets()
                    let id = config.storedTranslateIDs(.media).first ?? ""
                    MenuChip(
                        title: targets.first { $0.id == id }?.displayName
                            ?? targets.first?.displayName
                            ?? L("Google (免费)"),
                        options: targets.map(\.id),
                        label: { choice in targets.first { $0.id == choice }?.displayName ?? choice },
                        isSelected: { $0 == id },
                        select: { config.setTranslateIDs([$0], .media) }
                    )
                }
                settingsRow(L("同时处理几份"), detail: L("同时在识别或等翻译的音视频，还没开始和已经落盘的不算")) {
                    HStack(spacing: 8) {
                        Text(String(media.concurrentLimit))
                            .font(Theme.TypeScale.body)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Stepper(L("同时处理几份"), value: $media.concurrentLimit, in: 1...10)
                            .labelsHidden()
                    }
                }
            }

            settingsGroup(L("朗读")) {
                if config.enabledTTSChoices().count > 1 {
                    settingsRow(L("用来朗读")) {
                        let choices = config.enabledTTSChoices()
                        MenuChip(
                            title: choices.first { $0.id == config.ttsSelection }?.name ?? L("Apple 系统声音"),
                            options: choices.map(\.id),
                            label: { id in choices.first { $0.id == id }?.name ?? id },
                            isSelected: { $0 == config.ttsSelection },
                            select: { config.ttsSelection = $0 }
                        )
                    }
                }
                settingsRow(L("Apple 系统声音")) {
                    Toggle("", isOn: Binding(
                        get: { config.ttsAppleEnabled },
                        set: { config.setTTSApple($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
                ForEach(Array(config.ttsProfiles.enumerated()), id: \.element.id) { idx, profile in
                    ttsProfileRow(idx: idx, profile: profile)
                }
                Button {
                    providerSheet = .tts
                } label: {
                    Label(L("添加朗读服务…"), systemImage: "plus")
                        .font(Theme.TypeScale.body)
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 38)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Text(L("浮层、词典、文件、字幕、沉浸字幕都用这一家。"))
                .font(Theme.TypeScale.caption)
                .foregroundStyle(.secondary)
                .padding(.top, -10)

            settingsGroup(L("截图识别")) {
                ForEach(OCRProviderID.allCases) { p in
                    ocrProviderRow(p)
                }
            }
            Text(L("在截图选区里涂抹再识别的地方，再识别。云识别失败时用涂过的图退回 Apple Vision。"))
                .font(Theme.TypeScale.caption)
                .foregroundStyle(.secondary)
                .padding(.top, -10)

            settingsGroup(L("识别词表")) {
                asrTermsBody
            }
        }
    }

    private func asrBuiltInRow(title: String, detail: String, on: Binding<Bool>, isDefault: Bool) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "apple.logo")
                .font(Theme.TypeScale.body)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Theme.TypeScale.body)
                Text(detail)
                    .font(Theme.TypeScale.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if isDefault {
                Text(L("默认"))
                    .font(Theme.TypeScale.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle("", isOn: on)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(minHeight: SettingsChrome.rowMinHeight)
    }

    // MARK: - 词典

    private var dictionaryPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsGroup(L("来源")) {
                ForEach(DictionaryProviderID.allCases) { provider in
                    dictProviderRow(provider)
                }
            }
            if !Pro.unlocked {
                HStack(spacing: 6) {
                    Text(L("免费版只用默认一家"))
                        .font(Theme.TypeScale.caption)
                        .foregroundStyle(.secondary)
                    Text(L("Pro 不限家数，按这个顺序排。"))
                        .font(Theme.TypeScale.caption)
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text(L("Pro 不限家数，按这个顺序排。"))
                    .font(Theme.TypeScale.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, -10)
            }
            settingsGroup(L("显示")) {
                settingsRow(L("翻译短词后展开释义"), detail: L("在翻译浮层里接着显示词典")) {
                    Toggle("", isOn: $config.dictAutoOpen)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }
        }
    }

    // MARK: - 划词插件、按应用、语音

    private var pluginsPage: some View {
        SelectionPluginSettingsSection()
    }

    private var appsPage: some View {
        QuickAppsSection()
    }

    private var asrTermsBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !config.asrTerms.isEmpty {
                FlowTags(spacing: 6) {
                    ForEach(config.asrTerms, id: \.self) { term in
                        HStack(spacing: 4) {
                            Text(term)
                                .font(Theme.TypeScale.label)
                                .lineLimit(1)
                            Button {
                                config.asrTerms.removeAll { $0 == term }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(Theme.TypeScale.micro)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help(L("移出"))
                        }
                        .padding(.leading, 8)
                        .padding(.trailing, 6)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Theme.wellFill))
                    }
                    TextField(L("加一个词，回车"), text: $asrTermDraft)
                        .textFieldStyle(.plain)
                        .font(Theme.TypeScale.label)
                        .frame(minWidth: 120)
                        .onSubmit { addASRTerms() }
                }
            } else {
                TextField(L("加一个词，回车"), text: $asrTermDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.TypeScale.body)
                    .onSubmit { addASRTerms() }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(L("预设词库"))
                    .font(Theme.TypeScale.caption)
                    .foregroundStyle(.secondary)
                FlowTags(spacing: 6) {
                    ForEach(ASRPreset.allCases) { pack in
                        let on = config.asrPresets.contains(pack.rawValue)
                        Button {
                            config.setASRPreset(pack, on: !on)
                        } label: {
                            Text(pack.title)
                                .font(Theme.TypeScale.caption)
                                .foregroundStyle(on ? Theme.accent : Color.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule().fill(on ? Theme.accent.opacity(0.12) : Theme.wellFill)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Text(L("实时字幕、媒体字幕和语音共用，最多 100 个。自己加的优先。"))
                .font(Theme.TypeScale.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func addASRTerms() {
        let parts = asrTermDraft.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return }
        var list = config.asrTerms
        for part in parts {
            let term = String(part.prefix(80))
            guard !list.contains(term), list.count < 100 else { continue }
            list.append(term)
        }
        config.asrTerms = list
        asrTermDraft = ""
    }

    private func hotkeyRow(_ action: HotkeyAction, spec: Binding<HotkeySpec>) -> some View {
        HotkeyRecorderButton(
            action: action,
            enabled: Binding(
                get: { config.isFeatureEnabled(action) },
                set: { config.setFeatureEnabled($0, for: action) }
            ),
            spec: spec,
            conflictWarning: config.hotkeyConflictWarning(for: action),
            onChange: { config.setHotkey($0, for: action) }
        ) {
            EmptyView()
        }
    }

    // MARK: - 填写块

    /// 一节一张圆角列表。节名空着就不画标题。
    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        SettingsGroup(title: title, content: content)
    }

    /// 一行：标签左对齐，控件贴右。说明在标签下面。
    private func settingsRow<Control: View>(
        _ title: String,
        detail: String? = nil,
        @ViewBuilder control: () -> Control
    ) -> some View {
        SettingsRow(title: title, detail: detail, control: control)
    }

    /// 填写块里的一行。左标签 13 磅，右控件默认宽 300，说明写在控件下面。
    private func fieldRow<Control: View>(
        _ title: String,
        note: String? = nil,
        showsDivider: Bool = true,
        controlWidth: CGFloat = SettingsMetrics.controlWidth,
        @ViewBuilder control: () -> Control
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Text(title)
                    .font(Theme.TypeScale.body)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                control()
                    .frame(width: controlWidth, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: SettingsChrome.rowMinHeight)
            if let note, !note.isEmpty {
                Text(note)
                    .font(Theme.TypeScale.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: SettingsMetrics.controlWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.top, -4)
                    .padding(.bottom, 8)
                    .padding(.trailing, 14)
            }
        }
        .overlay(alignment: .top) {
            if showsDivider {
                Rectangle().fill(Theme.hairline).frame(height: 0.5)
            }
        }
    }

    /// 点开一行之后，填写块就在这一行下面，浅一档底色，左缩进到标题文字列。
    private func fillBlock<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(.leading, SettingsChrome.expandLeading)
        .padding(.trailing, SettingsChrome.expandTrailing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.expandFill)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
        }
        .environment(\.settingsFieldWidth, SettingsMetrics.controlWidth)
    }

    /// 服务行：左名称，右状态 / 默认 / 开关。展开时 chevron 跟在名称旁。
    private func serviceRowChrome<
        Label: View,
        Trailing: View
    >(
        expanded: Bool? = nil,
        toggleExpand: (() -> Void)? = nil,
        @ViewBuilder label: () -> Label,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .center, spacing: 8) {
            HStack(spacing: 6) {
                label()
                if let expanded, let toggleExpand {
                    Button(action: toggleExpand) {
                        KIconView(.chevR, size: 9)
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .animation(reduceMotion ? nil : .snappy(duration: 0.16), value: expanded)
                            .frame(width: 12, height: 12)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(expanded ? L("收起") : L("展开"))
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(minHeight: SettingsChrome.rowMinHeight)
        .contentShape(Rectangle())
    }

    private func serviceSwitch(
        isOn: Binding<Bool>,
        ready: Bool,
        helpOn: String = L("停用"),
        helpOff: String = L("启用"),
        helpBlocked: String = L("填好密钥后可启用")
    ) -> some View {
        let on = isOn.wrappedValue
        return Toggle("", isOn: Binding(
            get: { isOn.wrappedValue },
            set: { enabled in
                if enabled && !ready { return }
                isOn.wrappedValue = enabled
            }
        ))
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.small)
        .disabled(!ready && !on)
        .help(ready ? (on ? helpOn : helpOff) : helpBlocked)
    }

    private func fieldNote(_ text: String) -> some View {
        Text(text)
            .font(Theme.TypeScale.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func menuLabel(_ title: String) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(Theme.TypeScale.label)
                .foregroundStyle(.primary)
                .lineLimit(1)
            ChromeChevron()
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Theme.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Theme.chipStroke, lineWidth: 0.5)
        )
    }

    /// 高级里某功能另选了服务。点了跳到那一页。
    private func divergenceNote(_ names: String, jump: @escaping () -> Void) -> some View {
        Button(action: jump) {
            Text(String(format: L("%@在高级里另选了"), names))
                .font(Theme.TypeScale.caption)
                .foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func permissionRow(
        title: String,
        feature: String,
        trusted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        settingsRow(title, detail: feature) {
            HStack(spacing: 8) {
                StatusDot(trusted ? .ok : .attention, trusted ? L("已授权") : L("未授权"))
                if !trusted {
                    Button(L("去授权"), action: action)
                        .controlSize(.small)
                }
            }
        }
    }

    private func refreshPermissions() {
        axTrusted = AXIsProcessTrusted()
        screenTrusted = CGPreflightScreenCaptureAccess()
        listenTrusted = CGPreflightListenEventAccess()
        micTrusted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        speechTrusted = SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    private func refreshApplePackStatus() {
        Task {
            let avail = LanguageAvailability()
            let en = Locale.Language(identifier: "en")
            let zh = Locale.Language(identifier: "zh-Hans")
            let a = await avail.status(from: en, to: zh)
            let b = await avail.status(from: zh, to: en)
            let label: (LanguageAvailability.Status) -> String = { s in
                switch s {
                case .installed: return L("已安装")
                case .supported: return L("未下载")
                case .unsupported: return L("不支持")
                @unknown default: return L("未知")
                }
            }
            await MainActor.run {
                applePackStatus = "en→zh \(label(a)) · zh→en \(label(b))"
            }
        }
    }

    @ViewBuilder
    private func providerRow(_ p: ProviderID) -> some View {
        let on = config.isProviderOn(p)
        let open = openBuiltin.contains(p.rawValue)
        let ready = config.builtinReady(p)
        let expandable = needsProviderFields(p)
        VStack(alignment: .leading, spacing: 0) {
            serviceRowChrome(
                expanded: expandable ? open : nil,
                toggleExpand: expandable ? { toggleBuiltinOpen(p) } : nil
            ) {
                HStack(spacing: 6) {
                    ProviderIconView(provider: p, size: 13)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.displayName)
                            .font(Theme.TypeScale.body)
                        if let detail = providerRowDetail(p) {
                            Text(detail)
                                .font(Theme.TypeScale.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } trailing: {
                HStack(spacing: 8) {
                    if !ready {
                        MissingKeyLabel()
                    } else if on {
                        StatusDot(.ok, L("已连接"))
                    }
                    serviceSwitch(
                        isOn: Binding(
                            get: { config.isProviderOn(p) },
                            set: { config.setProviderOn(p, $0) }
                        ),
                        ready: ready
                    )
                }
            }
            .rowTapToggle { if expandable { toggleBuiltinOpen(p) } }
            if open && expandable {
                fillBlock {
                    providerFields(p)
                }
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.16), value: open)
    }

    private func needsProviderFields(_ p: ProviderID) -> Bool {
        switch p {
        case .googleFree, .mymemory: return false
        default: return true
        }
    }

    private func providerRowDetail(_ p: ProviderID) -> String? {
        switch p {
        case .googleFree: return L("无需密钥，用 Google 公开接口")
        case .apple: return L("本机翻译，首次用某种语言时下载语言包")
        case .mymemory: return L("无需密钥；有额度限制的公开接口")
        default: return nil
        }
    }

    private func toggleBuiltinOpen(_ p: ProviderID) {
        if openBuiltin.contains(p.rawValue) { openBuiltin.remove(p.rawValue) }
        else { openBuiltin.insert(p.rawValue) }
    }

    private func pausedName(_ id: String) -> String {
        if let p = ProviderID(rawValue: id) { return p.displayName }
        return config.aiProfiles.first { "ai:\($0.id)" == id }?.name ?? id
    }

    private func providerAtCap(_ use: TranslateUse) -> Bool {
        guard let cap = config.translateCap(use) else { return false }
        let selected = config.storedTranslateIDs(use)
        return selected.count >= cap && config.catalogTargets().contains { !selected.contains($0.id) }
    }

    private func providerTags(_ use: TranslateUse) -> some View {
        let selected = config.storedTranslateIDs(use)
        let available = config.catalogTargets().filter { !selected.contains($0.id) }
        return ProviderLines(
            items: selected.map { ($0, pausedName($0)) },
            available: available.map { ($0.id, $0.displayName) },
            canAdd: !providerAtCap(use),
            onRemove: { _ = config.toggleTranslate($0, use) },
            onAdd: { _ = config.toggleTranslate($0, use) },
            onMove: { config.moveTranslate(use, from: $0, to: $1) }
        )
    }

    private struct ProviderLines: View {
        let items: [(id: String, title: String)]
        var available: [(id: String, title: String)] = []
        var canAdd = true
        var onRemove: (String) -> Void
        var onAdd: (String) -> Void
        var onMove: (String, String) -> Void
        @State private var dragging: String?

        var body: some View {
            FlowTags(spacing: 6) {
                ForEach(items, id: \.id) { item in
                    ProviderLine(title: item.title) { onRemove(item.id) }
                        .opacity(dragging == item.id ? 0.45 : 1)
                        .onDrag {
                            dragging = item.id
                            return NSItemProvider(object: item.id as NSString)
                        }
                        .onDrop(of: [.plainText], delegate: ReorderDrop(target: item.id, dragging: $dragging, move: onMove))
                }
                if !available.isEmpty {
                    Menu {
                        ForEach(available, id: \.id) { item in
                            Button(item.title) { onAdd(item.id) }
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(Theme.TypeScale.micro)
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Theme.wellFill))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .buttonStyle(.plain)
                    .frame(width: 22, height: 22)
                    .disabled(!canAdd)
                }
            }
        }
    }

    private struct ProviderLine: View {
        let title: String
        var remove: () -> Void
        @State private var hover = false

        var body: some View {
            HStack(spacing: 4) {
                Text(title)
                    .font(Theme.TypeScale.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(Theme.TypeScale.micro)
                        .foregroundStyle(Theme.accent.opacity(0.8))
                        .frame(width: 12, height: 12)
                }
                .buttonStyle(.plain)
                .opacity(hover ? 1 : 0)
                .allowsHitTesting(hover)
            }
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(Theme.accent.opacity(0.14)))
            .fixedSize()
            .onHover { hover = $0 }
        }
    }

    private struct ReorderDrop: DropDelegate {
        let target: String
        @Binding var dragging: String?
        var move: (String, String) -> Void

        func dropEntered(info: DropInfo) {
            guard let dragging, dragging != target else { return }
            move(dragging, target)
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            DropProposal(operation: .move)
        }

        func performDrop(info: DropInfo) -> Bool {
            dragging = nil
            return true
        }
    }

    @ViewBuilder
    private func providerFields(_ p: ProviderID) -> some View {
        switch p {
        case .googleFree:
            EmptyView()
        case .googleCloud:
            SettingsField(title: "API Key", showsDivider: false) {
                SecureField("", text: $config.googleCloudKey, prompt: Text(L("粘贴密钥")))
                    .textFieldStyle(.roundedBorder)
            }
        case .deepl:
            SettingsField(title: "API Key", showsDivider: false) {
                SecureField("", text: $config.deeplKey, prompt: Text(L("粘贴密钥")))
                    .textFieldStyle(.roundedBorder)
            }
            fieldRow(L("用 Free API（api-free.deepl.com）")) {
                Toggle("", isOn: $config.deeplUseFreeAPI)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
        case .apple:
            SettingsField(title: L("语言包"), showsDivider: false) {
                HStack(spacing: 8) {
                    Text(applePackStatus)
                        .font(Theme.TypeScale.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(L("下载…")) {
                        AppleLangPack.presentDownloadPrompt(force: true)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            refreshApplePackStatus()
                        }
                    }
                    .controlSize(.small)
                }
            }
        case .microsoft:
            SettingsField(title: "API Key", showsDivider: false) {
                SecureField("", text: $config.microsoftKey, prompt: Text(L("粘贴密钥")))
                    .textFieldStyle(.roundedBorder)
            }
            SettingsField(title: L("区域")) {
                TextField("", text: $config.microsoftRegion, prompt: Text("eastasia 或 global"))
                    .textFieldStyle(.roundedBorder)
            }
        case .baidu:
            SettingsField(title: L("App ID"), showsDivider: false) {
                TextField("", text: $config.baiduAppID)
                    .textFieldStyle(.roundedBorder)
            }
            SettingsField(title: L("密钥")) {
                SecureField("", text: $config.baiduSecret)
                    .textFieldStyle(.roundedBorder)
            }
        case .youdao:
            SettingsField(title: L("应用 ID"), showsDivider: false) {
                TextField("", text: $config.youdaoAppKey)
                    .textFieldStyle(.roundedBorder)
            }
            SettingsField(title: L("应用密钥")) {
                SecureField("", text: $config.youdaoSecret)
                    .textFieldStyle(.roundedBorder)
            }
        case .caiyun:
            SettingsField(title: L("Token"), showsDivider: false) {
                SecureField("", text: $config.caiyunToken)
                    .textFieldStyle(.roundedBorder)
            }
        case .mymemory:
            EmptyView()
        case .libreTranslate:
            SettingsField(title: L("实例 URL"), showsDivider: false) {
                TextField("", text: $config.libreTranslateURL)
                    .textFieldStyle(.roundedBorder)
            }
            SettingsField(title: L("API Key（可选）"), note: L("可填自建或公共 LibreTranslate 实例")) {
                SecureField("", text: $config.libreTranslateKey)
                    .textFieldStyle(.roundedBorder)
            }
        case .lingva:
            SettingsField(title: L("实例 URL"), note: L("Google 前端镜像，无需密钥；实例不可用时可换地址"), showsDivider: false) {
                TextField("", text: $config.lingvaURL)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    @ViewBuilder
    private func dictProviderRow(_ p: DictionaryProviderID) -> some View {
        let on = config.isDictOn(p)
        let ready = config.dictReady(p)
        let isDefault = config.dictProvider == p
        let needsFields = p.translateProvider.map { !config.isProviderOn($0) && (on || !ready) } ?? false
        VStack(alignment: .leading, spacing: 0) {
            serviceRowChrome {
                HStack(spacing: 6) {
                    Image(systemName: p.systemImage)
                        .font(Theme.TypeScale.body)
                        .frame(width: 16)
                    Text(p.displayName)
                        .font(Theme.TypeScale.body)
                }
            } trailing: {
                HStack(spacing: 8) {
                    if isDefault {
                        Text(L("默认"))
                            .font(Theme.TypeScale.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !ready {
                        MissingKeyLabel()
                    }
                    serviceSwitch(
                        isOn: Binding(
                            get: { config.isDictOn(p) },
                            set: { config.setDictOn(p, $0) }
                        ),
                        ready: ready
                    )
                }
            }
            if needsFields, let translate = p.translateProvider {
                fillBlock {
                    providerFields(translate)
                }
            }
        }
    }

    private func ocrProviderRow(_ p: OCRProviderID) -> some View {
        let on = config.isOCROn(p)
        let isDefault = config.ocrProvider == p
        let open = openOCR.contains(p.rawValue)
        let expandable = p != .appleVision
        let ready = config.ocrReady(p)
        return VStack(alignment: .leading, spacing: 0) {
            serviceRowChrome(
                expanded: expandable ? open : nil,
                toggleExpand: expandable ? { toggleOCROpen(p) } : nil
            ) {
                ocrRowLabel(p)
            } trailing: {
                HStack(spacing: 8) {
                    if on {
                        if isDefault {
                            Text(L("默认"))
                                .font(Theme.TypeScale.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Button(L("设为默认")) { config.setOCRDefault(p) }
                                .buttonStyle(.plain)
                                .font(Theme.TypeScale.caption)
                                .foregroundStyle(Theme.accent)
                                .opacity(hoveredOCR == p.rawValue ? 1 : 0)
                                .allowsHitTesting(hoveredOCR == p.rawValue)
                        }
                    }
                    if !ready {
                        MissingKeyLabel()
                    }
                    serviceSwitch(
                        isOn: Binding(
                            get: { config.isOCROn(p) },
                            set: { enabled in
                                config.setOCROn(p, enabled)
                                if !enabled { openOCR.remove(p.rawValue) }
                            }
                        ),
                        ready: ready
                    )
                }
            }
            .rowTapToggle { if expandable { toggleOCROpen(p) } }
            .onHover { inside in
                if inside { hoveredOCR = p.rawValue }
                else if hoveredOCR == p.rawValue { hoveredOCR = nil }
            }
            if open && expandable {
                fillBlock {
                    ocrProviderFields(p)
                }
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.16), value: open)
    }

    private func toggleOCROpen(_ p: OCRProviderID) {
        if openOCR.contains(p.rawValue) { openOCR.remove(p.rawValue) }
        else { openOCR.insert(p.rawValue) }
    }

    private func ocrRowLabel(_ p: OCRProviderID) -> some View {
        HStack(spacing: 6) {
            ProviderIconView(ocr: p, size: 13)
            Text(p.displayName)
        }
    }

    @ViewBuilder
    private func ocrProviderFields(_ p: OCRProviderID) -> some View {
        switch p {
        case .appleVision:
            EmptyView()
        case .baidu, .baiduAccurate:
            syncKeysToggle($config.ocrBaiduSync, title: L("和翻译服务里的百度用同一个密钥"), first: true)
            SettingsField(title: L("App ID")) {
                TextField("", text: config.ocrBaiduSync ? $config.baiduAppID : $config.ocrBaiduAppID)
                    .textFieldStyle(.roundedBorder)
            }
            SettingsField(title: L("密钥")) {
                SecureField("", text: config.ocrBaiduSync ? $config.baiduSecret : $config.ocrBaiduSecret)
                    .textFieldStyle(.roundedBorder)
            }
        case .youdao:
            syncKeysToggle($config.ocrYoudaoSync, title: L("和翻译服务里的有道用同一个密钥"), first: true)
            SettingsField(title: L("应用 ID")) {
                TextField("", text: config.ocrYoudaoSync ? $config.youdaoAppKey : $config.ocrYoudaoAppKey)
                    .textFieldStyle(.roundedBorder)
            }
            SettingsField(title: L("应用密钥")) {
                SecureField("", text: config.ocrYoudaoSync ? $config.youdaoSecret : $config.ocrYoudaoSecret)
                    .textFieldStyle(.roundedBorder)
            }
        case .tencent:
            SettingsField(title: "SecretId", showsDivider: false) {
                TextField("", text: $config.tencentSecretID)
                    .textFieldStyle(.roundedBorder)
            }
            SettingsField(title: "SecretKey") {
                SecureField("", text: $config.tencentSecretKey)
                    .textFieldStyle(.roundedBorder)
            }
        case .googleVision:
            syncKeysToggle($config.ocrGoogleSync, title: L("和翻译服务里的 Google 用同一个密钥"), first: true)
            SettingsField(title: "API Key") {
                SecureField("", text: config.ocrGoogleSync ? $config.googleCloudKey : $config.ocrGoogleKey, prompt: Text(L("粘贴密钥")))
                    .textFieldStyle(.roundedBorder)
            }
        case .azure:
            SettingsField(title: L("终结点"), showsDivider: false) {
                TextField("", text: $config.azureVisionEndpoint, prompt: Text("https://{resource}.cognitiveservices.azure.com"))
                    .textFieldStyle(.roundedBorder)
            }
            SettingsField(title: L("密钥")) {
                SecureField("", text: $config.azureVisionKey)
                    .textFieldStyle(.roundedBorder)
            }
        case .ocrSpace:
            SettingsField(title: "API Key", showsDivider: false) {
                SecureField("", text: $config.ocrSpaceKey)
                    .textFieldStyle(.roundedBorder)
            }
        case .aiVision:
            fieldRow(L("模型"), showsDivider: false) {
                let profiles = config.aiProfiles.filter { config.isAIOn($0) }
                MenuChip(
                    title: profiles.first { $0.id == config.ocrAIProfileID }?.name ?? L("自动（第一个）"),
                    options: [""] + profiles.map(\.id),
                    label: { id in
                        id.isEmpty ? L("自动（第一个）") : (profiles.first { $0.id == id }?.name ?? id)
                    },
                    isSelected: { $0 == config.ocrAIProfileID },
                    select: { config.ocrAIProfileID = $0 }
                )
            }
        }
    }


    /// 同传这类预设的 id 是 `qwen-live`，图标挂在关联的翻译提供商上。
    private func asrIconPreset(_ profile: ASRProfile) -> String {
        if let preset = ASRPresetDef.find(profile.preset), !preset.aiPreset.isEmpty {
            return preset.aiPreset
        }
        return profile.preset
    }

    private func ttsIconPreset(_ profile: TTSProfile) -> String {
        if let preset = TTSPresetDef.find(profile.preset), !preset.aiPreset.isEmpty {
            return preset.aiPreset
        }
        return profile.preset
    }

    private func asrProfileRow(idx: Int, profile: ASRProfile) -> some View {
        let on = config.asrProfiles.indices.contains(idx) && config.asrProfiles[idx].enabled
        let expanded = expandedASRIds.contains(profile.id)
        let ready = config.asrProfileReady(profile)
        return VStack(alignment: .leading, spacing: 0) {
            serviceRowChrome(
                expanded: expanded,
                toggleExpand: { toggleASRExpanded(profile.id) }
            ) {
                HStack(spacing: 6) {
                    ProviderIconView(aiPreset: asrIconPreset(profile), name: profile.name, size: 13)
                    Text(profile.name.isEmpty ? L("未命名") : profile.name)
                        .font(Theme.TypeScale.body)
                }
            } trailing: {
                HStack(spacing: 8) {
                    if !ready {
                        MissingKeyLabel()
                    } else if on {
                        StatusDot(.ok, L("已连接"))
                    }
                    serviceSwitch(
                        isOn: Binding(
                            get: { config.asrProfiles.indices.contains(idx) && config.asrProfiles[idx].enabled },
                            set: { config.setASROn(at: idx, $0) }
                        ),
                        ready: ready
                    )
                }
            }
            .rowTapToggle { toggleASRExpanded(profile.id) }
            if expanded {
                fillBlock {
                    asrProfileFields(idx)
                    HStack {
                        Button(L("移除这家")) {
                            expandedASRIds.remove(profile.id)
                            config.removeASR(at: idx)
                        }
                        .buttonStyle(.plain)
                        .font(Theme.TypeScale.label)
                        .foregroundStyle(Theme.danger)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private func toggleASRExpanded(_ id: String) {
        if expandedASRIds.contains(id) { expandedASRIds.remove(id) }
        else { expandedASRIds.insert(id) }
    }

    @ViewBuilder
    private func asrProfileFields(_ idx: Int) -> some View {
        let profile = config.asrProfiles.indices.contains(idx) ? config.asrProfiles[idx] : ASRProfile.fromPreset(ASRPresetDef.all[0])
        let preset = ASRPresetDef.find(profile.preset)
        if preset?.interpWire != nil {
            interpProfileFields(idx, profile: profile, preset: preset)
        } else {
            whisperProfileFields(idx, profile: profile, preset: preset)
        }
    }

    /// 同传服务：地址总是自己的 WebSocket，密钥可以跟同一家的翻译服务共用。
    @ViewBuilder
    private func interpProfileFields(_ idx: Int, profile: ASRProfile, preset: ASRPresetDef?) -> some View {
        let canSync = !(preset?.aiPreset ?? "").isEmpty
        if canSync {
            syncKeysToggle(asrSyncBinding(idx), first: true)
            if profile.syncAI { syncKeyNotice(aiPreset: preset?.aiPreset ?? "") }
        }
        SettingsField(title: L("连接地址")) {
            TextField("", text: asrBinding(idx, \.baseURL), prompt: Text(preset?.baseURL ?? "wss://"))
                .textFieldStyle(.roundedBorder)
        }
        if !borrowsKey(profile.syncAI, aiPreset: preset?.aiPreset ?? "") {
            SettingsField(title: "API Key") {
                SecureField("", text: asrKeyBinding(idx), prompt: Text(L("粘贴密钥")))
                    .textFieldStyle(.roundedBorder)
            }
        }
        SettingsField(title: L("模型")) {
            ModelComboBox(text: asrBinding(idx, \.model), items: preset?.models ?? [], placeholder: preset?.model ?? "")
                .frame(height: 24)
        }
        if preset?.interpWire == .qwen {
            let voices = [""] + QwenInterpVoice.all.map(\.voice)
            let chosen = profile.voice.trimmingCharacters(in: .whitespacesAndNewlines)
            MenuChip(
                title: chosen.isEmpty ? L("译音音色：默认") : String(format: L("译音音色：%@"), QwenInterpVoice.name(for: chosen)),
                options: voices,
                label: { voice in
                    voice.isEmpty ? L("默认") : "\(QwenInterpVoice.name(for: voice)) · \(voice)"
                },
                isSelected: { $0 == chosen },
                select: { voice in
                    guard config.asrProfiles.indices.contains(idx) else { return }
                    var next = config.asrProfiles[idx]
                    next.voice = voice
                    config.asrProfiles[idx] = next
                }
            )
            .help(L("同传译音用这把声音。改了之后，下次开始生效。"))
        }
        Text(preset?.interpWire == .qwen
             ? L("可以直接贴百炼控制台给的业务空间地址，会自动换成同传用的 WebSocket 地址。")
             : L("用 GA 版 Realtime 接口，按分钟计费。"))
            .font(Theme.TypeScale.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func whisperProfileFields(_ idx: Int, profile: ASRProfile, preset: ASRPresetDef?) -> some View {
        let canSync = !(preset?.aiPreset ?? "").isEmpty
        if canSync {
            syncKeysToggle(asrSyncBinding(idx), first: true)
            if profile.syncAI { syncKeyNotice(aiPreset: preset?.aiPreset ?? "") }
        }
        if !borrowsKey(profile.syncAI, aiPreset: preset?.aiPreset ?? "") {
            SettingsField(title: "Base URL") {
                TextField("", text: asrBinding(idx, \.baseURL), prompt: Text(preset?.baseURL ?? "https://api.example.com/v1"))
                    .textFieldStyle(.roundedBorder)
            }
            SettingsField(title: (preset?.noKey ?? false) ? L("API Key（可选）") : "API Key") {
                SecureField("", text: asrKeyBinding(idx))
                    .textFieldStyle(.roundedBorder)
            }
        }
        SettingsField(title: L("模型")) {
            ASRModelPicker(idx: idx)
                .environmentObject(config)
        }
    }

    private func asrBinding(_ idx: Int, _ keyPath: WritableKeyPath<ASRProfile, String>) -> Binding<String> {
        Binding(
            get: {
                guard config.asrProfiles.indices.contains(idx) else { return "" }
                return config.asrProfiles[idx][keyPath: keyPath]
            },
            set: { v in
                guard config.asrProfiles.indices.contains(idx) else { return }
                var p = config.asrProfiles[idx]
                p[keyPath: keyPath] = v
                config.asrProfiles[idx] = p
            }
        )
    }

    private func asrSyncBinding(_ idx: Int) -> Binding<Bool> {
        Binding(
            get: { config.asrProfiles.indices.contains(idx) && config.asrProfiles[idx].syncAI },
            set: { v in
                guard config.asrProfiles.indices.contains(idx) else { return }
                var p = config.asrProfiles[idx]
                p.syncAI = v
                config.asrProfiles[idx] = p
            }
        )
    }

    private func asrKeyBinding(_ idx: Int) -> Binding<String> {
        Binding(
            get: {
                guard config.asrProfiles.indices.contains(idx) else { return "" }
                return config.asrKey(for: config.asrProfiles[idx])
            },
            set: { v in
                guard config.asrProfiles.indices.contains(idx) else { return }
                config.setASRKey(v, for: config.asrProfiles[idx])
            }
        )
    }

    private func ttsProfileRow(idx: Int, profile: TTSProfile) -> some View {
        let on = config.ttsProfiles.indices.contains(idx) && config.ttsProfiles[idx].enabled
        let expanded = expandedTTSIds.contains(profile.id)
        let ready = config.ttsReady(profile)
        return VStack(alignment: .leading, spacing: 0) {
            serviceRowChrome(
                expanded: expanded,
                toggleExpand: { toggleTTSExpanded(profile.id) }
            ) {
                HStack(spacing: 6) {
                    ProviderIconView(aiPreset: ttsIconPreset(profile), name: profile.name, size: 13)
                    Text(profile.name.isEmpty ? L("未命名") : profile.name)
                        .font(Theme.TypeScale.body)
                }
            } trailing: {
                HStack(spacing: 8) {
                    if !ready {
                        MissingKeyLabel()
                    }
                    serviceSwitch(
                        isOn: Binding(
                            get: { config.ttsProfiles.indices.contains(idx) && config.ttsProfiles[idx].enabled },
                            set: { config.setTTSOn(at: idx, $0) }
                        ),
                        ready: ready
                    )
                }
            }
            .rowTapToggle { toggleTTSExpanded(profile.id) }
            if expanded {
                fillBlock {
                    ttsProfileFields(idx)
                    HStack {
                        Button(L("移除这家")) {
                            expandedTTSIds.remove(profile.id)
                            config.removeTTS(at: idx)
                        }
                        .buttonStyle(.plain)
                        .font(Theme.TypeScale.label)
                        .foregroundStyle(Theme.danger)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private func toggleTTSExpanded(_ id: String) {
        if expandedTTSIds.contains(id) { expandedTTSIds.remove(id) }
        else { expandedTTSIds.insert(id) }
    }

    @ViewBuilder
    private func ttsProfileFields(_ idx: Int) -> some View {
        let profile = config.ttsProfiles.indices.contains(idx) ? config.ttsProfiles[idx] : TTSProfile.fromPreset(TTSPresetDef.all[0])
        let preset = TTSPresetDef.find(profile.preset)
        let wire = preset?.wire ?? .openai
        let canSync = !(preset?.aiPreset ?? "").isEmpty
        if canSync {
            syncKeysToggle(ttsSyncBinding(idx), first: true)
            if profile.syncAI { syncKeyNotice(aiPreset: preset?.aiPreset ?? "") }
        }
        if !borrowsKey(profile.syncAI, aiPreset: preset?.aiPreset ?? "") {
            SettingsField(title: wire == .azure ? L("区域") : "Base URL", showsDivider: canSync) {
                if wire == .azure {
                    ModelComboBox(
                        text: ttsBinding(idx, \.baseURL),
                        items: ["eastasia", "southeastasia", "eastus", "eastus2", "westus2", "japaneast", "koreacentral", "westeurope", "northeurope"],
                        placeholder: L("区域，如 eastasia")
                    )
                    .frame(height: 24)
                } else {
                    TextField("Base URL", text: ttsBinding(idx, \.baseURL), prompt: Text(preset?.baseURL ?? "https://api.example.com/v1"))
                        .textFieldStyle(.roundedBorder)
                }
            }
            SettingsField(title: (preset?.noKey ?? false) ? L("API Key（可选）") : "API Key") {
                SecureField("", text: ttsKeyBinding(idx))
                    .textFieldStyle(.roundedBorder)
            }
        }
        if wire != .azure {
            SettingsField(title: wire == .deepgram ? L("音色") : L("模型")) {
                ModelComboBox(
                    text: ttsBinding(idx, \.model),
                    items: preset?.models ?? [],
                    placeholder: wire == .deepgram ? L("音色") : (preset?.model ?? L("模型"))
                )
                .frame(height: 24)
            }
        }
        if wire != .deepgram {
            if preset?.namedVoices == true {
                SettingsField(title: L("音色")) {
                    HStack(spacing: 8) {
                        TextField("", text: ttsBinding(idx, \.voice))
                            .textFieldStyle(.roundedBorder)
                        Menu {
                            ForEach(preset?.voices ?? []) { voice in
                                Button(voice.name) {
                                    guard config.ttsProfiles.indices.contains(idx) else { return }
                                    var p = config.ttsProfiles[idx]
                                    p.voice = voice.id
                                    config.ttsProfiles[idx] = p
                                }
                            }
                        } label: {
                            MenuLabel {
                                Text(L("预设"))
                                    .font(Theme.TypeScale.caption)
                            }
                        }
                        .menuChevron()
                    }
                }
            } else if !(preset?.voices ?? []).isEmpty || !profile.voice.isEmpty {
                SettingsField(title: L("音色")) {
                    ModelComboBox(
                        text: ttsBinding(idx, \.voice),
                        items: preset?.voices.map(\.id) ?? [],
                        placeholder: preset?.voice ?? L("音色")
                    )
                    .frame(height: 24)
                }
            }
        }
        if let note = preset?.note, !note.isEmpty {
            Text(note)
                .font(Theme.TypeScale.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func ttsBinding(_ idx: Int, _ keyPath: WritableKeyPath<TTSProfile, String>) -> Binding<String> {
        Binding(
            get: {
                guard config.ttsProfiles.indices.contains(idx) else { return "" }
                return config.ttsProfiles[idx][keyPath: keyPath]
            },
            set: { v in
                guard config.ttsProfiles.indices.contains(idx) else { return }
                var p = config.ttsProfiles[idx]
                p[keyPath: keyPath] = v
                config.ttsProfiles[idx] = p
            }
        )
    }

    private func ttsSyncBinding(_ idx: Int) -> Binding<Bool> {
        Binding(
            get: { config.ttsProfiles.indices.contains(idx) && config.ttsProfiles[idx].syncAI },
            set: { v in
                guard config.ttsProfiles.indices.contains(idx) else { return }
                var p = config.ttsProfiles[idx]
                p.syncAI = v
                config.ttsProfiles[idx] = p
            }
        )
    }

    private func ttsKeyBinding(_ idx: Int) -> Binding<String> {
        Binding(
            get: {
                guard config.ttsProfiles.indices.contains(idx) else { return "" }
                return config.ttsKey(for: config.ttsProfiles[idx])
            },
            set: { v in
                guard config.ttsProfiles.indices.contains(idx) else { return }
                config.setTTSKey(v, for: config.ttsProfiles[idx])
            }
        )
    }

    private func expandChevron(expanded: Bool, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            KIconView(.chevR, size: 9)
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .animation(reduceMotion ? nil : .snappy(duration: 0.16), value: expanded)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(expanded ? L("收起") : L("展开"))
    }

    /// 开了同步，且对上的翻译提供商确实填了 Key，才藏起自己的 Key 栏。
    private func borrowsKey(_ sync: Bool, aiPreset: String) -> Bool {
        sync && config.syncedAIKey(preset: aiPreset) != nil
    }

    /// 开了同步却借不到 Key 时说清楚为什么，下面会露出自己的 Key 栏。
    @ViewBuilder
    private func syncKeyNotice(aiPreset: String) -> some View {
        if config.syncedAIKey(preset: aiPreset) == nil {
            Group {
                if let ai = config.syncedAIProfile(preset: aiPreset) {
                    Text(String(format: L("翻译提供商「%@」还没填 Key，先用下面填的 Key。"), ai.name))
                } else {
                    Text(L("没找到同一家的翻译提供商，先用下面填的 Key。"))
                }
            }
            .font(Theme.TypeScale.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func syncKeysToggle(_ isOn: Binding<Bool>, title: String = L("同步翻译密钥"), first: Bool = false) -> some View {
        fieldRow(title, showsDivider: !first) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private func aiProviderRow(idx: Int, profile: AIProfile) -> some View {
        let expanded = expandedAIIds.contains(profile.id)
        let on = config.isAIOn(profile)
        let ready = config.aiReady(profile)
        VStack(alignment: .leading, spacing: 0) {
            serviceRowChrome(
                expanded: expanded,
                toggleExpand: { toggleAIExpanded(profile.id) }
            ) {
                HStack(spacing: 6) {
                    ProviderIconView(aiPreset: profile.preset, name: profile.name, size: 13)
                    Text(profile.name.isEmpty ? L("未命名") : profile.name)
                        .font(Theme.TypeScale.body)
                }
            } trailing: {
                HStack(spacing: 8) {
                    if !ready {
                        MissingKeyLabel()
                    } else if !profile.model.isEmpty {
                        StatusDot(.ok, profile.model)
                    } else if on {
                        StatusDot(.ok, L("已连接"))
                    }
                    serviceSwitch(
                        isOn: Binding(
                            get: { config.isAIOn(profile) },
                            set: { config.setAIOn(at: idx, $0) }
                        ),
                        ready: ready
                    )
                }
            }
            .rowTapToggle { toggleAIExpanded(profile.id) }

            if expanded {
                fillBlock {
                    aiEditor(idx: idx)
                    HStack {
                        Button(L("移除这家")) {
                            expandedAIIds.remove(profile.id)
                            config.removeAI(at: idx)
                        }
                        .buttonStyle(.plain)
                        .font(Theme.TypeScale.label)
                        .foregroundStyle(Theme.danger)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private func toggleAIExpanded(_ id: String) {
        if expandedAIIds.contains(id) { expandedAIIds.remove(id) }
        else { expandedAIIds.insert(id) }
    }

    private func aiEditor(idx: Int) -> some View {
        let profile = config.aiProfiles.indices.contains(idx) ? config.aiProfiles[idx] : AIProfile.makeDefault(name: "")
        let preset = AIPresetDef.find(profile.preset)
        return VStack(alignment: .leading, spacing: 0) {
            SettingsField(title: L("名称"), showsDivider: false) {
                TextField("", text: binding(idx, \.name))
                    .textFieldStyle(.roundedBorder)
            }
            SettingsField(title: "Base URL") {
                TextField("", text: binding(idx, \.baseURL), prompt: Text("https://api.example.com/v1"))
                    .textFieldStyle(.roundedBorder)
            }
            if !(preset?.noKey ?? false) {
                SettingsField(title: "API Key") {
                    SecureField("", text: aiKeyBinding(idx), prompt: Text(L("粘贴密钥")))
                        .textFieldStyle(.roundedBorder)
                }
            } else {
                SettingsField(title: L("API Key（可选）"), note: L("本地服务通常无需密钥；设了鉴权再填。")) {
                    SecureField("", text: aiKeyBinding(idx))
                        .textFieldStyle(.roundedBorder)
                }
            }
            SettingsField(title: L("模型")) {
                AIModelPicker(idx: idx)
                    .environmentObject(config)
            }
            SettingsField(title: L("系统提示")) {
                TextField("", text: binding(idx, \.systemPrompt), prompt: Text(L("可空")), axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
            }
            if let urlStr = preset?.keysURL, !urlStr.isEmpty, let url = URL(string: urlStr) {
                HStack {
                    Spacer(minLength: 0)
                    Button(L("怎么拿密钥 ↗")) { NSWorkspace.shared.open(url) }
                        .buttonStyle(.plain)
                        .font(Theme.TypeScale.label)
                        .foregroundStyle(Theme.accent)
                }
                .padding(.bottom, 8)
            }
        }
    }

    private func binding(_ idx: Int, _ keyPath: WritableKeyPath<AIProfile, String>) -> Binding<String> {
        Binding(
            get: {
                guard config.aiProfiles.indices.contains(idx) else { return "" }
                return config.aiProfiles[idx][keyPath: keyPath]
            },
            set: { v in
                guard config.aiProfiles.indices.contains(idx) else { return }
                var p = config.aiProfiles[idx]
                p[keyPath: keyPath] = v
                config.aiProfiles[idx] = p
            }
        )
    }

    private func aiKeyBinding(_ idx: Int) -> Binding<String> {
        Binding(
            get: {
                guard config.aiProfiles.indices.contains(idx) else { return "" }
                return config.aiKey(for: config.aiProfiles[idx])
            },
            set: { v in
                guard config.aiProfiles.indices.contains(idx) else { return }
                config.setAIKey(v, for: config.aiProfiles[idx])
            }
        )
    }

    private func exportAI() {
        guard let data = config.exportAIProvidersJSON() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "korgi-ai-providers.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
    }

    private func importAI() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        let n = config.importAIProvidersJSON(data)
        let a = NSAlert()
        a.messageText = n > 0 ? String(format: L("已导入 %@ 个提供商"), String(describing: n)) : L("没有新提供商可导入")
        a.informativeText = n > 0 ? L("API Key 不会随文件导入，请在开启后自行填写。") : L("文件无效，或提供商 id 已存在。")
        a.runModal()
    }

    @ViewBuilder
    private func testResultCard(_ o: ProviderOutcome) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(o.name)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                if o.text != nil {
                    Label(L("成功"), systemImage: "checkmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(Theme.ok)
                        .help(L("成功"))
                } else {
                    Label(L("失败"), systemImage: "xmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(Theme.danger)
                        .help(L("失败"))
                }
            }
            if let t = o.text {
                Text(t)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let e = o.error, !e.isEmpty {
                ErrorLine(text: e)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(L("无结果"))
                    .font(Theme.TypeScale.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func runTest() {
        testing = true
        testOutcomes = []
        testDirection = ""
        Task {
            let r = await Translator.translateAll("hello world")
            await MainActor.run {
                testDirection = r.direction
                testOutcomes = r.outcomes
                testing = false
            }
        }
    }
}

/// Add-provider sheet: pick a preset, then paste a key.
struct AddProviderSheet: View {
    @EnvironmentObject var config: AppConfig
    @Binding var isPresented: Bool
    var onPick: (AIPresetDef) -> Void
    @State private var query = ""
    @State private var filter: Filter = .all
    @State private var selected: AIPresetDef?

    private enum Filter: String, CaseIterable, Identifiable {
        case all, noKey, china, abroad, local
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return L("全部")
            case .noKey: return L("无需 Key")
            case .china: return L("国内")
            case .abroad: return L("国外")
            case .local: return L("本机")
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("添加 AI 提供商"))
                .font(Theme.TypeScale.reading)
                .fontWeight(.semibold)

            HStack(spacing: 6) {
                KIconView(.search, size: 13)
                    .foregroundStyle(.tertiary)
                TextField(L("搜索名称、说明或网址"), text: $query)
                    .textFieldStyle(.plain)
                    .font(Theme.TypeScale.body)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.wellFill))

            HStack(spacing: 6) {
                ForEach(Filter.allCases) { item in
                    Button {
                        filter = item
                    } label: {
                        Text(item.title)
                    }
                    .buttonStyle(ChipButtonStyle(selected: filter == item))
                }
                Spacer(minLength: 0)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered) { p in
                        Button {
                            selected = p
                        } label: {
                            HStack(spacing: 10) {
                                ProviderIconView(aiPreset: p.id, name: p.name, size: 15)
                                    .frame(width: 22, height: 22)
                                Text(p.name)
                                    .font(Theme.TypeScale.body)
                                    .foregroundStyle(.primary)
                                Spacer(minLength: 8)
                                Text(hostLabel(p))
                                    .font(Theme.TypeScale.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .frame(minHeight: SettingsChrome.rowMinHeight)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(selected?.id == p.id ? Theme.accent.opacity(0.12) : Color.clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(Theme.hairline).frame(height: 0.5)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                        .fill(Theme.cardFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            }

            HStack {
                Spacer(minLength: 0)
                PageButton(title: L("取消")) { isPresented = false }
                PageButton(title: L("添加"), primary: true) {
                    guard let selected else { return }
                    onPick(selected)
                    isPresented = false
                }
                .disabled(selected == nil)
                .opacity(selected == nil ? 0.45 : 1)
            }
        }
        .padding(18)
        .frame(width: 460, height: 520)
        .controlSize(.small)
        .onAppear {
            if selected == nil { selected = filtered.first }
        }
        .onChange(of: filter) { _, _ in
            if let selected, filtered.contains(where: { $0.id == selected.id }) { return }
            self.selected = filtered.first
        }
        .onChange(of: query) { _, _ in
            if let selected, filtered.contains(where: { $0.id == selected.id }) { return }
            self.selected = filtered.first
        }
    }

    private var filtered: [AIPresetDef] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return config.availablePresets().filter { p in
            let matchesQuery = q.isEmpty || [p.name, p.note, p.baseURL, p.id].contains { $0.localizedCaseInsensitiveContains(q) }
            guard matchesQuery else { return false }
            switch filter {
            case .all: return true
            case .noKey: return p.noKey
            case .local: return p.kind == .local
            case .china: return isChina(p)
            case .abroad: return p.kind != .local && !isChina(p)
            }
        }
    }

    private func isChina(_ p: AIPresetDef) -> Bool {
        let host = p.baseURL.lowercased()
        if host.contains(".cn") || host.contains("aliyuncs") || host.contains("bigmodel") || host.contains("moonshot.cn") || host.contains("deepseek.com") || host.contains("volces") || host.contains("baichuan") || host.contains("minimaxi") || host.contains("siliconflow.cn") {
            return true
        }
        return ["deepseek", "moonshot", "zhipu", "qwen", "doubao", "baichuan", "minimax", "yi", "stepfun", "siliconflow"].contains(where: { p.id.hasPrefix($0) })
    }

    private func hostLabel(_ p: AIPresetDef) -> String {
        if p.kind == .local || p.noKey && p.baseURL.isEmpty { return L("本机 · 无需 Key") }
        if p.baseURL.isEmpty { return L("自己填地址") }
        if let host = URL(string: p.baseURL)?.host { return host }
        return p.baseURL
    }
}


/// Model field: auto-detect via `/models`, ComboBox dropdown + free text, refresh + cache.
struct AIModelPicker: View {
    @EnvironmentObject var config: AppConfig
    let idx: Int

    @State private var models: [String] = []
    @State private var loading = false
    @State private var errorText: String = ""
    @State private var didAutoFetch = false

    private var profile: AIProfile {
        guard config.aiProfiles.indices.contains(idx) else {
            return AIProfile.makeDefault(name: "")
        }
        return config.aiProfiles[idx]
    }
    private var preset: AIPresetDef? { AIPresetDef.find(profile.preset) }
    private var allowEmptyKey: Bool { preset?.noKey ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                ModelComboBox(text: modelBinding, items: models)
                    .frame(height: 24)
                Button {
                    Task { await refresh(force: true) }
                } label: {
                    if loading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(L("刷新"))
                    }
                }
                .controlSize(.small)
                .disabled(loading || !canFetch)
                .help(canFetch ? String(format: L("从 %@/models 拉取"), String(describing: profile.baseURL)) : (allowEmptyKey ? L("请先填写 Base URL") : L("请先填写 Base URL 和 API Key")))
            }
            if !errorText.isEmpty {
                Text(errorText)
                    .font(Theme.TypeScale.caption)
                    .foregroundStyle(Theme.attention)
                    .lineLimit(2)
            } else if !models.isEmpty {
                Text(String(format: L("已检测到 %@ 个模型，可下拉选择或直接输入"), String(describing: models.count)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if !canFetch {
                Text(allowEmptyKey
                     ? L("填写 Base URL 后可自动检测模型")
                     : L("填写 Base URL 和 API Key 后可自动检测模型"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            models = ModelListFetcher.cached(profileID: profile.id)
            ensurePresetDefaultSelected()
            if !didAutoFetch {
                didAutoFetch = true
                if canFetch && models.isEmpty {
                    Task { await refresh(force: false) }
                }
            }
        }
        .onChange(of: profile.baseURL) { _, _ in
            if canFetch && models.isEmpty {
                Task { await refresh(force: false) }
            }
        }
        .onChange(of: config.aiKey(for: profile)) { _, _ in
            if canFetch && models.isEmpty {
                Task { await refresh(force: false) }
            }
        }
    }

    private var canFetch: Bool {
        let base = profile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return false }
        if allowEmptyKey { return true }
        return !config.aiKey(for: profile).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: {
                guard config.aiProfiles.indices.contains(idx) else { return "" }
                return config.aiProfiles[idx].model
            },
            set: { v in
                guard config.aiProfiles.indices.contains(idx) else { return }
                var p = config.aiProfiles[idx]
                p.model = v
                config.aiProfiles[idx] = p
            }
        )
    }

    private func ensurePresetDefaultSelected() {
        guard config.aiProfiles.indices.contains(idx) else { return }
        var p = config.aiProfiles[idx]
        if p.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let def = preset?.model, !def.isEmpty {
            p.model = def
            config.aiProfiles[idx] = p
        }
    }

    @MainActor
    private func refresh(force: Bool) async {
        guard config.aiProfiles.indices.contains(idx) else { return }
        let p = config.aiProfiles[idx]
        let base = p.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else {
            errorText = L("请先填写 Base URL")
            return
        }
        if !force, let cached = ModelListFetcher.cachedEntry(profileID: p.id),
           cached.baseURL == base, !cached.models.isEmpty {
            models = cached.models
            applyListSelection(models)
            errorText = ""
            return
        }
        loading = true
        errorText = ""
        defer { loading = false }
        do {
            let key = config.aiKey(for: p)
            let list = try await ModelListFetcher.fetch(
                baseURL: base,
                apiKey: key,
                allowEmptyKey: allowEmptyKey
            )
            ModelListFetcher.store(profileID: p.id, baseURL: base, models: list)
            models = list
            applyListSelection(list)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func applyListSelection(_ list: [String]) {
        guard config.aiProfiles.indices.contains(idx) else { return }
        var p = config.aiProfiles[idx]
        let current = p.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty { return }
        if let def = preset?.model, list.contains(def) {
            p.model = def
            config.aiProfiles[idx] = p
            return
        }
        if let first = list.first {
            p.model = first
            config.aiProfiles[idx] = p
        }
    }
}

struct AddASRSheet: View {
    @EnvironmentObject var config: AppConfig
    @Binding var isPresented: Bool
    var onPick: (ASRPresetDef) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("添加识别提供商"))
                    .font(Theme.TypeScale.reading).fontWeight(.semibold)
                Spacer()
                Button(L("取消")) { isPresented = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)
            List(config.availableASRPresets()) { p in
                Button {
                    onPick(p)
                    isPresented = false
                } label: {
                    HStack(spacing: 10) {
                        ProviderIconView(aiPreset: p.aiPreset.isEmpty ? p.id : p.aiPreset, name: p.name, size: 15)
                            .frame(width: 28, height: 28)
                            .well(radius: 7)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name)
                                .font(Theme.TypeScale.body).fontWeight(.medium)
                            if !p.note.isEmpty {
                                Text(p.note)
                                    .font(Theme.TypeScale.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
        .frame(width: 420, height: 460)
        .controlSize(.small)
    }
}

struct AddTTSSheet: View {
    @EnvironmentObject var config: AppConfig
    @Binding var isPresented: Bool
    var onPick: (TTSPresetDef) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("添加朗读提供商"))
                    .font(Theme.TypeScale.reading).fontWeight(.semibold)
                Spacer()
                Button(L("取消")) { isPresented = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)
            List(config.availableTTSPresets()) { p in
                Button {
                    onPick(p)
                    isPresented = false
                } label: {
                    HStack(spacing: 10) {
                        ProviderIconView(aiPreset: p.aiPreset.isEmpty ? p.id : p.aiPreset, name: p.name, size: 15)
                            .frame(width: 28, height: 28)
                            .well(radius: 7)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name)
                                .font(Theme.TypeScale.body).fontWeight(.medium)
                            if !p.note.isEmpty {
                                Text(p.note)
                                    .font(Theme.TypeScale.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
        .frame(width: 420, height: 460)
        .controlSize(.small)
    }
}

struct ASRModelPicker: View {
    @EnvironmentObject var config: AppConfig
    let idx: Int

    @State private var models: [String] = []
    @State private var loading = false
    @State private var errorText: String = ""
    @State private var didAutoFetch = false

    private var profile: ASRProfile {
        guard config.asrProfiles.indices.contains(idx) else {
            return ASRProfile.fromPreset(ASRPresetDef.all[0])
        }
        return config.asrProfiles[idx]
    }
    private var preset: ASRPresetDef? { ASRPresetDef.find(profile.preset) }
    private var allowEmptyKey: Bool { preset?.noKey ?? false }

    private var resolvedBase: String {
        if profile.syncAI, let ai = config.syncedAIProfile(preset: preset?.aiPreset ?? "") {
            let b = ai.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if !b.isEmpty { return b }
        }
        let own = profile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !own.isEmpty { return own }
        return preset?.baseURL ?? ""
    }

    private var resolvedKey: String {
        if profile.syncAI, let key = config.syncedAIKey(preset: preset?.aiPreset ?? "") {
            return key
        }
        return config.asrKey(for: profile)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                ModelComboBox(text: modelBinding, items: models, placeholder: preset?.model ?? L("选择或输入模型 id"))
                    .frame(height: 24)
                Button {
                    Task { await refresh(force: true) }
                } label: {
                    if loading {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(L("刷新"))
                    }
                }
                .controlSize(.small)
                .disabled(loading || !canFetch)
            }
            if !errorText.isEmpty {
                Text(errorText)
                    .font(Theme.TypeScale.caption)
                    .foregroundStyle(Theme.attention)
                    .lineLimit(2)
            } else if !models.isEmpty {
                Text(String(format: L("已检测到 %@ 个模型，可下拉选择或直接输入"), String(describing: models.count)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            models = merged(ModelListFetcher.cached(profileID: cacheID))
            if !didAutoFetch {
                didAutoFetch = true
                if canFetch { Task { await refresh(force: false) } }
            }
        }
    }

    private var cacheID: String { "asr.\(profile.id)" }

    private var canFetch: Bool {
        guard !resolvedBase.isEmpty else { return false }
        if allowEmptyKey || profile.syncAI { return !resolvedKey.isEmpty || allowEmptyKey }
        return !resolvedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: {
                guard config.asrProfiles.indices.contains(idx) else { return "" }
                return config.asrProfiles[idx].model
            },
            set: { v in
                guard config.asrProfiles.indices.contains(idx) else { return }
                var p = config.asrProfiles[idx]
                p.model = v
                config.asrProfiles[idx] = p
            }
        )
    }

    private func merged(_ fetched: [String]) -> [String] {
        let hints = ["whisper", "sensevoice", "telespeech", "paraformer", "transcribe", "asr", "speech", "audio"]
        let filtered = fetched.filter { id in
            let l = id.lowercased()
            return hints.contains { l.contains($0) }
        }
        var out: [String] = []
        for m in (preset?.models ?? []) + filtered where !m.isEmpty && !out.contains(m) {
            out.append(m)
        }
        let current = profile.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty && !out.contains(current) { out.insert(current, at: 0) }
        return out
    }

    @MainActor
    private func refresh(force: Bool) async {
        guard config.asrProfiles.indices.contains(idx) else { return }
        let base = resolvedBase
        guard !base.isEmpty else {
            errorText = L("请先填写 Base URL")
            return
        }
        if !force, let cached = ModelListFetcher.cachedEntry(profileID: cacheID),
           cached.baseURL == base, !cached.models.isEmpty {
            models = merged(cached.models)
            errorText = ""
            return
        }
        loading = true
        errorText = ""
        defer { loading = false }
        do {
            let list = try await ModelListFetcher.fetch(
                baseURL: base,
                apiKey: resolvedKey,
                allowEmptyKey: allowEmptyKey
            )
            ModelListFetcher.store(profileID: cacheID, baseURL: base, models: list)
            models = merged(list)
        } catch {
            models = merged([])
            errorText = error.localizedDescription
        }
    }
}
