import AppKit
import SwiftUI

/// 体验步的真实动作探针。
///
/// 引导里的五项都不再「替用户做一遍」。每项只摆出素材，等用户真的按了快捷键、
/// 真的说了话，由功能自己的那一侧把结果交回来，这一层只负责记下来。
///
/// 探针按项单独挂：只有引导停在这一项、而且这一项的素材已经摆好时才收，
/// 别处正常使用功能不会被记进来。
@MainActor
final class OnboardingTryBridge: ObservableObject {
    static let shared = OnboardingTryBridge()

    /// 现在等的是哪一项。nil 表示没在等。
    @Published private(set) var waiting: OnboardingTry?
    /// 等到的结果。换一项就清掉。
    @Published private(set) var landed: Landed?
    /// 用户已经动手、还没结果。摆素材时清掉。
    @Published private(set) var touched = false

    struct Landed: Equatable {
        /// 识别或抓到的原文。快捷翻译和语音可能和素材不完全一致，照实显示。
        var source: String
        /// 译文。截图的 OCR 交回原文时这里是空的，由引导自己补翻。
        var translation: String?
    }

    /// 这一项开始等。`clear` 为假时保留上一轮的结果（重读同一项不闪）。
    func arm(_ item: OnboardingTry) {
        waiting = item
        landed = nil
        touched = false
    }

    func disarm() {
        waiting = nil
    }

    /// 用户已经动手。比结果先到：语音开始听、截图开始框，都能立刻给个回音。
    func noteTouched(_ item: OnboardingTry) {
        guard waiting == item else { return }
        touched = true
    }

