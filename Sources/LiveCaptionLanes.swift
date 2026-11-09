import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit
import Speech

final class LaneFan: LiveAudioSink {
    var children: [any LiveAudioSink] = []
    func prepare() throws { for child in children { try child.prepare() } }
    func ensureConverter(from format: AVAudioFormat) { for child in children { child.ensureConverter(from: format) } }
    func startRecognition() { for child in children { child.startRecognition() } }
    func append(pcm: AVAudioPCMBuffer) { for child in children { child.append(pcm: pcm) } }
    func append(sampleBuffer: CMSampleBuffer) { for child in children { child.append(sampleBuffer: sampleBuffer) } }
    func stop() {
        for child in children { child.stop() }
        children = []
    }
}

enum SpeakerThreshold {
    static let key = "live.speakerThreshold"
    static let range: ClosedRange<Double> = 0.08...0.45

    static func current(_ kind: SystemAudioTranslateController.SourceKind) -> Float {
        let key = kind == .system ? "live.speakerThreshold.system" : "live.speakerThreshold.mic"
        let stored = UserDefaults.standard.object(forKey: key) as? Double
            ?? UserDefaults.standard.object(forKey: Self.key) as? Double
            ?? 0.2
        return Float(min(range.upperBound, max(range.lowerBound, stored)))
    }
}

struct SpeakerTracker {
    var kind: SystemAudioTranslateController.SourceKind = .system
    private struct Profile {
        var pitch: Float
        var zcr: Float
    }

    private var profiles: [Profile] = []
    private var votes: [Int] = []
    private var current = 1
    private var window: [Float] = []
    private var sinceEval = 0

    var speaker: Int { profiles.isEmpty ? 0 : current }

    mutating func push(_ samples: UnsafePointer<Float>, count: Int, sampleRate: Double) {
        guard count > 0, sampleRate > 0 else { return }
        let step = max(1, Int((sampleRate / 8000).rounded()))
        let effective = Float(sampleRate) / Float(step)
        var index = 0
        while index < count {
            window.append(samples[index])
            index += step
        }
        if window.count > 4800 {
            window.removeFirst(window.count - 4800)
        }
        sinceEval += count / step
        guard sinceEval >= 700 else { return }
        sinceEval = 0
        evaluate(sampleRate: effective)
    }

    private mutating func evaluate(sampleRate: Float) {
        guard window.count >= 1000 else { return }
        let slice = Array(window.suffix(1400))
        var energy: Float = 0
        for x in slice { energy += x * x }
        guard sqrt(energy / Float(slice.count)) > 0.015 else { return }
        guard let pitch = pitchOf(slice, sampleRate: sampleRate) else { return }
        let zcr = zeroCrossing(slice)
        let guess = match(pitch: pitch, zcr: zcr)
        votes.append(guess)
        if votes.count > 5 { votes.removeFirst(votes.count - 5) }
        if votes.filter({ $0 == guess }).count >= 3 {
            current = guess
        }
    }

    private mutating func match(pitch: Float, zcr: Float) -> Int {
        var bestIndex = -1
        var best = Float.greatestFiniteMagnitude
        for (index, profile) in profiles.enumerated() {
            let pitchDelta = abs(pitch - profile.pitch) / max(profile.pitch, 1)
            let distance = pitchDelta + abs(zcr - profile.zcr) * 0.85
            if distance < best {
                best = distance
                bestIndex = index
            }
        }
        if bestIndex >= 0, best < SpeakerThreshold.current(kind) {
            profiles[bestIndex].pitch = profiles[bestIndex].pitch * 0.82 + pitch * 0.18
            profiles[bestIndex].zcr = profiles[bestIndex].zcr * 0.82 + zcr * 0.18
            return bestIndex + 1
        }
        guard profiles.count < 5 else { return max(bestIndex, 0) + 1 }
        profiles.append(Profile(pitch: pitch, zcr: zcr))
        return profiles.count
    }

