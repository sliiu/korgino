import AppKit
import SwiftUI

/// 主窗口里的一页。侧栏顺序就是这个枚举的顺序。
enum MainPage: String, CaseIterable, Identifiable {
    case translate
    case live
    case history
    case dictionary
    case media
    case voice

    var id: String { rawValue }

    var title: String {
        switch self {
        case .translate: return L("翻译")
        case .live: return L("实时与会议")
        case .history: return L("历史")
        case .dictionary: return L("词典")
        case .media: return L("媒体字幕")
        case .voice: return L("语音")
        }
    }

    var symbol: String {
        switch self {
        case .translate: return "character.bubble"
        case .live: return "waveform"
        case .history: return "clock"
        case .dictionary: return "text.book.closed"
        case .media: return "film"
        case .voice: return "mic"
        }
    }

    /// 「更多」下面的三项。功能在设置里关掉时侧栏不显示。
    var isMore: Bool {
        switch self {
        case .dictionary, .media, .voice: return true
        case .translate, .live, .history: return false
        }
    }

    /// 对应的功能开关。没有开关的页一直在。
    var feature: HotkeyAction? {
        switch self {
        case .dictionary: return .dictionary
        case .media: return .mediaCaptions
        case .voice: return nil
        case .translate, .live, .history: return nil
        }
    }

    func isShown(in config: AppConfig) -> Bool {
        switch self {
        case .voice: return config.dictateEnabled
        case .dictionary, .media:
            guard let feature else { return true }
            return config.isFeatureEnabled(feature)
        case .translate, .live, .history:
            return true
        }
    }
}

/// 主窗口：侧栏切换各页，记住大小和上次所在页。
/// 关掉它不退出；实时字幕在听时继续听，沉浸字幕和菜单栏图标都不跟着走。
@MainActor
final class MainWindowController {
    static let shared = MainWindowController()

    private var window: NSWindow?
    let model = MainWindowModel()

    func show(page: MainPage? = nil) {
        if let page {
            model.page = page
        }
        if window == nil {
            let root = MainWindowView(model: model)
                .environmentObject(AppConfig.shared)
            let host = NSHostingController(rootView: root)
            let w = NSWindow(contentViewController: host)
            w.title = "Korgino"
            w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 900, height: 620))
            w.minSize = NSSize(width: 760, height: 520)
            w.setFrameAutosaveName("KorginoMain")
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func relocalize() {
        model.epoch += 1
    }

    /// 截图前让开。框选盖住全屏，主窗口留在画面里会被一起截进去。
    func yieldForCapture() {
        window?.orderOut(nil)
    }
}

@MainActor
final class MainWindowModel: ObservableObject {
    @Published var page: MainPage {
        didSet { UserDefaults.standard.set(page.rawValue, forKey: Self.pageKey) }
    }
    /// 界面语言变了就加一，好让已经算出的文案重画。
    @Published var epoch = 0

    private static let pageKey = "mainWindow.page"

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.pageKey),
           let saved = MainPage(rawValue: raw) {
            page = saved
        } else {
            page = .translate
        }
    }
}

struct MainWindowView: View {
    @ObservedObject var model: MainWindowModel
    @EnvironmentObject private var config: AppConfig
    @ObservedObject private var live = SystemAudioTranslateController.shared

    private var listening: Bool {
        if case .listening = live.state { return true }
        return false
    }

