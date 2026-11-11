import AppKit
import AVFoundation
import AVKit
import Speech
import SwiftUI
import UniformTypeIdentifiers

// MARK: - SRT

struct SRTCue: Equatable {
    var start: TimeInterval
    var end: TimeInterval
    var lines: [String]
}

enum SRTDocument {
    static func oneLine(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func stamp(_ time: TimeInterval) -> String {
        let msTotal = Int((max(0, time) * 1000).rounded())
        let ms = msTotal % 1000
        let seconds = (msTotal / 1000) % 60
        let minutes = (msTotal / 60_000) % 60
        let hours = msTotal / 3_600_000
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, seconds, ms)
    }

    static func text(from cues: [SRTCue]) -> String {
        var blocks: [String] = []
        for (index, cue) in cues.enumerated() {
            let end = max(cue.end, cue.start + 0.2)
            let body = cue.lines.map(oneLine).filter { !$0.isEmpty }.joined(separator: "\n")
            guard !body.isEmpty else { continue }
            blocks.append("\(blocks.count + 1)\n\(stamp(cue.start)) --> \(stamp(end))\n\(body)")
            _ = index
        }
        guard !blocks.isEmpty else { return "" }
        return blocks.joined(separator: "\n\n") + "\n"
    }
}

enum MediaClock {
    static func format(_ time: TimeInterval) -> String {
        let total = Int(max(0, time).rounded(.down))
        let seconds = total % 60
        let minutes = (total / 60) % 60
        let hours = total / 3600
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%d:%02d", minutes, seconds)
    }

    static func parse(_ raw: String) -> TimeInterval? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return 0 }
        let parts = text.split(separator: ":")
        func num(_ part: Substring) -> Double? {
            Double(part.replacingOccurrences(of: ",", with: "."))
        }
        switch parts.count {
        case 1:
            return num(parts[0])
        case 2:
            guard let minutes = num(parts[0]), let seconds = num(parts[1]) else { return nil }
            return minutes * 60 + seconds
        case 3:
            guard let hours = num(parts[0]), let minutes = num(parts[1]), let seconds = num(parts[2]) else { return nil }
            return hours * 3600 + minutes * 60 + seconds
        default:
            return nil
        }
    }
}

// MARK: - Drop routing

enum MediaDrop {
    static let extensions: Set<String> = [
        "mp3", "m4a", "aac", "wav", "caf", "aiff", "aif", "flac",
        "mp4", "mov", "m4v", "mpeg", "mpg", "mkv", "webm", "ogg", "wma", "avi"
    ]

    static func looksLikeMedia(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if extensions.contains(ext) { return true }
        guard let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .audiovisualContent) || type.conforms(to: .audio) || type.conforms(to: .movie)
    }

    static func looksLikeDocument(_ url: URL) -> Bool {
        !looksLikeMedia(url) && FileReader.isAccepted(url)
    }

    static func sameFile(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.path == b.standardizedFileURL.path
    }

    @discardableResult
    static func take(_ providers: [NSItemProvider], _ go: @escaping @MainActor (URL) -> Void) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL? = {
                if let url = item as? URL { return url }
                if let data = item as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
                if let path = item as? String { return URL(fileURLWithPath: path) }
                return nil
            }()
            guard let url else { return }
            Task { @MainActor in go(url) }
        }
        return true
    }
}

// MARK: - File transcription

struct MediaPiece: Sendable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
    var speaker: Int
}

enum MediaTranscriber {
    struct Track: Sendable, Identifiable, Hashable {
        var id: Int
        var title: String
    }

    struct Probe: Sendable {
        var duration: TimeInterval
        var tracks: [Track]
        var hasVideo: Bool
    }

    static func probe(url: URL) async throws -> Probe {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw TErr(L("这个文件没有音轨")) }
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        guard duration.isFinite, duration > 0.2 else { throw TErr(L("读不到这段声音的时长")) }
        let listed = tracks.enumerated().map { index, track in
            Track(id: Int(track.trackID), title: String(format: L("音轨 %@"), String(index + 1)))
        }
        let video = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        return Probe(duration: duration, tracks: listed, hasVideo: !video.isEmpty)
    }

    static func transcribe(
        url: URL,
        trackID: Int,
        from start: TimeInterval,
        locale: Locale,
        onDevice: Bool,
        whisper: WhisperASRConfig?,
        language: String?,
        onProgress: @escaping @Sendable (TimeInterval) -> Void,
        onPieces: @escaping @Sendable ([MediaPiece]) -> Void
    ) async throws {
        if whisper == nil {
            try await authorizeSpeech()
        }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let opened = try await openReader(url: url, trackID: trackID, from: start)
        let reader = opened.reader
        let output = opened.output
        let duration = opened.duration
        let terms = AppConfig.shared.asrContextTerms
        let prompt = AppConfig.shared.asrContextPrompt

        var speakers = SpeakerTracker()
        speakers.kind = .system
        var marks: [(time: TimeInterval, speaker: Int)] = []
        var chunk: [AVAudioPCMBuffer] = []
        var floats: [Float] = []
        var chunkStart = start
        let chunkLimit = 28.0
        let chunkQuiet = 20.0

        func emit(pieces: [MediaPiece], at time: TimeInterval) {
            let cut = MediaCutter.cut(tag(pieces, marks: marks))
            if !cut.isEmpty { onPieces(cut) }
            onProgress(time)
        }

        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let pcm = LiveASRLane.pcmBuffer(from: sample) else { continue }
            let rawTime = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            let fileTime = rawTime.isFinite ? rawTime : chunkStart
            if let channels = pcm.floatChannelData {
                speakers.push(channels[0], count: Int(pcm.frameLength), sampleRate: pcm.format.sampleRate)
            }
            marks.append((fileTime, speakers.speaker))
            onProgress(max(fileTime, start))
            if chunk.isEmpty { chunkStart = fileTime }
            chunk.append(pcm)
            if whisper != nil {
                floats.append(contentsOf: monoFloats(pcm))
            }
            let span = fileTime - chunkStart
            if span >= chunkLimit || (span >= chunkQuiet && level(pcm) < quietLevel) {
                try await flush(
                    &chunk, floats: &floats, chunkStart: chunkStart, fileTime: fileTime,
                    locale: locale, onDevice: onDevice, whisper: whisper, language: language,
                    terms: terms, prompt: prompt, emit: emit
                )
                marks.removeAll(keepingCapacity: true)
            }
        }
        try Task.checkCancellation()
        if reader.status == .failed, chunk.isEmpty, floats.isEmpty {
            throw TErr(reader.error?.localizedDescription ?? L("读不出这条音轨"))
        }
        let tail = max(chunkStart, start)
        try await flush(
            &chunk, floats: &floats, chunkStart: chunkStart, fileTime: max(tail, duration),
            locale: locale, onDevice: onDevice, whisper: whisper, language: language,
            terms: terms, prompt: prompt, emit: emit
        )
    }

    struct OpenReader: @unchecked Sendable {
        var reader: AVAssetReader
        var output: AVAssetReaderTrackOutput
        var duration: TimeInterval
    }

    /// 从起点读到结尾，16 kHz 单声道浮点。调用方负责安全作用域。
    static func openReader(url: URL, trackID: Int, from start: TimeInterval) async throws -> OpenReader {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first(where: { Int($0.trackID) == trackID }) ?? tracks.first else {
            throw TErr(L("这个文件没有音轨"))
        }
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        guard duration.isFinite, duration > start + 0.2 else {
            throw TErr(L("起点已经在结尾之后"))
        }
        let reader = try AVAssetReader(asset: asset)
        let begin = CMTime(seconds: max(0, start), preferredTimescale: 600)
        let end = CMTime(seconds: duration, preferredTimescale: 600)
        reader.timeRange = CMTimeRange(start: begin, end: end)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: true,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw TErr(L("读不出这条音轨")) }
        reader.add(output)
        guard reader.startReading() else {
            throw TErr(reader.error?.localizedDescription ?? L("读不出这条音轨"))
        }
        return OpenReader(reader: reader, output: output, duration: duration)
    }

    /// 一块里的均方根音量。低于这个就算停顿。
    static let quietLevel: Float = 0.008

    private static func level(_ pcm: AVAudioPCMBuffer) -> Float {
        let count = Int(pcm.frameLength)
        guard count > 0, let channels = pcm.floatChannelData else { return 1 }
        var sum: Float = 0
        let samples = channels[0]
        for i in 0..<count { sum += samples[i] * samples[i] }
        return (sum / Float(count)).squareRoot()
    }

    private static func flush(
        _ chunk: inout [AVAudioPCMBuffer],
        floats: inout [Float],
        chunkStart: TimeInterval,
        fileTime: TimeInterval,
        locale: Locale,
        onDevice: Bool,
        whisper: WhisperASRConfig?,
        language: String?,
        terms: [String],
        prompt: String?,
        emit: ([MediaPiece], TimeInterval) -> Void
    ) async throws {
        defer {
            chunk.removeAll(keepingCapacity: true)
            floats.removeAll(keepingCapacity: true)
        }
        if let whisper {
            guard !floats.isEmpty else { return }
            let wav = PCM16WAV.data(samples: floats, sampleRate: 16_000)
            let span = max(fileTime - chunkStart, 0.2)
            let cues = try await WhisperASR.transcribeCues(
                wav: wav, config: whisper, language: language, chunkDuration: span, prompt: prompt
            )
            let pieces = cues.map { cue in
                MediaPiece(
                    text: cue.text,
                    start: chunkStart + cue.start,
                    end: chunkStart + cue.end,
                    speaker: 0
                )
            }
            emit(pieces, fileTime)
            return
        }
        guard !chunk.isEmpty else { return }
        let pieces = try await recognizeApple(
            chunk, chunkStart: chunkStart, locale: locale, onDevice: onDevice, terms: terms
        )
        emit(pieces, fileTime)
    }

    private static func authorizeSpeech() async throws {
        let status: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard status == .authorized else { throw TErr(L("没有语音识别权限")) }
    }

    private static func recognizeApple(
        _ buffers: [AVAudioPCMBuffer],
        chunkStart: TimeInterval,
        locale: Locale,
        onDevice: Bool,
        terms: [String]
    ) async throws -> [MediaPiece] {
        do {
            return try await recognizeAppleOnce(buffers, chunkStart: chunkStart, locale: locale, onDevice: onDevice, terms: terms)
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if isNoSpeech(error) { return [] }
            guard onDevice else { throw error }
            return try await recognizeAppleOnce(buffers, chunkStart: chunkStart, locale: locale, onDevice: false, terms: terms)
        }
    }

    private static func recognizeAppleOnce(
        _ buffers: [AVAudioPCMBuffer],
        chunkStart: TimeInterval,
        locale: Locale,
        onDevice: Bool,
        terms: [String]
    ) async throws -> [MediaPiece] {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw TErr(String(format: L("无法创建语音识别器（%@）"), locale.identifier))
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if onDevice, recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        if #available(macOS 13.0, *) { request.addsPunctuation = true }
        if !terms.isEmpty { request.contextualStrings = terms }
        let box = SpeechOnce()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[MediaPiece], Error>) in
            box.task = recognizer.recognitionTask(with: request) { result, error in
                if let result {
                    guard result.isFinal else { return }
                    let pieces = result.bestTranscription.segments.compactMap { seg -> MediaPiece? in
                        let text = seg.substring.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return nil }
                        let start = chunkStart + seg.timestamp
                        let end = start + max(seg.duration, 0.2)
                        return MediaPiece(text: text, start: start, end: end, speaker: 0)
                    }
                    box.finish { cont.resume(returning: pieces) }
                    return
                }
                if let error {
                    let ns = error as NSError
                    let cancelled = ns.domain == NSCocoaErrorDomain && ns.code == NSUserCancelledError
                        || ns.code == 216
                        || ns.localizedDescription.lowercased().contains("cancel")
                    box.finish {
                        if cancelled || Task.isCancelled {
                            cont.resume(throwing: CancellationError())
                        } else if isNoSpeech(error) {
                            cont.resume(returning: [])
                        } else {
                            cont.resume(throwing: error)
                        }
                    }
                }
            }
            for buffer in buffers {
                request.append(buffer)
            }
            request.endAudio()
            }
        } onCancel: {
            box.task?.cancel()
        }
    }

    /// 这一块没有人声（片头音乐、静场）。不算失败，跳过接着识别。
    static func isNoSpeech(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == "kAFAssistantErrorDomain", ns.code == 1110 || ns.code == 1107 { return true }
        return ns.localizedDescription.lowercased().contains("no speech detected")
    }

    private static func tag(_ pieces: [MediaPiece], marks: [(time: TimeInterval, speaker: Int)]) -> [MediaPiece] {
        pieces.map { piece in
            var copy = piece
            let mid = (piece.start + piece.end) / 2
            var speaker = 0
            for mark in marks where mark.time <= mid {
                speaker = mark.speaker
            }
            copy.speaker = speaker
            return copy
        }
    }

    private static func monoFloats(_ pcm: AVAudioPCMBuffer) -> [Float] {
        let count = Int(pcm.frameLength)
        guard count > 0 else { return [] }
        if let channels = pcm.floatChannelData {
            return Array(UnsafeBufferPointer(start: channels[0], count: count))
        }
        if let channels = pcm.int16ChannelData {
            return (0..<count).map { Float(channels[0][$0]) / 32768 }
        }
        return []
    }
}

