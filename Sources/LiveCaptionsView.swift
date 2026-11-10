import AppKit
import SwiftUI

/// Latest-line follow flag. A class so a scroll already queued can see a drag that started after it was queued.
final class CaptionFollow: ObservableObject {
    @Published var stick = true
    @Published var userScrolling = false
}


/// Reports user scrolling only. Programmatic `scrollTo` does not post live-scroll notifications,
/// so a new caption line can follow the bottom without treating that jump as the user letting go.
struct LiveScrollPin: NSViewRepresentable {
    /// `active` is true from the start of a drag or wheel gesture until it ends. `atBottom` is the scroller position.
    var onUserScroll: (_ active: Bool, _ atBottom: Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onUserScroll: onUserScroll) }

    func makeNSView(context: Context) -> PinView {
        let view = PinView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: PinView, context: Context) {
        context.coordinator.onUserScroll = onUserScroll
        nsView.coordinator = context.coordinator
        nsView.attachIfNeeded()
    }

    final class PinView: NSView {
        var coordinator: Coordinator?
        private var attachAttempts = 0

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attachIfNeeded()
        }

        func attachIfNeeded() {
            guard let scroll = enclosingScrollView else {
                guard attachAttempts < 5 else { return }
                attachAttempts += 1
                DispatchQueue.main.async { [weak self] in self?.attachIfNeeded() }
                return
            }
            coordinator?.observe(scroll)
        }
    }

    final class Coordinator: NSObject {
        var onUserScroll: (Bool, Bool) -> Void
        private var scroll: NSScrollView?

        init(onUserScroll: @escaping (Bool, Bool) -> Void) { self.onUserScroll = onUserScroll }

        func observe(_ scroll: NSScrollView) {
            guard self.scroll !== scroll else { return }
            if let old = self.scroll {
                NotificationCenter.default.removeObserver(self, name: nil, object: old)
            }
            self.scroll = scroll
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(started), name: NSScrollView.willStartLiveScrollNotification, object: scroll)
            center.addObserver(self, selector: #selector(moved), name: NSScrollView.didLiveScrollNotification, object: scroll)
            center.addObserver(self, selector: #selector(ended), name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        }

        @objc private func started(_ note: Notification) { report(note, active: true) }
        @objc private func moved(_ note: Notification) { report(note, active: true) }
        @objc private func ended(_ note: Notification) { report(note, active: false) }

        private func report(_ note: Notification, active: Bool) {
            guard let scroll = note.object as? NSScrollView else { return }
            let visible = scroll.contentView.documentVisibleRect
            let height = scroll.documentView?.frame.height ?? 0
            let atBottom = height <= visible.height + 1 || visible.maxY >= height - 32
            onUserScroll(active, atBottom)
        }

        deinit {
            if let scroll {
                NotificationCenter.default.removeObserver(self, name: nil, object: scroll)
            }
        }
    }
}


/// One lane's caption list. Follows the bottom only while already there, and pauses while its note is open.
/// `maxHeight == nil` fills whatever height the parent gives; otherwise it sizes to its rows up to the cap.
/// `focusID` keeps that row in view (media playback) unless the person is scrolling.
struct CaptionJump: Equatable {
    var lane: UUID
    var id: UUID
    var tick: Int
}


struct LaneCaptionScroller<Content: View>: View {
    var noteOpen: Bool
    var token: Int
    var hasLines: Bool
    var pinToBottom: Bool
    var maxHeight: CGFloat? = 420
    var focusID: UUID? = nil
    /// A 一场笔记 line was clicked: show that segment, and stop following the bottom until asked.
    var jump: CaptionJump? = nil
    @ViewBuilder var content: () -> Content
    @StateObject private var follow = CaptionFollow()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    content()
                    Color.clear.frame(height: 1).id(bottomID)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: maxHeight == nil ? 96 : nil, maxHeight: maxHeight ?? .infinity)
            .background {
                LiveScrollPin { active, atBottom in
                    follow.userScrolling = active
                    follow.stick = atBottom
                }
            }
            .onAppear {
                follow.stick = true
                follow.userScrolling = false
                scroll(proxy, force: true)
            }
            .onChange(of: pinToBottom) { _, on in
                guard on else { return }
                follow.stick = true
                follow.userScrolling = false
                scroll(proxy, force: true)
            }
            .onChange(of: follow.userScrolling) { _, active in
                guard !active else { return }
                scroll(proxy)
            }
            .onChange(of: token) { _, _ in
                scroll(proxy)
            }
            .onChange(of: focusID) { _, id in
                guard let id, !follow.userScrolling, !noteOpen else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id) }
            }
            .onChange(of: jump) { _, target in
                guard let target else { return }
                follow.stick = false
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(target.id, anchor: .center) }
            }
            .overlay(alignment: .bottom) {
                if pinToBottom, !follow.stick, hasLines {
                    Button {
                        follow.stick = true
                        follow.userScrolling = false
                        scroll(proxy, force: true)
                    } label: {
                        HStack(spacing: 4) {
                            Text(L("回到最新"))
                            Image(systemName: "arrow.down")
                        }
                        .font(Theme.TypeScale.caption)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Theme.cardFill)
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(Theme.chipStroke, lineWidth: 0.5)
                        )
                        .shadow(color: Color.black.opacity(0.08), radius: 6, y: 2)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 12)
                }
            }
        }
    }

    private var bottomID: String { "lane-caption-bottom" }

    private func scroll(_ proxy: ScrollViewProxy, force: Bool = false) {
        guard force || (follow.stick && !follow.userScrolling) else { return }
        guard force || !noteOpen else { return }
        DispatchQueue.main.async {
            guard force || (self.follow.stick && !self.follow.userScrolling) else { return }
            guard force || !self.noteOpen else { return }
            proxy.scrollTo(self.bottomID, anchor: .bottom)
        }
    }
}



