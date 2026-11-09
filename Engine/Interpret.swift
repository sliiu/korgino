import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 同传服务的两种接口。声音一直送进去，原文、译文和译音边说边回来。
enum InterpWire: String, Sendable {
    case qwen
    case openai
}

struct InterpConfig: Sendable {
    var wire: InterpWire
    var url: URL
    var key: String
    var model: String
    /// The service's own language code, e.g. `zh`, `en`.
    var target: String
    /// 识别词表里能原样保留的词。
    var terms: [String]
    var audio: Bool
    /// 译音用的系统音色。空着用服务的默认。只对千问有意义。
    var voice: String = ""

    /// PCM16 mono.
    var inputRate: Int { wire == .openai ? 24_000 : 16_000 }
    static let outputRate = 24_000
}

enum InterpLanguages {
    static let openai: Set<String> = ["en", "es", "pt", "fr", "ja", "ru", "zh", "de", "ko", "hi", "id", "vi", "it"]
    /// Targets that come back with both text and voice.
    static let qwen: Set<String> = [
        "zh", "en", "ar", "de", "fr", "es", "pt", "id", "it", "ko", "ru", "th", "vi", "ja", "tr", "hi",
        "ms", "nl", "ur", "nb", "sv", "da", "he", "fi", "pl", "is", "cs", "fil", "fa",
    ]

    static func code(_ language: TargetLanguage) -> String {
        let raw = (language.resolvedDestination.appleCode ?? "en").lowercased()
        if raw.hasPrefix("zh") { return "zh" }
        return String(raw.split(separator: "-").first ?? Substring(raw))
    }

    static func supports(_ wire: InterpWire, _ language: TargetLanguage) -> Bool {
        let c = code(language)
        switch wire {
        case .openai: return openai.contains(c)
        case .qwen: return qwen.contains(c)
        }
    }
}

enum InterpEvent: Sendable {
    /// Configured and taking audio.
    case ready
    /// `text` is everything heard so far for this item.
    case source(id: String, text: String, final: Bool, speaker: Int)
    /// `text` is everything translated so far for this item. `sourceID` is the item it renders, when the service says so.
    case target(id: String, sourceID: String?, text: String, final: Bool)
    /// PCM16 little-endian mono at `InterpConfig.outputRate`.
    case audio(Data)
    case failed(String)
}

/// One WebSocket to a 同传服务. Everything runs on one serial queue.
final class InterpSession: @unchecked Sendable {
    private struct Piece {
        var confirmed = ""
        var stash = ""
        var final = false
        var text: String { confirmed + stash }
    }

    let config: InterpConfig
    private let onEvent: @Sendable (InterpEvent) -> Void
    private let queue = DispatchQueue(label: "Korgino.interp", qos: .userInitiated)
    private var task: URLSessionWebSocketTask?
    private var ready = false
    private var closed = false
    private var finishing = false
    private var failedOnce = false
    private var held: [Data] = []
    private var heldBytes = 0
    private var outgoing = Data()
    private var lastOutputAt = Date()
    private var finished: [CheckedContinuation<Void, Never>] = []

    private var sources: [String: Piece] = [:]
    private var targets: [String: Piece] = [:]
    private var targetSource: [String: String] = [:]
    private var speakers: [String: Int] = [:]
    private var lastSourceID: String?

    // OpenAI does not name its items. Utterances are cut on `.done` or a pause.
    private var serial = 0
    private var openSource: String?
    private var openTarget: String?
    private var sourceQuiet: DispatchWorkItem?
    private var targetQuiet: DispatchWorkItem?

    init(config: InterpConfig, onEvent: @escaping @Sendable (InterpEvent) -> Void) {
        self.config = config
        self.onEvent = onEvent
    }

    func open() {
        queue.async { self.openLocked() }
    }

    /// PCM16 little-endian mono at `config.inputRate`.
    func send(pcm16: Data) {
        guard !pcm16.isEmpty else { return }
        queue.async { self.sendLocked(pcm16) }
    }

