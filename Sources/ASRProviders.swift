import AVFoundation
import CoreMedia
import Foundation
import Speech

protocol LiveAudioSink: AnyObject {
    func prepare() throws
    func ensureConverter(from format: AVAudioFormat)
    func startRecognition()
    func append(pcm: AVAudioPCMBuffer)
    func append(sampleBuffer: CMSampleBuffer)
    func stop()
    /// 停下来，并把还在路上的最后一句等出来再交回。
    func finish() async
}

extension LiveAudioSink {
    func finish() async { stop() }
}

final class LiveWhisperLane: @unchecked Sendable {
    let source: SystemAudioTranslateController.SourceKind
    private let config: WhisperASRConfig
    private let language: String?
    private let prompt: String?
    private let onHypothesis: @Sendable (SystemAudioTranslateController.SourceKind, String, Bool, Int) -> Void
    private let onBusy: @Sendable (SystemAudioTranslateController.SourceKind, Bool) -> Void
    private let onError: @Sendable (SystemAudioTranslateController.SourceKind, String) -> Void

    private let queue: DispatchQueue
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var pending: [Float] = []
    private var lastVoiceAt: Date?
    private var inFlight = false
    private var flightStarted: Date?
    private var flightToken = 0
    private var wantFlush = false
    private var speakers = SpeakerTracker()
    private var stopped = false

    private let sampleRate = 16000
    private let voiceRMS: Float = 0.012

    init(
        source: SystemAudioTranslateController.SourceKind,
        config: WhisperASRConfig,
        language: String?,
        prompt: String?,
        onHypothesis: @escaping @Sendable (SystemAudioTranslateController.SourceKind, String, Bool, Int) -> Void,
        onBusy: @escaping @Sendable (SystemAudioTranslateController.SourceKind, Bool) -> Void,
        onError: @escaping @Sendable (SystemAudioTranslateController.SourceKind, String) -> Void
    ) {
        self.source = source
        self.config = config
        self.language = language
        self.prompt = prompt
        self.onHypothesis = onHypothesis
        self.onBusy = onBusy
        self.onError = onError
        self.queue = DispatchQueue(label: "com.sliiu.Korgino.whisper.\(source.rawValue)", qos: .userInitiated)
        self.speakers.kind = source
    }

    func prepare() throws {
        if config.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw TErr(L("请先在设置里填写语音识别 API Key"))
        }
        if config.transcriptionURL == nil {
            throw TErr(L("Whisper 接口地址无效"))
        }
    }

    func ensureConverter(from format: AVAudioFormat) {
        queue.async { [weak self] in
            self?.ensureConverterLocked(from: format)
        }
    }

    func startRecognition() {}

    func append(pcm: AVAudioPCMBuffer) {
        queue.async { [weak self] in
            self?.appendLocked(pcm: pcm)
        }
    }

    func append(sampleBuffer: CMSampleBuffer) {
        guard let pcm = LiveASRLane.pcmBuffer(from: sampleBuffer) else { return }
        append(pcm: pcm)
    }

    func stop() {
        queue.sync { [weak self] in
            guard let self else { return }
            self.stopped = true
            if !self.pending.isEmpty, self.lastVoiceAt != nil {
                self.flushLocked()
            }
            self.pending.removeAll()
            self.converter = nil
            self.targetFormat = nil
        }
    }

    private func ensureConverterLocked(from format: AVAudioFormat) {
        if converter != nil, targetFormat != nil { return }
        guard format.channelCount > 0, format.sampleRate > 0 else { return }
        guard let mono = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        ) else { return }
        targetFormat = mono
        converter = AVAudioConverter(from: format, to: mono)
    }

    private func appendLocked(pcm: AVAudioPCMBuffer) {
        guard !stopped else { return }
        if converter == nil || targetFormat == nil {
            ensureConverterLocked(from: pcm.format)
        }
        guard let converted = convertLocked(pcm) else { return }
        guard let channels = converted.floatChannelData else { return }
        let frames = Int(converted.frameLength)
        guard frames > 0 else { return }
        pending.append(contentsOf: UnsafeBufferPointer(start: channels[0], count: frames))
        let meterCount = min(pending.count, sampleRate / 10)
        let meter = meterCount == 0 ? 0 : rms(pending.suffix(meterCount))
        SystemAudioTranslateController.reportLevel(source, rms: meter)
        speakers.push(channels[0], count: frames, sampleRate: Double(sampleRate))
        let cap = sampleRate * 20
        if pending.count > cap {
            pending.removeFirst(pending.count - cap)
        }
        if inFlight, let flightStarted, Date().timeIntervalSince(flightStarted) > 22 {
            inFlight = false
            self.flightStarted = nil
            flightToken += 1
            onBusy(source, false)
        }

        let seconds = Double(pending.count) / Double(sampleRate)
        let tailCount = min(pending.count, Int(0.22 * Double(sampleRate)))
        let silent = tailCount == 0 || rms(pending.suffix(tailCount)) < voiceRMS
        if !silent { lastVoiceAt = Date() }

        if lastVoiceAt == nil, seconds > 3.5 {
            pending.removeAll(keepingCapacity: true)
            SystemAudioTranslateController.reportLevel(source, rms: 0)
            return
        }
        let quietFor = lastVoiceAt.map { Date().timeIntervalSince($0) } ?? 0
        if seconds >= 3.2 || (lastVoiceAt != nil && quietFor >= 0.7 && seconds >= 0.55) || seconds >= 8 {
            flushLocked()
        }
    }

    private func convertLocked(_ pcm: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter, let targetFormat else { return pcm }
        let capacity = AVAudioFrameCount(
            Double(pcm.frameLength) * targetFormat.sampleRate / max(pcm.format.sampleRate, 1)
        )
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: max(capacity, 1)) else {
            return pcm
        }
        var error: NSError?
        var consumed = false
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return pcm
        }
        if error == nil, out.frameLength > 0 { return out }
        return nil
    }

    private func flushLocked() {
        guard !stopped else { return }
        if inFlight {
            wantFlush = true
            return
        }
        let minSamples = Int(0.45 * Double(sampleRate))
        guard pending.count >= minSamples else { return }
        let samples = pending
        pending.removeAll(keepingCapacity: true)
        lastVoiceAt = nil
        inFlight = true
        flightStarted = Date()
        flightToken += 1
        let token = flightToken
        onBusy(source, true)
        let cfg = config
        let lang = language
        let hint = prompt
        let src = source
        let speaker = speakers.speaker
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let wav = PCM16WAV.data(samples: samples, sampleRate: 16000)
                let text = try await WhisperASR.transcribe(wav: wav, config: cfg, language: lang, prompt: hint)

                self?.queue.async {
                    guard let self, self.flightToken == token else { return }
                    self.inFlight = false
                    self.flightStarted = nil
                    self.onBusy(src, false)
                    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { self.onHypothesis(src, t, true, speaker) }
                    if self.wantFlush {
                        self.wantFlush = false
                        self.flushLocked()
                    }
                }
            } catch {
                self?.queue.async {
                    guard let self, !self.stopped, self.flightToken == token else { return }
                    self.inFlight = false
                    self.flightStarted = nil
                    self.onBusy(src, false)
                    self.onError(src, error.localizedDescription)
                    if self.wantFlush {
                        self.wantFlush = false
                        self.flushLocked()
                    }
                }
            }
        }
    }

    private func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var s: Float = 0
        for x in samples { s += x * x }
        return sqrt(s / Float(samples.count))
    }
}

