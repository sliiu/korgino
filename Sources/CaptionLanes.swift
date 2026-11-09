import AppKit
import SwiftUI

enum CaptionExportRule: String {
    case byLane
    case byBinding

    static let key = "caption.exportRule"

    static var remembered: CaptionExportRule {
        get { CaptionExportRule(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .byLane }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

struct SpeakerMarkBook: Equatable {
    var renamed: [Int: String] = [:]
    var removed: Set<Int> = []
    /// Merged away → kept. New segments heard as the first number land on the second.
    var merged: [Int: Int] = [:]
    /// Speaker number → the voice that reads this person's lines. Empty means the usual voice.
    /// `apple:<voice id>` is a system voice; `tts:<profile id>:<voice>` is one cloud voice of one service.
    var voices: [Int: String] = [:]

    func resolve(_ speaker: Int) -> Int {
        var current = speaker
        var hops = 0
        while let next = merged[current], next != current, hops < 16 {
            current = next
            hops += 1
        }
        return current
    }

    mutating func merge(_ from: Int, into: Int) {
        guard from > 0, into > 0, resolve(into) != from else { return }
        merged[from] = into
        renamed.removeValue(forKey: from)
        removed.remove(from)
        voices.removeValue(forKey: from)
    }

    /// The voice assigned to this speaker, or nil when this person uses the usual voice.
    func voice(for speaker: Int) -> String? {
        guard speaker > 0, !removed.contains(speaker) else { return nil }
        let value = voices[speaker]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    mutating func setVoice(_ speaker: Int, to raw: String?) {
        guard speaker > 0 else { return }
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if value.isEmpty {
            voices.removeValue(forKey: speaker)
        } else {
            voices[speaker] = value
        }
    }

    func token(speaker: Int, fallback: String) -> String? {
        guard speaker > 0, !removed.contains(speaker) else { return nil }
        if let name = renamed[speaker] {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]"), trimmed.count >= 2 { return trimmed }
            return "[\(trimmed)]"
        }
        return fallback
    }

    mutating func rename(speaker: Int, to raw: String) {
        guard speaker > 0 else { return }
        removed.remove(speaker)
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[") { trimmed.removeFirst() }
        if trimmed.hasSuffix("]") { trimmed.removeLast() }
        trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            renamed.removeValue(forKey: speaker)
        } else {
            renamed[speaker] = trimmed
        }
    }

    mutating func remove(speaker: Int) {
        renamed.removeValue(forKey: speaker)
        removed.insert(speaker)
        voices.removeValue(forKey: speaker)
    }

    mutating func removeAll(_ speakers: Set<Int>) {
        for speaker in speakers { remove(speaker: speaker) }
    }
}

/// One translation service plus one target language on a lane. 「不翻译」 is a binding whose text is the source.
struct LaneBinding: Hashable, Identifiable {
    static let sourceID = "none"
    /// 同传服务自己给的译文。只挂在同传那一路上，一路一条。
    static let interpID = "interp"

    var translateID: String
    var target: TargetLanguage

    var id: String { key }
    var isSource: Bool { translateID == Self.sourceID }
    var isInterp: Bool { translateID == Self.interpID }
    var key: String { isSource ? Self.sourceID : "\(translateID)@\(target.rawValue)" }

    init(translateID: String, target: TargetLanguage) {
        self.translateID = translateID
        self.target = target
    }

    init?(key: String) {
        if key == Self.sourceID {
            self.init(translateID: Self.sourceID, target: .auto)
            return
        }
        guard let at = key.lastIndex(of: "@"),
              let target = TargetLanguage(rawValue: String(key[key.index(after: at)...])) else { return nil }
        self.init(translateID: String(key[..<at]), target: target)
    }

    static let source = LaneBinding(translateID: sourceID, target: .auto)
}

struct RecognitionLane: Identifiable, Equatable {
    var id = UUID()
    var asrID: String
    var bindings: [LaneBinding]
    var marks = SpeakerMarkBook()
    var note = SessionNoteSlot()

    var bindingKeys: [String] { bindings.map(\.key) }
    /// The binding the 同传服务 itself fills, on a 同传 lane.
    var interpBinding: LaneBinding? { bindings.first(where: \.isInterp) }
    var translatingKeys: [String] { bindings.filter { !$0.isSource }.map(\.key) }

    /// Translation services in use, 「不翻译」 excluded, each once.
    var translateIDs: [String] {
        var seen: [String] = []
        for b in bindings where !b.isSource && !seen.contains(b.translateID) { seen.append(b.translateID) }
        return seen
    }

    mutating func addBinding(_ binding: LaneBinding) {
        guard !bindingKeys.contains(binding.key) else { return }
        bindings.append(binding)
    }

    mutating func removeBinding(_ key: String) {
        bindings.removeAll { $0.key == key }
        if bindings.isEmpty { bindings = [.source] }
    }

    /// Returns false when the edited pair already exists on this lane.
    @discardableResult
    mutating func replaceBinding(_ key: String, with next: LaneBinding) -> Bool {
        guard let index = bindings.firstIndex(where: { $0.key == key }) else { return false }
        if next.key != key, bindingKeys.contains(next.key) { return false }
        bindings[index] = next
        return true
    }
}

enum LaneBindingNames {
    static func service(_ id: String) -> String {
        if id == LaneBinding.sourceID { return L("不翻译") }
        if id == LaneBinding.interpID { return L("同传") }
        return AppConfig.shared.catalogTargets().first { $0.id == id }?.displayName
            ?? AppConfig.shared.enabledTranslateTargets().first { $0.id == id }?.displayName
            ?? id
    }

    static func title(_ binding: LaneBinding) -> String {
        binding.isSource ? L("不翻译") : "\(service(binding.translateID)) → \(binding.target.shortTitle)"
    }

    static func title(key: String) -> String {
        LaneBinding(key: key).map(title) ?? key
    }

    static func fileStem(_ binding: LaneBinding) -> String {
        binding.isSource ? L("原文") : "\(service(binding.translateID)).\(binding.target.shortTitle)"
    }
}

struct LaneDraft: Equatable {
    var text = ""
    var translations: [String: String] = [:]
    var speaker = 0
    var mask: [NSRange] = []
    var partial = false
}

struct CaptionLaneFile {
    var name: String
    var text: String
}

enum CaptionExport {
    struct Cue {
        var start: TimeInterval
        var end: TimeInterval
        var source: String
        var mark: String?
        /// Keyed by binding key; only finished translations.
        var translations: [String: String] = [:]
    }

    /// One recognition lane as the export sheet sees it.
    struct Lane {
        /// Remembers the 「带原文」 tick across sessions, e.g. `system|apple`.
        var key: String
        var title: String
        var fileStem: String
        var bindings: [LaneBinding]
        var cues: [Cue]
    }

    struct Choice {
        var folder: URL
        var rule: CaptionExportRule
        var sourceLanes: Set<String>
    }

    private static let droppedSourceKey = "caption.exportDroppedSource"

    private static var droppedSource: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: droppedSourceKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: droppedSourceKey) }
    }

