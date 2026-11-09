import Foundation
import WinSDK

private let className = Array("Korgino".utf16) + [0]
private let windowFill = COLORREF((0xF6 << 16) | (0xF4 << 8) | 0xF4)
private let cardFill = COLORREF(0x00FFFFFF)
private let resultLock = NSLock()
private var pendingResult = ""
private var sourceEdit: HWND?
private var resultEdit: HWND?
private var translateButton: HWND?
private var windowBrush: HBRUSH?
private var cardBrush: HBRUSH?
private var uiFont: HFONT?

private func wide(_ text: String) -> [WCHAR] {
    text.utf16.map { WCHAR($0) } + [0]
}

private func windowString(_ hwnd: HWND?) -> String {
    let count = GetWindowTextLengthW(hwnd)
    guard count > 0 else { return "" }
    var buf = [WCHAR](repeating: 0, count: Int(count) + 1)
    _ = GetWindowTextW(hwnd, &buf, Int32(buf.count))
    let units = buf.prefix { $0 != 0 }.map { UInt16($0) }
    return String(decoding: units, as: UTF16.self)
}

private func setWindowString(_ hwnd: HWND?, _ text: String) {
    var units = wide(text)
    _ = SetWindowTextW(hwnd, &units)
}

private func place(_ parent: HWND?) {
    guard let parent else { return }
    var rect = RECT()
    GetClientRect(parent, &rect)
    let width = Int(rect.right - rect.left)
    let height = Int(rect.bottom - rect.top)
    let pad = 16
    let inner = max(120, width - pad * 2)
    let buttonH = 32
    let gap = 12
    let editH = max(80, (height - pad * 2 - buttonH - gap * 2) / 2)
    var y = pad
    _ = MoveWindow(sourceEdit, Int32(pad), Int32(y), Int32(inner), Int32(editH), true)
    y += editH + gap
    _ = MoveWindow(translateButton, Int32(pad), Int32(y), 96, Int32(buttonH), true)
    y += buttonH + gap
    let rest = max(80, height - y - pad)
    _ = MoveWindow(resultEdit, Int32(pad), Int32(y), Int32(inner), Int32(rest), true)
}

private func storeResult(_ body: String) {
    resultLock.lock()
    pendingResult = body
    resultLock.unlock()
}

private func takeResult() -> String {
    resultLock.lock()
    let body = pendingResult
    resultLock.unlock()
    return body
}

private func translate() {
    let text = windowString(sourceEdit).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, let host = sourceEdit.flatMap({ GetParent($0) }) else { return }
    setWindowString(resultEdit, "")
    Task {
        let result = await Translator.translateAll(text, targets: AppConfig.shared.translateTargets(.select))
        let body = result.outcomes.compactMap { item -> String? in
            if let text = item.text, !text.isEmpty { return text }
            if let error = item.error, !error.isEmpty { return error }
            return nil
        }.joined(separator: "\n\n")
        storeResult(body)
        _ = PostMessageW(host, UINT(WM_APP), 0, 0)
    }
}

private func wndProc(hwnd: HWND?, message: UINT, wParam: WPARAM, lParam: LPARAM) -> LRESULT {
    switch message {
    case UINT(WM_CREATE):
        let source = wide("")
        let button = wide("\u{7ffb}\u{8bd1}")
        let editClass = wide("EDIT")
        let buttonClass = wide("BUTTON")
        sourceEdit = CreateWindowExW(
            DWORD(WS_EX_CLIENTEDGE), editClass, source,
            DWORD(WS_CHILD | WS_VISIBLE | WS_VSCROLL | ES_MULTILINE | ES_AUTOVSCROLL | ES_WANTRETURN),
            0, 0, 0, 0, hwnd, nil, nil, nil
        )
        translateButton = CreateWindowExW(
            0, buttonClass, button,
            DWORD(WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON),
            0, 0, 0, 0, hwnd, HMENU(bitPattern: 1), nil, nil
        )
        resultEdit = CreateWindowExW(
            DWORD(WS_EX_CLIENTEDGE), editClass, source,
            DWORD(WS_CHILD | WS_VISIBLE | WS_VSCROLL | ES_MULTILINE | ES_AUTOVSCROLL | ES_READONLY),
            0, 0, 0, 0, hwnd, nil, nil, nil
        )
        if let uiFont {
            let font = WPARAM(bitPattern: Int64(Int(bitPattern: uiFont)))
            _ = SendMessageW(sourceEdit, UINT(WM_SETFONT), font, 1)
            _ = SendMessageW(translateButton, UINT(WM_SETFONT), font, 1)
            _ = SendMessageW(resultEdit, UINT(WM_SETFONT), font, 1)
        }
        place(hwnd)
        return 0
    case UINT(WM_SIZE):
        place(hwnd)
        return 0
    case UINT(WM_COMMAND):
        let id = UInt64(wParam & 0xFFFF)
        let code = UInt64((wParam >> 16) & 0xFFFF)
        if code == UInt64(BN_CLICKED), id == 1 {
            translate()
        }
        return 0
    case UINT(WM_APP):
        setWindowString(resultEdit, takeResult())
        return 0
    case UINT(WM_CTLCOLOREDIT), UINT(WM_CTLCOLORSTATIC), UINT(WM_CTLCOLORBTN):
        let dc = HDC(bitPattern: UInt(wParam))
        SetBkColor(dc, cardFill)
        SetTextColor(dc, COLORREF(0x001C1C20))
        return LRESULT(bitPattern: UInt64(UInt(bitPattern: cardBrush)))
    case UINT(WM_DESTROY):
        PostQuitMessage(0)
        return 0
    default:
        return DefWindowProcW(hwnd, message, wParam, lParam)
    }
}

@main
enum WindowsMain {
    static func main() {
        WindowsKeychain.install()
        _ = AppConfig.shared
        windowBrush = CreateSolidBrush(windowFill)
        cardBrush = CreateSolidBrush(cardFill)
        uiFont = CreateFontW(-16, 0, 0, 0, FW_NORMAL, DWORD(0), DWORD(0), DWORD(0), DWORD(DEFAULT_CHARSET), DWORD(0), DWORD(0), DWORD(CLEARTYPE_QUALITY), DWORD(0), wide("Segoe UI"))
        var cls = WNDCLASSEXW()
        cls.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
        cls.lpfnWndProc = wndProc
        cls.hInstance = GetModuleHandleW(nil)
        cls.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))
        cls.hbrBackground = windowBrush
        className.withUnsafeBufferPointer { name in
            cls.lpszClassName = name.baseAddress
            _ = RegisterClassExW(&cls)
        }
        let title = wide("Korgino")
        let hwnd: HWND? = className.withUnsafeBufferPointer { name in
            title.withUnsafeBufferPointer { titlePtr in
                CreateWindowExW(
                    0, name.baseAddress, titlePtr.baseAddress,
                    DWORD(WS_OVERLAPPEDWINDOW) | DWORD(WS_VISIBLE),
                    CW_USEDEFAULT, CW_USEDEFAULT, 520, 680,
                    nil, nil, cls.hInstance, nil
                )
            }
        }
        _ = ShowWindow(hwnd, SW_SHOW)
        _ = UpdateWindow(hwnd)
        var msg = MSG()
        while GetMessageW(&msg, nil, 0, 0) {
            TranslateMessage(&msg)
            _ = DispatchMessageW(&msg)
        }
    }
}