private final class SpeechOnce: @unchecked Sendable {
    var task: SFSpeechRecognitionTask?
    private var done = false
    private let lock = NSLock()

    func finish(_ body: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        guard first else { return }
        body()
        task?.cancel()
    }
}

enum MediaCutter {
    static func cut(_ pieces: [MediaPiece]) -> [MediaPiece] {
        let pieces = characters(pieces)
        var groups: [[MediaPiece]] = []
        var current: [MediaPiece] = []
        for piece in pieces {
            guard !piece.text.isEmpty else { continue }
            if let last = current.last {
                let gap = piece.start - last.end
                let origin = current.first?.start ?? last.start
                let span = max(0, last.end - origin)
                let speakerBreak = piece.speaker > 0 && last.speaker > 0 && piece.speaker != last.speaker
                let pause = gap >= 0.5 || (gap >= 0.32 && span >= 2)
                if speakerBreak || pause {
                    groups.append(current)
                    current = []
                }
            }
            current.append(piece)
        }
        if !current.isEmpty { groups.append(current) }
        return lead(groups.flatMap(cutGroup))
    }

    private static func characters(_ pieces: [MediaPiece]) -> [MediaPiece] {
        pieces.flatMap(timedCharacters)
    }

    private static func timedCharacters(_ piece: MediaPiece) -> [MediaPiece] {
        let parts = speechAtoms(piece.text)
        guard parts.count > 1 else { return piece.text.isEmpty ? [] : [piece] }
        let span = max(piece.end - piece.start, 0.05)
        let step = span / Double(parts.count)
        return parts.enumerated().map { index, text in
            let start = piece.start + step * Double(index)
            let end = index == parts.count - 1 ? piece.end : start + step
            return MediaPiece(
                text: text,
                start: start,
                end: max(end, start + 0.02),
                speaker: piece.speaker
            )
        }
    }

    private static func speechAtoms(_ text: String) -> [String] {
        var atoms: [String] = []
        var current = ""
        func isSpeech(_ ch: Character) -> Bool {
            CaptionCut.isWide(ch) || ch.isLetter || ch.isNumber
        }
        func close() {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            current = ""
            guard !trimmed.isEmpty else { return }
            if trimmed.contains(where: isSpeech) {
                atoms.append(trimmed)
            } else if !atoms.isEmpty {
                atoms[atoms.count - 1] += trimmed
            } else {
                current = trimmed
            }
        }
        for ch in text {
            if ch.isWhitespace {
                current.append(ch)
                continue
            }
            if CaptionCut.isWide(ch) {
                if current.contains(where: isSpeech) { close() }
                let prefix = current.trimmingCharacters(in: .whitespaces)
                current = prefix + String(ch)
                close()
                continue
            }
            if ch.isLetter || ch.isNumber {
                if current.contains(where: CaptionCut.isWide) { close() }
                current.append(ch)
                continue
            }
            if current.contains(where: isSpeech) || atoms.isEmpty {
                current.append(ch)
            } else {
                atoms[atoms.count - 1].append(ch)
            }
        }
        close()
        return atoms
    }

    private static func lead(_ pieces: [MediaPiece]) -> [MediaPiece] {
        pieces.map { piece in
            var copy = piece
            copy.start = min(max(0, piece.start - 0.2), max(0, piece.end - 0.05))
            return copy
        }
    }

    private static func cutGroup(_ pieces: [MediaPiece]) -> [MediaPiece] {
        var out: [MediaPiece] = []
        var buf: [MediaPiece] = []
        var shown = ""
        func flush() {
            if let joined = join(buf) { out.append(joined) }
            buf.removeAll(keepingCapacity: true)
            shown = ""
        }
        func preview(_ part: MediaPiece) -> String {
            var next = shown
            if !next.isEmpty, let prev = next.last, let first = part.text.first, needsSpace(prev, first) {
                next.append(" ")
            }
            next += part.text
            return next
        }
        for piece in pieces where !piece.text.isEmpty {
            let parts = CaptionBudget.textWidth(piece.text) > CaptionBudget.lineWidth ? slice(piece) : [piece]
            for part in parts {
                let bare = CaptionCut.letterCount(part.text.trimmingCharacters(in: .whitespacesAndNewlines)) == 0
                if !buf.isEmpty, !bare {
                    let next = preview(part)
                    let span = part.end - (buf.first?.start ?? part.start)
                    if CaptionBudget.textWidth(next) > CaptionBudget.lineWidth || span > CaptionBudget.maxDuration {
                        flush()
                    }
                }
                if !shown.isEmpty, let prev = shown.last, let first = part.text.first, needsSpace(prev, first) {
                    shown.append(" ")
                }
                shown += part.text
                buf.append(part)
                let span = (buf.last?.end ?? 0) - (buf.first?.start ?? 0)
                if sentenceEnded(part.text) {
                    flush()
                } else if clauseEnded(part.text), span >= 2.2 || CaptionBudget.textWidth(shown) >= CaptionBudget.lineWidth * 0.82 {
                    flush()
                }
            }
        }
        flush()
        return out
    }

    private static func slice(_ piece: MediaPiece) -> [MediaPiece] {
        let text = piece.text
        guard !text.isEmpty else { return [] }
        let span = max(piece.end - piece.start, 0.05)
        let step = span / Double(text.count)
        var timed: [(ch: Character, start: TimeInterval, end: TimeInterval)] = []
        for (offset, ch) in text.enumerated() {
            let start = piece.start + step * Double(offset)
            timed.append((ch, start, start + step))
        }
        let full = String(timed.map(\.ch))
        var cursor = 0
        var out: [MediaPiece] = []
        for part in CaptionCut.split(full, finishAll: true).ready {
            let lower = cursor
            let upper = min(cursor + part.count, timed.count)
            cursor = upper
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard lower < upper, CaptionCut.letterCount(trimmed) >= 2 else { continue }
            let range = timed[lower..<upper]
            guard let first = range.first, let last = range.last else { continue }
            out.append(MediaPiece(
                text: trimmed,
                start: first.start,
                end: max(last.end, first.start + 0.2),
                speaker: piece.speaker
            ))
        }
        return out.isEmpty ? [piece] : out
    }

    private static func join(_ pieces: [MediaPiece]) -> MediaPiece? {
        guard let first = pieces.first, let last = pieces.last else { return nil }
        var text = ""
        for (index, piece) in pieces.enumerated() {
            if index > 0, let prev = text.last, let next = piece.text.first,
               needsSpace(prev, next) {
                text.append(" ")
            }
            text += piece.text
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CaptionCut.letterCount(trimmed) >= 2 else { return nil }
        return MediaPiece(
            text: trimmed,
            start: first.start,
            end: max(last.end, first.start + 0.2),
            speaker: majoritySpeaker(pieces.map(\.speaker))
        )
    }

    private static func needsSpace(_ prev: Character, _ next: Character) -> Bool {
        (spaced(prev) || prev.isNumber || ",.!?;:".contains(prev))
            && (spaced(next) || next.isNumber)
    }

    private static func sentenceEnded(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let ch = trimmed.last else { return false }
        if ch == "." {
            if trimmed.count >= 2 {
                let prev = trimmed[trimmed.index(trimmed.endIndex, offsetBy: -2)]
                if prev.isNumber { return false }
            }
            return true
        }
        return "。！？!?…．".contains(ch)
    }

    private static func clauseEnded(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let ch = trimmed.last else { return false }
        if ch == "." {
            if trimmed.count >= 2 {
                let prev = trimmed[trimmed.index(trimmed.endIndex, offsetBy: -2)]
                if prev.isNumber { return false }
            }
            return true
        }
        return "。！？!?…．，,、；;：:".contains(ch)
    }

    /// 词与词之间要空格的文字。中文、日文的字挨着写。
    private static func spaced(_ ch: Character) -> Bool {
        guard ch.isLetter, let scalar = ch.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F:
            return false
        default:
            return true
        }
    }

    private static func majoritySpeaker(_ speakers: [Int]) -> Int {
        var counts: [Int: Int] = [:]
        for speaker in speakers where speaker > 0 {
            counts[speaker, default: 0] += 1
        }
        return counts.max { $0.value < $1.value }?.key ?? 0
    }
}

// MARK: - Jobs

struct MediaSegment: Identifiable, Equatable {
    let id = UUID()
    var source: String
    var translations: [String: String] = [:]
    var errors: [String: String] = [:]
    var loadingIDs: Set<String> = []
    var speaker = 0
    var laneID = UUID()
    var start: TimeInterval = 0
    var end: TimeInterval = 0
    var maskRanges: [NSRange] = []

    var loading: Bool { !loadingIDs.isEmpty }
}

enum MediaPhase: Equatable {
    case waiting
    case running
    case waitingForTranslation
    case finished
}