    static func rememberedSourceLanes(_ lanes: [Lane]) -> Set<String> {
        let dropped = droppedSource
        return Set(lanes.map(\.key).filter { !dropped.contains($0) })
    }

    @MainActor
    static func choose(lanes: [Lane], suggestedName: String = "", start: URL? = nil) -> Choice? {
        let picked = RulePicks(lanes: lanes)
        let ruleTitle = NSTextField(labelWithString: L("怎么分文件"))
        ruleTitle.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        let sourceTitle = NSTextField(labelWithString: L("带原文"))
        sourceTitle.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        let sourceHint = NSTextField(wrappingLabelWithString: L("勾上的一路，导出时保留识别出的原文；取消就只出译文。"))
        sourceHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        sourceHint.textColor = .secondaryLabelColor
        sourceHint.preferredMaxLayoutWidth = 330
        let dropped = droppedSource
        for lane in lanes {
            let box = NSButton(checkboxWithTitle: lane.title, target: picked, action: #selector(RulePicks.sourceToggled(_:)))
            box.state = dropped.contains(lane.key) ? .off : .on
            picked.sourceBoxes.append((lane.key, box))
        }

        let stack = NSStackView(views: [
            ruleTitle,
            picked.choice,
            indent(picked.laneHint), indent(picked.bindingHint),
            picked.preview,
            spacer(14),
            sourceTitle, indent(sourceHint),
        ] + picked.sourceBoxes.map(\.1))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        stack.setCustomSpacing(3, after: ruleTitle)
        stack.setCustomSpacing(12, after: picked.choice)
        stack.setCustomSpacing(4, after: sourceTitle)
        stack.setCustomSpacing(4, after: sourceHint)
        stack.frame = NSRect(x: 0, y: 0, width: 420, height: 0)
        stack.layoutSubtreeIfNeeded()
        stack.frame.size.height = max(ceil(stack.fittingSize.height), 180)
        picked.refresh()

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = L("导出")
        panel.message = suggestedName.isEmpty ? L("选择文件夹") : String(format: L("把「%@」的字幕导出到"), suggestedName)
        if let start { panel.directoryURL = start }
        panel.accessoryView = stack
        panel.isAccessoryViewDisclosed = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let chosen = picked.rule
        CaptionExportRule.remembered = chosen
        var keep = Set<String>()
        var drop = droppedSource
        for (key, box) in picked.sourceBoxes {
            if box.state == .on {
                keep.insert(key)
                drop.remove(key)
            } else {
                drop.insert(key)
            }
        }
        droppedSource = drop
        return Choice(folder: url, rule: chosen, sourceLanes: keep)
    }

    private static func indent(_ view: NSView) -> NSView {
        let pad = NSView()
        pad.translatesAutoresizingMaskIntoConstraints = false
        pad.widthAnchor.constraint(equalToConstant: 19).isActive = true
        let row = NSStackView(views: [pad, view])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 0
        return row
    }

    private static func spacer(_ height: CGFloat) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }

    /// The two output shapes as radio buttons. A radio's dot reads at a glance, which a segmented control
    /// inside a panel's accessory view does not — and the hint under each one says what actually lands in
    /// the folder, with a live count so the choice can be checked before pressing Export.
    @MainActor
    final class RulePicks: NSObject {
        private let lanes: [Lane]
        let choice: PillChoice
        let laneHint: NSTextField
        let bindingHint: NSTextField
        let preview: NSTextField
        var sourceBoxes: [(String, NSButton)] = []

        init(lanes: [Lane]) {
            self.lanes = lanes
            choice = PillChoice(titles: [L("一路识别一份"), L("一条译文一份")])
            laneHint = NSTextField(wrappingLabelWithString: L("一条字幕里，原文在上，这一路的各家译文按顺序排在下。"))
            bindingHint = NSTextField(wrappingLabelWithString: L("每家译文单独成文件，各自带上对应的原文。"))
            preview = NSTextField(labelWithString: "")
            super.init()
            choice.selected = CaptionExportRule.remembered == .byLane ? 0 : 1
            choice.onChange = { [weak self] _ in self?.refresh() }
            for hint in [laneHint, bindingHint, preview] {
                hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                hint.textColor = .secondaryLabelColor
                hint.preferredMaxLayoutWidth = 340
            }
            preview.lineBreakMode = .byTruncatingTail
            preview.maximumNumberOfLines = 2
        }

        var rule: CaptionExportRule { choice.selected == 0 ? .byLane : .byBinding }

        @objc func sourceToggled(_ sender: NSButton) {
            refresh()
        }

        func refresh() {
            laneHint.textColor = rule == .byLane ? .labelColor : .tertiaryLabelColor
            bindingHint.textColor = rule == .byBinding ? .labelColor : .tertiaryLabelColor
            let kept = Set(sourceBoxes.filter { $0.1.state == .on }.map(\.0))
            let names = CaptionExport.names(lanes: lanes, rule: rule, sourceLanes: kept)
            if names.isEmpty {
                preview.stringValue = L("这样设置导不出文件")
                preview.textColor = .systemOrange
            } else {
                let title = String(format: L("会导出 %@ 个文件"), String(names.count))
                preview.stringValue = "\(title)：\(names.prefix(2).joined(separator: "、"))\(names.count > 2 ? " …" : "")"
                preview.textColor = .tertiaryLabelColor
            }
        }
    }

    /// The names `files` would write, without building the SRT bodies — for the export sheet's preview.
    static func names(lanes: [Lane], rule: CaptionExportRule, sourceLanes: Set<String>) -> [String] {
        var out: [String] = []
        for lane in lanes {
            let laneStem = sanitized(lane.fileStem)
            let translating = lane.bindings.filter { !$0.isSource }
            let hasSourceBinding = lane.bindings.contains { $0.isSource }
            let wantsSource = sourceLanes.contains(lane.key)
            switch rule {
            case .byLane:
                let withSource = wantsSource || hasSourceBinding || translating.isEmpty
                let hasBody = lane.cues.contains { cue in
                    let texts = translating.compactMap { cue.translations[$0.key] }.filter { !$0.isEmpty }
                    return !Self.lines(cue, source: withSource, translations: texts).isEmpty
                }
                if hasBody { out.append("\(laneStem).srt") }
            case .byBinding:
                for binding in lane.bindings {
                    let hasBody = lane.cues.contains { cue in
                        if binding.isSource { return !cue.source.isEmpty || !Self.lines(cue, source: true, translations: []).isEmpty }
                        guard let tr = cue.translations[binding.key], !tr.isEmpty else { return false }
                        return true
                    }
                    if hasBody { out.append("\(laneStem).\(sanitized(LaneBindingNames.fileStem(binding))).srt") }
                }
            }
        }
        return out
    }

