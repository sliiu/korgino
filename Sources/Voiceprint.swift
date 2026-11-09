import Accelerate
import AVFoundation
import Combine
import CoreML
import CryptoKit
import Foundation

// 声纹：靠声音分出是谁在说。模型是 WeSpeaker ResNet34-LM（VoxCeleb，CC BY 4.0），
// 由 wquguru/cicada 转成 Core ML。不进安装包，第一次要用时下载（同 ADR 0033）。
// 没有模型或模型出错时，调用方仍用 SpeakerTracker。
// 本文件的 mel 前端与后处理派生自 wquguru/cicada（Apache-2.0）；
// 许可全文见 LICENSES/Apache-2.0.txt，来源与改动说明见 THIRD-PARTY-NOTICES.md。

// MARK: - Model files

/// 声纹模型的下载、安装和删除。只在被要求时联网。
@MainActor
final class VoiceprintModel: ObservableObject {
    enum State: Equatable {
        case absent
        case downloading(Double)
        case preparing
        case ready
        case failed(String)
    }

    static let shared = VoiceprintModel()

    // MARK: Hosting — the one list of download URLs. Primary first; same file at each.
    // TODO: real URLs before release (dist/voiceprint/README.md).
    nonisolated static let sources: [URL] = [
        URL(string: "https://models-r2.example.com/korgi/voiceprint/SpeakerEmbedding-v1.zip")!,   // Cloudflare R2
        URL(string: "https://models-oss.example.com/korgi/voiceprint/SpeakerEmbedding-v1.zip")!,  // 阿里云 OSS
    ]
    nonisolated static let sha256 = "5fc83cc858bb656fbfa842056131c67b1060444d01ff7352ce672c6b0998b261"
    nonisolated static let zipBytes: Int64 = 12_315_933

    /// ~/Library/Application Support/Korgino/Models/Voiceprint
    nonisolated static var folder: URL {
        AppPaths.appSupport
            .appendingPathComponent("Models/Voiceprint", isDirectory: true)
    }

    nonisolated static var compiledURL: URL {
        folder.appendingPathComponent("SpeakerEmbedding-v1.mlmodelc", isDirectory: true)
    }

    nonisolated static var installed: Bool {
        FileManager.default.fileExists(atPath: compiledURL.appendingPathComponent("coremldata.bin").path)
    }

    @Published private(set) var state: State

    var isReady: Bool { state == .ready }

    private var attempt = 0
    private var job: Task<Void, Never>?
    private var transfer: URLSessionDownloadTask?
    private var watch: NSKeyValueObservation?

    private init() {
        state = Self.installed ? .ready : .absent
        Self.sweepStaging()
    }

    private var busy: Bool {
        switch state {
        case .downloading, .preparing: return true
        default: return false
        }
    }

    /// Tries each URL in `sources` in turn. A file whose hash doesn't match counts as a failed source.
    func download() {
        guard !busy, state != .ready else { return }
        #if KORGI_DEV
        // 上传前先用本地 zip 试装。
        if let path = ProcessInfo.processInfo.environment["KORGI_VOICEPRINT_ZIP"], !path.isEmpty,
           FileManager.default.fileExists(atPath: path) {
            install(from: URL(fileURLWithPath: path))
            return
        }
        #endif
        attempt += 1
        let id = attempt
        state = .downloading(0)
        job = Task { [weak self] in await self?.runDownload(id) }
    }

    /// A file the user picked: the release .zip (hash checked) or a SpeakerEmbedding.mlpackage folder.
    func install(from url: URL) {
        guard !busy else { return }
        attempt += 1
        let id = attempt
        state = .preparing
        job = Task { [weak self] in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let result = await Task.detached(priority: .userInitiated) { () -> Error? in
                do {
                    try Self.installPicked(url)
                    return nil
                } catch {
                    return error
                }
            }.value
            self?.finish(id, error: result)
        }
    }

    /// Stops a download. Preparing (unzip + compile, a few seconds) runs to the end.
    func cancel() {
        guard case .downloading = state else { return }
        attempt += 1
        job?.cancel()
        transfer?.cancel()
        transfer = nil
        watch = nil
        state = Self.installed ? .ready : .absent
        Self.sweepStaging()
    }

