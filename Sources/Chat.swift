import Combine
import AppKit
import SwiftUI

// MARK: - Models

struct ChatMessage: Identifiable, Equatable, Sendable {
    let id: String
    let role: Role
    var content: String
    var isStreaming: Bool

    enum Role: String { case user, assistant, system }

    init(id: String = UUID().uuidString, role: Role, content: String, isStreaming: Bool = false) {
        self.id = id
        self.role = role
        self.content = content
        self.isStreaming = isStreaming
    }
}

/// 一段可以拿来提问的文字：原文，或某一家的译文。
struct ChatContextItem: Identifiable, Equatable, Sendable {
    static let sourceID = "source"

    let id: String
    /// 界面上的名字。
    let name: String
    let text: String

    var isSource: Bool { id == Self.sourceID }

    /// 有译文的那几家，按显示顺序。
    static func translations(_ outcomes: [ProviderOutcome]) -> [ChatContextItem] {
        outcomes.compactMap { o in
            guard let t = o.text, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return ChatContextItem(id: o.id, name: o.name, text: t)
        }
    }
}

// MARK: - Chat API (OpenAI-compatible)

enum ChatAPI {
    /// 每一段最多发出去的字数。
    static let contextLimit = 6000

    static func systemPrompt(_ context: [ChatContextItem]) -> String {
        let source = context.first(where: \.isSource)
        let translations = context.filter { !$0.isSource }
        var lines = [
            "You are a helpful assistant discussing a translation with the user.",
            "Keep answers concise and useful. Prefer Markdown when it helps (lists, code, emphasis).",
            "Reply in the same language the user writes in (Chinese → Chinese, English → English), unless they ask otherwise.",
        ]
        if translations.count > 1 {
            lines.append("The user is asking about \(translations.count) translations of the same original, each from a different service. Name the service when you refer to one, and compare them when asked.")
        } else if source == nil, !translations.isEmpty {
            lines.append("The user is asking about the translation only. The original is not shown to you.")
        } else if translations.isEmpty, source != nil {
            lines.append("The user is asking about the original only. No translation is shown to you.")
        }
        var out = lines.joined(separator: "\n") + "\n"
        if let source {
            out += "\n--- Original ---\n\(source.text)\n"
        }
        for t in translations {
            let label = translations.count > 1 || source == nil ? "Translation (\(t.name))" : "Translation"
            out += "\n--- \(label) ---\n\(t.text)\n"
        }
        return out + "---"
    }

    static func chat(
        messages: [ChatMessage],
        profile: AIProfile,
        context: [ChatContextItem]
    ) async throws -> String {
        // 发出去的是截断后的原文；上下文和对话都是一段一段送。
        let sentContext = context.map { String($0.text.prefix(contextLimit)) }
        let visible = messages.filter { $0.role != .system }
        let sent = try await MaskedSend.prepare(
            sentContext + visible.map(\.content),
            destination: MaskDestination.entry(.ai(profile))
        )
        let covered = zip(context, sent.prefix(context.count)).map {
            ChatContextItem(id: $0.id, name: $0.name, text: $1)
        }
        let rows = zip(visible, sent.suffix(visible.count)).map { ($0.role.rawValue, $1) }
        var apiMessages: [[String: String]] = [
            ["role": "system", "content": systemPrompt(covered)]
        ]
        for (role, content) in rows {
            apiMessages.append(["role": role, "content": content])
        }
        let body: [String: Any] = [
            "model": profile.model,
            "temperature": 0.5,
            "messages": apiMessages,
        ]
        let content = try await ChatClient.completion(
            profile: profile,
            body: body,
            timeout: 120,
            failFormat: L("%@ 对话失败 (%@): %@")
        )
        return SecretCover.restore(content)
    }

