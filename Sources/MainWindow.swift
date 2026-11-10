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
        model.showingSettings = false
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

    /// ⌘, 和侧栏底部的「设置」进到这里，不再开独立窗口。
    func showSettings(tab: PreferencesTab = .common) {
        show()
        model.openSettings(tab)
    }

    /// 引导把示例句填进翻译页的原文框并翻译。走现有的剪贴板填充，不新写一条翻译。
    func showTranslate(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model.pendingSource = trimmed
        show(page: .translate)
        model.translateRequest += 1
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
    /// 侧栏换成设置目录。返回时回到之前的页。
    @Published var showingSettings = false
    @Published var settingsTab: PreferencesTab = .common
    /// 引导交了一句要翻的例句。翻译页听这个数，出现后填进去。
    @Published var translateRequest = 0
    var pendingSource: String?

    private static let pageKey = "mainWindow.page"

    func openSettings(_ tab: PreferencesTab) {
        let resolved: PreferencesTab = tab == .about ? .account : tab
        settingsTab = resolved == .voice ? .common : resolved
        showingSettings = true
    }

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
        HStack(spacing: 0) {
            sidebar
                .frame(width: Theme.sidebarWidth)
                .frame(maxHeight: .infinity)
                .background(Theme.sidebarFill)
            Rectangle()
                .fill(Theme.hairline)
                .frame(width: 0.5)
                .frame(maxHeight: .infinity)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.windowFill)
        }
        .frame(minWidth: 760, minHeight: 520)
        .background(Theme.windowFill)
        .onChange(of: config.featureEnabled) { _, _ in keepPageVisible() }
        .onChange(of: config.dictateEnabled) { _, _ in keepPageVisible() }
    }

    @ViewBuilder
    private var detail: some View {
        if model.showingSettings {
            PreferencesDetail(tab: model.settingsTab)
        } else {
            page(model.page)
        }
    }

    @ViewBuilder
    private var sidebar: some View {
        if model.showingSettings {
            SettingsSidebar(tab: $model.settingsTab) {
                model.showingSettings = false
            }
        } else {
            pagesSidebar
        }
    }

    private var pagesSidebar: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(primary) { page in
                row(page)
            }
            if !more.isEmpty {
                SidebarGroupLabel(title: L("更多"))
                ForEach(more) { page in
                    row(page)
                }
            }
            Spacer(minLength: 8)
            row(settings: true)
        }
        .padding(.horizontal, 10)
        .padding(.top, 36)
        .padding(.bottom, 10)
    }

    private func row(_ page: MainPage) -> some View {
        SidebarRow(
            title: page.title,
            systemImage: page.symbol,
            selected: model.page == page,
            badge: page == .live && listening
        ) {
            model.page = page
        }
    }

    private func row(settings: Bool) -> some View {
        SidebarRow(title: L("设置"), systemImage: "gearshape", selected: false) {
            model.openSettings(.common)
        }
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
            VoiceSettingsPage()
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
        VStack(alignment: .leading, spacing: 0) {
            if let banner = model.banner {
                PermissionBanner(text: banner.text) {
                    model.authorize(banner.pane)
                }
                .padding(.horizontal, 26)
                .padding(.top, 14)
            }
            VStack(alignment: .leading, spacing: 14) {
                toolbar
                sourceCard
                if model.hasResults {
                    results
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 22)
        }
        .onAppear {
            model.refreshPermissions()
            consumePending()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissions()
        }
        .onChange(of: MainWindowController.shared.model.translateRequest) { _, _ in
            consumePending()
        }
    }

    /// 引导交来的例句。和剪贴板按钮一样，填进原文框再翻译。
    private func consumePending() {
        guard let text = MainWindowController.shared.model.pendingSource else { return }
        MainWindowController.shared.model.pendingSource = nil
        model.fillSource(text)
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
        HStack(spacing: 8) {
            MenuChip(
                title: model.sourceLanguage == .auto ? L("自动检测") : model.sourceLanguage.menuTitle,
                options: sourceChoices,
                label: { $0 == .auto ? L("自动检测") : $0.menuTitle },
                isSelected: { $0 == model.sourceLanguage },
                select: { model.sourceLanguage = $0 }
            )
            Text("→")
                .font(Theme.TypeScale.body)
                .foregroundStyle(.tertiary)
            MenuChip(
                title: model.targetLanguage.menuTitle,
                options: TargetLanguage.specific,
                label: { $0.menuTitle },
                isSelected: { $0 == model.targetLanguage },
                select: { model.targetLanguage = $0 }
            )
        }
    }

    private var sourceChoices: [TargetLanguage] {
        [.auto] + TargetLanguage.specific
    }

    private func pageButton(_ symbol: String, _ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        PageButton(title: title, systemImage: symbol, action: action)
            .disabled(!enabled)
    }

    private var sourceCard: some View {
        PageCard(minHeight: 150, padding: EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0), content:
            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.source)
                    .font(Theme.TypeScale.body)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                    .frame(maxWidth: .infinity, minHeight: 150)
                if model.source.isEmpty {
                    Text(L("输入、粘贴，或把文件拖进来 · ⌘↩ 翻译"))
                        .font(Theme.TypeScale.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 16)
                        .padding(.bottom, 12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                Text("\(model.source.count)")
                    .font(Theme.TypeScale.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .padding(.trailing, 16)
                    .padding(.bottom, 12)
                    .allowsHitTesting(false)
            }
        )
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
        PageCard(padding: EdgeInsets(top: 12, leading: 16, bottom: 0, trailing: 16), content:
            VStack(alignment: .leading, spacing: 0) {
                if model.outcomes.indices.contains(model.expandedIndex) {
                    TranslateResultBody(
                        outcome: model.outcomes[model.expandedIndex],
                        targets: model.switchableTargets,
                        speechCode: model.speechCode,
                        onPick: { model.useProvider($0) }
                    )
                }
                ForEach(Array(model.outcomes.enumerated()), id: \.element.id) { index, outcome in
                    if index != model.expandedIndex {
                        TranslateFoldRow(outcome: outcome) {
                            model.expand(outcome.id)
                        }
                    }
                }
            }
        )
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

/// 展开的那一家：服务名可切、朗读、复制，下面是译文。卡本身由翻译页包一层。
private struct TranslateResultBody: View {
    let outcome: ProviderOutcome
    let targets: [TranslateTarget]
    let speechCode: String?
    let onPick: (String) -> Void
    @State private var copiedID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ProviderIconView(outcomeID: outcome.id, name: outcome.name, size: 14)
                MenuChip(
                    title: outcome.name,
                    options: targets.map(\.id),
                    label: { id in targets.first { $0.id == id }?.displayName ?? id },
                    isSelected: { $0 == outcome.id },
                    select: { onPick($0) }
                )
                .disabled(targets.count < 2)
                Spacer(minLength: 8)
                if let text = outcome.text, !outcome.loading {
                    SpeakButton(text: text, language: speechCode, tag: "translatePage.\(outcome.id)")
                    CopyMarkdownMenu(id: outcome.id, text: text, copiedID: $copiedID)
                }
            }
            bodyContent
                .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                ProviderIconView(outcomeID: outcome.id, name: outcome.name, size: 14)
                Text(outcome.name)
                    .font(Theme.TypeScale.labelMedium)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .layoutPriority(1)
                peek
                Spacer(minLength: 8)
                ChromeChevron(color: Color.primary.opacity(0.32))
            }
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .overlay(alignment: .top) {
                Rectangle().fill(Theme.hairline).frame(height: 0.5)
            }
        }
        .buttonStyle(.plain)
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
        fillSource(text)
    }

    /// 把一句放进原文框并翻译。剪贴板按钮和引导的「去试试」都走这里。
    func fillSource(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        source = trimmed
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
/// 没在听是两张采集卡加会议记录；正在听时整页换成字幕，停了再回到卡片。
private struct LiveMeetingPage: View {
    @EnvironmentObject private var config: AppConfig
    @ObservedObject private var live = SystemAudioTranslateController.shared
    @ObservedObject private var records = MeetingRecordsController.shared.model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 哪张卡展开了设置。同一时间只展开一张，开始或收起就收回。
    @State private var setup: SystemAudioTranslateController.SourceKind?

    var body: some View {
        let _ = config.appLanguage
        Group {
            if live.isActive {
                LiveListeningView(model: live)
            } else {
                idle
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.windowFill)
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { CaptionBudget.note("live", geo.size.width) }
                    .onChange(of: geo.size.width) { _, width in
                        CaptionBudget.note("live", width)
                    }
            }
        }
        .onAppear { records.reload() }
        .onChange(of: live.isActive) { _, active in
            if active { setup = nil }
        }
    }

    private var idle: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                cards
                startBar
                MeetingRecordList(model: records)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 展开的那张排在上面，另一张收到下面。收起时两张并排。
    @ViewBuilder
    private var cards: some View {
        let kinds = SystemAudioTranslateController.SourceKind.allCases
        if let open = setup {
            VStack(spacing: 12) {
                LiveSourceCard(model: live, kind: open, expanded: true) { toggleSetup(open) }
                ForEach(kinds.filter { $0 != open }) { kind in
                    LiveSourceCard(model: live, kind: kind, expanded: false) { toggleSetup(kind) }
                }
            }
            .animation(cardMotion, value: setup)
        } else {
            HStack(alignment: .top, spacing: 12) {
                ForEach(kinds) { kind in
                    LiveSourceCard(model: live, kind: kind, expanded: false) { toggleSetup(kind) }
                        .frame(maxWidth: .infinity, alignment: .top)
                }
            }
        }
    }

    private var cardMotion: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.2)
    }

    private func toggleSetup(_ kind: SystemAudioTranslateController.SourceKind) {
        withAnimation(cardMotion) {
            setup = setup == kind ? nil : kind
        }
    }

    private var armed: [SystemAudioTranslateController.SourceKind] {
        SystemAudioTranslateController.SourceKind.allCases.filter { live.captures($0) }
    }

    private var startBar: some View {
        let count = armed.count
        let ready = count > 0 && !live.isRequestingPermission
        return HStack(spacing: 12) {
            Text(sessionLine)
                .font(Theme.TypeScale.body)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            PageButton(title: startTitle, primary: true) { begin() }
                .keyboardShortcut(.defaultAction)
                .disabled(!ready)
                .help(ready ? L("打开的几路一起开始，记成同一场会议记录") : L("先打开一路"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(Theme.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 0.5)
        )
    }

    private var sessionLine: String {
        guard !armed.isEmpty else { return L("先打开一路") }
        let names = armed.map { kind -> String in
            if kind == .microphone, live.captureSystem {
                return "\(kind.title)（\(live.micDeviceName)）"
            }
            return kind.title
        }
        return String(format: L("这一场听：%@ · 记成同一场会议记录"), names.joined(separator: " + "))
    }

    private var startTitle: String {
        let count = armed.count
        if live.isRequestingPermission { return L("准备中…") }
        if count == 0 { return L("先打开一路") }
        return String(format: L("开始 · %@ 路"), String(count))
    }

    private func begin() {
        guard !armed.isEmpty, !live.isRequestingPermission else { return }
        setup = nil
        live.start()
    }
}

/// 一张采集卡。收起时只露听什么、译成什么；设置在这张卡里原地展开。
private struct LiveSourceCard: View {
    @ObservedObject var model: SystemAudioTranslateController
    @EnvironmentObject private var config: AppConfig
    var kind: SystemAudioTranslateController.SourceKind
    var expanded: Bool
    var onToggleSetup: () -> Void

    private var on: Bool { model.captures(kind) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            VStack(alignment: .leading, spacing: 12) {
                direction
                if expanded {
                    LiveCaptureSettings(model: model, kind: kind)
                } else {
                    Text(model.serviceLine(kind))
                        .font(Theme.TypeScale.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .opacity(on ? 1 : 0.4)
            .allowsHitTesting(on)
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(Theme.cardFill)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(expanded ? Theme.accent.opacity(0.45) : Theme.hairline, lineWidth: expanded ? 1.5 : 0.5)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: kind == .system ? "speaker.wave.2.fill" : "mic.fill")
                .font(Theme.TypeScale.reading)
                .foregroundStyle(Theme.accent)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.accent.opacity(0.12)))
            Text(kind.title)
                .font(Theme.TypeScale.body).fontWeight(.semibold)
            if kind == .microphone {
                Text(model.micDeviceName)
                    .font(Theme.TypeScale.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(action: onToggleSetup) {
                HStack(spacing: 3) {
                    Text(expanded ? L("收起设置") : L("设置"))
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }
                .font(Theme.TypeScale.caption)
                .foregroundStyle(expanded ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(expanded ? L("收起设置") : L("展开设置"))
            Toggle("", isOn: capture)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .disabled(model.isRequestingPermission)
                .help(kind.title)
                .accessibilityLabel(kind.title)
        }
    }

    private var direction: some View {
        HStack(spacing: 8) {
            Text(L("听"))
                .font(Theme.TypeScale.caption)
                .foregroundStyle(.secondary)
            LiveLocaleMenu(model: model, kind: kind)
            Text(L("译成"))
                .font(Theme.TypeScale.caption)
                .foregroundStyle(.secondary)
            LiveTargetMenu(model: model, kind: kind)
        }
    }

    private var capture: Binding<Bool> {
        Binding(
            get: { model.captures(kind) },
            set: { model.setCapture(kind, $0) }
        )
    }
}

/// 听什么语言。和识别引擎用同一份可选语言。
private struct LiveLocaleMenu: View {
    @ObservedObject var model: SystemAudioTranslateController
    var kind: SystemAudioTranslateController.SourceKind

    var body: some View {
        let choices = ASRLanguage.available(apple: model.laneUsesSystemSpeech(kind))
        MenuChip(
            title: model.asrLanguage(for: kind).title,
            options: choices.map(\.id),
            label: { id in choices.first { $0.id == id }?.title ?? id },
            isSelected: { $0 == model.asrLanguage(for: kind).id },
            select: { model.setLocale(kind, $0) }
        )
        .disabled(model.isActive || model.isRequestingPermission)
    }
}

/// 译成什么。改的是这一路第一家翻译；没有翻译时先加一家。
private struct LiveTargetMenu: View {
    @ObservedObject var model: SystemAudioTranslateController
    var kind: SystemAudioTranslateController.SourceKind

    private var lane: RecognitionLane? { model.lanes(kind).first }
    private var binding: LaneBinding? { lane?.bindings.first { !$0.isSource } }

    var body: some View {
        let languages: [TargetLanguage] = {
            if let lane, let binding { return model.bindingLanguages(lane, binding) }
            if lane != nil { return TargetLanguage.specific }
            return []
        }()
        MenuChip(
            title: binding?.target.shortTitle ?? L("不翻译"),
            options: languages,
            label: { $0.shortTitle },
            isSelected: { $0 == binding?.target },
            select: { lang in
                if let lane, let binding {
                    model.setBindingTarget(lane.id, kind, binding.key, lang)
                } else if let lane {
                    model.ensureTranslation(lane.id, kind, lang)
                }
            }
        )
        .disabled(model.isActive || model.isRequestingPermission || lane == nil)
    }
}

/// 卡片里展开的设置：识别与翻译，再加分说话人、录音、译音送到。
private struct LiveCaptureSettings: View {
    @ObservedObject var model: SystemAudioTranslateController
    @EnvironmentObject private var config: AppConfig
    var kind: SystemAudioTranslateController.SourceKind

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("识别与翻译"))
                .font(Theme.TypeScale.caption)
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(Array(model.lanes(kind).enumerated()), id: \.element.id) { index, lane in
                    if index > 0 { Divider() }
                    laneBlock(lane, index: index)
                }
                if model.canAddBinding {
                    Divider()
                    actions
                }
            }
            .card(fill: Theme.wellFill, radius: 10, stroke: false)
            Text(L("更多"))
                .font(Theme.TypeScale.caption)
                .foregroundStyle(.secondary)
            more
                .card(fill: Theme.wellFill, radius: 10, stroke: false)
        }
    }

    private func laneBlock(_ lane: RecognitionLane, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(String(format: L("第 %@ 路 · %@"), String(index + 1), model.laneTitle(lane)))
                    .font(Theme.TypeScale.body).fontWeight(.medium)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Menu {
                    let taken = Set(model.lanes(kind).filter { $0.id != lane.id }.map(\.asrID))
                    ForEach(config.liveASRChoices().filter { !taken.contains($0.id) }) { choice in
                        Button(choice.name) { model.setLaneEngine(lane.id, kind, choice.id) }
                    }
                } label: {
                    Text(L("换引擎"))
                        .font(Theme.TypeScale.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(model.isActive)
                if model.lanes(kind).count > 1 {
                    Menu {
                        Button(L("移除这一路识别"), role: .destructive) {
                            model.removeRecognitionLane(lane.id, kind)
                        }
                        .disabled(model.isActive)
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(Theme.TypeScale.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.04))
            ForEach(lane.bindings) { binding in
                Divider()
                bindingRow(lane, binding)
            }
        }
    }

    private func bindingRow(_ lane: RecognitionLane, _ binding: LaneBinding) -> some View {
        let immersive = model.immersiveKey(kind, lane.asrID, binding.key)
        let on = model.immersiveOn.contains(immersive)
        let removable = lane.bindings.count > 1 || !binding.isSource
        return HStack(spacing: 8) {
            ProviderMark(id: binding.translateID)
            Menu {
                Button(L("不翻译")) { model.setBindingService(lane.id, kind, binding.key, LaneBinding.sourceID) }
                if model.offersInterp(lane, binding) {
                    Button(L("同传")) { model.setBindingService(lane.id, kind, binding.key, LaneBinding.interpID) }
                }
                Divider()
                ForEach(model.liveServiceChoices(), id: \.id) { target in
                    Button(target.displayName) { model.setBindingService(lane.id, kind, binding.key, target.id) }
                }
            } label: {
                Text(LaneBindingNames.service(binding.translateID))
                    .font(Theme.TypeScale.body)
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            if binding.isSource {
                Text(L("只出原文"))
                    .font(Theme.TypeScale.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Menu {
                    ForEach(model.bindingLanguages(lane, binding)) { lang in
                        Button(lang.shortTitle) { model.setBindingTarget(lane.id, kind, binding.key, lang) }
                    }
                } label: {
                    Text(binding.target.shortTitle)
                        .font(Theme.TypeScale.body)
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            if binding.isInterp {
                Text(L("同传"))
                    .font(Theme.TypeScale.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if let profile = model.bindingProfile(binding) {
                ModelOverrideMenu(profile: profile, override: $model.modelOverrides.model(for: profile), maxWidth: 120)
            }
            Toggle(L("沉浸字幕"), isOn: Binding(
                get: { on },
                set: { model.setImmersive(immersive, on: $0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(Theme.TypeScale.caption)
            .fixedSize()
            Button {
                model.removeBinding(lane.id, kind, binding.key)
            } label: {
                Image(systemName: "xmark")
                    .font(Theme.TypeScale.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .disabled(!removable)
            .opacity(removable ? 1 : 0)
            .help(L("移除这条翻译"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.canAddBinding, let lane = model.lanes(kind).first {
                Button {
                    model.addBinding(lane.id, kind)
                } label: {
                    Label(L("加翻译"), systemImage: "plus")
                        .font(Theme.TypeScale.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
            }
            if Pro.unlocked {
                addLane
            }
        }
    }

    private var addLane: some View {
        let taken = Set(model.lanes(kind).map(\.asrID))
        let choices = config.liveASRChoices().filter { !taken.contains($0.id) }
        return Menu {
            ForEach(choices) { choice in
                Button(choice.name) { model.addRecognitionLane(kind, asrID: choice.id) }
            }
        } label: {
            Label(L("再加一路识别"), systemImage: "plus")
                .font(Theme.TypeScale.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .disabled(choices.isEmpty || model.isActive)
        .padding(.horizontal, 4)
    }

    private var more: some View {
        VStack(spacing: 0) {
            if kind == .microphone {
                settingRow(L("设备")) { LiveMicDeviceMenu(model: model) }
                Divider()
            }
            settingRow(L("分说话人")) {
                VoiceprintSettingRow(
                    threshold: model.thresholdBinding(kind),
                    reseparateInterp: $model.reseparateInterp,
                    listening: model.isActive
                )
            }
            Divider()
            settingRow(L("录音"), detail: L("开始后把听到的声音另存一份，停止后可从「导出」存成 M4A")) {
                Toggle("", isOn: Binding(
                    get: { model.recordAudio },
                    set: { model.setRecordAudio($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .disabled(model.isActive || model.isRequestingPermission)
            }
            Divider()
            settingRow(L("译音送到"), detail: kind == .microphone
                ? L("通话时把你这一路的同传译音送进虚拟声卡，聊天软件选它当麦克风；对方那一路的译音自动播到耳机。请戴耳机。")
                : L("同传译音在本机的音量。通话时聊天软件会压低其他声音，可以调大。")) {
                if kind == .microphone {
                    LiveRelayMenu(model: model)
                } else {
                    HStack(spacing: 8) {
                        Slider(value: $model.interpGain, in: 1...6)
                            .frame(width: 120)
                        Text(String(format: "×%.1f", model.interpGain))
                            .font(Theme.TypeScale.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func settingRow<Control: View>(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.TypeScale.body)
                if let detail {
                    Text(detail)
                        .font(Theme.TypeScale.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

private struct ProviderMark: View {
    var id: String

    var body: some View {
        let letter = String(LaneBindingNames.service(id).prefix(1))
        Text(letter)
            .font(Theme.TypeScale.micro)
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(Circle().fill(Color.accentColor.opacity(0.85)))
    }
}

private struct LiveMicDeviceMenu: View {
    @ObservedObject var model: SystemAudioTranslateController

    var body: some View {
        let devices = MicInput.devices()
        Menu {
            Button(L("系统默认")) { model.micDeviceUID = "" }
            ForEach(devices) { device in
                Button(device.name) { model.micDeviceUID = device.uid }
            }
        } label: {
            Text(model.micDeviceName)
                .font(Theme.TypeScale.caption)
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(model.isActive)
    }
}

private struct LiveRelayMenu: View {
    @ObservedObject var model: SystemAudioTranslateController

    var body: some View {
        let devices = AudioOutputs.devices()
        let name = devices.first { $0.uid == model.relayDeviceUID }?.name
            ?? (model.relayDeviceUID.isEmpty ? L("不送出") : L("已断开"))
        return Menu {
            Button(L("不送出")) { model.relayDeviceUID = "" }
            ForEach(devices) { device in
                Button(device.name) { model.relayDeviceUID = device.uid }
            }
        } label: {
            Text(name)
                .font(Theme.TypeScale.caption)
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(model.isActive)
        .help(L("通话时把你这一路的同传译音送进虚拟声卡，聊天软件选它当麦克风；对方那一路的译音自动播到耳机。请戴耳机。"))
    }
}

/// 正在听。顶栏管整场，下面按采集分栏，笔记从右侧拉出。
private struct LiveListeningView: View {
    @ObservedObject var model: SystemAudioTranslateController
    @EnvironmentObject private var config: AppConfig
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var setup: SystemAudioTranslateController.SourceKind?
    @State private var noteOpen = false
    @State private var jump: CaptionJump?

    private var shown: [SystemAudioTranslateController.SourceKind] {
        SystemAudioTranslateController.SourceKind.allCases.filter { model.captures($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(alignment: .top, spacing: 0) {
                columns
                if noteOpen {
                    Divider()
                    noteColumn
                        .frame(width: 280)
                        .transition(.move(edge: .trailing))
                }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: noteOpen)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            if let started = model.sessionStartedAt {
                TimelineView(.periodic(from: started, by: 1)) { context in
                    StatusDot(.live, "\(L("正在听")) \(MeetingExport.clock(context.date.timeIntervalSince(started)))")
                }
            } else {
                StatusDot(.live, L("正在听"))
            }
            Text(sessionName)
                .font(Theme.TypeScale.body)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button {
                model.showImmersiveOverlay()
            } label: {
                Label(L("沉浸字幕"), systemImage: "captions.bubble")
            }
            .disabled(model.immersiveChips().isEmpty)
            .help(model.immersiveOn.isEmpty ? L("打开沉浸字幕") : L("沉浸字幕"))
            Button {
                openNote()
            } label: {
                Label(L("笔记"), systemImage: "square.and.pencil")
            }
            .disabled(!canRewrite)
            exportMenu
            Button(role: .destructive) {
                model.stop()
            } label: {
                Label(L("停止"), systemImage: "stop.fill")
            }
            .keyboardShortcut(".", modifiers: [.command])
            .tint(Theme.danger)
        }
        .font(Theme.TypeScale.label)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.windowFill)
    }

    private var sessionName: String {
        model.recordTitle.isEmpty ? L("会议记录") : model.recordTitle
    }

    /// 两边都开时是综合笔记。只开一路时用这一路自己的笔记。
    private var noteTarget: (SystemAudioTranslateController.SourceKind, RecognitionLane)? {
        guard !model.offersCombinedNote, let only = shown.first, let lane = model.lanes(only).first else { return nil }
        return (only, lane)
    }

    private var canRewrite: Bool {
        if let (kind, lane) = noteTarget { return model.canWriteNote(lane.id, kind) }
        return model.canWriteCombinedNote()
    }

    private var exportMenu: some View {
        Menu {
            Button(L("字幕（SRT）…")) { model.exportCaptions() }
                .disabled(!model.canExportCaptions())
            if !model.recordings.isEmpty {
                Button(L("录音（M4A）…")) { model.exportRecordings() }
                    .disabled(model.isActive)
            }
        } label: {
            Label(L("导出…"), systemImage: "square.and.arrow.up")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var columns: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element) { index, kind in
                if index > 0 { Divider() }
                LiveListenColumn(model: model, kind: kind, setup: setup == kind, jump: jump) {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                        setup = setup == kind ? nil : kind
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
    }

    private var noteColumn: some View {
        let slot = noteSlot
        return SessionNoteCard(
            title: L("一场笔记"),
            page: slot.page,
            writing: slot.writing,
            error: slot.error,
            following: slot.follow && model.isActive,
            maxHeight: nil,
            onJump: { raw in
                guard let id = UUID(uuidString: raw), let lane = model.noteLane(id) else { return }
                jump = CaptionJump(lane: lane, id: id, tick: (jump?.tick ?? 0) + 1)
            },
            onRewrite: canRewrite ? { openNote() } : nil,
            onClose: {
                closeNote()
                noteOpen = false
            }
        )
        .padding(12)
    }

    private var noteSlot: SessionNoteSlot {
        if let (kind, lane) = noteTarget { return model.noteSlot(lane.id, kind) }
        return model.combinedNote
    }

    private func openNote() {
        noteOpen = true
        if let (kind, lane) = noteTarget {
            model.writeNote(lane.id, kind)
        } else {
            model.writeCombinedNote()
        }
    }

    private func closeNote() {
        if let (kind, lane) = noteTarget {
            model.closeNote(lane.id, kind)
        } else {
            model.closeCombinedNote()
        }
    }
}

/// 正在听时的一路：栏头是采集名、方向、电平和设置，下面是这一路的字幕。
private struct LiveListenColumn: View {
    @ObservedObject var model: SystemAudioTranslateController
    @EnvironmentObject private var config: AppConfig
    var kind: SystemAudioTranslateController.SourceKind
    var setup: Bool
    var jump: CaptionJump?
    var onToggleSetup: () -> Void
    @State private var editingID: UUID?
    @State private var editSource = ""
    @State private var editTranslations: [String: String] = [:]
    @State private var hoveredID: UUID?
    @State private var clearing: UUID?
    @State private var batching: UUID?
    @ObservedObject private var speech = SpeechPlayback.shared

    private var segments: [LiveCaptionSegment] {
        (kind == .system ? model.systemSegments : model.micSegments)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            columnHeader
            if setup {
                LiveCaptureSettings(model: model, kind: kind)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
            ForEach(model.lanes(kind)) { lane in
                laneBody(lane)
            }
        }
        .confirmationDialog(
            L("清空这一路的字幕？"),
            isPresented: Binding(get: { clearing != nil }, set: { if !$0 { clearing = nil } }),
            presenting: clearing
        ) { lane in
            Button(L("清空"), role: .destructive) { model.clearDisplayedLane(lane, kind) }
        } message: { _ in
            Text(L("字幕、标记和笔记会一起清掉，别的路不动。"))
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 8) {
            Text(kind.title)
                .font(Theme.TypeScale.body).fontWeight(.semibold)
            Text(model.directionLine(kind))
                .font(Theme.TypeScale.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            levelMeter
            Spacer(minLength: 6)
            Button(action: onToggleSetup) {
                HStack(spacing: 3) {
                    Text(setup ? L("收起") : L("设置"))
                    Image(systemName: setup ? "chevron.up" : "chevron.down")
                }
                .font(Theme.TypeScale.caption)
                .foregroundStyle(setup ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var levelMeter: some View {
        let level = kind == .system ? model.systemLevel : model.micLevel
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4, id: \.self) { index in
                let on = level > Double(index) * 0.22
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(on ? Color.accentColor : Color.primary.opacity(0.15))
                    .frame(width: 3, height: CGFloat(6 + index * 3))
            }
        }
        .frame(height: 16, alignment: .bottom)
        .help(L("识别中"))
    }

    private func laneBody(_ lane: RecognitionLane) -> some View {
        let mine = segments.filter { $0.laneID == lane.id }
        let draft = model.laneDrafts[lane.id]
        let showingDraft = draft?.partial == true && !(draft?.text ?? "").isEmpty
        return VStack(alignment: .leading, spacing: 0) {
            if model.lanes(kind).count > 1 {
                Text(String(format: L("第 %@ 路 · %@"), laneIndex(lane), model.laneTitle(lane)))
                    .font(Theme.TypeScale.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 4)
            }
            LaneCaptionScroller(
                noteOpen: false,
                token: captionToken(mine, draft),
                hasLines: !mine.isEmpty || showingDraft,
                pinToBottom: true,
                maxHeight: nil,
                jump: jump?.lane == lane.id ? jump : nil
            ) {
                if mine.isEmpty, !showingDraft {
                    Text(L("正在听，听到人声就会出字幕"))
                        .font(Theme.TypeScale.label)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                }
                ForEach(Array(mine.enumerated()), id: \.element.id) { index, seg in
                    let previous = index > 0 ? mine[index - 1] : nil
                    captionRow(seg, lane: lane, latest: seg.id == mine.last?.id, showSpeaker: previous?.speaker != seg.speaker)
                }
                if showingDraft, let draft {
                    draftRow(draft, lane: lane)
                }
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(L("批量")) { batching = lane.id }
                    .buttonStyle(.borderless)
                    .disabled(mine.isEmpty && !showingDraft)
                    .popover(
                        isPresented: Binding(
                            get: { batching == lane.id },
                            set: { if !$0 { batching = nil } }
                        ),
                        arrowEdge: .bottom
                    ) {
                        CaptionBatchSheet(cues: model.batchCues(lane.id, kind)) { ids in
                            model.deleteSegments(ids, kind: kind)
                        }
                    }
                Button(L("清空")) { clearing = lane.id }
                    .buttonStyle(.borderless)
                    .disabled(mine.isEmpty && !showingDraft)
            }
            .font(Theme.TypeScale.caption)
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
    }

    private func laneIndex(_ lane: RecognitionLane) -> String {
        let index = model.lanes(kind).firstIndex { $0.id == lane.id } ?? 0
        return String(index + 1)
    }

    private func captionRow(_ seg: LiveCaptionSegment, lane: RecognitionLane, latest: Bool, showSpeaker: Bool) -> some View {
        let keys = translationKeys(seg)
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .trailing, spacing: 4) {
                Text(clock(seg.start))
                    .font(Theme.TypeScale.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if showSpeaker, let mark = model.markToken(lane: seg.laneID, kind: kind, speaker: seg.speaker) {
                    speakerMark(seg, mark: mark)
                }
            }
            .frame(width: 44, alignment: .trailing)
            VStack(alignment: .leading, spacing: 4) {
                if editingID == seg.id {
                    editor(seg, keys: keys)
                } else {
                    HStack(alignment: .top, spacing: 6) {
                        highlightedSource(seg.source, ranges: seg.maskRanges)
                            .font(Theme.TypeScale.body)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        rowActions(seg, keys: keys)
                            .opacity(hoveredID == seg.id ? 1 : 0)
                    }
                    ForEach(Array(keys.enumerated()), id: \.element) { index, key in
                        if let text = segmentTranslation(seg, providerID: key) {
                            translationBlock(text, key: key, labeled: keys.count > 1, failed: seg.errors[key] != nil, first: index == 0) {
                                model.speak(text, kind: .translation, source: kind, target: LaneBinding(key: key)?.target, lane: seg.laneID, speaker: seg.speaker)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(jump?.id == seg.id ? Color.accentColor.opacity(0.08) : Color.clear)
        .onHover { inside in hoveredID = inside ? seg.id : (hoveredID == seg.id ? nil : hoveredID) }
    }

    private func editor(_ seg: LiveCaptionSegment, keys: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(L("原文"), text: $editSource, axis: .vertical)
                .font(Theme.TypeScale.body)
                .textFieldStyle(.roundedBorder)
            ForEach(keys, id: \.self) { key in
                TextField(LaneBindingNames.title(key: key), text: Binding(
                    get: { editTranslations[key] ?? "" },
                    set: { editTranslations[key] = $0 }
                ), axis: .vertical)
                .font(Theme.TypeScale.reading)
                .textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer(minLength: 0)
                Button(L("完成")) { commit(seg) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button(L("取消")) { editingID = nil }
                    .controlSize(.small)
            }
        }
    }

    private func rowActions(_ seg: LiveCaptionSegment, keys: [String]) -> some View {
        HStack(spacing: 0) {
            IconButton(systemImage: "pencil", help: L("修改")) {
                editingID = seg.id
                editSource = seg.source
                editTranslations = Dictionary(uniqueKeysWithValues: keys.map { ($0, seg.translations[$0] ?? "") })
            }
            IconButton(systemImage: "speaker.wave.2", help: speech.notice.isEmpty ? L("朗读原文") : speech.notice) {
                model.speak(seg.source, kind: .source, source: kind, lane: seg.laneID, speaker: seg.speaker)
            }
            IconButton(systemImage: "trash", help: L("删除")) {
                if editingID == seg.id { editingID = nil }
                model.deleteSegment(id: seg.id, kind: kind)
            }
        }
    }

    private func translationBlock(_ text: String, key: String, labeled: Bool, failed: Bool, first: Bool, speak: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if labeled {
                Text(LaneBindingNames.title(key: key))
                    .font(Theme.TypeScale.caption)
                    .foregroundStyle(.tertiary)
            }
            if failed {
                ErrorLine(text: text)
            } else {
                HStack(alignment: .top, spacing: 6) {
                    Text(text)
                        .font(Theme.TypeScale.reading)
                        .foregroundStyle(Color.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    IconButton(systemImage: "speaker.wave.2", help: speech.notice.isEmpty ? L("朗读译文") : speech.notice, action: speak)
                        .opacity(hoveredID == nil ? 0 : 1)
                        .disabled(text == L("翻译中…"))
                }
            }
        }
    }

    private func draftRow(_ draft: LaneDraft, lane: RecognitionLane) -> some View {
        let keys = draft.translations.keys.sorted().filter { !(draft.translations[$0] ?? "").isEmpty }
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .trailing, spacing: 4) {
                Text(L("识别中"))
                    .font(Theme.TypeScale.caption)
                    .foregroundStyle(.tertiary)
                if let mark = model.markToken(lane: lane.id, kind: kind, speaker: draft.speaker) {
                    speakerDot(draft.speaker, mark: mark)
                }
            }
            .frame(width: 44, alignment: .trailing)
            VStack(alignment: .leading, spacing: 4) {
                highlightedSource(draft.text, ranges: draft.mask)
                    .font(Theme.TypeScale.body)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(Array(keys.enumerated()), id: \.element) { index, key in
                    let text = draft.translations[key] ?? ""
                    VStack(alignment: .leading, spacing: 2) {
                        if keys.count > 1 {
                            Text(LaneBindingNames.title(key: key))
                                .font(Theme.TypeScale.caption)
                                .foregroundStyle(.tertiary)
                        }
                        if text.hasPrefix(L("翻译失败")) {
                            ErrorLine(text: text)
                        } else {
                            Text(text)
                                .font(Theme.TypeScale.reading)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// 圆标。点开仍能改名、并入另一位、换朗读的声音。
    private func speakerMark(_ seg: LiveCaptionSegment, mark: String) -> some View {
        let rows = model.speakerRows(seg.laneID, kind)
        return SpeakerChipButton(
            speaker: seg.speaker,
            token: mark,
            canDelete: false,
            onRename: { model.renameSpeaker(seg.laneID, kind, seg.speaker, to: $0) },
            onDelete: {},
            others: rows.filter { $0.id != seg.speaker },
            onMerge: { model.mergeSpeaker(seg.laneID, kind, seg.speaker, into: $0) },
            voices: SpeakerVoice.choices(language: model.asrLanguage(for: kind).locale.identifier),
            voiceID: model.speakerVoice(seg.laneID, kind, seg.speaker),
            onVoice: { model.setSpeakerVoice(seg.laneID, kind, seg.speaker, to: $0) }
        ) { speakerDot(seg.speaker, mark: mark) }
    }

    private func speakerDot(_ speaker: Int, mark: String) -> some View {
        let hue = SpeakerPalette.color(for: speaker)
        let letter = String(SpeakerMarkText.display(mark).prefix(1))
        return Text(letter.isEmpty ? "•" : letter)
            .font(Theme.TypeScale.micro)
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(Circle().fill(hue))
            .help(SpeakerMarkText.display(mark))
    }

    private func translationKeys(_ seg: LiveCaptionSegment) -> [String] {
        var keys = model.lanes(kind).first { $0.id == seg.laneID }?.translatingKeys ?? []
        let extra = Set(seg.translations.keys).union(seg.loadingProviderIDs).union(seg.errors.keys)
        for key in extra.sorted() where !keys.contains(key) { keys.append(key) }
        return keys.filter { segmentTranslation(seg, providerID: $0) != nil }
    }

    private func segmentTranslation(_ seg: LiveCaptionSegment, providerID: String) -> String? {
        if let text = seg.translations[providerID], !text.isEmpty { return text }
        if seg.loadingProviderIDs.contains(providerID) { return L("翻译中…") }
        if let error = seg.errors[providerID], !error.isEmpty { return error }
        return nil
    }

    private func captionToken(_ segments: [LiveCaptionSegment], _ draft: LaneDraft?) -> Int {
        var hasher = Hasher()
        for seg in segments {
            hasher.combine(seg.id)
            hasher.combine(seg.source)
            hasher.combine(seg.translations)
            hasher.combine(seg.errors)
            hasher.combine(seg.loadingProviderIDs.isEmpty)
        }
        hasher.combine(draft?.text)
        hasher.combine(draft?.translations)
        return hasher.finalize()
    }

    private func commit(_ seg: LiveCaptionSegment) {
        model.updateSegment(id: seg.id, kind: kind, source: editSource, translation: nil, providerID: "")
        for (key, text) in editTranslations {
            model.updateSegment(id: seg.id, kind: kind, source: editSource, translation: text, providerID: key)
        }
        editingID = nil
    }

    private func clock(_ time: TimeInterval) -> String {
        let seconds = Int(max(0, time).rounded(.down))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// 没在听时的会议记录。一行一场，点开仍是原来的记录。
private struct MeetingRecordList: View {
    @ObservedObject var model: MeetingRecordsModel
    @State private var open: MeetingRecordsModel.Entry?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("会议记录"))
                    .font(Theme.TypeScale.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(String(format: L("共 %@ 场"), String(model.filtered.count)))
                    .font(Theme.TypeScale.caption)
                    .foregroundStyle(.tertiary)
            }
            if model.filtered.isEmpty {
                Text(model.entries.isEmpty ? L("还没有会议记录") : L("没有符合的记录"))
                    .font(Theme.TypeScale.body)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .card(radius: 12)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.filtered.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { Divider().padding(.leading, 14) }
                        row(entry)
                    }
                }
                .card(radius: 12)
            }
        }
        .sheet(item: $open) { entry in
            MeetingRecordSheet(model: model, entry: entry)
        }
    }

    private func row(_ entry: MeetingRecordsModel.Entry) -> some View {
        let record = entry.record
        return Button {
            model.select(entry.id)
            open = entry
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.title(record))
                        .font(Theme.TypeScale.body).fontWeight(.medium)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle(record))
                        .font(Theme.TypeScale.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(Theme.TypeScale.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(L("在访达中显示")) { model.reveal(entry.id) }
            Divider()
            Button(L("删除"), role: .destructive) { model.delete(entry.id) }
                .disabled(model.isRecording(record))
        }
    }

    private func subtitle(_ record: MeetingRecord) -> String {
        var parts = [record.startedAt.formatted(date: .abbreviated, time: .shortened)]
        parts.append(MeetingExport.duration(record.duration))
        let captures = record.lanes.map(\.captureTitle).reduce(into: [String]()) { list, title in
            if !list.contains(title) { list.append(title) }
        }
        if !captures.isEmpty { parts.append(captures.joined(separator: " + ")) }
        return parts.joined(separator: " · ")
    }
}

/// 点开一场会议记录。内容还是原来的详情，只是从这一页拉出来。
private struct MeetingRecordSheet: View {
    @ObservedObject var model: MeetingRecordsModel
    var entry: MeetingRecordsModel.Entry
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.title(entry.record))
                    .font(Theme.TypeScale.title)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button(L("关闭")) { dismiss() }
            }
            .padding(14)
            Divider()
            MeetingRecordDetail(model: model, entry: entry)
        }
        .frame(minWidth: 640, minHeight: 480)
    }
}

