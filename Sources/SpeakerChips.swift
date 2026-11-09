import SwiftUI

/// One stable hue per speaker number, so 藤崎 keeps the same color across rows and windows.
enum SpeakerPalette {
    static let colors: [Color] = [.blue, .orange, .purple, .teal, .pink, .indigo, .green, .brown]

    static func color(for speaker: Int) -> Color {
        guard speaker > 0 else { return .secondary }
        return colors[(speaker - 1) % colors.count]
    }
}

enum SpeakerMarkText {
    /// Marks are stored with brackets for SRT export; on screen the bracket comes off.
    static func display(_ token: String) -> String {
        var text = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("[") { text.removeFirst() }
        if text.hasSuffix("]") { text.removeLast() }
        return text.trimmingCharacters(in: .whitespaces)
    }
}

/// A speaker's name as a colored capsule.
struct SpeakerChip: View {
    var speaker: Int
    var token: String

    var body: some View {
        let hue = SpeakerPalette.color(for: speaker)
        Text(SpeakerMarkText.display(token))
            .font(Theme.TypeScale.micro)
            .foregroundStyle(hue)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule(style: .continuous).fill(hue.opacity(0.16)))
            .fixedSize()
    }
}

/// A chip you can click to rename. Deleting is offered only when the caller allows it.
struct SpeakerChipButton: View {
    var speaker: Int
    var token: String
    var canDelete: Bool
    var onRename: (String) -> Void
    var onDelete: () -> Void
    /// The lane's other speakers. Empty hides 「并入」.
    var others: [(id: Int, token: String)] = []
    var onMerge: ((Int) -> Void)?
    /// Voices this person can be read in, for the language of the line being read. Nil hides the picker.
    var voices: [SpeakerVoice]? = nil
    /// The voice assigned to this person, or nil for the usual one.
    var voiceID: String? = nil
    var onVoice: ((String?) -> Void)? = nil
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        Button {
            draft = SpeakerMarkText.display(token)
            editing = true
        } label: {
            SpeakerChip(speaker: speaker, token: token)
        }
        .buttonStyle(.plain)
        .help(chipHelp)
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                TextField("", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.TypeScale.label)
                    .frame(width: 168)
                    .focused($focused)
                    .onSubmit(commit)
                HStack(spacing: 8) {
                    if canDelete {
                        Button(L("删除"), role: .destructive) {
                            onDelete()
                            editing = false
                        }
                        .controlSize(.small)
                    }
                    if let onMerge, !others.isEmpty {
                        Menu(L("并入…")) {
                            ForEach(others, id: \.id) { other in
                                Button(SpeakerMarkText.display(other.token)) {
                                    onMerge(other.id)
                                    editing = false
                                }
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .controlSize(.small)
                        .help(L("认成了两个人时，把这一位的话都算给另一位"))
                    }
                    Spacer(minLength: 0)
                    Button(L("完成"), action: commit)
                        .controlSize(.small)
                        .keyboardShortcut(.defaultAction)
                }
                if let voices, let onVoice {
                    voicePicker(voices, onVoice: onVoice)
                }
            }
            .padding(12)
            .onAppear { focused = true }
        }
    }

    private func commit() {
        onRename(draft)
        editing = false
    }

    private var chipHelp: String {
        guard voices != nil else { return L("点一下改名") }
        if let voiceID, let title = SpeakerVoice.title(for: voiceID) {
            return String(format: L("点一下改名，朗读用 %@"), title)
        }
        return L("点一下改名，也可以换朗读的声音")
    }

    /// 这一位用哪把声音读。没指定就用默认的那一把。下拉框，不用再点一层几乎看不见的菜单。
    private func voicePicker(_ voices: [SpeakerVoice], onVoice: @escaping (String?) -> Void) -> some View {
        let stored = voiceID ?? ""
        let current = SpeakerVoice.title(for: stored)
        let services = voices.map(\.service).filter { !$0.isEmpty }.reduce(into: [String]()) { list, service in
            if !list.contains(service) { list.append(service) }
        }
        return VStack(alignment: .leading, spacing: 4) {
            Picker(L("朗读"), selection: Binding(
                get: { stored },
                set: { onVoice($0.isEmpty ? nil : $0) }
            )) {
                Text(SpeakerVoice.defaultTitle()).tag("")
                if !voices.isEmpty {
                    Section(L("系统语音")) {
                        ForEach(voices.filter { $0.service.isEmpty }) { voice in
                            Text(voice.name).tag(voice.id)
                        }
                    }
                    ForEach(services, id: \.self) { service in
                        Section(service) {
                            ForEach(voices.filter { $0.service == service }) { voice in
                                Text(voice.name).tag(voice.id)
                            }
                        }
                    }
                }
            }
            .pickerStyle(.menu)
            .frame(width: 220, alignment: .leading)
            if !stored.isEmpty, current == nil {
                Text(L("这把声音已经不在了"))
                    .font(.caption)
                    .foregroundStyle(Theme.attention)
            }
        }
    }
}

/// Wraps its children onto as many rows as the width needs.
struct ChipFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > 0, x + spacing + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            rowHeight = max(rowHeight, size.height)
            x += (x > 0 ? spacing : 0) + size.width
        }
        return CGSize(width: proposal.width ?? x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }

        // Lay the rows out first, so every chip in a row shares that row's height.
        // Centering against a height still being accumulated lifts the first chip of each row.
        var rows: [[Int]] = [[]]
        var rowWidths: [CGFloat] = [0]
        for (index, size) in sizes.enumerated() {
            let width = rowWidths[rowWidths.count - 1]
            let extra = width > 0 ? spacing + size.width : size.width
            if width > 0, width + extra > bounds.width {
                rows.append([index])
                rowWidths.append(size.width)
            } else {
                rows[rows.count - 1].append(index)
                rowWidths[rowWidths.count - 1] = width + extra
            }
        }

        var y = bounds.minY
        for row in rows {
            let rowHeight = row.map { sizes[$0].height }.max() ?? 0
            var x = bounds.minX
            for (slot, index) in row.enumerated() {
                let size = sizes[index]
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (rowHeight - size.height) / 2),
                    proposal: ProposedViewSize(width: size.width, height: size.height)
                )
                x += size.width + (slot < row.count - 1 ? spacing : 0)
            }
            y += rowHeight + spacing
        }
    }
}

/// All of a lane's speakers, as chips. Renaming is a click; deleting is in the chip's popover.
struct SpeakerChipRow: View {
    var rows: [(id: Int, token: String)]
    var canDelete: Bool
    var onRename: (Int, String) -> Void
    var onDelete: (Int) -> Void
    var onDeleteAll: () -> Void
    var onMerge: ((Int, Int) -> Void)?
    /// Voices offered for each person. Nil hides the picker.
    var voices: [SpeakerVoice]? = nil
    var voiceID: ((Int) -> String?)? = nil
    var onVoice: ((Int, String?) -> Void)? = nil

    var body: some View {
        if !rows.isEmpty {
            ChipFlow(spacing: 6) {
                ForEach(rows, id: \.id) { row in
                    SpeakerChipButton(
                        speaker: row.id,
                        token: row.token,
                        canDelete: canDelete,
                        onRename: { onRename(row.id, $0) },
                        onDelete: { onDelete(row.id) },
                        others: onMerge == nil ? [] : rows.filter { $0.id != row.id },
                        onMerge: onMerge.map { merge in { merge(row.id, $0) } },
                        voices: voices,
                        voiceID: voiceID?(row.id),
                        onVoice: onVoice.map { pick in { pick(row.id, $0) } }
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
