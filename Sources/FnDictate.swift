import AppKit
import AVFoundation
import Speech

/// 按住 Fn 走当前语音模式。松开后写入、朗读，并记进历史。
@MainActor
final class FnDictate {
    static let shared = FnDictate()
    static var sessionEngineID = ""

    private var token = 0
    private var ear: DictateEar?
    private var stopAsked = false
    private var beganAt: TimeInterval = 0
    private var mode: VoiceMode = .recognize
    private var bundleID: String?
    private var heard = ""
    private var translated = ""
    /// 这句译文对应的原文。对得上才不用再译。
    private var renderedFor = ""
    private var translateTask: Task<Void, Never>?
    private var voiced = ""
    private var speechLanguage = ""
    /// 按住开始时的前台应用。松开后只往这个应用里写。
    private var fieldPID: pid_t = 0
    /// 说话期间先问过能不能写，松开时不再等辅助功能把树建起来。
    private var fieldProbe: Task<Bool, Never>?
    /// 模式切换刚把胶囊亮起来时，紧接着的取消不要把胶囊收掉。
    private var keepOverlay = false
    /// 选的是同传服务时的那条连接。原文、译文和译音都从它来。
    private var interp: InterpSession?
    private var interpSources: [(id: String, text: String)] = []
    private var interpTargets: [(id: String, text: String)] = []
    private var interpLanguage: TargetLanguage = .en
    private var interpService: (id: String, name: String)?
    private var interpError: String?
    /// 听写和快捷翻译都往同一个输入框里写字，同一时间只开一个。
    private var holdsField = false
    /// 哪一轮拿着输入框。上一轮收尾回来时不能把下一轮的锁放掉。
    private var fieldOwner = 0

    private func claimField(session: Int) -> Bool {
        holdsField = QuickSpaceTap.shared.claim()
        if holdsField { fieldOwner = session }
        return holdsField
    }

    /// 只放自己那一轮拿到的锁。
    private func releaseField(session: Int? = nil) {
        guard holdsField else { return }
        if let session, session != fieldOwner { return }
        holdsField = false
        fieldOwner = 0
        QuickSpaceTap.shared.release()
    }

    /// 起不来时给一句话，同时把输入框让出来。
    private func fail(_ message: String, session: Int) {
        VoiceCapsule.shared.fail(message)
        releaseField(session: session)
    }

    func begin(pid: pid_t) {
        let app = pid == 0 ? nil : NSRunningApplication(processIdentifier: pid)
        // 这个来源应用关了语音，按住 Fn 也不开始听。
        guard AppConfig.shared.isAppOn(.voice, bundleID: app?.bundleIdentifier) else {
            NSSound.beep()
            return
        }
        // 快捷翻译正在往同一个输入框里写，这一轮就不接。
        // 先申请再推进 token：申请失败时上一轮还在收尾，不能被这一下顺手打断。
        let next = token + 1
        guard claimField(session: next) else { return }
        token = next
        let current = token
        stopAsked = false
        keepOverlay = false
        beganAt = ProcessInfo.processInfo.systemUptime
        bundleID = app?.bundleIdentifier
        mode = AppConfig.shared.resolvedVoiceMode(bundleID: bundleID)
        heard = ""
        translated = ""
        renderedFor = ""
        voiced = ""
        speechLanguage = ""
        translateTask?.cancel()
        translateTask = nil
        ear?.cancel()
        ear = nil
        syncPulse()
        dropInterp()
        fieldPID = pid
        armFieldProbe(pid)
        SpeechPlayback.shared.stop()
        VoiceCapsule.shared.prepare(mode)
        Task { await start(token: current) }
    }

    func end() {
        if ProcessInfo.processInfo.systemUptime - beganAt < 0.2 {
            cancel()
            return
        }
        stopAsked = true
        guard let ear else { return }
        let current = token
        self.ear = nil
        syncPulse()
        Task { await finish(ear, token: current) }
    }

    /// 停掉正在听的这一轮，不动浮层。模式切换自己会亮胶囊。
    func abandon() {
        token += 1
        stopAsked = true
        translateTask?.cancel()
        translateTask = nil
        ear?.cancel()
        ear = nil
        syncPulse()
        dropInterp()
        SpeechPlayback.shared.stop()
        releaseField()
    }

    /// 耳朵在，菜单栏图标就在摆；收起来就停。
    private func syncPulse() {
        MenuBarPulse.shared.setActive(ear != nil, for: .dictate)
    }

    private func dropInterp() {
        interp?.cancel()
        interp = nil
        interpSources = []
        interpTargets = []
        interpService = nil
        interpError = nil
        InterpPlayer.shared.stop()
    }

    func suppressOverlayHide() { keepOverlay = true }

