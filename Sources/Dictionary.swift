import AppKit
import Combine
import SwiftUI

@MainActor
final class DictionaryController: ObservableObject {
    static let shared = DictionaryController()

    @Published var query = ""
    @Published var loading = false
    @Published var entry: DictionaryEntry?
    @Published var errorText: String?
    @Published var statusLine = L("输入单词或短语后查询")

    private var task: Task<Void, Never>?

    func show(seed: String? = nil) {
        if let seed, !seed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            query = seed.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if query.isEmpty, let clip = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines), DictionaryLookup.isLookupCandidate(clip) {
            query = clip
        }
        MainWindowController.shared.show(page: .dictionary)
        if !query.isEmpty { lookup() }
    }

    func lookup() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        task?.cancel()
        loading = true
        errorText = nil
        entry = nil
        statusLine = L("查询中…")
        task = Task { @MainActor in
            do {
                let e = try await Background.run {
                    try await DictionaryLookup.lookup(q)
                }
                guard !Task.isCancelled else { return }
                entry = e
                loading = false
                statusLine = "\(e.word)\(e.phonetic.map { " · \($0)" } ?? "")"
            } catch {
                guard !Task.isCancelled else { return }
                loading = false
                entry = nil
                errorText = error.localizedDescription
                statusLine = L("查询失败")
            }
        }
    }

    func relocalize() {}
}

struct DictionaryView: View {
    @ObservedObject var model: DictionaryController
    @EnvironmentObject private var config: AppConfig

    var body: some View {
        let _ = config.appLanguage
        VStack(alignment: .leading, spacing: 0) {
            searchField
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 10)
            Divider()
            Group {
                if model.loading {
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = model.errorText {
                    ContentUnavailableView(L("查询失败"), systemImage: "exclamationmark.magnifyingglass", description: Text(err))
                } else if let entry = model.entry {
                    ScrollView {
                        entryBody(entry)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "character.book.closed")
                            .font(.system(size: 26, weight: .light))
                            .foregroundStyle(.tertiary)
                        Text(L("输入单词或短语后查询"))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.cardFill)
        }
        .frame(minWidth: 360, minHeight: 320)
        .controlSize(.regular)
    }

    private var searchField: some View {
        SearchField(text: $model.query, prompt: L("单词 / 短语"), fontSize: 14) { model.lookup() }
    }

    private func entryBody(_ entry: DictionaryEntry) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.word)
                        .font(.system(size: entry.word.count > 16 ? 18 : 28, weight: .semibold, design: .serif))
                        .lineLimit(4)
                        .textSelection(.enabled)
                    SpeakButton(text: entry.word, language: DictSpeech.language(entry.word), help: L("朗读"), tag: "dict.\(entry.word)", size: 13)
                }
                if let ph = entry.phonetic, !ph.isEmpty {
                    Text(ph)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(entry.sections) { section in
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(section.title)
                    if let ph = section.phonetic, !ph.isEmpty, ph != entry.phonetic {
                        Text(ph)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(section.senses.enumerated()), id: \.element.id) { i, s in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(i + 1)")
                                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .frame(width: 16, alignment: .trailing)
                            senseBody(s, size: 14, exampleSize: 13)
                        }
                    }
                }
            }
        }
    }
}

private struct SenseBody: View {
    let sense: DictionarySense
    var size: CGFloat
    var exampleSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !sense.partOfSpeech.isEmpty {
                PartOfSpeechTag(text: sense.partOfSpeech)
            }
            Text(sense.definition)
                .font(.system(size: size))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let original = sense.original, !original.isEmpty {
                Text(original)
                    .font(.system(size: exampleSize))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let ex = sense.example, !ex.isEmpty {
                ExampleQuote(text: ex, size: exampleSize)
            }
        }
    }
}

private func senseBody(_ sense: DictionarySense, size: CGFloat, exampleSize: CGFloat) -> some View {
    SenseBody(sense: sense, size: size, exampleSize: exampleSize)
}

private struct PartOfSpeechTag: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .italic()
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
    }
}

private struct ExampleQuote: View {
    let text: String
    var size: CGFloat
    var body: some View {
        Text(text)
            .font(.system(size: size))
            .italic()
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 8)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1).fill(Color.primary.opacity(0.15)).frame(width: 2)
            }
    }
}

/// Compact dictionary block for the translate popup.
struct PopupDictionarySection: View {
    let entry: DictionaryEntry?
    let loading: Bool
    let error: String?
    @Binding var expanded: Bool
    @Binding var query: String
    var onSubmit: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func toggleExpanded() {
        if reduceMotion {
            expanded.toggle()
        } else {
            withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
            Button(action: toggleExpanded) {
                HStack(spacing: 6) {
                    Image(systemName: "character.book.closed")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    if let entry {
                        Text(entry.word).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        if let ph = entry.phonetic, !ph.isEmpty {
                            Text(ph).font(.system(size: 11)).foregroundStyle(.tertiary)
                        }
                    } else {
                        SectionHeader(L("词典"))
                    }
                    if loading { ProgressView().controlSize(.mini) }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let entry {
                SpeakButton(text: entry.word, language: DictSpeech.language(entry.word), help: L("朗读"), tag: "dict.\(entry.word)")
            }
            Button(action: toggleExpanded) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            }
            if expanded {
                SearchField(text: $query, prompt: L("单词 / 短语"), fontSize: 12, onSubmit: onSubmit)
                if let error, !error.isEmpty, !loading {
                    ErrorLine(text: error)
                } else if let entry {
                    ForEach(entry.sections) { section in
                        VStack(alignment: .leading, spacing: 4) {
                            SectionHeader(section.title)
                            ForEach(section.senses.prefix(entry.sections.count > 1 ? 2 : 4)) { s in
                                VStack(alignment: .leading, spacing: 4) {
                                    senseBody(s, size: 12, exampleSize: 11)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .card(fill: Theme.cardFill.opacity(min(1, max(0.35, AppConfig.shared.panelOpacity))))
    }
}

enum DictSpeech {
    /// 词条多是英文，单个词按文本猜常猜错；全是拉丁字母就按英文读。
    static func language(_ word: String) -> String? {
        word.unicodeScalars.allSatisfy { $0.isASCII } ? "en" : nil
    }
}
