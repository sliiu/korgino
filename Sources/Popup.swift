import Combine
import AppKit
import SwiftUI


struct OCRGroup: Identifiable {
    var id: String
    var name: String
    var source: String
    var outcomes: [ProviderOutcome]
}

struct PopupTabSnapshot: Identifiable {
    let id: UUID
    var title: String
    var source: String
    var direction: String
    var outcomes: [ProviderOutcome]
    var loading: Bool
    var globalError: String?
    var pendingFirstTranslate: Bool
    var sourceCaption: String
    var kind: String
    var ocrShot: CGImage?
    var showsOCRShot: Bool
    var dictEntry: DictionaryEntry?
    var dictLoading: Bool
    var dictError: String?
    var dictQuery: String
    var dictAutoQuery: String
    var dictExpanded: Bool
    var collapsedProviderIDs: Set<String>
    var openedProviderIDs: Set<String>
    var detectedLinks: [DetectedLink]
    var chatExpanded: Bool
    var targetLanguage: TargetLanguage
    var sourceLanguage: TargetLanguage
    var translatedText: String
    var translatedTarget: TargetLanguage?
    var plugin: SelectionPlugin?
}

final class PopupModel: ObservableObject {
    @Published var source = ""
    @Published var direction = ""
    @Published var outcomes: [ProviderOutcome] = []
    @Published var loading = true
    @Published var globalError: String?
    @Published var copiedID: String?
    @Published var chatExpanded = false
    /// OCR draft: recognized text shown for edit before first translate.
    @Published var pendingFirstTranslate = false
    /// Header above source editor ("原文" vs "识别文字").
    @Published var sourceCaption = L("原文（可编辑）")
    /// When true, outside-click / focus-loss will not dismiss the popup.
    @Published var pinned = false
    /// 用户折起来的服务。第一家不在这里就是展开的。
    @Published var collapsedProviderIDs: Set<String> = []
    /// 用户点开过的第二家及以后。不在这里的默认折成一行。
    @Published var openedProviderIDs: Set<String> = []
    /// In-panel dictionary. Short lemmas open it; long text waits for a typed query.
    @Published var dictEntry: DictionaryEntry? = nil
    @Published var dictLoading = false
    @Published var dictError: String? = nil
    @Published var dictQuery = ""
    /// Last query chosen automatically from source or translation. A different `dictQuery` is the user's.
    @Published var dictAutoQuery = ""
    @Published var dictExpanded = false
    /// Heights the user dragged the dictionary and chat panes to. Kept across popups; nil splits by content.
    @Published var dictPaneHeight: CGFloat? = nil
    @Published var chatPaneHeight: CGFloat? = nil
    /// Links / QR payloads detected from OCR (or text).
    @Published var detectedLinks: [DetectedLink] = []
    /// When pinned, multiple translate sessions as tabs.
    @Published var tabs: [PopupTabSnapshot] = []
    @Published var activeTabID: UUID? = nil
    /// select / clipboard / ocr / file / plugin — for favorites metadata.
    @Published var sessionKind: String = "select"
    /// 这一页是哪个划词插件跑出来的。重新翻译时重跑它，而不是退回普通翻译。
    @Published var sessionPlugin: SelectionPlugin? = nil
    /// Pro 在这一次浮层里临时加上的翻译服务，不写回设置。
    @Published var sessionExtraIDs: [String] = []
    /// 这次浮层换的模型。和临时加的家一样，新开一次浮层就清掉，不写回设置。
    @Published var sessionModelOverrides: ModelOverrides = [:]
    /// 这一页的目标语言。不写回设置。
    @Published var targetLanguage: TargetLanguage = .en
    /// 这一页的原文语言。`.auto` 按检测走；短词常判错，可以手选。不写回设置。
    @Published var sourceLanguage: TargetLanguage = .auto
    /// 眼下这些译文用的原文和目标语言。没翻过时为 nil。
    @Published var translatedText = ""
    @Published var translatedTarget: TargetLanguage? = nil
    /// 截图多路识别。第一家仍走 source，其余挂在这里。
    @Published var ocrGroups: [OCRGroup] = []
    /// 截图 OCR 的原始裁剪图。只有 OCR 这一页有；原文区可以切过去看。
    @Published var ocrShot: CGImage?
    /// 原文区现在显示的是原图而不是识别文字。
    @Published var showsOCRShot = false
    /// This tab came from a live 划词 and can try 写回.
    @Published var writeBackOffered = false
    /// Why 写回 is shown but cannot run. Nil when it can.
    @Published var writeBackBlocked: String? = nil
    /// ⌘1…⌘9 marks. Hidden until Command has been held for a second.
    @Published var writeBackShortcutsVisible = false
    /// Refusal for the button that was just clicked. Nil after a tab change.
    @Published var writeBackNoteID: String? = nil
    @Published var writeBackNote: String? = nil
    /// Bumped when favorites change so star buttons refresh.
    @Published var favoriteBump: Int = 0

    var singleMode: Bool { outcomes.count <= 1 }

    var primaryText: String? {
        outcomes.first(where: { $0.text != nil })?.text ?? outcomes.first?.text
    }

    /// 对话里能选作提问对象的各家译文。
    var chatTranslations: [ChatContextItem] { ChatContextItem.translations(outcomes) }

    var bestTranslation: String {
        if let t = outcomes.first(where: { $0.text != nil })?.text { return t }
        return outcomes.compactMap(\.text).joined(separator: "\n\n")
    }

    /// 改了目标语言，还没重新翻译。
    var targetPending: Bool {
        translatedTarget.map { $0 != targetLanguage } ?? false
    }

    /// This page's plan. A picked source replaces detection.
    func plan(for text: String) -> Lang.Plan {
        plan(for: text, target: targetLanguage)
    }

    func plan(for text: String, target: TargetLanguage) -> Lang.Plan {
        let picked = sourceLanguage == .auto ? nil : sourceLanguage
        var plan = Lang.plan(text, target: target, source: picked?.appleCode, mutual: true)
        plan.chosenSource = picked
        return plan
    }

    var canChat: Bool {
        !loading && globalError == nil && outcomes.contains(where: { $0.text != nil })
    }
}

struct PopupView: View {
    @ObservedObject var model: PopupModel
    @ObservedObject var chat: ChatSession
    @ObservedObject private var config = AppConfig.shared
    @ObservedObject private var pro = Pro.shared
    var onCopy: (String) -> Void
    var onToggleChat: () -> Void
    var onRelayout: () -> Void
    var onLookupDictionary: () -> Void
    var onRetranslate: () -> Void
    var onTogglePin: () -> Void
    var onSelectTab: (UUID) -> Void
    var onCloseTab: (UUID) -> Void
    var onWriteBack: (String, String) -> Void
    /// Measurement leaves this false so a short translation reports its own height.
    /// The on-screen panel sets it so a dragged window stays filled, including the empty area below a short result.
    var fillsWindow = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// On-screen heights of the lower panes, so a drag starts from what is shown.
    @State private var dictPaneShown: CGFloat = 0
    @State private var chatPaneShown: CGFloat = 0
    /// 原文超过三行时点开看全。每次重新翻译收回去。
    @State private var sourceExpanded = false
    /// 「再加一家」就地弹出的服务列表。
    @State private var addProviderOpen = false

