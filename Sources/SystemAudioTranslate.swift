import AppKit
import AudioToolbox
import AVFoundation
import Combine
import CoreMedia
import CoreGraphics
import Foundation
import ScreenCaptureKit
import Speech
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Controller

/// Realtime captions: system audio + microphone → on-device Speech ASR → translate → floating UI.
@MainActor
final class SystemAudioTranslateController: ObservableObject {
    static let shared = SystemAudioTranslateController()

    enum State: Equatable {
        case idle
        case requestingPermission
        case listening
        case failed(String)
    }

    enum SourceKind: String, CaseIterable, Identifiable {
        case system, microphone
        var id: String { rawValue }
        var title: String {
            switch self {
            case .system: return L("系统声音")
            case .microphone: return L("麦克风")
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published var captureSystem = true
    @Published var captureMicrophone = true
    @Published var asrLocaleID: String = SystemAudioTranslateController.savedLocale(key: "live.asrLocale") {
        didSet {
            guard asrLocaleID != oldValue else { return }
            UserDefaults.standard.set(asrLocaleID, forKey: "live.asrLocale")
        }
    }
    @Published var micAsrLocaleID: String = SystemAudioTranslateController.savedLocale(key: "live.asrLocale.mic") {
        didSet {
            guard micAsrLocaleID != oldValue else { return }
            UserDefaults.standard.set(micAsrLocaleID, forKey: "live.asrLocale.mic")
        }
    }
    @Published var systemAsrID: String = UserDefaults.standard.string(forKey: "live.asr.system")
        ?? UserDefaults.standard.string(forKey: "asrSelection") ?? "apple" {
        didSet {
            guard systemAsrID != oldValue else { return }
            UserDefaults.standard.set(systemAsrID, forKey: "live.asr.system")
        }
    }
    @Published var micAsrID: String = UserDefaults.standard.string(forKey: "live.asr.mic")
        ?? UserDefaults.standard.string(forKey: "asrSelection") ?? "apple" {
        didSet {
            guard micAsrID != oldValue else { return }
            UserDefaults.standard.set(micAsrID, forKey: "live.asr.mic")
        }
    }
    @Published var micDeviceUID: String = UserDefaults.standard.string(forKey: "live.micDeviceUID") ?? "" {
        didSet { UserDefaults.standard.set(micDeviceUID, forKey: "live.micDeviceUID") }
    }
    /// 通话模式：麦克风那一路的同传译音送进这个输出设备（虚拟声卡），聊天软件选它当麦克风。
    /// 设了它，系统声音那一路的同传译音也自动播到耳机。空：不送。
    @Published var relayDeviceUID: String = UserDefaults.standard.string(forKey: "live.relayDeviceUID") ?? "" {
        didSet { UserDefaults.standard.set(relayDeviceUID, forKey: "live.relayDeviceUID") }
    }
    /// 同传译音在本机播放时的放大倍数。
    @Published var interpGain: Double = {
        let saved = UserDefaults.standard.double(forKey: "live.interpGain")
        return saved > 0 ? saved : 1
    }() {
        didSet {
            UserDefaults.standard.set(interpGain, forKey: "live.interpGain")
            InterpPlayer.shared.gain = Float(interpGain)
        }
    }
    @Published var systemSpeakerThreshold: Double = SystemAudioTranslateController.savedThreshold(key: "live.speakerThreshold.system") {
        didSet { Self.persistThreshold(systemSpeakerThreshold, old: oldValue, key: "live.speakerThreshold.system") { systemSpeakerThreshold = $0 } }
    }
    @Published var micSpeakerThreshold: Double = SystemAudioTranslateController.savedThreshold(key: "live.speakerThreshold.mic") {
        didSet { Self.persistThreshold(micSpeakerThreshold, old: oldValue, key: "live.speakerThreshold.mic") { micSpeakerThreshold = $0 } }
    }
    /// 同传这一路默认用服务给的说话人。打开后，这一路说完再按本机声纹分一次。
    @Published var reseparateInterp: Bool = UserDefaults.standard.bool(forKey: "live.reseparateInterp") {
        didSet { UserDefaults.standard.set(reseparateInterp, forKey: "live.reseparateInterp") }
    }
    /// The language a new binding on this capture starts with: the last one picked here.
    @Published var systemTarget: TargetLanguage = SystemAudioTranslateController.savedTarget(key: "live.target.system") {
        didSet { UserDefaults.standard.set(systemTarget.rawValue, forKey: "live.target.system") }
    }
    @Published var micTarget: TargetLanguage = SystemAudioTranslateController.savedTarget(key: "live.target.mic") {
        didSet { UserDefaults.standard.set(micTarget.rawValue, forKey: "live.target.mic") }
    }
    /// Keep a copy of what was heard, per capture, in the 会议记录. On unless the user turned it off.
    @Published var recordAudio: Bool = UserDefaults.standard.object(forKey: "live.recordAudio") as? Bool ?? true {
        didSet { UserDefaults.standard.set(recordAudio, forKey: "live.recordAudio") }
    }
    /// Each session becomes a 会议记录. Off: nothing is kept after the next 开始.
    @Published var keepRecords: Bool = UserDefaults.standard.object(forKey: "live.keepRecords") as? Bool ?? true {
        didSet { UserDefaults.standard.set(keepRecords, forKey: "live.keepRecords") }
    }
    /// The 会议记录 this window writes to, from 开始 until the next 开始.
    @Published var recordID: UUID?
    /// 综合笔记: both captures on one page. See LiveCombinedNote.swift.
    @Published var combinedNote = SessionNoteSlot()
    var combinedNoteTask: Task<Void, Never>?
    var recordFolder: URL?
    var recordStartedAt: Date?
    var recordEndedAt: Date?
    var recordKinds: [SourceKind] = []
    var recordTitle = ""
    var recordSaveTask: Task<Void, Never>?
    var recordSinks: [AnyCancellable] = []
    /// Per capture: tells speakers apart by voice when the voiceprint model is installed.
    var voiceTaggers: [SourceKind: VoiceTagger] = [:]
    /// Finished recordings of the last session. Filled on Stop.
    @Published var recordings: [SourceKind: URL] = [:]

    var asrLanguage: ASRLanguage { asrLanguage(for: .system) }

    func asrEngineID(for kind: SourceKind) -> String {
        let lanes = kind == .system ? systemLanes : micLanes
        let raw = lanes.first?.asrID ?? AppConfig.shared.resolvedLiveAsr()
        let ids = AppConfig.shared.liveASRChoices().map(\.id)
        if ids.contains(raw) { return raw }
        return ids.first ?? "apple"
    }

    func laneUsesApple(_ kind: SourceKind) -> Bool {
        AppConfig.shared.isLegacyASR(asrEngineID(for: kind))
    }

    func laneUsesAnalyzer(_ kind: SourceKind) -> Bool {
        AppConfig.shared.isAnalyzerASR(asrEngineID(for: kind))
    }

    func laneUsesSystemSpeech(_ kind: SourceKind) -> Bool {
        AppConfig.shared.isSystemASR(asrEngineID(for: kind))
    }

    func normalizeAsrEngines() {
        seedLanes()
        let ids = AppConfig.shared.liveASRChoices().map(\.id)
        let fallback = ids.first ?? "apple"
        if !ids.contains(systemLanes[0].asrID) { systemLanes[0].asrID = fallback }
        if !ids.contains(micLanes[0].asrID) { micLanes[0].asrID = fallback }
        clampAsrLocale(for: .system)
        clampAsrLocale(for: .microphone)
    }

    private func clampAsrLocale(for kind: SourceKind) {
        let ids = ASRLanguage.available(apple: laneUsesSystemSpeech(kind)).map(\.id)
        let fallback = ids.contains("zh-CN") ? "zh-CN" : (ids.first ?? "en-US")
        switch kind {
        case .system:
            if !ids.contains(asrLocaleID) { asrLocaleID = fallback }
        case .microphone:
            if !ids.contains(micAsrLocaleID) { micAsrLocaleID = fallback }
        }
    }

    func asrLanguage(for kind: SourceKind) -> ASRLanguage {
        let id = kind == .system ? asrLocaleID : micAsrLocaleID
        return ASRLanguage.available(apple: laneUsesSystemSpeech(kind))
            .first { $0.id == id }
            ?? ASRLanguage(id: id)
    }

    private static func savedLocale(key: String) -> String {
        if let saved = UserDefaults.standard.string(forKey: key), !saved.isEmpty { return saved }
        if key != "live.asrLocale",
           let legacy = UserDefaults.standard.string(forKey: "live.asrLocale"), !legacy.isEmpty {
            return legacy
        }
        let id = Locale.current.identifier.replacingOccurrences(of: "_", with: "-").lowercased()
        if id.hasPrefix("zh-hant") || id.hasPrefix("zh-tw") || id.hasPrefix("zh-hk") || id.hasPrefix("zh-mo") {
            return "zh-TW"
        }
        if id.hasPrefix("zh") { return "zh-CN" }
        return "en-US"
    }

    private static func savedThreshold(key: String) -> Double {
        let stored = UserDefaults.standard.object(forKey: key) as? Double
            ?? UserDefaults.standard.object(forKey: SpeakerThreshold.key) as? Double
            ?? 0.2
        return min(SpeakerThreshold.range.upperBound, max(SpeakerThreshold.range.lowerBound, stored))
    }

    private static func persistThreshold(_ value: Double, old: Double, key: String, assign: (Double) -> Void) {
        let clamped = min(SpeakerThreshold.range.upperBound, max(SpeakerThreshold.range.lowerBound, value))
        if clamped != value {
            assign(clamped)
            return
        }
        guard value != old else { return }
        UserDefaults.standard.set(value, forKey: key)
    }

    private static func savedTarget(key: String) -> TargetLanguage {
        TargetLanguage.storedCaptionTarget(key: key)
    }

    func lastTarget(for kind: SourceKind) -> TargetLanguage {
        kind == .system ? systemTarget : micTarget
    }

    private func rememberTarget(_ lang: TargetLanguage, for kind: SourceKind) {
        if kind == .system { systemTarget = lang } else { micTarget = lang }
    }

    func lanes(_ kind: SourceKind) -> [RecognitionLane] {
        kind == .system ? systemLanes : micLanes
    }

    func editLane(_ laneID: UUID, _ kind: SourceKind, _ change: (inout RecognitionLane) -> Void) {
        var list = lanes(kind)
        guard let index = list.firstIndex(where: { $0.id == laneID }) else { return }
        change(&list[index])
        if kind == .system { systemLanes = list } else { micLanes = list }
    }

    /// Free tier keeps one binding per lane (`0041`); 「不翻译」 counts as one.
    var canAddBinding: Bool { Pro.unlocked }

    func addBinding(_ laneID: UUID, _ kind: SourceKind) {
        guard canAddBinding, let lane = lanes(kind).first(where: { $0.id == laneID }) else { return }
        let target = lastTarget(for: kind)
        let used = Set(lane.bindingKeys)
        let candidates = AppConfig.shared.translateTargets(.live).map(\.id) + liveServiceChoices().map(\.id)
        guard let id = candidates.first(where: { !used.contains(LaneBinding(translateID: $0, target: target).key) }) else { return }
        editLane(laneID, kind) { $0.addBinding(LaneBinding(translateID: id, target: target)) }
        refreshLiveProviders()
        syncInterpLane(laneID, kind)
    }

    func removeBinding(_ laneID: UUID, _ kind: SourceKind, _ key: String) {
        guard let lane = lanes(kind).first(where: { $0.id == laneID }) else { return }
        let full = immersiveKey(kind, lane.asrID, key)
        if immersiveOn.contains(full) { setImmersive(full, on: false) }
        editLane(laneID, kind) { $0.removeBinding(key) }
        refreshLiveProviders()
        syncInterpLane(laneID, kind)
    }

    func setBindingService(_ laneID: UUID, _ kind: SourceKind, _ key: String, _ translateID: String) {
        guard let old = LaneBinding(key: key) else { return }
        var target = old.isSource ? lastTarget(for: kind) : old.target
        if translateID == LaneBinding.interpID {
            guard let lane = lanes(kind).first(where: { $0.id == laneID }),
                  let wire = AppConfig.shared.interpWire(lane.asrID) else { return }
            if lane.interpBinding != nil, !old.isInterp { return }
            target = Self.interpTarget(target, wire: wire)
        }
        replaceBinding(laneID, kind, key, with: LaneBinding(translateID: translateID, target: target))
    }

    /// The nearest language the 同传服务 can speak: the one asked for, else English.
    static func interpTarget(_ wanted: TargetLanguage, wire: InterpWire) -> TargetLanguage {
        InterpLanguages.supports(wire, wanted) ? wanted : .en
    }

    /// Languages a binding may pick. The 同传 binding only offers what its service speaks.
    func bindingLanguages(_ lane: RecognitionLane, _ binding: LaneBinding) -> [TargetLanguage] {
        guard binding.isInterp, let wire = AppConfig.shared.interpWire(lane.asrID) else { return TargetLanguage.specific }
        return TargetLanguage.specific.filter { InterpLanguages.supports(wire, $0) }
    }

    /// Whether the 同传 choice belongs in this binding's service menu.
    func offersInterp(_ lane: RecognitionLane, _ binding: LaneBinding) -> Bool {
        guard AppConfig.shared.isInterpASR(lane.asrID) else { return false }
        return binding.isInterp || lane.interpBinding == nil
    }

    /// A running 同传 lane follows its binding's language from the next sentence.
    private func syncInterpLane(_ laneID: UUID, _ kind: SourceKind) {
        guard isActive, let lane = lanes(kind).first(where: { $0.id == laneID }) else { return }
        let fan = kind == .system ? systemFan : micFan
        guard let sink = fan.children.compactMap({ $0 as? LiveInterpLane }).first(where: { $0.laneID == laneID }) else { return }
        let wanted = lane.interpBinding?.target ?? sink.language
        guard wanted != sink.language else { return }
        interpLanes[laneID] = nil
        clearPartial(laneID, kind)
        sink.retarget(wanted)
    }

    /// Applies from the next segment; finished segments keep what they were translated into.
    func setBindingTarget(_ laneID: UUID, _ kind: SourceKind, _ key: String, _ lang: TargetLanguage) {
        guard let old = LaneBinding(key: key), !old.isSource else { return }
        rememberTarget(lang, for: kind)
        replaceBinding(laneID, kind, key, with: LaneBinding(translateID: old.translateID, target: lang))
    }

    private func replaceBinding(_ laneID: UUID, _ kind: SourceKind, _ key: String, with next: LaneBinding) {
        guard let lane = lanes(kind).first(where: { $0.id == laneID }), next.key != key else { return }
        var ok = false
        editLane(laneID, kind) { ok = $0.replaceBinding(key, with: next) }
        guard ok else { return }
        moveImmersive(from: immersiveKey(kind, lane.asrID, key), to: immersiveKey(kind, lane.asrID, next.key))
        refreshLiveProviders()
        syncInterpLane(laneID, kind)
    }

    func liveServiceChoices() -> [TranslateTarget] {
        AppConfig.shared.simultaneousTargets()
    }

    /// 实时字幕这次换的模型。不写回设置，和各路翻译一样只在这次运行里。
    @Published var modelOverrides: ModelOverrides = [:]

    /// 这一条翻译用的 AI 配置（设置里的那份）。不是 AI 时为空。
    func bindingProfile(_ binding: LaneBinding) -> AIProfile? {
        guard !binding.isSource, !binding.isInterp else { return nil }
        return liveServiceChoices().first { $0.id == binding.translateID }?.aiProfile
    }

    // Dual-lane segmented captions
    @Published var systemSegments: [LiveCaptionSegment] = []
    @Published var micSegments: [LiveCaptionSegment] = []
    @Published var systemMarks = SpeakerMarkBook()
    @Published var micMarks = SpeakerMarkBook()
    @Published var systemLanes: [RecognitionLane] = []
    @Published var micLanes: [RecognitionLane] = []
    @Published var laneDrafts: [UUID: LaneDraft] = [:]
    @Published var systemPartialText = ""
    @Published var micPartialText = ""
    @Published var systemPartialTranslations: [String: String] = [:]
    @Published var micPartialTranslations: [String: String] = [:]
    @Published var systemPartialSpeaker = 0
    @Published var micPartialSpeaker = 0
    @Published var systemPartialMask: [NSRange] = []
    @Published var micPartialMask: [NSRange] = []
    @Published var systemPartial = false
    @Published var micPartial = false

    /// Snapshot of enabled translate providers for this session (tabs).
    @Published var liveProviderIDs: [String] = []
    @Published var liveRealtimeIDs: [String] = []
    @Published var liveOtherIDs: [String] = []
    @Published var liveProviderNames: [String: String] = [:]
    @Published var systemConfigOpen = true
    @Published var micConfigOpen = true
    @Published var systemLevel: Double = 0
    @Published var micLevel: Double = 0
    private var levelClock: [SourceKind: CFAbsoluteTime] = [:]

    @Published var statusLine = L("未开始")
    @Published var lastActiveSource: SourceKind?
    @Published var translateEngineLabel = ""

    /// 跨文件（LiveCaptionWindow）读写。
    var window: NSWindow?
    /// 跨文件（LiveCaptionWindow）读写。
    var hosting: NSHostingView<AnyView>?

    struct ImmersivePane: Equatable {
        var showSource = false
        var showTranslation = true
        var speechPlaying = false
    }

    private final class ImmersiveBox {
        var window: NSPanel?
        var hosting: NSHostingView<AnyView>?
        var fitter: NSHostingController<AnyView>?
        var bottomAnchor: CGFloat?
        var applyingFrame = false
        let providerID: String
        init(providerID: String) { self.providerID = providerID }
    }

    @Published var immersiveOn: [String] = UserDefaults.standard.stringArray(forKey: "live.immersiveProviders") ?? []
    @Published var immersivePanes: [String: ImmersivePane] = [:]
    private var immersiveBoxes: [String: ImmersiveBox] = [:]
    private var speakingProviderID: String?
    /// Per 同传 lane: which utterance became which segment, and the lines translated so far.
    fileprivate var interpLanes: [UUID: InterpLaneState] = [:]

    var immersiveMode: Bool { !immersiveOn.isEmpty }

    private var autoSpokenID: UUID?
    private var autoSpokenKind: SpeakKind?

    private var stream: SCStream?
    private var streamOutput: SystemAudioStreamOutput?
    /// 通话模式下代替 `stream`：只抓把译音设备当麦克风的通话软件，并把它的原声静音。
    private var callTap: ProcessTapCapture?
    /// 这一场是不是通话。译音往哪送、系统声音从哪听，都看它，不看「译音送到」设过没有。
    private(set) var inCall = false
    /// 麦克风那一路正听着译音设备，这一场录进去只会是静音。
    private(set) var micOnRelay = false
    /// Watches the chosen mic. An iPhone mic drops when the phone locks or walks away.
    private var micWatch: NSObjectProtocol?
    private var audioEngine: AVAudioEngine?

    private let systemFan = LaneFan()
    private let micFan = LaneFan()
    var recorders: [SourceKind: LiveAudioRecorder] = [:]
    /// 跨文件（LiveCaptionWindow）读写。
    var recordingFailure: String?

    private struct TranslateKey: Hashable {
        var segment: UUID
        var provider: String
    }
    private var translateTasks: [TranslateKey: Task<Void, Never>] = [:]
    private var noteTasks: [UUID: Task<Void, Never>] = [:]
    private var idleCommitTasks: [UUID: Task<Void, Never>] = [:]
    private struct DraftKey: Hashable {
        var lane: UUID
        var provider: String
    }
    private var draftTranslateTasks: [DraftKey: Task<Void, Never>] = [:]
    private var draftSource: [UUID: String] = [:]
    private var cursors: [UUID: CaptionCursor] = [:]
    /// Zero of the shared SRT clock. Set when listening actually begins.
    private var sessionStartedAt: Date?
    /// End time of the last committed segment on each recognition lane.
    private var laneSpokenUntil: [UUID: TimeInterval] = [:]
    /// When the line now being drafted on each lane was first heard.
    private var laneHeardAt: [UUID: TimeInterval] = [:]
    private var hiddenSources: [SourceKind: [String]] = [:]

    var isActive: Bool {
        if case .listening = state { return true }
        return false
    }

    var isRequestingPermission: Bool {
        if case .requestingPermission = state { return true }
        return false
    }

    func show() {
        refreshLiveProviders()
        showWindow()
    }

    /// Listening and actually writing audio right now. 「录音」 is armed by `recordAudio`; only this says it is happening.
    var isRecordingNow: Bool { isActive && recordAudio && !recorders.isEmpty }

    /// Arming the next session. Only while stopped: turning it off mid-session would leave a half-written file.
    func setRecordAudio(_ on: Bool) {
        guard !isActive, !isRequestingPermission, recordAudio != on else { return }
        recordAudio = on
    }

    func toggle() {
        if isActive { stop() } else { start() }
    }

    func start() {
        guard !isActive else { return }
        if case .requestingPermission = state { return }
        guard captureSystem || captureMicrophone else {
            state = .failed(L("请至少开启「系统声音」或「麦克风」一路"))
            statusLine = L("请至少开启一路采集")
            showWindow()
            return
        }
        state = .requestingPermission
        statusLine = L("检查权限…")
        saveRecordNow()
        clearCaptions()
        discardRecordings()
        beginRecord()
        showWindow()

        Task { @MainActor in
            do {
                // Let SwiftUI paint "检查权限…" before TCC / SCK work.
                await Task.yield()
                try await ensurePermissions()
                refreshLiveProviders()
                let cfg = AppConfig.shared
                // 通话模式 only when a call is up. A relay device left over from the last call would otherwise put
                // 系统声音 on the process tap — which hears only the caller — and refuse to start over a mic
                // defaulting to that same virtual device, both while nothing is happening.
                inCall = !relayDeviceUID.isEmpty && ProcessTapCapture.callIsLive(relayUID: relayDeviceUID)
                if inCall { try checkCallRelay(cfg) }
                for kind in SourceKind.allCases where captures(kind) {
                    let lanes = kind == .system ? systemLanes : micLanes
                    for lane in lanes {
                        if #available(macOS 26.0, *), cfg.isAnalyzerASR(lane.asrID) {
                            let locale = asrLanguage(for: kind).locale
                            switch await MediaAnalyzerASR.readiness(for: locale) {
                            case .ready:
                                break
                            case .unsupported:
                                throw TErr(String(format: L("语音分析不支持这种语言：%@"), asrLanguage(for: kind).title))
                            case .needsModel(let modelLocale):
                                statusLine = L("正在下载语音模型")
                                try await MediaAnalyzerASR.installModel(modelLocale) { _ in }
                            }
                        } else if cfg.isSystemASR(lane.asrID) {
                            let locale = asrLanguage(for: kind).locale
                            guard SFSpeechRecognizer(locale: locale) != nil else {
                                throw TErr(String(format: L("当前系统不支持语音识别语言：%@"), String(describing: locale.identifier)))
                            }
                        } else if let wire = cfg.interpWire(lane.asrID) {
                            let target = lane.interpBinding?.target ?? lastTarget(for: kind)
                            guard InterpLanguages.supports(wire, target) else {
                                throw TErr(String(format: L("这家同传译不成%@"), target.shortTitle))
                            }
                            _ = try cfg.interpConfig(selection: lane.asrID, target: target, audio: true)
                        } else {
                            _ = try cfg.asrWhisperConfig(selection: lane.asrID)
                        }
                    }
                }

                if captureSystem {
                    systemFan.children = []
                    for lane in systemLanes {
                        let sink = try makeSink(lane, source: .system)
                        try sink.prepare()
                        systemFan.children.append(sink)
                    }
                    try attachRecorder(.system, to: systemFan)
                    // The process tap hears only the caller and mutes their original. Outside a call it would
                    // hear nothing at all, so a video playing in a browser has to come from the whole-machine tap.
                    if inCall {
                        try beginCallTapCapture()
                    } else {
                        try await beginSCKAudioCapture()
                    }
                }
                if captureMicrophone {
                    micFan.children = []
                    for lane in micLanes {
                        let sink = try makeSink(lane, source: .microphone)
                        try sink.prepare()
                        micFan.children.append(sink)
                    }
                    try attachRecorder(.microphone, to: micFan)
                    try beginMicrophoneCapture()
                }

                let startedAt = Date()
                sessionStartedAt = startedAt
                recordStartedAt = startedAt
                for recorder in recorders.values { recorder.arm(at: startedAt) }
                for tagger in voiceTaggers.values { tagger.arm(at: startedAt) }
                laneSpokenUntil = [:]
                laneHeardAt = [:]
                state = .listening
                systemConfigOpen = false
                micConfigOpen = false
                if immersiveMode { showImmersiveOverlay() }
                var parts: [String] = []
                if captureSystem { parts.append(L("系统声音")) }
                if captureMicrophone { parts.append(L("麦克风")) }
                var engines: [String] = []
                for kind in SourceKind.allCases where captures(kind) {
                    for lane in (kind == .system ? systemLanes : micLanes) {
                        let name = cfg.liveASRChoices().first { $0.id == lane.asrID }?.name ?? lane.asrID
                        if !engines.contains(name) { engines.append(name) }
                    }
                }
                let engine = engines.joined(separator: " / ")
                var seen: [String] = []
                for title in SourceKind.allCases.filter(captures).map({ asrLanguage(for: $0).title }) where !seen.contains(title) {
                    seen.append(title)
                }
                let langLabel = seen.joined(separator: " / ")
                statusLine = String(format: L("监听中：%@ · %@ · %@ · 翻译 %@"), parts.joined(separator: " + "), engine, langLabel, translateEngineLabel)
                if micOnRelay {
                    statusLine += L("。麦克风这一路在用译音设备听，听不到你说话。请在麦克风设备里选真实的麦克风。")
                }
            } catch {
                await teardownAll()
                abandonRecordIfEmpty()
                state = .failed(error.localizedDescription)
                statusLine = String(format: L("启动失败：%@"), String(describing: error.localizedDescription))
            }
        }
    }

    func stop() {
        Task { @MainActor in
            await teardownAll()
            // Clear「识别中」and partial draft; keep finished segments for review.
            systemPartial = false
            micPartial = false
            systemPartialText = ""
            micPartialText = ""
            systemPartialTranslations = [:]
            micPartialTranslations = [:]
            systemPartialSpeaker = 0
            micPartialSpeaker = 0
            systemPartialMask = []
            micPartialMask = []
            systemLevel = 0
            micLevel = 0
            cursors.removeAll()
            state = .idle
            systemConfigOpen = true
            micConfigOpen = true
            statusLine = L("已停止")
            if let failure = recordingFailure {
                statusLine = String(format: L("已停止。录音出错：%@"), failure)
                recordingFailure = nil
            }
            stopSpeaking()
            finishRecord()
            relayoutWindow()
        }
    }

    private func clearCaptions() {
        sessionStartedAt = nil
        laneSpokenUntil = [:]
        laneHeardAt = [:]
        systemSegments = []
        micSegments = []
        systemPartialText = ""
        micPartialText = ""
        systemPartialTranslations = [:]
        micPartialTranslations = [:]
        systemPartialSpeaker = 0
        micPartialSpeaker = 0
        systemPartialMask = []
        micPartialMask = []
        systemPartial = false
        micPartial = false
        cursors.removeAll()
        lastActiveSource = nil
        autoSpokenID = nil
        autoSpokenKind = nil
        draftSource.removeAll()
        for (_, task) in translateTasks { task.cancel() }
        translateTasks.removeAll()
        for (_, task) in idleCommitTasks { task.cancel() }
        idleCommitTasks.removeAll()
        for (_, task) in draftTranslateTasks { task.cancel() }
        draftTranslateTasks.removeAll()
        hiddenSources.removeAll()
        laneDrafts = [:]
        dismissNotes(.system)
        dismissNotes(.microphone)
        dismissCombinedNote()
        for index in systemLanes.indices { systemLanes[index].marks = SpeakerMarkBook() }
        for index in micLanes.indices { micLanes[index].marks = SpeakerMarkBook() }
    }

    func clearDisplayedLane(_ laneID: UUID, _ kind: SourceKind) {
        let ids: Set<UUID>
        switch kind {
        case .system:
            ids = Set(systemSegments.filter { $0.laneID == laneID }.map(\.id))
            systemSegments.removeAll { $0.laneID == laneID }
        case .microphone:
            ids = Set(micSegments.filter { $0.laneID == laneID }.map(\.id))
            micSegments.removeAll { $0.laneID == laneID }
        }
        editLane(laneID, kind) { $0.marks = SpeakerMarkBook() }
        cursors[laneID] = isActive ? CaptionCursor(committed: cursors[laneID]?.lastFull ?? "", lastFull: "") : nil
        draftSource[laneID] = nil
        laneSpokenUntil[laneID] = sessionTime()
        laneHeardAt[laneID] = nil
        laneDrafts[laneID] = nil
        idleCommitTasks[laneID]?.cancel()
        idleCommitTasks[laneID] = nil
        cancelDrafts(laneID)
        mirrorPartial(kind)
        cancelTranslations { ids.contains($0) }
        if let spoken = autoSpokenID, ids.contains(spoken) {
            autoSpokenID = nil
            autoSpokenKind = nil
            stopSpeaking()
        }
        dismissNote(laneID, kind)
        if immersiveMode { refreshImmersiveOverlay() }
    }

    /// 批量删除：只把点名的段从列表里拿掉。删过的句子再被听到时会重新出现。
    func deleteSegments(_ ids: Set<UUID>, kind: SourceKind) {
        guard !ids.isEmpty else { return }
        switch kind {
        case .system:
            systemSegments.removeAll { ids.contains($0.id) }
        case .microphone:
            micSegments.removeAll { ids.contains($0.id) }
        }
        cancelTranslations { ids.contains($0) }
        if let spoken = autoSpokenID, ids.contains(spoken) {
            autoSpokenID = nil
            autoSpokenKind = nil
            stopSpeaking()
        }
        if immersiveMode { refreshImmersiveOverlay() }
    }

    func deleteSegment(id: UUID, kind: SourceKind) {
        switch kind {
        case .system:
            systemSegments.removeAll { $0.id == id }
        case .microphone:
            micSegments.removeAll { $0.id == id }
        }
        cancelTranslations { $0 == id }
        if autoSpokenID == id {
            autoSpokenID = nil
            autoSpokenKind = nil
            stopSpeaking()
        }
        if immersiveMode { refreshImmersiveOverlay() }
    }

    func updateSegment(id: UUID, kind: SourceKind, source: String, translation: String?, providerID: String) {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            deleteSegment(id: id, kind: kind)
            return
        }
        func patch(_ arr: inout [LiveCaptionSegment]) {
            guard let i = arr.firstIndex(where: { $0.id == id }) else { return }
            if arr[i].source != trimmed {
                hideSource(arr[i].source, kind: kind)
                arr[i].source = trimmed
                arr[i].maskRanges = []
            }
            if let translation, !providerID.isEmpty {
                let tr = translation.trimmingCharacters(in: .whitespacesAndNewlines)
                arr[i].loadingProviderIDs.remove(providerID)
                if tr.isEmpty || tr == "—" || tr == L("翻译中…") {
                    arr[i].translations.removeValue(forKey: providerID)
                } else {
                    arr[i].translations[providerID] = tr
                    arr[i].errors.removeValue(forKey: providerID)
                }
            }
        }
        switch kind {
        case .system: patch(&systemSegments)
        case .microphone: patch(&micSegments)
        }
        if immersiveMode { refreshImmersiveOverlay() }
    }