    func expireOverlaySuppress() { keepOverlay = false }

    func cancel() {
        let keep = keepOverlay
        keepOverlay = false
        abandon()
        if keep { return }
        VoiceCapsule.shared.hide()
    }

    private func start(token current: Int) async {
        guard current == token else { return }
        let live = SystemAudioTranslateController.shared
        if live.isActive, live.captureMicrophone {
            fail(L("麦克风正在用于实时字幕"), session: current)
            return
        }
        let cfg = AppConfig.shared
        let choices = cfg.liveASRChoices()
        let picked = Pro.unlocked && choices.contains { $0.id == FnDictate.sessionEngineID } ? FnDictate.sessionEngineID : cfg.resolvedDictateAsr()
        let engine = choices.contains { $0.id == picked } ? picked : (choices.first?.id ?? "apple")
        let language = ASRLanguage(id: cfg.dictateLocaleID)
        if stopped(current) { return }
        if cfg.isSystemASR(engine) {
            let status = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
                SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
            }
            guard status == .authorized else {
                fail(L("没有语音识别权限"), session: current)
                return
            }
        }
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        if mic == .notDetermined {
            // Same sheet as live captions. Keep swallowing mouse moves until the
            // events the sheet queued have drained, so they never reach SwiftUI hover.
            _ = await LiveCaptionHost.whileMicrophonePrompt {
                await AVCaptureDevice.requestAccess(for: .audio)
            }
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            fail(L("需要麦克风权限"), session: current)
            return
        }
        if stopped(current) { return }
        var feed: InterpFeed?
        if let wire = cfg.interpWire(engine) {
            let target = cfg.resolvedDictateTarget(bundleID: bundleID).resolvedDestination
            guard InterpLanguages.supports(wire, target) else {
                fail(String(format: L("这家同传译不成%@"), target.shortTitle), session: current)
                return
            }
            do {
                let config = try cfg.interpConfig(selection: engine, target: target, audio: mode == .interpret)
                let session = current
                let link = InterpSession(config: config) { event in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            FnDictate.shared.interpEvent(event, session: session)
                        }
                    }
                }
                interp = link
                interpLanguage = target
                interpService = (engine, choices.first { $0.id == engine }?.name ?? engine)
                feed = InterpFeed(session: link)
                link.open()
            } catch {
                fail(error.localizedDescription, session: current)
                return
            }
        }
        let made: DictateEar
        do {
            let session = current
            made = try DictateEar(engine: engine, language: language, interp: feed) { text in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        FnDictate.shared.shows(text, session: session)
                    }
                }
            }
            try made.start()
        } catch {
            dropInterp()
            fail(error.localizedDescription, session: current)
            return
        }
        guard current == token else {
            made.cancel()
            releaseField(session: current)
            return
        }
        ear = made
        syncPulse()
        VoiceCapsule.shared.listen(mode)
        if stopAsked {
            end()
        }
    }

    fileprivate func shows(_ text: String, session: Int) {
        guard token == session else { return }
        let plain = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plain.isEmpty else { return }
        guard mode.translates else {
            VoiceCapsule.shared.note(plain)
            return
        }
        let previous = heard
        heard = plain
        let carry = (!translated.isEmpty && (plain.hasPrefix(previous) || previous.hasPrefix(plain))) ? translated : ""
        VoiceCapsule.shared.note(carry.isEmpty ? plain : carry)
        ensurePump(session: session)
    }

    /// 按住期间一直译最新的一句。有一句在路上就不取消，译完再跟上。
    private func ensurePump(session: Int) {
        guard translateTask == nil else { return }
        translateTask = Task { [weak self] in
            await self?.pump(session: session)
        }
    }

    private func pump(session: Int) async {
        var renderedSource = ""
        while token == session, !Task.isCancelled {
            if stopAsked { break }
            let snapshot = heard.trimmingCharacters(in: .whitespacesAndNewlines)
            if snapshot.isEmpty || snapshot == renderedSource {
                try? await Task.sleep(nanoseconds: 100_000_000)
                continue
            }
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard token == session, !stopAsked, !Task.isCancelled else { break }
            let text = heard.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty || text == renderedSource { continue }
            guard let out = try? await Self.render(text, bundleID: bundleID) else {
                renderedSource = text
                try? await Task.sleep(nanoseconds: 400_000_000)
                continue
            }
            let shown = out.trimmingCharacters(in: .whitespacesAndNewlines)
            guard token == session, !shown.isEmpty else { break }
            guard heard.hasPrefix(text) || text.hasPrefix(heard) else {
                renderedSource = text
                continue
            }
            translated = shown
            renderedFor = text
            renderedSource = text
            VoiceCapsule.shared.note(shown)
            if mode == .interpret { voiceStable(shown) }
        }
    }

    private func finish(_ ear: DictateEar, token current: Int) async {
        // 这一轮说完了，输入框让给快捷翻译。被换掉的那一轮不放别人的锁。
        defer { releaseField(session: current) }
        if let interp {
            await finishInterp(ear, link: interp, token: current)
            return
        }
        VoiceCapsule.shared.busy(L("识别中"))
        let text = await ear.transcript()
        guard current == token else { return }
        let plain = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plain.isEmpty else {
            VoiceCapsule.shared.fail(L("没有听到人声"))
            return
        }
        let prepared = await Self.prepareSpeech(plain, bundleID: bundleID)
        guard current == token else { return }
        let basis = prepared.text
        let polishNote = prepared.note
        if mode.translates {
            await translateTask?.value
            translateTask = nil
            let shown: String
            do {
                if basis == plain, renderedFor == plain, !translated.isEmpty {
                    shown = translated
                } else {
                    VoiceCapsule.shared.busy(L("翻译中"))
                    let rendered = try await Self.render(basis, bundleID: bundleID)
                    shown = rendered.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !shown.isEmpty else { throw TErr(L("没有翻译结果")) }
                }
            } catch {
                guard current == token else { return }
                remember(source: basis, translation: nil, direction: "", front: nil)
                VoiceCapsule.shared.fail(error.localizedDescription)
                return
            }
            guard current == token else { return }
            let plan = Self.plan(basis, bundleID: bundleID)
            VoiceCapsule.shared.note(shown)
            if mode == .interpret {
                if speechLanguage.isEmpty { speechLanguage = plan.tgt }
                voiceRemainder(shown)
                remember(source: basis, translation: shown, direction: plan.directionLabel, front: nil)
                if !polishNote.isEmpty {
                    VoiceCapsule.shared.kept(polishNote)
                    return
                }
                let overlay = VoiceCapsule.shared.generationToken()
                SpeechPlayback.shared.whenDone {
                    Task { @MainActor in
                        VoiceCapsule.shared.hideIfStill(overlay)
                    }
                }
                return
            }
            await deliver(shown, source: basis, direction: plan.directionLabel, translation: shown, session: current, notice: polishNote)
            return
        }
        VoiceCapsule.shared.note(basis)
        await deliver(basis, source: basis, direction: "", translation: nil, session: current, notice: polishNote)
    }

    fileprivate func interpEvent(_ event: InterpEvent, session: Int) {
        guard token == session, interp != nil else { return }
        switch event {
        case .ready:
            return
        case .source(let id, let text, _, _):
            Self.upsert(&interpSources, id: id, text: text)
            heard = InterpText.join(interpSources.map(\.text))
        case .target(let id, _, let text, _):
            Self.upsert(&interpTargets, id: id, text: InterpText.shaped(text, for: interpLanguage))
            translated = InterpText.join(interpTargets.map(\.text))
        case .audio(let pcm):
            if mode == .interpret { InterpPlayer.shared.play(pcm) }
            return
        case .failed(let message):
            interpError = message
            guard !stopAsked else { return }
            abandon()
            VoiceCapsule.shared.fail(message)
            return
        }
        let source = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty || !translated.isEmpty else { return }
        let shown = mode.translates && !translated.isEmpty ? translated : source
        if !shown.isEmpty {
            VoiceCapsule.shared.note(shown)
        }
    }

    private static func upsert(_ list: inout [(id: String, text: String)], id: String, text: String) {
        if let i = list.firstIndex(where: { $0.id == id }) {
            list[i].text = text
        } else {
            list.append((id, text))
        }
    }

    /// 松开后让同传把听到的说完，再写入或读完。译文就是它给的，不再润色原文。
    private func finishInterp(_ ear: DictateEar, link: InterpSession, token current: Int) async {
        ear.stopListening()
        if heard.isEmpty, translated.isEmpty {
            VoiceCapsule.shared.busy(mode.translates ? L("翻译中") : L("识别中"))
        }
        await link.finish()
        guard current == token else { return }
        interp = nil
        let source = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = translated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty || !shown.isEmpty else {
            InterpPlayer.shared.stop()
            VoiceCapsule.shared.fail(interpError ?? L("没有听到人声"))
            return
        }
        guard mode.translates else {
            let prepared = await Self.prepareSpeech(source, bundleID: bundleID)
            guard current == token else { return }
            VoiceCapsule.shared.note(prepared.text)
            await deliver(prepared.text, source: prepared.text, direction: "", translation: nil, session: current, notice: prepared.note)
            return
        }
        guard !shown.isEmpty else {
            InterpPlayer.shared.stop()
            remember(source: source, translation: nil, direction: "", front: nil)
            VoiceCapsule.shared.fail(interpError ?? L("没有翻译结果"))
            return
        }
        let direction = Lang.languagePair(Lang.detectSource(source).code, interpLanguage.appleCode ?? "en")
        VoiceCapsule.shared.note(shown)
        if mode == .interpret {
            remember(source: source, translation: shown, direction: direction, front: nil)
            let overlay = VoiceCapsule.shared.generationToken()
            InterpPlayer.shared.whenDrained {
                Task { @MainActor in
                    VoiceCapsule.shared.hideIfStill(overlay)
                }
            }
            return
        }
        await deliver(shown, source: source, direction: direction, translation: shown, session: current, notice: "")
    }

    /// 松开后才润色。没有 AI 或润色失败时仍用原来的字。
    private static func prepareSpeech(_ text: String, bundleID: String?) async -> (text: String, note: String) {
        let cfg = AppConfig.shared
        guard cfg.voicePolish else { return (text, "") }
        guard let profile = cfg.voicePolishProfile(bundleID: bundleID) else {
            return (text, L("没有可用来润色的 AI"))
        }
        VoiceCapsule.shared.busy(L("润色中"))
        do {
            let out = try await Translator.polishSpeech(text, profile: profile, style: cfg.voicePolishStyle, note: cfg.voicePolishNote)
            let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return (text, "") }
            return (trimmed, "")
        } catch {
            return (text, "")
        }
    }

    /// 只读已经断句的部分。尾巴还可能被下一截译文改掉。
    private func voiceStable(_ full: String) {
        guard full.hasPrefix(voiced) else { return }
        if speechLanguage.isEmpty {
            speechLanguage = Self.plan(heard, bundleID: bundleID).tgt
        }
        let start = full.index(full.startIndex, offsetBy: voiced.count)
        var cut: String.Index?
        var index = start
        while index < full.endIndex {
            if Self.isSentenceEnd(full[index]) {
                cut = full.index(after: index)
            }
            index = full.index(after: index)
        }
        guard let cut, cut > start else { return }
        let piece = full[start..<cut].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !piece.isEmpty else { return }
        voiced = String(full[..<cut])
        SpeechPlayback.shared.enqueue(piece, languageCode: speechLanguage, tag: "voice.interpret")
    }

    /// 松开后把还没读的尾巴读完。
    private func voiceRemainder(_ full: String) {
        guard full.hasPrefix(voiced) else {
            if voiced.isEmpty {
                voiced = full
                SpeechPlayback.shared.enqueue(full, languageCode: speechLanguage, tag: "voice.interpret")
            }
            return
        }
        let rest = full.dropFirst(voiced.count).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty else { return }
        voiced = full
        SpeechPlayback.shared.enqueue(rest, languageCode: speechLanguage, tag: "voice.interpret")
    }

    private static func isSentenceEnd(_ character: Character) -> Bool {
        character.unicodeScalars.contains { sentenceEnds.contains($0) }
    }

    private static let sentenceEnds = CharacterSet(charactersIn: "。！？!?；;")

    /// 松开时麦克风还没开。短按走取消；按住超过那一下就说明没听成。
    private func stopped(_ current: Int) -> Bool {
        guard current == token else { return true }
        guard stopAsked else { return false }
        fail(L("还没开始听"), session: current)
        return true
    }

    private func deliver(_ text: String, source: String, direction: String, translation: String?, session: Int, notice: String) async {
        let front = await writeField(text, session: session)
        guard token == session else { return }
        remember(source: source, translation: translation, direction: direction, front: front)
        if front == nil, !notice.isEmpty {
            VoiceCapsule.shared.kept(L("已记入历史") + "。" + notice)
            return
        }
        if front == nil {
            VoiceCapsule.shared.kept(L("已记入历史"))
            return
        }
        if !notice.isEmpty {
            VoiceCapsule.shared.kept(notice)
            return
        }
        VoiceCapsule.shared.hide()
    }

    private func armFieldProbe(_ pid: pid_t) {
        fieldProbe?.cancel()
        guard mode.writesField, pid != 0 else {
            fieldProbe = nil
            return
        }
        fieldProbe = Task.detached {
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                QuickAX.queue.async {
                    cont.resume(returning: QuickAX.canInsert(pid: pid))
                }
            }
        }
    }

    /// 只写回按住时的那个应用。中途换了前台，或者这一轮已经被取消，就不写。
    private func writeField(_ text: String, session: Int) async -> NSRunningApplication? {
        let pid = fieldPID
        let allowed = await fieldProbe?.value ?? false
        guard token == session, allowed, pid != 0 else { return nil }
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier == pid, !front.isTerminated else { return nil }
        guard token == session else { return nil }
        SelectionGrabber.typePlainText(text)
        return front
    }

    private func remember(source: String, translation: String?, direction: String, front: NSRunningApplication?) {
        var results: [HistoryProviderResult] = []
        if let translation {
            if let service = interpService {
                results.append(HistoryProviderResult(id: service.id, name: service.name, text: translation, error: nil))
            } else if let target = AppConfig.shared.dictateTranslateTarget(bundleID: front?.bundleIdentifier) {
                results.append(HistoryProviderResult(id: target.id, name: target.displayName, text: translation, error: nil))
            }
        }
        let kind = mode.historyKind
        let appName = front?.localizedName
        let bundleID = front?.bundleIdentifier
        Task.detached(priority: .utility) {
            HistoryStore.append(
                source: source,
                direction: direction,
                kind: kind,
                results: results,
                appName: appName,
                bundleID: bundleID
            )
        }
    }

    private static func render(_ text: String, bundleID: String?) async throws -> String {
        let cfg = AppConfig.shared
        guard let target = cfg.dictateTranslateTarget(bundleID: bundleID) else {
            throw TErr(L("没有可用的翻译"))
        }
        let out = try await Translator.translateQuiet(
            text,
            target: target,
            language: cfg.resolvedDictateTarget(bundleID: bundleID)
        ).text
        let plain = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plain.isEmpty else { throw TErr(L("没有翻译结果")) }
        return plain
    }

    private static func plan(_ text: String, bundleID: String?) -> Lang.Plan {
        let cfg = AppConfig.shared
        let language = cfg.resolvedDictateTarget(bundleID: bundleID)
        return Lang.plan(text, target: language, mutual: false)
    }
}