extension LiveWhisperLane: LiveAudioSink {}
extension LiveASRLane: LiveAudioSink {}

/// SpeechAnalyzer 的实时车道。系统低于 macOS 26 时没有这个类型，`makeSink` 会退回 `LiveASRLane`。
@available(macOS 26.0, *)
final class LiveAnalyzerLane: LiveAudioSink, @unchecked Sendable {
    let source: SystemAudioTranslateController.SourceKind
    private let locale: Locale
    private let terms: [String]
    private let onHypothesis: @Sendable (SystemAudioTranslateController.SourceKind, String, Bool, Int) -> Void
    private let onError: @Sendable (SystemAudioTranslateController.SourceKind, String) -> Void

    private let queue = DispatchQueue(label: "com.sliiu.Korgino.analyzer", qos: .userInitiated)
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var targetFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var converterSource: AVAudioFormat?
    private var held: [AVAudioPCMBuffer] = []
    private var speakers = SpeakerTracker()
    private var speaker = 0
    private var clock: TimeInterval = 0
    private var stamps: [(time: TimeInterval, speaker: Int)] = []
    private let speakerLock = NSLock()
    private var pitchConverter: AVAudioConverter?
    private var pitchSource: AVAudioFormat?
    private var stopped = false
    private var task: Task<Void, Never>?
    /// 收尾要用它把最后一句挤出来，光取消任务会把没吐完的结果一起丢掉。
    private var analyzer: SpeechAnalyzer?

    init(
        source: SystemAudioTranslateController.SourceKind,
        locale: Locale,
        terms: [String],
        onHypothesis: @escaping @Sendable (SystemAudioTranslateController.SourceKind, String, Bool, Int) -> Void,
        onError: @escaping @Sendable (SystemAudioTranslateController.SourceKind, String) -> Void
    ) {
        self.source = source
        self.locale = locale
        self.terms = terms
        self.onHypothesis = onHypothesis
        self.onError = onError
        self.speakers.kind = source
    }

    func prepare() throws {
        guard SpeechTranscriber.isAvailable else {
            throw TErr(L("这台 Mac 上的语音分析不可用"))
        }
    }

    func ensureConverter(from format: AVAudioFormat) {}