struct MediaJob: Identifiable {
    let id = UUID()
    var url: URL
    var duration: TimeInterval
    var tracks: [MediaTranscriber.Track]
    var hasVideo: Bool
    var trackID: Int
    var startText: String
    var phase: MediaPhase = .waiting
    var recognizedTime: TimeInterval = 0
    var segments: [MediaSegment] = []
    var status = ""
    var savedURL: URL?
    /// 系统语音模型的下载进度。没在下载时为空。
    var downloadFraction: Double?
    /// 这一轮开始识别的时刻和起点，用来估剩余时间。
    var startedAt: Date?
    var startPosition: TimeInterval = 0
    /// 每次开始换一个，旧一轮的回调认得出自己已经过时。
    var run = UUID()
    /// The first lane's engine; the recognition language is clamped against it.
    var engineID = "apple"
    var localeID = "en-US"
    var lanes: [RecognitionLane] = []
    var savedURLs: [URL] = []
    /// How far each lane has recognized in this run.
    var laneTimes: [UUID: TimeInterval] = [:]
    /// Lanes of this run that have not finished recognizing.
    var pendingLanes: Set<UUID> = []
    /// 识别完了，正在用声纹把每一段重新分人。
    var relabeling = false
    /// 这一份换的模型。跟着这一份走，不写回设置（docs/adr/0023、0053）。
    var modelOverrides: ModelOverrides = [:]

    var name: String { url.lastPathComponent }
    var translatedCount: Int {
        segments.filter { !$0.loading && $0.errors.isEmpty }.count
    }
    var stillTranslating: Bool { segments.contains { $0.loading } }
    var savedName: String? { savedURLs.first?.lastPathComponent ?? savedURL?.lastPathComponent }
    var failedCount: Int {
        segments.filter { !$0.loading && !$0.errors.isEmpty }.count
    }

    var fraction: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, recognizedTime / duration))
    }

    /// 识别了至少 3 秒、走过 2% 之后才估。
    var remaining: TimeInterval? {
        guard phase == .running, downloadFraction == nil, let startedAt else { return nil }
        let elapsed = Date().timeIntervalSince(startedAt)
        let done = recognizedTime - startPosition
        let total = duration - startPosition
        guard elapsed >= 3, total > 0, done / total >= 0.02 else { return nil }
        return max(0, (duration - recognizedTime) / (done / elapsed))
    }
}

@MainActor
final class MediaCaptionsController: ObservableObject {
    static let shared = MediaCaptionsController()

    @Published var jobs: [MediaJob] = []
    @Published var selectedID: UUID?
    @Published var notice: String?
    @Published var isDropTargeted = false
    @Published var engineID: String = UserDefaults.standard.string(forKey: "media.asrEngine") ?? "apple" {
        didSet { UserDefaults.standard.set(engineID, forKey: "media.asrEngine") }
    }
    @Published var localeID: String = UserDefaults.standard.string(forKey: "media.asrLocale") ?? "en-US" {
        didSet { UserDefaults.standard.set(localeID, forKey: "media.asrLocale") }
    }
    /// The language a new binding starts with: the last one picked.
    @Published var target: TargetLanguage = MediaCaptionsController.savedTarget() {
        didSet { UserDefaults.standard.set(target.rawValue, forKey: "media.target") }
    }
    @Published var concurrentLimit: Int = MediaCaptionsController.savedConcurrentLimit() {
        didSet {
            let clamped = min(10, max(1, concurrentLimit))
            if clamped != concurrentLimit {
                concurrentLimit = clamped
                return
            }
            UserDefaults.standard.set(clamped, forKey: Self.concurrentKey)
        }
    }

    private static let concurrentKey = "media.concurrentLimit"

    private var work: [UUID: Task<Void, Never>] = [:]
    private var noteTasks: [UUID: Task<Void, Never>] = [:]
    private var laneWork: [UUID: [Task<Void, Never>]] = [:]
    private struct MediaTranslateKey: Hashable {
        var segment: UUID
        var provider: String
    }
    private var translateTasks: [MediaTranslateKey: Task<Void, Never>] = [:]

    var needsFlushBeforeQuit: Bool {
        jobs.contains { $0.phase == .running || $0.phase == .waitingForTranslation }
    }

    func show() {
        MainWindowController.shared.show(page: .media)
    }

    func relocalize() {}