    /// Deletes the model. Ignored while preparing.
    func remove() {
        guard state != .preparing else { return }
        cancel()
        attempt += 1
        VoiceprintEngine.shared.unload()
        try? FileManager.default.removeItem(at: Self.folder)
        state = .absent
    }

    // MARK: Download

    private func runDownload(_ id: Int) async {
        var last: Error?
        for source in Self.sources {
            guard id == attempt, !Task.isCancelled else { return }
            state = .downloading(0)
            let staging: URL
            do {
                staging = try Self.makeStaging()
            } catch {
                last = error
                break
            }
            do {
                let zip = staging.appendingPathComponent("SpeakerEmbedding.zip")
                try await fetch(source, to: zip, id: id)
                guard id == attempt else { return }
                state = .preparing
                let failure = await Task.detached(priority: .userInitiated) { () -> Error? in
                    do {
                        try Self.installZip(zip, staging: staging)
                        return nil
                    } catch {
                        try? FileManager.default.removeItem(at: staging)
                        return error
                    }
                }.value
                if failure == nil || failure is CompileError {
                    finish(id, error: failure)
                    return
                }
                last = failure
            } catch {
                last = error
                try? FileManager.default.removeItem(at: staging)
            }
        }
        guard id == attempt else { return }
        let reason = last?.localizedDescription ?? L("没有可用的下载地址")
        finish(id, error: TErr(String(format: L("声纹模型下载失败：%@"), reason)))
    }