    func refreshLiveProviders() {
        seedLanes()
        let all = AppConfig.shared.catalogTargets()
        liveProviderNames = Dictionary(all.map { ($0.id, $0.displayName) }, uniquingKeysWith: { a, _ in a })
        var seen: [String] = []
        for id in (systemLanes + micLanes).flatMap(\.translateIDs) where !seen.contains(id) {
            seen.append(id)
        }
        liveRealtimeIDs = seen.filter { id in all.first { $0.id == id }?.suitsLiveTranslation == true }
        liveOtherIDs = seen.filter { !liveRealtimeIDs.contains($0) }
        liveProviderIDs = liveRealtimeIDs + liveOtherIDs
        migrateImmersiveKeys()
        let valid = Set(immersiveChips().map(\.key))
        for id in immersiveOn where !valid.contains(id) { hideImmersiveOverlay(id) }
        immersiveOn.removeAll { !valid.contains($0) }
        UserDefaults.standard.set(immersiveOn, forKey: "live.immersiveProviders")
        for id in immersiveOn {
            if immersivePanes[id] == nil { immersivePanes[id] = loadPane(id) }
            showImmersiveOverlay(id)
        }
        let names = liveProviderIDs.compactMap { id in
            liveProviderNames[id] ?? (id == LaneBinding.interpID ? LaneBindingNames.service(id) : nil)
        }
        translateEngineLabel = names.isEmpty ? L("不翻译") : names.joined(separator: " / ")
    }