    static func files(base: String, lanes: [Lane], rule: CaptionExportRule, sourceLanes: Set<String>) -> [CaptionLaneFile] {
        var out: [CaptionLaneFile] = []
        for lane in lanes {
            let laneStem = sanitized(lane.fileStem)
            let translating = lane.bindings.filter { !$0.isSource }
            let hasSourceBinding = lane.bindings.contains { $0.isSource }
            let wantsSource = sourceLanes.contains(lane.key)
            switch rule {
            case .byLane:
                let withSource = wantsSource || hasSourceBinding || translating.isEmpty
                let body = lane.cues.compactMap { cue -> SRTCue? in
                    let texts = translating.compactMap { cue.translations[$0.key] }.filter { !$0.isEmpty }
                    let lines = Self.lines(cue, source: withSource, translations: texts)
                    return lines.isEmpty ? nil : SRTCue(start: cue.start, end: cue.end, lines: lines)
                }
                let text = SRTDocument.text(from: body)
                if !text.isEmpty { out.append(CaptionLaneFile(name: "\(base).\(laneStem).srt", text: text)) }
            case .byBinding:
                for binding in lane.bindings {
                    let stem = sanitized(LaneBindingNames.fileStem(binding))
                    let body = lane.cues.compactMap { cue -> SRTCue? in
                        if binding.isSource {
                            let lines = Self.lines(cue, source: true, translations: [])
                            return lines.isEmpty ? nil : SRTCue(start: cue.start, end: cue.end, lines: lines)
                        }
                        guard let tr = cue.translations[binding.key], !tr.isEmpty else { return nil }
                        let lines = Self.lines(cue, source: wantsSource, translations: [tr])
                        return SRTCue(start: cue.start, end: cue.end, lines: lines)
                    }
                    let text = SRTDocument.text(from: body)
                    if !text.isEmpty { out.append(CaptionLaneFile(name: "\(base).\(laneStem).\(stem).srt", text: text)) }
                }
            }
        }
        return out
    }

    private static func lines(_ cue: Cue, source: Bool, translations: [String]) -> [String] {
        let prefix = cue.mark.map { "\($0) " } ?? ""
        if source {
            guard !cue.source.isEmpty else { return translations }
            return [prefix + cue.source] + translations
        }
        guard let first = translations.first else { return [] }
        return [prefix + first] + translations.dropFirst()
    }

    static func write(_ files: [CaptionLaneFile], to folder: URL) throws -> [URL] {
        var urls: [URL] = []
        for file in files {
            let dest = folder.appendingPathComponent(file.name)
            try file.text.write(to: dest, atomically: true, encoding: .utf8)
            urls.append(dest)
        }
        return urls
    }

    static func sanitized(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = name.components(separatedBy: bad).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? L("翻译") : cleaned
    }
}

/// One caption as the batch delete sheet sees it.
struct CaptionBatchCue: Identifiable {
    var id: UUID
    var start: TimeInterval
    var end: TimeInterval
    var speaker: Int
    var mark: String
    var source: String
}

/// Picks captions to drop from one lane: by speaker, by a span of the recognition clock, or one by one.
/// Filters only narrow what is listed; the ticks are what gets deleted, so nothing off screen goes unseen.
struct CaptionBatchSheet: View {
    var cues: [CaptionBatchCue]
    var onDelete: (Set<UUID>) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID> = []
    /// `nil` 是所有说话人；`0` 是还没分出说话人的那些段。
    @State private var speaker: Int? = nil
    @State private var from = ""
    @State private var to = ""

    private var speakers: [Int] {
        var ids: [Int] = []
        for cue in cues where !ids.contains(cue.speaker) { ids.append(cue.speaker) }
        // 分好的人按编号排，没分出来的（0）放最后。
        return ids.sorted { a, b in
            if a == 0 { return false }
            if b == 0 { return true }
            return a < b
        }
    }