/// 引导的体验步借来听一句，只出文字，不写进输入框。
@MainActor
final class TryoutMic {
    private let ear: DictateEar

    init(engine: String, language: ASRLanguage, onPartial: @escaping @MainActor (String) -> Void) throws {
        ear = try DictateEar(engine: engine, language: language) { text in
            DispatchQueue.main.async { MainActor.assumeIsolated { onPartial(text) } }
        }
    }

    func start() throws { try ear.start() }
    func cancel() { ear.cancel() }
    func transcript() async -> String { await ear.transcript() }
}

private final class DictateEar: @unchecked Sendable {
    private let engineID: String
    private let language: ASRLanguage
    private let audio = AVAudioEngine()
    private let queue = DispatchQueue(label: "Korgino.dictate.audio")
    private let lock = NSLock()
    /// 电平不必每块缓冲都上主线程。
    private var lastLevelAt: CFAbsoluteTime = 0
    private var closed = false
    private var torn = false
    private let system: Bool
    private var floats: [Float] = []
    private var recorded: [AVAudioPCMBuffer] = []
    private var converter: AVAudioConverter?
    private var speech: DictateSpeech?
    private var analyzer: (any DictateAnalyzerSession)?
    private let interp: InterpFeed?

    init(engine: String, language: ASRLanguage, interp: InterpFeed? = nil, onPartial: @escaping @Sendable (String) -> Void) throws {
        engineID = engine
        self.language = language
        self.interp = interp
        let cfg = AppConfig.shared
        system = cfg.isSystemASR(engine)
        if interp != nil {
            return
        }
        if #available(macOS 26.0, *), cfg.isAnalyzerASR(engine), SpeechTranscriber.isAvailable {
            analyzer = DictateAnalyzer(locale: language.locale, terms: cfg.asrContextTerms, onPartial: onPartial)
        } else if system {
            speech = try DictateSpeech(
                locale: language.locale,
                onDevice: cfg.asrAppleOnDevice,
                terms: cfg.asrContextTerms,
                onPartial: onPartial
            )
        } else {
            _ = try cfg.asrWhisperConfig(selection: engine)
        }
    }

    func start() throws {
        if let analyzer { try analyzer.prepare() }
        let input = audio.inputNode
        // 选中的设备已经拔掉时退回系统默认。设置里仍显示已断开，插回后下一轮再用它。
        let chosen = AppConfig.shared.dictateInputUID
        var choseDevice = false
        if !chosen.isEmpty, let deviceID = MicInput.deviceID(uid: chosen) {
            try MicInput.select(deviceID, on: input)
            choseDevice = true
        }
        let format = try MicInput.readyInputFormat(input, failure: L("麦克风不可用"))
        // 只有输入的麦克风接进主混音器会在 start() 报 -10875。没选设备时仍走原来的接法。
        if !choseDevice {
            audio.connect(input, to: audio.mainMixerNode, format: format)
            audio.mainMixerNode.outputVolume = 0
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let copy = buffer.detachedCopy() else { return }
            let now = CFAbsoluteTimeGetCurrent()
            if let self, now - self.lastLevelAt >= 0.05,
               let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 {
                self.lastLevelAt = now
                var sum: Float = 0
                let count = Int(buffer.frameLength)
                for i in 0..<count { sum += samples[i] * samples[i] }
                let rms = (sum / Float(count)).squareRoot()
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { VoiceCapsule.shared.level(rms: rms) }
                }
            }
            self?.queue.async { self?.take(copy) }
        }
        do {
            audio.prepare()
            try audio.start()
        } catch {
            audio.inputNode.removeTap(onBus: 0)
            throw error
        }
        analyzer?.begin()
    }

    func transcript() async -> String {
        stopCapture(drain: true)
        if let speech {
            let streamed = await speech.finish()
            if !streamed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return streamed }
            return await fallback(onDevice: speech.keepOnDevice)
        }
        if let analyzer {
            let streamed = await analyzer.finish()
            if !streamed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return streamed }
            return await fallback(onDevice: false)
        }
        return await whisper(snapshotSamples())
    }

    private func fallback(onDevice: Bool) async -> String {
        let buffers = snapshotBuffers()
        let cfg = AppConfig.shared
        return await DictateOnce.transcribe(
            buffers: buffers,
            locale: language.locale,
            terms: cfg.asrContextTerms,
            onDevice: onDevice
        )
    }

    private func whisper(_ samples: [Float]) async -> String {
        let cfg: WhisperASRConfig
        do {
            cfg = try AppConfig.shared.asrWhisperConfig(selection: engineID)
        } catch {
            return ""
        }
        guard !samples.isEmpty else { return "" }
        let wav = PCM16WAV.data(samples: samples, sampleRate: 16_000)
        return (try? await WhisperASR.transcribe(
            wav: wav,
            config: cfg,
            language: language.whisperCode,
            prompt: AppConfig.shared.asrContextPrompt
        )) ?? ""
    }

    func cancel() {
        stopCapture(drain: false)
        speech?.cancel()
        analyzer?.cancel()
    }

    /// Stops the microphone after every captured buffer has been handed on.
    func stopListening() {
        stopCapture(drain: true)
    }

    private func stopCapture(drain: Bool) {
        lock.lock()
        if torn {
            lock.unlock()
            return
        }
        if !drain {
            torn = true
            closed = true
        }
        lock.unlock()
        audio.inputNode.removeTap(onBus: 0)
        audio.stop()
        guard drain else { return }
        queue.sync {}
        lock.lock()
        torn = true
        closed = true
        lock.unlock()
    }

    private func snapshotSamples() -> [Float] {
        lock.lock()
        let samples = floats
        lock.unlock()
        return samples
    }

    private func snapshotBuffers() -> [AVAudioPCMBuffer] {
        lock.lock()
        let buffers = recorded
        lock.unlock()
        return buffers
    }

    private func take(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let stop = closed
        lock.unlock()
        guard !stop else { return }
        if let interp {
            interp.take(buffer)
            return
        }
        if system {
            lock.lock()
            recorded.append(buffer)
            if recorded.count > 1500 { recorded.removeFirst(recorded.count - 1500) }
            lock.unlock()
            speech?.take(buffer) { [weak self] in
                guard let self else { return [] }
                self.lock.lock()
                let replay = self.recorded
                self.lock.unlock()
                return replay
            }
            analyzer?.append(buffer)
            return
        }
        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false) else { return }
        if converter == nil { converter = AVAudioConverter(from: buffer.format, to: mono) }
        guard let converter else { return }
        let ratio = 16_000 / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: capacity) else { return }
        var handed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if handed {
                status.pointee = .noDataNow
                return nil
            }
            handed = true
            status.pointee = .haveData
            return buffer
        }
        guard out.frameLength > 0, let channels = out.floatChannelData else { return }
        lock.lock()
        floats.append(contentsOf: UnsafeBufferPointer(start: channels[0], count: Int(out.frameLength)))
        lock.unlock()
    }
}