    private func fetch(_ source: URL, to dest: URL, id: Int) async throws {
        // `streaming`: same proxy as `shared`, without its 60 s cap on the whole transfer.
        let session = NetSession.streaming
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let task = session.downloadTask(with: source) { tmp, response, error in
                if let error {
                    cont.resume(throwing: NetSession.mapTransportError(error))
                    return
                }
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard let tmp, (200..<300).contains(code) else {
                    cont.resume(throwing: TErr(String(format: L("服务器返回 %@"), String(code))))
                    return
                }
                // `tmp` is deleted once this handler returns.
                do {
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.moveItem(at: tmp, to: dest)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
            watch = task.observe(\.countOfBytesReceived) { [weak self] t, _ in
                let total = t.countOfBytesExpectedToReceive > 0 ? t.countOfBytesExpectedToReceive : Self.zipBytes
                let f = min(1, Double(t.countOfBytesReceived) / Double(max(total, 1)))
                Task { @MainActor [weak self] in
                    guard let self, self.attempt == id, case .downloading(let was) = self.state,
                          f - was >= 0.005 || f >= 1 else { return }
                    self.state = .downloading(f)
                }
            }
            transfer = task
            task.resume()
        }
        transfer = nil
        watch = nil
    }

    private func finish(_ id: Int, error: Error?) {
        guard id == attempt else { return }
        job = nil
        transfer = nil
        watch = nil
        try? FileManager.default.removeItem(at: Self.stagingRoot)
        VoiceprintEngine.shared.unload()
        if let error {
            state = .failed(error.localizedDescription)
        } else {
            state = Self.installed ? .ready : .failed(L("声纹模型准备失败"))
        }
    }

    // MARK: Install (off main)

    private struct CompileError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    nonisolated private static var stagingRoot: URL { folder.appendingPathComponent("staging", isDirectory: true) }

    nonisolated private static func makeStaging() throws -> URL {
        let dir = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Leftovers from a quit mid-download.
    nonisolated private static func sweepStaging() {
        try? FileManager.default.removeItem(at: stagingRoot)
    }

    nonisolated private static func installPicked(_ url: URL) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { throw TErr(L("选的不是声纹模型")) }
        let staging = try makeStaging()
        defer { try? fm.removeItem(at: staging) }
        if isDir.boolValue {
            guard url.pathExtension == "mlpackage" || fm.fileExists(atPath: url.appendingPathComponent("Manifest.json").path) else {
                throw TErr(L("选的不是声纹模型"))
            }
            // Copy first: the picked folder's sandbox access ends with this call.
            let pkg = staging.appendingPathComponent("SpeakerEmbedding.mlpackage", isDirectory: true)
            try fm.copyItem(at: url, to: pkg)
            try compile(pkg)
        } else {
            guard url.pathExtension.lowercased() == "zip" else { throw TErr(L("选的不是声纹模型")) }
            // ditto runs as a child process and may not inherit access to the picked file.
            let zip = staging.appendingPathComponent("SpeakerEmbedding.zip")
            try fm.copyItem(at: url, to: zip)
            try installZip(zip, staging: staging)
        }
    }

    /// Hash → unzip → compile → keep the .mlmodelc. Removes `staging`.
    nonisolated private static func installZip(_ zip: URL, staging: URL) throws {
        defer { try? FileManager.default.removeItem(at: staging) }
        guard try hash(of: zip) == sha256 else { throw TErr(L("声纹模型校验不通过")) }
        let out = staging.appendingPathComponent("unzipped", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, out.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw TErr(L("声纹模型解压失败")) }
        try? FileManager.default.removeItem(at: zip)
        guard let pkg = findPackage(in: out) else { throw TErr(L("声纹模型解压失败")) }
        try compile(pkg)
    }

    nonisolated private static func hash(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var h = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            h.update(data: chunk)
        }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func findPackage(in dir: URL) -> URL? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        if let pkg = items.first(where: { $0.pathExtension == "mlpackage" }) { return pkg }
        for sub in items where sub.lastPathComponent != "__MACOSX" && sub.hasDirectoryPath {
            if let pkg = (try? fm.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil))?
                .first(where: { $0.pathExtension == "mlpackage" }) {
                return pkg
            }
        }
        return nil
    }

    /// Compiles once and checks the I/O the engine relies on before replacing the installed copy.
    nonisolated private static func compile(_ pkg: URL) throws {
        let fm = FileManager.default
        let compiled: URL
        do {
            compiled = try MLModel.compileModel(at: pkg)
        } catch {
            throw CompileError(message: String(format: L("声纹模型准备失败：%@"), error.localizedDescription))
        }
        defer { try? fm.removeItem(at: compiled) }
        let model = try MLModel(contentsOf: compiled)
        guard model.modelDescription.inputDescriptionsByName[VoiceprintEngine.input] != nil,
              model.modelDescription.outputDescriptionsByName[VoiceprintEngine.output] != nil else {
            throw CompileError(message: L("选的不是声纹模型"))
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try? fm.removeItem(at: compiledURL)
        try fm.moveItem(at: compiled, to: compiledURL)
    }
}

// MARK: - Fbank

/// Kaldi log-mel filterbank as `torchaudio.compliance.kaldi.fbank` with WeSpeaker's training defaults:
/// 16 kHz, 25 ms Povey windows every 10 ms, DC removed, pre-emphasis 0.97, 512-point power spectrum,
/// 80 mel bins 20 Hz–8 kHz, natural log, no dither. Samples are scaled to int16 range first.
/// After wquguru/cicada SpeakerID.swift, Apache-2.0.
enum VoiceFbank {
    static let bins = 80
    static let frameLength = 400
    static let shift = 160
    private static let fftSize = 512
    private static let log2n: vDSP_Length = 9

    private static let window: [Float] = (0..<frameLength).map {
        pow(0.5 - 0.5 * cos(2 * Float.pi * Float($0) / Float(frameLength - 1)), 0.85)
    }

    /// `bins` rows × `fftSize / 2 + 1` columns; the Nyquist column stays zero, as in Kaldi.
    private static let melBanks: [Float] = {
        func mel(_ f: Double) -> Double { 1127 * log(1 + f / 700) }
        let cols = fftSize / 2 + 1
        let lo = mel(20), hi = mel(8000), delta = (hi - lo) / Double(bins + 1)
        var w = [Float](repeating: 0, count: bins * cols)
        for m in 0..<bins {
            let left = lo + Double(m) * delta, center = left + delta, right = center + delta
            for k in 0..<(fftSize / 2) {
                let x = mel(Double(k) * 16000 / Double(fftSize))
                let v = min((x - left) / (center - left), (right - x) / (right - center))
                if v > 0 { w[m * cols + k] = Float(v) }
            }
        }
        return w
    }()

