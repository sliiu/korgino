import AppKit
import SwiftUI
import ApplicationServices
import CoreGraphics
import ServiceManagement
import Translation
import UniformTypeIdentifiers

enum PreferencesTab: String, CaseIterable, Identifiable, Hashable {
    case general, providers, recognition, features, privacy, permissions, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return L("通用")
        case .providers: return L("翻译服务")
        case .recognition: return L("识别")
        case .features: return L("功能")
        case .privacy: return L("隐私")
        case .permissions: return L("权限")
        case .about: return L("关于")
        }
    }
    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .providers: return "character.bubble"
        case .recognition: return "text.viewfinder"
        case .features: return "square.grid.2x2"
        case .privacy: return "hand.raised"
        case .permissions: return "lock.shield"
        case .about: return "info.circle"
        }
    }
    var toolbarIdentifier: NSToolbarItem.Identifier {
        NSToolbarItem.Identifier("prefs.\(rawValue)")
    }
    static func from(toolbarIdentifier id: NSToolbarItem.Identifier) -> PreferencesTab? {
        allCases.first { $0.toolbarIdentifier == id }
    }
}

/// Classic Mac preference window: titlebar (traffic lights) above icon toolbar.
@MainActor
final class PreferencesTabs: ObservableObject {
    @Published var tab: PreferencesTab = .general
    @Published var epoch = 0
}

@MainActor
final class PreferencesController: NSObject, NSToolbarDelegate {
    static let shared = PreferencesController()
    private var window: NSWindow?
    private let tabs = PreferencesTabs()
    private var selectedTab: PreferencesTab {
        get { tabs.tab }
        set { tabs.tab = newValue }
    }
    private let toolbarID = "Korgino.PreferencesToolbar"

    func show() {
        if window == nil {
            buildWindow()
        }
        selectTab(selectedTab, updateToolbar: true)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func show(tab: PreferencesTab) {
        selectedTab = tab
        show()
    }

    private func buildWindow() {
        let root = PreferencesPane(tabs: tabs)
            .environmentObject(AppConfig.shared)
        let host = NSHostingView(rootView: AnyView(root))
        host.translatesAutoresizingMaskIntoConstraints = false

        // Classic Mac prefs: separate titlebar (traffic lights top-left) ABOVE
        // the icon toolbar. Do NOT use fullSizeContentView — that merges lights
        // into the same row as the tab icons.
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.title = L("Korgino 设置")
        w.titleVisibility = .visible
        w.titlebarAppearsTransparent = false
        // Without fullSizeContentView, .preference keeps the lights in their own
        // titlebar row and centers the icon toolbar below (System Settings style).
        w.toolbarStyle = .preference
        w.isReleasedWhenClosed = false
        w.setContentSize(NSSize(width: 760, height: 560))
        w.minSize = NSSize(width: 700, height: 480)
        w.maxSize = NSSize(width: 980, height: 900)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 560))
        container.wantsLayer = true
        w.contentView = container

        let toolbar = NSToolbar(identifier: toolbarID)
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.selectedItemIdentifier = selectedTab.toolbarIdentifier
        w.toolbar = toolbar

        container.addSubview(host)
        // Without fullSizeContentView, contentView is already below titlebar+toolbar.
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        w.center()
        window = w
    }

    private func selectTab(_ tab: PreferencesTab, updateToolbar: Bool) {
        tabs.tab = tab
        if updateToolbar {
            window?.toolbar?.selectedItemIdentifier = tab.toolbarIdentifier
        }
        window?.title = tab.title
    }

    func relocalize() {
        guard window != nil else { return }
        let toolbar = NSToolbar(identifier: toolbarID)
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.selectedItemIdentifier = selectedTab.toolbarIdentifier
        window?.toolbar = toolbar
        tabs.epoch += 1
        selectTab(selectedTab, updateToolbar: true)
    }

    @objc private func toolbarTabClicked(_ sender: NSToolbarItem) {
        guard let tab = PreferencesTab.from(toolbarIdentifier: sender.itemIdentifier) else { return }
        selectTab(tab, updateToolbar: true)
    }

    // MARK: NSToolbarDelegate

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        PreferencesTab.allCases.map(\.toolbarIdentifier) + [.flexibleSpace]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        PreferencesTab.allCases.map(\.toolbarIdentifier)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        PreferencesTab.allCases.map(\.toolbarIdentifier)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let tab = PreferencesTab.from(toolbarIdentifier: itemIdentifier) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = tab.title
        item.paletteLabel = tab.title
        item.toolTip = tab.title
        // Prefer large SF Symbols so preference toolbar icons read like Finder
        let cfg = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        if let img = NSImage(systemSymbolName: tab.systemImage, accessibilityDescription: tab.title)?
            .withSymbolConfiguration(cfg) {
            img.isTemplate = true
            item.image = img
        }
        item.target = self
        item.action = #selector(toolbarTabClicked(_:))
        return item
    }
}

