import Foundation

/// One 实时字幕 session, from 开始 to the next 开始: every lane's segments, marks, 一场笔记 and recordings.
/// Kept on this computer only. Not part of 历史.
struct MeetingRecord: Codable, Identifiable, Equatable {
    static let currentVersion = 1

    var id: UUID
    var version: Int = MeetingRecord.currentVersion
    /// Empty until the user names it; `displayTitle` falls back to the start time.
    var title: String = ""
    var startedAt: Date
    var endedAt: Date
    var lanes: [Lane] = []
    var segments: [Segment] = []
    /// Capture (`system` / `microphone`) → file name inside the record folder.
    var audio: [String: String] = [:]

    struct Lane: Codable, Equatable, Identifiable {
        var id: UUID
        /// `system` or `microphone`.
        var capture: String
        var captureTitle: String
        var asrID: String
        var asrName: String
        var language: String
        /// BCP-47 of the recognition language, so a speaker's voice can be listed in that language.
        var languageCode: String = ""
        var bindings: [Binding]
        var marks: Marks = Marks()
        var note: SessionNotePage?
    }

    struct Binding: Codable, Equatable, Identifiable {
        /// Same key as a live binding: `none`, or a service id and a language joined by `@`.
        var key: String
        var title: String
        var id: String { key }
        var isSource: Bool { key == "none" }
    }

    struct Marks: Codable, Equatable {
        /// Speaker number (as text, so the JSON stays an object) → name without brackets.
        var renamed: [String: String] = [:]
        var removed: [Int] = []
        /// Speaker number → the voice that reads this person's lines. Same encoding as `SpeakerMarkBook`.
        var voices: [String: String] = [:]

        func token(_ speaker: Int, fallback: String) -> String? {
            guard speaker > 0, !removed.contains(speaker) else { return nil }
            if let name = renamed[String(speaker)]?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                return "[\(name)]"
            }
            return fallback
        }

        func voice(for speaker: Int) -> String? {
            guard speaker > 0, !removed.contains(speaker) else { return nil }
            let value = voices[String(speaker)]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? nil : value
        }
    }

    struct Segment: Codable, Equatable, Identifiable {
        var id: UUID
        var laneID: UUID
        var start: TimeInterval
        var end: TimeInterval
        var speaker: Int
        var source: String
        /// Binding key → finished translation. Failed and pending ones are not kept.
        var translations: [String: String] = [:]
    }

    var duration: TimeInterval { max(0, endedAt.timeIntervalSince(startedAt)) }

    func segments(in laneID: UUID) -> [Segment] {
        segments.filter { $0.laneID == laneID }.sorted { $0.start < $1.start }
    }

    func speakers(in laneID: UUID) -> [Int] {
        var out: [Int] = []
        for seg in segments(in: laneID) where seg.speaker > 0 && !out.contains(seg.speaker) {
            out.append(seg.speaker)
        }
        return out
    }

    /// The first lines a list row shows when the record has no note yet.
    var preview: String {
        if let summary = lanes.lazy.compactMap({ $0.note?.summary }).first(where: { !$0.isEmpty }) {
            return summary
        }
        return segments.sorted { $0.start < $1.start }.prefix(3).map(\.source).joined(separator: " ")
    }

    /// Moves every segment of `from` onto `into` in one lane. The name of `into` wins.
    mutating func mergeSpeaker(_ from: Int, into: Int, lane laneID: UUID) {
        guard from != into, from > 0, into > 0 else { return }
        for i in segments.indices where segments[i].laneID == laneID && segments[i].speaker == from {
            segments[i].speaker = into
        }
        if let index = lanes.firstIndex(where: { $0.id == laneID }) {
            lanes[index].marks.renamed.removeValue(forKey: String(from))
            lanes[index].marks.voices.removeValue(forKey: String(from))
        }
    }
}

/// Folder per record under `root`: `record.json` plus the recordings.
enum MeetingStore {
    static let fileName = "record.json"

    /// Set once at launch by the app. Defaults to a folder in Application Support.
    static var root: URL = AppPaths.appSupport
        .appendingPathComponent("Meetings", isDirectory: true)

    static func folderName(id: UUID, startedAt: Date) -> String {
        return "\(TimeText.folderStamp.string(from: startedAt))-\(id.uuidString.prefix(8))"
    }