    func startRecognition() {
        let locale = locale
        let terms = terms
        let source = source
        task = Task { [weak self] in
            do {
                guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
                    throw TErr(String(format: L("语音分析不支持这种语言：%@"), locale.identifier))
                }
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
                    try await analyzer.setContext(context)
                }
                let natural = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
                guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: natural) else {
                    throw TErr(L("这台 Mac 上的语音分析不可用"))
                }
                try await analyzer.prepareToAnalyze(in: format)
                let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
                self?.queue.async {
                    guard let self, !self.stopped else {
                        continuation.finish()
                        return
                    }
                    self.targetFormat = format
                    self.input = continuation
                    self.analyzer = analyzer
                    self.clock = 0
                    self.speakerLock.lock()
                    self.stamps.removeAll()
                    self.speakerLock.unlock()
                    let pending = self.held
                    self.held = []
                    for pcm in pending { self.emitLocked(pcm) }
                }
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for try await result in transcriber.results {
                            let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !text.isEmpty else { continue }
                            let end = CMTimeGetSeconds(result.range.end)
                            let who = self?.speaker(at: end) ?? 0
                            self?.onHypothesis(source, text, result.isFinal, who)
                        }
                    }
                    group.addTask {
                        try await analyzer.start(inputSequence: stream)
                    }
                    try await group.waitForAll()
                }
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                self?.onError(source, error.localizedDescription)
            }
        }
    }

    func append(pcm: AVAudioPCMBuffer) {
        guard let copy = pcm.detachedCopy() else { return }
        queue.async { [weak self] in
            self?.emitLocked(copy)
        }
    }

    func append(sampleBuffer: CMSampleBuffer) {
        guard let pcm = LiveASRLane.pcmBuffer(from: sampleBuffer) else { return }
        append(pcm: pcm)
    }

    func stop() {
        _ = closeInput()
        task?.cancel()
    }

    func finish() async {
        // 先把入口关掉，再让分析器把缓冲里剩下的话收完。直接 cancel 会让尾巴整句消失。
        guard let (analyzer, task) = closeInput() else { return }
        do { try await analyzer.finalizeAndFinishThroughEndOfInput() } catch {}
        // 终稿由分析器异步送回来，给它一点时间落地再收工。
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await task?.value }
            group.addTask { try? await Task.sleep(nanoseconds: 900_000_000) }
            await group.next()
            group.cancelAll()
        }
        task?.cancel()
    }

    /// 关掉输入口，交出分析器和任务；调用方负责把它们收尾。
    private func closeInput() -> (SpeechAnalyzer, Task<Void, Never>?)? {
        let closed = queue.sync { () -> SpeechAnalyzer? in
            stopped = true
            input?.finish()
            input = nil
            held.removeAll()
            defer { self.analyzer = nil }
            return self.analyzer
        }
        guard let closed else { return nil }
        return (closed, task)
    }

    /// Speaker at an analyzer timestamp. Results arrive later than the audio, so the person is whoever was speaking then, not whoever is speaking when the text shows up.
    private func speaker(at time: TimeInterval) -> Int {
        speakerLock.lock()
        defer { speakerLock.unlock() }
        guard time.isFinite, time > 0, !stamps.isEmpty else { return speaker }
        var lo = 0
        var hi = stamps.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if stamps[mid].time <= time { lo = mid + 1 } else { hi = mid }
        }
        let found = stamps[lo == 0 ? 0 : lo - 1].speaker
        return found > 0 ? found : speaker
    }

    private func emitLocked(_ pcm: AVAudioPCMBuffer) {
        guard !stopped else { return }
        guard let input, let targetFormat else {
            held.append(pcm)
            if held.count > 40 { held.removeFirst(held.count - 40) }
            return
        }
        guard let converted = convert(pcm, to: targetFormat) else { return }
        // The analyzer's own format is often interleaved or integer. Pitch only reads mono float, same as the Apple 语音 lane.
        if let heard = monoFloat(pcm), let channels = heard.floatChannelData {
            speakers.push(channels[0], count: Int(heard.frameLength), sampleRate: heard.format.sampleRate)
        }
        let at = clock
        clock += Double(converted.frameLength) / max(converted.format.sampleRate, 1)
        let who = speakers.speaker
        speakerLock.lock()
        speaker = who
        if stamps.last?.speaker != who {
            stamps.append((time: at, speaker: who))
            if stamps.count > 2000 { stamps.removeFirst(stamps.count - 2000) }
        }
        speakerLock.unlock()
        input.yield(AnalyzerInput(buffer: converted))
    }

    private func monoFloat(_ pcm: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if pcm.format.commonFormat == .pcmFormatFloat32, !pcm.format.isInterleaved, pcm.floatChannelData != nil {
            return pcm
        }
        let rate = pcm.format.sampleRate > 0 ? pcm.format.sampleRate : 48_000
        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false) else { return nil }
        if pcm.format == mono { return pcm }
        if pitchConverter == nil || pitchSource != pcm.format {
            pitchConverter = AVAudioConverter(from: pcm.format, to: mono)
            pitchSource = pcm.format
        }
        guard let pitchConverter else { return nil }
        guard let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: max(pcm.frameLength, 1)) else { return nil }
        var handed = false
        var error: NSError?
        let status = pitchConverter.convert(to: out, error: &error) { _, state in
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

    private func convert(_ pcm: AVAudioPCMBuffer, to target: AVAudioFormat) -> AVAudioPCMBuffer? {
        if pcm.format == target { return pcm }
        if converter == nil || converterSource != pcm.format {
            converter = AVAudioConverter(from: pcm.format, to: target)
            converterSource = pcm.format
        }
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