private final class DictateSpeech: @unchecked Sendable {
    private let recognizer: SFSpeechRecognizer
    private let terms: [String]
    private let onPartial: @Sendable (String) -> Void
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var latest = ""
    private var prefix = ""
    private var onDevice: Bool
    private var needsRestart = false
    private var needsRotate = false
    private var ending = false
    private var done = false
    private var wait: CheckedContinuation<String, Never>?

    var keepOnDevice: Bool { onDevice && !needsRestart }

    init(locale: Locale, onDevice: Bool, terms: [String], onPartial: @escaping @Sendable (String) -> Void) throws {
        guard let recognizer = DictateOnce.recognizer(for: locale) else {
            throw TErr(L("语音识别器暂不可用"))
        }
        self.recognizer = recognizer
        self.terms = terms
        self.onDevice = onDevice && recognizer.supportsOnDeviceRecognition
        self.onPartial = onPartial
        open(onDevice: self.onDevice, replay: [])
    }

    func take(_ buffer: AVAudioPCMBuffer, replayIfRestart: () -> [AVAudioPCMBuffer]) {
        lock.lock()
        let restart = needsRestart
        if restart { needsRestart = false }
        let ending = ending
        lock.unlock()
        guard !ending else { return }
        if restart {
            open(onDevice: false, replay: replayIfRestart())
            return
        }
        lock.lock()
        let rotate = needsRotate
        if rotate { needsRotate = false }
        let device = onDevice
        lock.unlock()
        if rotate {
            open(onDevice: device, replay: [])
        }
        request?.append(buffer)
    }