    static func makeFolder(id: UUID, startedAt: Date) throws -> URL {
        let url = root.appendingPathComponent(folderName(id: id, startedAt: startedAt), isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    static func save(_ record: MeetingRecord, in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try encoder().encode(record)
        try data.write(to: folder.appendingPathComponent(fileName), options: .atomic)
    }

    static func load(_ folder: URL) -> MeetingRecord? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)) else { return nil }
        return try? decoder().decode(MeetingRecord.self, from: data)
    }

    /// Newest first. Folders without a readable `record.json` are skipped, not deleted.
    static func loadAll() -> [(record: MeetingRecord, folder: URL)] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        var out: [(record: MeetingRecord, folder: URL)] = []
        for folder in items where folder.hasDirectoryPath || (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            if let record = load(folder) { out.append((record, folder)) }
        }
        return out.sorted { $0.record.startedAt > $1.record.startedAt }
    }

    static func delete(_ folder: URL) throws {
        // Only ever remove folders that live under `root`.
        guard folder.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else { return }
        try FileManager.default.removeItem(at: folder)
    }

    static func audioURL(_ record: MeetingRecord, capture: String, in folder: URL) -> URL? {
        guard let name = record.audio[capture] else { return nil }
        let url = folder.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

/// Plain-text exports that need no AppKit.
enum MeetingExport {
    static func clock(_ t: TimeInterval) -> String {
        let s = Int(max(0, t).rounded(.down))
        let h = s / 3600, m = (s / 60) % 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }

    static func duration(_ t: TimeInterval) -> String {
        let minutes = Int((t / 60).rounded())
        if minutes < 1 { return L("不到 1 分钟") }
        if minutes < 60 { return String(format: L("%@ 分钟"), String(minutes)) }
        return String(format: L("%@ 小时 %@ 分"), String(minutes / 60), String(minutes % 60))
    }

    static func markdown(_ record: MeetingRecord, title: String, speakerFallback: (Int) -> String) -> String {
        var out: [String] = ["# \(title)", ""]
        out.append("\(TimeText.medium.string(from: record.startedAt)) · \(duration(record.duration))")
        out.append("")
        for lane in record.lanes {
            let segs = record.segments(in: lane.id)
            guard !segs.isEmpty || lane.note != nil else { continue }
            if record.lanes.count > 1 {
                out.append("## \(lane.captureTitle) · \(lane.asrName)")
                out.append("")
            }
            let level = record.lanes.count > 1 ? "###" : "##"
            if let note = lane.note {
                out.append("\(level) \(L("一场笔记"))")
                out.append("")
                if !note.summary.isEmpty {
                    out.append(note.summary)
                    out.append("")
                }
                for (name, items, box) in [(L("议题"), note.topics, false), (L("结论"), note.decisions, false), (L("待办"), note.todos, true)] where !items.isEmpty {
                    out.append("**\(name)**")
                    out.append("")
                    for item in items {
                        let refs = item.cues.compactMap { id in segs.first { $0.id.uuidString == id } }
                            .map { clock($0.start) }
                        let tail = refs.isEmpty ? "" : " （\(refs.joined(separator: ", "))）"
                        out.append((box ? "- [ ] " : "- ") + item.text + tail)
                    }
                    out.append("")
                }
                if !note.terms.isEmpty {
                    out.append("**\(L("反复出现的词"))**")
                    out.append("")
                    out.append(contentsOf: note.terms.map { "- \($0.word) — \($0.rendering)" })
                    out.append("")
                }
            }
            out.append("\(level) \(L("文字记录"))")
            out.append("")
            var lastSpeaker = -1
            for seg in segs {
                let name = lane.marks.token(seg.speaker, fallback: speakerFallback(seg.speaker))
                    .map { stripBrackets($0) }
                var head = "`\(clock(seg.start))`"
                if let name, seg.speaker != lastSpeaker { head += " **\(name)**" }
                lastSpeaker = seg.speaker
                out.append("\(head)  \(seg.source)")
                for binding in lane.bindings where !binding.isSource {
                    if let tr = seg.translations[binding.key], !tr.isEmpty {
                        out.append("> \(tr)")
                    }
                }
                out.append("")
            }
        }
        return out.joined(separator: "\n")
    }

    static func stripBrackets(_ token: String) -> String {
        var t = token.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("[") { t.removeFirst() }
        if t.hasSuffix("]") { t.removeLast() }
        return t
    }
}
