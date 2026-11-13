import AppKit
import AVFoundation
import ApplicationServices
import CoreGraphics
import CoreMedia
import ScreenCaptureKit
import Speech
import SwiftUI
import Translation

/// 初始引导。走完或关掉都记「已看过」，下次不整段重来。
/// 授权那一步的「下次启动不再提醒」单独记：没勾、而且还有没授权的，下次启动只再弹那一步。
enum Onboarding {
    static var seen: Bool {
        get { UserDefaults.standard.bool(forKey: ConfigKeys.onboardingSeen) }
        set { UserDefaults.standard.set(newValue, forKey: ConfigKeys.onboardingSeen) }
    }

    static var permissionsQuiet: Bool {
        get { UserDefaults.standard.bool(forKey: ConfigKeys.onboardingPermissionsQuiet) }
        set { UserDefaults.standard.set(newValue, forKey: ConfigKeys.onboardingPermissionsQuiet) }
    }

    /// 第一次，或者看过了但授权还没齐、也没勾「不再提醒」。
    static var shouldPresent: Bool {
        if !seen { return true }
        return !permissionsQuiet && !PermissionCheck.allGranted
    }

    /// 各处「去授权」的统一入口：打开引导面板，直接停在授权那一步。
    /// 只管权限：关掉不改「已看过」，也不会把后面几步塞给用户。
    @MainActor
    static func showPermissions(focus: PermissionCheck.Kind? = nil) {
        OnboardingWindow.shared.showPermissions(focus: focus)
    }

    @MainActor
    static func showPermissions(pane: PrivacyPane) {
        showPermissions(focus: PermissionCheck.Kind(pane: pane))
    }

    /// 设置页「重新看引导」：清掉已看过，从语言重来。
    @MainActor
    static func replay() {
        seen = false
        OnboardingWindow.shared.show(start: .language)
    }
}

/// 五项权限的现状。辅助功能、屏幕录制、输入监视走系统查询；麦克风和语音识别走系统授权状态。
enum PermissionCheck {
    static var accessibility: Bool { AXIsProcessTrusted() }
    static var screenCapture: Bool { CGPreflightScreenCaptureAccess() }
    static var inputMonitoring: Bool { CGPreflightListenEventAccess() }
    static var microphone: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    static var speech: Bool { SFSpeechRecognizer.authorizationStatus() == .authorized }

    static var allGranted: Bool {
        accessibility && screenCapture && inputMonitoring && microphone && speech
    }

    /// 没授权的出「去授权」，走现有的授权路径。
    @MainActor
    static func request(_ kind: Kind) {
        switch kind {
        case .accessibility:
            if accessibility {
                PermissionGrantController.shared.openSettings(.accessibility)
            } else {
                PermissionGrantController.shared.prompt(.accessibility)
            }
        case .screenCapture:
            if screenCapture {
                PermissionGrantController.shared.openSettings(.screenCapture)
            } else {
                // 录屏这一项必须由应用主动请求，系统才会把它登记进面板并给出开关。
                _ = CGRequestScreenCaptureAccess()
                PermissionGrantController.shared.prompt(.screenCapture)
            }
        case .inputMonitoring:
            if inputMonitoring {
                PermissionGrantController.shared.openSettings(.inputMonitoring)
            } else {
                PermissionGrantController.shared.prompt(.inputMonitoring)
            }
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
            default:
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            }
        case .speech:
            switch SFSpeechRecognizer.authorizationStatus() {
            case .notDetermined:
                SFSpeechRecognizer.requestAuthorization { _ in }
            default:
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    enum Kind: CaseIterable {
        case accessibility, screenCapture, inputMonitoring, microphone, speech

        init(pane: PrivacyPane) {
            switch pane {
            case .accessibility: self = .accessibility
            case .screenCapture: self = .screenCapture
            case .inputMonitoring: self = .inputMonitoring
            }
        }

        var title: String {
            switch self {
            case .accessibility: return L("辅助功能")
            case .screenCapture: return L("屏幕录制")
            case .inputMonitoring: return L("输入监视")
            case .microphone: return L("麦克风")
            case .speech: return L("语音识别")
            }
        }

        /// 一行写给哪个功能用。
        var feature: String {
            switch self {
            case .accessibility: return L("划词翻译读取并写回到别的应用里选中的文字")
            case .screenCapture: return L("截图翻译框选屏幕；实时字幕听系统声音")
            case .inputMonitoring: return L("连按空格快捷翻译、按住 Fn 说话")
            case .microphone: return L("实时字幕的麦克风、语音")
            case .speech: return L("Apple 语音识别")
            }
        }

        var granted: Bool {
            switch self {
            case .accessibility: return PermissionCheck.accessibility
            case .screenCapture: return PermissionCheck.screenCapture
            case .inputMonitoring: return PermissionCheck.inputMonitoring
            case .microphone: return PermissionCheck.microphone
            case .speech: return PermissionCheck.speech
            }
        }
    }
}

/// 五步。下次启动只补授权时从授权开始。
enum OnboardingStep: Int, CaseIterable {
    case language = 0, permissions, engines, tryout, done

    var title: String {
        switch self {
        case .language: return L("语言")
        case .permissions: return L("授权")
        case .engines: return L("翻译与识别")
        case .tryout: return L("体验")
        case .done: return L("完成")
        }
    }

    var index: Int { rawValue }
}

/// 引导里的翻译单选。选中的写进划词、剪贴板、截图、文件各自名单的第一家。
enum OnboardingTranslateChoice: String, CaseIterable, Identifiable {
    case google
    case apple
    case keyed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .google: return L("Google 免费")
        case .apple: return L("Apple 本地")
        case .keyed: return L("DeepL 或 AI")
        }
    }

    var detail: String {
        switch self {
        case .google: return L("无需密钥，需要能连上 Google")
        case .apple: return L("在本机翻译，离线可用")
        case .keyed: return L("需要密钥，稍后在设置里填")
        }
    }