    private var fromTime: TimeInterval? { blank(from) ? nil : MediaClock.parse(from) }
    private var toTime: TimeInterval? { blank(to) ? nil : MediaClock.parse(to) }

    private func blank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var filterKey: String { "\(speaker.map(String.init) ?? "all")|\(from)|\(to)" }

    private var visible: [CaptionBatchCue] {
        cues.filter { cue in
            if let speaker, cue.speaker != speaker { return false }
            if let fromTime, cue.start < fromTime { return false }
            if let toTime, cue.start > toTime { return false }
            return true
        }
    }

    private var allVisibleSelected: Bool {
        !visible.isEmpty && visible.allSatisfy { selected.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(L("批量删除"))
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                Toggle(isOn: Binding(
                    get: { allVisibleSelected },
                    set: { on in
                        let ids = Set(visible.map(\.id))
                        if on { selected.formUnion(ids) } else { selected.subtract(ids) }
                    }
                )) {
                    Text(L("全选"))
                        .font(.system(size: 12))
                }
                .toggleStyle(.checkbox)
                .disabled(visible.isEmpty)
            }

            HStack(spacing: 8) {
                Text(L("说话人"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker(L("说话人"), selection: $speaker) {
                    Text(L("全部")).tag(Int?.none)
                    ForEach(speakers, id: \.self) { id in
                        Text(speakerLabel(id)).tag(Int?.some(id))
                    }
                }
                .labelsHidden()
                .frame(width: 132)
            }

            HStack(spacing: 8) {
                Text(L("时段"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("0:00:00", text: $from)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .well(radius: 6)
                    .frame(width: 88)
                Text("→")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                TextField(L("到末尾"), text: $to)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .well(radius: 6)
                    .frame(width: 88)
                if !blank(from) || !blank(to) {
                    IconButton(systemImage: "xmark.circle", help: L("清掉时段")) {
                        from = ""
                        to = ""
                    }
                }
                Spacer(minLength: 0)
                Text(String(format: L("%@ 段"), String(visible.count)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            if visible.isEmpty {
                Text(L("这个范围里没有字幕"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(visible) { cue in
                            row(cue)
                        }
                    }
                }
                .frame(height: 240)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.wellFill)
                }
            }

            HStack(spacing: 8) {
                Text(selected.isEmpty ? L("还没选") : String(format: L("已选 %@ 段"), String(selected.count)))
                    .font(.caption)
                    .foregroundStyle(selected.isEmpty ? .tertiary : .secondary)
                Spacer(minLength: 8)
                Button(L("取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(selected.isEmpty ? L("删除") : String(format: L("删除 %@ 段"), String(selected.count))) {
                    let ids = selected
                    onDelete(ids)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty)
            }
        }
        .padding(14)
        .frame(width: 420)
        .onChange(of: filterKey) { _, _ in
            selected.formIntersection(Set(visible.map(\.id)))
        }
    }

    private func speakerLabel(_ id: Int) -> String {
        guard id > 0 else { return L("未分说话人") }
        return cues.first { $0.speaker == id && !$0.mark.isEmpty }?.mark ?? String(format: L("说话人 %@"), String(id))
    }

    private func row(_ cue: CaptionBatchCue) -> some View {
        let on = selected.contains(cue.id)
        return Button {
            if on { selected.remove(cue.id) } else { selected.insert(cue.id) }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12))
                    .foregroundStyle(on ? Color.accentColor : Color.secondary)
                    .padding(.top, 1)
                Text(SRTDocument.stamp(cue.start))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    if !cue.mark.isEmpty {
                        Text(cue.mark)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    Text(cue.source)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(on ? Color.accentColor.opacity(0.08) : Color.clear)
        }
        .buttonStyle(.plain)
        .help(String(format: L("%@ → %@"), SRTDocument.stamp(cue.start), SRTDocument.stamp(cue.end)))
    }
}

struct SpeakerMarkList: View {
    var rows: [(id: Int, token: String)]
    var canDelete: Bool
    var onRename: (Int, String) -> Void
    var onDelete: (Int) -> Void
    var onDeleteAll: () -> Void
    var voices: [SpeakerVoice]? = nil
    var voiceID: ((Int) -> String?)? = nil
    var onVoice: ((Int, String?) -> Void)? = nil

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                SpeakerChipRow(
                    rows: rows,
                    canDelete: canDelete,
                    onRename: onRename,
                    onDelete: onDelete,
                    onDeleteAll: onDeleteAll,
                    voices: voices,
                    voiceID: voiceID,
                    onVoice: onVoice
                )
                if canDelete {
                    Button(L("全部删除")) { onDeleteAll() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
        }
    }
}

/// 「外观」那一组分段切换的 AppKit 版：灰底轨道，选中的一项浮一块白色滑块。
///
/// Finder 的保存面板里只能放 AppKit 视图，SwiftUI 的 `PillSegmented` 进不去，
/// 所以这里照它的配色、字号和圆角重画一份，两处的样子才对得上。
/// 尺寸也跟着它走：字号 11，水平内边距 12，垂直 3.3，轨道圆角 7、滑块圆角 5、外圈留 2。
@MainActor
final class PillChoice: NSView {
    private let titles: [String]
    private static let fontSize: CGFloat = 11
    private static let padX: CGFloat = fontSize + 1
    private static let padY: CGFloat = fontSize * 0.3
    private static let trackPad: CGFloat = 2

    /// 选中第几项。改它不会回调 `onChange`。
    var selected: Int = 0 {
        didSet {
            guard selected != oldValue else { return }
            needsDisplay = true
        }
    }

    var onChange: ((Int) -> Void)?
    private var widths: [CGFloat] = []

    init(titles: [String]) {
        self.titles = titles
        super.init(frame: .zero)
        widths = titles.map { title in
            let font = NSFont.systemFont(ofSize: Self.fontSize, weight: .semibold)
            let w = (title as NSString).size(withAttributes: [.font: font]).width
            return ceil(w) + Self.padX * 2
        }
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel(titles.joined(separator: " / "))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { return nil }

    override var isFlipped: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var textHeight: CGFloat {
        let font = NSFont.systemFont(ofSize: Self.fontSize, weight: .semibold)
        return ceil(((titles.first ?? "") as NSString).size(withAttributes: [.font: font]).height)
    }

    private var trackSize: NSSize {
        NSSize(
            width: widths.reduce(0, +) + Self.trackPad * 2,
            height: textHeight + Self.padY * 2 + Self.trackPad * 2
        )
    }

    override var intrinsicContentSize: NSSize { trackSize }

    /// 每一项的横向范围，从轨道左边算起。
    private func segmentRanges() -> [(CGFloat, CGFloat)] {
        var x = Self.trackPad
        return widths.map { w in
            let range = (x, w)
            x += w
            return range
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSBezierPath(
            roundedRect: NSRect(origin: .zero, size: trackSize),
            xRadius: 7, yRadius: 7
        )
        NSColor.labelColor.withAlphaComponent(0.07).setFill()
        track.fill()

        let ranges = segmentRanges()
        guard selected >= 0, selected < ranges.count else { return }
        let (x, w) = ranges[selected]
        let thumbRect = NSRect(
            x: x, y: Self.trackPad,
            width: w, height: trackSize.height - Self.trackPad * 2
        )
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.14)
        shadow.shadowBlurRadius = 1
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.set()
        let thumb = NSBezierPath(roundedRect: thumbRect, xRadius: 5, yRadius: 5)
        Self.cardFill.setFill()
        thumb.fill()
        NSGraphicsContext.restoreGraphicsState()

        for (i, title) in titles.enumerated() {
            let font = NSFont.systemFont(
                ofSize: Self.fontSize, weight: i == selected ? .semibold : .regular
            )
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: i == selected ? NSColor.labelColor : NSColor.secondaryLabelColor,
            ]
            let size = (title as NSString).size(withAttributes: attrs)
            let seg = ranges[i]
            let point = NSPoint(
                x: seg.0 + (seg.1 - size.width) / 2,
                y: (trackSize.height - size.height) / 2
            )
            (title as NSString).draw(at: point, withAttributes: attrs)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let ranges = segmentRanges()
        guard let idx = ranges.firstIndex(where: { point.x >= $0.0 && point.x < $0.0 + $0.1 }) else { return }
        guard idx != selected else { return }
        selected = idx
        onChange?(idx)
    }

    /// 和 `Theme.cardFill` 同一对颜色：浅色白、深色 #2A2A2F。
    private static let cardFill = NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let hex: UInt32 = dark ? 0x2A2A2F : 0xFFFFFF
        return NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
