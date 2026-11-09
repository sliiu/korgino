import Foundation

/// 全局快捷键的数据部分。两边共用：Mac 用 Carbon 的键码和修饰位，
/// Windows 的键码就是同一个虚拟键号，修饰位也照搬 Carbon 的数值。
/// 只在界面上挂的东西（NSMenuItem、NSEvent）留在 Sources/Hotkey.swift。
///
/// 键码表写数值而不是引用 Carbon 常量，Engine 才能不 import AppKit。
/// 常量值来自 Carbon/HIToolbox/Events.h，改动时请对照该头文件。
struct HotkeySpec: Equatable, Codable, Hashable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    // Carbon modifier bits: cmdKey 256, shiftKey 512, optionKey 2048, controlKey 4096
    private static let control: UInt32 = 4096
    private static let option: UInt32 = 2048
    private static let shift: UInt32 = 512
    private static let command: UInt32 = 256

    static let selectDefault = HotkeySpec(keyCode: Key.d, carbonModifiers: option)
    static let clipboardDefault = HotkeySpec(keyCode: Key.v, carbonModifiers: option | shift)
    static let ocrDefault = HotkeySpec(keyCode: Key.d, carbonModifiers: option | shift)
    static let fileDefault = HotkeySpec(keyCode: Key.f, carbonModifiers: option | shift)
    static let liveCaptionsDefault = HotkeySpec(keyCode: Key.c, carbonModifiers: option | shift)
    static let mediaCaptionsDefault = HotkeySpec(keyCode: Key.m, carbonModifiers: option | shift)
    static let dictionaryDefault = HotkeySpec(keyCode: Key.y, carbonModifiers: option | shift)
    static let historyDefault = HotkeySpec(keyCode: Key.h, carbonModifiers: option | shift)
    /// 连按三下空格。没有修饰键，不走 Carbon 热键。
    static let quickTranslateDefault = HotkeySpec(keyCode: Key.space, carbonModifiers: 0)
    static let quickUndoDefault = HotkeySpec(keyCode: Key.z, carbonModifiers: option)
    static let voiceRecognizeDefault = HotkeySpec(keyCode: Key.r, carbonModifiers: option | shift)
    static let voiceTranslateDefault = HotkeySpec(keyCode: Key.t, carbonModifiers: option | shift)
    static let voiceInterpretDefault = HotkeySpec(keyCode: Key.s, carbonModifiers: option | shift)
    /// 打开主窗口。默认 ⌥⌘K。
    static let openMainDefault = HotkeySpec(keyCode: Key.k, carbonModifiers: option | command)

    /// Carbon 虚拟键码。
    enum Key {
        static let a: UInt32 = 0x00
        static let s: UInt32 = 0x01
        static let d: UInt32 = 0x02
        static let f: UInt32 = 0x03
        static let h: UInt32 = 0x04
        static let g: UInt32 = 0x05
        static let z: UInt32 = 0x06
        static let x: UInt32 = 0x07
        static let c: UInt32 = 0x08
        static let v: UInt32 = 0x09
        static let b: UInt32 = 0x0B
        static let q: UInt32 = 0x0C
        static let w: UInt32 = 0x0D
        static let e: UInt32 = 0x0E
        static let r: UInt32 = 0x0F
        static let y: UInt32 = 0x10
        static let t: UInt32 = 0x11
        static let one: UInt32 = 0x12
        static let two: UInt32 = 0x13
        static let three: UInt32 = 0x14
        static let four: UInt32 = 0x15
        static let six: UInt32 = 0x16
        static let five: UInt32 = 0x17
        static let equal: UInt32 = 0x18
        static let nine: UInt32 = 0x19
        static let seven: UInt32 = 0x1A
        static let minus: UInt32 = 0x1B
        static let eight: UInt32 = 0x1C
        static let zero: UInt32 = 0x1D
        static let rightBracket: UInt32 = 0x1E
        static let o: UInt32 = 0x1F
        static let u: UInt32 = 0x20
        static let leftBracket: UInt32 = 0x21
        static let i: UInt32 = 0x22
        static let p: UInt32 = 0x23
        static let ret: UInt32 = 0x24
        static let l: UInt32 = 0x25
        static let j: UInt32 = 0x26
        static let quote: UInt32 = 0x27
        static let k: UInt32 = 0x28
        static let semicolon: UInt32 = 0x29
        static let backslash: UInt32 = 0x2A
        static let comma: UInt32 = 0x2B
        static let slash: UInt32 = 0x2C
        static let n: UInt32 = 0x2D
        static let m: UInt32 = 0x2E
        static let period: UInt32 = 0x2F
        static let tab: UInt32 = 0x30
        static let space: UInt32 = 0x31
        static let grave: UInt32 = 0x32
        static let delete: UInt32 = 0x33
        static let escape: UInt32 = 0x35
        static let forwardDelete: UInt32 = 0x75
        static let leftArrow: UInt32 = 0x7B
        static let rightArrow: UInt32 = 0x7C
        static let downArrow: UInt32 = 0x7D
        static let upArrow: UInt32 = 0x7E
        static let f1: UInt32 = 0x7A
        static let f2: UInt32 = 0x78
        static let f3: UInt32 = 0x63
        static let f4: UInt32 = 0x76
        static let f5: UInt32 = 0x60
        static let f6: UInt32 = 0x61
        static let f7: UInt32 = 0x62
        static let f8: UInt32 = 0x64
        static let f9: UInt32 = 0x65
        static let f10: UInt32 = 0x6D
        static let f11: UInt32 = 0x67
        static let f12: UInt32 = 0x6F
    }

    var isBareSpace: Bool { keyCode == Key.space && carbonModifiers == 0 }

    var display: String { keys.joined() }

    /// 修饰键和主键分开，设置里按菜单栏那样逐个排开。
    var keys: [String] {
        if isBareSpace { return [L("空格"), "×3"] }
        var k: [String] = []
        if carbonModifiers & Self.control != 0 { k.append("⌃") }
        if carbonModifiers & Self.option != 0 { k.append("⌥") }
        if carbonModifiers & Self.shift != 0 { k.append("⇧") }
        if carbonModifiers & Self.command != 0 { k.append("⌘") }
        k.append(Self.keyName(keyCode))
        return k
    }

    static func keyName(_ code: UInt32) -> String {
        switch code {
        case Key.a: return "A"
        case Key.b: return "B"
        case Key.c: return "C"
        case Key.d: return "D"
        case Key.e: return "E"
        case Key.f: return "F"
        case Key.g: return "G"
        case Key.h: return "H"
        case Key.i: return "I"
        case Key.j: return "J"
        case Key.k: return "K"
        case Key.l: return "L"
        case Key.m: return "M"
        case Key.n: return "N"
        case Key.o: return "O"
        case Key.p: return "P"
        case Key.q: return "Q"
        case Key.r: return "R"
        case Key.s: return "S"
        case Key.t: return "T"
        case Key.u: return "U"
        case Key.v: return "V"
        case Key.w: return "W"
        case Key.x: return "X"
        case Key.y: return "Y"
        case Key.z: return "Z"
        case Key.zero: return "0"
        case Key.one: return "1"
        case Key.two: return "2"
        case Key.three: return "3"
        case Key.four: return "4"
        case Key.five: return "5"
        case Key.six: return "6"
        case Key.seven: return "7"
        case Key.eight: return "8"
        case Key.nine: return "9"
        case Key.space: return L("空格")
        case Key.ret: return "↩"
        case Key.escape: return "⎋"
        case Key.tab: return "⇥"
        case Key.delete: return "⌫"
        case Key.forwardDelete: return "⌦"
        case Key.leftArrow: return "←"
        case Key.rightArrow: return "→"
        case Key.upArrow: return "↑"
        case Key.downArrow: return "↓"
        case Key.f1: return "F1"
        case Key.f2: return "F2"
        case Key.f3: return "F3"
        case Key.f4: return "F4"
        case Key.f5: return "F5"
        case Key.f6: return "F6"
        case Key.f7: return "F7"
        case Key.f8: return "F8"
        case Key.f9: return "F9"
        case Key.f10: return "F10"
        case Key.f11: return "F11"
        case Key.f12: return "F12"
        case Key.minus: return "-"
        case Key.equal: return "="
        case Key.leftBracket: return "["
        case Key.rightBracket: return "]"
        case Key.semicolon: return ";"
        case Key.quote: return "'"
        case Key.comma: return ","
        case Key.period: return "."
        case Key.slash: return "/"
        case Key.backslash: return "\\"
        case Key.grave: return "`"
        default: return String(format: L("键%@"), String(describing: code))
        }
    }

    /// NSMenuItem.keyEquivalent expects lowercase a–z, digits, or a few symbols.
    static func menuChar(_ code: UInt32) -> String {
        switch code {
        case Key.a: return "a"
        case Key.b: return "b"
        case Key.c: return "c"
        case Key.d: return "d"
        case Key.e: return "e"
        case Key.f: return "f"
        case Key.g: return "g"
        case Key.h: return "h"
        case Key.i: return "i"
        case Key.j: return "j"
        case Key.k: return "k"
        case Key.l: return "l"
        case Key.m: return "m"
        case Key.n: return "n"
        case Key.o: return "o"
        case Key.p: return "p"
        case Key.q: return "q"
        case Key.r: return "r"
        case Key.s: return "s"
        case Key.t: return "t"
        case Key.u: return "u"
        case Key.v: return "v"
        case Key.w: return "w"
        case Key.x: return "x"
        case Key.y: return "y"
        case Key.z: return "z"
        case Key.zero: return "0"
        case Key.one: return "1"
        case Key.two: return "2"
        case Key.three: return "3"
        case Key.four: return "4"
        case Key.five: return "5"
        case Key.six: return "6"
        case Key.seven: return "7"
        case Key.eight: return "8"
        case Key.nine: return "9"
        case Key.space: return " "
        case Key.ret: return "\r"
        case Key.escape: return "\u{1b}"
        case Key.tab: return "\t"
        case Key.delete: return "\u{8}"
        case Key.minus: return "-"
        case Key.equal: return "="
        case Key.leftBracket: return "["
        case Key.rightBracket: return "]"
        case Key.semicolon: return ";"
        case Key.quote: return "'"
        case Key.comma: return ","
        case Key.period: return "."
        case Key.slash: return "/"
        case Key.backslash: return "\\"
        case Key.grave: return "`"
        default: return ""
        }
    }
}