struct ImmersiveCaptionOverlay: View {
    @ObservedObject var model: SystemAudioTranslateController
    var providerID: String
    var pinToBottom = false
    @ObservedObject private var lang = AppConfig.shared
    @State private var hovering = false
    @State private var hoverToken = 0

    private var pane: SystemAudioTranslateController.ImmersivePane {
        model.immersivePanes[providerID] ?? .init()
    }

    private var lines: ImmersiveCaptionLines { model.immersiveLines(for: providerID) }

    private var translationVisible: Bool {
        pane.showTranslation && !lines.translation.isEmpty
    }

    private var translationAnchored: Bool {
        translationVisible || (pane.showTranslation && pane.showSource && lines.sourcePartial)
    }

    private var sourceVisible: Bool {
        if lines.source.isEmpty { return false }
        if pane.showSource { return true }
        return pane.showTranslation && !translationVisible
    }

    var body: some View {
        let _ = lang.appLanguage
        let stack = VStack(spacing: 6) {
            chrome
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color(white: 30 / 255).opacity(hovering ? 0.86 : 0))
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(Color.white.opacity(hovering ? 0.12 : 0), lineWidth: 0.5)
                        )
                )
                .opacity(hovering ? 1 : 0)
                .accessibilityHidden(!hovering)
            captionBlock
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 14)
                .frame(maxWidth: .infinity)
                .background(capsuleBackground)
        }
        .padding(.top, 6)
        .frame(minWidth: 200)
        .contentShape(Rectangle())
        .onHover { inside in
            hoverToken += 1
            let token = hoverToken
            if inside {
                hovering = true
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    if hoverToken == token { hovering = false }
                }
            }
        }
        .onChange(of: lines) { _, _ in
            guard pinToBottom else { return }
            model.refreshImmersiveOverlay(providerID)
        }
        .onChange(of: pane) { _, _ in
            guard pinToBottom else { return }
            DispatchQueue.main.async { model.refreshImmersiveOverlay(providerID) }
        }
        .onChange(of: hovering) { _, _ in
            guard pinToBottom else { return }
            DispatchQueue.main.async { model.refreshImmersiveOverlay(providerID) }
        }
        if pinToBottom {
            stack.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        } else {
            stack
        }
    }

    /// 悬停条在字幕框上方外侧，不压字。最左红点表示在听，原文和译文可以各自关。
    private var chrome: some View {
        let sourceOnly = model.immersiveIsSource(providerID)
        return HStack(spacing: 2) {
            Circle()
                .fill(model.isActive ? Theme.live : Theme.onDark.tertiary)
                .frame(width: 6, height: 6)
                .padding(.horizontal, 6)
                .help(model.isActive ? L("正在听") : L("已停止"))
                .accessibilityLabel(model.isActive ? L("正在听") : L("已停止"))
            Text(model.immersiveTitle(providerID))
                .font(Theme.TypeScale.caption)
                .foregroundStyle(Theme.onDark.secondary)
                .lineLimit(1)
            if !sourceOnly {
                captionToggle(L("原文"), on: pane.showSource) {
                    model.setImmersiveShowSource(providerID, !pane.showSource)
                }
                captionToggle(L("译文"), on: pane.showTranslation) {
                    model.setImmersiveShowTranslation(providerID, !pane.showTranslation)
                }
            }
            chromeButton(pane.speechPlaying ? "speaker.wave.2.fill" : "speaker.slash", help: pane.speechPlaying ? L("暂停朗读") : L("朗读")) {
                model.toggleImmersiveSpeech(providerID)
            }
            chromeButton("xmark", help: L("关闭沉浸字幕")) {
                model.setImmersive(providerID, on: false)
            }
        }
    }

    private func chromeButton(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(Theme.TypeScale.caption)
                .foregroundStyle(Theme.onDark.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private func captionToggle(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.TypeScale.caption)
                .foregroundStyle(on ? Theme.onDark.primary : Theme.onDark.tertiary)
                .padding(.horizontal, 7)
                .frame(height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(on ? 0.22 : 0.08))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(on ? String(format: L("隐藏%@"), String(describing: title)) : String(format: L("显示%@"), String(describing: title)))
    }

    private var captionBlock: some View {
        VStack(spacing: 3) {
            if !lines.mark.isEmpty {
                Text(lines.mark)
                    .font(Theme.TypeScale.caption).fontWeight(.semibold)
                    .foregroundStyle(Theme.onDark.secondary)
            }
            if sourceVisible {
                captionText(
                    lines.source,
                    ranges: lines.sourceMask,
                    font: translationAnchored ? Theme.TypeScale.displaySource : Theme.TypeScale.display,
                    color: lines.sourcePartial || translationAnchored ? Theme.onDark.secondary : Theme.onDark.primary,
                    limit: 6
                )
            }
            if translationVisible {
                if lines.translationFailed {
                    ErrorLine(text: lines.translation, onDark: true)
                        .frame(maxWidth: CaptionBudget.lineWidth)
                } else {
                    captionText(
                        lines.translation,
                        font: Theme.TypeScale.display,
                        color: lines.translationPartial ? Theme.onDark.secondary : Theme.onDark.primary,
                        limit: 6
                    )
                }
            } else if pane.showTranslation, lines.sourcePartial, pane.showSource {
                captionText("…", font: Theme.TypeScale.displaySource, color: Theme.onDark.tertiary, limit: 1)
            }
            if !sourceVisible && !translationVisible {
                if !pane.showSource && !pane.showTranslation
                    && (!lines.source.isEmpty || !lines.translation.isEmpty) {
                    Color.clear.frame(width: 180, height: 18)
                } else {
                    captionText(
                        model.isActive ? "···" : L("沉浸字幕"),
                        font: Theme.TypeScale.display,
                        color: Theme.onDark.tertiary,
                        limit: 1
                    )
                }
            }
        }
    }

    private func captionText(
        _ text: String,
        ranges: [NSRange] = [],
        font: Font,
        color: Color,
        limit: Int
    ) -> some View {
        highlightedSource(text, ranges: ranges)
            .font(font)
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
            .lineLimit(limit)
            .frame(maxWidth: CaptionBudget.lineWidth)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var capsuleBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.black.opacity(0.72))
    }
}


