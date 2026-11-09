import AVFoundation
import Speech

/// 媒体字幕的 Apple 识别：macOS 26 的 SpeechAnalyzer 整份识别。时间取自识别结果自己的时间段。
@available(macOS 26.0, *)
enum MediaAnalyzerASR {
    enum Readiness {
        case ready(Locale)
        case needsModel(Locale)
        case unsupported
    }

    static func readiness(for locale: Locale) async -> Readiness {
        guard SpeechTranscriber.isAvailable,
              let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return .unsupported }
        let module = SpeechTranscriber(locale: supported, preset: .transcription)
        switch await AssetInventory.status(forModules: [module]) {
        case .installed:
            return .ready(supported)
        case .supported, .downloading:
            // A model already on this Mac still reports .supported until this app reserves it; reserving downloads nothing.
            let onDisk = await SpeechTranscriber.installedLocales
            if onDisk.contains(where: { $0.identifier(.bcp47) == supported.identifier(.bcp47) }),
               (try? await installModel(supported) { _ in }) != nil {
                return .ready(supported)
            }
            return .needsModel(supported)
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }

    static func installModel(_ locale: Locale, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let module = SpeechTranscriber(locale: locale, preset: .transcription)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else { return }
        let watch = request.progress.observe(\.fractionCompleted, options: [.initial, .new]) { progress, _ in
            onProgress(progress.fractionCompleted)
        }
        defer { watch.invalidate() }
        try await request.downloadAndInstall()
    }

    static func transcribe(
        url: URL,
        trackID: Int,
        from start: TimeInterval,
        locale: Locale,
        onProgress: @escaping @Sendable (TimeInterval) -> Void,
        onPieces: @escaping @Sendable ([MediaPiece]) -> Void
    ) async throws {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let reader = try await MediaTranscriber.openReader(url: url, trackID: trackID, from: start)

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let terms = AppConfig.shared.asrContextTerms
        if !terms.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings = [.general: terms]
            try await analyzer.setContext(context)
        }
        let natural = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: natural) else {
            throw TErr(L("这台 Mac 上的语音识别不可用"))
        }
        try await analyzer.prepareToAnalyze(in: format)

        let feed = MediaAnalyzerFeed(reader: reader, start: start, target: format, onProgress: onProgress)
        let results = Task {
            for try await result in transcriber.results {
                let cut = MediaCutter.cut(feed.marks.tag(feed.onsets.snap(pieces(from: result, offset: start))))
                if !cut.isEmpty { onPieces(cut) }
            }
        }
        do {
            try await withTaskCancellationHandler {
                if let last = try await analyzer.analyzeSequence(MediaAnalyzerInput(feed: feed)) {
                    try await analyzer.finalizeAndFinish(through: last)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } onCancel: {
                feed.stop()
                Task { await analyzer.cancelAndFinishNow() }
            }
            try await results.value
        } catch {
            results.cancel()
            throw error
        }
        try Task.checkCancellation()
        if let failure = feed.failure { throw failure }
    }

    /// 一段结果按词拆开，每个词带自己的时间。没有时间的标点跟着前一个词。
    private static func pieces(from result: SpeechTranscriber.Result, offset: TimeInterval) -> [MediaPiece] {
        var out: [MediaPiece] = []
        var cursor = offset + result.range.start.seconds
        for run in result.text.runs {
            let text = String(result.text[run.range].characters)
            guard !text.isEmpty else { continue }
            var begin = cursor
            var end = cursor
            if let range = run.audioTimeRange, range.start.seconds.isFinite, range.end.seconds.isFinite {
                begin = offset + range.start.seconds
                end = offset + range.end.seconds
            }
            end = max(end, begin + 0.05)
            out.append(MediaPiece(text: text, start: begin, end: end, speaker: 0))
            cursor = end
        }
        if out.isEmpty {
            let text = String(result.text.characters)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let begin = offset + result.range.start.seconds
                out.append(MediaPiece(text: text, start: begin, end: max(begin + 0.2, offset + result.range.end.seconds), speaker: 0))
            }
        }
        return out
    }
}

/// 识别器要一块，才从文件里读一块，内存不随文件变长。
@available(macOS 26.0, *)
final class MediaAnalyzerFeed: @unchecked Sendable {
    let marks = SpeakerMarks()
    let onsets = VoiceOnsets()
    private let reader: MediaTranscriber.OpenReader
    private let start: TimeInterval
    private let target: AVAudioFormat
    private let onProgress: @Sendable (TimeInterval) -> Void
    private var converter: AVAudioConverter?
    private var speakers = SpeakerTracker()
    private let lock = NSLock()
    private var stopped = false
    private var failed: Error?