    private func pitchOf(_ samples: [Float], sampleRate: Float) -> Float? {
        let minLag = max(1, Int(sampleRate / 420))
        let maxLag = min(samples.count / 2, Int(sampleRate / 75))
        guard maxLag > minLag else { return nil }
        var bestLag = 0
        var best: Float = 0
        let count = samples.count
        var lag = minLag
        while lag <= maxLag {
            var corr: Float = 0
            var left: Float = 0
            var right: Float = 0
            var index = 0
            let limit = count - lag
            while index < limit {
                let a = samples[index]
                let b = samples[index + lag]
                corr += a * b
                left += a * a
                right += b * b
                index += 2
            }
            let norm = corr / sqrt(max(left * right, 1e-8))
            if norm > best {
                best = norm
                bestLag = lag
            }
            lag += 1
        }
        guard best > 0.45, bestLag > 0 else { return nil }
        return sampleRate / Float(bestLag)
    }

    private func zeroCrossing(_ samples: [Float]) -> Float {
        guard samples.count > 1 else { return 0 }
        var crossings = 0
        for index in 1..<samples.count where (samples[index] >= 0) != (samples[index - 1] >= 0) {
            crossings += 1
        }
        return Float(crossings) / Float(samples.count)
    }
}

/// One recognition lane. All mutable state is confined to `queue` to avoid
/// NSLock re-entrancy deadlocks (append → ensureConverter used to lock twice)
/// and lock ↔ Speech callback inversions that froze live captions on start.
final class LiveASRLane: @unchecked Sendable {
    let source: SystemAudioTranslateController.SourceKind
    private let locale: Locale
    private let preferOnDevice: Bool
    private let terms: [String]
    private let onHypothesis: @Sendable (SystemAudioTranslateController.SourceKind, String, Bool, Int) -> Void

    private let queue: DispatchQueue
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var startedAt = Date()
    private var beganAt = Date.distantPast
    private var lastFinalText = ""
    private var lastHypothesis = ""
    private var generation = 0
    private var voicedSinceResult = 0.0
    private var speakers = SpeakerTracker()
    private var stopped = false
    /// 停止旗与收尾状态分属两条线程：界面线程写旗，识别队列读旗并收尾。
    private let stopLock = NSLock()
    private var stopRequested = false

    init(
        source: SystemAudioTranslateController.SourceKind,
        locale: Locale,
        preferOnDevice: Bool,
        terms: [String],
        onHypothesis: @escaping @Sendable (SystemAudioTranslateController.SourceKind, String, Bool, Int) -> Void
    ) {
        self.source = source
        self.locale = locale
        self.preferOnDevice = preferOnDevice
        self.terms = terms
        self.onHypothesis = onHypothesis
        self.queue = DispatchQueue(label: "com.sliiu.Korgino.asr.\(source.rawValue)", qos: .userInitiated)
        self.speakers.kind = source
    }

