import AppKit
import AVFoundation
import ApplicationServices
import CoreGraphics
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

    /// 怎么触发。
    var trigger: String {
        switch self {
        case .select: return L("选中外文，按 ⌥D")
        case .screenshot: return L("按 ⌥S，框住要认的字")
        case .quick: return L("在输入框里打一句母语，连按三下空格")
        case .voice: return L("按住 Fn 说一句母语，松开结束")
        case .meeting: return L("在实时与会议里点开始")
        }
    }
}

/// 内置四组例句。例句直接写在代码里，不走翻译，也不进语言包。
/// 其它组合用 English 那一组（母语不是中文或英文时，也用这一组）。
struct OnboardingSamples {
    /// 读到外文：目标语言写的原文，译成母语。
    var readForeign: String
    var readNative: String
    /// 写成外文：母语写的原文，译成目标语言。
    var writeNative: String
    var writeForeign: String
    /// 体验步用的一句目标语言，和它的母语译文。
    var demoForeign: String
    var demoNative: String
    /// 体验步用的一句母语，和它的目标语言译文。
    var sayNative: String
    var sayForeign: String

    static func pair(native: TargetLanguage, target: TargetLanguage) -> OnboardingSamples {
        switch (native, target) {
        case (.zhHans, .en):
            return OnboardingSamples(
                readForeign: "The meeting has been moved to Thursday.",
                readNative: "会议改到周四了。",
                writeNative: "麻烦把报价单再发我一份。",
                writeForeign: "Could you send me the quote again?",
                demoForeign: "Our flight was delayed by two hours because of the storm.",
                demoNative: "因为暴风雨，我们的航班延误了两个小时。",
                sayNative: "帮我订一张明天早上去上海的高铁票。",
                sayForeign: "Book me a high-speed train ticket to Shanghai tomorrow morning."
            )
        case (.zhHans, .ja):
            return OnboardingSamples(
                readForeign: "会議は木曜日に変更になりました。",
                readNative: "会议改到周四了。",
                writeNative: "麻烦把报价单再发我一份。",
                writeForeign: "見積もりをもう一度送っていただけますか。",
                demoForeign: "風で便が二時間遅れました。",
                demoNative: "因为大风，航班晚了两个小时。",
                sayNative: "帮我订一张明天早上去上海的高铁票。",
                sayForeign: "明朝上海行きの高鉄の切符を一枚予約してください。"
            )
        case (.en, .zhHans):
            return OnboardingSamples(
                readForeign: "会议改到周四了。",
                readNative: "The meeting has been moved to Thursday.",
                writeNative: "Could you send me the quote again?",
                writeForeign: "麻烦把报价单再发我一份。",
                demoForeign: "因为暴风雨，我们的航班延误了两个小时。",
                demoNative: "Our flight was delayed by two hours because of the storm.",
                sayNative: "Book me a high-speed train ticket to Shanghai tomorrow morning.",
                sayForeign: "帮我订一张明天早上去上海的高铁票。"
            )
        case (.en, .es):
            return OnboardingSamples(
                readForeign: "La reunión se ha pasado al jueves.",
                readNative: "The meeting has been moved to Thursday.",
                writeNative: "Could you send me the quote again?",
                writeForeign: "¿Me puedes enviar el presupuesto otra vez?",
                demoForeign: "El vuelo se retrasó dos horas por la tormenta.",
                demoNative: "Our flight was delayed by two hours because of the storm.",
                sayNative: "Book me a high-speed train ticket to Shanghai tomorrow morning.",
                sayForeign: "Resérvame un billete de tren de alta velocidad a Shanghái para mañana por la mañana."
            )
        default:
            return pair(native: .zhHans, target: .en)
        }
    }
}