    nonisolated(unsafe) private static let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!

    /// Frames × `bins`, row-major.
    static func compute(_ samples: [Float]) -> [Float] {
        guard samples.count >= frameLength else { return [] }
        let frames = 1 + (samples.count - frameLength) / shift
        let cols = fftSize / 2 + 1
        let half = fftSize / 2
        var out = [Float](repeating: 0, count: frames * bins)
        var frame = [Float](repeating: 0, count: fftSize)
        var re = [Float](repeating: 0, count: half), im = re
        var power = [Float](repeating: 0, count: cols)
        var mels = [Float](repeating: 0, count: bins)
        for f in 0..<frames {
            let start = f * shift
            for i in 0..<frameLength { frame[i] = samples[start + i] * 32768 }
            for i in frameLength..<fftSize { frame[i] = 0 }
            var mean: Float = 0
            vDSP_meanv(frame, 1, &mean, vDSP_Length(frameLength))
            for i in 0..<frameLength { frame[i] -= mean }
            for i in stride(from: frameLength - 1, to: 0, by: -1) { frame[i] -= 0.97 * frame[i - 1] }
            frame[0] -= 0.97 * frame[0]
            vDSP_vmul(frame, 1, window, 1, &frame, 1, vDSP_Length(frameLength))
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    frame.withUnsafeBytes { raw in
                        vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                }
            }
            // vDSP's real FFT is scaled by 2; Nyquist is packed into im[0].
            power[0] = re[0] * re[0] / 4
            power[cols - 1] = im[0] * im[0] / 4
            for k in 1..<half { power[k] = (re[k] * re[k] + im[k] * im[k]) / 4 }
            vDSP_mmul(melBanks, 1, power, 1, &mels, 1, vDSP_Length(bins), 1, vDSP_Length(cols))
            for b in 0..<bins { out[f * bins + b] = log(max(mels[b], .ulpOfOne)) }
        }
        return out
    }
}

// MARK: - Engine

/// 一段 16 kHz 单声道声音 → 一个单位长度的 256 维声纹。模型第一次用时在调用线程上加载，别在主线程调。
final class VoiceprintEngine: @unchecked Sendable {
    static let shared = VoiceprintEngine()

    static let input = "feats"
    static let output = "embs"
    static let sampleRate = 16000.0
    /// Shorter clips give no voiceprint (the model needs 50 frames).
    static let minSeconds = 0.5
    /// Longer clips are cut: 20 s is plenty to know a voice and bounds the work.
    static let maxSeconds = 20.0

    private let modelURL: URL
    private let lock = NSLock()
    private var model: MLModel?
    private var loadFailed = false

    init(modelURL: URL = VoiceprintModel.compiledURL) {
        self.modelURL = modelURL
    }

    /// A compiled model is on disk and hasn't failed to load.
    var available: Bool {
        lock.lock()
        defer { lock.unlock() }
        return model != nil || (!loadFailed && FileManager.default.fileExists(atPath: modelURL.path))
    }

    /// Drops the loaded model; the next `embed` loads what is on disk.
    func unload() {
        lock.lock()
        defer { lock.unlock() }
        model = nil
        loadFailed = false
    }

