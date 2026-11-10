import AppKit
import SwiftUI

enum MarkdownTextUtil {
    /// Render markdown → plain text (strips formatting markers).
    static func plain(_ markdown: String) -> String {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        if let attr = try? AttributedString(markdown: markdown, options: opts) {
            return String(attr.characters)
        }
        return markdown
    }

    static func copyMarkdown(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    static func copyPlain(_ markdown: String) {
        copyMarkdown(plain(markdown))
    }

    /// Heuristic: looks like markdown worth previewing.
    static func looksLikeMarkdown(_ text: String) -> Bool {
        if text.contains("```") { return true }
        if text.contains("|") && text.contains("\n") { return true }
        let patterns = ["**", "__", "* ", "- ", "# ", "> ", "`", "[", "]("]
        return patterns.contains { text.contains($0) }
    }
}

/// Compact AttributedString markdown preview for popup / lists.
struct InlineMarkdownText: View {
    let text: String
    var font: Font = Theme.TypeScale.reading
    var weight: Font.Weight? = nil

    var body: some View {
        Group {
            if let attributed = try? AttributedString(
                markdown: text,
                options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
            ) {
                Text(attributed)
                    .font(font).fontWeight(weight)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(text)
                    .font(font).fontWeight(weight)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Primary click copies full Markdown「复制（包含格式）」; chevron menu offers plain text.
struct CopyMarkdownMenu: View {
    let id: String
    let text: String
    @Binding var copiedID: String?

    private var copied: Bool {
        copiedID == id || copiedID == id + ".plain"
    }

    var body: some View {
        IconButton(
            icon: copied ? .check : .copy,
            help: L("复制完整内容（含 Markdown 格式）；右键可复制纯文本"),
            tint: copied ? Theme.ok : nil,
            size: 11
        ) {
            MarkdownTextUtil.copyMarkdown(text)
            markCopied(id)
        }
        .contextMenu {
            Button(L("复制（包含格式）")) {
                MarkdownTextUtil.copyMarkdown(text)
                markCopied(id)
            }
            Button(L("复制纯文本")) {
                MarkdownTextUtil.copyPlain(text)
                markCopied(id + ".plain")
            }
        }
    }

    private func markCopied(_ key: String) {
        copiedID = key
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copiedID == key { copiedID = nil }
        }
    }
}
