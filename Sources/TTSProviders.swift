import AVFoundation
import Combine
import Foundation
import NaturalLanguage
import SwiftUI

final class SpeechPlayback: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    static let shared = SpeechPlayback()

    @Published private(set) var isSpeaking = false
    @Published private(set) var notice = ""
    /// 正在读的那一段是谁发起的。几个朗读按钮同时在屏上时，只有这一个变成「停止」。
    @Published private(set) var speakingTag: String?
    @Published private(set) var noticeTag: String?
    /// 这次朗读用的一家。空字符串表示用设置里的默认。不写回设置。
    @Published var sessionEngineID = ""
    /// 这一轮指定的声音。`apple:` 用系统语音的某一把，`tts:` 用某一家的某一把。空的走默认。
    private var activeVoiceID = ""

    private let synth = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var queue: [String] = []
    private var token = 0
    private var currentUtterance: AVSpeechUtterance?
    private var activeTicket = 0
    private var activeRequest: TTSRequest?
    private var activeLanguage: String?
    private var onFailure: (() -> Void)?
    private var onFinish: (() -> Void)?
    private var usingApple = false

    override init() {
        super.init()
        synth.delegate = self
    }

    func toggle(_ text: String, languageCode: String?, tag: String? = nil, voiceID: String? = nil) {
        if isSpeaking, speakingTag == tag {
            stop()
            return
        }
        speak(text, languageCode: languageCode, tag: tag, voiceID: voiceID)
    }

    func isSpeaking(tag: String) -> Bool { isSpeaking && speakingTag == tag }

    func notice(tag: String) -> String { noticeTag == tag ? notice : "" }

    func speak(
        _ text: String,
        languageCode: String?,
        tag: String? = nil,
        voiceID: String? = nil,
        onFailure: (() -> Void)? = nil,
        onFinish: (() -> Void)? = nil
    ) {
        stop()
        self.onFailure = onFailure
        self.onFinish = onFinish
        notice = ""
        speakingTag = tag
        noticeTag = tag
        activeVoiceID = voiceID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            self.onFailure = nil
            self.onFinish = nil
            return
        }
        let ticket = token
        if activeVoiceID.hasPrefix("apple:") {
            usingApple = true
            apple(trimmed, languageCode: languageCode, voiceID: String(activeVoiceID.dropFirst("apple:".count)))
            return
        }
        let engineID = Pro.unlocked && !sessionEngineID.isEmpty ? sessionEngineID : AppConfig.shared.ttsSelection
        if engineID == "apple", !activeVoiceID.hasPrefix("tts:") {
            usingApple = true
            apple(trimmed, languageCode: languageCode, voiceID: nil)
            return
        }
        usingApple = false
        let request: TTSRequest
        do {
            if activeVoiceID.hasPrefix("tts:") {
                request = try Self.pinnedRequest(activeVoiceID)
            } else {
                request = try AppConfig.shared.ttsRequest(selection: engineID)
            }
        } catch {
            self.notice = error.localizedDescription
            self.onFinish = nil
            let cb = self.onFailure
            self.onFailure = nil
            cb?()
            return
        }
        queue = TTSText.chunks(trimmed)
        guard !queue.isEmpty else {
            finished()
            return
        }
        activeRequest = request
        activeLanguage = languageCode
        isSpeaking = true
        kick(ticket)
    }

    func stop() {
        token += 1
        queue.removeAll()
        player?.stop()
        player = nil
        currentUtterance = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        if isSpeaking { isSpeaking = false }
        onFailure = nil
        onFinish = nil
        usingApple = false
    }

    /// 同一轮还在读时，把下一段接在后面，不打断已经开口的那句。
    func enqueue(
        _ text: String,
        languageCode: String?,
        tag: String,
        voiceID: String? = nil,
        onFailure: (() -> Void)? = nil,
        onFinish: (() -> Void)? = nil
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let voiceID { activeVoiceID = voiceID.trimmingCharacters(in: .whitespacesAndNewlines) }
        if isSpeaking, speakingTag == tag {
            if let onFailure { self.onFailure = onFailure }
            if let onFinish { self.onFinish = onFinish }
            append(trimmed, languageCode: languageCode)
            return
        }
        speak(trimmed, languageCode: languageCode, tag: tag, voiceID: voiceID, onFailure: onFailure, onFinish: onFinish)
    }

    /// 这一轮读完再叫。没在读就马上叫。
    func whenDone(_ body: @escaping () -> Void) {
        if !isSpeaking {
            body()
            return
        }
        let previous = onFinish
        onFinish = {
            previous?()
            body()
        }
    }

    private func append(_ text: String, languageCode: String?) {
        if usingApple {
            let voice = activeVoiceID.hasPrefix("apple:") ? String(activeVoiceID.dropFirst("apple:".count)) : nil
            let u = utterance(text, languageCode: languageCode, voiceID: voice)
            currentUtterance = u
            isSpeaking = true
            synth.speak(u)
            return
        }
        queue.append(contentsOf: TTSText.chunks(text))
        if !isSpeaking {
            isSpeaking = true
            kick(token)
        }
    }

    private func apple(_ text: String, languageCode: String?, voiceID: String?) {
        let u = utterance(text, languageCode: languageCode, voiceID: voiceID)
        currentUtterance = u
        isSpeaking = true
        synth.speak(u)
    }

    /// 说话人指定的云端音色。服务停用、没填密钥或音色不在名单里，就退回设置里的默认。
    private static func pinnedRequest(_ voiceID: String) throws -> TTSRequest {
        let rest = String(voiceID.dropFirst("tts:".count))
        guard let split = rest.lastIndex(of: ":") else {
            return try AppConfig.shared.ttsRequest()
        }
        let profileID = String(rest[..<split])
        let voice = String(rest[rest.index(after: split)...])
        guard let profile = AppConfig.shared.ttsProfiles.first(where: { $0.id == profileID && $0.enabled }),
              let preset = TTSPresetDef.find(profile.preset) else {
            return try AppConfig.shared.ttsRequest()
        }
        var request = try AppConfig.shared.ttsRequest(selection: profileID)
        // 音色空着：用设置里这一家现在填的那把，改设置之后跟着变。
        if !voice.isEmpty, preset.voices.contains(where: { $0.id == voice }) {
            request.voice = voice
        }
        return request
    }

    private func utterance(_ text: String, languageCode: String?, voiceID: String? = nil) -> AVSpeechUtterance {
        let u = AVSpeechUtterance(string: text)
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        u.volume = 1
        if let voiceID, !voiceID.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: voiceID) {
            u.voice = voice
            return u
        }
        if let code = languageCode, !code.isEmpty {
            u.voice = AVSpeechSynthesisVoice(language: code)
                ?? AVSpeechSynthesisVoice(language: String(code.prefix(2)))
                ?? AVSpeechSynthesisVoice(language: Locale.current.identifier)
        } else {
            u.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier)
        }
        return u
    }

    private func kick(_ ticket: Int) {
        guard ticket == token else { return }
        guard let request = activeRequest, !queue.isEmpty else {
            if ticket == token { finished() }
            return
        }
        let piece = queue.removeFirst()
        let language = activeLanguage
        Task {
            do {
                let data = try await TTSEngine.synthesize(text: piece, request: request, languageCode: language)
                DispatchQueue.main.async {
                    guard ticket == self.token else { return }
                    self.play(data, ticket: ticket)
                }
            } catch {
                DispatchQueue.main.async {
                    guard ticket == self.token else { return }
                    self.fail(error)
                }
            }
        }
    }

    private func play(_ data: Data, ticket: Int) {
        do {
            let p = try AVAudioPlayer(data: data)
            p.delegate = self
            player = p
            activeTicket = ticket
            guard p.play() else { throw TErr(L("无法播放语音")) }
        } catch {
            fail(error)
        }
    }

    private func fail(_ error: Error) {
        token += 1
        queue.removeAll()
        player?.stop()
        player = nil
        isSpeaking = false
        notice = error.localizedDescription
        onFinish = nil
        let cb = onFailure
        onFailure = nil
        cb?()
    }

    private func finished() {
        isSpeaking = false
        let done = onFinish
        onFinish = nil
        done?()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            guard utterance === self.currentUtterance else { return }
            self.isSpeaking = true
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            guard utterance === self.currentUtterance else { return }
            if self.synth.isSpeaking { return }
            self.currentUtterance = nil
            self.finished()
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            guard utterance === self.currentUtterance else { return }
            self.currentUtterance = nil
            self.isSpeaking = false
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            guard self.activeTicket == self.token else { return }
            if !flag {
                self.fail(TErr(L("无法播放语音")))
                return
            }
            self.kick(self.token)
        }
    }
}