    /// 一段指令加一段原文，要一段回复。划词插件走这一条，不需要对话上下文。
    static func complete(instruction: String, source: String, profile: AIProfile) async throws -> String {
        // 发出去的是截断后的原文。拿截断前后比会把「太长」错当成「遮了密钥」，
        // 每次长选区都弹一次确认。
        let sent = String(source.prefix(contextLimit))
        let masked = try await MaskedSend.prepare(
            [instruction, sent],
            destination: MaskDestination.entry(.ai(profile))
        )
        let coveredInstruction = masked[0]
        let coveredSource = masked[1]
        let system = [
            "You follow the user's instruction on the passage they selected in another app.",
            "Reply with the result only — no preamble, no restating the instruction, no closing remark.",
            "Write in the same language as the passage unless the instruction says otherwise.",
            "Markdown is fine when it helps.",
        ].joined(separator: "\n")
        let body: [String: Any] = [
            "model": profile.model,
            "temperature": 0.4,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": "\(coveredInstruction)\n\n---\n\(coveredSource)"],
            ],
        ]
        let content = try await ChatClient.completion(
            profile: profile,
            body: body,
            timeout: 120,
            failFormat: L("%@ 对话失败 (%@): %@")
        )
        return SecretCover.restore(content)
    }
}

// MARK: - Session model

@MainActor
final class ChatSession: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var input = ""
    @Published var isSending = false
    @Published var error: String?
    @Published var profileID: String = ""
    @Published var source: String = ""
    /// 有译文的那几家。
    @Published private(set) var translations: [ChatContextItem] = []
    /// 提问对象：原文和哪几家译文。至少留一项。
    @Published private(set) var askIDs: Set<String> = []
    /// 这次换的模型。不写回设置。
    @Published var modelOverrides: ModelOverrides = [:]

    /// 用户自己点过提问对象。之后换译文也不改回默认。
    private var askPicked = false
    /// 用户在这个窗口里选过的 AI。只在内存里。
    private var pickedProfileID: String?
    private var task: Task<Void, Never>?

    var enabledProfiles: [AIProfile] {
        AppConfig.shared.aiProfiles.filter { p in
            guard AppConfig.shared.isActiveAI(p) else { return false }
            let preset = AIPresetDef.find(p.preset)
            let keyOK = (preset?.noKey ?? false)
                || !AppConfig.shared.aiKey(for: p).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let urlOK = !p.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let modelOK = !p.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return keyOK && urlOK && modelOK
        }
    }

    /// 设置里的那份配置，没有换模型。
    var selectedProfile: AIProfile? {
        if let p = enabledProfiles.first(where: { $0.id == profileID }) { return p }
        return enabledProfiles.first
    }

    /// 真正发出去的那份：换过模型就用换的。
    var effectiveProfile: AIProfile? {
        selectedProfile.map { $0.withModel(modelOverrides[$0.id]) }
    }

    /// 原文在前，再按显示顺序放各家译文。
    var contextItems: [ChatContextItem] {
        var out: [ChatContextItem] = []
        if !source.isEmpty {
            out.append(ChatContextItem(id: ChatContextItem.sourceID, name: L("原文"), text: source))
        }
        return out + translations
    }

    /// 这一次提问会带上的几段。
    var askedItems: [ChatContextItem] {
        contextItems.filter { askIDs.contains($0.id) }
    }

    func pickProfile(_ id: String) {
        profileID = id
        pickedProfileID = id
    }

    func isAsked(_ id: String) -> Bool { askIDs.contains(id) }

    /// 点一下提问对象。最后一项点不掉。
    func toggleAsk(_ id: String) {
        guard contextItems.contains(where: { $0.id == id }) else { return }
        var next = askIDs
        if next.contains(id) { next.remove(id) } else { next.insert(id) }
        guard !next.isEmpty else { return }
        askIDs = next
        askPicked = true
    }

    /// `primaryID` 是界面上正在看的那一家，没点过提问对象时默认问它。
    func configure(
        source: String,
        translations: [ChatContextItem],
        primaryID: String? = nil,
        preferredProfileID: String? = nil
    ) {
        self.source = source
        self.translations = translations
        self.error = nil
        let valid = Set(contextItems.map(\.id))
        let kept = askIDs.intersection(valid)
        if askPicked, !kept.isEmpty {
            askIDs = kept
        } else {
            askPicked = false
            var ids: Set<String> = source.isEmpty ? [] : [ChatContextItem.sourceID]
            if let first = translations.first(where: { $0.id == primaryID }) ?? translations.first {
                ids.insert(first.id)
            }
            askIDs = ids
        }
        let preferred = pickedProfileID
            ?? preferredProfileID
            ?? (AppConfig.shared.fileAIProfileID.isEmpty ? nil : AppConfig.shared.fileAIProfileID)
        if let id = preferred, enabledProfiles.contains(where: { $0.id == id }) {
            profileID = id
        } else if profileID.isEmpty || !enabledProfiles.contains(where: { $0.id == profileID }) {
            profileID = enabledProfiles.first?.id ?? ""
        }
    }

    /// 换了一段新的翻译。清掉对话和提问对象；这个窗口里选过的 AI 和换过的模型留着。
    func reset(
        source: String,
        translations: [ChatContextItem],
        primaryID: String? = nil,
        preferredProfileID: String? = nil
    ) {
        task?.cancel()
        messages = []
        input = ""
        isSending = false
        error = nil
        askPicked = false
        askIDs = []
        configure(source: source, translations: translations, primaryID: primaryID, preferredProfileID: preferredProfileID)
    }

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        guard let profile = effectiveProfile else {
            error = L("请先在偏好设置添加并启用 AI 提供商")
            return
        }
        profileID = profile.id
        input = ""
        error = nil
        messages.append(ChatMessage(role: .user, content: text))
        isSending = true
        let snapshot = messages
        let context = askedItems
        let p = profile

        task = Task { @MainActor in
            do {
                let reply = try await Background.run {
                    try await ChatAPI.chat(messages: snapshot, profile: p, context: context)
                }
                if Task.isCancelled { return }
                messages.append(ChatMessage(role: .assistant, content: reply))
                isSending = false
            } catch {
                if Task.isCancelled || error is MaskDeclined {
                    isSending = false
                    return
                }
                self.error = error.localizedDescription
                isSending = false
            }
        }
    }

    func cancel() {
        task?.cancel()
        isSending = false
    }

    func clearHistory() {
        guard !isSending else { return }
        messages = []
        error = nil
    }
}

