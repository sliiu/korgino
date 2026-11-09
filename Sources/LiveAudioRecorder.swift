import AVFoundation
import CoreMedia
import Foundation

/// 实时字幕的录音：和识别通道并排挂在同一路采集上，把听到的声音写成单声道 m4a。
/// 从 `arm(at:)` 给的那一刻开始写，和 SRT 共用一个零点。采集断档的地方补静音，时间轴不缩。
final class LiveAudioRecorder: LiveAudioSink, @unchecked Sendable {
    let url: URL

    private let queue = DispatchQueue(label: "com.sliiu.Korgino.liverecord", qos: .utility)
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var origin: Date?
    private var written: AVAudioFramePosition = 0
    private var stopped = false
    private var failure: String?

    /// Session recordings live here until the next session starts.
    static let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("Korgino-LiveRecording", isDirectory: true)

    static func discardAll() {
        try? FileManager.default.removeItem(at: folder)
    }

    init(name: String) {
        url = Self.folder.appendingPathComponent("\(name).m4a")
    }

    /// Writes straight into a 会议记录 folder.
    init(url: URL) {
        self.url = url
    }

    func prepare() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
    }

    func ensureConverter(from format: AVAudioFormat) {}

    func startRecognition() {}

    /// Buffers that arrive before this are dropped.
    func arm(at origin: Date) {
        queue.async { [weak self] in self?.origin = origin }
    }

    func append(pcm: AVAudioPCMBuffer) {
        let arrived = Date()
        queue.async { [weak self] in self?.write(pcm, arrived: arrived) }
    }

    func append(sampleBuffer: CMSampleBuffer) {
        guard let pcm = LiveASRLane.pcmBuffer(from: sampleBuffer) else { return }
        append(pcm: pcm)
    }

    func stop() {
        queue.sync {
            stopped = true
            file?.close()
            file = nil
            converter = nil
        }
    }

    /// Whether anything was written. Read after `stop()`.
    var hasAudio: Bool { queue.sync { written > 0 } }

    var error: String? { queue.sync { failure } }

    // MARK: Writing (on `queue`)

    private func write(_ pcm: AVAudioPCMBuffer, arrived: Date) {
        guard !stopped, let origin, arrived >= origin, pcm.frameLength > 0 else { return }
        do {
            if file == nil { try open(for: pcm.format) }
            guard let file else { return }
            let format = file.processingFormat
            if converter?.inputFormat != pcm.format {
                converter = try Self.makeConverter(from: pcm.format, to: format)
            }
            guard let converter, let out = Self.convert(pcm, with: converter, to: format) else { return }
            // Capture stops sending while nothing plays. Fill that span so the file stays on the SRT clock.
            let rate = format.sampleRate
            let due = AVAudioFramePosition(arrived.timeIntervalSince(origin) * rate)
            let gap = due - written - AVAudioFramePosition(out.frameLength)
            if gap > AVAudioFramePosition(rate * 0.5) {
                try writeSilence(gap, format: format, to: file)
            }
            try file.write(from: out)
            written += AVAudioFramePosition(out.frameLength)
        } catch {
            failure = error.localizedDescription
            stopped = true
            file?.close()
            file = nil
        }
    }

    private func open(for input: AVAudioFormat) throws {
        let rate = min(max(input.sampleRate, 8000), 48000)
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
        ]
        if rate >= 32000 { settings[AVEncoderBitRateKey] = 64000 }
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    private static func makeConverter(from input: AVAudioFormat, to output: AVAudioFormat) throws -> AVAudioConverter {
        guard let converter = AVAudioConverter(from: input, to: output) else {
            throw TErr(L("录音格式不受支持"))
        }
        converter.downmix = true
        return converter
    }

    private static func convert(_ pcm: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / max(pcm.format.sampleRate, 1)
        let capacity = AVAudioFrameCount((Double(pcm.frameLength) * ratio).rounded(.up)) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        // `.noDataNow` keeps the converter open for the next buffer; `.endOfStream` would end it.
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return pcm
        }
        guard error == nil, out.frameLength > 0 else { return nil }
        return out
    }

    private func writeSilence(_ frames: AVAudioFramePosition, format: AVAudioFormat, to file: AVAudioFile) throws {
        let chunk = AVAudioFrameCount(format.sampleRate)
        guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return }
        var left = frames
        while left > 0 {
            let n = AVAudioFrameCount(min(left, AVAudioFramePosition(chunk)))
            silence.frameLength = n
            for ch in 0..<Int(format.channelCount) {
                if let data = silence.floatChannelData?[ch] { memset(data, 0, Int(n) * MemoryLayout<Float>.size) }
            }
            try file.write(from: silence)
            written += AVAudioFramePosition(n)
            left -= AVAudioFramePosition(n)
        }
    }
}