    func finish() async -> String {
        let request = markEnding()
        request?.endAudio()
        return await withCheckedContinuation { cont in
            lock.lock()
            if done {
                lock.unlock()
                cont.resume(returning: latest)
                return
            }
            wait = cont
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.complete()
            }
        }
    }

    func cancel() {
        lock.lock()
        ending = true
        let request = request
        let task = task
        lock.unlock()
        request?.endAudio()
        task?.cancel()
        complete()
    }

    private func open(onDevice: Bool, replay: [AVAudioPCMBuffer]) {
        task?.cancel()
        request?.endAudio()
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        if onDevice { req.requiresOnDeviceRecognition = true }
        if !terms.isEmpty { req.contextualStrings = terms }
        for buffer in replay { req.append(buffer) }
        lock.lock()
        self.onDevice = onDevice
        request = req
        done = false
        lock.unlock()
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            self?.hear(result, error: error)
        }
    }

    private func hear(_ result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            let piece = result.bestTranscription.formattedString
            lock.lock()
            let shown = Self.join(prefix, piece)
            latest = shown
            let rotate = result.isFinal && !ending
            if rotate {
                prefix = shown
                needsRotate = true
            }
            lock.unlock()
            onPartial(shown)
            if result.isFinal, !rotate { complete() }
            return
        }
        guard error != nil else { return }
        lock.lock()
        let canRetry = onDevice && !ending && latest.isEmpty
        if canRetry { needsRestart = true }
        let stop = ending
        lock.unlock()
        if stop { complete() }
    }

    private func markEnding() -> SFSpeechAudioBufferRecognitionRequest? {
        lock.lock()
        ending = true
        let request = request
        lock.unlock()
        return request
    }

    private func complete() {
        lock.lock()
        if done {
            lock.unlock()
            return
        }
        done = true
        let text = latest
        let cont = wait
        wait = nil
        lock.unlock()
        cont?.resume(returning: text)
    }

    private static func join(_ base: String, _ next: String) -> String {
        let a = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = next.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        if b.hasPrefix(a) { return b }
        let left = a.last?.isASCII == true && a.last?.isLetter == true
        let right = b.first?.isASCII == true && b.first?.isLetter == true
        return left && right ? a + " " + b : a + b
    }
}