@MainActor
final class OnboardingWindow: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindow()

    private var window: NSWindow?
    private let model = OnboardingModel()

    /// 没看过且授权还没齐时，从授权那一步开始，不从语言重来。
    func show(start: OnboardingStep? = nil) {
        let step = start ?? (Onboarding.seen ? .permissions : .language)
        model.step = step
        if window == nil {
            let root = OnboardingView(model: model) { [weak self] openMain in
                self?.close(openMain: openMain)
            }
            .environmentObject(AppConfig.shared)
            let host = NSHostingController(rootView: root)
            let w = NSWindow(contentViewController: host)
            w.title = L("初始引导")
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 640, height: 520))
            w.minSize = NSSize(width: 640, height: 520)
            w.maxSize = NSSize(width: 640, height: 520)
            w.delegate = self
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        window = nil
        finish(openMain: true)
    }

    private func close(openMain: Bool) {
        let w = window
        window = nil
        w?.delegate = nil
        w?.close()
        finish(openMain: openMain)
    }

    /// 走完或关掉都记已看过。五项都授权了就把「不再提醒」也记上。
    private func finish(openMain: Bool) {
        Onboarding.seen = true
        if PermissionCheck.allGranted {
            Onboarding.permissionsQuiet = true
        }
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

    var body: some View {
        VStack(spacing: 0) {
            stepBar
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 28)
                    .padding(.top, 8)
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
                        .fill(step.index <= model.step.index ? Theme.accent.opacity(0.5) : Theme.hairline)
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
                    .fill(done || current ? Theme.accent : Color.primary.opacity(0.08))
                    .frame(width: 16, height: 16)
                if done {
                    Image(systemName: "checkmark")
                        .font(Theme.TypeScale.micro)
                        .foregroundStyle(Color.white)
                } else {
                    Text("\(step.index + 1)")
                        .font(Theme.TypeScale.micro)
                        .foregroundStyle(current ? Color.white : Color.secondary)
                }
            }
            Text(step.title)
                .font(Theme.TypeScale.caption)
                .foregroundStyle(current ? Color.primary : Color.secondary)
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
                row(L("母语")) { languageMenu($config.nativeLanguage) }
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

    private func languageMenu(_ selection: Binding<TargetLanguage>) -> some View {
        Menu {
            ForEach(TargetLanguage.specific) { lang in
                Button(lang.menuTitle) { selection.wrappedValue = lang }
            }
        } label: {
            menuLabel(selection.wrappedValue.menuTitle)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
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
                        .buttonStyle(.plain)
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
            if tryItem.needsPermission {
                Text(L("需要权限"))
                    .font(Theme.TypeScale.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(tryItem.trigger)
                    .font(Theme.TypeScale.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var tryTabs: some View {
        HStack(spacing: 6) {
            ForEach(Array(OnboardingTry.allCases.enumerated()), id: \.element) { index, item in
                let current = index == model.tryIndex
                Button {
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
                        Text(item.needsPermission ? L("需要权限") : item.title)
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

    @ViewBuilder
    private var tryCard: some View {
        let item = tryItem
        VStack(alignment: .leading, spacing: 8) {
            if item.needsPermission, let permission = item.permission {
                Text(String(format: L("%@需要「%@」权限。"), item.title, permission.title))
                    .font(Theme.TypeScale.body)
                Button(L("去授权")) { PermissionCheck.request(permission) }
                    .controlSize(.small)
            } else {
                Text(tryExample)
                    .font(Theme.TypeScale.reading)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(tryHint)
                    .font(Theme.TypeScale.label)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer(minLength: 0)
                    Button(L("去试试")) { tryIt() }
                        .controlSize(.small)
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

    /// 一句对应语言的示例。划词、截图、会议字幕用目标语言；快捷翻译和语音用母语。
    private var tryExample: String {
        switch tryItem {
        case .select, .screenshot, .meeting: return samples.demoForeign
        case .quick, .voice: return samples.sayNative
        }
    }

    private var tryHint: String {
        switch tryItem {
        case .select:
            return String(format: L("点「去试试」，这句会填进翻译页并译成：%@"), samples.demoNative)
        case .screenshot:
            return String(format: L("点「去试试」后框住这句，识别出的字会译成：%@"), samples.demoNative)
        case .quick:
            return String(format: L("点「去试试」，这句会填进翻译页并译成：%@"), samples.sayForeign)
        case .voice:
            return String(format: L("点「去试试」后对着麦克风读这句，写进去的是：%@"), samples.sayForeign)
        case .meeting:
            return String(format: L("点「去试试」就开始听系统声音，字幕会译成：%@"), samples.demoNative)
        }
    }

    /// 点了就走现有动作。没授权的那一项上面已经改成「去授权」，到不了这里。
    private func tryIt() {
        model.noteTried()
        switch tryItem {
        case .select:
            putOnPasteboard(samples.demoForeign)
            onFinish(false)
            MainWindowController.shared.showTranslate(text: samples.demoForeign)
        case .screenshot:
            onFinish(false)
            (NSApp.delegate as? AppDelegate)?.ocrTranslate()
        case .quick:
            putOnPasteboard(samples.sayNative)
            onFinish(false)
            MainWindowController.shared.showTranslate(text: samples.sayNative)
        case .voice:
            onFinish(false)
            FnDictate.shared.beginForOnboarding()
        case .meeting:
            onFinish(false)
            let live = SystemAudioTranslateController.shared
            if !live.isActive {
                live.setCapture(.system, true)
            }
            MainWindowController.shared.show(page: .live)
            live.start()
        }
    }

    /// 划词和快捷翻译的示例句同时放进剪贴板，用户也可以自己贴到别处。
    private func putOnPasteboard(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
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
                shortcutRow(L("划词翻译"), L("⌥D"))
                shortcutRow(L("截图翻译"), L("⌥S"))
                shortcutRow(L("快捷翻译"), L("连按三下空格"))
                shortcutRow(L("打开 Korgino"), L("⌥⌘K"))
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
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
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
            if model.step != .language && model.step != .done {
                Button(L("上一步")) { goBack() }
                    .buttonStyle(.plain)
                    .font(Theme.TypeScale.body)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if model.step == .permissions {
                Button(L("跳过")) { advance() }
                    .buttonStyle(.plain)
                    .font(Theme.TypeScale.body)
                    .foregroundStyle(Theme.accent)
            }
            if model.step == .tryout {
                Button(L("跳过体验")) { advance() }
                    .buttonStyle(.plain)
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
        case .done:
            Button(L("打开 Korgino")) { onFinish(true) }
                .keyboardShortcut(.defaultAction)
        case .tryout:
            Button(model.tryIndex == OnboardingTry.allCases.count - 1 ? L("下一步") : L("下一个")) {
                model.noteTried()
                if model.tryIndex < OnboardingTry.allCases.count - 1 {
                    model.tryIndex += 1
                } else {
                    advance()
                }
            }
            .keyboardShortcut(.defaultAction)
        default:
            Button(L("下一步")) { advance() }
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
        VStack(alignment: .leading, spacing: 0) {
            content()
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

    private func row<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        HStack {
            Text(title)
                .font(Theme.TypeScale.body)
            Spacer(minLength: 12)
            control()
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 38)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.leading, 14)
        }
    }

    private func menuLabel(_ text: String) -> some View {
        HStack(spacing: 4) {
            Text(text)
                .font(Theme.TypeScale.body)
                .foregroundStyle(.primary)
            Image(systemName: "chevron.up.chevron.down")
                .font(Theme.TypeScale.micro)
                .foregroundStyle(.secondary)
        }
    }
}
