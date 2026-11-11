import AppKit
import SwiftUI

struct MaskDeclined: LocalizedError, Sendable {
    var errorDescription: String? { "已取消" }
}

/// 命中之后，把将要发出的文本给人看：遮了什么、发到哪里，还可以选择直接发原文。
///
/// 同一段遮盖文本已经确认过，就不再问；但「发原文」的选择不记 —— 每次发原文都该是明确的。
enum MaskSendConfirm {
    private static let lock = NSLock()
    /// 上次确认过的遮盖文本和选择。只记遮盖版，免得误判之后每次都被问一遍。
    private static var lastMasked: String?

    /// - Parameters:
    ///   - masked: 真正要发出去的、已经换成占位符的文本。
    ///   - original: 遮盖前的原文，选「发送原文」时用它。
    ///   - hits: 每一处命中的类别，用来写清遮了什么。
    ///   - destination: 发给谁，例如「OpenAI（api.openai.com）」。
    /// - Returns: `.masked` 发送遮盖版，`.original` 发送原文。
    /// - Throws: `MaskDeclined` 当用户取消。
    @MainActor
    static func ask(
        masked: String,
        original: String,
        hits: [MaskHit],
        destination: String
    ) throws -> MaskChoice {
        lock.lock()
        let seen = lastMasked == masked
        lock.unlock()
        if seen { return .masked }

        let kinds = orderedLabels(hits)
        let preview = masked.count > 12000 ? String(masked.prefix(12000)) + "\n…" : masked

        let box = ChoiceBox()
        let window = MaskConfirmWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 420),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true

        let choose: (MaskChoice?) -> Void = { choice in
            guard box.choice == nil else { return }
            box.choice = choice
            NSApp.stopModal(withCode: choice == nil ? .cancel : .OK)
            window.orderOut(nil)
        }
        let host = NSHostingView(rootView: MaskConfirmView(
            preview: preview,
            hitsLine: kinds.isEmpty ? "" : String(format: L("命中：%@"), kinds),
            destinationLine: destination.isEmpty ? "" : String(format: L("发往：%@"), destination),
            hits: hits,
            choose: choose
        ))
        window.onCancel = { choose(nil) }
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.setContentSize(host.fittingSize)
        window.center()

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        _ = NSApp.runModal(for: window)
        window.orderOut(nil)

        guard let choice = box.choice else { throw MaskDeclined() }
        switch choice {
        case .masked:
            lock.lock()
            lastMasked = masked
            lock.unlock()
        case .original:
            // 发原文不算「确认过遮盖版」，下次命中还得再问。
            break
        }
        return choice
    }

    /// 命中的类别去重后按出现顺序排成一句话。
    private static func orderedLabels(_ hits: [MaskHit]) -> String {
        var seen = Set<String>()
        var out: [String] = []
        for hit in hits {
            let label = hit.label
            guard seen.insert(label).inserted else { continue }
            out.append(label)
        }
        return out.prefix(4).joined(separator: "、") + (out.count > 4 ? "…" : "")
    }
}

/// 模态期间存选择。窗口关掉时还空着，就当取消。
private final class ChoiceBox: @unchecked Sendable {
    var choice: MaskChoice?
}

@MainActor
private final class MaskConfirmWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    /// Esc 走取消。
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

private struct MaskConfirmView: View {
    let preview: String
    let hitsLine: String
    let destinationLine: String
    let hits: [MaskHit]
    let choose: (MaskChoice?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield")
                    .font(Theme.TypeScale.title)
                    .foregroundStyle(Theme.attention)
                Text(L("将要发送的内容里有私密信息"))
                    .font(Theme.TypeScale.title)
            }

            VStack(alignment: .leading, spacing: 3) {
                if !hitsLine.isEmpty { line(hitsLine, strong: true) }
                if !destinationLine.isEmpty { line(destinationLine, strong: false) }
            }

            if !hits.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(format: L("被替换的内容（%d 处）"), hits.count))
                        .font(Theme.TypeScale.caption).fontWeight(.medium)
                        .foregroundStyle(.secondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(hits.enumerated()), id: \.offset) { _, hit in
                                hitRow(hit)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: hits.count > 6 ? 96 : .infinity)
                }
            }

            Text(L("发出去的会换成占位符，结果回来后自动填回原文。判断错了可以选「发送原文」。"))
                .font(Theme.TypeScale.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                Text(preview)
                    .font(Theme.TypeScale.label.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 200)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: Theme.smallRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.smallRadius)
                    .strokeBorder(Color.primary.opacity(0.15))
            )

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(L("取消")) { choose(nil) }
                    .keyboardShortcut(.cancelAction)
                Button(L("发送原文")) { choose(.original) }
                Button(L("发送脱敏版")) { choose(.masked) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
        }
        .padding(20)
        .frame(width: 540, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.panelRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.panelRadius)
                .strokeBorder(Color.primary.opacity(0.12))
        )
    }

    /// 一处命中：类别标签 + 原文。原文截断到 160 字，整行可选可复制。
    private func hitRow(_ hit: MaskHit) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(hit.label)
                .font(Theme.TypeScale.micro)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(
                    Capsule().fill(Theme.attention.opacity(0.18))
                )
                .fixedSize()
            Text(Self.clip(hit.value))
                .font(Theme.TypeScale.caption.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    /// 换行压成空格，太长就留头留尾。
    private static func clip(_ value: String) -> String {
        let flat = value.replacingOccurrences(of: "\n", with: "⏎")
        guard flat.count > 160 else { return flat }
        return String(flat.prefix(90)) + " … " + String(flat.suffix(60))
    }

    private func line(_ text: String, strong: Bool) -> some View {
        Text(text)
            .font(strong ? Theme.TypeScale.labelMedium : Theme.TypeScale.label)
            .foregroundStyle(strong ? Color.primary : Color.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}