/// 一个说话人可以指定的一把声音。系统语音按正在读的语言列；云端音色属于已启用的那一家，每种语言都列。
struct SpeakerVoice: Identifiable, Equatable {
    /// `apple:<voice identifier>`，或 `tts:<profile id>:<voice>`。
    var id: String
    var name: String
    /// 这把声音属于哪一家。系统语音为空。
    var service: String

    /// `language` 是 BCP-47。系统语音在前，然后是每一家已启用、列了音色的服务。
    @MainActor
    static func choices(language: String?) -> [SpeakerVoice] {
        var out: [SpeakerVoice] = []
        let code = TTSLang.bcp47(language) ?? Locale.current.identifier
        let voices = AVSpeechSynthesisVoice.speechVoices()
            .filter { TTSLang.same($0.language, code) }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        for voice in voices {
            out.append(SpeakerVoice(id: "apple:\(voice.identifier)", name: voice.name, service: ""))
        }
        for profile in AppConfig.shared.ttsProfiles where profile.enabled {
            guard let preset = TTSPresetDef.find(profile.preset), preset.voices.isEmpty == false || preset.wire == .deepgram else { continue }
            let service = profile.name.isEmpty ? preset.name : profile.name
            let current = settingsVoiceName(profile)
            out.append(SpeakerVoice(
                id: "tts:\(profile.id):",
                name: current.isEmpty ? L("设置里的音色") : String(format: L("设置里的（%@）"), current),
                service: service
            ))
            for voice in preset.voices {
                out.append(SpeakerVoice(
                    id: "tts:\(profile.id):\(voice.id)",
                    name: voice.name,
                    service: service
                ))
            }
        }
        return out
    }