// MARK: - Reusable chat UI

private enum ChatMarkdown {
    static func display(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            var plain = AttributedString(text)
            plain.font = Theme.TypeScale.body
            return plain
        }
        var out = AttributedString()
        var previous: Block?
        for run in parsed.runs {
            let raw = String(parsed[run.range].characters)
            guard !raw.isEmpty else { continue }
            let block = run.presentationIntent.map(Block.init) ?? Block.plain
            if let previous, previous.id != block.id || previous.column != block.column {
                if previous.row != nil, previous.row == block.row, previous.column != block.column {
                    out.append(AttributedString(" | "))
                } else {
                    let tight = previous.marker != nil && block.marker != nil
                        || previous.row != nil && block.row != nil
                    out.append(AttributedString(tight ? "\n" : "\n\n"))
                }
            }
            if previous?.id != block.id, let marker = block.marker {
                var mark = AttributedString(marker)
                mark.font = Theme.TypeScale.body
                mark.foregroundColor = .secondary
                out.append(mark)
            }
            var piece = AttributedString(styled(raw, block: block))
            piece.font = font(run.inlinePresentationIntent, block: block)
            if run.inlinePresentationIntent?.contains(.code) == true || block.code {
                piece.backgroundColor = Color.primary.opacity(0.06)
            }
            if let link = run.link {
                piece.link = link
                piece.underlineStyle = .single
                piece.foregroundColor = Color.accentColor
            }
            out.append(piece)
            previous = block
        }
        if out.characters.isEmpty {
            var plain = AttributedString(text)
            plain.font = Theme.TypeScale.body
            return plain
        }
        return out
    }

    private static func styled(_ raw: String, block: Block) -> String {
        guard block.code else { return raw }
        return raw.hasSuffix("\n") ? String(raw.dropLast()) : raw
    }

    private static func font(_ inline: InlinePresentationIntent?, block: Block) -> Font {
        let header = block.headerLevel
        let base: Font = block.code || inline?.contains(.code) == true
            ? Theme.TypeScale.label.monospaced()
            : (header == 1 ? Theme.TypeScale.title : (header == 2 ? Theme.TypeScale.reading : Theme.TypeScale.body))
        var font = base.weight(header != nil || inline?.contains(.stronglyEmphasized) == true ? .semibold : .regular)
        if inline?.contains(.emphasized) == true { font = font.italic() }
        return font
    }

    private struct Block: Equatable {
        var id: Int
        var marker: String?
        var headerLevel: Int?
        var code: Bool
        var row: Int?
        var column: Int?

        static let plain = Block(id: -1, marker: nil, headerLevel: nil, code: false, row: nil, column: nil)

        private init(id: Int, marker: String?, headerLevel: Int?, code: Bool, row: Int?, column: Int?) {
            self.id = id
            self.marker = marker
            self.headerLevel = headerLevel
            self.code = code
            self.row = row
            self.column = column
        }

        init(_ intent: PresentationIntent) {
            var id = -1
            var marker: String?
            var headerLevel: Int?
            var code = false
            var row: Int?
            var column: Int?
            var ordered = false
            var itemID: Int?
            var itemOrdinal = 1
            var quoted = false
            for part in intent.components {
                switch part.kind {
                case .paragraph:
                    if id < 0 { id = part.identity }
                case .header(let level):
                    id = part.identity
                    headerLevel = level
                case .orderedList:
                    ordered = true
                case .unorderedList:
                    break
                case .listItem(let ordinal):
                    itemID = part.identity
                    itemOrdinal = ordinal
                case .codeBlock(_):
                    id = part.identity
                    code = true
                case .blockQuote:
                    quoted = true
                case .thematicBreak:
                    id = part.identity
                case .table(_):
                    break
                case .tableCell(let index):
                    column = index
                case .tableHeaderRow:
                    id = part.identity
                    row = -1
                case .tableRow(let index):
                    id = part.identity
                    row = index
                @unknown default:
                    break
                }
            }
            if let itemID {
                id = itemID
                marker = ordered ? "\(itemOrdinal). " : "• "
            } else if quoted, marker == nil {
                marker = "› "
            }
            self.id = id
            self.marker = marker
            self.headerLevel = headerLevel
            self.code = code
            self.row = row
            self.column = column
        }
    }
}