    /// Nil when too short, or when the model is missing or failed.
    func embed(_ samples16k: [Float]) -> [Float]? {
        guard Double(samples16k.count) >= Self.minSeconds * Self.sampleRate else { return nil }
        let limit = Int(Self.maxSeconds * Self.sampleRate)
        let clip = samples16k.count > limit ? Array(samples16k.prefix(limit)) : samples16k
        var feats = VoiceFbank.compute(clip)
        let bins = VoiceFbank.bins
        let frames = feats.count / bins
        guard frames >= 50 else { return nil }
        // Per-bin mean over the clip, as in training. After wquguru/cicada SpeakerID.swift, Apache-2.0.
        for b in 0..<bins {
            var sum: Float = 0
            for f in 0..<frames { sum += feats[f * bins + b] }
            let mean = sum / Float(frames)
            for f in 0..<frames { feats[f * bins + b] -= mean }
        }
        guard let input = try? MLMultiArray(shape: [1, NSNumber(value: frames), NSNumber(value: bins)], dataType: .float32) else {
            return nil
        }
        feats.withUnsafeBytes { src in
            input.withUnsafeMutableBytes { dst, _ in dst.copyMemory(from: src) }
        }
        lock.lock()
        defer { lock.unlock() }
        guard let model = loadLocked(),
              let provider = try? MLDictionaryFeatureProvider(dictionary: [Self.input: input]),
              let out = try? model.prediction(from: provider),
              let embs = out.featureValue(for: Self.output)?.multiArrayValue else { return nil }
        var v = (0..<embs.count).map { Float(truncating: embs[$0]) }
        var sq: Float = 0
        vDSP_svesq(v, 1, &sq, vDSP_Length(v.count))
        guard sq > 0, sq.isFinite else { return nil }
        var n = sq.squareRoot()
        vDSP_vsdiv(v, 1, &n, &v, 1, vDSP_Length(v.count))
        return v
    }

    private func loadLocked() -> MLModel? {
        if let model { return model }
        guard !loadFailed, FileManager.default.fileExists(atPath: modelURL.path) else { return nil }
        let config = MLModelConfiguration()
        // Every clip is a new input length. The GPU recompiles per length (up to ~0.5 s); the CPU stays at a few ms.
        config.computeUnits = .cpuOnly
        do {
            model = try MLModel(contentsOf: modelURL, configuration: config)
        } catch {
            loadFailed = true
            NSLog("Korgino: voiceprint model failed to load: \(error)")
        }
        return model
    }
}

// MARK: - Tagger

/// 一路采集一个：听到的声音转成 16 kHz 单声道，留最近约 120 秒，按会话时间取一段给出说话人号。
/// 零点由 `arm(at:)` 给出，和段的 start / end 同一个钟。所有活在自己的队列上。
final class VoiceTagger: LiveAudioSink, @unchecked Sendable {
    static let keepSeconds = 120.0
    /// Taken on each side of a segment.
    static let pad = 0.2
    /// Clips quieter than this are not tagged.
    static let silentRMS: Float = 0.003

    private let queue = DispatchQueue(label: "com.sliiu.Korgino.voicetag", qos: .utility)
    private let engine: VoiceprintEngine
    private let rate = VoiceprintEngine.sampleRate
    private let capacity: Int
    private var ring: [Float]
    /// Session sample index of the next sample to write.
    private var written: Int = 0
    private var origin: Date?
    private var converter: AVAudioConverter?
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private var cluster = VoiceCluster()
    private var stopped = false
    private var pending: [Request] = []
    private var draining = false

    init(engine: VoiceprintEngine = .shared) {
        self.engine = engine
        capacity = Int(Self.keepSeconds * VoiceprintEngine.sampleRate)
        ring = [Float](repeating: 0, count: capacity)
    }

    // MARK: LiveAudioSink

    func prepare() throws {
        queue.async { [weak self] in self?.stopped = false }
    }

    func ensureConverter(from format: AVAudioFormat) {}

    func startRecognition() {}

    /// Zero point shared with segment start / end. Buffers that arrive before this are dropped.
    func arm(at origin: Date) {
        queue.async { [weak self] in
            guard let self else { return }
            self.origin = origin
            self.written = 0
            self.stopped = false
        }
    }

    func append(pcm: AVAudioPCMBuffer) {
        let arrived = Date()
        queue.async { [weak self] in self?.write(pcm, arrived: arrived) }
    }

    func append(sampleBuffer: CMSampleBuffer) {
        guard let pcm = LiveASRLane.pcmBuffer(from: sampleBuffer) else { return }
        append(pcm: pcm)
    }

    /// Stops taking audio. What was heard stays for `tag` until `reset()` or the next `arm(at:)`.
    func stop() {
        queue.async { [weak self] in
            self?.stopped = true
            self?.converter = nil
            self?.drain()
        }
    }

    // MARK: Tagging