    func prepare() throws {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw TErr(String(format: L("无法创建语音识别器（%@）"), String(describing: locale.identifier)))
        }
        guard recognizer.isAvailable else {
            throw TErr(String(format: L("语音识别器暂不可用（%@）"), String(describing: locale.identifier)))
        }
        self.recognizer = recognizer
    }

    func ensureConverter(from format: AVAudioFormat) {
        queue.async { [weak self] in
            self?.ensureConverterLocked(from: format)
        }
    }

    func startRecognition() {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.beginRequestLocked()
        }
    }

    func append(pcm: AVAudioPCMBuffer) {
        queue.async { [weak self] in
            self?.appendLocked(pcm: pcm)
        }
    }

    func append(sampleBuffer: CMSampleBuffer) {
        guard let pcm = Self.pcmBuffer(from: sampleBuffer) else { return }
        append(pcm: pcm)
    }

    func stop() {
        // 停止从界面来，主线程上不能等识别队列跑到头：识别回调可能正占着队列。
        // 只翻一个「停止」旗，收尾排到队列上异步做完。
        stopLock.lock()
        stopRequested = true
        stopLock.unlock()
        queue.async { [weak self] in
            self?.finishStopLocked()
        }
    }

    /// 只在识别队列上调用。
    private func finishStopLocked() {
        stopLock.lock()
        let pending = stopRequested
        stopRequested = false
        stopLock.unlock()
        guard pending, !stopped else { return }
        let leftover = lastHypothesis.trimmingCharacters(in: .whitespacesAndNewlines)
        if !leftover.isEmpty, leftover != lastFinalText {
            onHypothesis(source, leftover, true, speakers.speaker)
        }
        stopped = true
        generation += 1
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        converter = nil
        targetFormat = nil
    }

    // MARK: queue-confined

    private func ensureConverterLocked(from format: AVAudioFormat) {
        if converter != nil, targetFormat != nil { return }
        guard format.channelCount > 0, format.sampleRate > 0 else { return }
        guard let mono = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: format.sampleRate,
            channels: 1,
            interleaved: false
        ) else { return }
        targetFormat = mono
        converter = AVAudioConverter(from: format, to: mono)
    }

    private func emitFinalLocked(_ text: String) {
        let leftover = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !leftover.isEmpty, leftover != lastFinalText else { return }
        lastFinalText = leftover
        lastHypothesis = ""
        onHypothesis(source, leftover, true, speakers.speaker)
    }

    private func beginRequestLocked(forceOnDevice: Bool? = nil) {
        guard !stopped, let recognizer else { return }
        beganAt = Date()
        generation += 1
        let gen = generation
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        lastHypothesis = ""
        voicedSinceResult = 0

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        let onDevice = forceOnDevice ?? (preferOnDevice && recognizer.supportsOnDeviceRecognition)
        if onDevice {
            req.requiresOnDeviceRecognition = true
        }
        if #available(macOS 13.0, *) {
            req.addsPunctuation = true
        }
        if !terms.isEmpty { req.contextualStrings = terms }
        request = req
        startedAt = Date()

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            self.queue.async {
                guard self.generation == gen, !self.stopped else { return }
                self.handleRecognitionResult(result, error: error, generation: gen)
            }
        }
    }

    private func rotateRequestLocked() {
        emitFinalLocked(lastHypothesis)
        beginRequestLocked()
    }

    private func handleRecognitionResult(_ result: SFSpeechRecognitionResult?, error: Error?, generation gen: Int) {
        guard !stopped, generation == gen else { return }
        if let result {
            let text = result.bestTranscription.formattedString
            let isFinal = result.isFinal
            lastHypothesis = text
            voicedSinceResult = 0
            if isFinal { lastFinalText = text }
            onHypothesis(source, text, isFinal, speakers.speaker)
            if isFinal {
                lastHypothesis = ""
                beginRequestLocked()
            }
            return
        }
        guard let error else { return }
        let ns = error as NSError
        let cancelled = ns.code == 1 || ns.localizedDescription.lowercased().contains("cancel")
        let retryWithoutOnDevice = request?.requiresOnDeviceRecognition == true
        if cancelled {
            request = nil
            task = nil
            if retryWithoutOnDevice { beginRequestLocked(forceOnDevice: false) }
            return
        }
        emitFinalLocked(lastHypothesis)
        request = nil
        task = nil
        if retryWithoutOnDevice {
            beginRequestLocked(forceOnDevice: false)
        }
    }

    private func appendLocked(pcm: AVAudioPCMBuffer) {
        guard !stopped else { return }
        let buffer = convertedBuffer(pcm)
        noteVoice(buffer)
        let stalled = voicedSinceResult > 6 && Date().timeIntervalSince(startedAt) > 2
        let aged = request != nil && Date().timeIntervalSince(startedAt) > 38
        let crowded = lastHypothesis.count > 380
        if stalled || aged || crowded {
            voicedSinceResult = 0
            rotateRequestLocked()
        }
        if request == nil {
            guard Date().timeIntervalSince(beganAt) >= 0.8 else { return }
            beginRequestLocked()
        }
        guard let request else { return }
        request.append(buffer)
        if let channels = buffer.floatChannelData {
            speakers.push(channels[0], count: Int(buffer.frameLength), sampleRate: buffer.format.sampleRate)
        }
    }

    private func noteVoice(_ pcm: AVAudioPCMBuffer) {
        let count = Int(pcm.frameLength)
        guard count > 0, pcm.format.sampleRate > 0 else { return }
        let rms = Self.bufferRMS(pcm)
        SystemAudioTranslateController.reportLevel(source, rms: rms)
        guard rms > 0.012 else { return }
        voicedSinceResult += Double(count) / pcm.format.sampleRate
    }

    private static func bufferRMS(_ pcm: AVAudioPCMBuffer) -> Float {
        let count = Int(pcm.frameLength)
        guard count > 0 else { return 0 }
        if let channels = pcm.floatChannelData {
            var energy: Float = 0
            let samples = channels[0]
            for i in 0..<count { energy += samples[i] * samples[i] }
            return sqrt(energy / Float(count))
        }
        if let channels = pcm.int16ChannelData {
            var energy: Float = 0
            let samples = channels[0]
            for i in 0..<count {
                let s = Float(samples[i]) / 32768
                energy += s * s
            }
            return sqrt(energy / Float(count))
        }
        return 0
    }

    private func convertedBuffer(_ pcm: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        if converter == nil || targetFormat == nil {
            ensureConverterLocked(from: pcm.format)
        }
        guard let converter, let targetFormat else { return pcm }
        let capacity = AVAudioFrameCount(Double(pcm.frameLength) * targetFormat.sampleRate / max(pcm.format.sampleRate, 1))
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: max(capacity, 1)) else { return pcm }
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
        return pcm
    }

    /// Convert ScreenCaptureKit audio sample buffer → AVAudioPCMBuffer.
    nonisolated static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        guard var asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee else { return nil }
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numSamples > 0 else { return nil }
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(numSamples)) else { return nil }
        pcm.frameLength = AVAudioFrameCount(numSamples)

        var bufferListSizeNeeded = 0
        _ = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &bufferListSizeNeeded,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: nil
        )
        let size = max(bufferListSizeNeeded, MemoryLayout<AudioBufferList>.size)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let audioBufferListPtr = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferListPtr,
            bufferListSize: size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }

        let srcList = UnsafeMutableAudioBufferListPointer(audioBufferListPtr)
        let dstList = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
        let n = min(srcList.count, dstList.count)
        guard n > 0 else { return nil }
        for i in 0..<n {
            guard let src = srcList[i].mData, let dst = dstList[i].mData else { continue }
            let byteCount = Int(min(srcList[i].mDataByteSize, dstList[i].mDataByteSize))
            if byteCount > 0 {
                memcpy(dst, src, byteCount)
            }
        }
        return pcm
    }
}

final class SystemAudioStreamOutput: NSObject, SCStreamOutput {
    let onSample: (CMSampleBuffer) -> Void
    init(onSample: @escaping (CMSampleBuffer) -> Void) { self.onSample = onSample }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        onSample(sampleBuffer)
    }
}

extension AVAudioPCMBuffer {
    /// The engine may reuse a tap's buffer after the callback returns; lanes read it later on their own queue.
    func detachedCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        copy.frameLength = frameLength
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for i in 0..<min(src.count, dst.count) {
            guard let from = src[i].mData, let to = dst[i].mData else { continue }
            memcpy(to, from, Int(min(src[i].mDataByteSize, dst[i].mDataByteSize)))
        }
        return copy
    }
}