struct TranslationChatView: View {
    @ObservedObject var session: ChatSession
    @EnvironmentObject var config: AppConfig
    var compact: Bool = false
    var hugsContent: Bool = false
    /// Set for a live 划词. File translation leaves this nil, so replies have no 写回.
    var onWriteBack: ((String, String) -> Void)? = nil
    /// Why 写回 cannot run for this 划词. The button stays, disabled.
    var writeBackBlocked: String? = nil
    var writeBackNoteID: String? = nil
    var writeBackNote: String? = nil
    @State private var copiedMessageID: String?
    @ObservedObject private var lists = ModelListRefresh.shared

    var body: some View {
        VStack(spacing: 0) {
            header
                .fixedSize(horizontal: false, vertical: true)
            askBar
                .fixedSize(horizontal: false, vertical: true)
            messageList
            if let e = session.error {
                ErrorLine(text: e)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
            }
            inputBar
                .fixedSize(horizontal: false, vertical: true)
        }
        .background(compact ? Color.clear : Theme.windowFill)
    }

    private var header: some View {
        HStack(spacing: 6) {
            SectionHeader(L("AI 对话"))
            Spacer()
            modelPicker
            if !session.messages.isEmpty {
                IconButton(systemImage: "trash", help: L("清空对话"), size: 11) { session.clearHistory() }
                    .disabled(session.isSending)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var modelPicker: some View {
        let _ = lists.version
        let profiles = session.enabledProfiles
        if profiles.isEmpty {
            Text(L("无可用模型"))
                .font(Theme.TypeScale.caption)
                .foregroundStyle(Theme.attention)
        } else {
            Menu {
                Section(L("AI 提供商")) {
                    Picker("", selection: Binding(
                        get: { session.profileID },
                        set: { session.pickProfile($0) }
                    )) {
                        ForEach(profiles) { p in
                            Text(p.name).tag(p.id)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                if let p = session.selectedProfile {
                    if Pro.unlocked {
                        ModelOverrideItems(profile: p, override: $session.modelOverrides.model(for: p))
                    } else {
                        Section(L("模型")) { Text(p.model) }
                    }
                }
            } label: {
                Text(session.effectiveProfile.map(modelLabel) ?? L("选择模型"))
                    .font(Theme.TypeScale.caption)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
            .frame(maxWidth: compact ? 200 : 260, alignment: .trailing)
            .disabled(session.isSending)
            .help(L("对话中可随时换模型，下一条消息起生效，不改设置"))
        }
    }

    /// 提问对象：原文、每一家的译文。点了从下一条消息起生效。
    @ViewBuilder
    private var askBar: some View {
        let items = session.contextItems
        if items.count > 1 {
            HStack(spacing: 4) {
                Text(L("提问对象"))
                    .font(Theme.TypeScale.micro)
                    .foregroundStyle(.tertiary)
                    .padding(.trailing, 2)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(items) { item in
                            askChip(item, onlyTranslation: session.translations.count == 1)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 4)
        }
    }

    private func askChip(_ item: ChatContextItem, onlyTranslation: Bool) -> some View {
        let on = session.isAsked(item.id)
        let title = item.isSource ? L("原文") : (onlyTranslation ? L("译文") : item.name)
        return Button {
            session.toggleAsk(item.id)
        } label: {
            HStack(spacing: 4) {
                if !item.isSource {
                    ProviderIconView(outcomeID: item.id, name: item.name, size: 10)
                }
                Text(title).lineLimit(1)
            }
        }
        .buttonStyle(ChipButtonStyle(selected: on))
        .disabled(session.isSending)
        .help(on
              ? String(format: L("提问时带上%@。再点一下不带"), title)
              : String(format: L("提问时也带上%@"), title))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var surfaceOpacity: Double {
        guard compact else { return 1 }
        return min(1, max(0.35, config.panelOpacity))
    }

    private func modelLabel(_ p: AIProfile) -> String {
        let model = p.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.isEmpty { return p.name }
        if model.count > 28 {
            return "\(p.name) · \(model.prefix(26))…"
        }
        return "\(p.name) · \(model)"
    }

    private var messageColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            if session.messages.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(session.askedItems) { item in
                        contextChip(
                            title: item.isSource ? L("原文") : (session.translations.count == 1 ? L("译文") : item.name),
                            text: item.text
                        )
                    }
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(session.messages) { msg in
                messageBubble(msg)
                    .id(msg.id)
            }
            if session.isSending {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(L("思考中…")).font(Theme.TypeScale.label).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .id("sending")
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var messageList: some View {
        if hugsContent {
            messageColumn
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    messageColumn
                }
                .scrollContentBackground(.hidden)
                .onChange(of: session.messages.count) { _, _ in
                    withAnimation {
                        if session.isSending {
                            proxy.scrollTo("sending", anchor: .bottom)
                        } else if let last = session.messages.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: session.isSending) { _, sending in
                    if sending {
                        withAnimation { proxy.scrollTo("sending", anchor: .bottom) }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func contextChip(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Theme.TypeScale.micro)
                .foregroundStyle(.tertiary)
            Text(text.truncated(to: 180))
                .font(Theme.TypeScale.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(fill: Theme.wellFill.opacity(surfaceOpacity), radius: 8, stroke: false)
    }

    @ViewBuilder
    private func messageBubble(_ msg: ChatMessage) -> some View {
        if msg.role == .user {
            HStack(spacing: 0) {
                Spacer(minLength: 48)
                Text(msg.content)
                    .font(Theme.TypeScale.body)
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.accentColor)
                    )
            }
            .padding(.horizontal, 12)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(ChatMarkdown.display(msg.content))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .card(fill: Theme.cardFill.opacity(surfaceOpacity), radius: 14)
                if !msg.content.isEmpty {
                    HStack(spacing: 4) {
                        IconButton(
                            systemImage: copiedMessageID == msg.id ? "checkmark" : "doc.on.doc",
                            help: L("复制这条回复"),
                            tint: copiedMessageID == msg.id ? .green : nil,
                            size: 10
                        ) {
                            let pb = NSPasteboard.general
                            pb.clearContents()
                            pb.setString(msg.content, forType: .string)
                            copiedMessageID = msg.id
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                if copiedMessageID == msg.id { copiedMessageID = nil }
                            }
                        }
                        if let onWriteBack {
                            IconButton(
                                systemImage: "text.insert",
                                help: writeBackBlocked ?? L("写回来源应用里当时的选区"),
                                size: 10
                            ) {
                                onWriteBack(msg.id, msg.content)
                            }
                            .disabled(writeBackBlocked != nil)
                            .accessibilityLabel(L("写回"))
                        }
                    }
                    if writeBackNoteID == msg.id, let writeBackNote {
                        ErrorLine(text: writeBackNote)
                    }
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 48)
        }
    }

    private var inputBar: some View {
        let canSend = !session.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !session.enabledProfiles.isEmpty
        return HStack(alignment: .center, spacing: 6) {
            ChatComposer(
                text: $session.input,
                placeholder: L("继续提问…"),
                isEnabled: !session.isSending && !session.enabledProfiles.isEmpty,
                onSubmit: { session.send() }
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 4)

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
                Button {
                    session.send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(Theme.TypeScale.title)
                        .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.4))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help(L("⌘↩ 发送"))
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 5)
        .padding(.vertical, 4)
        .card(fill: Theme.cardFill.opacity(surfaceOpacity), radius: 16)
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }
}

// MARK: - Composer

/// Multiline chat field. Return sends; Shift-Return inserts a newline. Return during
/// IME composition confirms the candidate and does not send.
struct ChatComposer: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var isEnabled: Bool
    var onSubmit: () -> Void

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

        let textView = ChatComposerTextView(frame: .zero)
        textView.configure()
        textView.delegate = context.coordinator
        textView.string = text
        textView.placeholder = placeholder
        textView.isEditable = isEnabled
        textView.onSubmit = onSubmit
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? ChatComposerTextView else { return }
        context.coordinator.parent = self
        textView.placeholder = placeholder
        textView.onSubmit = onSubmit
        textView.isEditable = isEnabled
        if !isEnabled, textView.window?.firstResponder === textView {
            textView.window?.makeFirstResponder(nil)
        }
        // A parent refresh can arrive while the binding still has the pre-composition
        // string. Pushing that back in cancels the candidate. An empty binding is a
        // real clear (send), and still replaces the field.
        if textView.isComposing, !text.isEmpty, text != textView.string { return }
        guard textView.string != text else { return }
        context.coordinator.applying = true
        if textView.hasMarkedText() {
            textView.inputContext?.discardMarkedText()
        }
        textView.string = text
        context.coordinator.applying = false
        textView.fitWidth(scroll.contentSize.width)
        scroll.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context) -> CGSize? {
        guard let textView = scroll.documentView as? ChatComposerTextView else { return nil }
        let width = proposal.width ?? scroll.bounds.width
        if width > 1 {
            textView.fitWidth(width)
        }
        return CGSize(width: max(width, 1), height: textView.cappedHeight)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatComposer
        var applying = false

        init(_ parent: ChatComposer) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard !applying, let textView = notification.object as? NSTextView else { return }
            if parent.text != textView.string {
                parent.text = textView.string
            }
        }
    }
}

final class ChatComposerTextView: NSTextView {
    var placeholder = "" {
        didSet { if placeholder != oldValue { needsDisplay = true } }
    }
    var onSubmit: () -> Void = {}
    /// True from setMarkedText until the composition is unmarked.
    private var composing = false
    /// Return arrived while a composition was still open. Swallow the newline that follows the commit.
    private var returnDuringComposition = false
    /// Set when a composition ends, cleared on the next turn. Covers IMEs that unmark
    /// and then deliver the same Return after marked text is already gone.
    private var suppressReturn = false
    private var allowingNewline = false
    private var fitting = false
    private var returnMonitor: Any?
    private var handledReturnStamp: TimeInterval = -1

    var isComposing: Bool { composing || hasMarkedText() }

    func configure() {
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        isSelectable = true
        isAutomaticLinkDetectionEnabled = false
        drawsBackground = false
        backgroundColor = .clear
        focusRingType = .none
        font = Theme.TypeScale.nsBody
        textColor = .labelColor
        insertionPointColor = .labelColor
        textContainerInset = NSSize(width: 0, height: 1)
        textContainer?.lineFragmentPadding = 0
        isHorizontallyResizable = false
        isVerticallyResizable = true
        autoresizingMask = [.width]
        textContainer?.widthTracksTextView = true
        textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        minSize = NSSize(width: 0, height: 0)
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        defaultParagraphStyle = style
        typingAttributes = [
            .font: Theme.TypeScale.nsBody,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style,
        ]
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        textColor = .labelColor
        typingAttributes[.foregroundColor] = NSColor.labelColor
        needsDisplay = true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let returnMonitor {
            NSEvent.removeMonitor(returnMonitor)
            self.returnMonitor = nil
        }
        guard window != nil else { return }
        returnMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.focusOwns(event), event.isComposerReturn else { return event }
            self.handleReturn(event)
            return nil
        }
    }

    deinit {
        if let returnMonitor { NSEvent.removeMonitor(returnMonitor) }
    }

    var composerLineHeight: CGFloat {
        layoutManager?.defaultLineHeight(for: font ?? Theme.TypeScale.nsBody) ?? 16
    }

    var cappedHeight: CGFloat {
        min(fullHeight, composerLineHeight * 5 + textContainerInset.height * 2)
    }

    var fullHeight: CGFloat {
        let inset = textContainerInset.height * 2
        guard let layoutManager, let textContainer else { return composerLineHeight + inset }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer).height
        return max(used, composerLineHeight) + inset
    }

    func fitWidth(_ proposed: CGFloat) {
        guard !fitting else { return }
        fitting = true
        defer { fitting = false }
        let width = max(proposed, 1)
        if abs(frame.width - width) > 0.5 {
            setFrameSize(NSSize(width: width, height: max(frame.height, 1)))
        }
        let content = fullHeight
        let visible = enclosingScrollView?.contentSize.height ?? content
        let height = max(content, visible, 1)
        if abs(frame.height - height) > 0.5 {
            setFrameSize(NSSize(width: width, height: height))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let font = self.font ?? Theme.TypeScale.nsBody
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        (placeholder as NSString).draw(at: textContainerOrigin, withAttributes: attrs)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
        enclosingScrollView?.invalidateIntrinsicContentSize()
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let wasMarked = hasMarkedText()
        let empty = Self.markedIsEmpty(string)
        composing = !empty
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        if empty, wasMarked { armSuppressReturn() }
    }

    override func unmarkText() {
        let ended = hasMarkedText()
        composing = false
        super.unmarkText()
        if ended { armSuppressReturn() }
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let ending = hasMarkedText()
        if !ending, Self.bareNewline(insertString) {
            if returnDuringComposition || suppressReturn {
                suppressReturn = false
                return
            }
            if allowingNewline || Self.shiftHeld() {
                super.insertText(insertString, replacementRange: replacementRange)
            } else {
                submitFromField()
            }
            return
        }
        super.insertText(insertString, replacementRange: replacementRange)
        composing = false
        if ending { armSuppressReturn() }
    }

    private func armSuppressReturn() {
        suppressReturn = true
        DispatchQueue.main.async { [weak self] in
            self?.suppressReturn = false
        }
    }

    override func keyDown(with event: NSEvent) {
        guard isEditable, event.isComposerReturn else {
            super.keyDown(with: event)
            return
        }
        handleReturn(event)
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(insertNewline(_:)), #selector(insertNewlineIgnoringFieldEditor(_:)):
            insertNewline(nil)
        case #selector(insertLineBreak(_:)):
            insertLineBreak(nil)
        default:
            super.doCommand(by: selector)
        }
    }

    override func insertNewline(_ sender: Any?) {
        if returnDuringComposition || hasMarkedText() { return }
        if suppressReturn {
            suppressReturn = false
            return
        }
        if allowingNewline || Self.shiftHeld() {
            allowingNewline = true
            super.insertNewline(sender)
            allowingNewline = false
            return
        }
        submitFromField()
    }

    override func insertNewlineIgnoringFieldEditor(_ sender: Any?) {
        insertNewline(sender)
    }

    override func insertLineBreak(_ sender: Any?) {
        allowingNewline = true
        super.insertLineBreak(sender)
        allowingNewline = false
    }

    private func focusOwns(_ event: NSEvent) -> Bool {
        guard isEditable, event.window === window, let responder = window?.firstResponder else { return false }
        if responder === self || responder === enclosingScrollView { return true }
        return (responder as? NSView)?.isDescendant(of: self) == true
    }

    private func handleReturn(_ event: NSEvent) {
        if event.timestamp == handledReturnStamp { return }
        handledReturnStamp = event.timestamp
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.shift), !mods.contains(.command), !mods.contains(.control) {
            insertPlainBreak()
            return
        }
        if hasMarkedText() {
            returnDuringComposition = true
            super.keyDown(with: event)
            returnDuringComposition = false
            return
        }
        composing = false
        if event.isARepeat || mods.contains(.control) || suppressReturn {
            suppressReturn = false
            return
        }
        submitFromField()
    }

    private func insertPlainBreak() {
        if hasMarkedText() { inputContext?.discardMarkedText() }
        composing = false
        allowingNewline = true
        super.insertNewline(nil)
        allowingNewline = false
    }

    private func submitFromField() {
        if let coord = delegate as? ChatComposer.Coordinator, coord.parent.text != string {
            coord.applying = true
            coord.parent.text = string
            coord.applying = false
        }
        onSubmit()
    }

    private static func markedIsEmpty(_ string: Any) -> Bool {
        switch string {
        case let value as String:
            return value.isEmpty
        case let value as NSAttributedString:
            return value.length == 0
        default:
            return true
        }
    }

    private static func bareNewline(_ string: Any) -> Bool {
        switch string {
        case let value as String:
            return value == "\n" || value == "\r" || value == "\r\n"
        case let value as NSAttributedString:
            return value.string == "\n" || value.string == "\r" || value.string == "\r\n"
        default:
            return false
        }
    }

    private static func shiftHeld() -> Bool {
        guard let event = NSApp.currentEvent, event.type == .keyDown else { return false }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return mods.contains(.shift) && !mods.contains(.command) && !mods.contains(.control)
    }
}

private extension NSEvent {
    var isComposerReturn: Bool {
        if keyCode == 36 || keyCode == 76 { return true }
        switch charactersIgnoringModifiers {
        case "\r"?, "\n"?, "\u{3}"?: return true
        default: return false
        }
    }
}