    func add(_ url: URL) {
        show()
        if MediaDrop.looksLikeDocument(url) {
            FileTranslateController.shared.loadSource(url: url, autoStart: true)
            return
        }
        if let existing = jobs.first(where: { MediaDrop.sameFile($0.url, url) }) {
            selectedID = existing.id
            notice = L("这份已经在列表里")
            return
        }
        notice = nil
        Task {
            do {
                let probe = try await MediaTranscriber.probe(url: url)
                self.place(url, probe: probe)
            } catch {
                self.notice = error.localizedDescription
            }
        }
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.audio, .movie, .video, .mpeg4Movie, .quickTimeMovie, .mp3]
        panel.message = L("选择要识别的音视频")
        panel.prompt = L("选择")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        add(url)
    }

    func start(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        guard jobs[index].phase == .waiting || jobs[index].phase == .finished else { return }
        let busy = jobs.filter { $0.phase == .running || $0.phase == .waitingForTranslation }.count
        guard busy < concurrentLimit else {
            notice = String(format: L("同时最多 %@ 份"), String(concurrentLimit))
            return
        }
        if jobs[index].lanes.isEmpty {
            jobs[index].lanes = [RecognitionLane(asrID: jobs[index].engineID, bindings: defaultBindings())]
        }
        guard let start = MediaClock.parse(jobs[index].startText) else {
            notice = L("起点时间读不懂")
            return
        }
        let duration = jobs[index].duration
        if !Pro.unlocked && duration > Pro.freeMediaSeconds {
            notice = L("免费版一份不超过 15 分钟")
            return
        }
        guard start >= 0, start < duration - 0.2 else {
            notice = L("起点已经在结尾之后")
            return
        }
        var laneRuns: [MediaLaneRun] = []
        for lane in jobs[index].lanes {
            let engine = resolvedEngine(lane.asrID)
            var whisper: WhisperASRConfig?
            if !AppConfig.shared.isSystemASR(engine) {
                do {
                    whisper = try AppConfig.shared.asrWhisperConfig(selection: engine)
                } catch {
                    notice = error.localizedDescription
                    return
                }
            }
            laneRuns.append(MediaLaneRun(laneID: lane.id, engineID: engine, whisper: whisper, bindings: lane.translatingKeys))
        }
        let locale = clampedLocale(engine: laneRuns[0].engineID, locale: jobs[index].localeID)
        for key in Array(translateTasks.keys) where jobs[index].segments.contains(where: { $0.id == key.segment }) {
            translateTasks[key]?.cancel()
            translateTasks[key] = nil
        }
        notice = nil
        let run = UUID()
        jobs[index].run = run
        jobs[index].phase = .running
        jobs[index].status = L("正在准备")
        jobs[index].recognizedTime = start
        jobs[index].startPosition = start
        jobs[index].startedAt = nil
        jobs[index].downloadFraction = nil
        jobs[index].segments = []
        noteTasks[id]?.cancel()
        noteTasks[id] = nil
        for lane in jobs[index].lanes {
            noteTasks[lane.id]?.cancel()
            noteTasks[lane.id] = nil
        }
        for laneIndex in jobs[index].lanes.indices {
            jobs[index].lanes[laneIndex].marks = SpeakerMarkBook()
            var slot = SessionNoteSlot()
            slot.generation = jobs[index].lanes[laneIndex].note.generation + 1
            jobs[index].lanes[laneIndex].note = slot
        }
        jobs[index].savedURL = nil
        jobs[index].savedURLs = []
        jobs[index].engineID = laneRuns[0].engineID
        jobs[index].localeID = locale
        jobs[index].laneTimes = [:]
        jobs[index].pendingLanes = Set(laneRuns.map(\.laneID))
        let plan = MediaRun(
            id: id,
            run: run,
            url: jobs[index].url,
            trackID: jobs[index].trackID,
            start: start,
            language: ASRLanguage(id: locale),
            lanes: laneRuns
        )
        work[id]?.cancel()
        work[id] = Task { [weak self] in
            guard let self else { return }
            var analyzerLocale: Locale?
            if #available(macOS 26.0, *),
               plan.lanes.contains(where: { AppConfig.shared.isAnalyzerASR($0.engineID) }) {
                guard let locale = await self.prepareAnalyzer(plan) else { return }
                analyzerLocale = locale
            }
            guard !Task.isCancelled, self.isCurrent(plan) else { return }
            for lane in plan.lanes {
                let mode: MediaEngineMode
                if #available(macOS 26.0, *),
                   AppConfig.shared.isAnalyzerASR(lane.engineID), let analyzerLocale {
                    mode = .analyzer(analyzerLocale)
                } else if let whisper = lane.whisper {
                    mode = .whisper(whisper)
                } else {
                    mode = .legacy
                }
                self.launch(plan, lane: lane, mode: mode)
            }
        }
    }

    private enum MediaEngineMode {
        case analyzer(Locale)
        case legacy
        case whisper(WhisperASRConfig)
    }

    private struct MediaLaneRun {
        var laneID: UUID
        var engineID: String
        var whisper: WhisperASRConfig?
        var bindings: [String]
    }

    private struct MediaRun {
        var id: UUID
        var run: UUID
        var url: URL
        var trackID: Int
        var start: TimeInterval
        var language: ASRLanguage
        var lanes: [MediaLaneRun]
    }

    private func isCurrent(_ plan: MediaRun) -> Bool {
        guard let job = jobs.first(where: { $0.id == plan.id }) else { return false }
        return job.run == plan.run && job.phase == .running
    }

    @available(macOS 26.0, *)
    private func prepareAnalyzer(_ plan: MediaRun) async -> Locale? {
        switch await MediaAnalyzerASR.readiness(for: plan.language.locale) {
        case .ready(let locale):
            return locale
        case .unsupported:
            update(plan.id) {
                $0.phase = $0.segments.isEmpty ? .waiting : .finished
                $0.status = L("这种语言没有语音分析")
            }
            notice = L("这种语言没有语音分析")
            return nil
        case .needsModel(let locale):
            guard isCurrent(plan) else { return nil }
            update(plan.id) {
                $0.downloadFraction = 0
                $0.status = L("正在下载语音模型")
            }
            do {
                let id = plan.id
                try await MediaAnalyzerASR.installModel(locale) { fraction in
                    Task { @MainActor in
                        MediaCaptionsController.shared.noteDownload(id, fraction: fraction)
                    }
                }
                update(plan.id) { $0.downloadFraction = nil }
                return locale
            } catch {
                if Task.isCancelled { return nil }
                update(plan.id) {
                    $0.downloadFraction = nil
                    $0.phase = .waiting
                    $0.status = L("语音模型没下载成功")
                }
                notice = error.localizedDescription
                return nil
            }
        }
    }

    func noteDownload(_ id: UUID, fraction: Double) {
        guard let job = jobs.first(where: { $0.id == id }), job.phase == .running, job.downloadFraction != nil else { return }
        let clamped = min(1, max(0, fraction))
        guard abs((job.downloadFraction ?? 0) - clamped) >= 0.01 || clamped >= 1 else { return }
        update(id) {
            $0.downloadFraction = clamped
            $0.status = String(format: L("正在下载语音模型 %@%%"), String(Int(clamped * 100)))
        }
    }

    private func launch(_ plan: MediaRun, lane: MediaLaneRun, mode: MediaEngineMode) {
        let id = plan.id
        let run = plan.run
        let laneID = lane.laneID
        update(id) {
            $0.status = L("正在识别")
            if $0.startedAt == nil { $0.startedAt = Date() }
        }
        let bindings = lane.bindings
        let appleSource = plan.language.appleSource
        let onProgress: @Sendable (TimeInterval) -> Void = { time in
            Task { @MainActor in
                MediaCaptionsController.shared.noteProgress(id, run: run, lane: laneID, time: time)
            }
        }
        let onPieces: @Sendable ([MediaPiece]) -> Void = { pieces in
            Task { @MainActor in
                MediaCaptionsController.shared.absorb(
                    id, run: run, pieces,
                    bindings: bindings,
                    source: appleSource,
                    laneID: laneID
                )
            }
        }
        let url = plan.url
        let trackID = plan.trackID
        let start = plan.start
        let language = plan.language
        let task = Task.detached {
            do {
                switch mode {
                case .analyzer(let locale):
                    guard #available(macOS 26.0, *) else { return }
                    try await MediaAnalyzerASR.transcribe(
                        url: url, trackID: trackID, from: start, locale: locale,
                        onProgress: onProgress, onPieces: onPieces
                    )
                case .legacy, .whisper:
                    var whisper: WhisperASRConfig?
                    if case .whisper(let config) = mode { whisper = config }
                    try await MediaTranscriber.transcribe(
                        url: url,
                        trackID: trackID,
                        from: start,
                        locale: language.locale,
                        onDevice: AppConfig.shared.asrAppleOnDevice,
                        whisper: whisper,
                        language: language.whisperCode,
                        onProgress: onProgress,
                        onPieces: onPieces
                    )
                }
                await MainActor.run { MediaCaptionsController.shared.recognitionFinished(id, run: run, lane: laneID) }
            } catch is CancellationError {
                await MainActor.run { MediaCaptionsController.shared.recognitionFinished(id, run: run, lane: laneID) }
            } catch {
                await MainActor.run {
                    MediaCaptionsController.shared.recognitionFailed(id, run: run, lane: laneID, message: error.localizedDescription)
                }
            }
        }
        laneWork[id, default: []].append(task)
    }

    private func cancelWork(_ id: UUID) {
        work[id]?.cancel()
        work[id] = nil
        for task in laneWork[id] ?? [] { task.cancel() }
        laneWork[id] = nil
    }

    func stop(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }), job.phase == .running else { return }
        cancelWork(id)
        if job.segments.isEmpty {
            update(id) {
                $0.phase = .waiting
                $0.status = L("已停止")
                $0.downloadFraction = nil
                $0.run = UUID()
            }
            return
        }
        update(id) {
            $0.phase = .waitingForTranslation
            $0.status = L("正在等翻译")
            $0.downloadFraction = nil
            $0.run = UUID()
        }
        settle(id)
    }

    /// 翻译失败的那一句单独再译。成了就重新落盘。
    func retry(_ jobID: UUID, segment segID: UUID) {
        guard let job = jobs.first(where: { $0.id == jobID }),
              let seg = job.segments.first(where: { $0.id == segID }),
              !seg.loading else { return }
        let failed = Array(seg.errors.keys)
        guard !failed.isEmpty else { return }
        updateSegment(jobID, segID) { item in
            for id in failed {
                item.errors.removeValue(forKey: id)
                item.loadingIDs.insert(id)
            }
        }
        if job.phase == .finished {
            update(jobID) {
                $0.phase = .waitingForTranslation
                $0.status = L("正在等翻译")
            }
        }
        for id in failed {
            translate(
                jobID, segment: segID, text: seg.source,
                binding: id,
                source: ASRLanguage(id: job.localeID).appleSource
            )
        }
    }

    func revealSaved(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        let urls = job.savedURLs.isEmpty ? [job.savedURL].compactMap { $0 } : job.savedURLs
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func saveCopy(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        let lanes = Self.exportLanes(for: job)
        guard !lanes.isEmpty,
              let choice = CaptionExport.choose(lanes: lanes, suggestedName: job.name, start: job.url.deletingLastPathComponent()) else { return }
        let base = job.url.deletingPathExtension().lastPathComponent
        let files = CaptionExport.files(base: base, lanes: lanes, rule: choice.rule, sourceLanes: choice.sourceLanes)
        guard !files.isEmpty else { return }
        do {
            let urls = try CaptionExport.write(files, to: choice.folder)
            update(id) {
                $0.savedURLs = urls
                $0.savedURL = urls.first
                $0.status = urls.first?.lastPathComponent ?? ""
            }
        } catch {
            notice = String(format: L("保存失败：%@"), error.localizedDescription)
        }
    }

    func clear(_ id: UUID) {
        if let job = jobs.first(where: { $0.id == id }) {
            for lane in job.lanes {
                noteTasks[lane.id]?.cancel()
                noteTasks[lane.id] = nil
            }
        }
        noteTasks[id]?.cancel()
        noteTasks[id] = nil
        cancelWork(id)
        if let job = jobs.first(where: { $0.id == id }) {
            for key in Array(translateTasks.keys) where job.segments.contains(where: { $0.id == key.segment }) {
                translateTasks[key]?.cancel()
                translateTasks[key] = nil
            }
        }
        try? FileManager.default.removeItem(at: Self.scratchFolder(id))
        jobs.removeAll { $0.id == id }
        if selectedID == id { selectedID = jobs.last?.id }
    }

    func flushForQuit() async {
        let running = jobs.filter { $0.phase == .running }.map(\.id)
        for id in running { stop(id) }
        let deadline = Date().addingTimeInterval(180)
        while needsFlushBeforeQuit, Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        for job in jobs where job.phase == .waitingForTranslation {
            for seg in job.segments where seg.loading {
                updateSegment(job.id, seg.id) { item in
                    for id in item.loadingIDs where item.translations[id] == nil {
                        item.errors[id] = L("翻译未完成")
                    }
                    item.loadingIDs = []
                }
            }
            settle(job.id)
        }
    }

    private func place(_ url: URL, probe: MediaTranscriber.Probe) {
        if let existing = jobs.first(where: { MediaDrop.sameFile($0.url, url) }) {
            selectedID = existing.id
            notice = L("这份已经在列表里")
            return
        }
        guard let track = probe.tracks.first else {
            notice = L("这个文件没有音轨")
            return
        }
        let engine = AppConfig.shared.resolvedMediaAsr()
        var job = MediaJob(
            url: url,
            duration: probe.duration,
            tracks: probe.tracks,
            hasVideo: probe.hasVideo,
            trackID: track.id,
            startText: "0:00:00"
        )
        job.engineID = engine
        job.localeID = clampedLocale(engine: engine, locale: localeID)
        job.lanes = [RecognitionLane(asrID: engine, bindings: defaultBindings())]
        job.status = probe.tracks.count > 1 ? L("选一条音轨，再开始") : L("还没开始")
        jobs.append(job)
        selectedID = job.id
        notice = nil
    }

    /// The row shows the slowest lane.
    func noteProgress(_ id: UUID, run: UUID, lane: UUID, time: TimeInterval) {
        guard let job = jobs.first(where: { $0.id == id }), job.phase == .running, job.run == run else { return }
        let previous = job.laneTimes[lane] ?? job.startPosition
        if time - previous < 0.3, time < job.duration - 0.4 { return }
        update(id) { job in
            job.laneTimes[lane] = max(previous, time)
            let slowest = job.lanes.map { job.laneTimes[$0.id] ?? job.startPosition }.min() ?? time
            job.recognizedTime = max(job.recognizedTime, slowest)
        }
    }

    func absorb(
        _ id: UUID,
        run: UUID,
        _ pieces: [MediaPiece],
        bindings: [String],
        source: String?,
        laneID: UUID
    ) {
        guard let job = jobs.first(where: { $0.id == id }), job.run == run,
              job.phase == .running || job.phase == .waitingForTranslation else { return }
        let fresh = pieces.map { piece in
            MediaSegment(
                source: piece.text,
                loadingIDs: Set(bindings),
                speaker: piece.speaker,
                laneID: laneID,
                start: piece.start,
                end: piece.end
            )
        }
        guard !fresh.isEmpty else { return }
        update(id) { $0.segments.append(contentsOf: fresh) }
        for seg in fresh {
            for binding in bindings {
                translate(id, segment: seg.id, text: seg.source, binding: binding, source: source)
            }
        }
    }

    private func translate(
        _ jobID: UUID,
        segment segID: UUID,
        text: String,
        binding translator: String,
        source: String?
    ) {
        guard let binding = LaneBinding(key: translator), let engine = resolveTarget(binding.translateID, job: jobID) else {
            updateSegment(jobID, segID) {
                $0.loadingIDs.remove(translator)
                $0.errors[translator] = L("请先选择翻译服务")
            }
            settle(jobID)
            return
        }
        let plan = Lang.plan(text, target: binding.target, source: source)
        let key = MediaTranslateKey(segment: segID, provider: translator)
        translateTasks[key]?.cancel()
        translateTasks[key] = Task { [weak self] in
            let outcome: Result<Translator.LiveSend, Error>
            do {
                let sent = try await Background.run {
                    try await Translator.translateLive(text, target: engine, plan: plan)
                }
                outcome = .success(sent)
            } catch {
                outcome = .failure(error)
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.updateSegment(jobID, segID) { seg in
                    seg.loadingIDs.remove(translator)
                    switch outcome {
                    case .success(let sent):
                        seg.translations[translator] = sent.text
                        seg.maskRanges = sent.maskRanges
                        seg.errors.removeValue(forKey: translator)
                    case .failure(let error):
                        seg.errors[translator] = error.localizedDescription
                    }
                }
                self.translateTasks[key] = nil
                self.settle(jobID)
            }
        }
    }

    func recognitionFinished(_ id: UUID, run: UUID, lane: UUID) {
        guard let job = jobs.first(where: { $0.id == id }), job.run == run else { return }
        guard job.phase == .running || job.phase == .waitingForTranslation else { return }
        update(id) {
            $0.pendingLanes.remove(lane)
            $0.laneTimes[lane] = $0.duration
        }
        guard jobs.first(where: { $0.id == id })?.pendingLanes.isEmpty ?? true else { return }
        update(id) {
            $0.phase = .waitingForTranslation
            if $0.status != L("正在等翻译") { $0.status = L("正在等翻译") }
        }
        // 声纹按整份重分，不跟着每一块识别跑。没有模型就保留识别时按音色给的号。
        if VoiceprintModel.shared.isReady {
            relabel(id, run: run)
        } else {
            settle(id)
        }
    }

    /// 识别结束后用声纹把每一路的段重新编号。这一轮识别时改过的名字清掉。
    /// 跟会议记录里「按声音重新分说话人」同一套：没分出来就留着原来的号。
    private func relabel(_ id: UUID, run: UUID) {
        guard let job = jobs.first(where: { $0.id == id }), job.run == run else { return }
        let lanes = job.lanes.map { lane -> (id: UUID, spans: [(start: TimeInterval, end: TimeInterval)]) in
            let spans = job.segments.filter { $0.laneID == lane.id }.map { (start: $0.start, end: $0.end) }
            return (lane.id, spans)
        }
        guard lanes.contains(where: { !$0.spans.isEmpty }) else {
            settle(id)
            return
        }
        let url = job.url
        let trackID = job.trackID
        update(id) { $0.relabeling = true }
        Task { @MainActor in
            var labels: [UUID: [Int?]] = [:]
            for lane in lanes where !lane.spans.isEmpty {
                labels[lane.id] = await VoiceTagger.label(
                    segments: lane.spans, audioURL: url, trackID: trackID
                )
            }
            guard let current = self.jobs.first(where: { $0.id == id }), current.run == run else { return }
            self.update(id) { job in
                job.relabeling = false
                for lane in lanes {
                    guard let numbers = labels[lane.id], numbers.count == lane.spans.count,
                          numbers.contains(where: { $0 != nil }) else { continue }
                    var index = 0
                    var last = 0
                    for i in job.segments.indices where job.segments[i].laneID == lane.id {
                        let number = numbers[index] ?? last
                        job.segments[i].speaker = number
                        if number > 0 { last = number }
                        index += 1
                    }
                    if let li = job.lanes.firstIndex(where: { $0.id == lane.id }) {
                        job.lanes[li].marks = SpeakerMarkBook()
                    }
                }
            }
            self.settle(id)
        }
    }

    func recognitionFailed(_ id: UUID, run: UUID, lane: UUID, message: String) {
        guard let job = jobs.first(where: { $0.id == id }), job.run == run else { return }
        update(id) { $0.pendingLanes.remove(lane) }
        if !(jobs.first(where: { $0.id == id })?.pendingLanes.isEmpty ?? true) {
            notice = message
            return
        }
        update(id) {
            if $0.segments.isEmpty {
                $0.phase = .finished
                $0.status = message
            } else {
                $0.phase = .waitingForTranslation
                $0.status = L("正在等翻译")
            }
        }
        if jobs.first(where: { $0.id == id })?.phase == .waitingForTranslation {
            settle(id)
        } else {
            notice = message
        }
    }

    private func settle(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        guard job.phase == .waitingForTranslation, !job.stillTranslating else { return }
        writeScratch(id)
    }

    private static func scratchFolder(_ id: UUID) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Korgino", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func writeScratch(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        let lanes = Self.exportLanes(for: job)
        let files = CaptionExport.files(
            base: job.url.deletingPathExtension().lastPathComponent,
            lanes: lanes,
            rule: CaptionExportRule.remembered,
            sourceLanes: CaptionExport.rememberedSourceLanes(lanes)
        )
        guard !files.isEmpty else {
            let silent = job.segments.isEmpty
            let message = silent
                ? String(format: L("没听到人声（识别语言：%@）。换一种识别语言或识别引擎再试"), ASRLanguage(id: job.localeID == "system" ? Locale.current.identifier : job.localeID).title)
                : L("没有可写入的字幕")
            update(id) {
                $0.phase = .finished
                $0.status = message
            }
            if silent { notice = message }
            return
        }
        let folder = Self.scratchFolder(id)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if let existing = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                for url in existing { try? FileManager.default.removeItem(at: url) }
            }
            _ = try CaptionExport.write(files, to: folder)
            update(id) {
                $0.phase = .finished
                $0.status = L("可以导出")
            }
        } catch {
            update(id) {
                $0.phase = .finished
                $0.status = String(format: L("保存失败：%@"), error.localizedDescription)
            }
        }
    }

    private static func exportLanes(for job: MediaJob) -> [CaptionExport.Lane] {
        job.lanes.compactMap { lane in
            let asr = AppConfig.shared.mediaASRChoices().first { $0.id == lane.asrID }?.name ?? lane.asrID
            let mine = job.lanes.count <= 1 ? job.segments : job.segments.filter { $0.laneID == lane.id }
            let cues = mine.compactMap { seg -> CaptionExport.Cue? in
                let source = SRTDocument.oneLine(seg.source)
                guard !source.isEmpty else { return nil }
                var translations: [String: String] = [:]
                for key in lane.translatingKeys where !seg.loadingIDs.contains(key) && seg.errors[key] == nil {
                    let text = seg.translations[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !text.isEmpty { translations[key] = SRTDocument.oneLine(text) }
                }
                return CaptionExport.Cue(
                    start: seg.start,
                    end: seg.end,
                    source: source,
                    mark: markToken(job, lane: lane, speaker: seg.speaker),
                    translations: translations
                )
            }
            guard !cues.isEmpty else { return nil }
            return CaptionExport.Lane(key: "media|\(lane.asrID)", title: asr, fileStem: asr, bindings: lane.bindings, cues: cues)
        }
    }

    func hasNoteMaterial(_ job: MediaJob, _ laneID: UUID) -> Bool {
        guard let lane = job.lanes.first(where: { $0.id == laneID }) else { return false }
        let binding = Self.noteBinding(lane)
        return job.segments.contains { seg in
            seg.laneID == lane.id && !seg.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !Self.noteWaiting(seg, binding: binding)
        }
    }

    func canWriteNote(_ job: MediaJob, _ laneID: UUID) -> Bool {
        guard let lane = job.lanes.first(where: { $0.id == laneID }) else { return false }
        return !lane.note.writing && hasNoteMaterial(job, laneID)
    }

    func writeNote(_ id: UUID, _ laneID: UUID) {
        selectedID = id
        guard let job = jobs.first(where: { $0.id == id }),
              job.lanes.contains(where: { $0.id == laneID }) else { return }
        let brief = Self.noteBrief(job, laneID)
        guard brief.hasCue else { return }
        noteTasks[laneID]?.cancel()
        let generation = (job.lanes.first { $0.id == laneID }?.note.generation ?? 0) + 1
        setNote(id, laneID) {
            $0.generation = generation
            $0.open = true
            $0.writing = true
            $0.error = ""
        }
        noteTasks[laneID] = Task { @MainActor in
            let result = await SessionNoteWriter.write(brief)
            guard let current = self.jobs.first(where: { $0.id == id }),
                  let lane = current.lanes.first(where: { $0.id == laneID }),
                  lane.note.generation == generation else { return }
            self.setNote(id, laneID) {
                $0.writing = false
                switch result {
                case .success(let page):
                    $0.error = ""
                    $0.page = page
                case .failure(let failure):
                    $0.error = failure.message
                }
            }
        }
    }

    func closeNote(_ id: UUID, _ laneID: UUID) {
        noteTasks[laneID]?.cancel()
        noteTasks[laneID] = nil
        setNote(id, laneID) {
            $0.generation += 1
            $0.open = false
            $0.writing = false
            $0.error = ""
        }
    }

    func clearMediaLane(_ id: UUID, _ laneID: UUID) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        let ids = Set(job.segments.filter { $0.laneID == laneID }.map(\.id))
        for key in Array(translateTasks.keys) where ids.contains(key.segment) {
            translateTasks[key]?.cancel()
            translateTasks[key] = nil
        }
        noteTasks[laneID]?.cancel()
        noteTasks[laneID] = nil
        update(id) { job in
            job.segments.removeAll { $0.laneID == laneID }
            guard let index = job.lanes.firstIndex(where: { $0.id == laneID }) else { return }
            job.lanes[index].marks = SpeakerMarkBook()
            var slot = SessionNoteSlot()
            slot.generation = job.lanes[index].note.generation + 1
            job.lanes[index].note = slot
        }
    }

    /// 批量删除：只动点名的段，说话人标记和笔记都留着。
    func deleteMediaSegments(_ id: UUID, _ ids: Set<UUID>) {
        guard !ids.isEmpty, jobs.contains(where: { $0.id == id }) else { return }
        for key in Array(translateTasks.keys) where ids.contains(key.segment) {
            translateTasks[key]?.cancel()
            translateTasks[key] = nil
        }
        update(id) { job in
            job.segments.removeAll { ids.contains($0.id) }
        }
    }

    private func setNote(_ id: UUID, _ laneID: UUID, _ change: (inout SessionNoteSlot) -> Void) {
        update(id) { job in
            guard let index = job.lanes.firstIndex(where: { $0.id == laneID }) else { return }
            change(&job.lanes[index].note)
        }
    }

    private static func noteBinding(_ lane: RecognitionLane) -> SessionNoteBinding {
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

    private static func noteWaiting(_ seg: MediaSegment, binding: SessionNoteBinding) -> Bool {
        !binding.isSource && seg.loadingIDs.contains(binding.key)
    }

    private static func noteBrief(_ job: MediaJob, _ laneID: UUID) -> SessionNoteBrief {
        guard let lane = job.lanes.first(where: { $0.id == laneID }) else { return .empty }
        let binding = noteBinding(lane)
        let cues = job.segments.filter { $0.laneID == lane.id }.map { seg in
            let translation: String? = {
                guard !binding.isSource else { return nil }
                let raw = seg.translations[binding.key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return raw.isEmpty ? nil : raw
            }()
            return SessionNoteCue(
                id: seg.id.uuidString,
                mark: markToken(job, lane: lane, speaker: seg.speaker) ?? "",
                source: seg.source,
                translation: translation,
                waiting: noteWaiting(seg, binding: binding)
            )
        }
        return SessionNote.brief(cues, binding: binding)
    }

    static func markToken(_ job: MediaJob, lane: RecognitionLane?, speaker: Int) -> String? {
        guard let lane else { return nil }
        return lane.marks.token(speaker: speaker, fallback: "[\(L("说话人")) \(speaker)]")
    }

    private func update(_ id: UUID, _ body: (inout MediaJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        body(&jobs[index])
    }

    private func updateSegment(_ jobID: UUID, _ segID: UUID, _ body: (inout MediaSegment) -> Void) {
        update(jobID) { job in
            guard let index = job.segments.firstIndex(where: { $0.id == segID }) else { return }
            body(&job.segments[index])
        }
    }

    func speakerRows(_ job: MediaJob, _ laneID: UUID) -> [(id: Int, token: String)] {
        guard let lane = job.lanes.first(where: { $0.id == laneID }) else { return [] }
        var ids: [Int] = []
        for seg in job.segments where seg.laneID == laneID && seg.speaker > 0 && !ids.contains(seg.speaker) {
            ids.append(seg.speaker)
        }
        return ids.compactMap { id in
            guard !lane.marks.removed.contains(id),
                  let token = lane.marks.token(speaker: id, fallback: "[\(id)]") else { return nil }
            return (id, token)
        }
    }

    func renameSpeaker(_ jobID: UUID, _ laneID: UUID, _ speaker: Int, to name: String) {
        update(jobID) { job in
            guard let index = job.lanes.firstIndex(where: { $0.id == laneID }) else { return }
            job.lanes[index].marks.rename(speaker: speaker, to: name)
        }
    }

    func setSpeakerVoice(_ jobID: UUID, _ laneID: UUID, _ speaker: Int, to voice: String?) {
        update(jobID) { job in
            guard let index = job.lanes.firstIndex(where: { $0.id == laneID }) else { return }
            job.lanes[index].marks.setVoice(speaker, to: voice)
        }
    }

    func speakerVoice(_ job: MediaJob, _ laneID: UUID, _ speaker: Int) -> String? {
        job.lanes.first { $0.id == laneID }?.marks.voice(for: speaker)
    }

    func deleteSpeaker(_ jobID: UUID, _ laneID: UUID, _ speaker: Int) {
        guard let job = jobs.first(where: { $0.id == jobID }), job.phase != .running else { return }
        update(jobID) { job in
            guard let index = job.lanes.firstIndex(where: { $0.id == laneID }) else { return }
            job.lanes[index].marks.remove(speaker: speaker)
        }
    }

    func deleteAllSpeakers(_ jobID: UUID, _ laneID: UUID) {
        guard let job = jobs.first(where: { $0.id == jobID }), job.phase != .running else { return }
        let ids = Set(speakerRows(job, laneID).map(\.id))
        update(jobID) { job in
            guard let index = job.lanes.firstIndex(where: { $0.id == laneID }) else { return }
            job.lanes[index].marks.removeAll(ids)
        }
    }

    private func resolvedEngine(_ id: String) -> String {
        let choices = AppConfig.shared.mediaASRChoices()
        if choices.contains(where: { $0.id == id }) { return id }
        return choices.first?.id ?? "apple"
    }

    private func clampedLocale(engine: String, locale: String) -> String {
        let available = ASRLanguage.available(apple: AppConfig.shared.isSystemASR(engine)).map(\.id)
        if available.contains(locale) { return locale }
        if available.contains("en-US") { return "en-US" }
        return available.first ?? "en-US"
    }

    private func canConfigure(_ id: UUID) -> Bool {
        guard let job = jobs.first(where: { $0.id == id }) else { return false }
        return job.phase == .waiting || job.phase == .finished
    }

    func defaultBindings() -> [LaneBinding] {
        let list = AppConfig.shared.translateTargets(.media).map { LaneBinding(translateID: $0.id, target: target) }
        return list.isEmpty ? [.source] : list
    }

    private func editLane(_ id: UUID, _ laneID: UUID, _ change: (inout RecognitionLane) -> Void) {
        guard canConfigure(id) else { return }
        update(id) { job in
            guard let index = job.lanes.firstIndex(where: { $0.id == laneID }) else { return }
            change(&job.lanes[index])
            job.engineID = job.lanes.first?.asrID ?? job.engineID
        }
    }

    func addMediaLane(_ id: UUID, asrID: String) {
        guard Pro.unlocked, canConfigure(id) else { return }
        let bindings = defaultBindings()
        update(id) { job in
            guard !job.lanes.contains(where: { $0.asrID == asrID }) else { return }
            job.lanes.append(RecognitionLane(asrID: asrID, bindings: bindings))
        }
    }

    func removeMediaLane(_ id: UUID, _ laneID: UUID) {
        guard canConfigure(id), let job = jobs.first(where: { $0.id == id }), job.lanes.count > 1 else { return }
        let wasFirst = job.lanes.first?.id == laneID
        let ids = Set(job.segments.filter { $0.laneID == laneID }.map(\.id))
        for key in Array(translateTasks.keys) where ids.contains(key.segment) {
            translateTasks[key]?.cancel()
            translateTasks[key] = nil
        }
        noteTasks[laneID]?.cancel()
        noteTasks[laneID] = nil
        update(id) { job in
            job.lanes.removeAll { $0.id == laneID }
            job.segments.removeAll { $0.laneID == laneID }
            job.engineID = job.lanes.first?.asrID ?? job.engineID
            if wasFirst, let engine = job.lanes.first?.asrID {
                job.localeID = clampedLocale(engine: engine, locale: job.localeID)
            }
        }
    }

    func setLaneEngine(_ id: UUID, _ laneID: UUID, _ engine: String) {
        guard let job = jobs.first(where: { $0.id == id }), !job.lanes.contains(where: { $0.asrID == engine }) else { return }
        editLane(id, laneID) { $0.asrID = engine }
        if job.lanes.first?.id == laneID {
            let locale = clampedLocale(engine: engine, locale: job.localeID)
            update(id) { $0.localeID = locale }
        }
    }

    func addMediaBinding(_ id: UUID, _ laneID: UUID) {
        guard Pro.unlocked, let lane = jobs.first(where: { $0.id == id })?.lanes.first(where: { $0.id == laneID }) else { return }
        let used = Set(lane.bindingKeys)
        let ids = AppConfig.shared.translateTargets(.media).map(\.id) + AppConfig.shared.catalogTargets().map(\.id)
        guard let next = ids.first(where: { !used.contains(LaneBinding(translateID: $0, target: target).key) }) else { return }
        editLane(id, laneID) { $0.addBinding(LaneBinding(translateID: next, target: target)) }
    }

    func removeMediaBinding(_ id: UUID, _ laneID: UUID, _ key: String) {
        editLane(id, laneID) { $0.removeBinding(key) }
    }

    func setMediaBindingService(_ id: UUID, _ laneID: UUID, _ key: String, _ translateID: String) {
        guard let old = LaneBinding(key: key) else { return }
        let next = LaneBinding(translateID: translateID, target: old.isSource ? target : old.target)
        editLane(id, laneID) { $0.replaceBinding(key, with: next) }
    }

    func setMediaBindingTarget(_ id: UUID, _ laneID: UUID, _ key: String, _ lang: TargetLanguage) {
        guard let old = LaneBinding(key: key), !old.isSource else { return }
        target = lang
        editLane(id, laneID) { $0.replaceBinding(key, with: LaneBinding(translateID: old.translateID, target: lang)) }
    }

    func setJobLocale(_ id: UUID, _ locale: String) {
        guard canConfigure(id), let job = jobs.first(where: { $0.id == id }) else { return }
        let clamped = clampedLocale(engine: job.engineID, locale: locale)
        update(id) { $0.localeID = clamped }
    }

    private static func savedConcurrentLimit() -> Int {
        guard UserDefaults.standard.object(forKey: concurrentKey) != nil else { return 5 }
        return min(10, max(1, UserDefaults.standard.integer(forKey: concurrentKey)))
    }

    private func resolveTarget(_ id: String, job jobID: UUID) -> TranslateTarget? {
        let overrides = jobs.first { $0.id == jobID }?.modelOverrides ?? [:]
        return AppConfig.shared.catalogTargets().first { $0.id == id }?.applying(overrides)
    }

    /// 这一条翻译用的 AI 配置（设置里的那份）。不是 AI 时为空。
    func bindingProfile(_ binding: LaneBinding) -> AIProfile? {
        guard !binding.isSource, !binding.isInterp else { return nil }
        return AppConfig.shared.catalogTargets().first { $0.id == binding.translateID }?.aiProfile
    }

    func modelOverride(_ jobID: UUID, for profile: AIProfile) -> Binding<String?> {
        Binding(
            get: { [weak self] in self?.jobs.first { $0.id == jobID }?.modelOverrides[profile.id] },
            set: { [weak self] m in self?.update(jobID) { $0.modelOverrides.setModel(m, for: profile) } }
        )
    }

    private static func savedTarget() -> TargetLanguage {
        TargetLanguage.storedCaptionTarget(key: "media.target")
    }
}

// MARK: - Window

struct MediaCaptionsView: View {
    @ObservedObject var model: MediaCaptionsController
    @ObservedObject private var pro = Pro.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.jobs.isEmpty {
                fileBar
            }
            if let notice = model.notice, !notice.isEmpty {
                Label(notice, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !model.jobs.isEmpty {
                queue
            }
            stage
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.windowFill)
        .onDrop(of: [UTType.fileURL], isTargeted: Binding(
            get: { model.isDropTargeted },
            set: { model.isDropTargeted = $0 }
        )) { providers in
            MediaDrop.take(providers) { model.add($0) }
        }
        .onAppear { _ = pro.purchased }
    }

    private var fileBar: some View {
        HStack {
            Spacer(minLength: 0)
            Button(L("添加文件…")) { model.chooseFile() }
                .controlSize(.small)
        }
    }

    // MARK: Queue

    private var queue: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.jobs.enumerated()), id: \.element.id) { index, job in
                if index > 0 {
                    Divider().padding(.leading, 28)
                }
                jobRow(job)
            }
        }
        .card()
    }

    private func jobRow(_ job: MediaJob) -> some View {
        let selected = model.selectedID == job.id
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(phaseColor(job.phase))
                    .frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(job.name)
                            .font(Theme.TypeScale.body).fontWeight(selected ? .semibold : .regular)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(progressLine(job))
                            .font(Theme.TypeScale.caption).monospacedDigit()
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    progressTrack(job)
                    Text(metaLine(job))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { model.selectedID = job.id }
                rowActions(job)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(selected ? Color.accentColor.opacity(0.06) : Color.clear)
    }

    private func progressTrack(_ job: MediaJob) -> some View {
        let downloading = job.downloadFraction
        let value = downloading ?? job.fraction
        return GeometryReader { geo in
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.08))
            Capsule(style: .continuous)
                .fill(trackColor(job, downloading: downloading != nil))
                .frame(width: max(0, geo.size.width * CGFloat(value)))
                .animation(.linear(duration: 0.25), value: value)
        }
        .frame(height: 3)
    }

    private func trackColor(_ job: MediaJob, downloading: Bool) -> Color {
        if downloading { return .orange }
        return job.phase == .running ? Color.accentColor : Color.primary.opacity(0.28)
    }

    private func rowActions(_ job: MediaJob) -> some View {
        HStack(spacing: 0) {
            switch job.phase {
            case .waiting:
                EmptyView()
            case .running:
                IconButton(icon: .stopFill, help: L("停止"), size: 11) {
                    model.stop(job.id)
                }
            case .waitingForTranslation:
                Image(systemName: "hourglass")
                    .font(Theme.TypeScale.caption).fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 22)
                    .help(L("正在等翻译"))
            case .finished:
                if job.savedURL != nil {
                    IconButton(icon: .folder, help: L("在访达中显示"), size: 11) {
                        model.revealSaved(job.id)
                    }
                }
                if !job.segments.isEmpty {
                    IconButton(icon: .save, help: L("导出"), size: 11) {
                        model.saveCopy(job.id)
                    }
                }
            }
            if job.phase != .waitingForTranslation && job.phase != .running {
                IconButton(icon: .trash, help: L("移除"), size: 11) {
                    model.clear(job.id)
                }
            }
        }
    }

    // MARK: Stage

    @ViewBuilder
    private var stage: some View {
        Group {
            if let job = model.jobs.first(where: { $0.id == model.selectedID }) {
                MediaStage(model: model, job: job)
                    .id(job.id)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "film")
                        .font(Theme.TypeScale.display)
                        .foregroundStyle(.tertiary)
                    Text(model.jobs.isEmpty ? L("拖入音视频") : L("选一份查看字幕"))
                        .font(Theme.TypeScale.body).fontWeight(.medium)
                    if model.jobs.isEmpty {
                        Text(String(format: L("可以放进多份，同时识别 %@ 份"), String(model.concurrentLimit)))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Button(L("选择文件…")) { model.chooseFile() }
                            .controlSize(.small)
                            .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 1.5)
                .opacity(model.isDropTargeted ? 1 : 0)
                .allowsHitTesting(false)
        }
    }

    // MARK: Text

    private func phaseColor(_ phase: MediaPhase) -> Color {
        switch phase {
        case .waiting: return Color.secondary.opacity(0.35)
        case .running: return Color.accentColor
        case .waitingForTranslation: return Theme.attention
        case .finished: return Color.secondary.opacity(0.7)
        }
    }

    private func progressLine(_ job: MediaJob) -> String {
        if let downloading = job.downloadFraction {
            return "\(Int(downloading * 100))%"
        }
        let times = "\(MediaClock.format(job.recognizedTime)) / \(MediaClock.format(job.duration))"
        guard job.phase == .running else { return times }
        var parts = ["\(Int(job.fraction * 100))%", times]
        if let remaining = job.remaining {
            parts.append(Self.remainingText(remaining))
        }
        return parts.joined(separator: " · ")
    }

    static func remainingText(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return String(format: L("约剩 %@ 秒"), String(max(1, Int(seconds.rounded()))))
        }
        return String(format: L("约剩 %@ 分钟"), String(Int((seconds / 60).rounded(.up))))
    }

    private func metaLine(_ job: MediaJob) -> String {
        var parts = [String(format: L("译好 %@ 段"), String(job.translatedCount))]
        if job.failedCount > 0 {
            parts.append(String(format: L("%@ 段没译成"), String(job.failedCount)))
        }
        if job.relabeling {
            parts.append(L("正在按声音分说话人…"))
        } else if !job.status.isEmpty {
            parts.append(job.status)
        }
        return parts.joined(separator: " · ")
    }

}