    private func defaultBindings(_ kind: SourceKind, asrID: String? = nil) -> [LaneBinding] {
        if let asrID, let wire = AppConfig.shared.interpWire(asrID) {
            return [LaneBinding(translateID: LaneBinding.interpID, target: Self.interpTarget(lastTarget(for: kind), wire: wire))]
        }
        let ids = AppConfig.shared.translateTargets(.live).map(\.id)
        let target = lastTarget(for: kind)
        let list = ids.map { LaneBinding(translateID: $0, target: target) }
        return list.isEmpty ? [.source] : list
    }

    func seedLanes() {
        let asr = AppConfig.shared.resolvedLiveAsr()
        if systemLanes.isEmpty {
            systemLanes = [RecognitionLane(asrID: asr, bindings: defaultBindings(.system, asrID: asr))]
        }
        if micLanes.isEmpty {
            micLanes = [RecognitionLane(asrID: asr, bindings: defaultBindings(.microphone, asrID: asr))]
        }
    }

    func addRecognitionLane(_ kind: SourceKind, asrID: String) {
        guard Pro.unlocked else { return }
        seedLanes()
        var list = lanes(kind)
        guard !list.contains(where: { $0.asrID == asrID }) else { return }
        let lane = RecognitionLane(asrID: asrID, bindings: defaultBindings(kind, asrID: asrID))
        list.append(lane)
        if kind == .system { systemLanes = list } else { micLanes = list }
        refreshLiveProviders()
        guard isActive else { return }
        let fan = kind == .system ? systemFan : micFan
        if let sink = try? makeSink(lane, source: kind) {
            try? sink.prepare()
            sink.startRecognition()
            fan.children.append(sink)
        }
    }

    /// Only while stopped: a running lane owns a recognizer on the capture's fan.
    func removeRecognitionLane(_ laneID: UUID, _ kind: SourceKind) {
        guard !isActive, lanes(kind).count > 1, let lane = lanes(kind).first(where: { $0.id == laneID }) else { return }
        let wasFirst = lanes(kind).first?.id == laneID
        for key in lane.bindingKeys {
            let full = immersiveKey(kind, lane.asrID, key)
            if immersiveOn.contains(full) { setImmersive(full, on: false) }
        }
        noteTasks[laneID]?.cancel()
        noteTasks[laneID] = nil
        let ids: Set<UUID>
        switch kind {
        case .system:
            ids = Set(systemSegments.filter { $0.laneID == laneID }.map(\.id))
            systemSegments.removeAll { $0.laneID == laneID }
            systemLanes.removeAll { $0.id == laneID }
        case .microphone:
            ids = Set(micSegments.filter { $0.laneID == laneID }.map(\.id))
            micSegments.removeAll { $0.laneID == laneID }
            micLanes.removeAll { $0.id == laneID }
        }
        laneDrafts[laneID] = nil
        cursors[laneID] = nil
        draftSource[laneID] = nil
        laneSpokenUntil[laneID] = nil
        laneHeardAt[laneID] = nil
        idleCommitTasks[laneID]?.cancel()
        idleCommitTasks[laneID] = nil
        cancelDrafts(laneID)
        cancelTranslations { ids.contains($0) }
        if let spoken = autoSpokenID, ids.contains(spoken) {
            autoSpokenID = nil
            autoSpokenKind = nil
            stopSpeaking()
        }
        mirrorPartial(kind)
        if wasFirst { clampAsrLocale(for: kind) }
        refreshLiveProviders()
        if immersiveMode { refreshImmersiveOverlay() }
    }

    func setLaneEngine(_ laneID: UUID, _ kind: SourceKind, _ asrID: String) {
        guard !isActive, let lane = lanes(kind).first(where: { $0.id == laneID }), lane.asrID != asrID,
              !lanes(kind).contains(where: { $0.asrID == asrID }) else { return }
        for key in lane.bindingKeys {
            moveImmersive(from: immersiveKey(kind, lane.asrID, key), to: immersiveKey(kind, asrID, key))
        }
        let wire = AppConfig.shared.interpWire(asrID)
        let seeded = defaultBindings(kind, asrID: asrID)
        editLane(laneID, kind) { lane in
            lane.asrID = asrID
            if wire == nil {
                // Without a 同传服务 the binding it filled has nothing to say.
                for binding in lane.bindings where binding.isInterp { lane.removeBinding(binding.key) }
            } else if lane.interpBinding == nil, let first = seeded.first {
                lane.bindings.insert(first, at: 0)
            }
        }
        if lanes(kind).first?.id == laneID { clampAsrLocale(for: kind) }
        refreshLiveProviders()
    }

    func immersiveChips() -> [(key: String, title: String)] {
        var out: [(key: String, title: String)] = []
        for kind in SourceKind.allCases {
            for lane in lanes(kind) {
                let asr = AppConfig.shared.liveASRChoices().first { $0.id == lane.asrID }?.name ?? lane.asrID
                for binding in lane.bindings {
                    out.append((key: immersiveKey(kind, lane.asrID, binding.key), title: "\(asr) · \(LaneBindingNames.title(binding))"))
                }
            }
        }
        return out
    }