/// 听写的 SpeechAnalyzer 车道。类型本身是 macOS 26 的，`FnDictate` 只通过这个协议拿它，好在 15 上编得过。
private protocol DictateAnalyzerSession: AnyObject {
    func prepare() throws
    func begin()
    func append(_ buffer: AVAudioPCMBuffer)
    func finish() async -> String
    func cancel()
}

@available(macOS 26.0, *)
private final class DictateAnalyzer: DictateAnalyzerSession, @unchecked Sendable {
    private let locale: Locale
    private let terms: [String]
    private let onPartial: @Sendable (String) -> Void
    private let lock = NSLock()
    private var latest = ""
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var task: Task<Void, Never>?
    private var target: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var held: [AVAudioPCMBuffer] = []

    init(locale: Locale, terms: [String], onPartial: @escaping @Sendable (String) -> Void) {
        self.locale = locale
        self.terms = terms
        self.onPartial = onPartial
    }

    func prepare() throws {
        guard SpeechTranscriber.isAvailable else { throw TErr(L("这台 Mac 上的语音分析不可用")) }
    }

    func begin() {
        let locale = locale
        let terms = terms
        task = Task { [weak self] in
            guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return }
            let transcriber = SpeechTranscriber(
                locale: supported,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults],
                attributeOptions: []
            )
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            if !terms.isEmpty {
                let context = AnalysisContext()
                context.contextualStrings = [.general: terms]
                try? await analyzer.setContext(context)
            }
            let natural = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: natural) else { return }
            try? await analyzer.prepareToAnalyze(in: format)
            let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
            let pending = self?.arm(format, continuation) ?? []
            for pcm in pending { self?.append(pcm) }
            try? await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    do {
                        for try await result in transcriber.results {
                            let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !text.isEmpty else { continue }
                            self?.note(text)
                        }
                    } catch {}
                }
                group.addTask {
                    try await analyzer.start(inputSequence: stream)
                }
                try await group.waitForAll()
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let slot = hold(buffer)
        guard let input = slot.input, let target = slot.target, let converted = convert(buffer, to: target) else { return }
        input.yield(AnalyzerInput(buffer: converted))
    }

    func finish() async -> String {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if armed() { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        takeInput()?.finish()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.task?.value }
            group.addTask { try? await Task.sleep(nanoseconds: 800_000_000) }
            await group.next()
            group.cancelAll()
        }
        return currentText()
    }

    func cancel() {
        takeInput()?.finish()
        task?.cancel()
    }

    private func note(_ text: String) {
        lock.lock()
        latest = text
        lock.unlock()
        onPartial(text)
    }

    private func arm(_ format: AVAudioFormat, _ continuation: AsyncStream<AnalyzerInput>.Continuation) -> [AVAudioPCMBuffer] {
        lock.lock()
        target = format
        input = continuation
        let pending = held
        held = []
        lock.unlock()
        return pending
    }

    private func hold(_ buffer: AVAudioPCMBuffer) -> (input: AsyncStream<AnalyzerInput>.Continuation?, target: AVAudioFormat?) {
        lock.lock()
        let input = input
        let target = target
        if input == nil || target == nil {
            held.append(buffer)
            if held.count > 40 { held.removeFirst(held.count - 40) }
        }
        lock.unlock()
        return (input, target)
    }

    private func armed() -> Bool {
        lock.lock()
        let ready = input != nil
        lock.unlock()
        return ready
    }

    private func takeInput() -> AsyncStream<AnalyzerInput>.Continuation? {
        lock.lock()
        let continuation = input
        input = nil
        lock.unlock()
        return continuation
    }

    private func currentText() -> String {
        lock.lock()
        let text = latest
        lock.unlock()
        return text
    }

    private func convert(_ pcm: AVAudioPCMBuffer, to target: AVAudioFormat) -> AVAudioPCMBuffer? {
        if pcm.format == target { return pcm }
        if converter == nil { converter = AVAudioConverter(from: pcm.format, to: target) }
        guard let converter else { return nil }
        let ratio = target.sampleRate / pcm.format.sampleRate
        let capacity = AVAudioFrameCount(Double(pcm.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var handed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, state in
            if handed {
                state.pointee = .noDataNow
                return nil
            }
            handed = true
            state.pointee = .haveData
            return pcm
        }
        guard status != .error, out.frameLength > 0 else { return nil }
        return out
    }
}