/// 选中的那一份：预览播放器和字幕列表。点一句跳到那里，播放时高亮当前句，识别时自动跟着最新一句。
private struct MediaStage: View {
    @ObservedObject var model: MediaCaptionsController
    @ObservedObject private var config = AppConfig.shared
    @ObservedObject private var pro = Pro.shared
    var job: MediaJob
    @StateObject private var player: MediaPlayerBridge
    /// A finished film shows its captions first. Settings come back only when asked for, to re-run.
    @State private var adjusting = false
    @State private var clearing: UUID?
    /// 哪个识别路开着批量删除。
    @State private var batching: UUID?

    init(model: MediaCaptionsController, job: MediaJob) {
        self.model = model
        self.job = job
        _player = StateObject(wrappedValue: MediaPlayerBridge(url: job.url))
    }

    private var setupOpen: Bool { job.phase == .waiting || (job.phase == .finished && adjusting) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(job.name)
                    .font(Theme.TypeScale.label).fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(String(format: L("%@ 段"), String(job.segments.count)))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            MediaPreview(player: player.player, showsVideo: job.hasVideo)
                .frame(height: job.hasVideo ? 216 : 52)
                .padding(.horizontal, 12)
            if setupOpen {
                // Settings can outgrow the stage: scroll them together with capped lanes.
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if job.phase == .finished { summaryRow }
                        filmSetup
                        ForEach(job.lanes) { lane in
                            lanePanel(lane, fill: false)
                        }
                        if Pro.unlocked {
                            addLaneMenu
                                .padding(.horizontal, 14)
                        }
                    }
                    .padding(.bottom, 8)
                }
            } else {
                // Captions first: lanes share the height under the player, no outer scroll.
                summaryRow
                ForEach(job.lanes) { lane in
                    lanePanel(lane, fill: true)
                }
            }
        }
        .padding(.bottom, setupOpen ? 0 : 8)
        .onDisappear { player.pause() }
        .onChange(of: job.phase) { _, _ in adjusting = false }
        .confirmationDialog(
            L("清空这一路的字幕？"),
            isPresented: Binding(get: { clearing != nil }, set: { if !$0 { clearing = nil } }),
            presenting: clearing
        ) { laneID in
            Button(L("清空"), role: .destructive) { model.clearMediaLane(job.id, laneID) }
        } message: { _ in
            Text(L("字幕、标记和笔记会一起清掉，别的路不动。"))
        }
    }

    private var summaryRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 8)
            if job.phase == .finished {
                Button(adjusting ? L("收起设置") : L("调整设置")) { adjusting.toggle() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help(L("换语言、起点、引擎或翻译后重新识别"))
            }
        }
        .padding(.horizontal, 14)
    }

    private var summary: String {
        var parts = [ASRLanguage(id: job.localeID).title]
        for lane in job.lanes {
            parts.append(([engineTitle(lane)] + lane.bindings.map(LaneBindingNames.title)).joined(separator: " · "))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: "  ·  ")
    }

    private var filmSetup: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    fieldLabel(L("语言"))
                    let languages = ASRLanguage.available(apple: AppConfig.shared.isSystemASR(job.engineID))
                    MenuChip(
                        title: languages.first { $0.id == localeBinding.wrappedValue }?.title ?? localeBinding.wrappedValue,
                        options: languages.map(\.id),
                        label: { id in languages.first { $0.id == id }?.title ?? id },
                        isSelected: { $0 == localeBinding.wrappedValue },
                        select: { localeBinding.wrappedValue = $0 }
                    )
                    .frame(maxWidth: 220, alignment: .leading)
                }
                GridRow {
                    fieldLabel(L("起点"))
                    HStack(spacing: 8) {
                        TextField("0:00:00", text: startBinding)
                            .textFieldStyle(.plain)
                            .font(Theme.TypeScale.label.monospaced())
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .well(radius: 6)
                            .frame(width: 92)
                        Text(String(format: L("总长 %@"), MediaClock.format(job.duration)))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                if job.tracks.count > 1 {
                    GridRow {
                        fieldLabel(L("音轨"))
                        MenuChip(
                            title: job.tracks.first { $0.id == trackBinding.wrappedValue }?.title ?? "",
                            options: job.tracks.map(\.id),
                            label: { id in job.tracks.first { $0.id == id }?.title ?? String(id) },
                            isSelected: { $0 == trackBinding.wrappedValue },
                            select: { trackBinding.wrappedValue = $0 }
                        )
                        .frame(maxWidth: 220, alignment: .leading)
                    }
                }
            }
            .controlSize(.small)
            HStack {
                if overFreeDuration {
                    Text(L("免费版一份不超过 15 分钟"))
                        .font(Theme.TypeScale.caption)
                        .foregroundStyle(Theme.attention)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Button {
                    model.start(job.id)
                } label: {
                    Label(job.phase == .finished ? L("重新识别") : L("开始识别"), systemImage: "waveform")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .keyboardShortcut(.defaultAction)
                .disabled(overFreeDuration)
            }
        }
        .padding(.horizontal, 14)
    }

    private var addLaneMenu: some View {
        let taken = Set(job.lanes.map(\.asrID))
        let choices = config.mediaASRChoices().filter { !taken.contains($0.id) }
        return Menu {
            ForEach(choices) { choice in
                Button(choice.name) { model.addMediaLane(job.id, asrID: choice.id) }
            }
        } label: {
            Label(L("再加一路识别"), systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .controlSize(.small)
        .fixedSize()
        .disabled(choices.isEmpty)
    }

    private func lanePanel(_ lane: RecognitionLane, fill: Bool) -> some View {
        let segs = job.segments.filter { $0.laneID == lane.id }.sorted { $0.start < $1.start }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(engineTitle(lane))
                    .font(Theme.TypeScale.labelMedium)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if !segs.isEmpty {
                    Text(String(format: L("%@ 段"), String(segs.count)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Button(L("笔记")) { model.writeNote(job.id, lane.id) }
                    .buttonStyle(.borderless)
                    .disabled(!model.canWriteNote(job, lane.id))
                    .help(L("用这一路已经切好的段"))
                Button(L("批量")) { batching = lane.id }
                    .buttonStyle(.borderless)
                    .disabled(segs.isEmpty)
                    .help(L("按说话人、时段或逐条挑要删的段"))
                    .popover(isPresented: Binding(get: { batching == lane.id }, set: { if !$0 { batching = nil } }), arrowEdge: .bottom) {
                        CaptionBatchSheet(cues: batchCues(lane, segs)) { ids in
                            model.deleteMediaSegments(job.id, ids)
                        }
                    }
                Button(L("清空")) { clearing = lane.id }
                    .buttonStyle(.borderless)
                    .disabled(segs.isEmpty)
                if setupOpen, job.lanes.count > 1 {
                    IconButton(systemImage: "minus.circle", help: L("移除这一路识别")) {
                        model.removeMediaLane(job.id, lane.id)
                    }
                }
            }
            if setupOpen {
                laneSettings(lane)
                SpeakerMarkList(
                    rows: model.speakerRows(job, lane.id),
                    canDelete: true,
                    onRename: { model.renameSpeaker(job.id, lane.id, $0, to: $1) },
                    onDelete: { model.deleteSpeaker(job.id, lane.id, $0) },
                    onDeleteAll: { model.deleteAllSpeakers(job.id, lane.id) },
                    voices: SpeakerVoice.choices(language: job.localeID),
                    voiceID: { model.speakerVoice(job, lane.id, $0) },
                    onVoice: { model.setSpeakerVoice(job.id, lane.id, $0, to: $1) }
                )
            }
            if lane.note.open {
                SessionNoteCard(
                    page: lane.note.page,
                    writing: lane.note.writing,
                    error: lane.note.error,
                    onClose: { model.closeNote(job.id, lane.id) }
                )
            }
            laneCaptions(lane, segs, fill: fill)
        }
        .padding(8)
        .frame(maxHeight: fill ? .infinity : nil, alignment: .top)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.wellFill)
        }
        .padding(.horizontal, 12)
    }

    private func laneCaptions(_ lane: RecognitionLane, _ segs: [MediaSegment], fill: Bool) -> some View {
        let active = player.playing ? activeID(in: segs, at: player.time) : nil
        var hasher = Hasher()
        for seg in segs {
            hasher.combine(seg.id)
            hasher.combine(seg.source)
            hasher.combine(seg.translations)
            hasher.combine(seg.errors)
            hasher.combine(seg.loading)
        }
        let running = job.phase == .running
        return LaneCaptionScroller(
            noteOpen: lane.note.open,
            token: hasher.finalize(),
            hasLines: !segs.isEmpty,
            pinToBottom: running,
            maxHeight: fill ? nil : 420,
            focusID: running ? nil : active
        ) {
            if segs.isEmpty {
                Text(emptyText)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
            }
            ForEach(segs) { seg in
                let keys = lane.translatingKeys
                MediaCueRow(
                    seg: seg,
                    lanes: keys,
                    names: Dictionary(uniqueKeysWithValues: keys.map { ($0, LaneBindingNames.title(key: $0)) }),
                    mark: MediaCaptionsController.markToken(job, lane: lane, speaker: seg.speaker) ?? "",
                    speaker: seg.speaker,
                    sourceLanguage: job.localeID,
                    voiceID: model.speakerVoice(job, lane.id, seg.speaker),
                    onRename: { model.renameSpeaker(job.id, lane.id, seg.speaker, to: $0) },
                    onVoice: { model.setSpeakerVoice(job.id, lane.id, seg.speaker, to: $0) },
                    active: seg.id == active
                )
                .equatable()
                .id(seg.id)
                .contentShape(Rectangle())
                .onTapGesture { player.seek(to: seg.start) }
                .overlay(alignment: .bottomTrailing) {
                    if seg.errors.values.contains(where: { !$0.isEmpty }), !seg.loading {
                        Button(L("重试")) { model.retry(job.id, segment: seg.id) }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .padding(.trailing, 14)
                            .padding(.bottom, 8)
                    }
                }
            }
        }
    }

    private func laneSettings(_ lane: RecognitionLane) -> some View {
        let taken = Set(job.lanes.filter { $0.id != lane.id }.map(\.asrID))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                fieldLabel(L("识别"))
                let choices = config.mediaASRChoices().filter { !taken.contains($0.id) }
                MenuChip(
                    title: choices.first { $0.id == lane.asrID }?.name ?? lane.asrID,
                    options: choices.map(\.id),
                    label: { id in choices.first { $0.id == id }?.name ?? id },
                    isSelected: { $0 == lane.asrID },
                    select: { model.setLaneEngine(job.id, lane.id, $0) }
                )
                .frame(maxWidth: 220, alignment: .leading)
            }
            ForEach(Array(lane.bindings.enumerated()), id: \.element.key) { index, binding in
                HStack(spacing: 8) {
                    if index == 0 { fieldLabel(L("翻译")) } else { Color.clear.frame(width: 48, height: 1) }
                    let services = [LaneBinding.sourceID] + config.catalogTargets().map(\.id)
                    MenuChip(
                        title: binding.translateID == LaneBinding.sourceID
                            ? L("不翻译")
                            : LaneBindingNames.service(binding.translateID),
                        options: services,
                        label: { id in id == LaneBinding.sourceID ? L("不翻译") : LaneBindingNames.service(id) },
                        isSelected: { $0 == binding.translateID },
                        select: { model.setMediaBindingService(job.id, lane.id, binding.key, $0) }
                    )
                    .frame(maxWidth: 220, alignment: .leading)
                    if let p = model.bindingProfile(binding) {
                        ModelOverrideMenu(profile: p, override: model.modelOverride(job.id, for: p), maxWidth: 130)
                    }
                    if binding.isSource {
                        Text(L("只出原文"))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(width: 120, alignment: .leading)
                    } else {
                        MenuChip(
                            title: binding.target.shortTitle,
                            options: TargetLanguage.specific,
                            label: { $0.shortTitle },
                            isSelected: { $0 == binding.target },
                            select: { model.setMediaBindingTarget(job.id, lane.id, binding.key, $0) }
                        )
                        .frame(width: 120, alignment: .leading)
                    }
                    Spacer(minLength: 0)
                    let removable = lane.bindings.count > 1 || !binding.isSource
                    IconButton(systemImage: "minus.circle", help: L("移除这条翻译")) {
                        model.removeMediaBinding(job.id, lane.id, binding.key)
                    }
                    .disabled(!removable)
                    .opacity(removable ? 1 : 0)
                }
            }
            if Pro.unlocked {
                HStack(spacing: 8) {
                    Color.clear.frame(width: 48, height: 1)
                    Button {
                        model.addMediaBinding(job.id, lane.id)
                    } label: {
                        Label(L("加翻译"), systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .controlSize(.small)
    }

    private func engineTitle(_ lane: RecognitionLane) -> String {
        config.mediaASRChoices().first { $0.id == lane.asrID }?.name ?? lane.asrID
    }

    private func batchCues(_ lane: RecognitionLane, _ segs: [MediaSegment]) -> [CaptionBatchCue] {
        segs.map { seg in
            CaptionBatchCue(
                id: seg.id,
                start: seg.start,
                end: seg.end,
                speaker: seg.speaker,
                mark: MediaCaptionsController.markToken(job, lane: lane, speaker: seg.speaker) ?? "",
                source: SRTDocument.oneLine(seg.source)
            )
        }
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: 48, alignment: .leading)
    }

    private var overFreeDuration: Bool {
        let _ = pro.purchased
        let _ = pro.trialEnd
        #if KORGI_DEV
        let _ = pro.devUnlocked
        #endif
        return !Pro.unlocked && job.duration > Pro.freeMediaSeconds
    }

    private var localeBinding: Binding<String> {
        Binding(
            get: { model.jobs.first { $0.id == job.id }?.localeID ?? job.localeID },
            set: { model.setJobLocale(job.id, $0) }
        )
    }

    private var startBinding: Binding<String> {
        Binding(
            get: { model.jobs.first { $0.id == job.id }?.startText ?? job.startText },
            set: { new in
                guard let index = model.jobs.firstIndex(where: { $0.id == job.id }),
                      model.jobs[index].phase == .waiting || model.jobs[index].phase == .finished else { return }
                model.jobs[index].startText = new
            }
        )
    }

    private var trackBinding: Binding<Int> {
        Binding(
            get: { model.jobs.first { $0.id == job.id }?.trackID ?? job.trackID },
            set: { new in
                guard let index = model.jobs.firstIndex(where: { $0.id == job.id }),
                      model.jobs[index].phase == .waiting || model.jobs[index].phase == .finished else { return }
                model.jobs[index].trackID = new
            }
        )
    }

    private var emptyText: String {
        switch job.phase {
        case .waiting: return L("开始后，字幕会出现在这里")
        case .running: return L("正在听，听到人声就会出字幕")
        default: return job.status.isEmpty ? L("还没有切出段") : job.status
        }
    }

    private func activeID(in segs: [MediaSegment], at time: TimeInterval) -> UUID? {
        var lo = 0
        var hi = segs.count - 1
        var hit: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if segs[mid].start <= time {
                hit = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        guard let hit, time <= segs[hit].end + 0.3 else { return nil }
        return segs[hit].id
    }
}

private struct MediaCueRow: View, Equatable {
    var seg: MediaSegment
    var lanes: [String]
    var names: [String: String]
    var mark: String
    var speaker: Int
    var sourceLanguage: String?
    /// 这一位指定的声音。空的用默认。
    var voiceID: String?
    var onRename: ((String) -> Void)?
    var onVoice: ((String?) -> Void)?
    var active: Bool

    static func == (a: MediaCueRow, b: MediaCueRow) -> Bool {
        a.active == b.active && a.mark == b.mark && a.lanes == b.lanes && a.seg.id == b.seg.id
            && a.sourceLanguage == b.sourceLanguage && a.voiceID == b.voiceID
            && a.seg.loading == b.seg.loading && a.seg.translations == b.seg.translations
            && a.seg.errors == b.seg.errors && a.seg.source == b.seg.source
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(SRTDocument.stamp(seg.start))
                .font(Theme.TypeScale.caption.monospaced())
                .foregroundStyle(active ? Color.accentColor : Color.secondary.opacity(0.6))
                .frame(width: 78, alignment: .trailing)
                .padding(.top, 2)
                .help(String(format: L("%@ → %@"), SRTDocument.stamp(seg.start), SRTDocument.stamp(seg.end)))
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if !mark.isEmpty {
                        SpeakerChipButton(
                            speaker: speaker,
                            token: mark,
                            canDelete: false,
                            onRename: { onRename?($0) },
                            onDelete: {},
                            voices: SpeakerVoice.choices(language: sourceLanguage),
                            voiceID: voiceID,
                            onVoice: { onVoice?($0) }
                        )
                        .padding(.top, 1)
                    }
                    highlightedSource(seg.source, ranges: seg.maskRanges)
                        .font(Theme.TypeScale.label)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !seg.source.isEmpty {
                        SpeakButton(text: seg.source, language: sourceLanguage, help: L("朗读原文"), tag: "media.\(seg.id).source", voiceID: voiceID)
                    }
                }
                ForEach(lanes, id: \.self) { id in
                    if lanes.count > 1, let name = names[id] {
                        Text(name)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 2)
                    }
                    if seg.loadingIDs.contains(id), seg.translations[id] == nil, seg.errors[id] == nil {
                        Text(L("翻译中…"))
                            .font(Theme.TypeScale.reading)
                            .foregroundStyle(.tertiary)
                    } else if let error = seg.errors[id] {
                        ErrorLine(text: error, lineLimit: 2)
                            .padding(.trailing, 56)
                    } else if let translation = seg.translations[id], !translation.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(translation)
                                .font(Theme.TypeScale.reading)
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                            SpeakButton(
                                text: translation,
                                language: LaneBinding(key: id)?.target.appleCode,
                                tag: "media.\(seg.id).\(id)",
                                voiceID: voiceID
                            )
                        }
                    }
                }
            }
            // The panel's width is the only limit here. CaptionBudget.lineWidth is the live-caption window's
            // line length; borrowing it capped this column well short of the panel and left the rest empty.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(active ? Color.accentColor.opacity(0.1) : Color.clear)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: 2)
                .opacity(active ? 1 : 0)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 0.5)
                .padding(.leading, 104)
        }
    }
}

