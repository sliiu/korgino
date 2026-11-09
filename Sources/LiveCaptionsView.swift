import AppKit
import AVFoundation
import Combine
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
            .overlay(alignment: .bottomTrailing) {
                if pinToBottom, !follow.stick, hasLines {
                    Button {
                        follow.stick = true
                        follow.userScrolling = false
                        scroll(proxy, force: true)
                    } label: {
                        Label(L("回到最新"), systemImage: "arrow.down")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(8)
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


struct SystemAudioTranslateView: View {
    typealias Kind = SystemAudioTranslateController.SourceKind

    @ObservedObject var model: SystemAudioTranslateController
    @EnvironmentObject var config: AppConfig
    @ObservedObject private var pro = Pro.shared
    @ObservedObject private var speech = SpeechPlayback.shared
    @State private var editingID: UUID?
    @State private var editSource = ""
    @State private var editTranslations: [String: String] = [:]
    @State private var hoveredID: UUID?
    @State private var clearing: (lane: UUID, kind: Kind)?
    /// 哪一路开着批量删除。
    @State private var batching: (lane: UUID, kind: Kind)?
    /// The segment a 一场笔记 line pointed at, lit for a moment.
    @State private var jump: CaptionJump?

    private let labelWidth: CGFloat = 64

    /// Settings open in any shown column: the page scrolls and each lane caps its height.
    /// All closed: no page scroll, the lanes share the window height so the wheel only ever scrolls captions.
    private var anySetupShown: Bool {
        Kind.allCases.contains { captures($0) && configOpen($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 0.5)
            if model.offersCombinedNote, model.combinedNote.open {
                combinedNoteCard
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
            }
            if anySetupShown {
                ScrollView {
                    captionLanes(fill: false)
                        .padding(14)
                }
            } else {
                captionLanes(fill: true)
                    .padding(14)
            }
        }
        .background(Theme.windowFill)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .frame(minHeight: 280)
        .onChange(of: model.captureSystem) { _, _ in scheduleRelayout() }
        .onChange(of: model.captureMicrophone) { _, _ in scheduleRelayout() }
        .onChange(of: model.isActive) { _, _ in scheduleRelayout() }
        .onChange(of: config.asrProfiles) { _, _ in model.normalizeAsrEngines() }
        .onChange(of: config.asrAppleEnabled) { _, _ in model.normalizeAsrEngines() }
        .onChange(of: config.asrAnalyzerEnabled) { _, _ in model.normalizeAsrEngines() }
        .onChange(of: config.activeSimultaneous) { _, _ in model.refreshLiveProviders() }
        .onChange(of: config.aiProfiles) { _, _ in model.refreshLiveProviders() }
        .onReceive(NotificationCenter.default.publisher(for: Pro.changed)) { _ in model.refreshLiveProviders() }
        .onAppear {
            model.normalizeAsrEngines()
            model.refreshLiveProviders()
            if model.immersiveMode { model.showImmersiveOverlay() }
        }
        .controlSize(.small)
        .confirmationDialog(
            L("清空这一路的字幕？"),
            isPresented: Binding(get: { clearing != nil }, set: { if !$0 { clearing = nil } }),
            presenting: clearing
        ) { target in
            Button(L("清空"), role: .destructive) { model.clearDisplayedLane(target.lane, target.kind) }
        } message: { _ in
            Text(L("字幕、标记和笔记会一起清掉，别的路不动。"))
        }
    }

    private func captures(_ kind: Kind) -> Bool {
        kind == .system ? model.captureSystem : model.captureMicrophone
    }

    // MARK: Toolbar

    /// One strip: which sounds to hear, what is happening, and the one primary action.
    /// How far the strip has had to give way to fit the window.
    private enum ToolbarFit: CaseIterable {
        case full, quietStatus, iconSources
    }

    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(ToolbarFit.allCases, id: \.self) { fit in
                toolbarRow(fit)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.windowFill)
    }

    /// Narrow windows lose the status words first, then the source names. The actions always stay whole.
    private func toolbarRow(_ fit: ToolbarFit) -> some View {
        HStack(spacing: 10) {
            sourceChip(.system, icon: "speaker.wave.2.fill", iconOnly: fit == .iconSources)
            sourceChip(.microphone, icon: "mic.fill", iconOnly: fit == .iconSources)
            recordChip
            statusBadge(showsText: fit == .full)
            Spacer(minLength: 8)
            Button {
                MeetingRecordsController.shared.show(select: model.recordID)
            } label: {
                Image(systemName: "tray.full")
            }
            .buttonStyle(.borderless)
            .help(L("会议记录"))
            .accessibilityLabel(L("会议记录"))
            if model.offersCombinedNote {
                Button(L("综合笔记")) {
                    if model.combinedNote.open, model.combinedNote.page != nil || model.combinedNote.writing {
                        model.closeCombinedNote()
                    } else {
                        model.writeCombinedNote()
                    }
                }
                .disabled(!model.combinedNote.open && !model.canWriteCombinedNote())
                .help(L("把系统声音和麦克风两边的话合在一页里写笔记"))
                .fixedSize()
            }
            if model.recordings.isEmpty {
                Button(L("导出…")) { model.exportCaptions() }
                    .disabled(!model.canExportCaptions())
                    .help(L("把译好的字幕存成 SRT"))
                    .fixedSize()
            } else {
                Menu(L("导出…")) {
                    Button(L("字幕（SRT）…")) { model.exportCaptions() }
                        .disabled(!model.canExportCaptions())
                    Button(L("录音（M4A）…")) { model.exportRecordings() }
                        .disabled(model.isActive)
                }
                .fixedSize()
            }
            if model.isActive {
                Button(L("停止")) { model.stop() }
                    .keyboardShortcut(".", modifiers: [.command])
                    .fixedSize()
            } else {
                Button(L("开始")) { model.start() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .fixedSize()
            }
        }
    }

    /// 综合笔记 across both columns. A cited line jumps to its segment in whichever column it came from.
    private var combinedNoteCard: some View {
        SessionNoteCard(
            title: L("综合笔记"),
            page: model.combinedNote.page,
            writing: model.combinedNote.writing,
            error: model.combinedNote.error,
            following: model.combinedNote.follow && model.isActive,
            maxHeight: 220,
            onJump: { raw in
                guard let id = UUID(uuidString: raw), let lane = model.combinedSegmentLane(id) else { return }
                jump = CaptionJump(lane: lane, id: id, tick: (jump?.tick ?? 0) + 1)
            },
            onRewrite: model.canWriteCombinedNote() ? { model.writeCombinedNote() } : nil,
            onClose: { model.closeCombinedNote() }
        )
    }

    /// Three states, not two: armed for the next session, recording right now, and off.
    /// Only the live one is red and ticking, so「有没有在录」reads at a glance.
    private var recordChip: some View {
        let armed = model.recordAudio
        let live = model.isRecordingNow
        return Button {
            model.setRecordAudio(!armed)
        } label: {
            HStack(spacing: 6) {
                ZStack {
                    Circle().fill(live ? Theme.live.opacity(0.16) : Color.primary.opacity(0.05))
                    Circle()
                        .strokeBorder(live ? Theme.live.opacity(0.4) : Theme.hairline, lineWidth: 0.5)
                    Image(systemName: live ? "record.circle.fill" : "record.circle")
                        .font(Theme.TypeScale.label).fontWeight(.semibold)
                        .foregroundStyle(live ? Theme.live : (armed ? Theme.live.opacity(0.65) : Color.secondary))
                        .symbolEffect(.pulse, options: .repeating, isActive: live)
                }
                .frame(width: 24, height: 24)
                if live, let started = model.recordStartedAt {
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        Text(Self.elapsedLabel(context.date.timeIntervalSince(started)))
                            .font(Theme.TypeScale.micro.monospaced())
                            .foregroundStyle(Theme.live)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isActive || model.isRequestingPermission)
        .help(recordHelp(live: live, armed: armed))
        .accessibilityLabel(live ? L("正在录音") : (armed ? L("下次开始会录音") : L("不录音")))
        .accessibilityAddTraits(live ? [.isSelected] : [])
    }

    private func recordHelp(live: Bool, armed: Bool) -> String {
        if live { return L("正在录这一场，停止后可导出 M4A") }
        if armed {
            return model.keepRecords
                ? L("已打开：开始后把听到的声音一起存进会议记录，也可从「导出」存成 M4A")
                : L("已打开：开始后把听到的声音另存一份，停止后可从「导出」存成 M4A")
        }
        return L("已关闭：这一场不留录音")
    }

    /// 和导出的会议记录用同一种写法：过了一小时是 `1:13:05`，不是 `73:05`。
    private static func elapsedLabel(_ seconds: TimeInterval) -> String {
        MeetingExport.clock(seconds)
    }

    private func sourceChip(_ kind: Kind, icon: String, iconOnly: Bool) -> some View {
        let hint = kind == .system ? L("视频和会议里对方的声音（需屏幕录制）") : L("本机发言（需麦克风）")
        return Button {
            captureBinding(kind).wrappedValue.toggle()
        } label: {
            chipLabel(iconOnly ? nil : kind.title, icon: icon, on: captures(kind))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(model.isActive || model.isRequestingPermission)
        .help(iconOnly ? "\(kind.title)\n\(hint)" : hint)
        .accessibilityLabel(kind.title)
        .accessibilityAddTraits(captures(kind) ? .isSelected : [])
    }

    private func chipLabel(_ title: String?, icon: String, on: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(Theme.TypeScale.caption).fontWeight(.semibold)
            if let title {
                Text(title)
                    .font(Theme.TypeScale.label).fontWeight(on ? .semibold : .regular)
                    .lineLimit(1)
            }
            Circle()
                .fill(Color.accentColor)
                .frame(width: 5, height: 5)
                .opacity(on ? 1 : 0)
                .frame(width: on ? 5 : 0)
        }
        .foregroundStyle(on ? Color.accentColor : Color.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background {
            Capsule(style: .continuous)
                .fill(on ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.05))
        }
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(on ? Color.accentColor.opacity(0.35) : Theme.hairline, lineWidth: 0.5)
        }
    }

    /// Dot plus the short state; the long line stays in the tooltip.
    private func statusBadge(showsText: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            if showsText {
                Text(shortStatus)
                    .font(Theme.TypeScale.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, showsText ? 9 : 7)
        .padding(.vertical, 4)
        .frame(minHeight: 20)
        .background(Capsule(style: .continuous).fill(Color.primary.opacity(0.04)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(shortStatus)
        .help(model.statusLine)
    }

    private var shortStatus: String {
        switch model.state {
        case .idle:
            return L("已停止")
        case .requestingPermission:
            return L("准备中…")
        case .listening:
            return L("正在听")
        case .failed:
            return L("出错了")
        }
    }

    private func captureBinding(_ kind: Kind) -> Binding<Bool> {
        Binding(
            get: { kind == .system ? model.captureSystem : model.captureMicrophone },
            set: { on in
                let system = kind == .system ? on : model.captureSystem
                let mic = kind == .microphone ? on : model.captureMicrophone
                guard system || mic, !model.isActive else { return }
                model.captureSystem = system
                model.captureMicrophone = mic
            }
        )
    }

    private var statusColor: Color {
        switch model.state {
        case .idle: return Color.secondary.opacity(0.45)
        case .requestingPermission: return .orange
        case .listening: return .red
        case .failed: return .red
        }
    }

    private func scheduleRelayout() {
        DispatchQueue.main.async {
            model.relayoutWindow()
        }
    }

    // MARK: Columns

    private func captionLanes(fill: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(Kind.allCases) { kind in
                if captures(kind) {
                    column(kind, fill: fill)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
        }
    }

    private func column(_ kind: Kind, fill: Bool) -> some View {
        let partial = (kind == .system ? model.systemPartial : model.micPartial) && model.isActive
        let setup = configOpen(kind)
        return VStack(alignment: .leading, spacing: 10) {
            columnHeader(kind, partial: partial)
            if setup {
                captureSettings(kind)
            }
            ForEach(model.lanes(kind)) { lane in
                lanePanel(lane, kind, setup: setup, fill: fill)
            }
            if setup, pro.purchased || Pro.unlocked {
                addLaneMenu(kind)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: .topLeading)
    }

    /// A plain head that names the source, shows level, and summarizes what it will do.
    private func columnHeader(_ kind: Kind, partial: Bool) -> some View {
        let live = model.lastActiveSource == kind && model.isActive
        return HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.accentColor.opacity(live ? 0.18 : 0.08))
                .frame(width: 26, height: 26)
                .overlay {
                    Image(systemName: kind == .system ? "speaker.wave.2.fill" : "mic.fill")
                        .font(Theme.TypeScale.label).fontWeight(.semibold)
                        .foregroundStyle(live ? Color.accentColor : Color.secondary)
                }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(kind.title)
                        .font(Theme.TypeScale.body).fontWeight(.semibold)
                    if partial {
                        Text(L("识别中"))
                            .font(Theme.TypeScale.micro)
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(laneSummary(kind))
                    .font(Theme.TypeScale.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(laneSummary(kind))
                    .truncationMode(.middle)
            }
            Spacer(minLength: 6)
            levelMeter(kind == .system ? model.systemLevel : model.micLevel)
                .padding(.top, 8)
            Button {
                setConfigOpen(!configOpen(kind), kind)
                scheduleRelayout()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "slider.horizontal.3")
                        .font(Theme.TypeScale.micro)
                    Text(configOpen(kind) ? L("收起") : L("设置"))
                        .font(Theme.TypeScale.caption)
                    Image(systemName: configOpen(kind) ? "chevron.up" : "chevron.down")
                        .font(Theme.TypeScale.micro)
                }
                .foregroundStyle(configOpen(kind) ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background {
                    Capsule(style: .continuous)
                        .fill(configOpen(kind) ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05))
                }
            }
            .buttonStyle(.plain)
            .help(configOpen(kind) ? L("收起设置") : L("展开设置"))
        }
    }

    /// 「日语(日本) · 千问同传 · 译成 简体中文」 — readable without opening settings.
    private func laneSummary(_ kind: Kind) -> String {
        var parts = [model.asrLanguage(for: kind).title]
        var engines: [String] = []
        var targets: [String] = []
        for lane in model.lanes(kind) {
            let name = laneTitle(lane)
            if !engines.contains(name) { engines.append(name) }
            for binding in lane.bindings where !binding.isSource {
                let t = binding.target.shortTitle
                if !targets.contains(t) { targets.append(t) }
            }
        }
        if !engines.isEmpty { parts.append(engines.joined(separator: " + ")) }
        if targets.isEmpty {
            parts.append(L("只出原文"))
        } else {
            parts.append(String(format: L("译成 %@"), targets.joined(separator: "/")))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Settings

    private func captureSettings(_ kind: Kind) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                settingLabel(L("设备"))
                if kind == .microphone {
                    micDevicePicker
                } else {
                    Text(L("系统输出"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                }
            }
            if kind == .microphone {
                GridRow {
                    settingLabel(L("译音送到"))
                    relayDevicePicker
                }
            } else {
                GridRow {
                    settingLabel(L("译音音量"))
                    HStack(spacing: 8) {
                        Slider(value: $model.interpGain, in: 1...6)
                        Text(String(format: "×%.1f", model.interpGain))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .trailing)
                    }
                    .help(L("同传译音在本机的音量。通话时聊天软件会压低其他声音，可以调大。"))
                }
            }
            GridRow {
                settingLabel(L("语言"))
                localePicker(kind)
            }
            GridRow {
                settingLabel(L("分说话人"))
                VoiceprintSettingRow(
                    threshold: thresholdBinding(kind),
                    reseparateInterp: $model.reseparateInterp,
                    listening: model.isActive
                )
            }
        }
        .padding(10)
        .well(radius: 10)
    }

    /// Two cards per lane: one for how it listens (only while settings are open), one for what it heard.
    private func lanePanel(_ lane: RecognitionLane, _ kind: Kind, setup: Bool, fill: Bool) -> some View {
        let segments = (kind == .system ? model.systemSegments : model.micSegments).filter { $0.laneID == lane.id }
        let draft = model.laneDrafts[lane.id]
        let showingDraft = model.isActive && draft?.partial == true && !(draft?.text ?? "").isEmpty
        let note = lane.note
        return VStack(alignment: .leading, spacing: 8) {
            if setup {
                laneSetupCard(lane, kind)
            }
            laneTranscriptCard(
                lane, kind,
                fill: fill,
                segments: segments,
                draft: draft,
                showingDraft: showingDraft,
                note: note
            )
        }
        .frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: .topLeading)
    }

    /// 识别、翻译、谁在说话 — configuration only, gone when settings are closed.
    private func laneSetupCard(_ lane: RecognitionLane, _ kind: Kind) -> some View {
        let speakers = model.speakerRows(lane.id, kind)
        return VStack(alignment: .leading, spacing: 0) {
            laneBlock(lane, kind)
                .padding(12)
            if !speakers.isEmpty {
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(height: 0.5)
                    .padding(.horizontal, 12)
                SpeakerChipRow(
                    rows: speakers,
                    canDelete: !model.isActive,
                    onRename: { model.renameSpeaker(lane.id, kind, $0, to: $1) },
                    onDelete: { model.deleteSpeaker(lane.id, kind, $0) },
                    onDeleteAll: { model.deleteAllSpeakers(lane.id, kind) },
                    onMerge: { model.mergeSpeaker(lane.id, kind, $0, into: $1) },
                    voices: SpeakerVoice.choices(language: model.asrLanguage(for: kind).locale.identifier),
                    voiceID: { model.speakerVoice(lane.id, kind, $0) },
                    onVoice: { model.setSpeakerVoice(lane.id, kind, $0, to: $1) }
                )
                .padding(12)
            }
        }
        .card(fill: Theme.wellFill, radius: 12, stroke: false)
    }

    /// The captions themselves, with the lane's own actions.
    private func laneTranscriptCard(
        _ lane: RecognitionLane,
        _ kind: Kind,
        fill: Bool,
        segments: [LiveCaptionSegment],
        draft: LaneDraft?,
        showingDraft: Bool,
        note: SessionNoteSlot
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            laneHeader(lane, kind, setup: configOpen(kind), count: segments.count, hasLines: !segments.isEmpty || showingDraft)
            if note.open {
                SessionNoteCard(
                    page: note.page,
                    writing: note.writing,
                    error: note.error,
                    following: note.follow && model.isActive,
                    onJump: { raw in
                        guard let id = UUID(uuidString: raw), segments.contains(where: { $0.id == id }) else { return }
                        let next = CaptionJump(lane: lane.id, id: id, tick: (jump?.tick ?? 0) + 1)
                        jump = next
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                            if jump?.tick == next.tick { jump = nil }
                        }
                    },
                    onRewrite: model.canWriteNote(lane.id, kind) ? { model.writeNote(lane.id, kind) } : nil,
                    onClose: { model.closeNote(lane.id, kind) }
                )
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
            LaneCaptionScroller(
                noteOpen: note.open,
                token: captionToken(segments, draft),
                hasLines: !segments.isEmpty || showingDraft,
                pinToBottom: model.isActive,
                maxHeight: fill ? nil : 420,
                jump: jump?.lane == lane.id ? jump : nil
            ) {
                if segments.isEmpty, !showingDraft {
                    emptyState
                }
                ForEach(Array(segments.enumerated()), id: \.element.id) { index, seg in
                    let previous = index > 0 ? segments[index - 1] : nil
                    segmentRow(seg, kind, latest: seg.id == segments.last?.id, showSpeaker: previous?.speaker != seg.speaker)
                    if index < segments.count - 1 || showingDraft {
                        Rectangle()
                            .fill(Theme.hairline)
                            .frame(height: 0.5)
                            .padding(.horizontal, 10)
                    }
                }
                if showingDraft {
                    partialRow(lane, kind)
                }
            }
            .frame(maxHeight: fill ? .infinity : nil)
        }
        .padding(.bottom, 6)
        .card(radius: 12)
        .frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: .topLeading)
    }

    private func laneHeader(_ lane: RecognitionLane, _ kind: Kind, setup: Bool, count: Int, hasLines: Bool) -> some View {
        HStack(spacing: 8) {
            Text(laneTitle(lane))
                .font(Theme.TypeScale.label).fontWeight(.semibold)
                .lineLimit(1)
            Text(laneTargetSummary(lane))
                .font(Theme.TypeScale.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: 6)
            if count > 0 {
                Text(String(format: L("%@ 段"), String(count)))
                    .font(Theme.TypeScale.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
            Button(L("笔记")) { model.writeNote(lane.id, kind) }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(!model.canWriteNote(lane.id, kind))
                .help(model.isActive
                    ? L("用这一路已经切好的段写一场笔记，之后跟着字幕更新")
                    : L("用这一路已经切好的段"))
            Button(L("批量")) {
                batching = (lane.id, kind)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(!hasLines)
            .help(L("按说话人、时段或逐条挑要删的段"))
            .popover(
                isPresented: Binding(
                    get: { batching?.lane == lane.id && batching?.kind == kind },
                    set: { if !$0 { batching = nil } }
                ),
                arrowEdge: .bottom
            ) {
                CaptionBatchSheet(cues: model.batchCues(lane.id, kind)) { ids in
                    model.deleteSegments(ids, kind: kind)
                }
            }
            Button(L("清空")) {
                if hasLines {
                    clearing = (lane.id, kind)
                } else {
                    model.clearDisplayedLane(lane.id, kind)
                }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(!hasLines)
            Menu {
                Button(L("再加翻译")) { model.addBinding(lane.id, kind) }
                    .disabled(!model.canAddBinding)
                Button(L("全部删除说话人")) { model.deleteAllSpeakers(lane.id, kind) }
                    .disabled(model.isActive || model.speakerRows(lane.id, kind).isEmpty)
                if setup, model.lanes(kind).count > 1 {
                    Divider()
                    Button(L("移除这一路识别"), role: .destructive) {
                        model.removeRecognitionLane(lane.id, kind)
                    }
                    .disabled(model.isActive)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(Theme.TypeScale.caption)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L("这一路的更多操作"))
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, setup || !lane.note.open ? 8 : 10)
    }

    private func laneTargetSummary(_ lane: RecognitionLane) -> String {
        let targets = lane.bindings.filter { !$0.isSource }.map { $0.target.shortTitle }
        guard !targets.isEmpty else { return L("只出原文") }
        var seen: [String] = []
        for t in targets where !seen.contains(t) { seen.append(t) }
        return "→ " + seen.joined(separator: " / ")
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "captions.bubble")
                .font(Theme.TypeScale.title)
                .foregroundStyle(.quaternary)
            Text(model.isActive ? L("正在听，听到人声就会出字幕") : L("开始后，字幕会出现在这里"))
                .font(Theme.TypeScale.label)
                .foregroundStyle(.tertiary)
            if !model.isActive {
                Text(L("先在上面选好声音和语言，再点「开始」"))
                    .font(Theme.TypeScale.caption)
                    .foregroundStyle(.quaternary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    /// Changes whenever a row's text, translation or loading state changes, without building one big string per render.
    private func captionToken(_ segments: [LiveCaptionSegment], _ draft: LaneDraft?) -> Int {
        var h = Hasher()
        for seg in segments {
            h.combine(seg.id)
            h.combine(seg.source)
            h.combine(seg.translations)
            h.combine(seg.errors)
            h.combine(seg.loadingProviderIDs.isEmpty)
        }
        h.combine(draft?.text)
        h.combine(draft?.translations)
        return h.finalize()
    }

    private func laneBlock(_ lane: RecognitionLane, _ kind: Kind) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                settingLabel(L("识别"))
                enginePicker(lane, kind)
            }
            ForEach(Array(lane.bindings.enumerated()), id: \.element.key) { index, binding in
                bindingRow(lane, kind, binding, first: index == 0)
            }
            if model.canAddBinding {
                HStack(spacing: 8) {
                    Color.clear.frame(width: labelWidth, height: 1)
                    Button {
                        model.addBinding(lane.id, kind)
                    } label: {
                        Label(L("加翻译"), systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private func bindingRow(_ lane: RecognitionLane, _ kind: Kind, _ binding: LaneBinding, first: Bool) -> some View {
        let immersive = model.immersiveKey(kind, lane.asrID, binding.key)
        let on = model.immersiveOn.contains(immersive)
        let removable = lane.bindings.count > 1 || !binding.isSource
        return HStack(spacing: 8) {
            if first { settingLabel(L("翻译")) } else { Color.clear.frame(width: labelWidth, height: 1) }
            Picker(L("翻译服务"), selection: Binding(
                get: { binding.translateID },
                set: { model.setBindingService(lane.id, kind, binding.key, $0) }
            )) {
                Text(L("不翻译")).tag(LaneBinding.sourceID)
                if model.offersInterp(lane, binding) {
                    Text(L("同传")).tag(LaneBinding.interpID)
                }
                Divider()
                ForEach(model.liveServiceChoices(), id: \.id) { target in
                    Text(target.displayName).tag(target.id)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PopUpFill())
            if let p = model.bindingProfile(binding) {
                ModelOverrideMenu(profile: p, override: $model.modelOverrides.model(for: p), maxWidth: 130)
            }
            if binding.isSource {
                Text(L("只出原文"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: 112, alignment: .leading)
            } else {
                Picker(L("译成"), selection: Binding(
                    get: { binding.target },
                    set: { model.setBindingTarget(lane.id, kind, binding.key, $0) }
                )) {
                    ForEach(model.bindingLanguages(lane, binding)) { lang in
                        Text(lang.shortTitle).tag(lang)
                    }
                }
                .labelsHidden()
                .frame(width: 112)
                .background(PopUpFill())
                .help(L("译成"))
            }
            IconButton(
                systemImage: on ? "captions.bubble.fill" : "captions.bubble",
                help: on ? L("关闭沉浸字幕") : L("打开沉浸字幕"),
                tint: on ? .accentColor : nil,
                size: 13
            ) {
                model.setImmersive(immersive, on: !on)
            }
            IconButton(systemImage: "minus.circle", help: L("移除这条翻译")) {
                model.removeBinding(lane.id, kind, binding.key)
            }
            .disabled(!removable)
            .opacity(removable ? 1 : 0)
        }
    }

    private func addLaneMenu(_ kind: Kind) -> some View {
        let taken = Set(model.lanes(kind).map(\.asrID))
        let choices = config.liveASRChoices().filter { !taken.contains($0.id) }
        return Menu {
            ForEach(choices) { choice in
                Button(choice.name) { model.addRecognitionLane(kind, asrID: choice.id) }
            }
        } label: {
            Label(L("再加一路识别"), systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(choices.isEmpty)
    }

    private func settingLabel(_ title: String) -> some View {
        Text(title)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: labelWidth, alignment: .leading)
    }

    private func configOpen(_ kind: Kind) -> Bool {
        kind == .system ? model.systemConfigOpen : model.micConfigOpen
    }

    private func setConfigOpen(_ open: Bool, _ kind: Kind) {
        if kind == .system { model.systemConfigOpen = open } else { model.micConfigOpen = open }
    }

    private func thresholdBinding(_ kind: Kind) -> Binding<Double> {
        Binding(
            get: { kind == .system ? model.systemSpeakerThreshold : model.micSpeakerThreshold },
            set: { new in
                if kind == .system { model.systemSpeakerThreshold = new } else { model.micSpeakerThreshold = new }
            }
        )
    }

    private var micDevicePicker: some View {
        let devices = MicInput.devices()
        return Picker(L("设备"), selection: $model.micDeviceUID) {
            Text(L("系统默认")).tag("")
            ForEach(devices) { device in
                Text(device.name).tag(device.uid)
            }
            if !model.micDeviceUID.isEmpty, !devices.contains(where: { $0.uid == model.micDeviceUID }) {
                Text(L("已断开")).tag(model.micDeviceUID)
            }
        }
        .labelsHidden()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PopUpFill())
        .disabled(model.isActive)
    }

    /// 通话模式：麦克风的同传译音送进虚拟声卡（如 BlackHole），微信等选它当麦克风。
    private var relayDevicePicker: some View {
        let devices = AudioOutputs.devices()
        return Picker(L("译音送到"), selection: $model.relayDeviceUID) {
            Text(L("不送出")).tag("")
            ForEach(devices) { device in
                Text(device.name).tag(device.uid)
            }
            if !model.relayDeviceUID.isEmpty, !devices.contains(where: { $0.uid == model.relayDeviceUID }) {
                Text(L("已断开")).tag(model.relayDeviceUID)
            }
        }
        .labelsHidden()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PopUpFill())
        .disabled(model.isActive)
        .help(L("通话时把你这一路的同传译音送进虚拟声卡，聊天软件选它当麦克风；对方那一路的译音自动播到耳机。请戴耳机。"))
    }

    private func enginePicker(_ lane: RecognitionLane, _ kind: Kind) -> some View {
        let _ = pro.purchased
        let taken = Set(model.lanes(kind).filter { $0.id != lane.id }.map(\.asrID))
        let choices = config.liveASRChoices().filter { !taken.contains($0.id) }
        return Picker(L("识别"), selection: Binding(
            get: { lane.asrID },
            set: { model.setLaneEngine(lane.id, kind, $0) }
        )) {
            ForEach(choices) { c in
                Text(c.name).tag(c.id)
            }
        }
        .labelsHidden()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PopUpFill())
        .disabled(model.isActive)
        .help(L("识别引擎"))
    }

    private func localePicker(_ kind: Kind) -> some View {
        let binding = Binding<String>(
            get: { kind == .system ? model.asrLocaleID : model.micAsrLocaleID },
            set: { new in
                if kind == .system { model.asrLocaleID = new } else { model.micAsrLocaleID = new }
            }
        )
        return Picker(L("识别语言"), selection: binding) {
            ForEach(ASRLanguage.available(apple: model.laneUsesSystemSpeech(kind))) { lang in
                Text(lang.title).tag(lang.id)
            }
        }
        .labelsHidden()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PopUpFill())
        .disabled(model.isActive)
    }

    private func levelMeter(_ level: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(level > 0.85 ? Theme.live : Theme.accent)
                    .frame(width: max(4, geo.size.width * level))
            }
        }
        .frame(width: 48, height: 4)
        .opacity(model.isActive ? 1 : 0.35)
    }

    // MARK: Captions

    /// Current bindings first, then keys this segment was translated under before an edit.
    private func translationKeys(_ seg: LiveCaptionSegment, _ kind: Kind) -> [String] {
        var keys = model.lanes(kind).first { $0.id == seg.laneID }?.translatingKeys ?? []
        let extra = Set(seg.translations.keys).union(seg.loadingProviderIDs).union(seg.errors.keys)
        for key in extra.sorted() where !keys.contains(key) { keys.append(key) }
        return keys.filter { segmentTranslation(seg, providerID: $0) != nil }
    }

    private func laneTitle(_ lane: RecognitionLane) -> String {
        config.liveASRChoices().first { $0.id == lane.asrID }?.name ?? lane.asrID
    }

    /// 字幕上的说话人名字。点开就能改名，也能换这一位朗读用的声音。
    private func speakerChip(_ seg: LiveCaptionSegment, _ kind: Kind, mark: String) -> some View {
        let rows = model.speakerRows(seg.laneID, kind)
        return SpeakerChipButton(
            speaker: seg.speaker,
            token: mark,
            canDelete: !model.isActive,
            onRename: { model.renameSpeaker(seg.laneID, kind, seg.speaker, to: $0) },
            onDelete: { model.deleteSpeaker(seg.laneID, kind, seg.speaker) },
            others: rows.filter { $0.id != seg.speaker },
            onMerge: { model.mergeSpeaker(seg.laneID, kind, seg.speaker, into: $0) },
            voices: SpeakerVoice.choices(language: model.asrLanguage(for: kind).locale.identifier),
            voiceID: model.speakerVoice(seg.laneID, kind, seg.speaker),
            onVoice: { model.setSpeakerVoice(seg.laneID, kind, seg.speaker, to: $0) }
        )
    }

    private func segmentRow(_ seg: LiveCaptionSegment, _ kind: Kind, latest: Bool, showSpeaker: Bool) -> some View {
        let keys = translationKeys(seg, kind)
        return HStack(alignment: .top, spacing: 8) {
            Text(SRTDocument.stamp(seg.start))
                .font(Theme.TypeScale.caption.monospaced())
                .foregroundStyle(latest && model.isActive ? Color.accentColor.opacity(0.8) : Color.secondary.opacity(0.6))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: 84, alignment: .trailing)
                .padding(.top, 1)
                .help(String(format: L("%@ → %@"), SRTDocument.stamp(seg.start), SRTDocument.stamp(seg.end)))
            segmentBody(seg, kind, latest: latest, showSpeaker: showSpeaker, keys: keys)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.accentColor.opacity(
            jump?.id == seg.id ? 0.14 : (latest && model.isActive ? 0.05 : 0)
        )))
        .animation(.easeOut(duration: 0.3), value: jump?.id == seg.id)
        .onHover { inside in
            if inside {
                hoveredID = seg.id
            } else if hoveredID == seg.id {
                hoveredID = nil
            }
        }
    }

    @ViewBuilder
    private func segmentBody(_ seg: LiveCaptionSegment, _ kind: Kind, latest: Bool, showSpeaker: Bool, keys: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if editingID == seg.id {
                TextField(L("原文"), text: $editSource, axis: .vertical)
                    .font(Theme.TypeScale.label)
                    .textFieldStyle(.roundedBorder)
                ForEach(keys, id: \.self) { key in
                    TextField(LaneBindingNames.title(key: key), text: Binding(
                        get: { editTranslations[key] ?? "" },
                        set: { editTranslations[key] = $0 }
                    ), axis: .vertical)
                        .font(Theme.TypeScale.reading)
                        .textFieldStyle(.roundedBorder)
                }
                HStack(spacing: 4) {
                    Spacer(minLength: 0)
                    IconButton(systemImage: "checkmark", help: L("完成")) {
                        commitEdit(seg, kind: kind)
                    }
                    IconButton(systemImage: "xmark", help: L("取消")) {
                        editingID = nil
                    }
                }
            } else {
                if showSpeaker, let mark = model.markToken(lane: seg.laneID, kind: kind, speaker: seg.speaker) {
                    speakerChip(seg, kind, mark: mark)
                        .padding(.bottom, 1)
                }
                HStack(alignment: .top, spacing: 6) {
                    highlightedSource(seg.source, ranges: seg.maskRanges)
                        .font(Theme.TypeScale.label)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: CaptionBudget.lineWidth, alignment: .leading)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                    Group {
                        IconButton(systemImage: "pencil", help: L("修改")) {
                            editingID = seg.id
                            editSource = seg.source
                            editTranslations = Dictionary(uniqueKeysWithValues: keys.map { ($0, seg.translations[$0] ?? "") })
                        }
                        IconButton(systemImage: "trash", help: L("删除")) {
                            if editingID == seg.id { editingID = nil }
                            model.deleteSegment(id: seg.id, kind: kind)
                        }
                    }
                    .opacity(hoveredID == seg.id ? 1 : 0)
                    .allowsHitTesting(hoveredID == seg.id)
                    IconButton(systemImage: "speaker.wave.2", help: speech.notice.isEmpty ? L("朗读原文") : speech.notice) {
                        model.speak(seg.source, kind: .source, source: kind, lane: seg.laneID, speaker: seg.speaker)
                    }
                }
                ForEach(keys, id: \.self) { key in
                    if let tr = segmentTranslation(seg, providerID: key) {
                        translationLine(tr, key: key, labeled: keys.count > 1, failed: seg.errors[key] != nil) {
                            model.speak(tr, kind: .translation, source: kind, target: LaneBinding(key: key)?.target, lane: seg.laneID, speaker: seg.speaker)
                        }
                        .disabled(tr == L("翻译中…"))
                    }
                }
            }
        }
    }

    private func translationLine(_ text: String, key: String, labeled: Bool, failed: Bool, speak: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if labeled {
                Text(LaneBindingNames.title(key: key))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            HStack(alignment: .top, spacing: 6) {
                if failed {
                    ErrorLine(text: text)
                        .frame(maxWidth: CaptionBudget.lineWidth, alignment: .leading)
                } else {
                    Text(text)
                        .font(Theme.TypeScale.reading)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: CaptionBudget.lineWidth, alignment: .leading)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                    IconButton(systemImage: "speaker.wave.2", help: speech.notice.isEmpty ? L("朗读译文") : speech.notice, action: speak)
                }
            }
        }
    }

    @ViewBuilder
    private func partialRow(_ lane: RecognitionLane, _ kind: Kind) -> some View {
        if let draft = model.laneDrafts[lane.id], !draft.text.isEmpty {
            let mark = model.markToken(lane: lane.id, kind: kind, speaker: draft.speaker) ?? ""
            let keys = draft.translations.keys.sorted().filter { !(draft.translations[$0] ?? "").isEmpty }
            VStack(alignment: .leading, spacing: 4) {
                if !mark.isEmpty {
                    SpeakerChip(speaker: draft.speaker, token: mark)
                        .padding(.bottom, 1)
                }
                HStack(alignment: .top, spacing: 6) {
                    highlightedSource(draft.text, ranges: draft.mask)
                        .font(Theme.TypeScale.label)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: CaptionBudget.lineWidth, alignment: .leading)
                }
                ForEach(keys, id: \.self) { key in
                    let text = draft.translations[key] ?? ""
                    VStack(alignment: .leading, spacing: 2) {
                        if keys.count > 1 {
                            Text(LaneBindingNames.title(key: key))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        if text.hasPrefix(L("翻译失败")) {
                            ErrorLine(text: text)
                        } else {
                            Text(text)
                                .font(Theme.TypeScale.reading)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
        }
    }

    private func commitEdit(_ seg: LiveCaptionSegment, kind: Kind) {
        model.updateSegment(id: seg.id, kind: kind, source: editSource, translation: nil, providerID: "")
        for (key, text) in editTranslations {
            model.updateSegment(id: seg.id, kind: kind, source: editSource, translation: text, providerID: key)
        }
        editingID = nil
    }

    private struct PopUpFill: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }
        func updateNSView(_ nsView: NSView, context: Context) {
            DispatchQueue.main.async {
                guard let host = nsView.superview else { return }
                guard let pop = Self.findPopUp(host), let parent = pop.superview else { return }
                let width = parent.bounds.width
                guard width > 20 else { return }
                if abs(pop.frame.width - width) > 0.5 || abs(pop.frame.origin.x) > 0.5 {
                    pop.setFrameOrigin(NSPoint(x: 0, y: pop.frame.origin.y))
                    pop.setFrameSize(NSSize(width: width, height: pop.frame.height))
                }
                pop.alignment = .left
                (pop.cell as? NSPopUpButtonCell)?.alignment = .left
            }
        }

        private static func findPopUp(_ view: NSView) -> NSPopUpButton? {
            if let pop = view as? NSPopUpButton { return pop }
            for sub in view.subviews {
                if let found = findPopUp(sub) { return found }
            }
            return nil
        }
    }

    private func segmentTranslation(_ seg: LiveCaptionSegment, providerID: String) -> String? {
        if let t = seg.translations[providerID], !t.isEmpty { return t }
        if seg.loadingProviderIDs.contains(providerID) { return L("翻译中…") }
        if let e = seg.errors[providerID], !e.isEmpty { return e }
        return nil
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
        let stack = captionBlock
            .padding(.horizontal, 28)
            .padding(.vertical, 10)
            .background(capsuleBackground)
            .overlay(alignment: .top) {
                chrome
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.black.opacity(0.6))
                    )
                    .padding(4)
                    .opacity(hovering ? 1 : 0)
                    .allowsHitTesting(hovering)
            }
            .padding(6)
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
        if pinToBottom {
            stack.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        } else {
            stack
        }
    }

    private var chrome: some View {
        let sourceOnly = model.immersiveIsSource(providerID)
        return HStack(spacing: 4) {
            Image(systemName: "line.3.horizontal")
                .font(Theme.TypeScale.caption)
                .foregroundStyle(Theme.onDark.tertiary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
                .help(L("拖动"))
            chromeButton(pane.speechPlaying ? "pause.fill" : "play.fill", help: pane.speechPlaying ? L("暂停朗读") : L("朗读")) {
                model.toggleImmersiveSpeech(providerID)
            }
            if !sourceOnly {
                captionToggle(L("原文"), on: pane.showSource) {
                    model.setImmersiveShowSource(providerID, !pane.showSource)
                }
                captionToggle(L("译文"), on: pane.showTranslation) {
                    model.setImmersiveShowTranslation(providerID, !pane.showTranslation)
                }
            }
            Text(model.immersiveTitle(providerID))
                .font(Theme.TypeScale.caption)
                .foregroundStyle(Theme.onDark.secondary)
                .lineLimit(1)
                .padding(.leading, 4)
            Spacer(minLength: 4)
            if model.isActive {
                Circle()
                    .fill(Theme.live)
                    .frame(width: 6, height: 6)
                    .help(L("正在听"))
            }
            chromeButton("xmark", help: L("关闭沉浸字幕")) {
                model.setImmersive(providerID, on: false)
            }
        }
    }

    private func chromeButton(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(Theme.TypeScale.caption).fontWeight(.medium)
                .foregroundStyle(Theme.onDark.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private func captionToggle(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.TypeScale.caption).fontWeight(.medium)
                .foregroundStyle(on ? Theme.onDark.primary : Theme.onDark.tertiary)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(on ? 0.18 : 0.06))
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
                    color: lines.sourcePartial ? Theme.onDark.secondary : (translationAnchored ? Theme.onDark.secondary : Theme.onDark.primary),
                    limit: 6
                )
            }
            if translationVisible {
                let failed = lines.translation.hasPrefix(L("翻译失败"))
                if failed {
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
                captionText("…", font: Theme.TypeScale.title, color: Theme.onDark.tertiary, limit: 1)
            }
            if !sourceVisible && !translationVisible {
                if !pane.showSource && !pane.showTranslation
                    && (!lines.source.isEmpty || !lines.translation.isEmpty) {
                    Color.clear.frame(width: 180, height: 18)
                } else {
                    captionText(
                        model.isActive ? "···" : L("沉浸字幕"),
                        font: model.isActive ? Theme.TypeScale.title : Theme.TypeScale.display,
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
            .minimumScaleFactor(0.78)
            .frame(maxWidth: CaptionBudget.lineWidth)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var capsuleBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.black.opacity(0.8))
    }
}


/// Receives audio and video dropped on the live-captions window.
final class LiveCaptionHost: NSHostingView<AnyView> {
    required init(rootView: AnyView) {
        super.init(rootView: rootView)
        registerForDraggedTypes([.fileURL])
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