    var body: some View {
        let _ = config.appLanguage
        let _ = model.epoch
        NavigationSplitView {
            sidebar
        } detail: {
            page(model.page)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 180, max: 180)
        .frame(minWidth: 760, minHeight: 520)
        .onChange(of: config.featureEnabled) { _, _ in keepPageVisible() }
        .onChange(of: config.dictateEnabled) { _, _ in keepPageVisible() }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $model.page) {
                ForEach(primary) { page in
                    row(page)
                }
                if !more.isEmpty {
                    Section(L("更多")) {
                        ForEach(more) { page in
                            row(page)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            Divider()
            Button {
                PreferencesController.shared.show()
            } label: {
                Label(L("设置"), systemImage: "gearshape")
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
    }

    private func row(_ page: MainPage) -> some View {
        Label {
            HStack(spacing: 6) {
                Text(page.title)
                if page == .live, listening {
                    Circle()
                        .fill(Theme.live)
                        .frame(width: 6, height: 6)
                        .accessibilityLabel(L("正在听"))
                }
            }
        } icon: {
            Image(systemName: page.symbol)
        }
        .font(.body)
        .tag(page)
    }

    private var primary: [MainPage] {
        MainPage.allCases.filter { !$0.isMore && $0.isShown(in: config) }
    }

    private var more: [MainPage] {
        MainPage.allCases.filter { $0.isMore && $0.isShown(in: config) }
    }

    @ViewBuilder
    private func page(_ page: MainPage) -> some View {
        switch page {
        case .translate:
            TranslatePage()
        case .live:
            LiveMeetingPage()
        case .history:
            HistoryFavoritesView(model: HistoryController.shared.model)
        case .dictionary:
            DictionaryView(model: DictionaryController.shared)
        case .media:
            MediaCaptionsPage()
                .background {
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { CaptionBudget.note("media", geo.size.width) }
                            .onChange(of: geo.size.width) { _, width in
                                CaptionBudget.note("media", width)
                            }
                    }
                }
        case .voice:
            VoicePage()
        }
    }

    /// 当前页被关掉时回到翻译页，免得侧栏空着、内容还停在看不见的页上。
    private func keepPageVisible() {
        guard !model.page.isShown(in: config) else { return }
        model.page = .translate
    }
}

/// 媒体字幕嵌进主窗口后，宽度从这一页量，不再从独立窗口量。
private struct MediaCaptionsPage: View {
    @ObservedObject private var model = MediaCaptionsController.shared
    @EnvironmentObject private var config: AppConfig

    var body: some View {
        let _ = config.appLanguage
        MediaCaptionsView(model: model)
    }
}

/// 翻译页。顶行选语言和三个入口，中间原文卡，下面各家译文。
/// 文档和拖进来的文件把这一页换成现有的文件翻译视图。
private struct TranslatePage: View {
    @EnvironmentObject private var config: AppConfig
    @ObservedObject private var files = FileTranslateController.shared
    @StateObject private var model = TranslatePageModel()

    var body: some View {
        let _ = config.appLanguage
        Group {
            if files.embedded {
                TranslateFilePane(files: files)
            } else {
                compose
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.windowFill)
    }

    private var compose: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let banner = model.banner {
                PermissionBanner(text: banner.text) {
                    model.authorize(banner.pane)
                }
            }
            toolbar
            sourceCard
            if model.hasResults {
                results
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .onAppear { model.refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissions()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            languageMenus
            Spacer(minLength: 8)
            pageButton("doc.on.clipboard", L("剪贴板"), enabled: config.isFeatureEnabled(.clipboard)) {
                model.fillClipboard()
            }
            pageButton("text.viewfinder", L("截图"), enabled: config.isFeatureEnabled(.ocr)) {
                model.captureScreenshot()
            }
            pageButton("doc", L("文档…"), enabled: config.isFeatureEnabled(.file)) {
                files.openInPlace()
            }
        }
    }

    private var languageMenus: some View {
        HStack(spacing: 6) {
            Menu {
                Button(L("自动检测")) { model.sourceLanguage = .auto }
                Divider()
                ForEach(TargetLanguage.specific) { language in
                    Button(language.menuTitle) { model.sourceLanguage = language }
                }
            } label: {
                menuLabel(model.sourceLanguage == .auto ? L("自动检测") : model.sourceLanguage.menuTitle)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Image(systemName: "arrow.right")
                .font(Theme.TypeScale.caption)
                .foregroundStyle(.tertiary)
            Menu {
                ForEach(TargetLanguage.specific) { language in
                    Button(language.menuTitle) { model.targetLanguage = language }
                }
            } label: {
                menuLabel(model.targetLanguage.menuTitle)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private func menuLabel(_ title: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(Theme.TypeScale.label)
                .foregroundStyle(.primary)
            Image(systemName: "chevron.down")
                .font(Theme.TypeScale.micro)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Theme.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 0.5)
        )
    }

    private func pageButton(_ symbol: String, _ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(Theme.TypeScale.label)
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!enabled)
    }

    private var sourceCard: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $model.source)
                .font(Theme.TypeScale.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(maxWidth: .infinity, minHeight: 150)
            if model.source.isEmpty {
                Text(L("输入、粘贴，或把文件拖进来 · ⌘↩ 翻译"))
                    .font(Theme.TypeScale.body)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 16)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Text("\(model.source.count)")
                .font(Theme.TypeScale.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .allowsHitTesting(false)
        }
        .card()
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard config.isFeatureEnabled(.file) else { return false }
            return files.handleEmbeddedDrop(providers: providers)
        }
        .background {
            Button("") { model.translateNow() }
                .keyboardShortcut(.defaultAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .onChange(of: model.source) { _, _ in model.sourceChanged() }
        .onChange(of: model.sourceLanguage) { _, _ in model.languageChanged() }
        .onChange(of: model.targetLanguage) { _, _ in model.languageChanged() }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(model.outcomes.enumerated()), id: \.element.id) { index, outcome in
                if index == model.expandedIndex {
                    TranslateResultCard(
                        outcome: outcome,
                        targets: model.switchableTargets,
                        speechCode: model.speechCode,
                        onPick: { model.useProvider($0) }
                    )
                } else {
                    TranslateFoldRow(outcome: outcome) {
                        model.expand(outcome.id)
                    }
                }
            }
        }
    }
}

/// 文档翻译：现有的文件翻译视图，顶上加「‹ 返回」。
private struct TranslateFilePane: View {
    @ObservedObject var files: FileTranslateController

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    files.leaveEmbedded()
                } label: {
                    Label(L("返回"), systemImage: "chevron.left")
                        .font(Theme.TypeScale.label)
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 4)
            FileTranslateView(model: files)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// 缺权限时内容区顶部的一条。一次只出最要紧的那条。
private struct PermissionBanner: View {
    let text: String
    let authorize: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Theme.attention)
                .frame(width: 6, height: 6)
            Text(text)
                .font(Theme.TypeScale.label)
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            Button(L("去授权"), action: authorize)
                .buttonStyle(.borderless)
                .font(Theme.TypeScale.label)
                .foregroundStyle(Theme.accent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.attention.opacity(0.12))
        )
    }
}