    /// 1-based speaker number for the span, on main; nil when too short, silent, out of the kept audio, or no model.
    func tag(start: TimeInterval, end: TimeInterval, completion: @escaping @MainActor (Int?) -> Void) {
        queue.async { [weak self] in
            self?.pending.append(Request(start: start, end: end, completion: completion))
            self?.drain()
        }
    }

    /// The user said two speakers are one. Later spans like either get `into`.
    func merge(_ from: Int, into: Int) {
        queue.async { [weak self] in self?.cluster.merge(from, into: into) }
    }

    /// A new session: forget the voices and the audio.
    func reset() {
        queue.async { [weak self] in
            guard let self else { return }
            self.cluster = VoiceCluster()
            self.written = 0
            self.origin = nil
            self.converter = nil
            self.drain()   // anything still waiting gets nil
        }
    }

    /// The voices so far, to save with a meeting record.
    func snapshot(_ completion: @escaping @MainActor (VoiceCluster) -> Void) {
        queue.async { [weak self] in
            guard let c = self?.cluster else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(c) } }
        }
    }

    /// Continue with voices saved earlier.
    func restore(_ saved: VoiceCluster) {
        queue.async { [weak self] in self?.cluster = saved }
    }

    // MARK: On `queue`

    private struct Request {
        let start: TimeInterval
        let end: TimeInterval
        let completion: @MainActor (Int?) -> Void
        var waits = 0
    }

    /// In order: a span still waiting for its audio holds the ones after it, so voices are met in time order.
    private func drain() {
        while var head = pending.first {
            let last = min(max(head.start, head.end), head.start + VoiceprintEngine.maxSeconds)
            // The segment can be reported a moment before its last audio arrives. Don't wait for the pad:
            // capture sends nothing while nothing plays.
            if Int(last * rate) > written, !stopped, origin != nil, head.waits < 4 {
                head.waits += 1
                pending[0] = head
                guard !draining else { return }
                draining = true
                queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.draining = false
                    self?.drain()
                }
                return
            }
            pending.removeFirst()
            let n = label(start: head.start, end: head.end, last: last)
            let completion = head.completion
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(n) } }
        }
    }

    private func label(start: TimeInterval, end: TimeInterval, last: TimeInterval) -> Int? {
        let lo = max(Int(max(0, start - Self.pad) * rate), written - capacity, 0)
        let hi = min(Int((last + Self.pad) * rate), written)
        guard hi - lo >= Int(VoiceprintEngine.minSeconds * rate) else { return nil }
        var clip = [Float](repeating: 0, count: hi - lo)
        for i in 0..<clip.count { clip[i] = ring[(lo + i) % capacity] }
        guard Self.rms(clip) >= Self.silentRMS, let v = engine.embed(clip) else { return nil }
        return cluster.label(v, seconds: last - start)
    }

    private func write(_ pcm: AVAudioPCMBuffer, arrived: Date) {
        guard !stopped, let origin, arrived >= origin, pcm.frameLength > 0 else { return }
        if converter?.inputFormat != pcm.format {
            converter = AVAudioConverter(from: pcm.format, to: format)
            converter?.downmix = true
        }
        guard let converter, let out = Self.convert(pcm, with: converter, to: format),
              let data = out.floatChannelData?[0] else { return }
        let n = Int(out.frameLength)
        // Capture stops sending while nothing plays. Keep the span silent so the ring stays on the session clock.
        let due = Int(arrived.timeIntervalSince(origin) * rate)
        let gap = due - written - n
        if gap > Int(rate * 0.5) {
            let fill = min(gap, capacity)
            for i in 0..<fill { ring[(written + gap - fill + i) % capacity] = 0 }
            written += gap
        }
        for i in 0..<n { ring[(written + i) % capacity] = data[i] }
        written += n
    }

    static func convert(_ pcm: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
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

    static func rms(_ x: [Float]) -> Float {
        guard !x.isEmpty else { return 0 }
        var r: Float = 0
        vDSP_rmsqv(x, 1, &r, vDSP_Length(x.count))
        return r
    }
}

// MARK: - Files