    init(reader: MediaTranscriber.OpenReader, start: TimeInterval, target: AVAudioFormat, onProgress: @escaping @Sendable (TimeInterval) -> Void) {
        self.reader = reader
        self.start = start
        self.target = target
        self.onProgress = onProgress
        speakers.kind = .system
    }

    var failure: Error? {
        lock.lock()
        defer { lock.unlock() }
        return failed
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    func next() -> AnalyzerInput? {
        while true {
            if isStopped || Task.isCancelled { return nil }
            guard let sample = reader.output.copyNextSampleBuffer() else {
                if reader.reader.status == .failed {
                    lock.lock()
                    failed = reader.reader.error ?? TErr(L("读不出这条音轨"))
                    lock.unlock()
                }
                return nil
            }
            guard let pcm = LiveASRLane.pcmBuffer(from: sample) else { continue }
            let raw = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            let fileTime = raw.isFinite ? raw : start
            if let channels = pcm.floatChannelData {
                speakers.push(channels[0], count: Int(pcm.frameLength), sampleRate: pcm.format.sampleRate)
                onsets.scan(channels[0], count: Int(pcm.frameLength), sampleRate: pcm.format.sampleRate, at: fileTime)
            }
            marks.append(time: fileTime, speaker: speakers.speaker)
            onProgress(max(fileTime, start))
            guard let converted = convert(pcm) else { continue }
            return AnalyzerInput(buffer: converted)
        }
    }

    private func convert(_ pcm: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
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

@available(macOS 26.0, *)
struct MediaAnalyzerInput: AsyncSequence, Sendable {
    typealias Element = AnalyzerInput
    let feed: MediaAnalyzerFeed

    struct AsyncIterator: AsyncIteratorProtocol {
        let feed: MediaAnalyzerFeed
        mutating func next() async -> AnalyzerInput? { feed.next() }
    }

    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(feed: feed) }
}

/// 静了一阵之后出声的时刻。识别结果里第一个词的时间常把前面的静音也算进去，用这些时刻把开头挪到真正出声的地方。
final class VoiceOnsets: @unchecked Sendable {
    private let lock = NSLock()
    private var times: [TimeInterval] = []
    /// 只在读声音的那个线程里用。
    private var quietFor: TimeInterval = .infinity

    private static let window: TimeInterval = 0.02
    private static let settle: TimeInterval = 0.3

    func scan(_ samples: UnsafePointer<Float>, count: Int, sampleRate: Double, at time: TimeInterval) {
        guard sampleRate > 0, count > 0 else { return }
        let step = max(1, Int(sampleRate * Self.window))
        var found: [TimeInterval] = []
        var i = 0
        while i < count {
            let n = min(step, count - i)
            var sum: Float = 0
            for k in 0..<n { sum += samples[i + k] * samples[i + k] }
            let level = (sum / Float(n)).squareRoot()
            if level < MediaTranscriber.quietLevel {
                quietFor += Double(n) / sampleRate
            } else {
                if quietFor >= Self.settle { found.append(time + Double(i) / sampleRate) }
                quietFor = 0
            }
            i += n
        }
        guard !found.isEmpty else { return }
        lock.lock()
        times.append(contentsOf: found)
        lock.unlock()
    }

    func snap(_ pieces: [MediaPiece]) -> [MediaPiece] {
        lock.lock()
        let times = times
        lock.unlock()
        guard !times.isEmpty else { return pieces }
        return pieces.map { piece in
            var lo = 0
            var hi = times.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if times[mid] <= piece.start { lo = mid + 1 } else { hi = mid }
            }
            guard lo < times.count else { return piece }
            let onset = times[lo]
            guard onset < piece.end - 0.05, onset - piece.start > 0.25 else { return piece }
            var moved = piece
            moved.start = onset
            return moved
        }
    }
}

/// 读声音时记下的说话人。按时间查，二分。
final class SpeakerMarks: @unchecked Sendable {
    private let lock = NSLock()
    private var times: [TimeInterval] = []
    private var speakers: [Int] = []

    func append(time: TimeInterval, speaker: Int) {
        lock.lock()
        if let last = times.last, time < last {
            lock.unlock()
            return
        }
        times.append(time)
        speakers.append(speaker)
        lock.unlock()
    }

    func tag(_ pieces: [MediaPiece]) -> [MediaPiece] {
        lock.lock()
        defer { lock.unlock() }
        guard !times.isEmpty else { return pieces }
        return pieces.map { piece in
            var copy = piece
            copy.speaker = speaker(at: (piece.start + piece.end) / 2)
            return copy
        }
    }

    private func speaker(at time: TimeInterval) -> Int {
        var lo = 0
        var hi = times.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if times[mid] <= time { lo = mid + 1 } else { hi = mid }
        }
        return lo == 0 ? 0 : speakers[lo - 1]
    }
}