    func immersiveKey(_ kind: SourceKind, _ asrID: String, _ bindingKey: String) -> String {
        "\(kind.rawValue)|\(asrID)|\(bindingKey)"
    }

    private func parseImmersiveKey(_ key: String) -> (kind: SourceKind, lane: RecognitionLane, binding: LaneBinding)? {
        let parts = key.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let kind = SourceKind(rawValue: parts[0]),
              let lane = lanes(kind).first(where: { $0.asrID == parts[1] }),
              let binding = LaneBinding(key: parts[2]) else { return nil }
        return (kind, lane, binding)
    }

    /// Keeps a block on screen, where it was, when its binding is edited.
    private func moveImmersive(from old: String, to new: String) {
        guard old != new, immersiveOn.contains(old) else { return }
        let pane = immersivePanes[old] ?? loadPane(old)
        if let w = immersiveBoxes[old]?.window {
            Self.persistImmersiveCenter(new, NSPoint(x: w.frame.midX, y: w.frame.midY))
        }
        hideImmersiveOverlay(old)
        immersiveBoxes[old] = nil
        immersivePanes[old] = nil
        if speakingProviderID == old { speakingProviderID = new }
        immersiveOn = immersiveOn.map { $0 == old ? new : $0 }
        immersivePanes[new] = pane
        UserDefaults.standard.set(pane.showSource, forKey: "live.immersive.\(new).source")
        UserDefaults.standard.set(pane.showTranslation, forKey: "live.immersive.\(new).translation")
        UserDefaults.standard.set(immersiveOn, forKey: "live.immersiveProviders")
        showImmersiveOverlay(new)
    }

    /// Old keys named a service alone; they take the capture's last language.
    private func migrateImmersiveKeys() {
        var changed = false
        var next: [String] = []
        for id in immersiveOn {
            let parts = id.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            if parts.count == 3 {
                if parts[2] == LaneBinding.sourceID || parts[2].contains("@") {
                    next.append(id)
                } else if let kind = SourceKind(rawValue: parts[0]) {
                    next.append(immersiveKey(kind, parts[1], LaneBinding(translateID: parts[2], target: lastTarget(for: kind)).key))
                    changed = true
                }
                continue
            }
            changed = true
            for kind in SourceKind.allCases {
                for lane in lanes(kind) where lane.translateIDs.contains(id) {
                    next.append(immersiveKey(kind, lane.asrID, LaneBinding(translateID: id, target: lastTarget(for: kind)).key))
                }
            }
        }
        if changed { immersiveOn = next }
    }

    func captures(_ kind: SourceKind) -> Bool {
        kind == .system ? captureSystem : captureMicrophone
    }

    nonisolated private static let levelGate = NSLock()
    nonisolated(unsafe) private static var levelSentAt: [SourceKind: CFAbsoluteTime] = [:]

    /// Called per audio buffer from the lanes' queues; only ~15 per second reach the main actor.
    nonisolated static func reportLevel(_ source: SourceKind, rms: Float) {
        let now = CFAbsoluteTimeGetCurrent()
        levelGate.lock()
        if rms > 0, let last = levelSentAt[source], now - last < 0.066 {
            levelGate.unlock()
            return
        }
        levelSentAt[source] = now
        levelGate.unlock()
        let db = 20 * log10(Double(max(rms, 1e-7)))
        let level = min(1, max(0, (db + 50) / 44))
        Task { @MainActor in
            shared.applyLevel(source, level: level)
        }
    }

    private func applyLevel(_ source: SourceKind, level: Double) {
        let now = CFAbsoluteTimeGetCurrent()
        if let last = levelClock[source], now - last < 0.066 { return }
        levelClock[source] = now
        switch source {
        case .system: systemLevel = level
        case .microphone: micLevel = level
        }
    }

    private func resolveTranslateTarget(_ bindingKey: String) -> (TranslateTarget, TargetLanguage)? {
        guard let binding = LaneBinding(key: bindingKey), !binding.isSource,
              let target = AppConfig.shared.simultaneousTargets().first(where: { $0.id == binding.translateID }) else { return nil }
        return (target.applying(modelOverrides), binding.target)
    }

    private func makeSink(_ lane: RecognitionLane, source: SourceKind) throws -> any LiveAudioSink {
        let laneID = lane.id
        let onH: @Sendable (SourceKind, String, Bool, Int) -> Void = { [weak self] src, text, isFinal, speaker in
            Task { @MainActor [weak self] in
                self?.handleHypothesis(lane: laneID, source: src, text: text, isFinal: isFinal, speaker: speaker)
            }
        }
        let onBusy: @Sendable (SourceKind, Bool) -> Void = { [weak self] src, busy in
            Task { @MainActor [weak self] in
                self?.handleBusy(source: src, busy: busy)
            }
        }
        let onError: @Sendable (SourceKind, String) -> Void = { [weak self] _, message in
            Task { @MainActor [weak self] in
                self?.statusLine = String(format: L("识别出错：%@"), message)
            }
        }
        let cfg = AppConfig.shared
        if let wire = cfg.interpWire(lane.asrID) {
            let target = lane.interpBinding?.target ?? Self.interpTarget(lastTarget(for: source), wire: wire)
            return LiveInterpLane(
                laneID: laneID,
                source: source,
                engineID: lane.asrID,
                target: target,
                audio: true
            ) { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.handleInterp(lane: laneID, kind: source, event: event)
                }
            }
        }
        if #available(macOS 26.0, *), cfg.isAnalyzerASR(lane.asrID) {
            return LiveAnalyzerLane(
                source: source,
                locale: asrLanguage(for: source).locale,
                terms: cfg.asrContextTerms,
                onHypothesis: onH,
                onError: onError
            )
        }
        if cfg.isSystemASR(lane.asrID) {
            return LiveASRLane(
                source: source,
                locale: asrLanguage(for: source).locale,
                preferOnDevice: cfg.asrAppleOnDevice,
                terms: cfg.asrContextTerms,
                onHypothesis: onH
            )
        }
        let whisper = try cfg.asrWhisperConfig(selection: lane.asrID)
        return LiveWhisperLane(
            source: source,
            config: whisper,
            language: asrLanguage(for: source).whisperCode,
            prompt: cfg.asrContextPrompt,
            onHypothesis: onH,
            onBusy: onBusy,
            onError: onError
        )
    }

    private func handleBusy(source: SourceKind, busy: Bool) {
        guard case .listening = state else { return }
        switch source {
        case .system: systemPartial = busy
        case .microphone: micPartial = busy
        }
    }
    // MARK: Capture

    private func beginSCKAudioCapture() async throws {
        // SCShareableContent may block on TCC / window server — never await it on MainActor.
        let content = try await Task.detached(priority: .userInitiated) {
            try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }.value
        guard let display = content.displays.first else {
            throw TErr(L("未找到可捕获的显示器"))
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let conf = SCStreamConfiguration()
        conf.capturesAudio = true
        conf.excludesCurrentProcessAudio = true
        conf.width = 2
        conf.height = 2
        conf.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        conf.sampleRate = 48000
        conf.channelCount = 1

        let stream = SCStream(filter: filter, configuration: conf, delegate: nil)
        let sink = systemFan
        let output = SystemAudioStreamOutput { sampleBuffer in
            sink.append(sampleBuffer: sampleBuffer)
        }
        let audioQ = DispatchQueue(label: "com.sliiu.Korgino.sysaudio", qos: .userInitiated)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: audioQ)
        try await stream.startCapture()
        self.stream = stream
        self.streamOutput = output
        systemFan.startRecognition()
    }
}

extension SystemAudioTranslateController {
    /// 通话模式：只听通话软件（把译音设备当麦克风的那个），它的原声静音，耳机里只有同传译音。
    fileprivate func beginCallTapCapture() throws {
        let sink = systemFan
        let tap = ProcessTapCapture(relayUID: relayDeviceUID) { buffer in
            sink.append(pcm: buffer)
        }
        try tap.start()
        callTap = tap
        systemFan.startRecognition()
    }

    /// 通话模式里对方听不到声音的几种设置，开始前就拦下来，不让它静悄悄地失败。
    fileprivate func checkCallRelay(_ cfg: AppConfig) throws {
        guard !relayDeviceUID.isEmpty else { return }
        let relayName = AudioOutputs.devices().first { $0.uid == relayDeviceUID }?.name ?? relayDeviceUID
        guard captureMicrophone else {
            throw TErr(String(format: L("译音要送到「%@」，请打开「麦克风」这一路。"), relayName))
        }
        // Only a 同传 engine speaks. Recognition plus text translation sends nothing to the virtual device.
        guard micLanes.contains(where: { cfg.interpWire($0.asrID) != nil }) else {
            throw TErr(String(format: L("麦克风这一路要选同传引擎，才有译音送到「%@」。现在的识别引擎只出字幕。"), relayName))
        }
        // In a call the system input is usually the virtual device itself, so 系统默认 would listen to our own output.
        if MicInput.effectiveUID(chosen: micDeviceUID) == relayDeviceUID {
            throw TErr(String(format: L("麦克风这一路正在听「%@」，听不到你说话。请在麦克风设备里选真实的麦克风。"), relayName))
        }
    }
}

/// 被 LiveCaptionsView 里的麦克风选择读到，跨文件了要放宽。
enum MicInput {
    struct Device: Identifiable, Hashable {
        var uid: String
        var name: String
        var id: String { uid }
    }

