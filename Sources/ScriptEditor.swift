import AppKit
import SwiftUI

/// 划词插件里写 JavaScript 的输入框：等宽字，按语法上色，回车自动缩进。
///
/// 不做真正的语法分析 —— 只是按顺序认注释、字符串、关键字、数字、函数名，
/// 先用注释和字符串把整段「吃掉」，关键字就不会跑到字符串里被染错色。
struct ScriptEditor: NSViewRepresentable {
    @Binding var text: String

    static let fontSize: CGFloat = 12

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        UIChrome.configure(scroll)

        let tv = CodeTextView()
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isEditable = true
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.backgroundColor = .clear
        tv.textContainerInset = NSSize(width: 6, height: 7)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        tv.delegate = context.coordinator

        // 代码里别自动替换引号、破折号，也别被拼写检查画红线。
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.usesFindBar = true

        let base = ScriptHighlighter.baseFont()
        tv.font = base
        tv.typingAttributes = ScriptHighlighter.baseAttributes()
        tv.defaultParagraphStyle = ScriptHighlighter.paragraphStyle()
        tv.string = text
        ScriptHighlighter.apply(tv)

        scroll.documentView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        guard tv.string != text else { return }
        let selected = tv.selectedRanges
        tv.string = text
        tv.selectedRanges = selected.filter { $0.rangeValue.location <= (text as NSString).length }
        tv.typingAttributes = ScriptHighlighter.baseAttributes()
        ScriptHighlighter.apply(tv)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ScriptEditor
        /// 上色时会动属性，别让那次改动又触发一遍上色。
        private var highlighting = false

        init(_ parent: ScriptEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            guard !highlighting else { return }
            highlighting = true
            ScriptHighlighter.apply(tv)
            highlighting = false
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            let ns = textView.string as NSString
            let lineStart = ns.lineRange(for: NSRange(location: textView.selectedRange().location, length: 0)).location
            let head = ns.substring(with: NSRange(location: lineStart, length: textView.selectedRange().location - lineStart))
            let indent = String(head.prefix { $0 == " " || $0 == "\t" })
            let extra = head.trimmingCharacters(in: .whitespaces)
            let opens = extra.hasSuffix("{") || extra.hasSuffix("[") || extra.hasSuffix("(")
            textView.insertText("\n" + indent + (opens ? "    " : ""), replacementRange: textView.selectedRange())
            return true
        }
    }
}

/// NSTextView 的一个小调整：粘贴进来的东西一律按纯文本写进去，保留等宽字。
final class CodeTextView: NSTextView {
    override func paste(_ sender: Any?) {
        guard let raw = NSPasteboard.general.string(forType: .string) else { return }
        insertText(raw, replacementRange: selectedRange())
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // 深浅色切换时系统色会自己变，但已经画上去的属性文字要重新算一遍。
        ScriptHighlighter.apply(self)
    }
}

enum ScriptHighlighter {
    /// 一条正则认完全部：注释 → 字符串 → 关键字 → 数字 → 函数名。
    /// 顺序就是优先级，注释和字符串先占住自己的地盘。
    private static let pattern: String = [
        #"//[^\n]*"#,
        #"/\*[\s\S]*?\*/"#,
        #""(?:\\.|[^"\\\n])*""#,
        #"'(?:\\.|[^'\\\n])*'"#,
        #"`(?:\\.|[^`\\])*`"#,
        #"\b(?:const|let|var|function|return|if|else|for|while|do|switch|case|break|continue|new|delete|typeof|instanceof|in|of|class|extends|super|this|try|catch|finally|throw|await|async|yield|true|false|null|undefined|void)\b"#,
        #"\b\d+(?:\.\d+)?\b"#,
        #"\b[A-Za-z_$][\w$]*(?=\s*\()"#,
    ].joined(separator: "|")

    private static let regex = try? NSRegularExpression(pattern: pattern, options: [])

    private enum Kind {
        case comment, string, keyword, number, call
    }

    private static func color(_ kind: Kind) -> NSColor {
        switch kind {
        case .comment: return .secondaryLabelColor
        case .string: return .systemRed
        case .keyword: return .systemPink
        case .number: return .systemBlue
        case .call: return .systemTeal
        }
    }

    /// 等宽字，行距放大一点，长脚本才不挤成一块。
    static func baseFont() -> NSFont {
        NSFont.monospacedSystemFont(ofSize: ScriptEditor.fontSize, weight: .regular)
    }

    static func paragraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.28
        style.tabStops = []
        style.defaultTabInterval = ScriptEditor.fontSize * 2.6
        return style
    }

    static func baseAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: baseFont(),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle(),
        ]
    }

    /// 重刷全篇。只在真正的编辑之后调用，几百行的脚本一次也就毫秒级。
    static func apply(_ tv: NSTextView) {
        guard let storage = tv.textStorage else { return }
        let text = storage.string as NSString
        let full = NSRange(location: 0, length: text.length)
        guard full.length > 0, let regex else {
            tv.setNeedsDisplay(tv.bounds)
            return
        }

        let selection = tv.selectedRanges

        storage.beginEditing()
        storage.setAttributes(baseAttributes(), range: full)
        regex.enumerateMatches(in: storage.string, options: [], range: full) { match, _, _ in
            guard let match, let kind = kind(of: text.substring(with: match.range)) else { return }
            storage.addAttribute(.foregroundColor, value: color(kind), range: match.range)
        }
        storage.endEditing()

        tv.selectedRanges = selection
        // 光标后继续敲的字要回到正文色，不跟着上一段的颜色走。
        tv.typingAttributes = baseAttributes()
        tv.setNeedsDisplay(tv.bounds)
    }

    private static func kind(of token: String) -> Kind? {
        guard let first = token.first else { return nil }
        if token.hasPrefix("//") || token.hasPrefix("/*") { return .comment }
        if first == "\"" || first == "'" || first == "`" { return .string }
        if first.isNumber { return .number }
        if first.isLetter || first == "_" || first == "$" {
            // 函数名和关键字长得一样，看它是不是在关键字表里就能分开。
            return keywords.contains(token) ? .keyword : .call
        }
        return nil
    }

    private static let keywords: Set<String> = [
        "const", "let", "var", "function", "return", "if", "else", "for", "while",
        "do", "switch", "case", "break", "continue", "new", "delete", "typeof",
        "instanceof", "in", "of", "class", "extends", "super", "this", "try",
        "catch", "finally", "throw", "await", "async", "yield", "true", "false",
        "null", "undefined", "void",
    ]
}