/// 预览用的播放器。持有文件的访问权，报告播放位置。
@MainActor
final class MediaPlayerBridge: ObservableObject {
    let player: AVPlayer
    @Published private(set) var time: TimeInterval = 0
    @Published private(set) var playing = false
    private let url: URL
    private let accessed: Bool
    nonisolated(unsafe) private var timeObserver: Any?
    nonisolated(unsafe) private var rateObserver: NSKeyValueObservation?

    init(url: URL) {
        self.url = url
        accessed = url.startAccessingSecurityScopedResource()
        player = AVPlayer(url: url)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] now in
            MainActor.assumeIsolated {
                guard let self, now.isNumeric else { return }
                self.time = now.seconds
            }
        }
        rateObserver = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let on = player.timeControlStatus != .paused
            Task { @MainActor in self?.playing = on }
        }
    }

    func seek(to seconds: TimeInterval) {
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        time = seconds
        if player.timeControlStatus == .paused { player.play() }
    }

    func pause() {
        player.pause()
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        rateObserver?.invalidate()
        if accessed { url.stopAccessingSecurityScopedResource() }
    }
}

private struct MediaPreview: NSViewRepresentable {
    var player: AVPlayer
    var showsVideo: Bool

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.videoGravity = .resizeAspect
        configure(view)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        configure(view)
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player = nil
    }

    private func configure(_ view: AVPlayerView) {
        view.controlsStyle = showsVideo ? .floating : .inline
        view.showsFullScreenToggleButton = showsVideo
        if view.player !== player { view.player = player }
    }
}