    static func devices() -> [Device] {
        var listed: [Device] = []
        for id in objectIDs(AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDevices) {
            guard !objectIDs(id, selector: kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput).isEmpty,
                  let uid = copyString(id, selector: kAudioDevicePropertyDeviceUID),
                  let name = copyString(id, selector: kAudioObjectPropertyName) else { continue }
            listed.append(Device(uid: uid, name: name))
        }
        return listed.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func deviceID(uid: String) -> AudioDeviceID? {
        for id in objectIDs(AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDevices) {
            if copyString(id, selector: kAudioDevicePropertyDeviceUID) == uid { return id }
        }
        return nil
    }

    /// UID of the device the mic lane will actually listen to: the chosen one, or the system default input.
    static func effectiveUID(chosen: String) -> String? {
        if !chosen.isEmpty { return chosen }
        let ids = objectIDs(AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultInputDevice)
        guard let id = ids.first, id != 0 else { return nil }
        return copyString(id, selector: kAudioDevicePropertyDeviceUID)
    }

    private static func objectIDs(
        _ object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func copyString(_ object: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ref) == noErr, let ref else { return nil }
        return ref.takeRetainedValue() as String
    }

    /// `inputNode` has already initialized the unit on the default device.
    /// CurrentDevice is ignored until that initialization is cleared, and the
    /// engine then keeps the default input.
    static func select(_ deviceID: AudioDeviceID, on input: AVAudioInputNode) throws {
        guard let unit = input.audioUnit else { throw TErr(L("麦克风不可用")) }
        AudioUnitUninitialize(unit)
        var selected = deviceID
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &selected,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr { throw TErr(L("无法切换到这个麦克风")) }
    }
}

extension SystemAudioTranslateController {
    private func beginMicrophoneCapture() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        var choseDevice = false
        if !micDeviceUID.isEmpty, let deviceID = MicInput.deviceID(uid: micDeviceUID) {
            try MicInput.select(deviceID, on: input)
            choseDevice = true
        }
        let hw = input.inputFormat(forBus: 0)
        let format = (hw.sampleRate > 0 && hw.channelCount > 0) ? hw : input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw TErr(L("麦克风不可用（无输入格式）。请检查系统设置 › 声音 › 输入。"))
        }
        // Not a call, but the mic lane is still listening to the virtual device — chosen, or reached through
        // 系统默认. It starts fine and hears silence, which looks like the app ignoring you. Say so instead.
        micOnRelay = !relayDeviceUID.isEmpty && MicInput.effectiveUID(chosen: micDeviceUID) == relayDeviceUID
        // A chosen mic is often input-only, or running at another rate than the
        // speakers. Connecting it to the mixer makes start() fail with -10875.
        // The default device already shares the output graph, so it still does.
        if !choseDevice {
            engine.connect(input, to: engine.mainMixerNode, format: format)
            engine.mainMixerNode.outputVolume = 0
        }
        let sink = micFan
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            guard let copy = buffer.detachedCopy() else { return }
            sink.append(pcm: copy)
        }
        engine.prepare()
        try engine.start()
        audioEngine = engine
        if choseDevice {
            let uid = micDeviceUID
            micWatch = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, MicInput.deviceID(uid: uid) == nil else { return }
                    // Not switching to the default input: in a call that is often BlackHole, which would loop.
                    self.statusLine = L("麦克风已断开，你说的话不会再翻译。请重新连接后停止再开始。")
                }
            }
        }
        sink.startRecognition()
    }

    /// Segments stay on screen after Stop, so their translations already in flight are left to finish.
    private func teardownAll() async {
        for (_, task) in idleCommitTasks { task.cancel() }
        idleCommitTasks.removeAll()
        for (_, task) in draftTranslateTasks { task.cancel() }
        draftTranslateTasks.removeAll()
        systemFan.stop()
        micFan.stop()
        collectRecordings()
        interpLanes.removeAll()
        InterpPlayer.shared.stop()
        InterpPlayer.relay.stop()
        // Segments still waiting on a 同传 line will not get one now.
        for i in systemSegments.indices { systemSegments[i].loadingProviderIDs = systemSegments[i].loadingProviderIDs.filter { !($0.hasPrefix(LaneBinding.interpID + "@")) } }
        for i in micSegments.indices { micSegments[i].loadingProviderIDs = micSegments[i].loadingProviderIDs.filter { !($0.hasPrefix(LaneBinding.interpID + "@")) } }
        callTap?.stop()
        callTap = nil
        inCall = false
        micOnRelay = false
        if let micWatch { NotificationCenter.default.removeObserver(micWatch) }
        micWatch = nil
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        streamOutput = nil
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        audioEngine = nil
    }

    // MARK: 同传 lanes

    /// 同传那一路：一句原文就是一段字幕，服务给的译文按句挂上去。
    fileprivate struct InterpLaneState {
        var segments: [String: UUID] = [:]
        var targets: [String: (source: String?, text: String, final: Bool)] = [:]
        var targetOrder: [String] = []
        var lastSource: String?

        func translation(for source: String) -> String {
            InterpText.join(targetOrder.compactMap { id in
                guard let t = targets[id], t.source == source else { return nil }
                return t.text
            })
        }

        func finished(_ source: String) -> Bool {
            targetOrder.contains { targets[$0]?.source == source && targets[$0]?.final == true }
        }
    }

    private func handleInterp(lane laneID: UUID, kind: SourceKind, event: InterpEvent) {
        guard case .listening = state, let lane = lanes(kind).first(where: { $0.id == laneID }) else { return }
        var st = interpLanes[laneID] ?? InterpLaneState()
        let key = lane.interpBinding?.key
        switch event {
        case .ready:
            return
        case .failed(let message):
            statusLine = String(format: L("同传出错：%@"), message)
        case .audio(let pcm):
            InterpPlayer.shared.gain = Float(interpGain)
            if inCall {
                // 通话：我说的译音给对方，对方说的译音给我，都不用点朗读。
                if kind == .microphone {
                    InterpPlayer.relay.route(to: relayDeviceUID)
                    InterpPlayer.relay.play(pcm)
                } else {
                    InterpPlayer.shared.play(pcm)
                }
                return
            }
            guard let key else { return }
            let pane = immersiveKey(kind, lane.asrID, key)
            guard speakingProviderID == pane, let state = immersivePanes[pane],
                  state.speechPlaying, state.showTranslation else { return }
            InterpPlayer.shared.play(pcm)
        case .source(let id, let text, let final, let speaker):
            lastActiveSource = kind
            st.lastSource = id
            interpLanes[laneID] = st
            let plain = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if final {
                if CaptionCut.letterCount(plain) >= 1, st.segments[id] == nil {
                    commitInterpSegment(lane, kind: kind, item: id, text: plain, speaker: speaker)
                } else {
                    clearPartial(laneID, kind)
                }
            } else if !plain.isEmpty {
                setPartial(laneID, kind, text: plain, speaker: speaker)
                if let key {
                    let shown = st.translation(for: id)
                    if !shown.isEmpty { setPartialTranslation(laneID, kind, key, shown) }
                }
                if immersiveMode { refreshImmersiveOverlay() }
            }
        case .target(let id, let sourceID, let text, let final):
            let src = sourceID ?? st.targets[id]?.source ?? st.lastSource
            if st.targets[id] == nil { st.targetOrder.append(id) }
            let language = lane.interpBinding?.target ?? .en
            st.targets[id] = (src, InterpText.shaped(text, for: language), final)
            interpLanes[laneID] = st
            guard let key, let src else { return }
            let shown = st.translation(for: src)
            if let segID = st.segments[src] {
                let done = st.finished(src)
                func patch(_ arr: inout [LiveCaptionSegment]) {
                    guard let i = arr.firstIndex(where: { $0.id == segID }) else { return }
                    arr[i].translations[key] = shown
                    if done { arr[i].loadingProviderIDs.remove(key) }
                }
                patch(&systemSegments)
                patch(&micSegments)
                if immersiveMode { refreshImmersiveOverlay() }
                if done { autoSpeakLatest() }
            } else if laneDrafts[laneID]?.partial == true, st.lastSource == src {
                setPartialTranslation(laneID, kind, key, shown)
                if immersiveMode { refreshImmersiveOverlay() }
            }
        }
    }

    private func commitInterpSegment(_ lane: RecognitionLane, kind: SourceKind, item: String, text: String, speaker: Int) {
        let shownSource = stripHidden(text, kind: kind)
        guard !shownSource.isEmpty, let stamp = timedPieces([shownSource], lane: lane.id).first else {
            clearPartial(lane.id, kind)
            return
        }
        let st = interpLanes[lane.id] ?? InterpLaneState()
        let interpKey = lane.interpBinding?.key
        var translations: [String: String] = [:]
        var loading = Set<String>()
        for key in lane.translatingKeys {
            if key == interpKey {
                let shown = st.translation(for: item)
                if !shown.isEmpty { translations[key] = shown }
                if !st.finished(item) { loading.insert(key) }
            } else {
                loading.insert(key)
            }
        }
        let seg = LiveCaptionSegment(
            id: UUID(),
            laneID: lane.id,
            kind: kind,
            source: shownSource,
            speaker: marksResolve(lane.id, kind, speaker),
            translations: translations,
            errors: [:],
            loadingProviderIDs: loading,
            maskRanges: [],
            start: stamp.start,
            end: max(stamp.end, stamp.start + 0.2)
        )
        switch kind {
        case .system: systemSegments.append(seg)
        case .microphone: micSegments.append(seg)
        }
        var next = st
        next.segments[item] = seg.id
        interpLanes[lane.id] = next
        clearPartial(lane.id, kind)
        idleCommitTasks[lane.id]?.cancel()
        idleCommitTasks[lane.id] = nil
        for key in loading where key != interpKey {
            translateSegment(seg, providerID: key)
        }
        if let interpKey, loading.contains(interpKey) {
            // Same-language speech gets no translation back. Stop waiting after a while.
            let segID = seg.id
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard let self else { return }
                func settle(_ arr: inout [LiveCaptionSegment]) {
                    guard let i = arr.firstIndex(where: { $0.id == segID }) else { return }
                    arr[i].loadingProviderIDs.remove(interpKey)
                }
                settle(&self.systemSegments)
                settle(&self.micSegments)
            }
        }
        if immersiveMode { refreshImmersiveOverlay() }
        autoSpeakLatest()
        tagVoice(seg)
    }

    // MARK: ASR → Translate

    private func handleHypothesis(lane: UUID, source: SourceKind, text: String, isFinal: Bool, speaker heard: Int) {
        guard case .listening = state else { return }
        // With the voiceprint model, the speaker is set per finished segment instead (`tagVoice`).
        let speaker = voiceTaggers[source] != nil ? 0 : marksResolve(lane, source, heard)
        let full = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !full.isEmpty else { return }
        lastActiveSource = source

        var cursor = cursors[lane] ?? CaptionCursor()
        if !full.hasPrefix(cursor.committed) {
            let common = Self.commonPrefix(cursor.committed, full)
            if !cursor.committed.isEmpty, common.count >= 8, common.count * 3 >= cursor.committed.count * 2 {
                cursor.committed = common
            } else {
                cursor.committed = ""
            }
        }
        if !full.hasPrefix(cursor.committed) {
            cursor.committed = ""
        }
        let tail = String(full.dropFirst(cursor.committed.count))
        let parts = CaptionCut.split(tail, finishAll: isFinal)
        var ready: [String] = []
        for piece in parts.ready {
            let display = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            if CaptionCut.letterCount(display) >= 2 {
                ready.append(display)
            }
            cursor.committed += piece
        }
        for stamp in timedPieces(ready, lane: lane) {
            commitSegment(lane: lane, kind: source, sourceText: stamp.text, speaker: speaker, start: stamp.start, end: stamp.end)
        }
        if isFinal {
            cursors[lane] = CaptionCursor()
            clearPartial(lane, source)
            return
        }
        cursor.lastFull = full
        cursors[lane] = cursor

        let held = parts.held.trimmingCharacters(in: .whitespacesAndNewlines)
        if held.isEmpty || CaptionCut.letterCount(held) == 0 {
            cursor.committed += parts.held
            cursors[lane] = cursor
            clearPartial(lane, source)
            idleCommitTasks[lane]?.cancel()
            idleCommitTasks[lane] = nil
            cancelDrafts(lane)
            return
        }
        let previous = laneDrafts[lane]?.text ?? ""
        setPartial(lane, source, text: held, speaker: speaker)
        if previous != held {
            scheduleIdleCommit(lane: lane, source: source, text: held)
            scheduleDraftTranslate(lane: lane, source: source, text: held)
        }
        if immersiveMode { refreshImmersiveOverlay() }
    }

    private func scheduleIdleCommit(lane: UUID, source: SourceKind, text: String) {
        idleCommitTasks[lane]?.cancel()
        let ended = text.last.map { "。！？!?…．".contains($0) } ?? false
        let delay: UInt64 = ended ? 1_600_000_000 : 2_400_000_000
        idleCommitTasks[lane] = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, case .listening = self.state else { return }
            guard self.laneDrafts[lane]?.text == text, !text.isEmpty else { return }
            self.finishHeld(lane: lane, source: source)
        }
    }

    private func finishHeld(lane: UUID, source: SourceKind) {
        let held = (laneDrafts[lane]?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard CaptionCut.letterCount(held) >= 2 else { return }
        var cursor = cursors[lane] ?? CaptionCursor()
        if !cursor.lastFull.isEmpty {
            cursor.committed = cursor.lastFull
        }
        cursors[lane] = cursor
        let speaker = laneDrafts[lane]?.speaker ?? 0
        let lines = CaptionCut.split(held, finishAll: true).ready.compactMap { piece -> String? in
            let display = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            return CaptionCut.letterCount(display) >= 2 ? display : nil
        }
        for stamp in timedPieces(lines.isEmpty ? [held] : lines, lane: lane) {
            commitSegment(lane: lane, kind: source, sourceText: stamp.text, speaker: speaker, start: stamp.start, end: stamp.end)
        }
        clearPartial(lane, source)
    }

    private static func commonPrefix(_ a: String, _ b: String) -> String {
        var i = a.startIndex
        var j = b.startIndex
        while i < a.endIndex, j < b.endIndex, a[i] == b[j] {
            i = a.index(after: i)
            j = b.index(after: j)
        }
        return String(a[..<i])
    }

    private func setPartial(_ lane: UUID, _ source: SourceKind, text: String, speaker: Int) {
        var draft = laneDrafts[lane] ?? LaneDraft()
        if draft.text != text { draft.mask = [] }
        draft.text = text
        draft.speaker = speaker
        draft.partial = true
        laneDrafts[lane] = draft
        noteHeard(lane)
        mirrorPartial(source)
    }

    /// First words of the next line on this lane: that is where its time starts, not where the last line ended.
    private func noteHeard(_ lane: UUID) {
        guard laneHeardAt[lane] == nil else { return }
        laneHeardAt[lane] = sessionTime()
    }

    private func setPartialTranslation(_ lane: UUID, _ source: SourceKind, _ provider: String, _ text: String) {
        var draft = laneDrafts[lane] ?? LaneDraft()
        draft.translations[provider] = text
        laneDrafts[lane] = draft
        mirrorPartial(source)
    }

    private func clearPartial(_ lane: UUID, _ source: SourceKind) {
        laneDrafts[lane] = nil
        laneHeardAt[lane] = nil
        mirrorPartial(source)
        cancelDrafts(lane)
    }

    private func mirrorPartial(_ source: SourceKind) {
        let lanes = source == .system ? systemLanes : micLanes
        let draft = lanes.compactMap { laneDrafts[$0.id] }.last { $0.partial }
        switch source {
        case .system:
            systemPartial = draft != nil
            systemPartialText = draft?.text ?? ""
            systemPartialTranslations = draft?.translations ?? [:]
            systemPartialSpeaker = draft?.speaker ?? 0
            systemPartialMask = draft?.mask ?? []
        case .microphone:
            micPartial = draft != nil
            micPartialText = draft?.text ?? ""
            micPartialTranslations = draft?.translations ?? [:]
            micPartialSpeaker = draft?.speaker ?? 0
            micPartialMask = draft?.mask ?? []
        }
    }

    private func cancelDrafts(_ lane: UUID) {
        for key in draftTranslateTasks.keys where key.lane == lane {
            draftTranslateTasks[key]?.cancel()
            draftTranslateTasks[key] = nil
        }
    }

    private func scheduleDraftTranslate(lane: UUID, source: SourceKind, text: String) {
        cancelDrafts(lane)
        let asr = (systemLanes + micLanes).first { $0.id == lane }?.asrID ?? ""
        let providers = (systemLanes + micLanes).first { $0.id == lane }?.translatingKeys.filter { key in
            immersiveOn.contains(immersiveKey(source, asr, key))
        } ?? []
        guard !providers.isEmpty else {
            var draft = laneDrafts[lane] ?? LaneDraft()
            draft.translations = [:]
            laneDrafts[lane] = draft
            return
        }
        for pid in providers {
            let key = DraftKey(lane: lane, provider: pid)
            draftTranslateTasks[key] = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 420_000_000)
                guard !Task.isCancelled, case .listening = self.state else { return }
                guard self.laneDrafts[lane]?.text == text, !text.isEmpty else { return }
                await self.translateDraft(lane: lane, source: source, provider: pid, text: text)
            }
        }
    }

    private func translateDraft(lane: UUID, source: SourceKind, provider: String, text: String) async {
        guard let (target, language) = resolveTranslateTarget(provider) else { return }
        let plan = Lang.plan(text, target: language, source: asrLanguage(for: source).appleSource)
        do {
            let sent = try await Background.run {
                try await Translator.translateLive(text, target: target, plan: plan)
            }
            guard laneDrafts[lane]?.text == text else { return }
            draftSource[lane] = text
            setPartialTranslation(lane, source, provider, sent.text)
            var draft = laneDrafts[lane] ?? LaneDraft()
            draft.mask = sent.maskRanges
            laneDrafts[lane] = draft
            mirrorPartial(source)
            refreshImmersiveOverlay()
        } catch {
            if error is MaskDeclined { return }
            guard laneDrafts[lane]?.text == text else { return }
            setPartialTranslation(lane, source, provider, String(format: L("翻译失败：%@"), error.localizedDescription))
        }
    }

    private func sessionTime() -> TimeInterval {
        guard let sessionStartedAt else { return 0 }
        return max(0, Date().timeIntervalSince(sessionStartedAt))
    }

    private func timedPieces(_ pieces: [String], lane: UUID) -> [(text: String, start: TimeInterval, end: TimeInterval)] {
        guard !pieces.isEmpty else { return [] }
        let now = sessionTime()
        let spokenUntil = laneSpokenUntil[lane] ?? 0
        // Start where these words were first heard. With no draft seen (a final out of nowhere, a 同传 line),
        // guess back from how long the words take to say, so the first line is not pinned to 0.
        let heard = laneHeardAt[lane] ?? (now - Self.spokenDuration(pieces))
        laneHeardAt[lane] = nil
        let origin = min(max(spokenUntil, heard), now)
        let span = max(now - origin, Double(pieces.count) * 0.4)
        let slice = span / Double(pieces.count)
        var out: [(text: String, start: TimeInterval, end: TimeInterval)] = []
        for (index, text) in pieces.enumerated() {
            let start = origin + slice * Double(index)
            let end = max(origin + slice * Double(index + 1), start + 0.2)
            out.append((text, start, end))
        }
        if let last = out.last { laneSpokenUntil[lane] = last.end }
        return out
    }

    /// Rough time to say these words: about 4 Han characters or 2.5 Latin words a second.
    private static func spokenDuration(_ pieces: [String]) -> TimeInterval {
        var seconds = 0.0
        for piece in pieces {
            var han = 0
            for scalar in piece.unicodeScalars where (0x3400...0x9FFF).contains(scalar.value) || (0x3040...0x30FF).contains(scalar.value) || (0xAC00...0xD7AF).contains(scalar.value) {
                han += 1
            }
            let words = piece.split { $0.isWhitespace }.count
            seconds += Double(han) * 0.25 + Double(max(0, words - (han > 0 ? 1 : 0))) * 0.4
        }
        return min(max(seconds, 0.8), 12)
    }

    private func commitSegment(
        lane: UUID,
        kind: SourceKind,
        sourceText: String,
        speaker: Int,
        start: TimeInterval,
        end: TimeInterval
    ) {
        let fresh = novelCaption(sourceText, lane: lane, kind: kind)
        guard !fresh.isEmpty else { return }
        let prior = (kind == .system ? systemSegments : micSegments).filter { $0.laneID == lane }
        if prior.last?.source == fresh { return }
        if let last = prior.last?.source, last.hasPrefix(fresh), last.count - fresh.count < 4 { return }
        let providers = (systemLanes + micLanes).first { $0.id == lane }?.translatingKeys ?? []
        var translations: [String: String] = [:]
        var loading = Set<String>()
        let drafts = laneDrafts[lane]?.translations ?? [:]
        let drafted = draftSource[lane] ?? ""
        let mask = laneDrafts[lane]?.mask ?? []
        var draftMask: [NSRange] = []
        for pid in providers {
            let draft = drafts[pid] ?? ""
            let usable = !draft.isEmpty && !draft.hasPrefix(L("翻译失败"))
                && (drafted == fresh || fresh.hasPrefix(drafted) || drafted.hasPrefix(fresh))
            if usable {
                translations[pid] = draft
                if drafted == fresh { draftMask = mask }
            } else {
                loading.insert(pid)
            }
        }
        let seg = LiveCaptionSegment(
            id: UUID(),
            laneID: lane,
            kind: kind,
            source: fresh,
            speaker: speaker,
            translations: translations,
            errors: [:],
            loadingProviderIDs: loading,
            maskRanges: draftMask,
            start: start,
            end: max(end, start + 0.2)
        )
        switch kind {
        case .system: systemSegments.append(seg)
        case .microphone: micSegments.append(seg)
        }
        clearPartial(lane, kind)
        idleCommitTasks[lane]?.cancel()
        idleCommitTasks[lane] = nil
        for pid in loading {
            translateSegment(seg, providerID: pid)
        }
        tagVoice(seg)
        if immersiveMode { refreshImmersiveOverlay() }
        autoSpeakLatest()
        refreshFollowingNotes()
    }

    private func novelCaption(_ text: String, lane: UUID, kind: SourceKind) -> String {
        let prior = (kind == .system ? systemSegments : micSegments).filter { $0.laneID == lane }
        var rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let recent = Array(prior.suffix(24))
        var index = 0
        while index < recent.count, !rest.isEmpty {
            let seg = recent[index].source.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !seg.isEmpty, let next = Self.dropping(rest, coveredBy: seg) else { break }
            let trimmed = next.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count >= rest.count { break }
            rest = trimmed
            index += 1
        }
        return stripHidden(rest, kind: kind)
    }

    private func hideSource(_ text: String, kind: SourceKind) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CaptionCut.letterCount(trimmed) >= 2 else { return }
        var list = hiddenSources[kind] ?? []
        if !list.contains(trimmed) { list.append(trimmed) }
        if list.count > 40 { list.removeFirst(list.count - 40) }
        hiddenSources[kind] = list
    }

    private func stripHidden(_ text: String, kind: SourceKind) -> String {
        var rest = text
        let hidden = hiddenSources[kind] ?? []
        guard !hidden.isEmpty else { return rest }
        var rounds = 0
        while rounds < 8, !rest.isEmpty {
            rounds += 1
            var dropped = false
            for seg in hidden {
                guard let next = Self.dropping(rest, coveredBy: seg) else { continue }
                let trimmed = next.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count < rest.count {
                    rest = trimmed
                    dropped = true
                    break
                }
            }
            if !dropped { break }
        }
        return rest
    }

    private static func dropping(_ raw: String, coveredBy segment: String) -> String? {
        let target = bare(segment)
        guard !target.isEmpty else { return nil }
        var t = target.startIndex
        var i = raw.startIndex
        while t < target.endIndex, i < raw.endIndex {
            let ch = raw[i]
            if isJoiner(ch) {
                i = raw.index(after: i)
                continue
            }
            if ch != target[t] { return nil }
            t = target.index(after: t)
            i = raw.index(after: i)
        }
        guard t == target.endIndex else { return nil }
        let atBoundary = i == raw.endIndex || isJoiner(raw[i])
        if !atBoundary, target.count < 4 { return nil }
        while i < raw.endIndex, isJoiner(raw[i]) {
            i = raw.index(after: i)
        }
        return String(raw[i...])
    }

    private static func bare(_ text: String) -> String {
        String(text.filter { !isJoiner($0) })
    }

    private static func isJoiner(_ ch: Character) -> Bool {
        "。！？!?…．，,、；;：: \n\t".contains(ch)
    }

    private func translateSegment(_ seg: LiveCaptionSegment, providerID: String) {
        guard let (target, language) = resolveTranslateTarget(providerID) else { return }
        let segID = seg.id
        let sourceText = seg.source
        let plan = Lang.plan(sourceText, target: language, source: asrLanguage(for: seg.kind).appleSource)
        let key = TranslateKey(segment: segID, provider: providerID)
        translateTasks[key]?.cancel()
        translateTasks[key] = Task { @MainActor in
            let result: Result<Translator.LiveSend, Error>
            do {
                let sent = try await Background.run {
                    try await Translator.translateLive(sourceText, target: target, plan: plan)
                }
                result = .success(sent)
            } catch {
                result = .failure(error)
            }
            if Task.isCancelled { return }
            self.applyTranslation(segmentID: segID, providerID: providerID, result: result)
            translateTasks[key] = nil
        }
    }

    private func cancelTranslations(where match: (UUID) -> Bool) {
        for key in translateTasks.keys where match(key.segment) {
            translateTasks[key]?.cancel()
            translateTasks[key] = nil
        }
    }

    private func markLoading(segmentID: UUID, providerID: String) {
        func patch(_ arr: inout [LiveCaptionSegment]) {
            guard let i = arr.firstIndex(where: { $0.id == segmentID }) else { return }
            arr[i].loadingProviderIDs.insert(providerID)
        }
        patch(&systemSegments)
        patch(&micSegments)
    }

    private func applyTranslation(segmentID: UUID, providerID: String, result: Result<Translator.LiveSend, Error>) {
        func patch(_ arr: inout [LiveCaptionSegment]) {
            guard let i = arr.firstIndex(where: { $0.id == segmentID }) else { return }
            arr[i].loadingProviderIDs.remove(providerID)
            switch result {
            case .success(let sent):
                arr[i].translations[providerID] = sent.text
                arr[i].errors.removeValue(forKey: providerID)
                arr[i].maskRanges = sent.maskRanges
            case .failure(let e):
                if e is MaskDeclined { return }
                arr[i].maskRanges = []
                arr[i].errors[providerID] = String(format: L("翻译失败：%@"), String(describing: e.localizedDescription))
            }
        }
        patch(&systemSegments)
        patch(&micSegments)
        if immersiveMode { refreshImmersiveOverlay() }
        autoSpeakLatest()
        refreshFollowingNotes()
    }

    // MARK: Immersive overlay + TTS

    func immersiveLines(for key: String) -> ImmersiveCaptionLines {
        guard let (kind, lane, binding) = parseImmersiveKey(key) else { return ImmersiveCaptionLines() }
        let segs = (kind == .system ? systemSegments : micSegments).filter { $0.laneID == lane.id }
        let draft = laneDrafts[lane.id]
        var lines = ImmersiveCaptionLines()
        let speaker = (draft?.partial == true && !(draft?.text ?? "").isEmpty) ? (draft?.speaker ?? 0) : (segs.last?.speaker ?? 0)
        lines.mark = markToken(lane: lane.id, kind: kind, speaker: speaker) ?? ""
        if let draft, draft.partial, !draft.text.isEmpty {
            lines.source = draft.text
            lines.sourcePartial = true
            lines.sourceMask = draft.mask
            if !binding.isSource {
                lines.translation = draft.translations[binding.key] ?? ""
                lines.translationPartial = !lines.translation.isEmpty
            }
        } else if let last = segs.last {
            lines.source = last.source
            lines.sourceMask = last.maskRanges
            if !binding.isSource { lines.translation = translationText(last, providerID: binding.key) }
        }
        return lines
    }

    func immersiveIsSource(_ key: String) -> Bool {
        parseImmersiveKey(key)?.binding.isSource ?? false
    }

    func immersiveTitle(_ key: String) -> String {
        guard let (_, lane, binding) = parseImmersiveKey(key) else { return key }
        let asr = AppConfig.shared.liveASRChoices().first { $0.id == lane.asrID }?.name ?? lane.asrID
        return "\(asr) · \(LaneBindingNames.title(binding))"
    }

    private func translationText(_ seg: LiveCaptionSegment, providerID: String) -> String {
        guard !providerID.isEmpty else { return "" }
        if let tr = seg.translations[providerID], !tr.isEmpty { return tr }
        if let err = seg.errors[providerID], !err.isEmpty, !seg.loadingProviderIDs.contains(providerID) { return err }
        return ""
    }

    func markToken(lane: UUID, kind: SourceKind, speaker: Int) -> String? {
        let lanes = kind == .system ? systemLanes : micLanes
        let match = lanes.first { $0.id == lane }
        return (match?.marks ?? SpeakerMarkBook()).token(speaker: speaker, fallback: "[\(L("说话人")) \(speaker)]")
    }

    /// 这一条轨的可挑段，按说话人、时段和逐条列表都要用。
    func batchCues(_ lane: UUID, _ kind: SourceKind) -> [CaptionBatchCue] {
        let segs = kind == .system ? systemSegments : micSegments
        let picked = segs.filter { $0.laneID == lane }.sorted { $0.start < $1.start }
        return picked.map { seg in
            CaptionBatchCue(
                id: seg.id,
                start: seg.start,
                end: seg.end,
                speaker: seg.speaker,
                mark: markToken(lane: lane, kind: kind, speaker: seg.speaker) ?? "",
                source: SRTDocument.oneLine(seg.source)
            )
        }
    }

    func noteSlot(_ laneID: UUID, _ kind: SourceKind) -> SessionNoteSlot {
        lanes(kind).first { $0.id == laneID }?.note ?? SessionNoteSlot()
    }

    func canWriteNote(_ laneID: UUID, _ kind: SourceKind) -> Bool {
        guard let lane = lanes(kind).first(where: { $0.id == laneID }), !lane.note.writing else { return false }
        let binding = noteBinding(lane)
        let segments = kind == .system ? systemSegments : micSegments
        return segments.contains { seg in
            seg.laneID == lane.id && !seg.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !noteWaiting(seg, binding: binding)
        }
    }

    /// Opened while listening, the page keeps following the captions until 停止.
    func writeNote(_ laneID: UUID, _ kind: SourceKind, following: Bool? = nil) {
        let brief = noteBrief(laneID, kind)
        guard brief.hasCue else { return }
        noteTasks[laneID]?.cancel()
        var slot = noteSlot(laneID, kind)
        slot.generation += 1
        let generation = slot.generation
        slot.open = true
        slot.writing = true
        slot.error = ""
        slot.follow = following ?? isActive
        slot.attemptedAt = Date()
        setNote(slot, laneID, kind)
        noteTasks[laneID] = Task { @MainActor in
            let result = await SessionNoteWriter.write(brief)
            guard self.noteSlot(laneID, kind).generation == generation else { return }
            var next = self.noteSlot(laneID, kind)
            next.writing = false
            switch result {
            case .success(let page):
                next.page = page
                next.error = ""
            case .failure(let failure):
                next.error = failure.message
            }
            self.setNote(next, laneID, kind)
            self.noteTasks[laneID] = nil
        }
    }

    static let noteStep = 5
    static let noteInterval: TimeInterval = 60

    /// Finished segments the page would be written from now.
    func noteCueCount(_ laneID: UUID, _ kind: SourceKind) -> Int {
        guard let lane = lanes(kind).first(where: { $0.id == laneID }) else { return 0 }
        let binding = noteBinding(lane)
        return (kind == .system ? systemSegments : micSegments).reduce(0) { count, seg in
            guard seg.laneID == laneID, !noteWaiting(seg, binding: binding),
                  !seg.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return count }
            return count + 1
        }
    }

    /// While listening: rewrite a following page once enough new segments settled and a minute passed.
    func refreshFollowingNotes() {
        guard isActive else { return }
        for kind in SourceKind.allCases where captures(kind) {
            for lane in lanes(kind) where lane.note.open && lane.note.follow && !lane.note.writing {
                let done = lane.note.page?.cueCount ?? 0
                let since = Date().timeIntervalSince(lane.note.attemptedAt ?? .distantPast)
                guard since >= Self.noteInterval, noteCueCount(lane.id, kind) - done >= Self.noteStep else { continue }
                writeNote(lane.id, kind, following: true)
            }
        }
        refreshCombinedNote()
    }

    /// At 停止: one last page for every following note that has something new.
    func finishFollowingNotes() {
        for kind in SourceKind.allCases {
            for lane in lanes(kind) where lane.note.open && lane.note.follow {
                let done = lane.note.page?.cueCount ?? 0
                if !lane.note.writing, noteCueCount(lane.id, kind) > done {
                    writeNote(lane.id, kind, following: false)
                } else {
                    editLane(lane.id, kind) { $0.note.follow = false }
                }
            }
        }
        finishCombinedNote()
    }

    func closeNote(_ laneID: UUID, _ kind: SourceKind) {
        noteTasks[laneID]?.cancel()
        noteTasks[laneID] = nil
        var slot = noteSlot(laneID, kind)
        slot.generation += 1
        slot.open = false
        slot.writing = false
        slot.follow = false
        slot.error = ""
        setNote(slot, laneID, kind)
    }

    private func dismissNote(_ laneID: UUID, _ kind: SourceKind) {
        noteTasks[laneID]?.cancel()
        noteTasks[laneID] = nil
        var slot = SessionNoteSlot()
        slot.generation = noteSlot(laneID, kind).generation + 1
        setNote(slot, laneID, kind)
    }

    private func dismissNotes(_ kind: SourceKind) {
        for id in lanes(kind).map(\.id) { dismissNote(id, kind) }
    }

    func setNote(_ slot: SessionNoteSlot, _ laneID: UUID, _ kind: SourceKind) {
        editLane(laneID, kind) { $0.note = slot }
    }

    func noteBinding(_ lane: RecognitionLane) -> SessionNoteBinding {
        let native = AppConfig.shared.nativeLanguage.resolvedDestination
        let bindings = lane.bindings.map { binding in
            SessionNoteBinding(
                id: binding.translateID,
                key: binding.key,
                isSource: binding.isSource,
                translatesToNative: !binding.isSource && binding.target.resolvedDestination == native
            )
        }
        return SessionNote.choose(bindings)
    }

    func noteWaiting(_ seg: LiveCaptionSegment, binding: SessionNoteBinding) -> Bool {
        !binding.isSource && seg.loadingProviderIDs.contains(binding.key)
    }

    func noteBrief(_ laneID: UUID, _ kind: SourceKind) -> SessionNoteBrief {
        guard let lane = lanes(kind).first(where: { $0.id == laneID }) else { return .empty }
        let binding = noteBinding(lane)
        let segments = (kind == .system ? systemSegments : micSegments).filter { $0.laneID == lane.id }
        let cues = segments.map { seg in
            let translation: String? = {
                guard !binding.isSource else { return nil }
                let raw = seg.translations[binding.key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return raw.isEmpty ? nil : raw
            }()
            return SessionNoteCue(
                id: seg.id.uuidString,
                mark: markToken(lane: lane.id, kind: kind, speaker: seg.speaker) ?? "",
                source: seg.source,
                translation: translation,
                waiting: noteWaiting(seg, binding: binding)
            )
        }
        return SessionNote.brief(cues, binding: binding)
    }

    func speakerRows(_ lane: UUID, _ kind: SourceKind) -> [(id: Int, token: String)] {
        let segs = (kind == .system ? systemSegments : micSegments).filter { $0.laneID == lane }
        var ids: [Int] = []
        for seg in segs where seg.speaker > 0 && !ids.contains(seg.speaker) {
            ids.append(seg.speaker)
        }
        if let draft = laneDrafts[lane], draft.speaker > 0, !ids.contains(draft.speaker) {
            ids.append(draft.speaker)
        }
        let book = (kind == .system ? systemLanes : micLanes).first { $0.id == lane }?.marks ?? SpeakerMarkBook()
        return ids.compactMap { id in
            guard !book.removed.contains(id), let token = markToken(lane: lane, kind: kind, speaker: id) else { return nil }
            return (id, token)
        }
    }

    func renameSpeaker(_ lane: UUID, _ kind: SourceKind, _ speaker: Int, to name: String) {
        if kind == .system, let index = systemLanes.firstIndex(where: { $0.id == lane }) {
            systemLanes[index].marks.rename(speaker: speaker, to: name)
        }
        if kind == .microphone, let index = micLanes.firstIndex(where: { $0.id == lane }) {
            micLanes[index].marks.rename(speaker: speaker, to: name)
        }
        refreshImmersiveOverlay()
    }

    func deleteSpeaker(_ lane: UUID, _ kind: SourceKind, _ speaker: Int) {
        guard !isActive else { return }
        if kind == .system, let index = systemLanes.firstIndex(where: { $0.id == lane }) {
            systemLanes[index].marks.remove(speaker: speaker)
        }
        if kind == .microphone, let index = micLanes.firstIndex(where: { $0.id == lane }) {
            micLanes[index].marks.remove(speaker: speaker)
        }
        refreshImmersiveOverlay()
    }

    func setSpeakerVoice(_ lane: UUID, _ kind: SourceKind, _ speaker: Int, to voice: String?) {
        editLane(lane, kind) { $0.marks.setVoice(speaker, to: voice) }
        refreshImmersiveOverlay()
    }

    /// The voice assigned to this person on this lane, or nil for the usual voice.
    func speakerVoice(_ lane: UUID, _ kind: SourceKind, _ speaker: Int) -> String? {
        (kind == .system ? systemLanes : micLanes).first { $0.id == lane }?.marks.voice(for: speaker)
    }

    func deleteAllSpeakers(_ lane: UUID, _ kind: SourceKind) {
        guard !isActive else { return }
        let ids = Set(speakerRows(lane, kind).map(\.id))
        if kind == .system, let index = systemLanes.firstIndex(where: { $0.id == lane }) {
            systemLanes[index].marks.removeAll(ids)
        }
        if kind == .microphone, let index = micLanes.firstIndex(where: { $0.id == lane }) {
            micLanes[index].marks.removeAll(ids)
        }
        refreshImmersiveOverlay()
    }

    func mirroredPartialLane(_ kind: SourceKind) -> UUID? {
        let lanes = kind == .system ? systemLanes : micLanes
        return lanes.last { laneDrafts[$0.id]?.partial == true }?.id
    }

    func setImmersive(_ id: String, on: Bool) {
        if on {
            guard immersiveChips().contains(where: { $0.key == id }) else { return }
            if !immersiveOn.contains(id) { immersiveOn.append(id) }
            if immersivePanes[id] == nil { immersivePanes[id] = loadPane(id) }
            showImmersiveOverlay(id)
        } else {
            immersiveOn.removeAll { $0 == id }
            hideImmersiveOverlay(id)
            if speakingProviderID == id {
                speakingProviderID = nil
                stopSpeaking()
            }
        }
        UserDefaults.standard.set(immersiveOn, forKey: "live.immersiveProviders")
    }

    func toggleImmersiveSpeech(_ id: String) {
        guard var pane = immersivePanes[id] else { return }
        pane.speechPlaying.toggle()
        if pane.speechPlaying {
            for other in immersivePanes.keys where other != id {
                immersivePanes[other]?.speechPlaying = false
            }
            speakingProviderID = id
            autoSpokenID = nil
            autoSpokenKind = nil
            immersivePanes[id] = pane
            autoSpeakLatest()
        } else {
            immersivePanes[id] = pane
            if speakingProviderID == id {
                speakingProviderID = nil
                stopSpeaking()
            }
        }
    }

    func setImmersiveShowSource(_ id: String, _ on: Bool) {
        immersivePanes[id]?.showSource = on
        UserDefaults.standard.set(on, forKey: "live.immersive.\(id).source")
        autoSpeakLatest()
        refreshImmersiveOverlay(id)
    }

    func setImmersiveShowTranslation(_ id: String, _ on: Bool) {
        immersivePanes[id]?.showTranslation = on
        UserDefaults.standard.set(on, forKey: "live.immersive.\(id).translation")
        autoSpeakLatest()
        refreshImmersiveOverlay(id)
    }

    private func loadPane(_ id: String) -> ImmersivePane {
        var pane = ImmersivePane()
        let sourceKey = "live.immersive.\(id).source"
        if UserDefaults.standard.object(forKey: sourceKey) != nil {
            pane.showSource = UserDefaults.standard.bool(forKey: sourceKey)
        }
        let translationKey = "live.immersive.\(id).translation"
        if UserDefaults.standard.object(forKey: translationKey) == nil {
            pane.showTranslation = true
        } else {
            pane.showTranslation = UserDefaults.standard.bool(forKey: translationKey)
        }
        return pane
    }

    private func autoSpeakLatest() {
        guard let pid = speakingProviderID, let pane = immersivePanes[pid], pane.speechPlaying else { return }
        // A 同传 pane speaks with the service's own voice as it arrives.
        if pane.showTranslation, parseImmersiveKey(pid)?.binding.isInterp == true { return }
        guard let line = latestSpeakableLine(pid, pane: pane) else {
            if !pane.showSource && !pane.showTranslation { stopSpeaking() }
            return
        }
        if line.id == autoSpokenID, line.kind == autoSpokenKind { return }
        autoSpokenID = line.id
        autoSpokenKind = line.kind
        speak(line.text, kind: line.kind, source: line.source, providerID: pid, lane: line.lane, speaker: line.speaker)
    }

    private func latestSpeakableLine(_ pid: String, pane: ImmersivePane) -> (id: UUID, text: String, kind: SpeakKind, source: SourceKind, lane: UUID, speaker: Int)? {
        guard let (kind, lane, binding) = parseImmersiveKey(pid) else { return nil }
        let segs = (kind == .system ? systemSegments : micSegments).filter { $0.laneID == lane.id }
        guard let seg = segs.last else { return nil }
        let src = seg.source.trimmingCharacters(in: .whitespacesAndNewlines)
        if binding.isSource {
            return src.isEmpty ? nil : (seg.id, src, .source, kind, lane.id, seg.speaker)
        }
        if pane.showTranslation {
            if let tr = seg.translations[binding.key]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !tr.isEmpty, tr != "—", !tr.hasPrefix(L("翻译失败")) {
                return (seg.id, tr, .translation, kind, lane.id, seg.speaker)
            }
            if seg.loadingProviderIDs.contains(binding.key) { return nil }
        }
        if pane.showSource, !src.isEmpty { return (seg.id, src, .source, kind, lane.id, seg.speaker) }
        return nil
    }

    func showImmersiveOverlay() {
        for id in immersiveOn { showImmersiveOverlay(id) }
    }

    func showImmersiveOverlay(_ id: String) {
        let box = immersiveBoxes[id] ?? ImmersiveBox(providerID: id)
        if box.window == nil {
            let root = AnyView(ImmersiveCaptionOverlay(model: self, providerID: id, pinToBottom: true))
            let h = NSHostingView(rootView: root)
            h.sizingOptions = []
            h.safeAreaRegions = []
            let w = OverlayPanel.make(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 72),
                style: .immersive,
                content: h
            )
            let size = NSSize(width: 640, height: 72)
            if let saved = Self.savedImmersiveCenter(id),
               let screen = NSScreen.screens.first(where: { NSMouseInRect(saved, $0.frame, false) }) ?? NSScreen.main {
                let origin = NSPoint(x: saved.x - size.width / 2, y: saved.y - size.height / 2)
                w.setFrame(NSRect(origin: origin, size: size), display: false)
                _ = screen
            } else if let screen = NSScreen.main {
                let vf = screen.visibleFrame
                var originY = vf.minY + max(48, vf.height * 0.08)
                let others = immersiveBoxes.values.compactMap { $0.window?.frame }.filter { $0.height > 1 }
                if let top = others.map(\.maxY).max() {
                    originY = top + 8
                }
                let origin = NSPoint(x: vf.midX - size.width / 2, y: originY)
                w.setFrame(NSRect(origin: origin, size: size), display: false)
            }
            box.window = w
            box.hosting = h
            box.bottomAnchor = w.frame.minY
            NotificationCenter.default.addObserver(
                forName: NSWindow.didMoveNotification,
                object: w,
                queue: nil
            ) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let box = self.immersiveBoxes[id], let win = note.object as? NSWindow, !box.applyingFrame else { return }
                    box.bottomAnchor = win.frame.minY
                    Self.persistImmersiveCenter(id, NSPoint(x: win.frame.midX, y: win.frame.midY))
                }
            }
            immersiveBoxes[id] = box
        }
        refreshImmersiveOverlay(id)
        box.window?.orderFrontRegardless()
    }

    func hideImmersiveOverlay(_ id: String) {
        guard let box = immersiveBoxes[id] else { return }
        if let w = box.window {
            Self.persistImmersiveCenter(id, NSPoint(x: w.frame.midX, y: w.frame.midY))
        }
        box.window?.orderOut(nil)
    }

    private static func centerKey(_ id: String) -> String { "live.immersiveCenter.\(id)" }

    private static func persistImmersiveCenter(_ id: String, _ p: NSPoint) {
        UserDefaults.standard.set(["x": p.x, "y": p.y], forKey: centerKey(id))
    }

    private static func savedImmersiveCenter(_ id: String) -> NSPoint? {
        guard let d = UserDefaults.standard.dictionary(forKey: centerKey(id)),
              let xNum = d["x"] as? NSNumber,
              let yNum = d["y"] as? NSNumber else { return nil }
        return NSPoint(x: CGFloat(xNum.doubleValue), y: CGFloat(yNum.doubleValue))
    }

    func refreshImmersiveOverlay() {
        for id in immersiveOn { refreshImmersiveOverlay(id) }
    }

    func refreshImmersiveOverlay(_ id: String) {
        guard immersiveOn.contains(id), let box = immersiveBoxes[id], let w = box.window, !box.applyingFrame else { return }
        CaptionBudget.note("screen", (w.screen ?? NSScreen.main)?.visibleFrame.width ?? 0)
        let cap = CaptionBudget.lineWidth + 76
        var size = immersiveCaptionSize(id, width: cap)
        size.width = min(max(ceil(size.width), 280), cap)
        size.height = max(ceil(size.height), 48)
        let bottom = box.bottomAnchor ?? w.frame.minY
        var originY = bottom
        if let screen = w.screen ?? NSScreen.main {
            let vf = screen.visibleFrame
            let topLimit = vf.maxY - 8
            let room = topLimit - originY
            if size.height > room { size.height = max(48, room) }
            if originY < vf.minY + 8 {
                originY = vf.minY + 8
                let roomAbove = topLimit - originY
                if size.height > roomAbove { size.height = max(48, roomAbove) }
            }
        }
        var frame = w.frame
        frame.size = size
        frame.origin.x = w.frame.midX - size.width / 2
        frame.origin.y = originY
        if let screen = w.screen ?? NSScreen.main {
            let vf = screen.visibleFrame
            if frame.minX < vf.minX { frame.origin.x = vf.minX + 8 }
            if frame.maxX > vf.maxX { frame.origin.x = vf.maxX - frame.width - 8 }
        }
        let cur = w.frame
        if abs(cur.minX - frame.minX) < 0.5,
           abs(cur.minY - frame.minY) < 0.5,
           abs(cur.width - frame.width) < 0.5,
           abs(cur.height - frame.height) < 0.5 {
            return
        }
        box.applyingFrame = true
        w.setFrame(frame, display: true, animate: false)
        DispatchQueue.main.async { [weak box] in
            MainActor.assumeIsolated { box?.applyingFrame = false }
        }
    }

    private func immersiveCaptionSize(_ id: String, width: CGFloat) -> NSSize {
        let root = AnyView(ImmersiveCaptionOverlay(model: self, providerID: id).frame(maxWidth: width))
        let box = immersiveBoxes[id] ?? ImmersiveBox(providerID: id)
        let fitter: NSHostingController<AnyView>
        if let existing = box.fitter {
            existing.rootView = root
            fitter = existing
        } else {
            let created = NSHostingController(rootView: root)
            created.sizingOptions = []
            created.safeAreaRegions = []
            box.fitter = created
            immersiveBoxes[id] = box
            fitter = created
        }
        let fitted = fitter.sizeThatFits(in: NSSize(width: width, height: 2000))
        let settled = fitter.sizeThatFits(in: NSSize(width: width, height: max(fitted.height, 48)))
        return settled.height > fitted.height + 0.5 ? settled : fitted
    }

    func speak(_ text: String, kind: SpeakKind, source: SourceKind? = nil, providerID: String? = nil, target: TargetLanguage? = nil, lane laneID: UUID? = nil, speaker: Int = 0) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "—", trimmed != L("翻译中…"), !trimmed.hasPrefix(L("翻译失败")) else { return }
        let lane = source ?? lastActiveSource ?? .system
        let asr = asrLanguage(for: lane)
        let code: String
        switch kind {
        case .source:
            code = asr.locale.identifier
        case .translation:
            let key = providerID ?? speakingProviderID
            let language = target ?? key.flatMap { parseImmersiveKey($0)?.binding.target } ?? lastTarget(for: lane)
            code = language.appleCode ?? (asr.id.hasPrefix("zh") ? "en-US" : "zh-CN")
        }
        let pid = providerID ?? speakingProviderID
        let voiceLane = laneID ?? pid.flatMap { parseImmersiveKey($0)?.lane.id }
        let voice = voiceLane.flatMap { speakerVoice($0, lane, speaker) }
        SpeechPlayback.shared.speak(trimmed, languageCode: code, voiceID: voice, onFailure: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let pid { self.immersivePanes[pid]?.speechPlaying = false }
                if self.speakingProviderID == pid { self.speakingProviderID = nil }
            }
        })
    }

    enum SpeakKind { case source, translation }

    func stopSpeaking() {
        SpeechPlayback.shared.stop()
        InterpPlayer.shared.stop()
    }

    /// Named after when the session began, so captions and recordings of one session share it.
    /// 跨文件（LiveCaptionWindow）调用。
    func exportBase() -> String {
        return "\(L("字幕"))-\(TimeText.fileStamp.string(from: sessionStartedAt ?? Date()))"
    }

    func exportCaptions() {
        let lanes = exportLanes()
        guard !lanes.isEmpty, let choice = CaptionExport.choose(lanes: lanes) else { return }
        let base = exportBase()
        let files = CaptionExport.files(base: base, lanes: lanes, rule: choice.rule, sourceLanes: choice.sourceLanes)
        guard !files.isEmpty else { return }
        do {
            let urls = try CaptionExport.write(files, to: choice.folder)
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        } catch {
            statusLine = String(format: L("保存失败：%@"), String(describing: error.localizedDescription))
        }
    }

    /// Bindings edited mid-session leave finished segments under their old key; those still export.
    private func exportLanes() -> [CaptionExport.Lane] {
        var out: [CaptionExport.Lane] = []
        for kind in SourceKind.allCases where captures(kind) {
            let segs = kind == .system ? systemSegments : micSegments
            for lane in lanes(kind) {
                let asr = AppConfig.shared.liveASRChoices().first { $0.id == lane.asrID }?.name ?? lane.asrID
                let mine = segs.filter { $0.laneID == lane.id }
                guard !mine.isEmpty else { continue }
                var bindings = lane.bindings
                for seg in mine {
                    for key in seg.translations.keys.sorted() where !bindings.contains(where: { $0.key == key }) {
                        if let b = LaneBinding(key: key) { bindings.append(b) }
                    }
                }
                let cues = mine.compactMap { seg -> CaptionExport.Cue? in
                    let source = SRTDocument.oneLine(seg.source)
                    guard !source.isEmpty else { return nil }
                    var translations: [String: String] = [:]
                    for b in bindings where !b.isSource {
                        if let line = translationLine(seg, b.key) { translations[b.key] = line }
                    }
                    return CaptionExport.Cue(
                        start: seg.start,
                        end: seg.end,
                        source: source,
                        mark: markToken(lane: lane.id, kind: kind, speaker: seg.speaker),
                        translations: translations
                    )
                }
                out.append(CaptionExport.Lane(
                    key: "\(kind.rawValue)|\(lane.asrID)",
                    title: "\(kind.title) · \(asr)",
                    fileStem: "\(kind.title).\(asr)",
                    bindings: bindings,
                    cues: cues
                ))
            }
        }
        return out
    }

    private func translationLine(_ seg: LiveCaptionSegment, _ providerID: String) -> String? {
        if seg.loadingProviderIDs.contains(providerID) || seg.errors[providerID] != nil { return nil }
        guard let tr = seg.translations[providerID]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !tr.isEmpty, tr != "—", tr != L("翻译中…"), !tr.hasPrefix(L("翻译失败")) else { return nil }
        return SRTDocument.oneLine(tr)
    }

    func canExportCaptions() -> Bool {
        (captureSystem && !systemSegments.isEmpty) || (captureMicrophone && !micSegments.isEmpty)
    }
}
