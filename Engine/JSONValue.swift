import Foundation

/// 一份 JSON 对象。以前 TTS 和 OCR 各写一个逐字相同的包装，合并到这里。
enum JSONValue {
    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
