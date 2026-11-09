import AVFoundation
import CoreAudio
import CoreMedia
import Foundation

/// 把采到的声音换成同传服务要的 PCM16 单声道，再送进连接。调用方保证同一时间只有一个线程在送。
final class InterpFeed: @unchecked Sendable {
    let session: InterpSession
    private let output: AVAudioFormat
    private var converter: AVAudioConverter?
    private var from: AVAudioFormat?

    init(session: InterpSession) {
        self.session = session
        output = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(session.config.inputRate),
            channels: 1,
            interleaved: true
        )!
    }

    func take(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0, buffer.format.sampleRate > 0 else { return }
        if converter == nil || from != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: output)
            from = buffer.format
        }
        guard let converter else { return }
        let ratio = output.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return }
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
        guard error == nil, out.frameLength > 0, let samples = out.int16ChannelData else { return }
        let data = Data(bytes: samples[0], count: Int(out.frameLength) * 2)
        session.send(pcm16: data)
    }
}

/// 同传服务送回来的译音，边收边播。
final class InterpPlayer: @unchecked Sendable {
    static let shared = InterpPlayer()
    /// 通话时把「我」那一路的译音送进一个虚拟声卡，聊天软件把它当麦克风。
    static let relay = InterpPlayer()

    private var engine = AVAudioEngine()
    private var node = AVAudioPlayerNode()
    /// Empty: the system default output.
    private var deviceUID = ""
    private let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(InterpConfig.outputRate),
        channels: 1,
        interleaved: false
    )!
    private let lock = NSLock()
    private var _gain: Float = 1
    /// 译音放大倍数。通话时聊天软件会把别的声音压低，1 倍常常听不清。超出的部分削掉，不会爆音到失真太多。
    var gain: Float {
        get { lock.lock(); defer { lock.unlock() }; return _gain }
        set { lock.lock(); _gain = max(0, newValue); lock.unlock() }
    }
    private var wired = false
    private var watch: NSObjectProtocol?
    private var pending = 0
    private var generation = 0
    private var drained: [@Sendable () -> Void] = []

    var isPlaying: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pending > 0
    }

    /// Sends what is played from now on to the output device with this UID. Empty: the system default.
    /// A change stops what is playing and rebuilds the engine on the next `play`.
    func route(to uid: String) {
        lock.lock()
        guard uid != deviceUID else {
            lock.unlock()
            return
        }
        deviceUID = uid
        lock.unlock()
        stop()
        lock.lock()
        resetEngine()
        lock.unlock()
    }

    /// Caller holds `lock`. The next `play` wires a fresh engine to `deviceUID`.
    private func resetEngine() {
        if let watch { NotificationCenter.default.removeObserver(watch) }
        watch = nil
        if engine.isRunning { engine.stop() }
        engine = AVAudioEngine()
        node = AVAudioPlayerNode()
        wired = false
    }

    /// A device change (a call app opening BlackHole at its own rate when the call starts, headphones plugged in) leaves
    /// the engine reporting running while it plays silence, so `ensureRunning` never restarts it.
    /// Rewire to the device's new format and let the next `play` start it again. A fresh engine would not help:
    /// switching it to a device at another rate than the default output posts the same change right after start.
    private func configurationChanged(_ changed: AVAudioEngine) {
        lock.lock()
        let current = changed === engine && wired
        lock.unlock()
        guard current else { return }
        // What was queued goes with the old graph.
        stop()
        lock.lock()
        defer { lock.unlock() }
        guard changed === engine, wired else { return }
        if !deviceUID.isEmpty {
            // A device that is gone plays nothing rather than falling back to the speakers.
            guard let id = AudioOutputs.deviceID(uid: deviceUID), let unit = engine.outputNode.audioUnit else {
                resetEngine()
                return
            }
            var selected: AudioDeviceID = 0
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &selected, &size)
            if selected != id {
                selected = id
                guard AudioUnitSetProperty(
                    unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                    &selected, UInt32(MemoryLayout<AudioDeviceID>.size)
                ) == noErr else {
                    resetEngine()
                    return
                }
            }
        }
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: engine.outputNode.outputFormat(forBus: 0))
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    /// The system can move a wired engine off its chosen device without posting a configuration change,
    /// e.g. when a meeting app reconfigures BlackHole. The engine then keeps playing on the speakers, session
    /// after session, and the other side of the call hears nothing. A moved engine is dropped and rebuilt.
    private func keepOnDevice() {
        lock.lock()
        let uid = deviceUID
        let unit = wired ? engine.outputNode.audioUnit : nil
        lock.unlock()
        guard !uid.isEmpty, let unit else { return }
        var selected: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &selected, &size)
        if status == noErr, let wanted = AudioOutputs.deviceID(uid: uid), selected == wanted { return }
        stop()
        lock.lock()
        resetEngine()
        lock.unlock()
    }

    /// PCM16 little-endian mono at `InterpConfig.outputRate`.
    func play(_ pcm16: Data) {
        let frames = pcm16.count / 2
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        let scale = gain / 32768
        pcm16.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<frames {
                channel[i] = min(1, max(-1, Float(Int16(littleEndian: samples[i])) * scale))
            }
        }
        keepOnDevice()
        lock.lock()
        guard ensureRunning() else {
            lock.unlock()
            return
        }
        pending += 1
        let gen = generation
        let node = self.node
        lock.unlock()
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.played(gen)
        }
        if !node.isPlaying { node.play() }
    }

    /// Runs `action` once everything scheduled so far has been heard, or right away when nothing is.
    func whenDrained(_ action: @escaping @Sendable () -> Void) {
        lock.lock()
        if pending == 0 {
            lock.unlock()
            action()
            return
        }
        drained.append(action)
        lock.unlock()
    }

    func stop() {
        lock.lock()
        generation += 1
        pending = 0
        let waiting = drained
        drained.removeAll()
        let running = wired && engine.isRunning
        let node = self.node
        let engine = self.engine
        lock.unlock()
        // Let go of the device too. A running engine keeps BlackHole busy after the call, and chat apps see it as taken.
        if running {
            node.stop()
            engine.stop()
        }
        for action in waiting { action() }
    }

    private func ensureRunning() -> Bool {
        if !wired {
            if !deviceUID.isEmpty {
                // A device that is gone plays nothing rather than falling back to the speakers.
                guard let id = AudioOutputs.deviceID(uid: deviceUID), let unit = engine.outputNode.audioUnit else { return false }
                var selected = id
                let status = AudioUnitSetProperty(
                    unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                    &selected, UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                guard status == noErr else { return false }
            }
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            wired = true
            let wiredEngine = engine
            watch = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: wiredEngine, queue: nil
            ) { [weak self, weak wiredEngine] _ in
                guard let self, let wiredEngine else { return }
                self.configurationChanged(wiredEngine)
            }
        }
        if !engine.isRunning {
            engine.prepare()
            do { try engine.start() } catch { return false }
        }
        return true
    }

    private func played(_ gen: Int) {
        lock.lock()
        guard gen == generation else {
            lock.unlock()
            return
        }
        pending = max(0, pending - 1)
        var waiting: [@Sendable () -> Void] = []
        if pending == 0 {
            waiting = drained
            drained.removeAll()
        }
        lock.unlock()
        for action in waiting { action() }
    }
}