enum HotkeyAction: String, CaseIterable, Identifiable {
    case select, clipboard, ocr, file, liveCaptions, mediaCaptions, dictionary, history, quickTranslate, quickUndo
    case voiceRecognize, voiceTranslate, voiceInterpret
    case openMain
    var id: String { rawValue }
    var title: String {
        switch self {
        case .select: return L("划词翻译")
        case .clipboard: return L("翻译剪贴板")
        case .ocr: return L("OCR 截图翻译")
        case .file: return L("翻译文件")
        case .liveCaptions: return L("实时字幕")
        case .mediaCaptions: return L("媒体字幕")
        case .dictionary: return L("词典")
        case .history: return L("历史和收藏")
        case .quickTranslate: return L("快捷翻译")
        case .quickUndo: return L("撤销快捷翻译")
        case .voiceRecognize: return L("语音识别")
        case .voiceTranslate: return L("语音翻译")
        case .voiceInterpret: return L("语音传译")
        case .openMain: return L("打开 Korgino")
        }
    }
    var defaultsKey: String { "hotkey.\(rawValue)" }
    var enabledKey: String { "feature.\(rawValue)" }
    var carbonID: UInt32 {
        switch self {
        case .select: return 1
        case .ocr: return 2
        case .file: return 3
        case .liveCaptions: return 4
        case .dictionary: return 5
        case .history: return 6
        case .clipboard: return 7
        case .quickTranslate: return 8
        case .mediaCaptions: return 9
        case .quickUndo: return 10
        case .voiceRecognize: return 11
        case .voiceTranslate: return 12
        case .voiceInterpret: return 13
        case .openMain: return 14
        }
    }
    var `default`: HotkeySpec {
        switch self {
        case .select: return .selectDefault
        case .clipboard: return .clipboardDefault
        case .ocr: return .ocrDefault
        case .file: return .fileDefault
        case .liveCaptions: return .liveCaptionsDefault
        case .mediaCaptions: return .mediaCaptionsDefault
        case .dictionary: return .dictionaryDefault
        case .history: return .historyDefault
        case .quickTranslate: return .quickTranslateDefault
        case .quickUndo: return .quickUndoDefault
        case .voiceRecognize: return .voiceRecognizeDefault
        case .voiceTranslate: return .voiceTranslateDefault
        case .voiceInterpret: return .voiceInterpretDefault
        case .openMain: return .openMainDefault
        }
    }
}

extension Notification.Name {
    static let korgiHotkeysDidChange = Notification.Name("Korgino.hotkeysDidChange")
}