/// Receives audio and video dropped on the live-captions window.
final class LiveCaptionHost: NSHostingView<AnyView> {
    /// While a microphone permission sheet is on screen, drop `mouseMoved` here.
    /// Forwarding it into SwiftUI hits `assumeIsolated` from a nested event loop
    /// whose main-executor pointer is invalid (SIGBUS at 0x800000000).
    /// The flag stays up through the next turn of the main queue: the sheet queues
    /// mouse moves before `requestAccess` returns, and those must not reach SwiftUI either.
    static var swallowMouseMoved = false

    /// Covers the system sheet and the mouse moves it leaves queued behind it.
    static func whileMicrophonePrompt<T>(_ body: () async -> T) async -> T {
        swallowMouseMoved = true
        let value = await body()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                swallowMouseMoved = false
                cont.resume()
            }
        }
        return value
    }

    required init(rootView: AnyView) {
        super.init(rootView: rootView)
        registerForDraggedTypes([.fileURL])
    }

    override func mouseMoved(with event: NSEvent) {
        if Self.swallowMouseMoved { return }
        super.mouseMoved(with: event)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let url = FileDropHandler.fileURL(sender), MediaDrop.looksLikeMedia(url) else { return [] }
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = FileDropHandler.fileURL(sender), MediaDrop.looksLikeMedia(url) else { return false }
        let target = url
        Task { @MainActor in
            MediaCaptionsController.shared.add(target)
        }
        return true
    }
}

func highlightedSource(_ text: String, ranges: [NSRange]) -> Text {
    guard !ranges.isEmpty else { return Text(text) }
    var attr = AttributedString(text)
    for r in ranges {
        guard let swift = Range(r, in: text),
              let lower = AttributedString.Index(swift.lowerBound, within: attr),
              let upper = AttributedString.Index(swift.upperBound, within: attr),
              lower < upper else { continue }
        attr[lower..<upper].backgroundColor = Theme.attention.opacity(0.45)
    }
    return Text(attr)
}