    var body: some View {
        Group {
            // Dictionary sits outside the result scroller, same as chat, so the panel
            // grows to its height. Inside that scroller it only appeared by scrolling.
            if fillsWindow && (chatOpen || model.dictExpanded) {
                paneSplit
            } else {
                huggedColumn
            }
        }
        .frame(maxWidth: .infinity, maxHeight: fillsWindow ? .infinity : nil, alignment: .topLeading)
        .background { panelGlass }
        .overlay {
            // 效果图 `.mat`：0.5 磅描边，黑 12%。
            panelShape.strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5)
        }
        .clipShape(panelShape)
        .shadow(color: Theme.panelShadow, radius: Theme.panelShadowRadius, y: Theme.panelShadowY)
        .controlSize(.small)
        .onChange(of: chat.messages.count) { _, _ in
            DispatchQueue.main.async { onRelayout() }
        }
        .onChange(of: chat.isSending) { _, _ in
            DispatchQueue.main.async { onRelayout() }
        }
        .onChange(of: model.source) { _, _ in
            sourceExpanded = false
        }
        .onChange(of: model.loading) { _, loading in
            if loading { sourceExpanded = false }
        }
    }

    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous)
    }

    private var glassOpacity: Double {
        min(1, max(0.35, config.panelOpacity))
    }

    private var panelGlass: some View {
        panelShape
            .fill(.regularMaterial)
            .compositingGroup()
            .opacity(glassOpacity)
    }

    /// Fixed-height title bar — pin icon / symbol metrics must not change chrome height.
    /// 效果图 / HTML `.popup .head` 是 34，不是之前的 36。
    private let chromeHeight: CGFloat = 34

    private var header: some View {
        ZStack {
            WindowDragHandle()
            HStack(spacing: 2) {
                directionMenu
                Spacer(minLength: 8)
                IconButton(
                    systemImage: "character.book.closed",
                    help: model.dictExpanded ? L("收起释义") : L("查词"),
                    tint: model.dictExpanded ? .accentColor : nil
                ) {
                    model.dictExpanded.toggle()
                    onRelayout()
                }
                IconButton(
                    systemImage: model.pinned ? "pin.fill" : "pin",
                    help: model.pinned ? L("取消固定（点击外部可关闭）") : L("固定窗口（点击外部不关闭）"),
                    tint: model.pinned ? .accentColor : nil,
                    action: onTogglePin
                )
                IconButton(
                    systemImage: "xmark",
                    help: L("关闭窗口"),
                    action: { AppDelegate.shared?.popup.dismiss() }
                )
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity)
        .frame(height: chromeHeight)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
        }
        .clipped()
    }

    private struct DirectionChoice: Hashable {
        enum Kind: Hashable { case target, source }
        var kind: Kind
        var language: TargetLanguage
        var title: String
    }

    /// 顶栏方向本身就是目标语言选择。原文语言留在同一个菜单里，不再另放一个下拉。
    private var popupDirectionChoices: [DirectionChoice] {
        let targets = TargetLanguage.specific.map {
            DirectionChoice(kind: .target, language: $0, title: $0.shortTitle)
        }
        let sources = [DirectionChoice(kind: .source, language: .auto, title: L("自动检测"))]
            + TargetLanguage.specific.map {
                DirectionChoice(kind: .source, language: $0, title: $0.shortTitle)
            }
        return targets + sources
    }

    private var directionMenu: some View {
        MenuChip(
            title: "\(sourceLabel) → \(targetLabel)",
            options: popupDirectionChoices,
            label: { $0.title },
            isSelected: { choice in
                switch choice.kind {
                case .target: return choice.language == model.targetLanguage
                case .source: return choice.language == model.sourceLanguage
                }
            },
            select: { choice in
                switch choice.kind {
                case .target:
                    model.targetLanguage = choice.language
                case .source:
                    guard choice.language != model.sourceLanguage else { return }
                    model.sourceLanguage = choice.language
                    if canRetranslate && !model.pendingFirstTranslate { onRetranslate() }
                }
            }
        )
        .disabled(model.loading)
        .help(model.targetPending
            ? L("目标语言已改，点原文旁的重新翻译生效")
            : L("这一页的目标语言，不改设置"))
    }

    /// 已启用、并且这一次还没在译的服务。勾上只管这一次。
    private var addableTargets: [TranslateTarget] {
        let have = Set(model.outcomes.map(\.id)).union(model.sessionExtraIDs)
        return config.catalogTargets().filter { !have.contains($0.id) }
    }

    private var addableOCR: [OCRProviderID] {
        guard model.sessionKind == "ocr" else { return [] }
        return config.orderedOCRProviders().filter { provider in
            config.isOCROn(provider)
                && provider != config.ocrProvider
                && !model.ocrGroups.contains { $0.id == provider.rawValue }
        }
    }

    private func addOCR(_ provider: OCRProviderID) {
        guard let image = model.ocrShot else { return }
        Task { @MainActor in
            let text = (try? await CloudOCR.recognizeText(cgImage: image, provider: provider)) ?? ""
            guard !text.isEmpty else { return }
            let targets = AppConfig.shared.translateTargets(.ocr).map { $0.applying(model.sessionModelOverrides) }
            var group = OCRGroup(id: provider.rawValue, name: provider.displayName, source: text, outcomes: targets.map {
                ProviderOutcome(id: $0.id, name: $0.displayName, text: nil, error: nil, loading: true)
            })
            model.ocrGroups.append(group)
            let plan = model.plan(for: text)
            let result = await Translator.translateAll(text, targets: targets, plan: plan)
            group.outcomes = result.outcomes
            if let index = model.ocrGroups.firstIndex(where: { $0.id == group.id }) {
                model.ocrGroups[index] = group
            }
            onRelayout()
        }
    }

    /// `direction` is「原文语言 → 译成语言」from `Lang.languagePair`.
    private var directionParts: [String] {
        model.direction.components(separatedBy: " → ")
    }

    private var directionTarget: String? {
        let parts = directionParts
        return parts.count == 2 ? parts[1] : nil
    }

    private var sourceLabel: String {
        if model.sourceLanguage != .auto { return model.sourceLanguage.shortTitle }
        let parts = directionParts
        if parts.count == 2 { return parts[0] }
        return L("自动检测")
    }

    /// The language the shown translations went into, until a new pick waits for 重新翻译.
    private var targetLabel: String {
        if !model.targetPending, let target = directionTarget { return target }
        return model.targetLanguage.shortTitle
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(model.tabs) { tab in
                    let active = tab.id == model.activeTabID
                    HStack(spacing: 0) {
                        Button {
                            onSelectTab(tab.id)
                        } label: {
                            Text(tab.title)
                                .lineLimit(1)
                                .frame(maxWidth: 120)
                                .padding(.leading, 10)
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Button {
                            onCloseTab(tab.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(Theme.TypeScale.micro)
                                .foregroundStyle(.secondary)
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(L("关闭标签"))
                        .padding(.trailing, 2)
                    }
                    .font(Theme.TypeScale.caption).fontWeight(active ? .semibold : .regular)
                    .foregroundStyle(active ? Color.accentColor : Color.primary.opacity(0.75))
                    .background(
                        Capsule(style: .continuous)
                            .fill(active ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05))
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
    }

    private var chatAllowed: Bool {
        let _ = pro.purchased
        let _ = pro.trialEnd
        #if KORGI_DEV
        let _ = pro.devUnlocked
        #endif
        return Pro.unlocked
    }

    /// 宽度 360 起，最宽 560（拖拽照旧）。测量用起点。
    private var popupWidth: CGFloat { 360 }

    private var canRetranslate: Bool {
        !model.loading
            && !model.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var chatOpen: Bool { model.chatExpanded && chatAllowed }

    private var panelChrome: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if model.tabs.count > 1 {
                tabBar
            }
        }
    }

    /// Measurement path. Chat and dictionary report their own height, so the panel can grow.
    private var huggedColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelChrome
            translationColumn
            if model.dictExpanded {
                dictionaryColumn(fills: false)
            }
            if chatOpen {
                chatColumn(fills: false)
            }
            followUpBar
        }
    }

    /// On-screen path once the window has a real height. Each open pane keeps a visible strip;
    /// the translation scrolls inside what is left.
    @ViewBuilder
    private var paneSplit: some View {
        if chatOpen, model.dictExpanded {
            PopupChatSplit(chatMin: 120, chatHeight: model.chatPaneHeight) {
                VStack(alignment: .leading, spacing: 0) {
                    panelChrome
                    PopupChatSplit(chatMin: 64, chatHeight: model.dictPaneHeight) {
                        translationColumn
                        dictionaryPane
                    }
                }
                .clipped()
                VStack(spacing: 0) {
                    chatPane
                    followUpBar
                }
            }
        } else if chatOpen {
            PopupChatSplit(chatMin: 120, chatHeight: model.chatPaneHeight) {
                VStack(alignment: .leading, spacing: 0) {
                    panelChrome
                    translationColumn
                }
                .clipped()
                VStack(spacing: 0) {
                    chatPane
                    followUpBar
                }
            }
        } else {
            PopupChatSplit(chatMin: 64, chatHeight: model.dictPaneHeight) {
                VStack(alignment: .leading, spacing: 0) {
                    panelChrome
                    translationColumn
                }
                .clipped()
                VStack(spacing: 0) {
                    dictionaryPane
                    followUpBar
                }
            }
        }
    }

    /// 底部常驻一行。没有 Pro 时不打开对话，只写需要 Pro。
    private var followUpBar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            if chatAllowed {
                PopupFollowUpBar(
                    session: chat,
                    canAsk: model.canChat,
                    onSend: {
                        if !model.chatExpanded {
                            chat.configure(source: model.source, translations: model.chatTranslations)
                            model.chatExpanded = true
                        }
                        chat.send()
                        onRelayout()
                    }
                )
            } else {
                Button {
                    Pro.shared.showOffer()
                } label: {
                    HStack(spacing: 6) {
                        Text(L("继续对话需要 Pro"))
                            .font(Theme.TypeScale.label)
                        ProBadge(help: L("继续对话需要 Pro"))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var dictionaryPane: some View {
        dictionaryColumn(fills: true)
            .padding(.top, 4)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { dictPaneShown = $0 }
            .overlay(alignment: .top) {
                PaneResizeHandle(height: $model.dictPaneHeight, current: dictPaneShown)
                    .offset(y: -4)
            }
    }

    private var chatPane: some View {
        chatColumn(fills: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { chatPaneShown = $0 }
            .overlay(alignment: .top) {
                PaneResizeHandle(height: $model.chatPaneHeight, current: chatPaneShown)
                    .offset(y: -4)
            }
    }

    private var translationColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 水平内边距都在 sourceWell / resultColumn 里，避免再叠 12。
            sourceWell
                .padding(.bottom, showsResults ? 0 : 12)
                .layoutPriority(1)
            if showsResults {
                resultScroller
                    .layoutPriority(0)
            }
        }
    }

    private func chatColumn(fills: Bool) -> some View {
        VStack(spacing: 0) {
            Divider().frame(height: 1)
            TranslationChatView(
                session: chat,
                compact: true,
                hugsContent: !fills,
                onWriteBack: model.writeBackOffered ? { id, text in onWriteBack(id, text) } : nil,
                writeBackBlocked: model.writeBackBlocked,
                writeBackNoteID: model.writeBackNoteID,
                writeBackNote: model.writeBackNote
            )
            .environmentObject(AppConfig.shared)
            .frame(maxWidth: .infinity, maxHeight: fills ? .infinity : nil, alignment: .top)
        }
    }

    /// OCR draft with nothing under the source yet: no result column, so the well keeps the bottom inset.
    private var showsResults: Bool {
        model.globalError != nil
            || !model.detectedLinks.isEmpty
            || !model.pendingFirstTranslate
    }

    @ViewBuilder
    private func dictionaryColumn(fills: Bool) -> some View {
        let section = PopupDictionarySection(
            entry: model.dictEntry,
            loading: model.dictLoading,
            error: model.dictError,
            expanded: Binding(
                get: { model.dictExpanded },
                set: {
                    model.dictExpanded = $0
                    onRelayout()
                }
            ),
            query: $model.dictQuery,
            onSubmit: onLookupDictionary
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        if fills {
            ScrollView {
                section.fixedSize(horizontal: false, vertical: true)
            }
            .scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            section.fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Hugs the translation when it fits. A plain `ScrollView` reports the proposed height and would
    /// stretch the panel even for a one-line result; `ViewThatFits` only scrolls once the column is taller
    /// than the height the window actually has.
    private var resultScroller: some View {
        ViewThatFits(in: .vertical) {
            resultColumn.fixedSize(horizontal: false, vertical: true)
            ScrollView {
                resultColumn.fixedSize(horizontal: false, vertical: true)
            }
            .scrollContentBackground(.hidden)
        }
    }

    private var resultColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !model.detectedLinks.isEmpty {
                DetectedLinksBar(links: model.detectedLinks)
                    .padding(.bottom, 8)
            }
            if let e = model.globalError {
                errorText(e)
            } else if model.pendingFirstTranslate {
                EmptyView()
            } else {
                providerList
            }
            ocrGroupList
            if !model.pendingFirstTranslate, model.globalError == nil {
                addProviderRow
            }
        }
        // 与 sourceWell 同列：效果图 body 左右 14。
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 原文和译文在同一块面板上。次要色、最多三行，点开看全。没有灰底。
    private var sourceWell: some View {
        VStack(alignment: .leading, spacing: 2) {
            if model.showsOCRShot, let shot = model.ocrShot {
                ocrShotPreview(shot)
            } else if model.pendingFirstTranslate {
                SourceEditor(text: $model.source, isEnabled: !model.loading, onHeightChange: onRelayout)
            } else {
                Text(model.source)
                    .font(Theme.TypeScale.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(sourceExpanded ? nil : 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        sourceExpanded.toggle()
                        onRelayout()
                    }
                    .help(sourceExpanded ? L("收起原文") : L("点开看全文"))
            }
            sourceActions
        }
        // 效果图 `.popup .body`：左右 14、顶 12。
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var sourceActions: some View {
        if model.pendingFirstTranslate {
            HStack(spacing: 2) {
                ocrShotToggle
                Spacer(minLength: 0)
                Button(L("翻译")) { onRetranslate() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canRetranslate)
                    .help(L("涂改识别文字后点击翻译"))
            }
        } else {
            HStack(spacing: 2) {
                ocrShotToggle
                Spacer(minLength: 0)
                SpeakButton(text: model.source, help: L("朗读原文"), tag: "popup.source")
                    .disabled(model.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                IconButton(
                    systemImage: "arrow.clockwise",
                    help: model.targetPending
                        ? L("按新的目标语言重新翻译")
                        : L("用编辑后的原文再次翻译"),
                    tint: model.targetPending ? .accentColor : nil,
                    size: 11,
                    action: onRetranslate
                )
                .disabled(!canRetranslate)
            }
            .opacity(0.72)
        }
    }

    /// 识别到的那张裁剪图，可缩放、旋转、拖动。
    private func ocrShotPreview(_ shot: CGImage) -> some View {
        OCRShotPanel(image: shot)
            .frame(height: 240)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    @ViewBuilder
    private var ocrShotToggle: some View {
        if model.ocrShot != nil {
            IconButton(
                systemImage: model.showsOCRShot ? "text.alignleft" : "photo",
                help: model.showsOCRShot ? L("看识别文字") : L("看截图原图"),
                tint: model.showsOCRShot ? .accentColor : nil,
                size: 11,
                action: toggleOCRShot
            )
        }
    }

    private func toggleOCRShot() {
        guard model.ocrShot != nil else { return }
        model.showsOCRShot.toggle()
        onRelayout()
    }

    private func errorText(_ e: String) -> some View {
        ErrorLine(text: e)
    }

    /// 设置里的那份 AI 配置。不是 AI 的那家为空。
    private func aiProfile(_ o: ProviderOutcome) -> AIProfile? {
        config.aiProfiles.first { "ai:\($0.id)" == o.id }
    }

    /// AI 那家名字旁边的模型。换了只重出这一家。
    @ViewBuilder
    private func modelMenu(_ o: ProviderOutcome) -> some View {
        if let p = aiProfile(o) {
            ModelOverrideMenu(
                profile: p,
                override: Binding(
                    get: { model.sessionModelOverrides[p.id] },
                    set: { AppDelegate.shared?.setSessionModel($0, for: p) }
                ),
                maxWidth: 140,
                freeBadge: false
            )
            .disabled(o.loading)
        }
    }

    private func loadingRow(_ title: String = L("翻译中…")) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(title).font(Theme.TypeScale.label).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    /// 正在跑的那件事叫什么。翻译插件和普通翻译一样写「翻译中」，别的插件写自己的名字。
    private var loadingTitle: String {
        guard let plugin = model.sessionPlugin, plugin.kind != .translate else { return L("翻译中…") }
        return String(format: L("%@中…"), plugin.title)
    }

    /// 第一家展开，其余折成一行。一家时也走这里，不再另画一张白卡。
    private var providerList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.outcomes.isEmpty, model.loading {
                loadingRow(loadingTitle)
                    .padding(.vertical, 8)
            }
            ForEach(Array(model.outcomes.enumerated()), id: \.element.id) { index, o in
                providerBlock(o, index: index, open: providerOpen(o, index: index))
                if index < model.outcomes.count - 1 {
                    Rectangle().fill(Theme.hairline).frame(height: 0.5)
                }
            }
        }
    }

    /// 第一家默认展开。其余默认折起，用户点开过的留在 `collapsedProviderIDs` 之外。
    private func providerOpen(_ o: ProviderOutcome, index: Int) -> Bool {
        if model.collapsedProviderIDs.contains(o.id) { return false }
        if index == 0 || model.outcomes.count <= 1 { return true }
        return model.openedProviderIDs.contains(o.id)
    }

    private func providerBlock(_ o: ProviderOutcome, index: Int, open: Bool) -> some View {
        ProviderHoverRow {
            VStack(alignment: .leading, spacing: 6) {
                if open {
                    expandedProvider(o, index: index)
                } else {
                    collapsedProvider(o, index: index)
                }
                writeBackNote(for: o.id)
            }
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func expandedProvider(_ o: ProviderOutcome, index: Int) -> some View {
        if o.loading, o.text == nil {
            loadingRow(loadingTitle)
            providerNameRow(o, index: index, open: true)
        } else if let e = o.error {
            errorText(e)
            if o.applePackMissing {
                Button(L("下载 Apple 语言包…")) {
                    AppleLangPack.presentDownloadPrompt(force: true)
                }
            }
            providerNameRow(o, index: index, open: true)
        } else if let t = o.text {
            resultText(t)
            providerNameRow(o, index: index, open: true, text: t)
        }
    }

    /// 折起来的一家：图标、名字、摘要，点开再看全文。
    private func collapsedProvider(_ o: ProviderOutcome, index: Int) -> some View {
        Button {
            toggleProvider(o.id, open: false)
        } label: {
            HStack(spacing: 6) {
                ProviderIconView(outcomeID: o.id, name: o.name, size: 14)
                Text(o.name)
                    .font(Theme.TypeScale.caption).fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                writeBackShortcutLabel(index: index)
                if o.loading {
                    ProgressView().controlSize(.mini)
                } else if let t = o.text {
                    Text(MarkdownTextUtil.plain(t))
                        .font(Theme.TypeScale.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else if o.error != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(Theme.TypeScale.caption)
                        .foregroundStyle(Theme.danger)
                }
                Spacer(minLength: 4)
                providerChevron(open: false) { toggleProvider(o.id, open: false) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("展开"))
    }

    /// 服务名一行：朗读、复制、写回。悬停这一家时变实。
    private func providerNameRow(_ o: ProviderOutcome, index: Int, open: Bool, text: String? = nil) -> some View {
        HStack(spacing: 4) {
            Button {
                toggleProvider(o.id, open: open)
            } label: {
                HStack(spacing: 6) {
                    ProviderIconView(outcomeID: o.id, name: o.name, size: 13)
                    Text(o.name)
                        .font(Theme.TypeScale.caption).fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    writeBackShortcutLabel(index: index)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            modelMenu(o)
            Spacer(minLength: 4)
            if let text {
                SpeakButton(text: text, language: targetSpeechCode, tag: "popup.\(o.id)")
                favoriteButton(translation: text, providerName: o.name)
                copyButton(id: o.id, text: text)
                writeBackButton(id: o.id, text: text, index: index)
            }
            if model.outcomes.count > 1 {
                providerChevron(open: true) { toggleProvider(o.id, open: true) }
            }
        }
    }

    /// 列表最下一行。免费版写「再加一家需要 Pro」，点了去关于页。
    @ViewBuilder
    private var addProviderRow: some View {
        Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.top, 2)
        if chatAllowed {
            Button {
                addProviderOpen.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(Theme.TypeScale.caption).fontWeight(.semibold)
                    Text(L("再加一家"))
                        .font(Theme.TypeScale.label)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("这次再加一家"))
            .disabled(addableTargets.isEmpty && addableOCR.isEmpty)
            .popover(isPresented: $addProviderOpen, arrowEdge: .bottom) {
                addProviderPopover
            }
        } else {
            Button {
                Pro.shared.showOffer()
            } label: {
                HStack(spacing: 6) {
                    Text(L("再加一家需要 Pro"))
                        .font(Theme.TypeScale.label)
                    ProBadge(help: L("再加一家需要 Pro"))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var addProviderPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            if addableTargets.isEmpty && addableOCR.isEmpty {
                Text(L("没有更多已启用的服务"))
                    .font(Theme.TypeScale.label)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
            ForEach(addableOCR) { provider in
                Button {
                    addOCR(provider)
                    addProviderOpen = false
                } label: {
                    addProviderLine(name: provider.displayName, icon: ProviderIconView(ocr: provider, size: 14))
                }
                .buttonStyle(.plain)
            }
            ForEach(addableTargets) { target in
                Button {
                    AppDelegate.shared?.addSessionTranslate(target.id)
                    addProviderOpen = false
                } label: {
                    addProviderLine(
                        name: target.displayName,
                        icon: ProviderIconView(outcomeID: target.id, name: target.displayName, size: 14)
                    )
                }
                .buttonStyle(.plain)
            }
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            Button {
                addProviderOpen = false
                PreferencesController.shared.show(tab: .providers)
            } label: {
                Text(L("管理服务…"))
                    .font(Theme.TypeScale.label)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: 220)
        .padding(.vertical, 4)
    }

    private func addProviderLine(name: String, icon: ProviderIconView) -> some View {
        HStack(spacing: 8) {
            icon
            Text(name)
                .font(Theme.TypeScale.label)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private var ocrGroupList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.ocrGroups.sorted { lhs, rhs in
                let order = config.orderedOCRProviders().map(\.rawValue)
                let li = order.firstIndex(of: lhs.id) ?? .max
                let ri = order.firstIndex(of: rhs.id) ?? .max
                return li < ri
            }) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Rectangle().fill(Theme.hairline).frame(height: 0.5)
                    Text(group.name)
                        .font(Theme.TypeScale.caption).fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                    Text(group.source)
                        .font(Theme.TypeScale.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                    ForEach(group.outcomes) { outcome in
                        if outcome.loading {
                            loadingRow()
                        } else if let error = outcome.error {
                            errorText(error)
                        } else if let text = outcome.text {
                            resultText(text)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    private func toggleProvider(_ id: String, open: Bool) {
        let update = {
            if open {
                model.collapsedProviderIDs.insert(id)
                model.openedProviderIDs.remove(id)
            } else {
                model.collapsedProviderIDs.remove(id)
                model.openedProviderIDs.insert(id)
            }
        }
        if reduceMotion {
            update()
        } else {
            withAnimation(.snappy(duration: 0.2)) { update() }
        }
        onRelayout()
    }

    private func providerChevron(open: Bool, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            Image(systemName: "chevron.right")
                .font(Theme.TypeScale.micro)
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(open ? 90 : 0))
                .animation(reduceMotion ? nil : .snappy(duration: 0.16), value: open)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(open ? L("收起") : L("展开"))
    }

    @ViewBuilder
    private func resultText(_ t: String) -> some View {
        InlineMarkdownText(text: t, font: Theme.TypeScale.reading)
            .lineSpacing(3)
    }

    private func favoriteButton(translation: String, providerName: String) -> some View {
        let starred = FavoritesStore.contains(source: model.source, translation: translation)
        // Touch bump so view refreshes after toggle.
        let _ = model.favoriteBump
        return IconButton(
            systemImage: starred ? "star.fill" : "star",
            help: starred ? L("取消收藏（可在「历史和收藏 › 收藏」查看）") : L("收藏译文（可在「历史和收藏 › 收藏」查看）"),
            tint: starred ? .yellow : nil,
            size: 11
        ) {
            if starred {
                FavoritesStore.remove(source: model.source, translation: translation)
            } else {
                FavoritesStore.add(
                    source: model.source,
                    translation: translation,
                    direction: model.direction,
                    providerName: providerName,
                    kind: model.sessionKind
                )
            }
            model.favoriteBump &+= 1
        }
    }

    private var targetSpeechCode: String? {
        model.plan(for: model.source).tgt
    }

    private func copyButton(id: String, text: String) -> some View {
        CopyMarkdownMenu(id: id, text: text, copiedID: $model.copiedID)
    }

    @ViewBuilder
    private func writeBackShortcutLabel(index: Int) -> some View {
        if model.writeBackOffered, model.writeBackBlocked == nil, model.writeBackShortcutsVisible, index < 9 {
            Text("⌘\(index + 1)")
                .font(Theme.TypeScale.micro)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func writeBackButton(id: String, text: String, index: Int) -> some View {
        if model.writeBackOffered {
            Button {
                onWriteBack(id, text)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(Theme.TypeScale.caption)
                    Text(L("写回"))
                        .font(Theme.TypeScale.caption)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .frame(height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(HoverPlateButtonStyle())
            .disabled(model.writeBackBlocked != nil)
            .help(model.writeBackBlocked
                ?? (index < 9
                    ? L("写回来源应用里当时的选区") + "（⌘\(index + 1)）"
                    : L("写回来源应用里当时的选区")))
            .accessibilityLabel(L("写回"))
        }
    }

    @ViewBuilder
    private func writeBackNote(for id: String) -> some View {
        if model.writeBackNoteID == id, let note = model.writeBackNote {
            ErrorLine(text: note)
        }
    }
}

/// 识别截图的可操作预览：滚轮/捏合缩放、90° 旋转、拖动平移、一键复位。
private struct OCRShotPanel: View {
    let image: CGImage
    @State private var zoom: CGFloat = 1
    @State private var angle: CGFloat = 0
    @State private var offset: CGSize = .zero

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            OCRShotCanvas(
                image: image,
                zoom: $zoom,
                angle: $angle,
                offset: $offset
            )
            HStack(spacing: 0) {
                IconButton(systemImage: "minus.magnifyingglass", help: L("缩小"), size: 11) {
                    zoom = max(0.5, zoom / 1.25)
                }
                IconButton(systemImage: "plus.magnifyingglass", help: L("放大"), size: 11) {
                    zoom = min(12, zoom * 1.25)
                }
                IconButton(systemImage: "rotate.right", help: L("旋转 90°"), size: 11) {
                    angle = (angle + 90).truncatingRemainder(dividingBy: 360)
                }
                IconButton(
                    systemImage: "arrow.counterclockwise",
                    help: L("复位"),
                    tint: (zoom == 1 && angle == 0 && offset == .zero) ? nil : .accentColor,
                    size: 11
                ) {
                    zoom = 1
                    angle = 0
                    offset = .zero
                }
            }
            .padding(.horizontal, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(.regularMaterial)
                    .overlay(Capsule(style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
            )
            .padding(6)
        }
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(alignment: .topLeading) {
            Text("\(Int((zoom * 100).rounded()))%")
                .font(Theme.TypeScale.micro).monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Capsule(style: .continuous).fill(.regularMaterial))
                .padding(6)
                .opacity(zoom == 1 ? 0 : 1)
        }
    }
}

/// AppKit 画布。SwiftUI 的手势做光标锚定缩放和自由拖动都不如直接吃 `scrollWheel` / `magnify`。
private struct OCRShotCanvas: NSViewRepresentable {
    let image: CGImage
    @Binding var zoom: CGFloat
    @Binding var angle: CGFloat
    @Binding var offset: CGSize

    func makeNSView(context: Context) -> OCRShotCanvasView {
        let v = OCRShotCanvasView()
        v.image = image
        return v
    }

    func updateNSView(_ v: OCRShotCanvasView, context: Context) {
        v.image = image
        v.zoom = zoom
        v.angle = angle
        v.offset = offset
        v.onZoom = { k, at in
            Self.applyZoom(k, at: at, zoom: &zoom, offset: &offset, in: v.bounds.size)
        }
        v.onPan = { delta in
            var o = offset
            o.width += delta.width
            o.height += delta.height
            offset = o
        }
        v.onReset = {
            zoom = 1
            angle = 0
            offset = .zero
        }
        v.needsDisplay = true
    }

    /// 以光标位置为锚点缩放：光标下的图像点待在原地。
    static func applyZoom(_ factor: CGFloat, at point: CGPoint?, zoom: inout CGFloat, offset: inout CGSize, in size: CGSize) {
        let old = zoom
        let new = min(12, max(0.5, old * factor))
        guard new != old else { return }
        let anchor = point ?? CGPoint(x: size.width / 2, y: size.height / 2)
        let cx = anchor.x - size.width / 2
        let cy = anchor.y - size.height / 2
        let k = new / old
        var o = offset
        o.width = cx - (cx - o.width) * k
        o.height = cy - (cy - o.height) * k
        zoom = new
        offset = o
    }
}

final class OCRShotCanvasView: NSView {
    var image: CGImage?
    var zoom: CGFloat = 1
    var angle: CGFloat = 0
    var offset: CGSize = .zero
    var onZoom: ((CGFloat, CGPoint?) -> Void)?
    var onPan: ((CGSize) -> Void)?
    var onReset: (() -> Void)?

    private var dragStart: NSPoint?

    override var isFlipped: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let image else { return }
        ctx.saveGState()
        ctx.translateBy(x: bounds.midX + offset.width, y: bounds.midY + offset.height)
        ctx.rotate(by: angle * .pi / 180)
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        let rad = angle * .pi / 180
        let c = abs(cos(rad)), s = abs(sin(rad))
        // 旋转后的外接框也要放得下，90° 时宽高互换。
        let fit = min(bounds.width / max(iw * c + ih * s, 1), bounds.height / max(iw * s + ih * c, 1))
        let scale = fit * zoom
        let w = iw * scale, h = ih * scale
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        ctx.restoreGState()
    }

    // MARK: Zoom

    override func scrollWheel(with event: NSEvent) {
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 120 : event.scrollingDeltaY / 10
        guard abs(dy) > 0.0001 else { return }
        onZoom?(exp(dy * 0.9), convert(event.locationInWindow, from: nil))
    }

    override func magnify(with event: NSEvent) {
        onZoom?(1 + event.magnification, convert(event.locationInWindow, from: nil))
    }

    // MARK: Pan

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onReset?()
            return
        }
        dragStart = convert(event.locationInWindow, from: nil)
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let now = convert(event.locationInWindow, from: nil)
        onPan?(CGSize(width: now.x - start.x, height: now.y - start.y))
        dragStart = now
    }

    override func mouseUp(with event: NSEvent) {
        if dragStart != nil { NSCursor.pop() }
        dragStart = nil
    }
}

private struct SourceEditor: NSViewRepresentable {
    @Binding var text: String
    var isEnabled: Bool
    var onHeightChange: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.contentView.drawsBackground = false
        UIChrome.configure(scroll)
        scroll.setContentHuggingPriority(.defaultLow, for: .horizontal)
        scroll.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        scroll.setContentHuggingPriority(.required, for: .vertical)

        let textView = NSTextView()
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.focusRingType = .none
        textView.font = Theme.TypeScale.nsBody
        textView.textColor = .secondaryLabelColor
        textView.insertionPointColor = .labelColor
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isEditable = isEnabled
        textView.isSelectable = isEnabled
        textView.string = text
        textView.delegate = context.coordinator
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        textView.isEditable = isEnabled
        textView.isSelectable = isEnabled
        textView.textColor = .secondaryLabelColor
        if !textView.hasMarkedText(), textView.string != text {
            context.coordinator.applying = true
            textView.string = text
            context.coordinator.applying = false
        }
        let width = scroll.contentSize.width > 1 ? scroll.contentSize.width : (scroll.bounds.width > 1 ? scroll.bounds.width : 0)
        guard width > 1 else { return }
        let height = layout(textView, width: width)
        guard abs(height - context.coordinator.reported) > 0.5 else { return }
        context.coordinator.reported = height
        DispatchQueue.main.async { [onHeightChange] in onHeightChange() }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context) -> CGSize? {
        guard let textView = scroll.documentView as? NSTextView else { return nil }
        let width = proposal.width ?? scroll.bounds.width
        let height = width > 1 ? layout(textView, width: width) : context.coordinator.reported
        return CGSize(width: max(width, 1), height: max(height, 1))
    }

    private func layout(_ textView: NSTextView, width: CGFloat) -> CGFloat {
        let contentWidth = max(width, 1)
        textView.textContainer?.containerSize = NSSize(width: contentWidth, height: CGFloat.greatestFiniteMagnitude)
        guard let manager = textView.layoutManager, let container = textView.textContainer else { return 22 }
        manager.ensureLayout(for: container)
        let line = manager.defaultLineHeight(for: textView.font ?? Theme.TypeScale.nsBody)
        let inset = textView.textContainerInset.height * 2
        let full = max(ceil(manager.usedRect(for: container).height), ceil(line)) + inset
        if abs(textView.frame.width - contentWidth) > 0.5 || abs(textView.frame.height - full) > 0.5 {
            textView.setFrameSize(NSSize(width: contentWidth, height: full))
        }
        return min(max(full, ceil(line) + inset), ceil(line) * 8 + inset)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SourceEditor
        var applying = false
        var reported: CGFloat = 0

        init(_ parent: SourceEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard !applying, let textView = notification.object as? NSTextView else { return }
            if parent.text != textView.string { parent.text = textView.string }
            textView.enclosingScrollView?.invalidateIntrinsicContentSize()
        }
    }
}

private struct PopupChatSplit: Layout {
    var chatMin: CGFloat
    /// Height the user dragged the lower pane to. Nil splits by content.
    var chatHeight: CGFloat? = nil
    /// Source well and header stay visible however far the lower pane is dragged.
    private let topMin: CGFloat = 96

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let ideal = subviews.reduce(CGFloat(0)) { partial, view in
            partial + view.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        }
        return CGSize(width: width, height: proposal.height ?? ideal)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count >= 2 else { return }
        let width = bounds.width
        let chatHeight = lowerHeight(available: bounds.height, width: width, subviews: subviews)
        let topHeight = bounds.height - chatHeight
        subviews[0].place(
            at: CGPoint(x: bounds.minX, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: width, height: topHeight)
        )
        subviews[1].place(
            at: CGPoint(x: bounds.minX, y: bounds.minY + topHeight),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: width, height: chatHeight)
        )
    }

    /// Both fit: the translation keeps its height. Otherwise the lower pane gets up to half,
    /// so a long translation no longer squeezes the dictionary or chat down to one strip.
    private func lowerHeight(available: CGFloat, width: CGFloat, subviews: Subviews) -> CGFloat {
        let floor = min(chatMin, available)
        let ceiling = max(floor, available - topMin)
        if let chatHeight { return min(max(chatHeight, floor), ceiling) }
        let topIdeal = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        if available >= topIdeal + chatMin { return available - topIdeal }
        let lowerIdeal = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        return min(max(min(lowerIdeal, available * 0.5), floor), ceiling)
    }
}

/// Drag strip on the top edge of a lower pane. Dragging up gives the pane more room.
private struct PaneResizeHandle: View {
    @Binding var height: CGFloat?
    var current: CGFloat
    @State private var start: CGFloat?
    @State private var hovering = false

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: 8)
            .overlay {
                Capsule()
                    .fill(Color.primary.opacity(hovering || start != nil ? 0.25 : 0))
                    .frame(width: 32, height: 3)
            }
            .contentShape(Rectangle())
            .pointerStyle(.rowResize)
            .onHover { hovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let base = start ?? current
                        if start == nil { start = current }
                        height = max(0, base - value.translation.height)
                    }
                    .onEnded { _ in
                        start = nil
                        // The split clamps the drag. Keep what is on screen, so dragging back has no dead zone.
                        height = current
                    }
            )
            .help(L("拖动调整高度"))
    }
}

final class TranslatePanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53 { onEscape?() } else { super.keyDown(with: e) }
    }
}

private struct PanelEdges: OptionSet {
    let rawValue: Int
    static let top = PanelEdges(rawValue: 1 << 0)
    static let left = PanelEdges(rawValue: 1 << 1)
    static let bottom = PanelEdges(rawValue: 1 << 2)
    static let right = PanelEdges(rawValue: 1 << 3)
}

/// Hit target around a borderless panel. Clicks in the middle pass through to the translation.
private final class PanelEdgeResize: NSView {
    var limits: () -> (min: NSSize, screen: NSRect) = {
        (NSSize(width: 300, height: 150), NSRect(x: 0, y: 0, width: 1200, height: 800))
    }
    var onBegan: () -> Void = {}

    private var drag: (edges: PanelEdges, start: NSRect, mouse: NSPoint, began: Bool)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        edges(at: point) == nil ? nil : self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        let regions: [(NSRect, PanelEdges)] = [
            (NSRect(x: bounds.width - 10, y: bounds.height - 10, width: 10, height: 10), [.top, .right]),
            (NSRect(x: 0, y: bounds.height - 10, width: 10, height: 10), [.top, .left]),
            (NSRect(x: bounds.width - 16, y: 0, width: 16, height: 16), [.bottom, .right]),
            (NSRect(x: 0, y: 0, width: 16, height: 16), [.bottom, .left]),
            (NSRect(x: 10, y: bounds.height - 6, width: max(0, bounds.width - 20), height: 6), [.top]),
            (NSRect(x: 16, y: 0, width: max(0, bounds.width - 32), height: 12), [.bottom]),
            (NSRect(x: 0, y: 16, width: 14, height: max(0, bounds.height - 16 - 36)), [.left]),
            (NSRect(x: 0, y: bounds.height - 36, width: 6, height: 28), [.left]),
            (NSRect(x: bounds.width - 14, y: 16, width: 14, height: max(0, bounds.height - 16 - 36)), [.right]),
            (NSRect(x: bounds.width - 6, y: bounds.height - 36, width: 6, height: 28), [.right]),
        ]
        for (rect, edge) in regions where rect.width > 0 && rect.height > 0 {
            addCursorRect(rect, cursor: cursor(for: edge))
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let edge = edges(at: point), let window else { return }
        drag = (edge, window.frame, NSEvent.mouseLocation, false)
        cursor(for: edge).set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard var drag, let window else { return }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - drag.mouse.x
        let dy = mouse.y - drag.mouse.y
        if !drag.began {
            guard hypot(dx, dy) >= 2 else { return }
            drag.began = true
            self.drag = drag
            onBegan()
        }
        cursor(for: drag.edges).set()
        let limits = limits()
        var frame = resized(drag.start, dx: dx, dy: dy, edges: drag.edges, min: limits.min)
        frame = clamped(frame, to: limits.screen)
        window.setFrame(frame, display: true, animate: false)
        window.contentView?.layoutSubtreeIfNeeded()
    }

    override func mouseUp(with event: NSEvent) {
        drag = nil
        window?.invalidateCursorRects(for: self)
    }

    /// Top band stays thin so it does not cover the pin and language buttons.
    private func edges(at point: NSPoint) -> PanelEdges? {
        let w = bounds.width
        let h = bounds.height
        guard bounds.contains(point) else { return nil }
        if point.x >= w - 10, point.y >= h - 10 { return [.top, .right] }
        if point.x <= 10, point.y >= h - 10 { return [.top, .left] }
        if point.x >= w - 16, point.y <= 16 { return [.bottom, .right] }
        if point.x <= 16, point.y <= 16 { return [.bottom, .left] }
        var hit: PanelEdges = []
        if point.y >= h - 6 { hit.insert(.top) }
        else if point.y <= 12 { hit.insert(.bottom) }
        let side: CGFloat = point.y > h - 36 ? 6 : 14
        if point.x <= side { hit.insert(.left) }
        else if point.x >= w - side { hit.insert(.right) }
        return hit.isEmpty ? nil : hit
    }

    private func cursor(for edges: PanelEdges) -> NSCursor {
        let position: NSCursor.FrameResizePosition
        switch (edges.contains(.top), edges.contains(.bottom), edges.contains(.left), edges.contains(.right)) {
        case (true, _, true, _): position = .topLeft
        case (true, _, _, true): position = .topRight
        case (_, true, true, _): position = .bottomLeft
        case (_, true, _, true): position = .bottomRight
        case (true, _, _, _): position = .top
        case (_, true, _, _): position = .bottom
        case (_, _, true, _): position = .left
        default: position = .right
        }
        return NSCursor.frameResize(position: position, directions: .all)
    }

    private func resized(_ start: NSRect, dx: CGFloat, dy: CGFloat, edges: PanelEdges, min: NSSize) -> NSRect {
        var frame = start
        if edges.contains(.right) { frame.size.width = start.width + dx }
        if edges.contains(.left) {
            frame.size.width = start.width - dx
            frame.origin.x = start.maxX - frame.width
        }
        if edges.contains(.top) { frame.size.height = start.height + dy }
        if edges.contains(.bottom) {
            frame.size.height = start.height - dy
            frame.origin.y = start.maxY - frame.height
        }
        if frame.width < min.width {
            if edges.contains(.left) { frame.origin.x = start.maxX - min.width }
            frame.size.width = min.width
        }
        if frame.width > 560 {
            if edges.contains(.left) { frame.origin.x = start.maxX - 560 }
            frame.size.width = 560
        }
        if frame.height < min.height {
            if edges.contains(.bottom) { frame.origin.y = start.maxY - min.height }
            frame.size.height = min.height
        }
        return frame
    }

    private func clamped(_ frame: NSRect, to limit: NSRect) -> NSRect {
        var frame = frame
        if frame.width > limit.width { frame.size.width = limit.width }
        if frame.height > limit.height { frame.size.height = limit.height }
        if frame.minX < limit.minX { frame.origin.x = limit.minX }
        if frame.maxX > limit.maxX { frame.origin.x = limit.maxX - frame.width }
        if frame.minY < limit.minY { frame.origin.y = limit.minY }
        if frame.maxY > limit.maxY { frame.origin.y = limit.maxY - frame.height }
        return frame
    }
}

@MainActor
final class PopupController {
    private var panel: TranslatePanel?
    private var hosting: NSHostingView<PopupView>?
    let model = PopupModel()
    let chat = ChatSession()
    private var monitors: [Any] = []
    private var anchor = NSPoint.zero
    /// First layout places the panel. Later layouts keep its top edge while the translation grows.
    private var didPlace = false
    /// Set once the user drags an edge. This showing keeps that size; the next popup adapts again.
    /// Opening chat or the dictionary may still grow it, never shrink it.
    private var userSized = false
    private var measurer: NSHostingController<PopupView>?
    private var shownAt = Date()
    /// Last translate kind for history when user hits 重新翻译.
    var lastKind: String = "select"
    /// Live 划词 targets, keyed by tab. Missing means this tab has no 写回.
    private var writeBackSlots: [UUID: WriteBackSlot] = [:]
    /// Place the text came from, keyed by tab, so a later 重新翻译 keeps it.
    private var origins: [UUID: OriginRecord] = [:]

    private struct OriginRecord {
        var appName: String?
        var bundleID: String?
        var filePath: String?
    }

    init() {
        model.pinned = UserDefaults.standard.bool(forKey: "popup.pinned")
    }

    func show(source: String, kind: String = "select", writeBack: WriteBackSlot? = nil, appName: String? = nil, bundleID: String? = nil, filePath: String? = nil) {
        let language = AppConfig.shared.appTargetLanguage(bundleID: bundleID)
        if model.pinned, panel != nil {
            pushNewTab(source: source, kind: kind, pendingFirstTranslate: false, links: [], loading: true, targetLanguage: language)
            rememberWriteBack(writeBack)
            rememberOrigin(appName: appName, bundleID: bundleID, filePath: filePath)
            return
        }
        close()
        model.tabs = []
        model.activeTabID = nil
        lastKind = kind
        applyContent(source: source, kind: kind, pendingFirstTranslate: false, links: [], loading: true, targetLanguage: language)
        presentPanel(focusEditor: false)
        rememberWriteBack(writeBack)
        rememberOrigin(appName: appName, bundleID: bundleID, filePath: filePath)
        refreshDictionary(for: source)
    }

    func originForActiveTab() -> (appName: String?, bundleID: String?, filePath: String?) {
        guard let id = model.activeTabID, let origin = origins[id] else { return (nil, nil, nil) }
        return (origin.appName, origin.bundleID, origin.filePath)
    }

    /// After OCR: show recognized text for editing; translate only when user clicks 翻译.
    func showOCRDraft(source: String, links: [DetectedLink] = [], shot: CGImage? = nil) {
        let language = AppConfig.shared.appTargetLanguage(bundleID: nil)
        if model.pinned, panel != nil {
            pushNewTab(source: source, kind: "ocr", pendingFirstTranslate: true, links: links, loading: false, targetLanguage: language, shot: shot)
            DispatchQueue.main.async { [weak self] in self?.focusSourceEditor() }
            return
        }
        close()
        model.tabs = []
        model.activeTabID = nil
        lastKind = "ocr"
        applyContent(source: source, kind: "ocr", pendingFirstTranslate: true, links: links, loading: false, targetLanguage: language, shot: shot)
        presentPanel(focusEditor: true)
    }

    private var dictTask: Task<Void, Never>?

    /// Dictionary for source and/or translation. Prefers a Latin short lemma (Free Dictionary),
    /// otherwise the first lookup-candidate among source then translation.
    func refreshDictionary(for text: String, translation: String? = nil) {
        let src = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let tr = (translation ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let q = Self.pickDictionaryQuery(source: src, translation: tr)
        let manual = !model.dictQuery.isEmpty && model.dictQuery != model.dictAutoQuery
        guard let q else {
            if !manual {
                model.dictEntry = nil
                model.dictLoading = false
                model.dictError = nil
                model.dictQuery = ""
                model.dictAutoQuery = ""
                relayout()
            }
            return
        }
        if manual { return }
        let userHidThis = !model.dictExpanded && model.dictQuery == q && model.dictAutoQuery == q
        model.dictQuery = q
        model.dictAutoQuery = q
        if !userHidThis, AppConfig.shared.dictAutoOpen || model.dictExpanded {
            model.dictExpanded = true
        }
        dictTask?.cancel()
        model.dictLoading = true
        model.dictError = nil
        model.dictEntry = nil
        let reading = dictionaryReading(for: q, source: src)
        let picked = dictionarySource(for: q, source: src)
        dictTask = Task { @MainActor in
            do {
                let entry = try await Background.run {
                    try await DictionaryLookup.lookup(q, explainIn: reading, source: picked)
                }
                guard !Task.isCancelled else { return }
                model.dictEntry = entry
                model.dictLoading = false
                relayout()
            } catch {
                guard !Task.isCancelled else { return }
                if error is MaskDeclined {
                    model.dictLoading = false
                    relayout()
                    return
                }
                // If primary query failed and the other side is a candidate, retry once.
                let alt: String? = {
                    if q == src, DictionaryLookup.isLookupCandidate(tr), tr != src { return tr }
                    if q == tr, DictionaryLookup.isLookupCandidate(src), src != tr { return src }
                    return nil
                }()
                if let alt {
                    let altReading = dictionaryReading(for: alt, source: src)
                    let altPicked = dictionarySource(for: alt, source: src)
                    do {
                        let entry = try await Background.run {
                            try await DictionaryLookup.lookup(alt, explainIn: altReading, source: altPicked)
                        }
                        guard !Task.isCancelled else { return }
                        model.dictEntry = entry
                        model.dictQuery = alt
                        model.dictAutoQuery = alt
                        model.dictLoading = false
                        model.dictError = nil
                        relayout()
                        return
                    } catch {
                        if error is MaskDeclined {
                            model.dictLoading = false
                            relayout()
                            return
                        }
                        // fall through
                    }
                }
                model.dictLoading = false
                model.dictError = error.localizedDescription
                relayout()
            }
        }
        if !userHidThis { relayout() }
    }

    /// Definitions of the source read in the language this page translates into. Anything else,
    /// such as the translation itself, reads in the native language.
    private func dictionaryReading(for query: String, source: String) -> TargetLanguage? {
        guard query == source.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let tgt = model.plan(for: source).tgt
        return TargetLanguage.specific.first { $0.appleCode == tgt }
    }

    /// The picked source language applies when the query is the source itself.
    private func dictionarySource(for query: String, source: String) -> TargetLanguage? {
        guard model.sourceLanguage != .auto,
              query == source.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return model.sourceLanguage
    }

    private static func pickDictionaryQuery(source: String, translation: String) -> String? {
        let srcOK = DictionaryLookup.isLookupCandidate(source)
        let trOK = DictionaryLookup.isLookupCandidate(translation)
        if trOK, DictionaryLookup.looksLatinLemma(translation) { return translation }
        if srcOK, DictionaryLookup.looksLatinLemma(source) { return source }
        if srcOK { return source }
        if trOK { return translation }
        return nil
    }

    func lookupDictionaryQuery() {
        let q = model.dictQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        model.dictQuery = q
        model.dictExpanded = true
        dictTask?.cancel()
        model.dictLoading = true
        model.dictError = nil
        model.dictEntry = nil
        let reading = dictionaryReading(for: q, source: model.source)
        let picked = dictionarySource(for: q, source: model.source)
        dictTask = Task { @MainActor in
            do {
                let entry = try await Background.run {
                    try await DictionaryLookup.lookup(q, explainIn: reading, source: picked)
                }
                guard !Task.isCancelled else { return }
                model.dictEntry = entry
                model.dictLoading = false
                relayout()
            } catch {
                guard !Task.isCancelled else { return }
                model.dictLoading = false
                if error is MaskDeclined {
                    relayout()
                    return
                }
                model.dictError = error.localizedDescription
                relayout()
            }
        }
        relayout()
    }


    private func tabTitle(for source: String) -> String {
        let s = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return L("新标签") }
        let one = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? s
        return one.truncated(to: 16)
    }

    private func snapshotCurrent(id: UUID? = nil, kind: String? = nil) -> PopupTabSnapshot {
        PopupTabSnapshot(
            id: id ?? model.activeTabID ?? UUID(),
            title: tabTitle(for: model.source),
            source: model.source,
            direction: model.direction,
            outcomes: model.outcomes,
            loading: model.loading,
            globalError: model.globalError,
            pendingFirstTranslate: model.pendingFirstTranslate,
            sourceCaption: model.sourceCaption,
            kind: kind ?? lastKind,
            ocrShot: model.ocrShot,
            showsOCRShot: model.showsOCRShot,
            dictEntry: model.dictEntry,
            dictLoading: model.dictLoading,
            dictError: model.dictError,
            dictQuery: model.dictQuery,
            dictAutoQuery: model.dictAutoQuery,
            dictExpanded: model.dictExpanded,
            collapsedProviderIDs: model.collapsedProviderIDs,
            openedProviderIDs: model.openedProviderIDs,
            detectedLinks: model.detectedLinks,
            chatExpanded: model.chatExpanded,
            targetLanguage: model.targetLanguage,
            sourceLanguage: model.sourceLanguage,
            translatedText: model.translatedText,
            translatedTarget: model.translatedTarget,
            plugin: model.sessionPlugin
        )
    }

    private func loadSnapshot(_ tab: PopupTabSnapshot) {
        model.activeTabID = tab.id
        model.source = tab.source
        model.direction = tab.direction
        model.outcomes = tab.outcomes
        model.loading = tab.loading
        model.globalError = tab.globalError
        model.pendingFirstTranslate = tab.pendingFirstTranslate
        model.sourceCaption = tab.sourceCaption
        model.ocrShot = tab.ocrShot
        model.showsOCRShot = tab.showsOCRShot
        model.dictEntry = tab.dictEntry
        model.dictLoading = tab.dictLoading
        model.dictError = tab.dictError
        model.dictQuery = tab.dictQuery
        model.dictAutoQuery = tab.dictAutoQuery
        model.dictExpanded = tab.dictExpanded
        model.collapsedProviderIDs = tab.collapsedProviderIDs
        model.openedProviderIDs = tab.openedProviderIDs
        model.detectedLinks = tab.detectedLinks
        model.targetLanguage = tab.targetLanguage
        model.sourceLanguage = tab.sourceLanguage
        model.translatedText = tab.translatedText
        model.translatedTarget = tab.translatedTarget
        model.sessionPlugin = tab.plugin
        model.chatExpanded = false
        model.copiedID = nil
        model.writeBackNote = nil
        model.writeBackNoteID = nil
        lastKind = tab.kind
        chat.reset(source: tab.source, translations: model.chatTranslations)
        publishWriteBackOffer()
        relayout()
    }

    private func persistActiveIntoTabs() {
        guard let aid = model.activeTabID,
              let idx = model.tabs.firstIndex(where: { $0.id == aid }) else { return }
        model.tabs[idx] = snapshotCurrent(id: aid)
    }

    private func applyContent(source: String, kind: String, pendingFirstTranslate: Bool, links: [DetectedLink], loading: Bool, targetLanguage: TargetLanguage, shot: CGImage? = nil) {
        lastKind = kind
        model.sessionKind = kind
        model.source = source
        model.direction = ""
        model.outcomes = []
        model.loading = loading
        model.globalError = nil
        model.copiedID = nil
        model.chatExpanded = false
        model.pendingFirstTranslate = pendingFirstTranslate
        model.sourceCaption = (kind == "ocr") ? L("识别文字（可编辑）") : L("原文（可编辑）")
        model.ocrShot = shot
        model.showsOCRShot = false
        model.collapsedProviderIDs = []
        model.openedProviderIDs = []
        model.dictEntry = nil
        model.dictLoading = false
        model.dictError = nil
        model.dictQuery = ""
        model.dictAutoQuery = ""
        model.dictExpanded = false
        model.detectedLinks = links
        model.targetLanguage = targetLanguage
        model.sourceLanguage = .auto
        model.translatedText = ""
        model.translatedTarget = nil
        model.writeBackNote = nil
        model.writeBackNoteID = nil
        model.sessionPlugin = nil
        chat.reset(source: source, translations: [])
    }

    private func pushNewTab(source: String, kind: String, pendingFirstTranslate: Bool, links: [DetectedLink], loading: Bool, targetLanguage: TargetLanguage, shot: CGImage? = nil) {
        // Seed first tab from current content if tabs empty
        if model.tabs.isEmpty {
            let firstID = UUID()
            model.activeTabID = firstID
            model.tabs = [snapshotCurrent(id: firstID)]
        } else {
            persistActiveIntoTabs()
        }
        let newID = UUID()
        applyContent(source: source, kind: kind, pendingFirstTranslate: pendingFirstTranslate, links: links, loading: loading, targetLanguage: targetLanguage, shot: shot)
        model.activeTabID = newID
        let snap = snapshotCurrent(id: newID, kind: kind)
        model.tabs.append(snap)
        beginPlacement(at: NSEvent.mouseLocation)
        shownAt = Date()
        relayout()
        panel?.orderFrontRegardless()
        panel?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
        if !pendingFirstTranslate {
            refreshDictionary(for: source)
        }
        publishWriteBackOffer()
        noteCommandHold()
    }

    private func presentPanel(focusEditor: Bool) {
        let h = NSHostingView(rootView: makeView(fillsWindow: true))
        // relayout sets the frame. Empty sizing options keep AppKit from resizing the window after the translation is framed.
        h.sizingOptions = []
        h.safeAreaRegions = []
        h.autoresizingMask = [.width, .height]
        let edges = PanelEdgeResize(frame: NSRect(x: 0, y: 0, width: 380, height: 80))
        edges.autoresizingMask = [.width, .height]
        edges.limits = { [weak self] in
            self?.resizeLimits() ?? (NSSize(width: 300, height: 150), NSRect(x: 0, y: 0, width: 1200, height: 800))
        }
        edges.onBegan = { [weak self] in
            self?.userSized = true
        }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 80))
        container.autoresizesSubviews = true
        let panel = TranslatePanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 80),
            styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = true
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = container
        h.frame = container.bounds
        edges.frame = container.bounds
        container.addSubview(h)
        container.addSubview(edges)
        panel.onEscape = { [weak self] in
            guard let self else { return }
            if self.model.chatExpanded {
                self.model.chatExpanded = false
                self.relayout()
            } else {
                self.dismiss()
            }
        }
        self.panel = panel
        self.hosting = h
        // Seed single tab for pin→new-tab continuity
        let tid = UUID()
        model.activeTabID = tid
        model.tabs = [snapshotCurrent(id: tid)]
        beginPlacement(at: NSEvent.mouseLocation)
        shownAt = Date()
        relayout()
        panel.orderFrontRegardless()
        panel.makeKey()
        NSApp.activate(ignoringOtherApps: true)
        installMonitors()
        noteCommandHold()
        if focusEditor {
            DispatchQueue.main.async { [weak self] in self?.focusSourceEditor() }
        }
        publishWriteBackOffer()
    }

    func selectTab(id: UUID) {
        guard id != model.activeTabID else { return }
        persistActiveIntoTabs()
        guard let tab = model.tabs.first(where: { $0.id == id }) else { return }
        loadSnapshot(tab)
    }

    func closeTab(id: UUID) {
        writeBackSlots.removeValue(forKey: id)
        origins.removeValue(forKey: id)
        guard let idx = model.tabs.firstIndex(where: { $0.id == id }) else { return }
        if model.tabs.count <= 1 {
            dismiss()
            return
        }
        let wasActive = model.activeTabID == id
        model.tabs.remove(at: idx)
        if wasActive {
            let next = model.tabs[min(idx, model.tabs.count - 1)]
            loadSnapshot(next)
        } else {
            relayout()
        }
    }

    private func makeView(fillsWindow: Bool) -> PopupView {
        PopupView(
            model: model,
            chat: chat,
            onCopy: { text in
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
            },
            onToggleChat: { [weak self] in
                self?.toggleChat()
            },
            onRelayout: { [weak self] in
                self?.relayout()
            },
            onLookupDictionary: { [weak self] in
                self?.lookupDictionaryQuery()
            },
            onRetranslate: { [weak self] in
                self?.retranslate()
            },
            onTogglePin: { [weak self] in
                self?.togglePin()
            },
            onSelectTab: { [weak self] id in
                self?.selectTab(id: id)
            },
            onCloseTab: { [weak self] id in
                self?.closeTab(id: id)
            },
            onWriteBack: { [weak self] id, text in
                self?.performWriteBack(noteID: id, markdown: text)
            },
            fillsWindow: fillsWindow
        )
    }

    func togglePin() {
        model.pinned.toggle()
        UserDefaults.standard.set(model.pinned, forKey: "popup.pinned")
    }

    func retranslate() {
        let text = model.source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !model.loading else { return }
        model.source = text
        model.pendingFirstTranslate = false
        refreshDictionary(for: text)
        panel?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
        AppDelegate.shared?.retranslateFromPopup(text: text, kind: lastKind, plugin: model.sessionPlugin)
    }

    func toggleChat() {
        if model.chatExpanded {
            model.chatExpanded = false
        } else {
            guard model.canChat else { return }
            guard Pro.unlocked else {
                Pro.shared.showOffer()
                return
            }
            chat.configure(source: model.source, translations: model.chatTranslations)
            model.chatExpanded = true
            panel?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
        relayout()
    }

    func showMulti(_ r: MultiResult, tabID: UUID? = nil) {
        if let tabID, tabID != model.activeTabID {
            guard let idx = model.tabs.firstIndex(where: { $0.id == tabID }) else { return }
            model.tabs[idx].loading = false
            model.tabs[idx].pendingFirstTranslate = false
            model.tabs[idx].direction = r.direction
            model.tabs[idx].outcomes = keepingAdded(r.outcomes, over: model.tabs[idx].outcomes)
            return
        }
        model.loading = false
        model.pendingFirstTranslate = false
        model.direction = r.direction
        model.outcomes = keepingAdded(r.outcomes, over: model.outcomes)
        let tr = model.bestTranslation
        chat.configure(source: model.source, translations: model.chatTranslations)
        refreshDictionary(for: model.source, translation: tr)
        persistActiveIntoTabs()
        relayout()
    }

    func updateOutcomes(_ outcomes: [ProviderOutcome], direction: String, tabID: UUID? = nil, refresh: Bool = true) {
        let still = outcomes.contains(where: \.loading)
        if let tabID, tabID != model.activeTabID {
            guard let idx = model.tabs.firstIndex(where: { $0.id == tabID }) else { return }
            model.tabs[idx].pendingFirstTranslate = false
            model.tabs[idx].loading = still
            model.tabs[idx].direction = direction
            model.tabs[idx].outcomes = keepingAdded(outcomes, over: model.tabs[idx].outcomes)
            return
        }
        model.pendingFirstTranslate = false
        model.loading = still
        model.direction = direction
        model.outcomes = keepingAdded(outcomes, over: model.outcomes)
        if refresh, !still {
            refreshDictionary(for: model.source, translation: model.bestTranslation)
        }
        persistActiveIntoTabs()
        relayout()
    }

    /// 一次插件运行在出结果前被取消、被换掉时，把这一页从转圈里放下来。
    /// 这一页已经不在了就什么都不做。
    func settlePluginLoading(tabID: UUID?) {
        let outcome = ProviderOutcome(id: "plugin:interrupted", name: "", text: nil, error: nil, loading: false)
        _ = outcome
        if let tabID, tabID != model.activeTabID {
            guard let idx = model.tabs.firstIndex(where: { $0.id == tabID }) else { return }
            guard model.tabs[idx].loading else { return }
            model.tabs[idx].loading = false
            if model.tabs[idx].outcomes.isEmpty {
                model.tabs[idx].outcomes = [ProviderOutcome(
                    id: "plugin:interrupted", name: L("插件"), text: nil,
                    error: L("这一次没跑完"), loading: false
                )]
            }
            return
        }
        guard model.loading else { return }
        model.loading = false
        if model.outcomes.isEmpty {
            model.outcomes = [ProviderOutcome(
                id: "plugin:interrupted", name: L("插件"), text: nil,
                error: L("这一次没跑完"), loading: false
            )]
        }
        persistActiveIntoTabs()
        relayout()
    }

    /// A run that started before a service was added does not list it. Keep that card instead of dropping it.
    private func keepingAdded(_ incoming: [ProviderOutcome], over existing: [ProviderOutcome]) -> [ProviderOutcome] {
        let ids = Set(incoming.map(\.id))
        let added = existing.filter { !ids.contains($0.id) && model.sessionExtraIDs.contains($0.id) }
        return incoming + added
    }

    /// Puts one service's card on a page, replacing its earlier card or adding it last.
    func putOutcome(_ outcome: ProviderOutcome, tabID: UUID?) {
        func put(_ list: inout [ProviderOutcome]) {
            if let i = list.firstIndex(where: { $0.id == outcome.id }) {
                list[i] = outcome
            } else {
                list.append(outcome)
            }
        }
        if let tabID, tabID != model.activeTabID {
            guard let idx = model.tabs.firstIndex(where: { $0.id == tabID }) else { return }
            put(&model.tabs[idx].outcomes)
            return
        }
        put(&model.outcomes)
        if !outcome.loading, outcome.text != nil {
            chat.configure(source: model.source, translations: model.chatTranslations)
        }
        persistActiveIntoTabs()
        relayout()
    }

    /// Result for a service added this time. Dropped when the page was translated again since, or the card is gone.
    func finishAdded(_ outcome: ProviderOutcome, tabID: UUID?, text: String, target: TargetLanguage) {
        let page: (text: String, target: TargetLanguage?, outcomes: [ProviderOutcome])?
        if let tabID, tabID != model.activeTabID {
            page = model.tabs.first(where: { $0.id == tabID }).map { ($0.translatedText, $0.translatedTarget, $0.outcomes) }
        } else {
            page = (model.translatedText, model.translatedTarget, model.outcomes)
        }
        guard let page, page.text == text, page.target == target,
              page.outcomes.contains(where: { $0.id == outcome.id && $0.loading }) else { return }
        putOutcome(outcome, tabID: tabID)
    }

    func showError(_ msg: String) {
        model.loading = false
        model.pendingFirstTranslate = false
        model.globalError = msg
        model.chatExpanded = false
        relayout()
    }

    /// A new selection places the panel again. Later height changes keep the top edge already on screen.
    private func beginPlacement(at point: NSPoint) {
        anchor = point
        didPlace = false
        userSized = false
    }

    private func resizeLimits() -> (min: NSSize, screen: NSRect) {
        let minH: CGFloat = model.chatExpanded ? 240 : 150
        let screen = (panel?.screen ?? NSScreen.main)?.visibleFrame.insetBy(dx: 8, dy: 8)
            ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        return (NSSize(width: 360, height: minH), screen)
    }

    private func relayout() {
        guard let p = panel, hosting != nil else { return }
        if userSized {
            var frame = p.frame
            if model.chatExpanded || model.dictExpanded {
                let fitted = measuredSize()
                if fitted.height > frame.height + 0.5 {
                    let top = frame.maxY
                    frame.size.height = fitted.height
                    frame.origin.y = top - frame.height
                }
            }
            clampIntoScreen(&frame)
            guard !Self.sameFrame(p.frame, frame) else { return }
            p.setFrame(frame, display: true, animate: false)
            return
        }
        let size = measuredSize()
        let frame: NSRect
        if didPlace {
            frame = frameKeepingTop(size, of: p)
        } else {
            didPlace = true
            frame = initialFrame(size)
        }
        guard !Self.sameFrame(p.frame, frame) else { return }
        p.setFrame(frame, display: true, animate: false)
    }

    /// Room for a long translation, with a strip of the desktop left visible.
    private func heightCeiling() -> CGFloat {
        let visible = (didPlace ? panel?.screen?.visibleFrame : nil) ?? screen(for: anchor)?.visibleFrame
        let screenH = visible?.height ?? 900
        let leftover = max(160, screenH * 0.28)
        return max(240, floor(screenH - leftover))
    }

    private func measuredSize() -> NSSize {
        let width: CGFloat = 360
        let maxH = heightCeiling()
        let minH: CGFloat = model.chatExpanded ? 420 : 120
        let view = makeView(fillsWindow: false)
        let probe: NSHostingController<PopupView>
        if let existing = measurer {
            probe = existing
        } else {
            let created = NSHostingController(rootView: view)
            created.sizingOptions = []
            created.safeAreaRegions = []
            measurer = created
            probe = created
        }
        probe.rootView = view
        let proposed = NSSize(width: width, height: 4000)
        var fitted = probe.sizeThatFits(in: proposed)
        let settled = probe.sizeThatFits(in: NSSize(width: width, height: max(fitted.height, minH)))
        if settled.height > fitted.height + 0.5 { fitted = settled }
        let height = min(max(ceil(fitted.height), min(minH, maxH)), maxH)
        return NSSize(width: width, height: height)
    }

    /// Panel sits above the cursor. If that would leave the screen, it sits below instead.
    private func initialFrame(_ size: NSSize) -> NSRect {
        var origin = NSPoint(x: anchor.x - 16, y: anchor.y - 16 - size.height)
        if let vf = screen(for: origin)?.visibleFrame {
            if origin.x + size.width > vf.maxX - 8 { origin.x = vf.maxX - 8 - size.width }
            if origin.x < vf.minX + 8 { origin.x = vf.minX + 8 }
            if origin.y < vf.minY + 8 { origin.y = anchor.y + 24 }
            if origin.y + size.height > vf.maxY - 8 { origin.y = vf.maxY - 8 - size.height }
        }
        var frame = NSRect(origin: origin, size: size)
        clampIntoScreen(&frame)
        return frame
    }

    private func frameKeepingTop(_ size: NSSize, of panel: NSWindow) -> NSRect {
        var frame = panel.frame
        let top = frame.maxY
        let width = min(560, max(360, frame.width))
        frame.size = NSSize(width: width, height: size.height)
        frame.origin.y = top - size.height
        clampIntoScreen(&frame)
        return frame
    }

    private func clampIntoScreen(_ frame: inout NSRect) {
        guard let vf = screen(for: frame.origin)?.visibleFrame else { return }
        let limit = vf.insetBy(dx: 8, dy: 8)
        if frame.height > limit.height {
            let top = frame.maxY
            frame.size.height = limit.height
            frame.origin.y = top - frame.height
        }
        if frame.minX < limit.minX { frame.origin.x = limit.minX }
        if frame.maxX > limit.maxX { frame.origin.x = limit.maxX - frame.width }
        if frame.minY < limit.minY { frame.origin.y = limit.minY }
        if frame.maxY > limit.maxY { frame.origin.y = limit.maxY - frame.height }
    }

    private func screen(for point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? panel?.screen ?? NSScreen.main
    }

    private static func sameFrame(_ a: NSRect, _ b: NSRect) -> Bool {
        abs(a.minX - b.minX) < 0.5 && abs(a.minY - b.minY) < 0.5
            && abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5
    }

    private func installMonitors() {
        if appQuitObserver == nil {
            appQuitObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.publishWriteBackOffer() }
            }
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated {
                // Keep OCR draft / editable source / pinned open; Esc still closes.
                guard let self,
                      !self.writeBackInFlight,
                      !self.model.pinned,
                      !self.model.chatExpanded,
                      !self.model.pendingFirstTranslate else { return }
                self.dismiss()
            }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged], handler: { [weak self] e in
            MainActor.assumeIsolated { self?.noteCommandHold(e.modifierFlags) }
            return e
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown], handler: { [weak self] e in
            if e.keyCode == 53 {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.model.chatExpanded {
                        self.model.chatExpanded = false
                        self.relayout()
                    } else {
                        self.dismiss()
                    }
                }
            }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { [weak self] e in
            if e.keyCode == 53 {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.model.chatExpanded {
                        self.model.chatExpanded = false
                        self.relayout()
                    } else {
                        self.dismiss()
                    }
                }
                return nil
            }
            if !e.isARepeat, let index = Self.providerWriteBackIndex(e) {
                var handled = false
                MainActor.assumeIsolated {
                    handled = self?.writeBackProvider(at: index) ?? false
                }
                if handled { return nil }
            }
            return e
        }) { monitors.append(m) }
    }

    /// ⌘1…⌘9, top to bottom as the providers are listed. Keypad digits count too.
    private static func providerWriteBackIndex(_ event: NSEvent) -> Int? {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods == .command else { return nil }
        let ansi: [UInt16: Int] = [
            0x12: 0, 0x13: 1, 0x14: 2, 0x15: 3, 0x17: 4,
            0x16: 5, 0x1A: 6, 0x1C: 7, 0x19: 8,
        ]
        let pad: [UInt16: Int] = [
            0x53: 0, 0x54: 1, 0x55: 2, 0x56: 3, 0x57: 4,
            0x58: 5, 0x59: 6, 0x5B: 7, 0x5C: 8,
        ]
        return ansi[event.keyCode] ?? pad[event.keyCode]
    }

    private var shortcutReveal: Task<Void, Never>?

    /// Show ⌘1…⌘9 only after Command has been held for one second. Releasing it hides them.
    private func noteCommandHold(_ flags: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
        let held = flags.intersection(.deviceIndependentFlagsMask).contains(.command)
        if held {
            guard shortcutReveal == nil, !model.writeBackShortcutsVisible else { return }
            shortcutReveal = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, self.panel != nil else { return }
                self.shortcutReveal = nil
                guard self.model.writeBackOffered else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    self.model.writeBackShortcutsVisible = true
                }
            }
        } else {
            shortcutReveal?.cancel()
            shortcutReveal = nil
            if model.writeBackShortcutsVisible {
                withAnimation(.easeOut(duration: 0.12)) {
                    model.writeBackShortcutsVisible = false
                }
            }
        }
    }

    /// Starts 写回 for the provider at that list index. False when there is nothing to write.
    private func writeBackProvider(at index: Int) -> Bool {
        guard model.writeBackOffered, model.writeBackBlocked == nil, model.outcomes.indices.contains(index),
              let text = model.outcomes[index].text else { return false }
        performWriteBack(noteID: model.outcomes[index].id, markdown: text)
        return true
    }


    /// Focus the source TextEditor (NSTextView) so OCR text can be painted/edited.
    private func focusSourceEditor() {
        guard let p = panel, let h = hosting else { return }
        p.makeKey()
        NSApp.activate(ignoringOtherApps: true)
        if let tv = firstTextView(in: h) {
            p.makeFirstResponder(tv)
            // Place caret at end for quick paint/edit.
            let end = tv.string.endIndex
            let loc = tv.string.utf16.distance(from: tv.string.startIndex, to: end)
            tv.setSelectedRange(NSRange(location: loc, length: 0))
        }
    }

    private func firstTextView(in view: NSView) -> NSTextView? {
        if let tv = view as? NSTextView { return tv }
        for sub in view.subviews {
            if let found = firstTextView(in: sub) { return found }
        }
        return nil
    }

    /// The user closed the popup. Drop the translation still running for it, so it can't land in the next one.
    func dismiss() {
        AppDelegate.shared?.panelTask?.cancel()
        close()
    }

    func close() {
        chat.cancel()
        dictTask?.cancel()
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        if let appQuitObserver { NSWorkspace.shared.notificationCenter.removeObserver(appQuitObserver) }
        appQuitObserver = nil
        didPlace = false
        userSized = false
        measurer = nil
        panel?.orderOut(nil)
        panel = nil
        hosting = nil
        model.chatExpanded = false
        model.tabs = []
        model.activeTabID = nil
        model.detectedLinks = []
        writeBackSlots.removeAll()
        shortcutReveal?.cancel()
        shortcutReveal = nil
        model.writeBackOffered = false
        model.writeBackBlocked = nil
        model.writeBackShortcutsVisible = false
        model.writeBackNote = nil
        model.writeBackNoteID = nil
        origins.removeAll()
    }

    private func rememberOrigin(appName: String?, bundleID: String?, filePath: String?) {
        guard let id = model.activeTabID else { return }
        let app = appName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let bundle = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let path = filePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if app.isEmpty && bundle.isEmpty && path.isEmpty {
            origins.removeValue(forKey: id)
        } else {
            origins[id] = OriginRecord(
                appName: app.isEmpty ? nil : app,
                bundleID: bundle.isEmpty ? nil : bundle,
                filePath: path.isEmpty ? nil : path
            )
        }
    }

    private func rememberWriteBack(_ slot: WriteBackSlot?) {
        guard let id = model.activeTabID else { return }
        if let slot {
            writeBackSlots[id] = slot
        } else {
            writeBackSlots.removeValue(forKey: id)
        }
        publishWriteBackOffer()
    }

    private func publishWriteBackOffer() {
        let slot = model.activeTabID.flatMap { writeBackSlots[$0] }
        let offered = slot != nil
        let blocked = slot.flatMap(writeBackBlockReason)
        if model.writeBackOffered != offered { model.writeBackOffered = offered }
        if model.writeBackBlocked != blocked { model.writeBackBlocked = blocked }
    }

    /// Why this slot cannot be written, checked without touching the source app.
    private func writeBackBlockReason(_ slot: WriteBackSlot) -> String? {
        if !slot.writable { return L("划词所在的地方不能改，不能写回") }
        if let app = slot.sourceApp {
            if app.isTerminated { return L("来源应用已经退出，不能写回") }
        } else if slot.element == nil {
            return L("找不到来源应用，不能写回")
        }
        return nil
    }

    private var writeBackInFlight = false
    private var appQuitObserver: NSObjectProtocol?

    private func revealPanel() {
        guard let panel else { return }
        panel.orderFrontRegardless()
        panel.makeKey()
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            guard panel === self.panel else { return }
            panel.orderFrontRegardless()
            panel.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func performWriteBack(noteID: String, markdown: String) {
        guard !writeBackInFlight else { return }
        guard let tabID = model.activeTabID, let slot = writeBackSlots[tabID] else { return }
        writeBackInFlight = true
        Task { @MainActor in
            defer { self.writeBackInFlight = false }
            if let refusal = await SelectionGrabber.writeBack(slot: slot, markdown: markdown) {
                if refusal == .rejected, var dead = self.writeBackSlots[tabID] {
                    dead.writable = false
                    self.writeBackSlots[tabID] = dead
                    self.publishWriteBackOffer()
                }
                self.model.writeBackNoteID = noteID
                self.model.writeBackNote = refusal.message
                self.relayout()
                self.revealPanel()
                return
            }
            let app = slot.sourceApp
            self.chat.reset(source: "", translations: [])
            self.closeTab(id: tabID)
            guard let app, !app.isTerminated else { return }
            app.activate(from: .current, options: [.activateAllWindows])
        }
    }
}


/// 底部常驻的「继续问 AI…」。开关决定这一次带原文还是带译文，⌘↩ 发送。
private struct PopupFollowUpBar: View {
    @ObservedObject var session: ChatSession
    var canAsk: Bool
    var onSend: () -> Void

    private var canSend: Bool {
        canAsk
            && !session.isSending
            && !session.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !session.enabledProfiles.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                contextToggle(on: session.asksSource, title: L("带原文")) {
                    session.toggleAskGroup(source: true)
                }
                contextToggle(on: session.asksTranslations, title: L("带译文")) {
                    session.toggleAskGroup(source: false)
                }
                Spacer(minLength: 0)
            }
            HStack(alignment: .center, spacing: 6) {
                ChatComposer(
                    text: $session.input,
                    placeholder: L("继续问 AI…"),
                    isEnabled: canAsk && !session.isSending && !session.enabledProfiles.isEmpty,
                    onSubmit: { if canSend { onSend() } }
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                if session.isSending {
                    Button {
                        session.cancel()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(Theme.TypeScale.title)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(L("停止生成"))
                } else {
                    Button(action: { if canSend { onSend() } }) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(Theme.TypeScale.title)
                            .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .help(L("⌘↩ 发送"))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private func contextToggle(on: Bool, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
        }
        .buttonStyle(ChipButtonStyle(selected: on))
        .disabled(session.isSending || session.contextItems.isEmpty)
        .help(on
              ? String(format: L("提问时带上%@。再点一下不带"), title)
              : String(format: L("提问时也带上%@"), title))
    }
}

/// 一家译文。操作行常驻、次要色，鼠标停在这一家上时变实。
private struct ProviderHoverRow<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @State private var hovering = false

    var body: some View {
        content()
            .opacity(hovering ? 1 : 0.72)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
    }
}

/// Transparent AppKit view that starts a window drag on mouseDown (for borderless panels).
struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowDragNSView()
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

final class WindowDragNSView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Accept hits so we receive mouseDown for dragging.
        bounds.contains(point) ? self : nil
    }
}