/// Output devices, for picking where 译音 goes.
enum AudioOutputs {
    struct Device: Identifiable, Hashable {
        var uid: String
        var name: String
        var id: String { uid }
    }

    static func devices() -> [Device] {
        var listed: [Device] = []
        for id in objectIDs(AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDevices) {
            guard !objectIDs(id, selector: kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput).isEmpty,
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

    private static func objectIDs(
        _ object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func copyString(_ object: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ref) == noErr, let ref else { return nil }
        return ref.takeRetainedValue() as String
    }
}

enum InterpText {
    /// Joins utterances. No space between two Han or kana runs.
    static func join(_ parts: [String]) -> String {
        var out = ""
        for raw in parts {
            let part = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !part.isEmpty else { continue }
            if let last = out.unicodeScalars.last, let first = part.unicodeScalars.first,
               !(isWide(last) && isWide(first)) {
                out += " "
            }
            out += part
        }
        return out
    }

    /// The services write simplified Chinese. 繁體 is converted here.
    static func shaped(_ text: String, for language: TargetLanguage) -> String {
        guard language.resolvedDestination == .zhHant else { return text }
        return text.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? text
    }

    private static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return Lang.isHan(v) || (0x3000...0x30FF).contains(v) || (0xFF00...0xFFEF).contains(v)
    }
}

/// 实时字幕里同传服务占的一路。连接在 `prepare` 时就开，说话前先连上。
final class LiveInterpLane: LiveAudioSink, @unchecked Sendable {
    let laneID: UUID
    let source: SystemAudioTranslateController.SourceKind
    private let engineID: String
    private let onEvent: @Sendable (InterpEvent) -> Void
    private let queue: DispatchQueue
    private var link: InterpSession?
    private var feed: InterpFeed?
    private var target: TargetLanguage
    private var withAudio: Bool
    private var stopped = false

    init(
        laneID: UUID,
        source: SystemAudioTranslateController.SourceKind,
        engineID: String,
        target: TargetLanguage,
        audio: Bool,
        onEvent: @escaping @Sendable (InterpEvent) -> Void
    ) {
        self.laneID = laneID
        self.source = source
        self.engineID = engineID
        self.target = target
        self.withAudio = audio
        self.onEvent = onEvent
        queue = DispatchQueue(label: "com.sliiu.Korgino.interp.\(source.rawValue)", qos: .userInitiated)
    }

    var language: TargetLanguage { target }

    func prepare() throws {
        let config = try AppConfig.shared.interpConfig(selection: engineID, target: target, audio: withAudio)
        let made = InterpSession(config: config, onEvent: onEvent)
        queue.sync {
            link?.cancel()
            link = made
            feed = InterpFeed(session: made)
        }
        made.open()
    }

    /// A new target language needs a new connection. What was in flight on the old one is dropped.
    func retarget(_ language: TargetLanguage) {
        guard language != target else { return }
        target = language
        let stale = queue.sync { () -> Bool in stopped }
        guard !stale else { return }
        try? prepare()
    }

    func ensureConverter(from format: AVAudioFormat) {}

    func startRecognition() {}

    func append(pcm: AVAudioPCMBuffer) {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            SystemAudioTranslateController.reportLevel(self.source, rms: Self.rms(pcm))
            self.feed?.take(pcm)
        }
    }

    func append(sampleBuffer: CMSampleBuffer) {
        guard let pcm = LiveASRLane.pcmBuffer(from: sampleBuffer) else { return }
        append(pcm: pcm)
    }

    func stop() {
        queue.sync {
            stopped = true
            link?.cancel()
            link = nil
            feed = nil
        }
    }

    private static func rms(_ pcm: AVAudioPCMBuffer) -> Float {
        guard let samples = pcm.floatChannelData?[0], pcm.frameLength > 0 else { return 0 }
        let count = Int(pcm.frameLength)
        var sum: Float = 0
        for i in 0..<count { sum += samples[i] * samples[i] }
        return (sum / Float(count)).squareRoot()
    }
}