    /// 这一家在设置里填的那把。Deepgram 的音色写在模型上。
    @MainActor
    static func settingsVoiceName(_ profile: TTSProfile) -> String {
        let preset = TTSPresetDef.find(profile.preset)
        let voice = profile.voice.trimmingCharacters(in: .whitespacesAndNewlines)
        if !voice.isEmpty {
            return preset?.voices.first { $0.id == voice }?.name ?? voice
        }
        if preset?.wire == .deepgram {
            let model = profile.model.trimmingCharacters(in: .whitespacesAndNewlines)
            return model.isEmpty ? (preset?.model ?? "") : model
        }
        let fallback = preset?.voice ?? ""
        guard !fallback.isEmpty else { return "" }
        return preset?.voices.first { $0.id == fallback }?.name ?? fallback
    }

    /// 「默认」现在实际用的那把。是云端服务时写出设置里的音色。
    @MainActor
    static func defaultTitle() -> String {
        let id = AppConfig.shared.ttsSelection
        guard id != "apple",
              let profile = AppConfig.shared.ttsProfiles.first(where: { $0.id == id && $0.enabled }) else {
            return L("默认")
        }
        let name = settingsVoiceName(profile)
        guard !name.isEmpty else { return L("默认") }
        return String(format: L("默认（%@）"), name)
    }

    /// 存下来的那一把现在叫什么。这台 Mac 上没有，或那一家停用了，就为空。
    @MainActor
    static func title(for id: String) -> String? {
        if id.hasPrefix("apple:") {
            let identifier = String(id.dropFirst("apple:".count))
            return AVSpeechSynthesisVoice(identifier: identifier)?.name
        }
        guard id.hasPrefix("tts:") else { return nil }
        let rest = String(id.dropFirst("tts:".count))
        guard let split = rest.lastIndex(of: ":") else { return nil }
        let profileID = String(rest[..<split])
        let voiceID = String(rest[rest.index(after: split)...])
        guard let profile = AppConfig.shared.ttsProfiles.first(where: { $0.id == profileID && $0.enabled }),
              let preset = TTSPresetDef.find(profile.preset) else { return nil }
        let service = profile.name.isEmpty ? preset.name : profile.name
        if voiceID.isEmpty {
            let name = settingsVoiceName(profile)
            let label = name.isEmpty ? L("设置里的音色") : String(format: L("设置里的（%@）"), name)
            return "\(service) · \(label)"
        }
        guard let voice = preset.voices.first(where: { $0.id == voiceID }) else { return nil }
        return "\(service) · \(voice.name)"
    }
}

/// 朗读按钮。`language` 是 BCP-47 代码；给空或「自动」时按文本猜。
struct SpeakButton: View {
    @ObservedObject private var speech = SpeechPlayback.shared
    let text: String
    var language: String? = nil
    var help: String = L("朗读译文")
    var tag: String? = nil
    /// 这一位指定的声音。空的用默认。
    var voiceID: String? = nil
    var size: CGFloat = 11

    private var key: String { tag ?? text }

    var body: some View {
        let playing = speech.isSpeaking(tag: key)
        let notice = speech.notice(tag: key)
        let helpText = notice.isEmpty ? (playing ? L("停止朗读") : help) : notice
        let tint: Color? = notice.isEmpty ? (playing ? .accentColor : nil) : .orange
        let toggle = {
            let plain = MarkdownTextUtil.plain(text).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !plain.isEmpty else { return }
            speech.toggle(
                plain,
                languageCode: SpeakLanguage.code(for: plain, hint: language),
                tag: key,
                voiceID: voiceID
            )
        }
        Group {
            if playing {
                IconButton(icon: .stop, help: helpText, tint: tint, size: size, action: toggle)
            } else {
                IconButton(icon: .spk, help: helpText, tint: tint, size: size, action: toggle)
            }
        }
        .contextMenu {
            if Pro.unlocked {
                ForEach(AppConfig.shared.enabledTTSChoices()) { choice in
                    Button(choice.name) {
                        speech.sessionEngineID = choice.id == AppConfig.shared.ttsSelection ? "" : choice.id
                    }
                }
            }
        }
    }
}

enum SpeakLanguage {
    /// 先用给定的语言，没有就用检测到的源语言，再不行按文本猜。
    static func code(for text: String, hint: String?) -> String? {
        if let hint, !hint.isEmpty, hint.lowercased() != "auto" { return hint }
        let sample = String(text.prefix(2000))
        if let detected = Lang.detectSource(sample).code, !detected.isEmpty { return detected }
        return NLLanguageRecognizer.dominantLanguage(for: sample)?.rawValue
    }
}