extension VoiceTagger {
    /// Speaker numbers for segments of a media file or a saved recording, in the order given.
    /// Reads one audio track once at 16 kHz mono, keeping only what the next segments need.
    /// `trackID` picks the track a media job is using; nil reads the first.
    /// All nil when the model is missing or the file can't be read.
    static func label(
        segments: [(start: TimeInterval, end: TimeInterval)],
        audioURL: URL,
        trackID: Int? = nil,
        engine: VoiceprintEngine = .shared
    ) async -> [Int?] {
        guard !segments.isEmpty else { return [] }
        let none = [Int?](repeating: nil, count: segments.count)
        guard engine.available else { return none }
        let scoped = audioURL.startAccessingSecurityScopedResource()
        defer { if scoped { audioURL.stopAccessingSecurityScopedResource() } }
        let asset = AVURLAsset(url: audioURL)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty else { return none }
        let track = tracks.first { trackID != nil && Int($0.trackID) == trackID } ?? tracks[0]
        let spans = segments
        return await Task.detached(priority: .utility) { () -> [Int?] in
            guard let reader = try? AVAssetReader(asset: asset) else { return none }
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsNonInterleaved: true,
                AVLinearPCMIsBigEndianKey: false,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
            ]
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { return none }
            reader.add(output)
            guard reader.startReading() else { return none }
            return embedAll(spans, reading: output, reader: reader, engine: engine)
        }.value
    }

    private static func embedAll(
        _ spans: [(start: TimeInterval, end: TimeInterval)],
        reading output: AVAssetReaderTrackOutput,
        reader: AVAssetReader,
        engine: VoiceprintEngine
    ) -> [Int?] {
        let rate = VoiceprintEngine.sampleRate
        let order = spans.indices.sorted { spans[$0].start < spans[$1].start }
        func window(_ i: Int) -> (from: Int, to: Int) {
            let s = spans[i]
            let end = min(s.end, s.start + VoiceprintEngine.maxSeconds)
            return (Int(max(0, s.start - pad) * rate), Int(max(0, end + pad) * rate))
        }
        var buffer: [Float] = []
        var bufferStart = 0   // file sample index of buffer[0]
        var eof = false
        var prints = [[Float]?](repeating: nil, count: spans.count)
        for (k, i) in order.enumerated() {
            if Task.isCancelled { break }
            let w = window(i)
            while !eof, bufferStart + buffer.count < w.to {
                guard let sample = output.copyNextSampleBuffer() else { eof = true; break }
                append(sample, to: &buffer)
            }
            let lo = max(w.from, bufferStart) - bufferStart
            let hi = min(w.to, bufferStart + buffer.count) - bufferStart
            if hi - lo >= Int(VoiceprintEngine.minSeconds * rate) {
                let clip = Array(buffer[lo..<hi])
                if rms(clip) >= silentRMS { prints[i] = engine.embed(clip) }
            }
            // Drop what no later segment needs.
            let keepFrom = k + 1 < order.count ? window(order[k + 1]).from : bufferStart + buffer.count
            let drop = min(max(0, keepFrom - bufferStart), buffer.count)
            if drop > 0 {
                buffer.removeFirst(drop)
                bufferStart += drop
            }
        }
        reader.cancelReading()
        // Cluster in time order, then map back to the caller's order.
        let items = order.map { (v: prints[$0] ?? [], seconds: min(max(0, spans[$0].end - spans[$0].start), VoiceprintEngine.maxSeconds)) }
        let labels = VoiceCluster.batch(items)
        var out = [Int?](repeating: nil, count: spans.count)
        for (k, i) in order.enumerated() { out[i] = labels[k] }
        return out
    }

    private static func append(_ sample: CMSampleBuffer, to buffer: inout [Float]) {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
        let bytes = CMBlockBufferGetDataLength(block)
        let n = bytes / MemoryLayout<Float>.size
        guard n > 0 else { return }
        let old = buffer.count
        buffer.append(contentsOf: repeatElement(0, count: n))
        buffer.withUnsafeMutableBytes { raw in
            _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: n * MemoryLayout<Float>.size,
                                           destination: raw.baseAddress! + old * MemoryLayout<Float>.size)
        }
    }
}
