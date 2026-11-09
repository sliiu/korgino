import AppKit
import SwiftUI

struct SessionNoteSlot: Equatable {
    var open = false
    var writing = false
    var page: SessionNotePage?
    var error = ""
    var generation = 0
    /// Opened while listening: the page is rewritten as new segments settle.
    var follow = false
    /// Last time a page was asked for, written or not. Keeps a failing AI from being called every segment.
    var attemptedAt: Date?
}

struct SessionNoteFailure: Error {
    var message: String
}

/// One call shared by 实时字幕、媒体字幕 and 会议记录.
enum SessionNoteWriter {
    @MainActor
    static func write(_ brief: SessionNoteBrief) async -> Result<SessionNotePage, SessionNoteFailure> {
        guard brief.hasCue else { return .failure(SessionNoteFailure(message: L("笔记没有写成"))) }
        guard let profile = AppConfig.shared.sessionNoteProfile(preferredID: brief.serviceID) else {
            return .failure(SessionNoteFailure(message: L("没有可用来写笔记的 AI")))
        }
        let language = AppConfig.shared.nativeLanguage.resolvedDestination.promptName
        do {
            let reply = try await Translator.sessionNote(brief.transcript, profile: profile, languageName: language)
            guard let page = SessionNote.page(reply, brief: brief) else {
                return .failure(SessionNoteFailure(message: L("笔记没有写成")))
            }
            return .success(page)
        } catch {
            let message = error.localizedDescription
            return .failure(SessionNoteFailure(
                message: SessionNote.rejectedForLength(message) ? L("这场太长，笔记没有写成") : message
            ))
        }
    }
}

struct SessionNoteCard: View {
    var title: String = L("一场笔记")
    var page: SessionNotePage?
    var writing: Bool
    var error: String
    /// Shown under the title while the page keeps up with the captions.
    var following = false
    var maxHeight: CGFloat? = 280
    var onJump: ((String) -> Void)?
    var onRewrite: (() -> Void)?
    var onClose: (() -> Void)?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                if let stamp = stampLine {
                    Text(stamp)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if writing {
                    ProgressView()
                        .controlSize(.small)
                    Text(page == nil ? L("正在写笔记") : L("正在更新"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let onRewrite, !writing {
                    IconButton(systemImage: "arrow.clockwise", help: L("重写"), size: 11, action: onRewrite)
                }
                if page != nil {
                    IconButton(systemImage: copied ? "checkmark" : "doc.on.doc", help: L("复制"), size: 11) {
                        copy()
                    }
                }
                if let onClose {
                    IconButton(systemImage: "xmark", help: L("关闭"), size: 11, action: onClose)
                }
            }
            if !error.isEmpty {
                ErrorLine(text: error)
            }
            if let page {
                ScrollView {
                    content(page)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: maxHeight ?? .infinity)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .onChange(of: page) { _, _ in copied = false }
    }

    private var stampLine: String? {
        guard let written = page?.writtenAt else { return following ? L("跟着字幕更新") : nil }
        let time = written.formatted(date: .omitted, time: .shortened)
        return following
            ? String(format: L("%@ 更新 · 跟着字幕更新"), time)
            : String(format: L("%@ 写成"), time)
    }

    private func content(_ page: SessionNotePage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            section(L("这场在说什么")) {
                Text(page.summary.isEmpty ? L("没有") : page.summary)
                    .font(.system(size: 13))
                    .foregroundStyle(page.summary.isEmpty ? Color.secondary : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            itemSection(L("议题"), page.topics, symbol: "number")
            itemSection(L("结论"), page.decisions, symbol: "checkmark.seal")
            itemSection(L("待办"), page.todos, symbol: "circle")
            terms(page.terms)
            unmatched(page.unmatched)
        }
    }

    private func section<Body: View>(_ title: String, @ViewBuilder body: () -> Body) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            body()
        }
    }

    private func itemSection(_ title: String, _ items: [SessionNoteItem], symbol: String) -> some View {
        section(title) {
            if items.isEmpty {
                Text(L("没有"))
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        itemRow(item, symbol: symbol)
                    }
                }
            }
        }
    }

    private func itemRow(_ item: SessionNoteItem, symbol: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 12)
            Text(item.text)
                .font(.system(size: 12.5))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let onJump, let first = item.cues.first {
                Button {
                    onJump(first)
                } label: {
                    Image(systemName: "text.quote")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .help(item.cues.count > 1
                    ? String(format: L("跳到原话（共 %@ 处）"), String(item.cues.count))
                    : L("跳到原话"))
            }
        }
    }

    private func terms(_ terms: [SessionNoteTerm]) -> some View {
        section(L("反复出现的词")) {
            if terms.isEmpty {
                Text(L("没有"))
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(Array(terms.enumerated()), id: \.offset) { _, term in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(term.word)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                        Text(term.rendering)
                            .font(.system(size: 13))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func unmatched(_ lines: [String]) -> some View {
        section(L("没对上的地方")) {
            if lines.isEmpty {
                Text(L("没有"))
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func copy() {
        guard let page else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(page.copyText(), forType: .string)
        copied = true
    }
}