/// 展开的那一家：服务名可切、朗读、复制，下面是译文。
private struct TranslateResultCard: View {
    let outcome: ProviderOutcome
    let targets: [TranslateTarget]
    let speechCode: String?
    let onPick: (String) -> Void
    @State private var copiedID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Menu {
                    ForEach(targets) { target in
                        Button {
                            onPick(target.id)
                        } label: {
                            if target.id == outcome.id {
                                Label(target.displayName, systemImage: "checkmark")
                            } else {
                                Text(target.displayName)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        ProviderIconView(outcomeID: outcome.id, name: outcome.name, size: 12)
                        Text(outcome.name)
                            .font(Theme.TypeScale.caption)
                            .foregroundStyle(.primary)
                        Image(systemName: "chevron.down")
                            .font(Theme.TypeScale.micro)
                            .foregroundStyle(.secondary)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(targets.count < 2)
                Spacer(minLength: 8)
                if let text = outcome.text, !outcome.loading {
                    SpeakButton(text: text, language: speechCode, tag: "translatePage.\(outcome.id)")
                    CopyMarkdownMenu(id: outcome.id, text: text, copiedID: $copiedID)
                }
            }
            bodyContent
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    @ViewBuilder
    private var bodyContent: some View {
        if outcome.loading {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(L("翻译中…"))
                    .font(Theme.TypeScale.label)
                    .foregroundStyle(.secondary)
            }
        } else if let error = outcome.error, !error.isEmpty {
            ErrorLine(text: error)
        } else if let text = outcome.text {
            InlineMarkdownText(text: text, font: Theme.TypeScale.reading)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 没展开的那一家：图标、名字、译文摘要、展开箭头，点整行展开。
private struct TranslateFoldRow: View {
    let outcome: ProviderOutcome
    let expand: () -> Void

    var body: some View {
        Button(action: expand) {
            HStack(spacing: 8) {
                ProviderIconView(outcomeID: outcome.id, name: outcome.name, size: 12)
                Text(outcome.name)
                    .font(Theme.TypeScale.labelMedium)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .layoutPriority(1)
                peek
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .font(Theme.TypeScale.micro)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .card()
    }

    @ViewBuilder
    private var peek: some View {
        if outcome.loading {
            ProgressView().controlSize(.mini)
        } else if let error = outcome.error, !error.isEmpty {
            Text(error)
                .font(Theme.TypeScale.caption)
                .foregroundStyle(Theme.danger)
                .lineLimit(1)
        } else if let text = outcome.text {
            Text(MarkdownTextUtil.plain(text))
                .font(Theme.TypeScale.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// 这一页自己的语言和这一次用的服务。当前目标语言不写回设置。
@MainActor
private final class TranslatePageModel: ObservableObject {
    @Published var source = ""
    @Published var sourceLanguage: TargetLanguage = .auto
    @Published var targetLanguage: TargetLanguage
    @Published var outcomes: [ProviderOutcome] = []
    /// 展开成卡片的那一家。其余折成一行。
    @Published var expandedID: String?
    @Published var banner: (text: String, pane: PrivacyPane)?

    private var task: Task<Void, Never>?
    private var debounce: Task<Void, Never>?
    private var generation = 0
    /// 眼下这些译文对应的原文和语言。没变就不再发一次请求。
    private var translatedKey: String?

    init() {
        targetLanguage = AppConfig.shared.targetLanguage.resolvedDestination
    }

    var hasResults: Bool { !outcomes.isEmpty }

    var expandedIndex: Int {
        guard let expandedID, let index = outcomes.firstIndex(where: { $0.id == expandedID }) else { return 0 }
        return index
    }

    /// 菜单里能换成的那几家：划词选的，再加上目录里其余几家，好让这一次能切。
    var switchableTargets: [TranslateTarget] {
        let selected = selectedTargets()
        let extra = AppConfig.shared.catalogTargets().filter { target in
            !selected.contains { $0.id == target.id }
        }
        return selected + extra
    }

    var speechCode: String? {
        plan(for: source).tgt
    }

    func refreshPermissions() {
        if !PrivacyPane.accessibility.isGranted {
            banner = (L("划词翻译需要辅助功能权限"), .accessibility)
        } else if !PrivacyPane.screenCapture.isGranted {
            banner = (L("截图需要屏幕录制权限"), .screenCapture)
        } else if !PrivacyPane.inputMonitoring.isGranted {
            banner = (L("快捷翻译需要输入监视权限"), .inputMonitoring)
        } else {
            banner = nil
        }
    }

    func authorize(_ pane: PrivacyPane) {
        if pane.isGranted {
            PermissionGrantController.shared.openSettings(pane)
        } else {
            PermissionGrantController.shared.prompt(pane)
        }
    }

    func sourceChanged() {
        debounce?.cancel()
        let snapshot = source
        debounce = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, snapshot == source else { return }
            translateNow()
        }
    }

    func languageChanged() {
        debounce?.cancel()
        translateNow()
    }

    func translateNow() {
        debounce?.cancel()
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            task?.cancel()
            outcomes = []
            expandedID = nil
            translatedKey = nil
            return
        }
        let plan = plan(for: text)
        let key = "\(text)\n\(sourceLanguage.rawValue)\n\(targetLanguage.rawValue)"
        guard key != translatedKey else { return }
        translatedKey = key
        generation += 1
        let generation = generation
        var picked = selectedTargets()
        if let expandedID, let pinned = AppConfig.shared.catalogTargets().first(where: { $0.id == expandedID }),
           !picked.contains(where: { $0.id == pinned.id }) {
            picked.insert(pinned, at: 0)
        }
        let targets = picked
        outcomes = targets.map {
            ProviderOutcome(id: $0.id, name: $0.displayName, text: nil, error: nil, loading: true)
        }
        if expandedID == nil || !targets.contains(where: { $0.id == expandedID }) {
            expandedID = targets.first?.id
        }
        task?.cancel()
        task = Task { @MainActor in
            let result = await Background.run {
                await Translator.translateAll(text, targets: targets, plan: plan)
            }
            guard !Task.isCancelled, generation == self.generation else { return }
            outcomes = result.outcomes
            record(text: text, direction: result.direction, outcomes: result.outcomes)
        }
    }

    /// 切这一次用的服务：点到的那家展开。还没翻过就补上这一家。
    func useProvider(_ id: String) {
        guard let target = AppConfig.shared.catalogTargets().first(where: { $0.id == id }) else { return }
        expandedID = id
        guard !outcomes.contains(where: { $0.id == id }) else { return }
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let plan = plan(for: text)
        generation += 1
        let generation = generation
        outcomes.insert(
            ProviderOutcome(id: target.id, name: target.displayName, text: nil, error: nil, loading: true),
            at: 0
        )
        task = Task { @MainActor in
            let result = await Background.run {
                await Translator.translateAll(text, targets: [target], plan: plan)
            }
            guard !Task.isCancelled, generation == self.generation,
                  let outcome = result.outcomes.first,
                  let index = outcomes.firstIndex(where: { $0.id == id }) else { return }
            outcomes[index] = outcome
        }
    }

    func expand(_ id: String) {
        expandedID = id
    }

    func fillClipboard() {
        guard AppConfig.shared.isFeatureEnabled(.clipboard) else { return }
        guard let text = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            NSSound.beep()
            return
        }
        source = text
        translateNow()
    }

    func captureScreenshot() {
        guard AppConfig.shared.isFeatureEnabled(.ocr) else { return }
        task?.cancel()
        task = Task { @MainActor in
            MainWindowController.shared.yieldForCapture()
            do {
                let captured = try await OCRCapture.captureRegion()
                MainWindowController.shared.show()
                source = captured.0.text
                translateNow()
            } catch {
                MainWindowController.shared.show()
                let message = error.localizedDescription
                if message.contains("取消") || message.contains("已取消")
                    || message.localizedCaseInsensitiveContains("cancel") { return }
                outcomes = [
                    ProviderOutcome(
                        id: "ocr",
                        name: L("截图"),
                        text: nil,
                        error: String(format: L("OCR 失败：%@"), message),
                        loading: false
                    )
                ]
                expandedID = "ocr"
            }
        }
    }

    private func selectedTargets() -> [TranslateTarget] {
        let picked = AppConfig.shared.selectTranslateTargets(bundleID: nil)
        if !picked.isEmpty { return picked }
        return Array(AppConfig.shared.catalogTargets().prefix(1))
    }

    private func plan(for text: String) -> Lang.Plan {
        let picked = sourceLanguage == .auto ? nil : sourceLanguage
        var plan = Lang.plan(text, target: targetLanguage, source: picked?.appleCode, mutual: true)
        plan.chosenSource = picked
        return plan
    }

    private func record(text: String, direction: String, outcomes: [ProviderOutcome]) {
        let results = outcomes.map {
            HistoryProviderResult(id: $0.id, name: $0.name, text: $0.text, error: $0.error)
        }
        Task.detached(priority: .utility) {
            HistoryStore.append(source: text, direction: direction, kind: "select", results: results)
        }
    }
}

/// 实时字幕和会议记录收在同一页。听的状态在控制器上，离开这一页不会停。
private struct LiveMeetingPage: View {
    @EnvironmentObject private var config: AppConfig
    @ObservedObject private var live = SystemAudioTranslateController.shared

    var body: some View {
        let _ = config.appLanguage
        VStack(spacing: 0) {
            SystemAudioTranslateView(model: live)
                .environmentObject(config)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            MeetingRecordsView(model: MeetingRecordsController.shared.model)
                .environmentObject(config)
                .frame(maxWidth: .infinity)
                .frame(height: 220)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { CaptionBudget.note("live", geo.size.width) }
                    .onChange(of: geo.size.width) { _, width in
                        CaptionBudget.note("live", width)
                    }
            }
        }
    }
}

/// 语音还没有自己的页。这里只说明三种模式，并打开设置里现有的语音部分。
private struct VoicePage: View {
    @EnvironmentObject private var config: AppConfig

    var body: some View {
        let _ = config.appLanguage
        VStack(alignment: .leading, spacing: 12) {
            Text(L("语音"))
                .font(.title2)
            Text(L("按住 Fn 走当前这一条：语音识别、语音翻译或语音传译。快捷键只切换模式，不开始听。"))
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(L("打开语音设置")) {
                PreferencesController.shared.showVoice()
            }
            .buttonStyle(.bordered)
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