private enum DictateOnce {
    static func transcribe(buffers: [AVAudioPCMBuffer], locale: Locale, terms: [String], onDevice: Bool) async -> String {
        guard !buffers.isEmpty else { return "" }
        let first = await recognize(buffers: buffers, locale: locale, terms: terms, onDevice: onDevice)
        if !first.isEmpty || !onDevice { return first }
        return await recognize(buffers: buffers, locale: locale, terms: terms, onDevice: false)
    }

    static func recognizer(for locale: Locale) -> SFSpeechRecognizer? {
        if let made = SFSpeechRecognizer(locale: locale), made.isAvailable { return made }
        let code = locale.language.languageCode?.identifier
        if let code {
            for loc in SFSpeechRecognizer.supportedLocales() {
                guard loc.language.languageCode?.identifier == code else { continue }
                if let made = SFSpeechRecognizer(locale: loc), made.isAvailable { return made }
            }
        }
        return SFSpeechRecognizer()
    }

    private static func recognize(buffers: [AVAudioPCMBuffer], locale: Locale, terms: [String], onDevice: Bool) async -> String {
        guard let recognizer = recognizer(for: locale) else { return "" }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if onDevice, recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        if !terms.isEmpty { request.contextualStrings = terms }
        for buffer in buffers { request.append(buffer) }
        request.endAudio()
        let box = OnceBox()
        return await withCheckedContinuation { cont in
            box.task = recognizer.recognitionTask(with: request) { result, error in
                if let result {
                    box.lock.lock()
                    box.latest = result.bestTranscription.formattedString
                    box.lock.unlock()
                }
                if result?.isFinal == true || error != nil { box.finish(cont) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 4) { box.finish(cont) }
        }
    }
}

private final class OnceBox: @unchecked Sendable {
    let lock = NSLock()
    var latest = ""
    var task: SFSpeechRecognitionTask?
    private var resumed = false

    func finish(_ cont: CheckedContinuation<String, Never>) {
        lock.lock()
        if resumed {
            lock.unlock()
            return
        }
        resumed = true
        let text = latest
        lock.unlock()
        task?.cancel()
        cont.resume(returning: text)
    }
}