    /// 功能那一侧做完了，把原文和译文交回来。不在等的项直接丢掉。
    func land(_ item: OnboardingTry, source: String, translation: String? = nil) {
        guard waiting == item else { return }
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        touched = true
        landed = Landed(
            source: trimmed,
            translation: translation?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

/// 探针的静态入口，给非 SwiftUI 的那几处功能调用，免得每处都写 MainActor 跳转。
@MainActor
enum TryProbe {
    /// 功能做完了。主线程上调用。
    static func land(_ item: OnboardingTry, source: String, translation: String? = nil) {
        let bridge = OnboardingTryBridge.shared
        guard bridge.waiting == item else { return }
        bridge.land(item, source: source, translation: translation)
    }

    /// 用户已经动手（开始听、开始框选）。
    static func touched(_ item: OnboardingTry) {
        let bridge = OnboardingTryBridge.shared
        guard bridge.waiting == item else { return }
        bridge.noteTouched(item)
    }

    /// 翻译回执里的 kind 折回体验项。别的 kind 引导不管。
    static func item(forKind kind: String) -> OnboardingTry? {
        switch kind {
        case "select": return .select
        case "ocr": return .screenshot
        case "quick": return .quick
        default: return nil
        }
    }

    /// 引导眼下是不是正停在这一项。功能侧要改变自己行为时先问一句。
    static func waiting(_ item: OnboardingTry) -> Bool {
        OnboardingTryBridge.shared.waiting == item
    }
}

// MARK: - 例句

/// 一种语言的一套素材。
///
/// 五句话各管一段：开会、延误、订票、对话问句、对话答句。母语和目标语言各取一套，
/// 任意一对组合都拼得出「读到外文」「写成外文」「听完出字幕」这三段像样的材料，
/// 不必为每一对组合各写一遍。句子里不放专有名词，翻过去也不会走样。
struct OnboardingLines {
    var meet: String
    var flight: String
    var ticket: String
    var ask: String
    var answer: String
    /// `say` 的读音名。没有合适的声音时留空，用系统默认。
    var voice: String
    /// 听写和字幕用的识别语言，给 `ASRLanguage` 用。
    var speech: String
}

/// 内置例句。按语言各写一份，这里直接写死，不走翻译，也不进语言包。
struct OnboardingSamples {
    var native: OnboardingLines
    var target: OnboardingLines

    /// 读到外文：目标语言写的原文，译成母语。
    var readForeign: String { target.meet }
    var readNative: String { native.meet }
    /// 写成外文：母语写的原文，译成目标语言。
    var writeNative: String { native.ticket }
    var writeForeign: String { target.ticket }
    /// 截图卡里的两句目标语言。字号大、句子短，框住就能认全。
    var demoForeign: String { target.flight }
    var demoNative: String { native.flight }
    /// 快捷翻译框里预填的一句母语，翻成目标语言。
    var sayNative: String { native.ticket }
    var sayForeign: String { target.ticket }
    /// 语音那关要读的一句。用母语写，识别语言跟着母语走，读出来就认得准。
    var speakNative: String { native.flight }
    var speakForeign: String { target.flight }
    /// 会议字幕的两人对话。两句一段，念完正好五六秒。
    var meetFirst: String { target.ask }
    var meetSecond: String { target.answer }
    var meetFirstNative: String { native.ask }
    var meetSecondNative: String { native.answer }

    static func pair(native: TargetLanguage, target: TargetLanguage) -> OnboardingSamples {
        OnboardingSamples(native: lines(native), target: lines(target))
    }

    static func lines(_ language: TargetLanguage) -> OnboardingLines {
        switch language {
        case .zhHans:
            return OnboardingLines(
                meet: "会议改到周四了。",
                flight: "航班因为暴风雨延误了两个小时。",
                ticket: "帮我订一张明天早上去上海的高铁票。",
                ask: "你好，周四还照常吗？",
                answer: "照常，不过房间换到五楼了。",
                voice: "Tingting",
                speech: "zh-CN"
            )
        case .zhHant:
            return OnboardingLines(
                meet: "會議改到週四了。",
                flight: "航班因為暴風雨延誤了兩個小時。",
                ticket: "幫我訂一張明天早上去上海的高鐵票。",
                ask: "你好，週四還照常嗎？",
                answer: "照常，不過房間換到五樓了。",
                voice: "Meijia",
                speech: "zh-TW"
            )
        case .en:
            return OnboardingLines(
                meet: "The meeting has been moved to Thursday.",
                flight: "Our flight was delayed by two hours because of the storm.",
                ticket: "Book me a high-speed train ticket to Shanghai tomorrow morning.",
                ask: "Hi, are we still on for Thursday?",
                answer: "Yes, but the room changed to the fifth floor.",
                voice: "Samantha",
                speech: "en-US"
            )
        case .ja:
            return OnboardingLines(
                meet: "会議は木曜日に変更になりました。",
                flight: "嵐で便が二時間遅れました。",
                ticket: "明日の朝、上海行きの新幹線の切符を一枚予約してください。",
                ask: "木曜日の件ですが、まだ大丈夫ですか。",
                answer: "はい、ただ部屋が五階に変わりました。",
                voice: "Kyoko",
                speech: "ja-JP"
            )
        case .ko:
            return OnboardingLines(
                meet: "회의가 목요일로 바뀌었습니다.",
                flight: "폭풍 때문에 항공편이 두 시간 지연됐습니다.",
                ticket: "내일 아침 상하이행 고속열차 표를 한 장 예약해 주세요.",
                ask: "목요일 약속 그대로인가요?",
                answer: "네, 다만 방이 5층으로 바뀌었습니다.",
                voice: "Yuna",
                speech: "ko-KR"
            )
        case .fr:
            return OnboardingLines(
                meet: "La réunion a été déplacée à jeudi.",
                flight: "Notre vol a été retardé de deux heures à cause de la tempête.",
                ticket: "Réservez-moi un billet de TGV pour Shanghai demain matin.",
                ask: "Bonjour, on maintient jeudi ?",
                answer: "Oui, mais la salle est au cinquième étage.",
                voice: "Thomas",
                speech: "fr-FR"
            )
        case .de:
            return OnboardingLines(
                meet: "Das Meeting wurde auf Donnerstag verschoben.",
                flight: "Unser Flug hat sich wegen des Sturms um zwei Stunden verspätet.",
                ticket: "Buchen Sie mir bitte für morgen früh einen Zug nach Shanghai.",
                ask: "Hallo, bleibt es beim Donnerstag?",
                answer: "Ja, aber der Raum ist jetzt im fünften Stock.",
                voice: "Anna",
                speech: "de-DE"
            )
        case .es:
            return OnboardingLines(
                meet: "La reunión se ha pasado al jueves.",
                flight: "Nuestro vuelo se retrasó dos horas por la tormenta.",
                ticket: "Resérvame un billete de tren de alta velocidad a Shanghái para mañana por la mañana.",
                ask: "Hola, ¿seguimos en pie para el jueves?",
                answer: "Sí, pero la sala cambió al quinto piso.",
                voice: "Mónica",
                speech: "es-ES"
            )
        case .ru:
            return OnboardingLines(
                meet: "Встречу перенесли на четверг.",
                flight: "Наш рейс задержали на два часа из-за шторма.",
                ticket: "Забронируйте мне билет на скоростной поезд до Шанхая на завтра утром.",
                ask: "Здравствуйте, четверг в силе?",
                answer: "Да, только комната теперь на пятом этаже.",
                voice: "Milena",
                speech: "ru-RU"
            )
        case .pt:
            return OnboardingLines(
                meet: "A reunião passou para quinta-feira.",
                flight: "O nosso voo atrasou duas horas por causa da tempestade.",
                ticket: "Reserve-me um bilhete de comboio para Xangai amanhã de manhã.",
                ask: "Olá, mantemos a quinta-feira?",
                answer: "Sim, mas a sala passou para o quinto andar.",
                voice: "Joana",
                speech: "pt-PT"
            )
        case .it:
            return OnboardingLines(
                meet: "La riunione è stata spostata a giovedì.",
                flight: "Il nostro volo è stato ritardato di due ore per la tempesta.",
                ticket: "Prenotami un biglietto dell'alta velocità per Shanghai domani mattina.",
                ask: "Ciao, confermiamo giovedì?",
                answer: "Sì, ma la sala è al quinto piano.",
                voice: "Alice",
                speech: "it-IT"
            )
        case .vi:
            return OnboardingLines(
                meet: "Cuộc họp đã dời sang thứ Năm.",
                flight: "Chuyến bay của chúng tôi bị hoãn hai tiếng vì bão.",
                ticket: "Đặt giúp tôi một vé tàu cao tốc đi Thượng Hải sáng mai.",
                ask: "Chào anh, thứ Năm vẫn như cũ chứ?",
                answer: "Vẫn vậy, chỉ là phòng đổi sang tầng năm.",
                voice: "Linh",
                speech: "vi-VN"
            )
        case .th:
            return OnboardingLines(
                meet: "เลื่อนประชุมไปเป็นวันพฤหัสบดีแล้ว",
                flight: "เที่ยวบินของเราล่าช้าสองชั่วโมงเพราะพายุ",
                ticket: "จองตั๋วรถไฟความเร็วสูงไปเซี่ยงไฮ้พรุ่งนี้เช้าให้หน่อย",
                ask: "สวัสดี วันพฤหัสบดียังได้เหมือนเดิมไหม",
                answer: "ได้ครับ แต่ห้องเปลี่ยนไปอยู่ชั้นห้า",
                voice: "Kanya",
                speech: "th-TH"
            )
        case .id:
            return OnboardingLines(
                meet: "Rapatnya dipindah ke hari Kamis.",
                flight: "Penerbangan kami tertunda dua jam karena badai.",
                ticket: "Pesankan saya tiket kereta cepat ke Shanghai besok pagi.",
                ask: "Halo, hari Kamis jadi ya?",
                answer: "Jadi, tapi ruangannya pindah ke lantai lima.",
                voice: "Damayanti",
                speech: "id-ID"
            )
        case .ar:
            return OnboardingLines(
                meet: "تم تأجيل الاجتماع إلى يوم الخميس.",
                flight: "تأخرت رحلتنا ساعتين بسبب العاصفة.",
                ticket: "احجز لي تذكرة قطار سريع إلى شنغهاي صباح الغد.",
                ask: "مرحبًا، هل ما زال الموعد يوم الخميس؟",
                answer: "نعم، لكن القاعة انتقلت إلى الطابق الخامس.",
                voice: "Majed",
                speech: "ar-SA"
            )
        case .hi:
            return OnboardingLines(
                meet: "मीटिंग अब गुरुवार को है।",
                flight: "तूफ़ान की वजह से हमारी उड़ान दो घंटे लेट हो गई।",
                ticket: "कल सुबह शंघाई के लिए हाई-स्पीड ट्रेन की टिकट बुक कर दीजिए।",
                ask: "नमस्ते, गुरुवार का कार्यक्रम वैसा ही है?",
                answer: "हाँ, बस कमरा पाँचवीं मंज़िल पर आ गया है।",
                voice: "Lekha",
                speech: "hi-IN"
            )
        case .tr:
            return OnboardingLines(
                meet: "Toplantı perşembeye alındı.",
                flight: "Fırtına yüzünden uçuşumuz iki saat rötar yaptı.",
                ticket: "Yarın sabah Şanghay'a hızlı tren bileti alır mısınız?",
                ask: "Merhaba, perşembe hâlâ geçerli mi?",
                answer: "Evet, ama oda beşinci kata taşındı.",
                voice: "Yelda",
                speech: "tr-TR"
            )
        case .nl:
            return OnboardingLines(
                meet: "De vergadering is verplaatst naar donderdag.",
                flight: "Onze vlucht had twee uur vertraging door de storm.",
                ticket: "Boek een hogesnelheidstrein naar Sjanghai voor morgenochtend.",
                ask: "Hallo, gaat donderdag door?",
                answer: "Ja, maar de zaal is verhuisd naar de vijfde verdieping.",
                voice: "Xander",
                speech: "nl-NL"
            )
        case .pl:
            return OnboardingLines(
                meet: "Spotkanie przeniesiono na czwartek.",
                flight: "Nasz lot był opóźniony o dwie godziny z powodu burzy.",
                ticket: "Zarezerwuj mi bilet na pociąg do Szanghaju na jutro rano.",
                ask: "Dzień dobry, czwartek nadal aktualny?",
                answer: "Tak, tylko sala zmieniła się na piąte piętro.",
                voice: "Zosia",
                speech: "pl-PL"
            )
        case .sv:
            return OnboardingLines(
                meet: "Mötet har flyttats till torsdag.",
                flight: "Vårt flyg blev två timmar försenat på grund av stormen.",
                ticket: "Boka en snabbtågsbiljett till Shanghai i morgon bitti åt mig.",
                ask: "Hej, gäller torsdag fortfarande?",
                answer: "Ja, men rummet har flyttats till femte våningen.",
                voice: "Alva",
                speech: "sv-SE"
            )
        case .auto:
            return lines(.en)
        }
    }
}

// MARK: - 五关的当场状态

/// 一关的当场状态。等于「这一刻该看见什么」，不管是谁把那句话送出来的。
@MainActor
final class OnboardingTryStage: ObservableObject {
    /// 用户已经动手，结果还没回来。
    @Published private(set) var working = false
    /// 会议字幕正在念。按「停止」能打断。
    @Published private(set) var playing = false
    /// 语音正在听。
    @Published private(set) var hearing = false
    /// 当场翻出来的结果。和探针交回的东西分开：探针只认功能那一侧，这一层只补翻。
    @Published var source = ""
    @Published var translation: String?
    @Published var error: String?
    private var task: Task<Void, Never>?

    func reset() {
        task?.cancel()
        task = nil
        working = false
        playing = false
        hearing = false
        source = ""
        translation = nil
        error = nil
    }

    func begin(_ work: @escaping @MainActor (OnboardingTryStage) async -> Void) {
        task?.cancel()
        working = true
        error = nil
        task = Task { @MainActor in
            await work(self)
            guard !Task.isCancelled else { return }
            self.working = false
        }
    }

    func set(playing: Bool, hearing: Bool) {
        self.playing = playing
        self.hearing = hearing
    }

    func stop() {
        task?.cancel()
        task = nil
        working = false
        playing = false
        hearing = false
    }
}

extension OnboardingTryStage {
    /// 就地翻译。划词、截图、会议字幕翻成母语；快捷翻译、语音翻成目标语言。
    /// 用这个功能平时用的那几家，不打开浮层，也不写回任何地方。
    static func translate(
        _ text: String,
        writing: Bool,
        into stage: OnboardingTryStage
    ) async {
        let cfg = AppConfig.shared
        let targets = writing
            ? (cfg.dictateTranslateTarget().map { [$0] } ?? [])
            : cfg.selectTranslateTargets(bundleID: nil)
        let picked = targets.isEmpty ? Array(cfg.catalogTargets().prefix(1)) : targets
        guard !picked.isEmpty else {
            stage.error = L("还没有可用的翻译服务")
            return
        }
        let language = writing ? cfg.targetLanguage.resolvedDestination : cfg.nativeLanguage
        let plan = Lang.plan(text, target: language, mutual: false)
        let result = await Translator.translateAll(text, targets: picked, plan: plan)
        guard !Task.isCancelled else { return }
        if let out = result.outcomes.first(where: { ($0.text ?? "").isEmpty == false })?.text {
            stage.translation = out
        } else {
            stage.error = result.outcomes.first?.error ?? L("没有翻译结果")
        }
    }
}

// MARK: - 划词那关的素材

/// 可选中、可复制的纯文本块。
///
/// 划词那关要让用户在引导自己的窗口里划一段字。SwiftUI 的 `textSelection` 在
/// 非激活态、嵌在滚动视图里的表现各不相同，⌘C 不一定送到手上；这里直接放一个
/// 只读的 `NSTextView`，拖选、⌘C 都和别的 App 里一样。
struct SelectableText: NSViewRepresentable {
    var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        view.string = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.string != text { view.string = text }
    }
}

// MARK: - 会议字幕那关的对话

/// 把一段双人对话念出来。
///
/// 实时字幕听不到本进程发出的声音（`excludesCurrentProcessAudio`），所以对话必须由
/// 外面的进程念：`say` 先合成两个文件，`afplay` 再按顺序放。`say` 的读音名不保证
/// 每台机器都装了，装不上就退回系统默认声音，念的是同一句话。
@MainActor
final class DialoguePlayer {
    private var running: Process?
    private var cancelled = false

    var isPlaying: Bool { running?.isRunning ?? false }

    /// 念两句。返回时两段都放完了，或者被停了。
    func play(first: String, second: String, lines: OnboardingLines) async {
        cancelled = false
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("korgino-try-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let a = dir.appendingPathComponent("a.aiff")
        let b = dir.appendingPathComponent("b.aiff")
        // 两句音高差一点，听着才像两个人在说话。第二句慢一点、低一点。
        guard await say(first, into: a, voice: lines.voice, pitch: nil, rate: 172),
              !cancelled,
              await say(second, into: b, voice: lines.voice, pitch: 48, rate: 162),
              !cancelled else { return }
        // afplay 一次只认一个文件，两句得分开放。
        for file in [a, b] {
            guard !cancelled, await run("/usr/bin/afplay", [file.path]) == 0 else { return }
        }
    }

    func stop() {
        cancelled = true
        running?.terminate()
        running = nil
    }

    /// 合成一段。带音高时用 `[[pbas n]]` 标记，半音数，负数是压低。
    private func say(
        _ text: String,
        into url: URL,
        voice: String,
        pitch: Int?,
        rate: Int
    ) async -> Bool {
        let spoken = pitch.map { "[[pbas \($0)]]" + text } ?? text
        var args = ["-r", "\(rate)", "-o", url.path]
        if !voice.isEmpty { args.insert(contentsOf: ["-v", voice], at: 0) }
        args.append(spoken)
        if await run("/usr/bin/say", args) == 0,
           FileManager.default.fileExists(atPath: url.path) {
            return true
        }
        // 这台机器没有那个读音名：换成系统默认再念一遍，话还是同一句。
        guard !voice.isEmpty else { return false }
        let plain = ["-r", "\(rate)", "-o", url.path, spoken]
        return await run("/usr/bin/say", plain) == 0
            && FileManager.default.fileExists(atPath: url.path)
    }

    /// 跑外面的进程，等它退出。被终止也算退出。记在 `running` 上，停止时才掐得掉。
    private func run(_ tool: String, _ args: [String]) async -> Int32 {
        await withCheckedContinuation { cont in
            let process = Process()
            running = process
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = args
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { done in
                cont.resume(returning: done.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                cont.resume(returning: -1)
            }
        }
    }
}