    /// Stops taking audio, lets the service finish what it heard, then closes.
    func finish(timeout: TimeInterval = 10) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                if self.closed {
                    cont.resume()
                    return
                }
                self.finished.append(cont)
                guard !self.finishing else { return }
                self.finishing = true
                self.flushOutgoing(force: true)
                self.beginFinish(timeout: timeout)
            }
        }
    }

    func cancel() {
        queue.async { self.closeLocked() }
    }

    // MARK: Connection

    private func openLocked() {
        guard task == nil, !closed else { return }
        var req = URLRequest(url: config.url)
        req.setValue("Bearer \(config.key)", forHTTPHeaderField: "Authorization")
        req.setValue(NetSession.chromeUA, forHTTPHeaderField: "User-Agent")
        let t = NetSession.streaming.webSocketTask(with: req)
        t.maximumMessageSize = 16 * 1024 * 1024
        task = t
        t.resume()
        receive()
    }

    private func receive() {
        guard let task else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard !self.closed else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text):
                        self.handle(Data(text.utf8))
                    case .data(let data):
                        self.handle(data)
                    @unknown default:
                        break
                    }
                    self.receive()
                case .failure(let error):
                    if self.finishing {
                        self.closeLocked()
                        return
                    }
                    self.fail(self.describe(error))
                }
            }
        }
    }

    private func describe(_ error: Error) -> String {
        // A server that hangs up says why in the close frame. URLSession only reports "socket is not connected".
        if let task, task.closeCode != .invalid {
            let reason = task.closeReason.flatMap { String(data: $0, encoding: .utf8) }?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let data = reason.data(using: .utf8),
               let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                let err = obj["error"] as? [String: Any]
                let code = (err?["code"] as? String) ?? (obj["code"] as? String) ?? ""
                let message = (err?["message"] as? String) ?? (obj["message"] as? String)
                if !code.isEmpty || !(message ?? "").isEmpty {
                    return Self.explain(code: code, message: message)
                }
            }
            if reason.localizedCaseInsensitiveContains("access to model denied") {
                return Self.explain(code: "AccessDenied", message: reason)
            }
            if !reason.isEmpty { return reason }
            return String(format: L("同传服务断开了连接（%@）"), String(describing: task.closeCode.rawValue))
        }
        if let http = task?.response as? HTTPURLResponse {
            switch http.statusCode {
            case 401, 403: return L("同传服务拒绝了这个密钥")
            case 404: return L("同传接口地址或模型不对")
            case 429: return L("同传服务限流了，稍后再试")
            case 400...599: return String(format: L("同传服务返回 %@"), String(describing: http.statusCode))
            default: break
            }
        }
        return NetSession.mapTransportError(error).localizedDescription
    }

    private func fail(_ message: String) {
        guard !failedOnce else { return }
        failedOnce = true
        onEvent(.failed(message))
        closeLocked()
    }

    private func closeLocked() {
        guard !closed else { return }
        closed = true
        sourceQuiet?.cancel()
        targetQuiet?.cancel()
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        held.removeAll()
        let waiting = finished
        finished.removeAll()
        for cont in waiting { cont.resume() }
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let task, !closed,
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { [weak self] error in
            guard let self, let error else { return }
            self.queue.async {
                guard !self.closed, !self.finishing else { return }
                self.fail(self.describe(error))
            }
        }
    }

    // MARK: Audio out

    private func sendLocked(_ pcm: Data) {
        guard !closed, !finishing else { return }
        outgoing.append(pcm)
        flushOutgoing(force: false)
    }

    /// About 100 ms per message.
    private func flushOutgoing(force: Bool) {
        let chunk = config.inputRate / 10 * 2
        while outgoing.count >= chunk || (force && !outgoing.isEmpty) {
            let n = min(chunk, outgoing.count)
            let piece = outgoing.prefix(n)
            outgoing.removeFirst(n)
            emitAudio(Data(piece))
        }
    }

    private func emitAudio(_ piece: Data) {
        guard ready else {
            held.append(piece)
            heldBytes += piece.count
            // Keep the last 8 s while the service is still saying hello.
            let cap = config.inputRate * 2 * 8
            while heldBytes > cap, !held.isEmpty {
                heldBytes -= held.removeFirst().count
            }
            return
        }
        let type = config.wire == .openai ? "session.input_audio_buffer.append" : "input_audio_buffer.append"
        sendJSON(["type": type, "audio": piece.base64EncodedString()])
    }

    private func becomeReady() {
        guard !ready else { return }
        ready = true
        onEvent(.ready)
        let pending = held
        held.removeAll()
        heldBytes = 0
        for piece in pending { emitAudio(piece) }
        if finishing {
            flushOutgoing(force: true)
            sendFinishMessage()
        }
    }

    // MARK: Finish

    private func beginFinish(timeout: TimeInterval) {
        lastOutputAt = Date()
        if ready { sendFinishMessage() }
        let started = Date()
        func poll() {
            queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, !self.closed else { return }
                let waited = Date().timeIntervalSince(started)
                let quiet = Date().timeIntervalSince(self.lastOutputAt)
                // OpenAI has no end-of-session message. Close once the voice has stopped coming.
                let settled = self.config.wire == .openai && self.ready && quiet >= 2.0 && waited >= 1.5
                if settled || waited >= timeout || (!self.ready && waited >= 2) {
                    self.closeOpenItems()
                    self.closeLocked()
                    return
                }
                poll()
            }
        }
        poll()
    }

    private func sendFinishMessage() {
        guard config.wire == .qwen else { return }
        sendJSON(["type": "session.finish"])
    }

    // MARK: Session setup

    private func sessionUpdate() -> [String: Any] {
        switch config.wire {
        case .openai:
            return [
                "type": "session.update",
                "session": [
                    "audio": [
                        "input": [
                            "transcription": ["model": "gpt-realtime-whisper"],
                            "noise_reduction": ["type": "near_field"],
                        ],
                        "output": ["language": config.target],
                    ],
                ],
            ]
        case .qwen:
            var translation: [String: Any] = ["language": config.target]
            let phrases = Self.keptPhrases(config.terms)
            if !phrases.isEmpty { translation["corpus"] = ["phrases": phrases] }
            let modes = config.audio ? ["text", "audio"] : ["text"]
            let model = config.model.lowercased()
            var session: [String: Any] = ["translation": translation]
            let voice = config.voice.trimmingCharacters(in: .whitespacesAndNewlines)
            if !voice.isEmpty { session["voice"] = voice }
            if model.hasPrefix("qwen3-livetranslate") {
                session["modalities"] = modes
                session["input_audio_format"] = "pcm16"
                session["output_audio_format"] = "pcm24"
                session["input_audio_transcription"] = ["model": "qwen3-asr-flash-realtime"]
            } else if model.hasPrefix("qwen3.5-livetranslate") {
                session["modalities"] = modes
                session["sample_rate"] = 16_000
                session["input_audio_format"] = "pcm"
                session["output_audio_format"] = "pcm"
                session["input_audio_transcription"] = ["model": "qwen3-asr-flash-realtime"]
            } else {
                session["output_modalities"] = modes
            }
            return ["type": "session.update", "session": session]
        }
    }

    /// Only words that read the same in any language, such as names in Latin script, are pinned as-is.
    static func keptPhrases(_ terms: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for raw in terms {
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, term.count <= 40 else { continue }
            let latin = term.unicodeScalars.allSatisfy { $0.isASCII }
            guard latin, term.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else { continue }
            out[term] = term
            if out.count >= 200 { break }
        }
        return out
    }

    // MARK: Events in

    private func handle(_ data: Data) {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        // DashScope rejects a model with a bare `{"code", "message"}` frame and then hangs up.
        guard let type = obj["type"] as? String else {
            if let code = obj["code"] as? String, !code.isEmpty {
                fail(Self.explain(code: code, message: obj["message"] as? String))
            }
            return
        }
        switch type {
        case "session.created":
            sendJSON(sessionUpdate())
        case "session.updated":
            becomeReady()
        case "error":
            let err = obj["error"] as? [String: Any]
            let message = (err?["message"] as? String) ?? (obj["message"] as? String)
            let code = (err?["code"] as? String) ?? (obj["code"] as? String) ?? ""
            fail(Self.explain(code: code, message: message))
        case "session.finished":
            closeOpenItems()
            closeLocked()
        default:
            switch config.wire {
            case .qwen: handleQwen(type, obj)
            case .openai: handleOpenAI(type, obj)
            }
        }
    }

    /// Server codes a person can act on get a sentence. Anything else keeps the service's own words.
    static func explain(code: String, message: String?) -> String {
        let lower = code.lowercased()
        if lower.contains("unpurchased") {
            return L("这个阿里云账号还没开通百炼，所有模型都调不了。用主账号登录百炼控制台，同意协议开通后再试。")
        }
        if lower.hasPrefix("accessdenied") || lower == "model_not_found" {
            return L("这把密钥用不了这个同传模型。到服务商控制台开通该模型，或换一个模型。")
        }
        if lower.contains("invalidapikey") || lower == "invalid_api_key" {
            return L("同传服务拒绝了这个密钥")
        }
        let text = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? (code.isEmpty ? L("同传服务出错") : code) : text
    }

    private func handleQwen(_ type: String, _ obj: [String: Any]) {
        let item = obj["item_id"] as? String ?? ""
        switch type {
        case "input_audio_buffer.speech_started":
            if let raw = obj["speaker_id"] {
                let n = (raw as? Int) ?? Int(String(describing: raw)) ?? -1
                if n >= 0, !item.isEmpty { speakers[item] = n + 1 }
            }
        case "conversation.item.input_audio_transcription.delta":
            guard !item.isEmpty, let delta = obj["delta"] as? String else { return }
            updateSource(item) { $0.confirmed += delta; $0.stash = "" }
        case "conversation.item.input_audio_transcription.text":
            guard !item.isEmpty else { return }
            let text = obj["text"] as? String ?? ""
            let stash = obj["stash"] as? String ?? ""
            updateSource(item) { Self.merge(&$0, text: text, stash: stash) }
        case "conversation.item.input_audio_transcription.completed":
            guard !item.isEmpty else { return }
            let transcript = obj["transcript"] as? String
            updateSource(item) { piece in
                if let transcript, !transcript.isEmpty { piece.confirmed = transcript }
                piece.stash = ""
                piece.final = true
            }
        case "conversation.item.created":
            guard let entry = obj["item"] as? [String: Any],
                  let id = entry["id"] as? String,
                  (entry["role"] as? String) == "assistant" else { return }
            if let previous = obj["previous_item_id"] as? String, !previous.isEmpty {
                targetSource[id] = previous
            }
        case "response.text.delta", "response.audio_transcript.delta":
            guard !item.isEmpty, let delta = obj["delta"] as? String else { return }
            updateTarget(item) { $0.confirmed += delta; $0.stash = "" }
        case "response.text.text", "response.audio_transcript.text":
            guard !item.isEmpty else { return }
            let text = obj["text"] as? String ?? ""
            let stash = obj["stash"] as? String ?? ""
            updateTarget(item) { Self.merge(&$0, text: text, stash: stash) }
        case "response.text.done", "response.audio_transcript.done":
            guard !item.isEmpty else { return }
            let whole = (obj["transcript"] as? String) ?? (obj["text"] as? String)
            updateTarget(item) { piece in
                if let whole, !whole.isEmpty { piece.confirmed = whole }
                piece.stash = ""
                piece.final = true
            }
        case "response.audio.delta":
            guard config.audio, let b64 = obj["delta"] as? String, let pcm = Data(base64Encoded: b64), !pcm.isEmpty else { return }
            lastOutputAt = Date()
            onEvent(.audio(pcm))
        case "response.done":
            if let response = obj["response"] as? [String: Any],
               let status = response["status"] as? String, status == "failed" {
                let details = response["status_details"] as? [String: Any]
                let err = details?["error"] as? [String: Any]
                onEvent(.failed((err?["message"] as? String) ?? L("同传服务出错")))
            }
        default:
            break
        }
    }

    private func handleOpenAI(_ type: String, _ obj: [String: Any]) {
        switch type {
        case "session.input_transcript.delta":
            guard let delta = obj["delta"] as? String, !delta.isEmpty else { return }
            let id = openSource ?? nextID("s")
            openSource = id
            updateSource(id) { $0.confirmed += delta }
            quietSource(id)
        case "session.input_transcript.done":
            guard let id = openSource else { return }
            let whole = obj["transcript"] as? String
            closeSource(id, whole: whole)
        case "session.output_transcript.delta":
            guard let delta = obj["delta"] as? String, !delta.isEmpty else { return }
            let id = openTarget ?? nextID("t")
            if openTarget == nil {
                openTarget = id
                if let source = openSource ?? lastSourceID { targetSource[id] = source }
            }
            updateTarget(id) { $0.confirmed += delta }
            quietTarget(id)
        case "session.output_transcript.done":
            guard let id = openTarget else { return }
            let whole = obj["transcript"] as? String
            closeTarget(id, whole: whole)
        case "session.output_audio.delta":
            guard config.audio, let b64 = obj["delta"] as? String, let pcm = Data(base64Encoded: b64), !pcm.isEmpty else { return }
            // Keep-alive frames are exact zeros. Speech always has some non-zero sample.
            guard pcm.contains(where: { $0 != 0 }) else { return }
            lastOutputAt = Date()
            onEvent(.audio(pcm))
        default:
            break
        }
    }

    private func nextID(_ prefix: String) -> String {
        serial += 1
        return "\(prefix)\(serial)"
    }

    private func quietSource(_ id: String) {
        sourceQuiet?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.closeSource(id, whole: nil) }
        sourceQuiet = work
        queue.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    private func quietTarget(_ id: String) {
        targetQuiet?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.closeTarget(id, whole: nil) }
        targetQuiet = work
        queue.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    private func closeSource(_ id: String, whole: String?) {
        guard openSource == id else { return }
        sourceQuiet?.cancel()
        openSource = nil
        updateSource(id) { piece in
            if let whole, !whole.isEmpty { piece.confirmed = whole }
            piece.final = true
        }
    }

    private func closeTarget(_ id: String, whole: String?) {
        guard openTarget == id else { return }
        targetQuiet?.cancel()
        openTarget = nil
        updateTarget(id) { piece in
            if let whole, !whole.isEmpty { piece.confirmed = whole }
            piece.final = true
        }
    }

    /// Lines still open when the session ends are as final as they will get.
    private func closeOpenItems() {
        if let id = openSource { closeSource(id, whole: nil) }
        if let id = openTarget { closeTarget(id, whole: nil) }
        for (id, piece) in sources where !piece.final {
            updateSource(id) { $0.final = true }
        }
        for (id, piece) in targets where !piece.final {
            updateTarget(id) { $0.final = true }
        }
    }

    /// `text` is either all that is confirmed so far or just the newly confirmed part. Both are seen in the wild.
    private static func merge(_ piece: inout Piece, text: String, stash: String) {
        if !text.isEmpty {
            if text.hasPrefix(piece.confirmed) {
                piece.confirmed = text
            } else if !piece.confirmed.hasSuffix(text) {
                piece.confirmed += text
            }
        }
        piece.stash = stash
    }

    private func updateSource(_ id: String, _ change: (inout Piece) -> Void) {
        var piece = sources[id] ?? Piece()
        guard !piece.final else { return }
        change(&piece)
        sources[id] = piece
        if !piece.text.isEmpty || piece.final { lastSourceID = id }
        onEvent(.source(id: id, text: piece.text, final: piece.final, speaker: speakers[id] ?? 0))
    }

    private func updateTarget(_ id: String, _ change: (inout Piece) -> Void) {
        var piece = targets[id] ?? Piece()
        guard !piece.final else { return }
        change(&piece)
        targets[id] = piece
        lastOutputAt = Date()
        onEvent(.target(id: id, sourceID: targetSource[id], text: piece.text, final: piece.final))
    }
}