    var recommended: Bool { self == .google }
}

/// 引导里的识别单选。Apple 语音分析是默认；另一项是第一家已配好的云识别。
enum OnboardingASRChoice: String, CaseIterable, Identifiable {
    case analyzer
    case cloud

    var id: String { rawValue }

    var recommended: Bool { self == .analyzer }
}

/// 体验步的五个标签。点「去试试」就走现有的动作。
enum OnboardingTry: Int, CaseIterable, Identifiable {
    case select, screenshot, quick, voice, meeting

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .select: return L("划词")
        case .screenshot: return L("截图")
        case .quick: return L("快捷翻译")
        case .voice: return L("语音")
        case .meeting: return L("会议字幕")
        }
    }

    /// 这一项要用到的权限。没授权就写「需要权限」，点了去授权。
    var permission: PermissionCheck.Kind? {
        switch self {
        case .select: return .accessibility
        case .screenshot: return .screenCapture
        case .quick: return .inputMonitoring
        case .voice: return .microphone
        case .meeting: return .screenCapture
        }
    }

    var needsPermission: Bool {
        guard let permission else { return false }
        return !permission.granted
    }

    /// 怎么触发。快捷键从设置里读，改了按键这里跟着变。
    var trigger: String {
        switch self {
        case .select:
            return String(format: L("选中这段外文，按 %@"), OnboardingTry.key(.select))
        case .screenshot:
            return String(format: L("按 %@，框住卡片里的两句"), OnboardingTry.key(.ocr))
        case .quick:
            return L("在下面这个框里连按三下空格")
        case .voice:
            return L("按住 Fn，把上面这句读完再松开")
        case .meeting:
            return L("点「开始这段对话」，听完出结果")
        }
    }

    /// 这一项按的快捷键。
    static func key(_ action: HotkeyAction) -> String {
        AppConfig.shared.hotkey(for: action).display
    }
}

/// 引导是主窗口上的对话框。没关掉之前主窗口既不能点也不能操作。
@MainActor
final class OnboardingWindow: NSObject {
    static let shared = OnboardingWindow()

    private var sheet: NSViewController?
    private let model = OnboardingModel()

    /// 没看过且授权还没齐时，从授权那一步开始，不从语言重来。
    func show(start: OnboardingStep? = nil) {
        model.permissionsOnly = false
        model.focus = nil
        let step = start ?? (Onboarding.seen ? .permissions : .language)
        present(step: step)
    }

    /// 只看授权那一步。关掉不记「已看过」，不打开主窗口。
    func showPermissions(focus: PermissionCheck.Kind?) {
        model.permissionsOnly = true
        model.focus = focus
        present(step: .permissions)
    }

    private func present(step: OnboardingStep) {
        model.step = step
        guard sheet == nil else { return }
        let root = OnboardingView(model: model) { [weak self] openMain in
            self?.close(openMain: openMain)
        }
        .environmentObject(AppConfig.shared)
        let host = NSHostingController(rootView: root)
        host.preferredContentSize = NSSize(width: 640, height: 520)
        sheet = host
        MainWindowController.shared.presentOnboarding(host)
    }

    private func close(openMain: Bool) {
        let host = sheet
        sheet = nil
        if let host {
            MainWindowController.shared.dismissOnboarding(host)
        }
        finish(openMain: openMain)
    }

    /// 截图前对话框让开了，截完再挂回来。内容还是原来那一份。
    func restore() {
        guard let sheet else { return }
        MainWindowController.shared.presentOnboarding(sheet)
    }

    /// 走完或关掉都记已看过。五项都授权了就把「不再提醒」也记上。
    private func finish(openMain: Bool) {
        if PermissionCheck.allGranted {
            Onboarding.permissionsQuiet = true
        }
        if model.permissionsOnly { return }
        Onboarding.seen = true
        if openMain {
            MainWindowController.shared.show()
        }
    }
}

@MainActor
final class OnboardingModel: ObservableObject {
    @Published var step: OnboardingStep = .language
    @Published var tryIndex = 0
    /// 体验说明了几项。点过「去试试」或「下一个」的算一项；跳过的不算。
    @Published var tried: Set<Int> = []
    @Published var packInstalled: Bool?
    /// 选了 Apple 本地之后真正去下。跳过不取消，失败只记下原因。
    @Published var packDownloading = false
    @Published var packError: String?
    @Published var packConfiguration: TranslationSession.Configuration?
    @Published var permissionTick = 0
    /// 从各处「去授权」进来：只显示授权一步，按钮是「完成」。
    @Published var permissionsOnly = false
    @Published var focus: PermissionCheck.Kind?

    func refreshPack(native: TargetLanguage, target: TargetLanguage) {
        let source = native.appleCode ?? "en"
        let destination = target.appleCode ?? "en"
        packInstalled = nil
        packError = nil
        packConfiguration = nil
        packDownloading = false
        Task {
            let status = await LanguageAvailability().status(
                from: Locale.Language(identifier: source),
                to: Locale.Language(identifier: destination)
            )
            let installed: Bool
            if case .installed = status { installed = true } else { installed = false }
            await MainActor.run {
                self.packInstalled = installed
                if !installed {
                    self.packDownloading = true
                    self.packConfiguration = AppleLangPack.prepareInline(source: source, target: destination)
                }
            }
        }
    }

    func packReady() {
        packDownloading = false
        packInstalled = true
        packError = nil
    }

    func packFailed(_ message: String) {
        packDownloading = false
        packError = message
    }

    func noteTried() {
        tried.insert(tryIndex)
    }
}

private struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    var onFinish: (Bool) -> Void
    @EnvironmentObject private var config: AppConfig
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var launchError: String?
    /// 五关的当场状态。探针是全局的，只有引导停在这一项时才挂上。
    @ObservedObject private var bridge = OnboardingTryBridge.shared
    @StateObject private var stage = OnboardingTryStage()
    @State private var quickText = ""
    @FocusState private var quickFocus: Bool
    /// 会议字幕念对话的那段声音，和正在听的那一路。
    @State private var player = DialoguePlayer()
    @State private var dialogue: TryoutListener?

    var body: some View {
        VStack(spacing: 0) {
            if !model.permissionsOnly { stepBar }
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 26)
                    .padding(.top, 16)
                    .padding(.bottom, 16)
            }
            footer
        }
        .frame(width: 640, height: 520)
        .background(Theme.windowFill)
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
            model.permissionTick += 1
            if PermissionCheck.allGranted {
                Onboarding.permissionsQuiet = true
            }
        }
        .onAppear {
            if config.storedTranslateIDs(.select).isEmpty {
                applyTranslateChoice(.google)
            }
        }
        .background {
            // 跳过不取消：这个任务挂在整页上，离开第 3 步也接着下。
            Color.clear
                .frame(width: 0, height: 0)
                .translationTask(model.packConfiguration) { session in
                    do {
                        try await session.prepareTranslation()
                        await MainActor.run { model.packReady() }
                    } catch is CancellationError {
                        await MainActor.run { model.packDownloading = false }
                    } catch {
                        await MainActor.run {
                            model.packFailed(error.localizedDescription)
                        }
                    }
                }
        }
    }

    private var stepBar: some View {
        HStack(spacing: 0) {
            ForEach(Array(OnboardingStep.allCases.enumerated()), id: \.element) { index, step in
                if index > 0 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.12))
                        .frame(width: 18, height: 1)
                }
                stepChip(step)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 28)
        .padding(.bottom, 12)
    }

    private func stepChip(_ step: OnboardingStep) -> some View {
        let done = step.index < model.step.index
        let current = step == model.step
        return HStack(spacing: 5) {
            ZStack {
                Circle()
                    .fill(current ? Theme.accent : (done ? Theme.ok.opacity(0.18) : Color.clear))
                    .overlay(
                        Circle().strokeBorder(
                            done || current ? Color.clear : Color.primary.opacity(0.15),
                            lineWidth: 1
                        )
                    )
                    .frame(width: 16, height: 16)
                if done {
                    Image(systemName: "checkmark")
                        .font(Theme.TypeScale.micro)
                        .foregroundStyle(Theme.ok)
                } else {
                    Text("\(step.index + 1)")
                        .font(Theme.TypeScale.micro)
                        .foregroundStyle(current ? Color.white : Color.primary.opacity(0.32))
                }
            }
            Text(step.title)
                .font(Theme.TypeScale.caption)
                .fontWeight(current ? .medium : .regular)
                .foregroundStyle(current ? Color.primary : Color.primary.opacity(0.32))
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .language: languageStep
        case .permissions: permissionsStep
        case .engines: enginesStep
        case .tryout: tryoutStep
        case .done: doneStep
        }
    }

    // MARK: 语言

    private var samples: OnboardingSamples {
        OnboardingSamples.pair(native: config.nativeLanguage, target: config.targetLanguage)
    }

    private var languageStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading(
                L("你读什么，写什么？"),
                L("母语用来读译文；目标语言是你常要写、要听的那一种。")
            )
            group {
                row(L("母语")) { languageMenu(nativeBinding) }
                row(L("目标语言")) { languageMenu($config.targetLanguage) }
            }
            Text(L("之后会这样翻"))
                .font(Theme.TypeScale.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            group {
                sampleRow(L("读到外文"), source: samples.readForeign, translation: samples.readNative)
                sampleRow(L("写成外文"), source: samples.writeNative, translation: samples.writeForeign)
            }
        }
    }


    /// 母语一改，应用语言跟着改：引导里选的语言就是这个应用往后说话的语言。
    /// 目标语言撞上母语（或还是「自动」）时换一个最常见的，免得「读到外文」和「写成外文」是同一句。
    private var nativeBinding: Binding<TargetLanguage> {
        Binding(
            get: { config.nativeLanguage },
            set: { pick in
                let previous = config.nativeLanguage
                guard pick != previous else { return }
                config.nativeLanguage = pick
                config.appLanguage = AppLanguage(rawValue: pick.rawValue) ?? .system
                if config.targetLanguage == pick || config.targetLanguage == previous || config.targetLanguage == .auto {
                    config.targetLanguage = pick == .en ? .zhHans : .en
                }
            }
        )
    }

    private func sampleRow(_ caption: String, source: String, translation: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(caption)
                .font(Theme.TypeScale.caption)
                .foregroundStyle(.secondary)
            Text(source)
                .font(Theme.TypeScale.label)
                .foregroundStyle(.secondary)
            Text(translation)
                .font(Theme.TypeScale.reading)
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.leading, 14)
        }
    }

    // MARK: 授权

    private var permissionsStep: some View {
        let all = PermissionCheck.allGranted
        let _ = model.permissionTick
        return VStack(alignment: .leading, spacing: 14) {
            heading(
                all ? L("都准备好了") : L("给 Korgino 几项权限"),
                all
                    ? L("五项权限都已打开，以后不会再弹出这一步。")
                    : L("每一项只给写明的功能用。不给也能先用，用到时再提醒你。")
            )
            group {
                ForEach(PermissionCheck.Kind.allCases, id: \.self) { kind in
                    permissionRow(kind)
                }
            }
            quietToggle(locked: all)
        }
    }

    private func permissionRow(_ kind: PermissionCheck.Kind) -> some View {
        let granted = kind.granted
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(kind.title)
                    .font(Theme.TypeScale.body)
                Text(kind.feature)
                    .font(Theme.TypeScale.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if granted {
                StatusDot(.ok, L("已授权"))
            } else {
                Button(L("去授权")) { PermissionCheck.request(kind) }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 38)
        .background(model.focus == kind && !granted ? Theme.accent.opacity(0.10) : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.leading, 14)
        }
    }

    /// 五项都授权了就自动勾上并变灰。没勾时，下次启动若仍有没授权的项，只再弹这一步。
    private func quietToggle(locked: Bool) -> some View {
        let on = locked || Onboarding.permissionsQuiet
        return Toggle(isOn: Binding(
            get: { on },
            set: { value in
                guard !locked else { return }
                Onboarding.permissionsQuiet = value
                model.permissionTick += 1
            }
        )) {
            Text(L("下次启动不再提醒"))
                .font(Theme.TypeScale.label)
                .foregroundStyle(locked ? Color.secondary : Color.primary)
        }
        .toggleStyle(.checkbox)
        .disabled(locked)
        .padding(.leading, 4)
    }

    // MARK: 翻译与识别

    private var currentTranslateChoice: OnboardingTranslateChoice {
        let id = config.storedTranslateIDs(.select).first ?? ""
        if id == ProviderID.apple.rawValue { return .apple }
        if id == ProviderID.googleFree.rawValue || id.isEmpty { return .google }
        return .keyed
    }

    /// 第一家已配好、并且不是 Apple 自带的云识别。没有就不出第二个选项。
    private var cloudASR: ASRChoice? {
        config.enabledASRChoices().first { choice in
            choice.id != "analyzer" && choice.id != "apple"
        }
    }

    private var currentASRChoice: OnboardingASRChoice {
        let id = config.liveASRChoices().first?.id ?? "analyzer"
        if id == "analyzer" || id == "apple" { return .analyzer }
        return .cloud
    }

    private var enginesStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading(
                L("默认用哪家"),
                L("之后在设置里随时换，也能同时开几家。")
            )
            Text(L("翻译"))
                .font(Theme.TypeScale.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(OnboardingTranslateChoice.allCases) { choice in
                    choiceCard(
                        title: choice.title,
                        detail: choice.detail,
                        recommended: choice.recommended,
                        selected: currentTranslateChoice == choice
                    ) {
                        applyTranslateChoice(choice)
                    }
                    if choice == .apple, currentTranslateChoice == .apple {
                        packLine
                    }
                }
            }
            Text(L("识别"))
                .font(Theme.TypeScale.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 8) {
                choiceCard(
                    title: L("Apple 语音分析"),
                    detail: L("本机识别，首次使用自动下载语音模型"),
                    recommended: true,
                    selected: currentASRChoice == .analyzer
                ) {
                    config.setASRAnalyzer(true)
                    config.setDefaultAsr("analyzer", live: true)
                }
                if let cloud = cloudASR {
                    choiceCard(
                        title: cloud.name,
                        detail: L("已配置的云识别"),
                        recommended: false,
                        selected: currentASRChoice == .cloud
                    ) {
                        config.setDefaultAsr(cloud.id, live: true)
                    }
                }
            }
        }
        .onAppear { model.refreshPack(native: config.nativeLanguage, target: config.targetLanguage) }
        .onChange(of: config.nativeLanguage) { _, _ in
            model.refreshPack(native: config.nativeLanguage, target: config.targetLanguage)
        }
        .onChange(of: config.targetLanguage) { _, _ in
            model.refreshPack(native: config.nativeLanguage, target: config.targetLanguage)
        }
    }

    /// 选中的写进划词、剪贴板、截图、文件各自名单的第一家。沿用设置页常用那一行的写法。
    private func applyTranslateChoice(_ choice: OnboardingTranslateChoice) {
        let id: String
        switch choice {
        case .google:
            id = ProviderID.googleFree.rawValue
        case .apple:
            id = ProviderID.apple.rawValue
        case .keyed:
            id = keyedTranslateID()
        }
        ensureProviderOn(id)
        for use: TranslateUse in [.select, .clipboard, .ocr, .file] {
            var ids = config.storedTranslateIDs(use)
            ids.removeAll { $0 == id }
            ids.insert(id, at: 0)
            config.setTranslateIDs(ids, use)
            // 密钥还没填的那家不在目录里，上面那一步会把它丢掉。仍把它留在名单最前，填好密钥就能用。
            if config.storedTranslateIDs(use).first != id {
                keepTranslateFront(id, use)
            }
        }
    }

    private func keepTranslateFront(_ id: String, _ use: TranslateUse) {
        var ids = config.storedTranslateIDs(use)
        ids.removeAll { $0 == id }
        ids.insert(id, at: 0)
        switch use {
        case .select: config.selectTranslateIDs = ids
        case .clipboard: config.clipboardTranslateIDs = ids
        case .ocr: config.ocrTranslateIDs = ids
        case .file: config.fileTranslateIDs = ids
        case .dictate, .live, .media: break
        }
    }

    /// DeepL 或 AI：优先已经配好的 DeepL，其次第一家已配好的 AI，都没有就先记 DeepL。
    private func keyedTranslateID() -> String {
        if config.builtinReady(.deepl) { return ProviderID.deepl.rawValue }
        if let profile = config.aiProfiles.first(where: { config.aiReady($0) }) {
            return "ai:\(profile.id)"
        }
        return ProviderID.deepl.rawValue
    }

    /// 免密钥的先勾上，名单才接得住。要密钥的没填也先勾上，密钥留给设置。
    private func ensureProviderOn(_ id: String) {
        if let provider = ProviderID(rawValue: id) {
            if !config.isProviderOn(provider) {
                config.setProviderOn(provider, true)
            }
            return
        }
        if id.hasPrefix("ai:"), let index = config.aiProfiles.firstIndex(where: { "ai:\($0.id)" == id }) {
            config.setAIOn(at: index, true)
        }
    }

    /// 选了 Apple 本地就按第 1 步的语言对下载。失败写出原因，不挡住下一步。
    private var packLine: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if model.packDownloading {
                    ProgressView().controlSize(.small)
                    Text(L("正在下载语言包…"))
                        .font(Theme.TypeScale.caption)
                        .foregroundStyle(.secondary)
                } else if model.packInstalled == true {
                    StatusDot(.ok, L("已安装"))
                } else if model.packInstalled == nil {
                    StatusDot(.attention, L("检查中…"))
                } else {
                    StatusDot(.attention, L("未安装"))
                }
                Spacer(minLength: 0)
                if model.packDownloading {
                    Button(L("跳过")) { advance() }
                        .buttonStyle(HoverPlateButtonStyle())
                        .font(Theme.TypeScale.caption)
                        .foregroundStyle(Theme.accent)
                        .help(L("跳过不取消下载，可以先去下一步"))
                }
            }
            if let packError = model.packError, !packError.isEmpty {
                ErrorLine(text: packError)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .padding(.leading, 18)
    }

    private func choiceCard(
        title: String,
        detail: String,
        recommended: Bool,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(Theme.TypeScale.body)
                    .foregroundStyle(selected ? Theme.accent : Color.secondary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(Theme.TypeScale.body)
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)
                        if recommended {
                            Text(L("推荐"))
                                .font(Theme.TypeScale.micro)
                                .foregroundStyle(Theme.accent)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Theme.accent.opacity(0.12)))
                        }
                    }
                    Text(detail)
                        .font(Theme.TypeScale.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .fill(selected ? Theme.accent.opacity(0.06) : Theme.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(selected ? Theme.accent.opacity(0.45) : Theme.hairline, lineWidth: selected ? 1 : 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: 体验

    private var tryItem: OnboardingTry {
        OnboardingTry.allCases[model.tryIndex]
    }

    private var tryoutStep: some View {
        let _ = model.permissionTick
        return VStack(alignment: .leading, spacing: 12) {
            Text(L("试一下"))
                .font(Theme.TypeScale.title)
            tryTabs
            tryCard
            if tryItem.needsPermission, let permission = tryItem.permission {
                HStack(spacing: 8) {
                    Text(String(format: L("%@需要「%@」权限。给上之后这一关才能真的跑起来。"), tryItem.title, permission.title))
                        .font(Theme.TypeScale.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(L("去授权")) { PermissionCheck.request(permission) }
                        .controlSize(.small)
                }
            }
            tryResult
        }
        .onAppear { enter(tryItem) }
        .onDisappear { leave() }
        .onChange(of: model.tryIndex) { _, _ in enter(tryItem) }
        .onChange(of: tryItem.needsPermission) { _, _ in enter(tryItem) }
        .onReceive(bridge.$landed.compactMap { $0 }) { landed in received(landed) }
    }

    private var tryTabs: some View {
        HStack(spacing: 6) {
            ForEach(Array(OnboardingTry.allCases.enumerated()), id: \.element) { index, item in
                let current = index == model.tryIndex
                Button {
                    guard index != model.tryIndex else { return }
                    leave()
                    stage.reset()
                    model.tryIndex = index
                } label: {
                    HStack(spacing: 4) {
                        if item.needsPermission {
                            Image(systemName: "exclamationmark")
                                .font(Theme.TypeScale.micro)
                                .foregroundStyle(Theme.attention)
                        } else if model.tried.contains(index) {
                            Image(systemName: "checkmark")
                                .font(Theme.TypeScale.micro)
                                .foregroundStyle(Theme.ok)
                        } else {
                            Text("\(index + 1)")
                                .font(Theme.TypeScale.micro)
                                .foregroundStyle(current ? Color.white : Color.secondary)
                                .frame(width: 14, height: 14)
                                .background(Circle().fill(current ? Theme.accent : Color.primary.opacity(0.08)))
                        }
                        Text(item.title)
                            .font(Theme.TypeScale.caption)
                            .foregroundStyle(current ? Color.primary : Color.secondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(current ? Color.primary.opacity(0.06) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var tryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch tryItem {
            case .select: selectCard
            case .screenshot: screenshotCard
            case .quick: quickCard
            case .voice: voiceCard
            case .meeting: meetingCard
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

    /// 一句话、一层底色。
    private func hintLine(_ text: String) -> some View {
        Text(text)
            .font(Theme.TypeScale.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 一步一行：圆点里有序号，做完的一步打勾。
    private func stepRow(_ number: Int, _ text: String, done: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            ZStack {
                Circle()
                    .fill(done ? Theme.ok.opacity(0.16) : Color.primary.opacity(0.07))
                    .frame(width: 16, height: 16)
                if done {
                    Image(systemName: "checkmark")
                        .font(Theme.TypeScale.micro)
                        .foregroundStyle(Theme.ok)
                } else {
                    Text("\(number)")
                        .font(Theme.TypeScale.micro)
                        .foregroundStyle(.secondary)
                }
            }
            Text(text)
                .font(Theme.TypeScale.label)
                .foregroundStyle(done ? Color.secondary : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 按一下快捷键的提示。按键从设置里读。
    private func keyBadge(_ keys: String) -> some View {
        Text(keys)
            .font(Theme.TypeScale.caption)
            .foregroundStyle(.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
            )
    }

    // 划词：先选中，再按快捷键，结果在下面出来。

    private var selectCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepRow(1, L("把下面这句读一遍，然后在上面拖选整句。"), done: bridge.touched || bridge.landed != nil)
            VStack(alignment: .leading, spacing: 6) {
                SelectableText(text: samples.readForeign)
                    .frame(height: 22)
                if !(bridge.touched || bridge.landed != nil) {
                    Text(L("在这句话上拖动鼠标，把它选上"))
                        .font(Theme.TypeScale.caption)
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous)
                    .fill(Theme.wellFill)
            )
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                stepRow(2, L("选好之后按"), done: bridge.landed != nil)
                keyBadge(OnboardingTry.key(.select))
                Spacer(minLength: 0)
            }
            stepRow(3, L("下面会出现译文。平时在别的应用里也是这么用。"), done: bridge.landed != nil)
        }
    }

    // 截图：素材已经摆好，框住它就行。

    private var screenshotCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                stepRow(1, L("按"), done: bridge.touched || bridge.landed != nil)
                keyBadge(OnboardingTry.key(.ocr))
                Spacer(minLength: 0)
            }
            stepRow(2, L("屏幕会停下来，把下面这块卡片框进去。"), done: bridge.landed != nil)
            Text(samples.demoForeign)
                .font(Theme.TypeScale.reading)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                        .fill(Theme.wellFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                        .strokeBorder(
                            bridge.landed == nil ? Theme.accent.opacity(0.5) : Theme.hairline,
                            style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                        )
                )
            stepRow(3, L("框好后按回车，认出来的字会翻成母语，显示在下面。"), done: bridge.landed != nil)
        }
    }

    // 快捷翻译：输入框先备好、光标先进去，用户自己连按三下空格。

    private var quickCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepRow(1, L("这个框里已经写好一句母语，光标在里面。"), done: bridge.touched || bridge.landed != nil)
            TextField(L("在这里连按三下空格"), text: $quickText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.TypeScale.reading)
                .lineLimit(1...1)
                .focused($quickFocus)
                .onSubmit {}
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous)
                        .fill(Theme.wellFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous)
                        .strokeBorder(quickFocus ? Theme.accent.opacity(0.55) : Theme.hairline, lineWidth: 1)
                )
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                stepRow(2, L("在框里连按三下空格"), done: bridge.landed != nil)
                Spacer(minLength: 0)
                Button(L("点回框里")) { quickFocus = true }
                    .buttonStyle(.plain)
                    .font(Theme.TypeScale.caption)
                    .foregroundStyle(Theme.accent)
            }
            stepRow(3, L("框中这句会换成译文。平时在任何输入框里都能这样用。"), done: bridge.landed != nil)
        }
    }

    // 语音：给一句母语，用户按住 Fn 读出来。

    private var voiceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepRow(1, L("按住 Fn，把下面这句读完再松开。"), done: bridge.touched || bridge.landed != nil)
            Text(samples.speakNative)
                .font(Theme.TypeScale.reading)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                        .fill(Theme.wellFill)
                )
            hintLine(String(format: L("这句的意思是：%@"), samples.speakForeign))
            stepRow(2, L("听出来的字和译文出现在下面。平时按住 Fn 直接写进当前输入框。"), done: bridge.landed != nil)
        }
    }

    // 会议字幕：两句对话已经备好，用户点一下开始。

    private var meetingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepRow(1, L("下面这段对话已经备好，点一下开始播放。"), done: stage.hearing || bridge.landed != nil)
            VStack(alignment: .leading, spacing: 6) {
                Text(samples.meetFirst)
                    .font(Theme.TypeScale.reading)
                Text(samples.meetSecond)
                    .font(Theme.TypeScale.reading)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .fill(Theme.wellFill)
            )
            HStack(spacing: 10) {
                Button(stage.playing || stage.hearing ? L("停止") : L("开始这段对话")) {
                    if stage.playing || stage.hearing {
                        stopDialogue()
                        model.noteTried()
                    } else {
                        startDialogue()
                    }
                }
                .controlSize(.small)
                if stage.hearing {
                    HStack(spacing: 3) {
                        ForEach(0..<3) { index in
                            Capsule()
                                .fill(Theme.live)
                                .frame(width: 3, height: 10)
                                .opacity(stage.hearing ? 1 : 0.2)
                                .animation(
                                    reduceMotion ? nil : .easeInOut(duration: 0.45).repeatForever(autoreverses: true).delay(Double(index) * 0.12),
                                    value: stage.hearing
                                )
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            stepRow(2, L("放完这一段，听出来的字幕会翻成母语显示在下面。"), done: bridge.landed != nil)
        }
    }

    /// 这一关当场做出来的东西。没动手时不占位置。
    @ViewBuilder
    private var tryResult: some View {
        if !stage.source.isEmpty || stage.working || stage.error != nil || bridge.touched {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if stage.working {
                        ProgressView().controlSize(.small)
                    } else if stage.error == nil, !stage.source.isEmpty {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Theme.ok)
                            .font(Theme.TypeScale.caption)
                    }
                    Text(resultCaption)
                        .font(Theme.TypeScale.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if !stage.source.isEmpty || stage.error != nil {
                        Button(L("重来")) { retry() }
                            .buttonStyle(.plain)
                            .font(Theme.TypeScale.caption)
                            .foregroundStyle(Theme.accent)
                    }
                }
                if !stage.source.isEmpty {
                    Text(stage.source)
                        .font(Theme.TypeScale.label)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                if let translation = stage.translation, !translation.isEmpty {
                    Text(translation)
                        .font(Theme.TypeScale.reading)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                if let error = stage.error {
                    ErrorLine(text: error)
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
    }

    private var resultCaption: String {
        if stage.error != nil { return L("没走通") }
        if stage.working {
            switch tryItem {
            case .voice: return L("正在听…")
            case .meeting: return L("正在听这段对话…")
            default: return L("正在翻译…")
            }
        }
        switch tryItem {
        case .select: return L("译文")
        case .screenshot: return L("认出来的是这句")
        case .quick: return L("已经换过的这一段")
        case .voice: return L("听到的是这句")
        case .meeting: return L("这段对话的字幕")
        }
    }

    // MARK: 五关的进与出

    /// 摆好这一关的素材，挂上探针。这一关要用的自身进程限制只在这期间放开。
    private func enter(_ item: OnboardingTry) {
        bridge.disarm()
        stage.reset()
        quickText = samples.sayNative
        guard !item.needsPermission else { return }
        switch item {
        case .quick:
            QuickSpaceTap.shared.setTrial(true)
            DispatchQueue.main.async { quickFocus = true }
        case .voice:
            FnDictate.trialMode = .translate
            FnDictate.trialLocaleID = samples.native.speech
        case .select, .screenshot, .meeting:
            // 会议字幕等用户自己点「开始这段对话」，卡片上就是这么写的。
            break
        }
        bridge.arm(item)
    }

    /// 离开这一关：探针撤掉，放开的限制收回，正在念的停掉。
    private func leave() {
        bridge.disarm()
        QuickSpaceTap.shared.setTrial(false)
        FnDictate.trialMode = nil
        FnDictate.trialLocaleID = ""
        player.stop()
        dialogue?.stop()
        dialogue = nil
        stage.stop()
    }

    /// 功能那一侧把结果交回来了。截图只交回原文，这里补翻。
    private func received(_ landed: OnboardingTryBridge.Landed) {
        guard bridge.waiting == tryItem else { return }
        model.noteTried()
        stage.source = landed.source
        if tryItem == .quick {
            quickText = stage.source
        }
        if let translation = landed.translation, !translation.isEmpty {
            stage.translation = translation
            if tryItem == .quick { quickText = translation }
            return
        }
        let writing: Bool
        switch tryItem {
        case .quick, .voice: writing = true
        default: writing = false
        }
        let text = landed.source
        stage.begin { stage in
            await OnboardingTryStage.translate(text, writing: writing, into: stage)
        }
    }

    /// 这一关重来：清掉结果，素材照旧摆好，探针重新挂上。
    private func retry() {
        enter(tryItem)
    }

    // MARK: 会议字幕那关的播放

    /// 两句对话先念出来，同时听系统声音。念完再多等一小会儿，让最后几个字到齐。
    private func startDialogue() {
        guard !stage.playing, !stage.hearing else { return }
        if SystemAudioTranslateController.shared.isActive {
            stage.error = L("实时字幕正在听，先停掉再试")
            return
        }
        model.noteTried()
        stage.set(playing: true, hearing: false)
        stage.begin { stage in
            stage.error = nil
            let listener: TryoutListener
            do {
                listener = try await TryoutListener(system: true, language: samples.target.speech)
            } catch {
                stage.set(playing: false, hearing: false)
                stage.error = error.localizedDescription
                return
            }
            guard !Task.isCancelled else {
                listener.stop()
                return
            }
            dialogue = listener
            stage.set(playing: true, hearing: true)
            let pump = Task { @MainActor in
                while !Task.isCancelled {
                    let heard = listener.latest.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !heard.isEmpty { stage.source = heard }
                    try? await Task.sleep(nanoseconds: 160_000_000)
                }
            }
            await player.play(
                first: samples.meetFirst,
                second: samples.meetSecond,
                lines: samples.target
            )
            try? await Task.sleep(nanoseconds: 900_000_000)
            pump.cancel()
            let heard = await listener.finish()
            dialogue = nil
            guard !Task.isCancelled else { return }
            stage.set(playing: false, hearing: false)
            let text = heard.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                stage.error = L("没有听清这段对话。换一个识别语言或检查屏幕录制权限后再试。")
                return
            }
            stage.source = text
            await OnboardingTryStage.translate(text, writing: false, into: stage)
        }
    }

    private func stopDialogue() {
        player.stop()
        dialogue?.stop()
        dialogue = nil
        stage.set(playing: false, hearing: false)
    }

    // MARK: 完成

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(Theme.TypeScale.title)
                    .foregroundStyle(Theme.ok)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Theme.ok.opacity(0.15)))
                Text(L("可以用了"))
                    .font(Theme.TypeScale.title)
                Text(String(format: L("体验说明了 %d 项中的 %d 项。"), OnboardingTry.allCases.count, model.tried.count))
                    .font(Theme.TypeScale.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            group {
                shortcutRow(HotkeyAction.select.title, OnboardingTry.key(.select))
                shortcutRow(HotkeyAction.ocr.title, OnboardingTry.key(.ocr))
                shortcutRow(HotkeyAction.quickTranslate.title, OnboardingTry.key(.quickTranslate))
                shortcutRow(HotkeyAction.openMain.title, OnboardingTry.key(.openMain))
            }
            Toggle(isOn: launchBinding) {
                Text(L("登录时打开"))
                    .font(Theme.TypeScale.body)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.leading, 4)
            if let launchError {
                ErrorLine(text: launchError)
                    .padding(.leading, 4)
            }
        }
    }

    /// 和设置页「登录时打开」同一个开关：注册或反注册 `SMAppService.mainApp`。
    private var launchBinding: Binding<Bool> {
        Binding(
            get: { LoginItem.isOn },
            set: { launchError = LoginItem.set($0) }
        )
    }

    private func shortcutRow(_ title: String, _ keys: String) -> some View {
        HStack {
            Text(title)
                .font(Theme.TypeScale.body)
            Spacer(minLength: 12)
            Text(keys)
                .font(Theme.TypeScale.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 38)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.leading, 14)
        }
    }

    // MARK: 底栏

    private var footer: some View {
        HStack(spacing: 12) {
            if model.step != .language && model.step != .done && !model.permissionsOnly {
                PageButton(title: L("上一步")) { goBack() }
            }
            Spacer(minLength: 0)
            if model.step == .permissions && !model.permissionsOnly {
                Button(L("跳过")) { advance() }
                    .buttonStyle(HoverPlateButtonStyle())
                    .font(Theme.TypeScale.body)
                    .foregroundStyle(Theme.accent)
            }
            if model.step == .tryout {
                Button(L("跳过体验")) { advance() }
                    .buttonStyle(HoverPlateButtonStyle())
                    .font(Theme.TypeScale.body)
                    .foregroundStyle(Theme.accent)
            }
            primaryButton
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch model.step {
        case _ where model.permissionsOnly:
            PageButton(title: L("完成"), primary: true) { onFinish(false) }
                .keyboardShortcut(.defaultAction)
        case .done:
            PageButton(title: L("打开 Korgino"), primary: true) { onFinish(true) }
                .keyboardShortcut(.defaultAction)
        case .tryout:
            PageButton(
                title: model.tryIndex == OnboardingTry.allCases.count - 1 ? L("下一步") : L("下一个"),
                primary: true
            ) {
                model.noteTried()
                if model.tryIndex < OnboardingTry.allCases.count - 1 {
                    model.tryIndex += 1
                } else {
                    advance()
                }
            }
            .keyboardShortcut(.defaultAction)
        default:
            PageButton(title: L("下一步"), primary: true) { advance() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private func goBack() {
        guard let previous = OnboardingStep(rawValue: model.step.rawValue - 1) else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
            model.step = previous
        }
    }

    private func advance() {
        guard let next = OnboardingStep(rawValue: model.step.rawValue + 1) else {
            onFinish(true)
            return
        }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
            model.step = next
        }
    }

    // MARK: 小件

    private func heading(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(Theme.TypeScale.title)
            Text(subtitle)
                .font(Theme.TypeScale.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func group<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        SettingsGroup(title: "", content: content())
    }

    private func row<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        SettingsRow(title: title, control: control())
    }

    private func languageMenu(_ selection: Binding<TargetLanguage>) -> some View {
        MenuChip(
            title: selection.wrappedValue.menuTitle,
            options: TargetLanguage.specific,
            label: { $0.menuTitle },
            isSelected: { $0 == selection.wrappedValue },
            select: { selection.wrappedValue = $0 }
        )
    }
}

/// 体验步里听一小段。语音走麦克风，会议字幕走系统声音。
/// 识别用设置里选的那一家，只出文字，不写进任何输入框，也不记成一场会议。
@MainActor
final class TryoutListener {
    private let system: Bool
    /// 系统声音按哪种语言认。引导里的双人对话用选定的母语。
    private let language: String
    private var ear: TryoutMic?
    private var stream: SCStream?
    private var streamOutput: SystemAudioStreamOutput?
    private var lane: (any LiveAudioSink)?
    private(set) var latest = ""
    /// 系统声音那一路已经定稿的句子。两个人各说一句，字幕要两句都在。
    private var settled: [String] = []
    private var stopped = false

    init(system: Bool, language: String? = nil) async throws {
        self.system = system
        self.language = language ?? "system"
        if system {
            try await startSystem()
        } else {
            try startMicrophone()
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        ear?.cancel()
        stream?.stopCapture()
        lane?.stop()
    }

    /// 停下来，等最后一句出齐再交回。
    func finish() async -> String {
        if system {
            guard !stopped else { return latest }
            stopped = true
            try? await stream?.stopCapture()
            await lane?.finish()
            return latest
        }
        let heard = await ear?.transcript() ?? latest
        stopped = true
        return heard.isEmpty ? latest : heard
    }

    /// 定稿的句子留下，正在说的那句跟在后面。
    private func heard(_ text: String, final: Bool) {
        if final, !text.isEmpty { settled.append(text) }
        let live = final || text.isEmpty ? [] : [text]
        latest = (settled + live).joined(separator: "\n")
    }

    private func startMicrophone() throws {
        let cfg = AppConfig.shared
        let session = try TryoutMic(engine: cfg.resolvedDictateAsr(), language: ASRLanguage(id: cfg.dictateLocaleID)) { [weak self] text in
            self?.latest = text
        }
        try session.start()
        ear = session
    }

    private func startSystem() async throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw TErr(L("听系统声音需要屏幕录制权限"))
        }
        let cfg = AppConfig.shared
        let engine = cfg.resolvedLiveAsr()
        let made = try Self.makeLane(engine: engine, language: ASRLanguage(id: language)) { [weak self] text, final in
            self?.heard(text, final: final)
        }
        try made.prepare()
        lane = made

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw TErr(L("未找到可捕获的显示器")) }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let conf = SCStreamConfiguration()
        conf.capturesAudio = true
        conf.excludesCurrentProcessAudio = true
        conf.width = 2
        conf.height = 2
        conf.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        conf.sampleRate = 48000
        conf.channelCount = 1
        let stream = SCStream(filter: filter, configuration: conf, delegate: nil)
        let output = SystemAudioStreamOutput { [weak made] sample in
            made?.append(sampleBuffer: sample)
        }
        let queue = DispatchQueue(label: "com.sliiu.Korgino.tryout", qos: .userInitiated)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        self.streamOutput = output
        made.startRecognition()
    }

    /// 按设置里选的那一家建一条识别。只收最后一句，不要说话人。
    private static func makeLane(
        engine: String,
        language: ASRLanguage,
        onText: @escaping @MainActor (String, Bool) -> Void
    ) throws -> any LiveAudioSink {
        let cfg = AppConfig.shared
        let report: @Sendable (SystemAudioTranslateController.SourceKind, String, Bool, Int) -> Void = { _, text, final, _ in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { onText(trimmed, final) } }
        }
        if #available(macOS 26.0, *), cfg.isAnalyzerASR(engine), SpeechTranscriber.isAvailable {
            return LiveAnalyzerLane(
                source: .system,
                locale: language.locale,
                terms: cfg.asrContextTerms,
                onHypothesis: report,
                onError: { _, _ in }
            )
        }
        if cfg.isSystemASR(engine) {
            return LiveASRLane(
                source: .system,
                locale: language.locale,
                preferOnDevice: cfg.asrAppleOnDevice,
                terms: cfg.asrContextTerms,
                onHypothesis: report
            )
        }
        return LiveWhisperLane(
            source: .system,
            config: try cfg.asrWhisperConfig(selection: engine),
            language: language.whisperCode,
            prompt: cfg.asrContextPrompt,
            onHypothesis: report,
            onBusy: { _, _ in },
            onError: { _, message in
                DispatchQueue.main.async { MainActor.assumeIsolated { onText("", false) } }
                _ = message
            }
        )
    }
}