private enum ProviderSheet: String, Identifiable {
    case ai, asr, tts
    var id: String { rawValue }
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

private struct RailItem: Identifiable {
    let id: String
    let title: String
    let symbol: String
}

private struct RailButton: View {
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(Theme.TypeScale.body).fontWeight(.medium)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .frame(width: 16)
                Text(title)
                    .font(Theme.TypeScale.body).fontWeight(selected ? .semibold : .regular)
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.16) : (hover ? Color.primary.opacity(0.05) : .clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct PaneSplit<Rail: View, Detail: View>: View {
    @ViewBuilder var rail: () -> Rail
    @ViewBuilder var detail: () -> Detail

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            rail()
                .frame(width: 168)
                .frame(maxHeight: .infinity, alignment: .top)
            Divider()
            detail()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct PreferencesPane: View {
    @ObservedObject var tabs: PreferencesTabs
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var tab: PreferencesTab { tabs.tab }

    @EnvironmentObject var config: AppConfig
    @State private var testOutcomes: [ProviderOutcome] = []
    @State private var testDirection: String = ""
    @State private var testing = false
    @State private var axTrusted = AXIsProcessTrusted()
    @State private var screenTrusted = CGPreflightScreenCaptureAccess()
    @State private var listenTrusted = CGPreflightListenEventAccess()
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
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
    @State private var showWeChatQR = false
    @State private var asrTermDraft = ""
    @State private var featureSection = "translate"
    @State private var providerSection = "builtin"
    @State private var recognitionSection = "ocr"
    @State private var openBuiltin: Set<String> = []
    @State private var openOCR: Set<String> = []
    @State private var hoveredOCR: String?
    @ObservedObject private var pro = Pro.shared
    @ObservedObject private var media = MediaCaptionsController.shared
    @ObservedObject private var file = FileTranslateController.shared
    var body: some View {
        pane
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            loginEnabled = SMAppService.mainApp.status == .enabled
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private var pane: some View {
        let _ = tabs.epoch
        switch tab {
        case .features:
            featuresSplit
        case .providers:
            providersSplit
        case .recognition:
            recognitionSplit
        default:
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .general: generalTab
        case .privacy: privacyTab
        case .permissions: permissionsTab
        case .about: aboutTab
        default: EmptyView()
        }
    }

    private func rail(_ items: [RailItem], selection: Binding<String>) -> some View {
        rail(items, selection: selection) { EmptyView() }
    }

    private func rail<Footer: View>(_ items: [RailItem], selection: Binding<String>, @ViewBuilder footer: () -> Footer) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(items) { item in
                RailButton(title: item.title, symbol: item.symbol, selected: selection.wrappedValue == item.id) {
                    selection.wrappedValue = item.id
                }
            }
            footer()
                .padding(.top, 10)
        }
        .padding(8)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func detailForm<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            content()
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var proStatus: String {
        #if KORGI_DEV
        if pro.devUnlocked { return L("开发版，当作已购买") }
        #endif
        if pro.purchased { return L("已购买") }
        if Pro.testAccessOpen { return L("测试中，Pro 开到 2026-12-31") }
        if Pro.channel == .direct {
            switch license.record?.standing {
            case .displaced: return L("这台已让出名额，现在是免费版")
            case .revoked: return L("钥匙已失效，现在是免费版")
            default: break
            }
        }
        if let days = pro.trialDaysLeft { return String(format: L("试用中，剩余 %@ 天"), String(days)) }
        if pro.trialEnd != nil { return L("试用已结束，现在是免费版") }
        return L("免费版")
    }

    @ViewBuilder
    private var proSections: some View {
        Section {
            LabeledContent("Pro", value: proStatus)
            #if KORGI_DEV
            Toggle(isOn: Binding(get: { !pro.devUnlocked }, set: { pro.devUnlocked = !$0 })) {
                Text(L("按免费版运行"))
                Text(L("只在开发版里出现"))
            }
            .toggleStyle(SegmentedToggleStyle())
            #endif
        } footer: {
            if !pro.purchased && !Pro.testAccessOpen {
                Text(Pro.channel == .store
                     ? L("一次购买，之后一直可用。先试用 14 天也行，试用结束不会自动扣费。")
                     : L("一次购买，之后一直可用。一把钥匙最多用在 3 台 Mac 上。"))
            }
        }
        if !pro.purchased && !Pro.testAccessOpen {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    Text(L("免费版就能用划词、快捷翻译、剪贴板、截图、词典、收藏、实时字幕和语音。快捷翻译两边都只用一家。"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    planTable(groups: [
                        (L("同时几家"), Self.providerRows),
                        (L("能用多少"), Self.amountRows),
                    ])
                }
                .padding(.vertical, 4)
            }
            if Pro.channel == .store {
                Section {
                    HStack {
                        Button(pro.products[Pro.productID].map { String(format: L("购买 Pro（%@）"), $0.displayPrice) } ?? L("购买 Pro")) {
                            Task { await pro.purchase(Pro.productID) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(pro.busy || pro.products[Pro.productID] == nil)
                        if pro.trialEnd == nil {
                            Button(String(format: L("免费试用 %@ 天"), String(Pro.trialDays))) {
                                Task { await pro.purchase(Pro.trialID) }
                            }
                            .disabled(pro.busy || pro.products[Pro.trialID] == nil)
                        }
                        Spacer()
                        Button(L("恢复购买")) {
                            Task { await pro.restore() }
                        }
                        .disabled(pro.busy)
                    }
                } footer: {
                    if pro.products[Pro.productID] == nil {
                        Text(L("这一份不是从 App Store 装的，现在买不了 Pro。上面免费版的功能都能用。"))
                    }
                }
            } else {
                directPurchaseSection
            }
        }
        if Pro.channel == .direct && pro.purchased {
            directManageSection
        }
    }

    /// 公证包未购买：去付款页、填钥匙、忘了就按邮箱补发。见 docs/adr/0062。
    @ViewBuilder
    private var directPurchaseSection: some View {
        Section {
            HStack {
                Button(L("购买 Pro")) {
                    if let url = LicenseEndpoint.purchaseURL { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(LicenseEndpoint.purchaseURL == nil)
                Spacer()
            }
            HStack {
                TextField(L("钥匙"), text: $keyInput)
                    .textFieldStyle(.roundedBorder)
                Button(L("填入")) {
                    let k = keyInput
                    Task {
                        await license.enter(key: k)
                        if license.isActive { keyInput = "" }
                    }
                }
                .disabled(license.busy || keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Button(L("忘了钥匙？")) { showReissue.toggle() }
                .buttonStyle(.link)
            if showReissue {
                HStack {
                    TextField(L("付款时用的邮箱"), text: $emailInput)
                        .textFieldStyle(.roundedBorder)
                    Button(L("发回")) {
                        let e = emailInput
                        Task { await license.reissue(email: e) }
                    }
                    .disabled(license.busy || emailInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if let note = license.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            if !license.isConfigured {
                Text(L("尚未接入支付系统，现在买不了 Pro。上面免费版的功能都能用。"))
            }
        }
    }

    /// 公证包已购买：看钥匙尾号，可以把这台的名额让出来。只让出自己。
    @ViewBuilder
    private var directManageSection: some View {
        Section {
            if let rec = license.record {
                LabeledContent(L("钥匙"), value: "…" + String(rec.key.suffix(4)))
                HStack {
                    Button(L("让出这台的名额")) {
                        Task { await license.release() }
                    }
                    .disabled(license.busy)
                    Spacer()
                }
                if rec.releasePending {
                    Text(L("这台先记着要让出，连上系统后自动完成；在那之前仍算已购买。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let note = license.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            Text(L("让出后这台变回免费版，名额空给别的 Mac。只让出这一台，不影响其他电脑。"))
        }
    }

    @ViewBuilder
    private func planCell(_ value: String) -> some View {
        switch value {
        case "✓":
            Image(systemName: "checkmark")
                .font(Theme.TypeScale.caption).fontWeight(.semibold)
                .foregroundStyle(.primary)
        case "—":
            Image(systemName: "minus")
                .font(Theme.TypeScale.caption).fontWeight(.semibold)
                .foregroundStyle(.tertiary)
        default:
            Text(value)
                .foregroundStyle(.secondary)
        }
    }

    private static var providerRows: [(String, String, String)] {
        [
            (L("划词、剪贴板、截图"), L("2 家"), L("不限")),
            (L("文件、实时字幕、媒体、语音"), L("1 家"), L("不限")),
            (L("词典"), L("默认 1 家"), L("配好的多家一起查")),
            (L("识别、朗读"), L("默认 1 家"), L("当次可加")),
        ]
    }

    private static var amountRows: [(String, String, String)] {
        [
            (L("一份文件"), L("5000 字"), L("不限")),
            (L("一份媒体"), L("15 分钟"), L("不限")),
            (L("历史"), L("最近 50 条"), L("全部")),
            (L("继续对话"), L("无"), L("有")),
        ]
    }

    private func planTable(groups: [(String, [(String, String, String)])]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            GridRow {
                Text("")
                Text(L("免费版")).font(Theme.TypeScale.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                Text("Pro").font(Theme.TypeScale.caption).fontWeight(.semibold).foregroundStyle(Color.accentColor)
            }
            ForEach(Array(groups.enumerated()), id: \.offset) { idx, group in
                GridRow {
                    Text(group.0)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .gridCellColumns(3)
                        .padding(.top, idx == 0 ? 2 : 8)
                }
                ForEach(group.1, id: \.0) { item, free, paid in
                    GridRow {
                        Text(item)
                        planCell(free)
                        planCell(paid)
                    }
                }
            }
        }
    }

    // MARK: - Tabs

    private var generalTab: some View {
        Form {
            Section {
                Picker(selection: $config.appLanguage) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.title).tag(lang)
                    }
                } label: {
                    Text(L("应用语言"))
                }
                LabeledContent(L("外观")) {
                    PillSegmented(
                        selection: $config.appearance,
                        options: AppearanceMode.allCases.map { ($0, $0.title) }
                    )
                }
                LabeledContent(L("浮层不透明度")) {
                    HStack(spacing: 10) {
                        Slider(value: $config.panelOpacity, in: 0.35...1)
                        Text("\(Int((config.panelOpacity * 100).rounded()))%")
                            .font(Theme.TypeScale.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                    .frame(maxWidth: 220)
                }
            } header: {
                Text(L("界面"))
            }

            Section {
                Toggle(isOn: loginAtLoginBinding) {
                    Text(L("开机自启"))
                    Text(L("登录时自动打开 Korgino"))
                }
                .toggleStyle(SegmentedToggleStyle())
            } header: {
                Text(L("启动"))
            }

            Section {
                Picker(selection: $config.nativeLanguage) {
                    ForEach(TargetLanguage.specific) { lang in
                        Text(lang.menuTitle).tag(lang)
                    }
                } label: {
                    Text(L("母语"))
                    Text(L("用来读译文"))
                }
                Picker(selection: $config.targetLanguage) {
                    ForEach(TargetLanguage.specific) { lang in
                        Text(lang.menuTitle).tag(lang)
                    }
                } label: {
                    Text(L("目标语言"))
                    Text(L("原文是母语就译成这种，原文是这种就译成母语，其它译成母语"))
                }
                Toggle(isOn: $config.polishSameLanguage) {
                    Text(L("同语润色"))
                    Text(L("原文已经是要译成的语言时，轻改措辞并保持结构"))
                }
                .toggleStyle(SegmentedToggleStyle())
            } header: {
                Text(L("语言"))
            }

            Section {
                proxyFields
            } header: {
                Text(L("网络"))
            } footer: {
                Text(L("默认跟随系统代理。国内访问 Google 免费翻译通常需要已开启的系统代理。"))
            }
        }
        .formStyle(.grouped)
    }

    private var featureRail: [RailItem] {
        [
            // 先是各项功能自己的页，再是横跨所有功能的：按应用改、快捷键一览。
            RailItem(id: "translate", title: L("翻译"), symbol: "character.textbox"),
            RailItem(id: "voice", title: L("语音与字幕"), symbol: "mic"),
            RailItem(id: "plugins", title: L("划词插件"), symbol: "square.stack"),
            RailItem(id: "apps", title: L("按应用设置"), symbol: "app.badge"),
            RailItem(id: "shortcuts", title: L("快捷键"), symbol: "command"),
        ]
    }

    private var featuresSplit: some View {
        PaneSplit {
            rail(featureRail, selection: $featureSection)
        } detail: {
            detailForm {
                Form {
                    switch featureSection {
                    case "shortcuts":
                        shortcutsFeature
                    case "apps":
                        QuickAppsSection()
                    case "plugins":
                        SelectionPluginSettingsSection()
                    case "voice":
                        dictateFeature
                        captionsFeature
                    default:
                        translateFeature
                        quickFeature
                        fileFeature
                        lookupFeature
                    }
                }
                .formStyle(.grouped)
            }
        }
    }

    private var hotkeyHint: Text {
        Text(L("勾选同时控制菜单项和快捷键，取消勾选后两者都停用。点右侧按钮后按下组合键即可修改，需包含 ⌃ / ⌥ / ⇧ / ⌘ 之一。Esc 取消。"))
    }

    private var shortcutsFeature: some View {
        Group {
            Section {
                hotkeyRow(.select, spec: $config.hotkeySelect)
                hotkeyRow(.clipboard, spec: $config.hotkeyClipboard)
                hotkeyRow(.ocr, spec: $config.hotkeyOCR)
            } header: {
                Text(L("翻译"))
            }
            Section {
                hotkeyRow(.quickTranslate, spec: $config.hotkeyQuick)
                hotkeyRow(.quickUndo, spec: $config.hotkeyQuickUndo)
            } header: {
                Text(L("快捷翻译"))
            }
            // 语音的开关只在「语音与字幕」页里，这里关着时整组变灰。
            Section {
                Group {
                    voiceHotkeyRow(.voiceRecognize, spec: $config.hotkeyVoiceRecognize)
                    voiceHotkeyRow(.voiceTranslate, spec: $config.hotkeyVoiceTranslate)
                    voiceHotkeyRow(.voiceInterpret, spec: $config.hotkeyVoiceInterpret)
                }
                .disabled(!config.dictateEnabled)
            } header: {
                Text(L("语音"))
            } footer: {
                if config.dictateEnabled {
                    Text(L("快捷键只切换模式，胶囊会写出模式名。按住 Fn 走当前这一条，松开结束。"))
                } else {
                    Text(L("语音没开。到「语音与字幕」页打开后，这几个快捷键才生效。"))
                }
            }
            Section {
                hotkeyRow(.file, spec: $config.hotkeyFile)
            } header: {
                Text(L("文件翻译"))
            }
            Section {
                hotkeyRow(.liveCaptions, spec: $config.hotkeyLiveCaptions)
                hotkeyRow(.mediaCaptions, spec: $config.hotkeyMediaCaptions)
            } header: {
                Text(L("字幕"))
            }
            Section {
                hotkeyRow(.dictionary, spec: $config.hotkeyDictionary)
                hotkeyRow(.history, spec: $config.hotkeyHistory)
            } header: {
                Text(L("查词和记录"))
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    hotkeyHint
                    HStack {
                        Spacer(minLength: 0)
                        Button(L("恢复默认快捷键")) {
                            config.resetHotkeysToDefaults()
                        }
                        .controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var translateFeature: some View {
        Section {
            serviceRow(L("划词翻译"), .select)
            serviceRow(L("翻译剪贴板"), .clipboard)
            serviceRow(L("OCR 截图翻译"), .ocr)
            Picker(L("截图识别"), selection: Binding(
                get: { config.ocrProvider },
                set: { config.setOCRDefault($0) }
            )) {
                ForEach(config.orderedOCRProviders()) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
        } header: {
            Text(L("划词与截图"))
        } footer: {
            Text(L("点加号添加这一项要用的翻译服务，点叉去掉。识别在上面选默认的一家。"))
        }
    }

    private var quickFeature: some View {
        Section {
            Picker(L("默认供应商"), selection: $config.quickProviderID) {
                Text(L("自动（第一个可用）")).tag("")
                ForEach(config.simultaneousTargets()) { target in
                    Text(target.displayName).tag(target.id)
                }
                if !config.quickProviderID.isEmpty,
                   !config.simultaneousTargets().contains(where: { $0.id == config.quickProviderID }) {
                    Text(String(format: L("%@（已暂停，先用第一个可用的）"), pausedName(config.quickProviderID)))
                        .tag(config.quickProviderID)
                }
            }
        } header: {
            Text(L("快捷翻译"))
        } footer: {
            Text(L("其他应用的输入框里，连按三下空格，把划选或整段换成这家的译文。输入法选词那一下也算一下。不打开翻译浮层。改成组合键后按一下即可。想按应用分开配，去「按应用设置」那一页。"))
        }
    }

    private var dictateFeature: some View {
        Section {
            Toggle(L("开启"), isOn: $config.dictateEnabled)
                .toggleStyle(SegmentedToggleStyle())
            Toggle(L("在菜单栏显示当前模式"), isOn: $config.voiceModeInMenuBar)
                .toggleStyle(SegmentedToggleStyle())
            if config.dictateEnabled {
                dictateInputPicker
                Picker(L("模式"), selection: $config.voiceMode) {
                    ForEach(VoiceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Picker(L("识别"), selection: $config.dictateEngineID) {
                    Text(L("自动（第一个可用）")).tag("")
                    ForEach(config.liveASRChoices()) { choice in
                        Text(choice.name).tag(choice.id)
                    }
                }
                Picker(L("识别语言"), selection: $config.dictateLocaleID) {
                    ForEach(ASRLanguage.available(apple: config.isSystemASR(config.dictateEngineID.isEmpty ? (config.liveASRChoices().first?.id ?? "apple") : config.dictateEngineID))) { lang in
                        Text(lang.title).tag(lang.id)
                    }
                }
                Picker(L("翻译"), selection: Binding(
                    get: { config.storedTranslateIDs(.dictate).first ?? "" },
                    set: { config.setTranslateIDs($0.isEmpty ? [] : [$0], .dictate) }
                )) {
                    ForEach(config.catalogTargets()) { target in
                        Text(target.displayName).tag(target.id)
                    }
                }
                Picker(L("目标语言"), selection: $config.dictateTargetLanguage) {
                    Text(L("跟随设置里的目标语言")).tag(TargetLanguage.auto)
                    ForEach(TargetLanguage.specific) { lang in
                        Text(lang.menuTitle).tag(lang)
                    }
                }
                Toggle(L("润色"), isOn: $config.voicePolish)
                    .toggleStyle(SegmentedToggleStyle())
                if config.voicePolish {
                    Picker(L("风格"), selection: $config.voicePolishStyle) {
                        ForEach(VoicePolishStyle.allCases) { style in
                            Text(style.title).tag(style)
                        }
                    }
                    if config.voicePolishStyle == .custom {
                        TextField(L("自己的要求"), text: $config.voicePolishNote)
                    }
                }
            }
        } header: {
            Text(L("语音"))
        } footer: {
            Text(L("按住 Fn 走当前模式。语音识别写下听到的字。语音翻译边听边出译文，松开后写入。语音传译边听边把说完的句子读出来。润色在松开后进行，按住时的字和已经读出去的句子不重来。没有 AI 时不改字。写不进输入框时只记历史。按住时再按别的键就取消。"))
        }
    }

    /// 按住 Fn 时听这只麦克风。拔掉的设备仍留在选项里，插回后下一轮继续用。
    private var dictateInputPicker: some View {
        let devices = MicInput.devices()
        return Picker(L("输入源"), selection: $config.dictateInputUID) {
            Text(L("系统默认")).tag("")
            ForEach(devices) { device in
                Text(device.name).tag(device.uid)
            }
            if !config.dictateInputUID.isEmpty, !devices.contains(where: { $0.uid == config.dictateInputUID }) {
                Text(L("已断开")).tag(config.dictateInputUID)
            }
        }
    }

    private var fileFeature: some View {
        Section {
            serviceRow(L("翻译服务"), .file)
            Picker(L("默认模型"), selection: Binding(
                get: { config.aiProfiles.contains { $0.id == config.fileAIProfileID && $0.enabled } ? config.fileAIProfileID : "" },
                set: { config.fileAIProfileID = $0 }
            )) {
                Text(L("自动（第一个可用）")).tag("")
                ForEach(config.aiProfiles.filter { config.isAIOn($0) }) { p in
                    Text(config.isPaused("ai:\(p.id)")
                         ? String(format: L("%@（已暂停，先用第一个可用的）"), p.name)
                         : p.name)
                        .tag(p.id)
                }
            }
            Toggle(isOn: $file.directVision) {
                Text(L("整页直读"))
                Text(L("扫描件和图片整页交给视觉模型，不先识别文字。数字版 PDF 仍抽文字。看不了图的模型会退回识别。"))
            }
            .toggleStyle(SegmentedToggleStyle())
        } header: {
            Text(L("文件翻译"))
        } footer: {
            if !Pro.unlocked {
                HStack(spacing: 6) {
                    Text(L("免费版单份原文 5000 字符以内，中文一个字算一个。"))
                    ProBadge(help: L("超过 5000 字符的文件需要 Pro"))
                }
            }
        }
    }

    private var captionsFeature: some View {
        Section {
            asrDefaultPicker(L("实时识别"), live: true)
            singleTranslatePicker(L("实时翻译"), .live)
            asrDefaultPicker(L("媒体识别"), live: false)
            singleTranslatePicker(L("媒体翻译"), .media)
            LabeledContent {
                HStack(spacing: 8) {
                    Text(String(media.concurrentLimit))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Stepper(L("媒体字幕同时份数"), value: $media.concurrentLimit, in: 1...10)
                        .labelsHidden()
                }
                .fixedSize()
            } label: {
                Text(L("媒体字幕同时份数"))
                Text(L("同时在识别或等翻译的音视频，还没开始和已经落盘的不算"))
            }
        } header: {
            Text(L("字幕"))
        }
    }

    private var lookupFeature: some View {
        Section {
            Picker(L("词典"), selection: $config.dictProvider) {
                ForEach(DictionaryProviderID.allCases.filter { config.isDictOn($0) }) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            if !Pro.unlocked {
                HStack(spacing: 6) {
                    Text(L("免费版只用默认一家"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ProBadge(help: L("Pro 不限家数"))
                }
            }
            Toggle(isOn: $config.dictAutoOpen) {
                Text(L("翻译后展开释义"))
                Text(L("短词翻完后，在翻译浮层里展开释义"))
            }
            .toggleStyle(SegmentedToggleStyle())
        } header: {
            Text(L("查词"))
        }
    }

    private var privacyTab: some View {
        Form {
            Section {
                maskSwitch(L("密钥"), L("API key、私钥、JWT 和密码"), $config.maskPrefs.secrets)
                maskSwitch(L("邮箱"), L("跳过 example.com 和 git 地址"), $config.maskPrefs.email)
                maskSwitch(L("手机号"), L("大陆手机号"), $config.maskPrefs.phone)
                maskSwitch(L("身份证"), L("校验过的号码"), $config.maskPrefs.idCard)
                maskSwitch(L("银行卡"), L("校验过的卡号"), $config.maskPrefs.bankCard)
                maskSwitch(L("社会安全号"), L("美国社会安全号"), $config.maskPrefs.ssn)
                maskSwitch(L("护照号"), L("写在护照或 passport 后面的"), $config.maskPrefs.passport)
                maskSwitch(L("IBAN"), L("校验过的国际账号"), $config.maskPrefs.iban)
                maskSwitch(L("生日"), L("写在生日或 birthday 后面，且早于一年前"), $config.maskPrefs.birthday)
            } header: {
                Text(L("身份和账号"))
            }

            Section {
                maskSwitch(L("MAC 地址"), L("网卡地址"), $config.maskPrefs.mac)
                maskSwitch(L("序列号"), L("写在序列号或 S/N 后面的"), $config.maskPrefs.serial)
                maskSwitch(L("主目录用户名"), L("/Users 或 /home 里的名字"), $config.maskPrefs.home)
                maskSwitch(L("用户名和主机名"), L("命令行提示符、ssh，以及单独一行的用户名或主机名"), $config.maskPrefs.userHost)
                maskSwitch(L("公网 IP"), L("不含内网、本机和公共 DNS"), $config.maskPrefs.ip)
                maskSwitch(L("云存储桶"), L("s3、oss 这类地址"), $config.maskPrefs.bucket)
            } header: {
                Text(L("设备和网络"))
            } footer: {
                Text(L("命中后先显示将要发出的内容，确认后才发出。结果回来再填回原文。这台 Mac 上留下的仍是原文。"))
            }

            Section {
                ForEach($config.maskPrefs.entries) { $entry in
                    customEntry($entry)
                }
                Button(L("新增一条")) {
                    config.maskPrefs.entries.append(MaskEntry())
                }
            } header: {
                Text(L("自定义"))
            } footer: {
                Text(L("一条一条加。普通按字面找，英文词两边要断开。正则匹配写到的那一段。替换成留空时用占位符；填了就发出这段，结果回来再填回原文。两处不同的原文用了同一个替换词时，后一处加上数字。写错的正则跳过，不拦住发送。命中后同样先确认。"))
            }
        }
        .formStyle(.grouped)
    }

    private func customEntry(_ entry: Binding<MaskEntry>) -> some View {
        let entryID = entry.wrappedValue.id
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                PillSegmented(
                    selection: entry.kind,
                    options: [(MaskEntry.Kind.literal, L("普通")), (.regex, L("正则"))]
                )
                Spacer(minLength: 0)
                Toggle(isOn: entry.ignoreCase) {
                    Text(L("不区分大小写"))
                }
                .toggleStyle(SegmentedToggleStyle())
                IconButton(systemImage: "minus.circle", help: L("移出")) {
                    config.maskPrefs.entries.removeAll { $0.id == entryID }
                }
            }
            HStack(spacing: 8) {
                TextField(entry.wrappedValue.kind == .literal ? L("要遮住的词") : L("正则"), text: entry.pattern)
                    .textFieldStyle(.roundedBorder)
                TextField(L("替换成"), text: entry.replacement, prompt: Text(L("留空则用占位符")))
                    .textFieldStyle(.roundedBorder)
            }
            if let problem = entry.wrappedValue.problem {
                ErrorLine(text: L(problem))
            }
        }
        .padding(.vertical, 2)
    }

    /// Callers pass text already run through `L()`, so the keys stay visible to the
    /// localization checker instead of hiding inside this helper.
    private func maskSwitch(_ title: String, _ detail: String, _ isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
            Text(detail)
        }
        .toggleStyle(SegmentedToggleStyle())
    }

    private var loginAtLoginBinding: Binding<Bool> {
        Binding(
            get: { loginEnabled },
            set: { on in
                do {
                    if on { try SMAppService.mainApp.register() }
                    else { try SMAppService.mainApp.unregister() }
                    loginEnabled = SMAppService.mainApp.status == .enabled
                } catch {
                    loginEnabled = SMAppService.mainApp.status == .enabled
                    let a = NSAlert()
                    a.messageText = L("设置开机自启失败")
                    a.informativeText = error.localizedDescription
                    a.runModal()
                }
            }
        )
    }

    private var aboutTab: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    if let nsimg = NSApp.applicationIconImage {
                        Image(nsImage: nsimg)
                            .resizable()
                            .frame(width: 56, height: 56)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Korgino")
                            .font(Theme.TypeScale.title)
                        Text(String(format: L("版本 %@"), String(describing: AppInfo.fullVersion)))
                            .font(Theme.TypeScale.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 8)
                    Button(checkingUpdate ? L("检查中…") : L("检查更新…")) {
                        checkingUpdate = true
                        Task {
                            let outcome = await UpdateChecker.check()
                            checkingUpdate = false
                            UpdateChecker.presentResult(outcome)
                        }
                    }
                    .disabled(checkingUpdate)
                }
                LabeledContent(L("联系")) {
                    HStack(spacing: 8) {
                        Button {
                            NSWorkspace.shared.open(AppInfo.xProfileURL)
                        } label: {
                            ContactIcon(kind: .x)
                        }
                        .help("X")
                        .accessibilityLabel("X")
                        Button {
                            showWeChatQR.toggle()
                        } label: {
                            ContactIcon(kind: .wechat)
                        }
                        .help(L("微信"))
                        .accessibilityLabel(L("微信"))
                    }
                }
                if showWeChatQR, let image = AppInfo.weChatQR {
                    VStack(spacing: 6) {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.none)
                            .frame(width: 168, height: 168)
                        Text(L("扫码添加企业微信"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            proSections
            Section(L("致谢")) {
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
        }
        .formStyle(.grouped)
    }

    private var providerRail: [RailItem] {
        [
            RailItem(id: "builtin", title: L("内置翻译引擎"), symbol: "character.bubble"),
            RailItem(id: "dict", title: L("词典"), symbol: "book.closed"),
            RailItem(id: "ai", title: L("AI 提供商"), symbol: "brain.head.profile"),
            RailItem(id: "test", title: L("测试"), symbol: "checkmark.circle"),
        ]
    }

    private var providersSplit: some View {
        PaneSplit {
            rail(providerRail, selection: $providerSection)
        } detail: {
            detailForm {
                Form {
                    switch providerSection {
                    case "dict":
                        dictProviders
                    case "ai":
                        aiProviders
                    case "test":
                        providerTest
                    default:
                        builtinProviders
                    }
                }
                .formStyle(.grouped)
            }
        }
    }

    private var builtinProviders: some View {
        Section {
            ForEach(ProviderID.allCases) { p in
                providerRow(p)
            }
        } footer: {
            Text(L("勾选表示已配置好并启用。每个功能用哪几家，在「功能」里选。"))
        }
    }

    private var dictProviders: some View {
        Section {
            ForEach(DictionaryProviderID.allCases) { provider in
                dictProviderRow(provider)
            }
        } footer: {
            Text(L("勾选启用。默认的一家在「功能」里选。"))
        }
    }

    private var aiProviders: some View {
        Section {
            if config.aiProfiles.isEmpty {
                Text(L("还没有 AI 提供商。点「添加提供商…」选一个预设即可。"))
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(config.aiProfiles.enumerated()), id: \.element.id) { idx, profile in
                aiProviderRow(idx: idx, profile: profile)
            }
            HStack {
                Button {
                    providerSheet = .ai
                } label: {
                    Label(L("添加提供商…"), systemImage: "plus")
                }
                Spacer()
                Button(L("导出…")) { exportAI() }
                    .disabled(config.aiProfiles.isEmpty)
                Button(L("导入…")) {
                    importAI()
                }
            }
        } footer: {
            Text(L("导出不含 API Key。"))
        }
    }

    private var providerTest: some View {
        Section {
            HStack {
                Button(testing ? L("测试中…") : L("测试已启用的服务")) {
                    runTest()
                }
                .disabled(testing)
                if testing {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.leading, 4)
                }
                Spacer(minLength: 0)
                if !testOutcomes.isEmpty && !testing {
                    Button(L("清除")) {
                        testOutcomes = []
                        testDirection = ""
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
            }

            if !testDirection.isEmpty {
                Text(testDirection)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !testOutcomes.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(testOutcomes.enumerated()), id: \.element.id) { index, outcome in
                        testResultCard(outcome)
                        if index < testOutcomes.count - 1 {
                            Divider()
                        }
                    }
                }
            }
        } footer: {
            Text(L("对已启用的服务发送「hello world」，结果按服务分条显示。"))
        }
    }

    @ViewBuilder
    private var proxyFields: some View {
        Picker(L("模式"), selection: $config.proxyMode) {
            ForEach(ProxyMode.allCases) { m in
                Text(m.label).tag(m)
            }
        }
        if config.proxyMode == .custom {
            Picker(L("类型"), selection: $config.proxyType) {
                ForEach(ProxyType.allCases) { t in
                    Text(t.label).tag(t)
                }
            }
            .pickerStyle(.segmented)
            TextField(L("主机"), text: $config.proxyHost, prompt: Text("127.0.0.1"))
                .textFieldStyle(.roundedBorder)
            TextField(L("端口"), value: $config.proxyPort, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
            TextField(L("用户名（可选）"), text: $config.proxyUsername)
                .textFieldStyle(.roundedBorder)
            SecureField(L("密码（可选）"), text: $config.proxyPassword)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var recognitionRail: [RailItem] {
        [
            RailItem(id: "ocr", title: L("OCR 引擎"), symbol: "text.viewfinder"),
            RailItem(id: "asr", title: L("语音识别"), symbol: "waveform"),
            RailItem(id: "tts", title: L("朗读"), symbol: "speaker.wave.2"),
            RailItem(id: "terms", title: L("识别词表"), symbol: "list.bullet"),
        ]
    }

    private var recognitionSplit: some View {
        PaneSplit {
            rail(recognitionRail, selection: $recognitionSection)
        } detail: {
            detailForm {
                Form {
                    switch recognitionSection {
                    case "asr":
                        asrSettings
                    case "terms":
                        asrTerms
                    case "tts":
                        ttsSettings
                    default:
                        ocrSettings
                    }
                }
                .formStyle(.grouped)
            }
        }
    }

    private var ocrSettings: some View {
        Section {
            ForEach(OCRProviderID.allCases) { p in
                ocrProviderRow(p)
            }
        } footer: {
            Text(L("勾选启用，默认的那一家用来识别。在截图选区里涂抹，再识别。云识别失败时，用涂过的图回退 Apple Vision。"))
        }
    }

    private var asrSettings: some View {
        Group {
            if config.asrAppleEnabled {
                Section {
                    Toggle(L("优先本机识别"), isOn: $config.asrAppleOnDevice)
                        .toggleStyle(SegmentedToggleStyle())
                } header: {
                    Text(L("Apple 语音"))
                } footer: {
                    Text(L("强制用本机模型识别。本机没识别出字时，再走一次网络。"))
                }
            }
            Section {
                Toggle(isOn: Binding(
                    get: { config.asrAnalyzerEnabled },
                    set: { config.setASRAnalyzer($0) }
                )) {
                    HStack(spacing: 6) {
                        Image(systemName: "apple.logo")
                            .font(Theme.TypeScale.body)
                            .frame(width: 16)
                        Text(L("Apple 语音分析"))
                        Spacer(minLength: 0)
                    }
                }
                .toggleStyle(CheckToggleStyle())
                Toggle(isOn: Binding(
                    get: { config.asrAppleEnabled },
                    set: { config.setASRApple($0) }
                )) {
                    HStack(spacing: 6) {
                        Image(systemName: "apple.logo")
                            .font(Theme.TypeScale.body)
                            .frame(width: 16)
                        Text(L("Apple 语音"))
                        Spacer(minLength: 0)
                    }
                }
                .toggleStyle(CheckToggleStyle())
                ForEach(Array(config.asrProfiles.enumerated()), id: \.element.id) { idx, profile in
                    asrProfileRow(idx: idx, profile: profile)
                }
                Button {
                    providerSheet = .asr
                } label: {
                    Label(L("添加识别提供商…"), systemImage: "plus")
                }
            } footer: {
                Text(L("勾选启用并填好密钥。实时字幕和媒体字幕的识别下拉只列出这些。Apple 语音分析用系统语音模型，Apple 语音是原来的引擎。同传服务边听边出译文和译音，只用在实时字幕和语音里。"))
            }
        }
    }

    private var asrTerms: some View {
        Section {
            ForEach(ASRPreset.allCases) { pack in
                Toggle(pack.title, isOn: Binding(
                    get: { config.asrPresets.contains(pack.rawValue) },
                    set: { config.setASRPreset(pack, on: $0) }
                ))
                .toggleStyle(CheckToggleStyle())
            }
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
                }
            }
            HStack {
                TextField(L("专有名词"), text: $asrTermDraft)
                    .onSubmit { addASRTerms() }
                Button(L("添加")) { addASRTerms() }
                    .disabled(asrTermDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || config.asrTerms.count >= 100)
            }
        } footer: {
            Text(L("预设来自清华大学开放中文词库，按词频取至少三个字的词。勾上就并进识别，取消勾选不影响自己加的词。自己加的词优先，一共不超过 100 个。实时字幕、媒体字幕和语音共用。"))
        }
    }

    private var ttsSettings: some View {
        Section {
            if config.enabledTTSChoices().count > 1 {
                Picker(L("用来朗读"), selection: $config.ttsSelection) {
                    ForEach(config.enabledTTSChoices()) { choice in
                        Text(choice.name).tag(choice.id)
                    }
                }
            }
            Toggle(isOn: Binding(
                get: { config.ttsAppleEnabled },
                set: { config.setTTSApple($0) }
            )) {
                HStack(spacing: 6) {
                    Image(systemName: "apple.logo")
                        .font(Theme.TypeScale.body)
                        .frame(width: 16)
                    Text(L("Apple 语音"))
                    Spacer(minLength: 0)
                }
            }
            .toggleStyle(CheckToggleStyle())
            ForEach(Array(config.ttsProfiles.enumerated()), id: \.element.id) { idx, profile in
                ttsProfileRow(idx: idx, profile: profile)
            }
            Button {
                providerSheet = .tts
            } label: {
                Label(L("添加朗读提供商…"), systemImage: "plus")
            }
        } footer: {
            Text(L("勾选放进目录。用来朗读的那一家在上面选。翻译浮层、词典、文件、实时字幕、媒体字幕和沉浸字幕都用它。"))
        }
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

    private func voiceHotkeyRow(_ action: HotkeyAction, spec: Binding<HotkeySpec>) -> some View {
        HotkeyRecorderButton(
            action: action,
            enabled: .constant(true),
            spec: spec,
            conflictWarning: config.hotkeyConflictWarning(for: action),
            showsToggle: false,
            onChange: { config.setHotkey($0, for: action) }
        ) {
            EmptyView()
        }
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

    private func serviceRow(_ title: String, _ use: TranslateUse) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            providerTags(use)
            if providerAtCap(use) {
                HStack(spacing: 6) {
                    Text(config.translateCap(use) == 1 ? L("免费版只用默认一家") : L("免费版最多同时两家"))
                        .font(.caption)
                        .foregroundStyle(Theme.attention)
                    ProBadge(help: L("Pro 不限家数"))
                }
            }
        }
    }

    private var permissionsTab: some View {
        Form {
            Section {
                permissionRow(
                    title: L("辅助功能"),
                    feature: L("划词翻译读取其他 App 中选中的文字"),
                    trusted: axTrusted
                ) {
                    if AXIsProcessTrusted() {
                        PermissionGrantController.shared.openSettings(.accessibility)
                    } else {
                        PermissionGrantController.shared.prompt(.accessibility)
                    }
                }
                permissionRow(
                    title: L("屏幕录制"),
                    feature: L("OCR 截图翻译框选屏幕区域识别文字"),
                    trusted: screenTrusted
                ) {
                    if CGPreflightScreenCaptureAccess() {
                        PermissionGrantController.shared.openSettings(.screenCapture)
                    } else {
                        PermissionGrantController.shared.prompt(.screenCapture)
                    }
                }
                permissionRow(
                    title: L("输入监视"),
                    feature: L("快捷翻译连按三下空格，按住 Fn 说话"),
                    trusted: listenTrusted
                ) {
                    if CGPreflightListenEventAccess() {
                        PermissionGrantController.shared.openSettings(.inputMonitoring)
                    } else {
                        PermissionGrantController.shared.prompt(.inputMonitoring)
                    }
                }
            } footer: {
                HStack {
                    Spacer()
                    Button(L("刷新权限状态")) {
                        refreshPermissions()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Rows

    private func permissionRow(
        title: String,
        feature: String,
        trusted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        LabeledContent {
            HStack(spacing: 10) {
                permissionStatus(trusted)
                if trusted {
                    Button(L("打开系统设置")) { action() }
                } else {
                    Button(L("去授权")) { action() }
                        .buttonStyle(.borderedProminent)
                }
            }
        } label: {
            Text(title)
            Text(feature)
        }
    }

    private func permissionStatus(_ trusted: Bool?) -> some View {
        let title = trusted == true ? L("已授权") : (trusted == false ? L("未授权") : L("未检测"))
        let color: Color = trusted == true ? .green : (trusted == false ? .orange : .secondary)
        return HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func refreshPermissions() {
        axTrusted = AXIsProcessTrusted()
        screenTrusted = CGPreflightScreenCaptureAccess()
        listenTrusted = CGPreflightListenEventAccess()
        loginEnabled = SMAppService.mainApp.status == .enabled
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Toggle(isOn: Binding(
                    get: { config.isProviderOn(p) },
                    set: { enabled in
                        if enabled && !ready { return }
                        config.setProviderOn(p, enabled)
                    }
                )) {
                    EmptyView()
                }
                .toggleStyle(CheckToggleStyle())
                .disabled(!ready && !on)
                .stopsRowTap(when: !ready && !on)
                .help(ready ? (on ? L("停用") : L("启用")) : L("填好密钥后可启用"))

                HStack(spacing: 6) {
                    ProviderIconView(provider: p, size: 13)
                    Text(p.displayName)
                }

                if !ready {
                    MissingKeyLabel()
                }
                Spacer(minLength: 8)
                expandChevron(expanded: open) { toggleBuiltinOpen(p) }
            }
            .rowTapToggle { toggleBuiltinOpen(p) }
            if open {
                providerFields(p)
                    .padding(.leading, 23)
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.16), value: open)
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
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(Theme.TypeScale.micro)
                        .foregroundStyle(.secondary)
                        .frame(width: 12, height: 12)
                }
                .buttonStyle(.plain)
                .opacity(hover ? 1 : 0)
                .allowsHitTesting(hover)
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(Theme.wellFill))
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

    private func singleTranslatePicker(_ title: String, _ use: TranslateUse) -> some View {
        Picker(title, selection: Binding(
            get: { config.storedTranslateIDs(use).first ?? "" },
            set: { config.setTranslateIDs($0.isEmpty ? [] : [$0], use) }
        )) {
            ForEach(config.catalogTargets()) { target in
                Text(target.displayName).tag(target.id)
            }
        }
    }

    private func asrDefaultPicker(_ title: String, live: Bool) -> some View {
        Picker(title, selection: Binding(
            get: { live ? config.resolvedLiveAsr() : config.resolvedMediaAsr() },
            set: { config.setDefaultAsr($0, live: live) }
        )) {
            ForEach(live ? config.liveASRChoices() : config.mediaASRChoices()) { choice in
                Text(choice.name).tag(choice.id)
            }
        }
    }

    @ViewBuilder
    private func providerFields(_ p: ProviderID) -> some View {
        switch p {
        case .googleFree:
            Text(L("无需 API Key，使用 Google 公开接口"))
                .font(.caption)
                .foregroundStyle(.secondary)
        case .googleCloud:
            SecureField("Google Cloud API Key", text: $config.googleCloudKey)
                .textFieldStyle(.roundedBorder)
        case .deepl:
            SecureField("DeepL API Key", text: $config.deeplKey)
                .textFieldStyle(.roundedBorder)
            Toggle(L("使用 Free API (api-free.deepl.com)"), isOn: $config.deeplUseFreeAPI)
                .toggleStyle(.checkbox)
                .controlSize(.small)
        case .apple:
            HStack {
                Text(applePackStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Button(L("下载语言包…")) {
                    AppleLangPack.presentDownloadPrompt(force: true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        refreshApplePackStatus()
                    }
                }
                .controlSize(.small)
            }
        case .microsoft:
            SecureField("Azure Translator Key", text: $config.microsoftKey)
                .textFieldStyle(.roundedBorder)
            TextField(L("区域（如 eastasia / global）"), text: $config.microsoftRegion)
                .textFieldStyle(.roundedBorder)
            Text(L("Microsoft Translator / Bing 官方 API"))
                .font(.caption)
                .foregroundStyle(.secondary)
        case .baidu:
            TextField(L("百度 App ID"), text: $config.baiduAppID)
                .textFieldStyle(.roundedBorder)
            SecureField(L("百度密钥"), text: $config.baiduSecret)
                .textFieldStyle(.roundedBorder)
        case .youdao:
            TextField(L("有道应用 ID"), text: $config.youdaoAppKey)
                .textFieldStyle(.roundedBorder)
            SecureField(L("有道应用密钥"), text: $config.youdaoSecret)
                .textFieldStyle(.roundedBorder)
        case .caiyun:
            SecureField(L("彩云 Token"), text: $config.caiyunToken)
                .textFieldStyle(.roundedBorder)
        case .mymemory:
            Text(L("无需 Key；有额度限制的公开接口"))
                .font(.caption)
                .foregroundStyle(.secondary)
        case .libreTranslate:
            TextField(L("实例 URL"), text: $config.libreTranslateURL)
                .textFieldStyle(.roundedBorder)
            SecureField(L("API Key（可选）"), text: $config.libreTranslateKey)
                .textFieldStyle(.roundedBorder)
            Text(L("可填自建或公共 LibreTranslate 实例"))
                .font(.caption)
                .foregroundStyle(.secondary)
        case .lingva:
            TextField(L("实例 URL"), text: $config.lingvaURL)
                .textFieldStyle(.roundedBorder)
            Text(L("Google 前端镜像，无需 Key；实例不可用时可换地址"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func dictProviderRow(_ p: DictionaryProviderID) -> some View {
        let on = config.isDictOn(p)
        let ready = config.dictReady(p)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Toggle(isOn: Binding(
                    get: { config.isDictOn(p) },
                    set: { enabled in
                        if enabled && !ready { return }
                        config.setDictOn(p, enabled)
                    }
                )) {
                    HStack(spacing: 6) {
                        Image(systemName: p.systemImage)
                            .font(Theme.TypeScale.body)
                            .frame(width: 16)
                        Text(p.displayName)
                    }
                }
                .toggleStyle(CheckToggleStyle())
                .disabled(!ready && !on)
                .help(ready ? (on ? L("停用") : L("启用")) : L("填好密钥后可启用"))
                if !ready {
                    MissingKeyLabel()
                }
                Spacer(minLength: 0)
            }
            if let translate = p.translateProvider, !config.isProviderOn(translate), on || !ready {
                providerFields(translate)
                    .padding(.leading, 23)
            }
        }
    }

    private func ocrProviderRow(_ p: OCRProviderID) -> some View {
        let on = config.isOCROn(p)
        let isDefault = config.ocrProvider == p
        let open = openOCR.contains(p.rawValue)
        let expandable = p != .appleVision
        let ready = config.ocrReady(p)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Toggle(isOn: Binding(
                    get: { config.isOCROn(p) },
                    set: { enabled in
                        if enabled && !ready { return }
                        config.setOCROn(p, enabled)
                        if !enabled { openOCR.remove(p.rawValue) }
                    }
                )) {
                    EmptyView()
                }
                .toggleStyle(CheckToggleStyle())
                .disabled(!ready && !on)
                .stopsRowTap(when: !ready && !on)
                .help(ready ? (on ? L("停用") : L("启用")) : L("填好密钥后可启用"))

                ocrRowLabel(p)

                if on {
                    if isDefault {
                        Text(L("默认"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Button(L("设为默认")) { config.setOCRDefault(p) }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .opacity(hoveredOCR == p.rawValue ? 1 : 0)
                            .allowsHitTesting(hoveredOCR == p.rawValue)
                    }
                }
                if !ready {
                    MissingKeyLabel()
                }
                Spacer(minLength: 8)
                if expandable {
                    expandChevron(expanded: open) { toggleOCROpen(p) }
                }
            }
            .rowTapToggle { if expandable { toggleOCROpen(p) } }
            .onHover { inside in
                if inside { hoveredOCR = p.rawValue }
                else if hoveredOCR == p.rawValue { hoveredOCR = nil }
            }
            if open && expandable {
                ocrProviderFields(p)
                    .padding(.leading, 23)
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
            syncKeysToggle($config.ocrBaiduSync)
            TextField(L("百度 App ID"), text: config.ocrBaiduSync ? $config.baiduAppID : $config.ocrBaiduAppID)
                .textFieldStyle(.roundedBorder)
            SecureField(L("百度密钥"), text: config.ocrBaiduSync ? $config.baiduSecret : $config.ocrBaiduSecret)
                .textFieldStyle(.roundedBorder)
        case .youdao:
            syncKeysToggle($config.ocrYoudaoSync)
            TextField(L("有道应用 ID"), text: config.ocrYoudaoSync ? $config.youdaoAppKey : $config.ocrYoudaoAppKey)
                .textFieldStyle(.roundedBorder)
            SecureField(L("有道应用密钥"), text: config.ocrYoudaoSync ? $config.youdaoSecret : $config.ocrYoudaoSecret)
                .textFieldStyle(.roundedBorder)
        case .tencent:
            TextField("SecretId", text: $config.tencentSecretID)
                .textFieldStyle(.roundedBorder)
            SecureField("SecretKey", text: $config.tencentSecretKey)
                .textFieldStyle(.roundedBorder)
        case .googleVision:
            syncKeysToggle($config.ocrGoogleSync)
            SecureField("Google Cloud API Key", text: config.ocrGoogleSync ? $config.googleCloudKey : $config.ocrGoogleKey)
                .textFieldStyle(.roundedBorder)
        case .azure:
            TextField(L("终结点"), text: $config.azureVisionEndpoint, prompt: Text("https://{resource}.cognitiveservices.azure.com"))
                .textFieldStyle(.roundedBorder)
            SecureField(L("密钥"), text: $config.azureVisionKey)
                .textFieldStyle(.roundedBorder)
        case .ocrSpace:
            SecureField("OCR.space API Key", text: $config.ocrSpaceKey)
                .textFieldStyle(.roundedBorder)
        case .aiVision:
            Picker(L("模型"), selection: Binding(
                get: { config.aiProfiles.contains { $0.id == config.ocrAIProfileID && $0.enabled } ? config.ocrAIProfileID : "" },
                set: { config.ocrAIProfileID = $0 }
            )) {
                Text(L("自动（第一个）")).tag("")
                ForEach(config.aiProfiles.filter { config.isAIOn($0) }) { ai in
                    Text(ai.name).tag(ai.id)
                }
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
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Toggle(isOn: Binding(
                    get: { config.asrProfiles.indices.contains(idx) && config.asrProfiles[idx].enabled },
                    set: { enabled in
                        if enabled && !ready { return }
                        config.setASROn(at: idx, enabled)
                    }
                )) {
                    EmptyView()
                }
                .toggleStyle(CheckToggleStyle())
                .disabled(!ready && !on)
                .stopsRowTap(when: !ready && !on)
                .help(ready ? (on ? L("停用") : L("启用")) : L("填好密钥后可启用"))

                HStack(spacing: 6) {
                    ProviderIconView(aiPreset: asrIconPreset(profile), name: profile.name, size: 13)
                    Text(profile.name.isEmpty ? L("未命名") : profile.name)
                }

                Spacer(minLength: 8)

                IconButton(systemImage: "trash", help: L("移除提供商")) {
                    expandedASRIds.remove(profile.id)
                    config.removeASR(at: idx)
                }
                expandChevron(expanded: expanded) { toggleASRExpanded(profile.id) }
            }
            .rowTapToggle { toggleASRExpanded(profile.id) }
            if expanded {
                asrProfileFields(idx)
                    .padding(.leading, 23)
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
            syncKeysToggle(asrSyncBinding(idx))
            if profile.syncAI { syncKeyNotice(aiPreset: preset?.aiPreset ?? "") }
        }
        TextField(L("连接地址"), text: asrBinding(idx, \.baseURL), prompt: Text(preset?.baseURL ?? "wss://"))
            .textFieldStyle(.roundedBorder)
        if !borrowsKey(profile.syncAI, aiPreset: preset?.aiPreset ?? "") {
            SecureField("API Key", text: asrKeyBinding(idx))
                .textFieldStyle(.roundedBorder)
        }
        ModelComboBox(text: asrBinding(idx, \.model), items: preset?.models ?? [], placeholder: preset?.model ?? "")
            .frame(height: 24)
        if preset?.interpWire == .qwen {
            Menu {
                Button(L("默认")) {
                    guard config.asrProfiles.indices.contains(idx) else { return }
                    var p = config.asrProfiles[idx]
                    p.voice = ""
                    config.asrProfiles[idx] = p
                }
                Divider()
                ForEach(QwenInterpVoice.all, id: \.voice) { item in
                    Button("\(item.name) · \(item.voice)") {
                        guard config.asrProfiles.indices.contains(idx) else { return }
                        var p = config.asrProfiles[idx]
                        p.voice = item.voice
                        config.asrProfiles[idx] = p
                    }
                }
            } label: {
                let chosen = profile.voice.trimmingCharacters(in: .whitespacesAndNewlines)
                Text(chosen.isEmpty ? L("译音音色：默认") : String(format: L("译音音色：%@"), QwenInterpVoice.name(for: chosen)))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: false, vertical: true)
            .help(L("同传译音用这把声音。改了之后，下次开始生效。"))
        }
        Text(preset?.interpWire == .qwen
             ? L("可以直接贴百炼控制台给的业务空间地址，会自动换成同传用的 WebSocket 地址。")
             : L("用 GA 版 Realtime 接口，按分钟计费。"))
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func whisperProfileFields(_ idx: Int, profile: ASRProfile, preset: ASRPresetDef?) -> some View {
        let canSync = !(preset?.aiPreset ?? "").isEmpty
        if canSync {
            syncKeysToggle(asrSyncBinding(idx))
            if profile.syncAI { syncKeyNotice(aiPreset: preset?.aiPreset ?? "") }
        }
        if !borrowsKey(profile.syncAI, aiPreset: preset?.aiPreset ?? "") {
            TextField("Base URL", text: asrBinding(idx, \.baseURL), prompt: Text(preset?.baseURL ?? "https://api.example.com/v1"))
                .textFieldStyle(.roundedBorder)
            SecureField((preset?.noKey ?? false) ? L("API Key（可选）") : "API Key", text: asrKeyBinding(idx))
                .textFieldStyle(.roundedBorder)
        }
        ASRModelPicker(idx: idx)
            .environmentObject(config)
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
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Toggle(isOn: Binding(
                    get: { config.ttsProfiles.indices.contains(idx) && config.ttsProfiles[idx].enabled },
                    set: { enabled in
                        if enabled && !ready { return }
                        config.setTTSOn(at: idx, enabled)
                    }
                )) {
                    EmptyView()
                }
                .toggleStyle(CheckToggleStyle())
                .disabled(!ready && !on)
                .stopsRowTap(when: !ready && !on)
                .help(ready ? (on ? L("停用") : L("启用")) : L("填好密钥后可启用"))

                HStack(spacing: 6) {
                    ProviderIconView(aiPreset: ttsIconPreset(profile), name: profile.name, size: 13)
                    Text(profile.name.isEmpty ? L("未命名") : profile.name)
                }

                Spacer(minLength: 8)

                IconButton(systemImage: "trash", help: L("移除提供商")) {
                    expandedTTSIds.remove(profile.id)
                    config.removeTTS(at: idx)
                }
                expandChevron(expanded: expanded) { toggleTTSExpanded(profile.id) }
            }
            .rowTapToggle { toggleTTSExpanded(profile.id) }
            if expanded {
                ttsProfileFields(idx)
                    .padding(.leading, 23)
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
            syncKeysToggle(ttsSyncBinding(idx))
            if profile.syncAI { syncKeyNotice(aiPreset: preset?.aiPreset ?? "") }
        }
        if !borrowsKey(profile.syncAI, aiPreset: preset?.aiPreset ?? "") {
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
            SecureField((preset?.noKey ?? false) ? L("API Key（可选）") : "API Key", text: ttsKeyBinding(idx))
                .textFieldStyle(.roundedBorder)
        }
        if wire != .azure {
            ModelComboBox(
                text: ttsBinding(idx, \.model),
                items: preset?.models ?? [],
                placeholder: wire == .deepgram ? L("音色") : (preset?.model ?? L("模型"))
            )
            .frame(height: 24)
        }
        if wire != .deepgram {
            if preset?.namedVoices == true {
                HStack(spacing: 8) {
                    TextField(L("音色"), text: ttsBinding(idx, \.voice))
                        .textFieldStyle(.roundedBorder)
                    Menu(L("预设")) {
                        ForEach(preset?.voices ?? []) { voice in
                            Button(voice.name) {
                                guard config.ttsProfiles.indices.contains(idx) else { return }
                                var p = config.ttsProfiles[idx]
                                p.voice = voice.id
                                config.ttsProfiles[idx] = p
                            }
                        }
                    }
                    .fixedSize()
                }
            } else if !(preset?.voices ?? []).isEmpty || !profile.voice.isEmpty {
                ModelComboBox(
                    text: ttsBinding(idx, \.voice),
                    items: preset?.voices.map(\.id) ?? [],
                    placeholder: preset?.voice ?? L("音色")
                )
                .frame(height: 24)
            }
        }
        if let note = preset?.note, !note.isEmpty {
            Text(note)
                .font(.caption)
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
            Image(systemName: "chevron.right")
                .font(Theme.TypeScale.micro)
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
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func syncKeysToggle(_ isOn: Binding<Bool>) -> some View {
        Toggle(L("同步翻译密钥"), isOn: isOn)
            .toggleStyle(.checkbox)
            .controlSize(.small)
    }

    @ViewBuilder
    private func aiProviderRow(idx: Int, profile: AIProfile) -> some View {
        let expanded = expandedAIIds.contains(profile.id)
        let on = config.isAIOn(profile)
        let ready = config.aiReady(profile)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Toggle(isOn: Binding(
                    get: { config.isAIOn(profile) },
                    set: { enabled in
                        if enabled && !ready { return }
                        config.setAIOn(at: idx, enabled)
                    }
                )) {
                    EmptyView()
                }
                .toggleStyle(CheckToggleStyle())
                .disabled(!ready && !on)
                .stopsRowTap(when: !ready && !on)
                .help(ready ? (on ? L("停用") : L("启用")) : L("填好密钥后可启用"))

                HStack(spacing: 6) {
                    ProviderIconView(aiPreset: profile.preset, name: profile.name, size: 13)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(profile.name.isEmpty ? L("未命名") : profile.name)
                        if !profile.preset.isEmpty, let pr = AIPresetDef.find(profile.preset) {
                            Text(pr.kind.sectionTitle + (pr.note.isEmpty ? "" : " · \(pr.note)"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer(minLength: 8)

                IconButton(systemImage: "trash", help: L("移除提供商")) {
                    expandedAIIds.remove(profile.id)
                    config.removeAI(at: idx)
                }
                expandChevron(expanded: expanded) { toggleAIExpanded(profile.id) }
            }
            .rowTapToggle { toggleAIExpanded(profile.id) }

            if expanded {
                aiEditor(idx: idx)
                    .padding(.leading, 23)
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
        return VStack(alignment: .leading, spacing: 8) {
            TextField(L("名称"), text: binding(idx, \.name))
                .textFieldStyle(.roundedBorder)
            TextField("Base URL", text: binding(idx, \.baseURL), prompt: Text("https://api.example.com/v1"))
                .textFieldStyle(.roundedBorder)
            if !(preset?.noKey ?? false) {
                SecureField("API Key", text: aiKeyBinding(idx))
                    .textFieldStyle(.roundedBorder)
            } else {
                Text(L("本地服务通常无需 Key；若设了鉴权可填写。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SecureField(L("API Key（可选）"), text: aiKeyBinding(idx))
                    .textFieldStyle(.roundedBorder)
            }
            AIModelPicker(idx: idx)
                .environmentObject(config)
            TextField(L("系统提示（可空）"), text: binding(idx, \.systemPrompt), axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
            if let urlStr = preset?.keysURL, !urlStr.isEmpty, let url = URL(string: urlStr) {
                Button(L("获取 API Key…")) { NSWorkspace.shared.open(url) }
                    .controlSize(.small)
            }
        }
        .padding(.leading, 4)
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
                    .font(.caption)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("添加提供商"))
                    .font(Theme.TypeScale.reading).fontWeight(.semibold)
                Spacer()
                Button(L("取消")) { isPresented = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            SearchField(text: $query, prompt: L("搜索名称、说明或 URL"))
                .padding(.horizontal, 16)
                .padding(.bottom, 6)

            if grouped.isEmpty {
                ContentUnavailableView.search(text: query)
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(grouped, id: \.kind) { group in
                        Section(group.kind.sectionTitle) {
                            ForEach(group.items) { p in
                                presetRow(p)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(width: 460, height: 520)
        .controlSize(.small)
    }

    private func presetRow(_ p: AIPresetDef) -> some View {
        Button {
            onPick(p)
            isPresented = false
        } label: {
            HStack(alignment: .center, spacing: 10) {
                ProviderIconView(aiPreset: p.id, name: p.name, size: 15)
                    .frame(width: 28, height: 28)
                    .well(radius: 7)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(p.name)
                            .font(Theme.TypeScale.body).fontWeight(.medium)
                        if p.noKey {
                            Text(L("无需 Key"))
                                .font(Theme.TypeScale.micro)
                                .foregroundStyle(Theme.ok)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Theme.ok.opacity(0.12)))
                        }
                    }
                    if !p.note.isEmpty {
                        Text(p.note)
                            .font(Theme.TypeScale.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if !p.baseURL.isEmpty {
                        Text(p.baseURL)
                            .font(Theme.TypeScale.micro.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var grouped: [(kind: AIPresetKind, items: [AIPresetDef])] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let avail = config.availablePresets().filter { p in
            q.isEmpty || [p.name, p.note, p.baseURL, p.id].contains { $0.localizedCaseInsensitiveContains(q) }
        }
        var out: [(AIPresetKind, [AIPresetDef])] = []
        for kind in [AIPresetKind.vendor, .relay, .local] {
            let items = avail.filter { $0.kind == kind }
            if !items.isEmpty { out.append((kind, items)) }
        }
        return out
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
                    .font(.caption)
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
                    .font(.caption)
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
