import AppKit
import AVFoundation
import Combine
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Controller

@MainActor
final class MeetingRecordsController {
    static let shared = MeetingRecordsController()
    let model = MeetingRecordsModel()

    func show(select id: UUID? = nil) {
        model.reload(select: id)
        MainWindowController.shared.show(page: .live)
    }

    func relocalize() {}
}

// MARK: - Model

@MainActor
final class MeetingRecordsModel: ObservableObject {
    typealias Kind = SystemAudioTranslateController.SourceKind

    struct Entry: Identifiable, Equatable {
        var record: MeetingRecord
        var folder: URL
        var id: UUID { record.id }
    }

    @Published private(set) var entries: [Entry] = []
    @Published var selectedID: UUID?
    @Published var laneID: UUID?
    @Published var query = ""
    @Published private(set) var loading = false
    @Published var noteWriting: Set<UUID> = []
    @Published var noteErrors: [UUID: String] = [:]
    @Published var relabeling = false
    @Published var message = ""
    @Published private(set) var playingCapture: String?
    @Published private(set) var playTime: TimeInterval = 0
    @Published private(set) var isPlaying = false

    private var player: AVAudioPlayer?
    private var playerURL: URL?
    private var ticker: AnyCancellable?
    private var observer: NSObjectProtocol?
    private var noteTasks: [UUID: Task<Void, Never>] = [:]
    /// Only the live window's slow-changing parts: state, which record, lane notes and marks.
    private var liveSinks: [AnyCancellable] = []

    private var live: SystemAudioTranslateController { .shared }

    var keepRecords: Bool {
        get { live.keepRecords }
        set {
            objectWillChange.send()
            live.keepRecords = newValue
        }
    }

    init() {
        let poke: () -> Void = { [weak self] in
            MainActor.assumeIsolated { self?.objectWillChange.send() }
        }
        let live = SystemAudioTranslateController.shared
        liveSinks = [
            live.$state.removeDuplicates().sink { _ in poke() },
            live.$recordID.removeDuplicates().sink { _ in poke() },
            live.$systemLanes.sink { _ in poke() },
            live.$micLanes.sink { _ in poke() },
        ]
        observer = NotificationCenter.default.addObserver(
            forName: .korgiMeetingRecordsChanged, object: nil, queue: .main
        ) { [weak self] note in
            let id = note.object as? UUID
            MainActor.assumeIsolated { self?.changed(id) }
        }
    }

    var filtered: [Entry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return entries }
        return entries.filter { entry in
            title(entry.record).localizedCaseInsensitiveContains(q)
                || entry.record.segments.contains { seg in
                    seg.source.localizedCaseInsensitiveContains(q)
                        || seg.translations.values.contains { $0.localizedCaseInsensitiveContains(q) }
                }
                || entry.record.lanes.contains { $0.note?.summary.localizedCaseInsensitiveContains(q) == true }
        }
    }

    var selected: Entry? {
        guard let selectedID else { return nil }
        return entries.first { $0.id == selectedID }
    }

    /// The lanes worth showing: ones with something in them.
    func shownLanes(_ record: MeetingRecord) -> [MeetingRecord.Lane] {
        let list = record.lanes.filter { lane in
            lane.note != nil || record.segments.contains { $0.laneID == lane.id }
        }
        return list.isEmpty ? Array(record.lanes.prefix(1)) : list
    }

    func currentLane(_ record: MeetingRecord) -> MeetingRecord.Lane? {
        let lanes = shownLanes(record)
        return lanes.first { $0.id == laneID } ?? lanes.first
    }

    func title(_ record: MeetingRecord) -> String {
        if !record.title.isEmpty { return record.title }
        return TimeText.medium.string(from: record.startedAt)
    }

    func isLive(_ record: MeetingRecord) -> Bool { live.recordID == record.id }
    func isRecording(_ record: MeetingRecord) -> Bool { isLive(record) && live.isActive }

    func speakerToken(_ lane: MeetingRecord.Lane, _ speaker: Int) -> String? {
        lane.marks.token(speaker, fallback: "[\(L("说话人")) \(speaker)]")
    }

    // MARK: Loading

    func reload(select id: UUID? = nil) {
        loading = true
        Task.detached(priority: .userInitiated) {
            let all = MeetingStore.loadAll()
            await MainActor.run {
                self.entries = all.map { Entry(record: $0.record, folder: $0.folder) }
                self.loading = false
                if let id, self.entries.contains(where: { $0.id == id }) {
                    self.select(id)
                } else if self.selectedID == nil || !self.entries.contains(where: { $0.id == self.selectedID }) {
                    self.select(self.entries.first?.id)
                }
            }
        }
    }

    func select(_ id: UUID?) {
        guard selectedID != id else { return }
        stopPlayback()
        selectedID = id
        laneID = selected.map { shownLanes($0.record).first?.id } ?? nil
        message = ""
    }

    private func changed(_ id: UUID?) {
        guard let id, let index = entries.firstIndex(where: { $0.id == id }) else {
            reload()
            return
        }
        let folder = entries[index].folder
        if let record = MeetingStore.load(folder) {
            entries[index].record = record
        }
    }

    private func update(_ id: UUID, save: Bool = true, _ change: (inout MeetingRecord) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[index].record)
        guard save else { return }
        let record = entries[index].record
        let folder = entries[index].folder
        do {
            try MeetingStore.save(record, in: folder)
        } catch {
            message = String(format: L("保存失败：%@"), error.localizedDescription)
        }
    }

    // MARK: Editing

    func rename(_ id: UUID, to raw: String) {
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        update(id, save: !isLiveID(id)) { $0.title = title }
        if isLiveID(id) { live.setRecordTitle(title) }
    }

    func renameSpeaker(_ id: UUID, lane laneID: UUID, _ speaker: Int, to raw: String) {
        if isLiveID(id), let kind = kind(of: id, lane: laneID) {
            live.renameSpeaker(laneID, kind, speaker, to: raw)
            return
        }
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix("[") { name.removeFirst() }
        if name.hasSuffix("]") { name.removeLast() }
        update(id) { record in
            guard let index = record.lanes.firstIndex(where: { $0.id == laneID }) else { return }
            if name.isEmpty {
                record.lanes[index].marks.renamed.removeValue(forKey: String(speaker))
            } else {
                record.lanes[index].marks.renamed[String(speaker)] = name
            }
            record.lanes[index].marks.removed.removeAll { $0 == speaker }
        }
    }

    func setSpeakerVoice(_ id: UUID, lane laneID: UUID, _ speaker: Int, to voice: String?) {
        if isLiveID(id), let kind = kind(of: id, lane: laneID) {
            live.setSpeakerVoice(laneID, kind, speaker, to: voice)
            return
        }
        let value = voice?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        update(id) { record in
            guard let index = record.lanes.firstIndex(where: { $0.id == laneID }) else { return }
            if value.isEmpty {
                record.lanes[index].marks.voices.removeValue(forKey: String(speaker))
            } else {
                record.lanes[index].marks.voices[String(speaker)] = value
            }
        }
    }

    func mergeSpeaker(_ id: UUID, lane laneID: UUID, _ from: Int, into: Int) {
        if isLiveID(id), let kind = kind(of: id, lane: laneID) {
            live.mergeSpeaker(laneID, kind, from, into: into)
            return
        }
        update(id) { $0.mergeSpeaker(from, into: into, lane: laneID) }
    }

    func setSpeaker(_ id: UUID, lane laneID: UUID, segment: UUID, to speaker: Int) {
        if isLiveID(id), let kind = kind(of: id, lane: laneID) {
            live.applySpeakers([segment: speaker], kind: kind)
            return
        }
        update(id) { record in
            guard let index = record.segments.firstIndex(where: { $0.id == segment }) else { return }
            record.segments[index].speaker = speaker
        }
    }

    func nextSpeaker(_ record: MeetingRecord, lane laneID: UUID) -> Int {
        (record.segments.filter { $0.laneID == laneID }.map(\.speaker).max() ?? 0) + 1
    }

    func delete(_ id: UUID) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        if isLiveID(id) {
            guard !live.isActive else { return }
            live.forgetRecord(id)
        }
        if selectedID == id { stopPlayback() }
        do {
            try MeetingStore.delete(entry.folder)
        } catch {
            message = String(format: L("删除失败：%@"), error.localizedDescription)
            return
        }
        let index = entries.firstIndex { $0.id == id } ?? 0
        entries.removeAll { $0.id == id }
        if selectedID == id {
            selectedID = nil
            let next = entries.indices.contains(index) ? entries[index].id : entries.last?.id
            select(next)
        }
    }

    func reveal(_ id: UUID) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([entry.folder])
    }

    private func isLiveID(_ id: UUID) -> Bool { live.recordID == id }

    private func kind(of id: UUID, lane laneID: UUID) -> Kind? {
        guard let lane = entries.first(where: { $0.id == id })?.record.lanes.first(where: { $0.id == laneID }) else { return nil }
        return Kind(rawValue: lane.capture)
    }

    // MARK: 一场笔记

    func canWriteNote(_ record: MeetingRecord, lane laneID: UUID) -> Bool {
        !noteWriting.contains(laneID) && record.segments.contains { $0.laneID == laneID && !$0.source.isEmpty }
    }

    func writeNote(_ id: UUID, lane laneID: UUID) {
        if isLiveID(id), let kind = kind(of: id, lane: laneID),
           live.lanes(kind).contains(where: { $0.id == laneID }) {
            live.writeNote(laneID, kind)
            return
        }
        guard let entry = entries.first(where: { $0.id == id }),
              let lane = entry.record.lanes.first(where: { $0.id == laneID }) else { return }
        let brief = Self.brief(entry.record, lane: lane, fallback: { self.speakerToken(lane, $0) ?? "" })
        guard brief.hasCue else { return }
        noteTasks[laneID]?.cancel()
        noteWriting.insert(laneID)
        noteErrors[laneID] = nil
        noteTasks[laneID] = Task { @MainActor in
            let result = await SessionNoteWriter.write(brief)
            self.noteWriting.remove(laneID)
            self.noteTasks[laneID] = nil
            switch result {
            case .success(let page):
                self.update(id) { record in
                    guard let index = record.lanes.firstIndex(where: { $0.id == laneID }) else { return }
                    record.lanes[index].note = page
                }
            case .failure(let failure):
                self.noteErrors[laneID] = failure.message
            }
        }
    }

    /// Same choice as the live window: the binding aimed at the native language, else the first one.
    static func brief(_ record: MeetingRecord, lane: MeetingRecord.Lane, fallback: (Int) -> String) -> SessionNoteBrief {
        let native = AppConfig.shared.nativeLanguage.resolvedDestination
        let bindings = lane.bindings.compactMap { b -> SessionNoteBinding? in
            guard let live = LaneBinding(key: b.key) else { return nil }
            return SessionNoteBinding(
                id: live.translateID,
                key: live.key,
                isSource: live.isSource,
                translatesToNative: !live.isSource && live.target.resolvedDestination == native
            )
        }
        let binding = SessionNote.choose(bindings)
        let cues = record.segments(in: lane.id).map { seg in
            SessionNoteCue(
                id: seg.id.uuidString,
                mark: seg.speaker > 0 ? fallback(seg.speaker) : "",
                source: seg.source,
                translation: binding.isSource ? nil : seg.translations[binding.key],
                waiting: false
            )
        }
        return SessionNote.brief(cues, binding: binding)
    }

    // MARK: Voices

    func canRelabel(_ record: MeetingRecord, lane: MeetingRecord.Lane) -> Bool {
        !relabeling && !isRecording(record) && VoiceprintModel.shared.isReady
            && audioURL(record, capture: lane.capture) != nil
            && record.segments.contains { $0.laneID == lane.id }
    }

    /// Runs the voiceprint model over this lane's recording and numbers the speakers again. Names are cleared.
    func relabel(_ id: UUID, lane laneID: UUID) {
        guard let entry = entries.first(where: { $0.id == id }),
              let lane = entry.record.lanes.first(where: { $0.id == laneID }),
              let url = audioURL(entry.record, capture: lane.capture) else { return }
        let segs = entry.record.segments(in: laneID)
        relabeling = true
        message = L("正在按声音分说话人…")
        Task { @MainActor in
            let labels = await VoiceTagger.label(segments: segs.map { (start: $0.start, end: $0.end) }, audioURL: url)
            self.relabeling = false
            guard labels.count == segs.count, labels.contains(where: { $0 != nil }) else {
                self.message = L("没有分出说话人")
                return
            }
            var map: [UUID: Int] = [:]
            var last = 0
            for (seg, label) in zip(segs, labels) {
                let number = label ?? last
                map[seg.id] = number
                if number > 0 { last = number }
            }
            if self.isLiveID(id), let kind = self.kind(of: id, lane: laneID) {
                self.live.applySpeakers(map, kind: kind, resetMarks: laneID)
            } else {
                self.update(id) { record in
                    for i in record.segments.indices {
                        if let n = map[record.segments[i].id] { record.segments[i].speaker = n }
                    }
                    if let index = record.lanes.firstIndex(where: { $0.id == laneID }) {
                        record.lanes[index].marks = MeetingRecord.Marks()
                    }
                }
            }
            let count = Set(map.values.filter { $0 > 0 }).count
            self.message = String(format: L("分出 %@ 位说话人"), String(count))
        }
    }

    // MARK: Playback

    func audioURL(_ record: MeetingRecord, capture: String) -> URL? {
        guard let entry = entries.first(where: { $0.id == record.id }) else { return nil }
        return MeetingStore.audioURL(record, capture: capture, in: entry.folder)
    }

    func play(_ record: MeetingRecord, capture: String, at time: TimeInterval) {
        guard !isRecording(record), let url = audioURL(record, capture: capture) else { return }
        if playerURL != url {
            stopPlayback()
            guard let p = try? AVAudioPlayer(contentsOf: url) else {
                message = L("录音打不开")
                return
            }
            p.prepareToPlay()
            player = p
            playerURL = url
        }
        guard let player else { return }
        player.currentTime = min(max(0, time), max(0, player.duration - 0.05))
        player.play()
        playingCapture = capture
        isPlaying = true
        playTime = player.currentTime
        ticker = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func togglePlayback(_ record: MeetingRecord, capture: String) {
        if isPlaying, playingCapture == capture {
            player?.pause()
            isPlaying = false
            ticker = nil
        } else {
            play(record, capture: capture, at: playingCapture == capture ? playTime : 0)
        }
    }

    func seek(_ time: TimeInterval) {
        guard let player else { return }
        player.currentTime = min(max(0, time), player.duration)
        playTime = player.currentTime
    }

    var playDuration: TimeInterval { player?.duration ?? 0 }

    func stopPlayback() {
        player?.stop()
        player = nil
        playerURL = nil
        ticker = nil
        isPlaying = false
        playingCapture = nil
        playTime = 0
    }

    private func tick() {
        guard let player else { return }
        playTime = player.currentTime
        if !player.isPlaying {
            isPlaying = false
            ticker = nil
        }
    }

    // MARK: Export

    private func exportBase(_ record: MeetingRecord) -> String {
        let stamp = TimeText.fileStamp.string(from: record.startedAt)
        return record.title.isEmpty ? "\(L("会议记录"))-\(stamp)" : CaptionExport.sanitized("\(record.title)-\(stamp)")
    }

    private func savePanel(_ name: String, type: UTType) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    func exportMarkdown(_ record: MeetingRecord) {
        let text = MeetingExport.markdown(record, title: title(record)) { "[\(L("说话人")) \($0)]" }
        let type = UTType(filenameExtension: "md") ?? .plainText
        guard let url = savePanel("\(exportBase(record)).md", type: type) else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            message = String(format: L("保存失败：%@"), error.localizedDescription)
        }
    }

    func exportWord(_ record: MeetingRecord) {
        let doc = MeetingWordDocument.make(record, title: title(record))
        let type = UTType(filenameExtension: "docx") ?? .data
        guard let url = savePanel("\(exportBase(record)).docx", type: type) else { return }
        do {
            let data = try doc.data(
                from: NSRange(location: 0, length: doc.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]
            )
            try data.write(to: url, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            message = String(format: L("保存失败：%@"), error.localizedDescription)
        }
    }

    func exportSRT(_ record: MeetingRecord) {
        let lanes = record.lanes.compactMap { lane -> CaptionExport.Lane? in
            let cues = record.segments(in: lane.id).compactMap { seg -> CaptionExport.Cue? in
                let source = SRTDocument.oneLine(seg.source)
                guard !source.isEmpty else { return nil }
                return CaptionExport.Cue(
                    start: seg.start,
                    end: seg.end,
                    source: source,
                    mark: speakerToken(lane, seg.speaker),
                    translations: seg.translations.mapValues(SRTDocument.oneLine)
                )
            }
            guard !cues.isEmpty else { return nil }
            return CaptionExport.Lane(
                key: "\(lane.capture)|\(lane.asrID)",
                title: "\(lane.captureTitle) · \(lane.asrName)",
                fileStem: "\(lane.captureTitle).\(lane.asrName)",
                bindings: lane.bindings.compactMap { LaneBinding(key: $0.key) },
                cues: cues
            )
        }
        guard !lanes.isEmpty, let choice = CaptionExport.choose(lanes: lanes, suggestedName: title(record)) else { return }
        let files = CaptionExport.files(base: exportBase(record), lanes: lanes, rule: choice.rule, sourceLanes: choice.sourceLanes)
        guard !files.isEmpty else { return }
        do {
            let urls = try CaptionExport.write(files, to: choice.folder)
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        } catch {
            message = String(format: L("保存失败：%@"), error.localizedDescription)
        }
    }

    func exportAudio(_ record: MeetingRecord) {
        let files = record.audio.keys.sorted().compactMap { capture in audioURL(record, capture: capture).map { (capture, $0) } }
        guard !files.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = L("导出")
        panel.message = L("把录音导出到")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let fm = FileManager.default
        do {
            var urls: [URL] = []
            for (capture, source) in files {
                let title = record.lanes.first { $0.capture == capture }?.captureTitle ?? capture
                let dest = folder.appendingPathComponent("\(exportBase(record)).\(CaptionExport.sanitized(title)).m4a")
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                try fm.copyItem(at: source, to: dest)
                urls.append(dest)
            }
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        } catch {
            message = String(format: L("保存失败：%@"), error.localizedDescription)
        }
    }
}

// MARK: - Live controller hooks used by the window

extension SystemAudioTranslateController {
    /// Sets speakers on finished segments of one capture. `resetMarks` clears that lane's names first.
    func applySpeakers(_ map: [UUID: Int], kind: SourceKind, resetMarks laneID: UUID? = nil) {
        if let laneID { editLane(laneID, kind) { $0.marks = SpeakerMarkBook() } }
        func patch(_ arr: inout [LiveCaptionSegment]) {
            for i in arr.indices {
                if let n = map[arr[i].id] { arr[i].speaker = n }
            }
        }
        switch kind {
        case .system: patch(&systemSegments)
        case .microphone: patch(&micSegments)
        }
        refreshImmersiveOverlay()
    }
}

// MARK: - Word

enum MeetingWordDocument {
    static func make(_ record: MeetingRecord, title: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        // Fixed colors: dynamic ones resolve to white in dark mode and the document comes out blank.
        let ink = NSColor(srgbRed: 0.1, green: 0.1, blue: 0.12, alpha: 1)
        let muted = NSColor(srgbRed: 0.42, green: 0.42, blue: 0.45, alpha: 1)
        func add(_ text: String, font: NSFont, color: NSColor? = nil, spacing: CGFloat = 6, indent: CGFloat = 0) {
            let color = color ?? ink
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = spacing
            style.firstLineHeadIndent = indent
            style.headIndent = indent
            out.append(NSAttributedString(string: text + "\n", attributes: [
                .font: font, .foregroundColor: color, .paragraphStyle: style,
            ]))
        }
        let body = Theme.TypeScale.nsCaption
        let small = Theme.TypeScale.nsMicro
        add(title, font: Theme.TypeScale.nsTitle, spacing: 4)
        add("\(TimeText.medium.string(from: record.startedAt)) · \(MeetingExport.duration(record.duration))", font: small, color: muted, spacing: 14)
        for lane in record.lanes {
            let segs = record.segments(in: lane.id)
            guard !segs.isEmpty || lane.note != nil else { continue }
            if record.lanes.count > 1 {
                add("\(lane.captureTitle) · \(lane.asrName)", font: Theme.TypeScale.nsReading, spacing: 8)
            }
            if let note = lane.note {
                add(L("一场笔记"), font: Theme.TypeScale.nsBodyMedium, spacing: 6)
                if !note.summary.isEmpty { add(note.summary, font: body, spacing: 10) }
                for (name, items, mark) in [(L("议题"), note.topics, "•"), (L("结论"), note.decisions, "•"), (L("待办"), note.todos, "☐")] where !items.isEmpty {
                    add(name, font: Theme.TypeScale.nsCaptionMedium, spacing: 3)
                    for item in items {
                        let times = item.cues.compactMap { id in segs.first { $0.id.uuidString == id } }.map { MeetingExport.clock($0.start) }
                        let tail = times.isEmpty ? "" : "（\(times.joined(separator: ", "))）"
                        add("\(mark) \(item.text)\(tail)", font: body, spacing: 3, indent: 12)
                    }
                    out.append(NSAttributedString(string: "\n"))
                }
                if !note.terms.isEmpty {
                    add(L("反复出现的词"), font: Theme.TypeScale.nsCaptionMedium, spacing: 3)
                    for term in note.terms { add("\(term.word) — \(term.rendering)", font: body, spacing: 2, indent: 12) }
                    out.append(NSAttributedString(string: "\n"))
                }
            }
            add(L("文字记录"), font: Theme.TypeScale.nsBodyMedium, spacing: 6)
            var lastSpeaker = -1
            for seg in segs {
                let name = lane.marks.token(seg.speaker, fallback: "[\(L("说话人")) \(seg.speaker)]").map(MeetingExport.stripBrackets)
                if let name, seg.speaker != lastSpeaker {
                    add(name, font: Theme.TypeScale.nsMicro, color: muted, spacing: 1)
                }
                lastSpeaker = seg.speaker
                add("\(MeetingExport.clock(seg.start))  \(seg.source)", font: body, spacing: 1)
                for binding in lane.bindings where !binding.isSource {
                    if let tr = seg.translations[binding.key], !tr.isEmpty {
                        add(tr, font: body, color: muted, spacing: 1, indent: 12)
                    }
                }
                out.append(NSAttributedString(string: "\n", attributes: [.font: small]))
            }
        }
        return out
    }
}

// MARK: - Views

struct MeetingRecordsView: View {
    @ObservedObject var model: MeetingRecordsModel
    @EnvironmentObject private var config: AppConfig

    var body: some View {
        let _ = config.appLanguage
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            if let entry = model.selected {
                MeetingRecordDetail(model: model, entry: entry)
                    .id(entry.id)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(Theme.TypeScale.display)
                        .foregroundStyle(.tertiary)
                    Text(model.entries.isEmpty ? L("还没有会议记录") : L("选一份会议记录"))
                        .foregroundStyle(.secondary)
                    if model.entries.isEmpty {
                        Text(L("在实时字幕里点「开始」，停下后这一场就留在这里。"))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .controlSize(.small)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            TextField(L("搜索标题、原文或译文"), text: $model.query)
                .textFieldStyle(.roundedBorder)
                .padding(10)
            List(selection: Binding(get: { model.selectedID }, set: { model.select($0) })) {
                ForEach(model.filtered) { entry in
                    row(entry)
                        .tag(entry.id)
                        .contextMenu {
                            Button(L("在访达中显示")) { model.reveal(entry.id) }
                            Divider()
                            Button(L("删除"), role: .destructive) { model.delete(entry.id) }
                                .disabled(model.isRecording(entry.record))
                        }
                }
            }
            .listStyle(.sidebar)
            Divider()
            Toggle(L("保留新的会议记录"), isOn: $model.keepRecords)
                .toggleStyle(.checkbox)
                .font(.caption)
                .help(L("关掉后，实时字幕不再留下新的会议记录。已有的不动。"))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ entry: MeetingRecordsModel.Entry) -> some View {
        let record = entry.record
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if model.isRecording(record) {
                    Circle().fill(Theme.live).frame(width: 6, height: 6)
                }
                Text(model.title(record))
                    .font(Theme.TypeScale.labelMedium)
                    .lineLimit(1)
            }
            Text(rowSubtitle(record))
                .font(Theme.TypeScale.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if !record.preview.isEmpty {
                Text(record.preview)
                    .font(Theme.TypeScale.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 3)
    }

    private func rowSubtitle(_ record: MeetingRecord) -> String {
        var parts: [String] = []
        if !record.title.isEmpty {
            parts.append(record.startedAt.formatted(date: .abbreviated, time: .shortened))
        }
        parts.append(model.isRecording(record) ? L("正在听") : MeetingExport.duration(record.duration))
        parts.append(String(format: L("%@ 段"), String(record.segments.count)))
        if !record.audio.isEmpty { parts.append(L("有录音")) }
        return parts.joined(separator: " · ")
    }
}

private struct MeetingRecordDetail: View {
    @ObservedObject var model: MeetingRecordsModel
    var entry: MeetingRecordsModel.Entry
    @ObservedObject private var voiceprint = VoiceprintModel.shared
    @State private var titleDraft = ""
    @State private var jump: CaptionJump?
    @State private var confirmDelete = false
    @State private var confirmRelabel = false

    private var record: MeetingRecord { entry.record }

    var body: some View {
        let lane = model.currentLane(record)
        VStack(alignment: .leading, spacing: 0) {
            header(lane)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)
            Divider()
            if let lane {
                laneBody(lane)
            } else {
                Spacer()
            }
        }
        .background(Theme.windowFill)
        .onAppear { titleDraft = record.title }
        .onChange(of: record.title) { _, t in titleDraft = t }
        .confirmationDialog(L("删除这份会议记录？"), isPresented: $confirmDelete) {
            Button(L("删除"), role: .destructive) { model.delete(record.id) }
        } message: {
            Text(L("文字、笔记和录音会一起删掉，不能恢复。"))
        }
        .confirmationDialog(L("按声音重新分说话人？"), isPresented: $confirmRelabel) {
            Button(L("重新分")) {
                if let lane { model.relabel(record.id, lane: lane.id) }
            }
        } message: {
            Text(L("用这一路的录音重新给每段认说话人，改过的名字会清掉。"))
        }
    }

    private func header(_ lane: MeetingRecord.Lane?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField(model.title(record), text: $titleDraft)
                    .textFieldStyle(.plain)
                    .font(Theme.TypeScale.title)
                    .onSubmit { model.rename(record.id, to: titleDraft) }
                    .help(L("给这一场起个名字，回车保存"))
                Spacer(minLength: 8)
                Menu(L("导出…")) {
                    Button(L("Markdown…")) { model.exportMarkdown(record) }
                    Button(L("Word…")) { model.exportWord(record) }
                    Button(L("字幕（SRT）…")) { model.exportSRT(record) }
                    if !record.audio.isEmpty {
                        Button(L("录音（M4A）…")) { model.exportAudio(record) }
                            .disabled(model.isRecording(record))
                    }
                }
                .fixedSize()
                Menu {
                    Button(L("在访达中显示")) { model.reveal(record.id) }
                    if let lane {
                        Button(L("按声音重新分说话人…")) { confirmRelabel = true }
                            .disabled(!model.canRelabel(record, lane: lane))
                    }
                    Divider()
                    Button(L("删除…"), role: .destructive) { confirmDelete = true }
                        .disabled(model.isRecording(record))
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            HStack(spacing: 6) {
                Text(record.startedAt.formatted(date: .complete, time: .shortened))
                Text("·")
                Text(model.isRecording(record) ? L("正在听") : MeetingExport.duration(record.duration))
                if model.isLive(record) {
                    Text("·")
                    Text(L("实时字幕窗口里的这一场"))
                        .help(L("在这里的改动会同步到实时字幕窗口"))
                }
            }
            .font(Theme.TypeScale.caption)
            .foregroundStyle(.secondary)
            if !model.message.isEmpty {
                Text(model.message)
                    .font(Theme.TypeScale.caption)
                    .foregroundStyle(.secondary)
            }
            let lanes = model.shownLanes(record)
            if lanes.count > 1 {
                Picker("", selection: Binding(get: { lane?.id ?? lanes[0].id }, set: { model.laneID = $0 })) {
                    ForEach(lanes) { l in
                        Text("\(l.captureTitle) · \(l.asrName)").tag(l.id)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(.top, 2)
            }
        }
    }

    @ViewBuilder
    private func laneBody(_ lane: MeetingRecord.Lane) -> some View {
        let segs = record.segments(in: lane.id)
        let speakers = record.speakers(in: lane.id).compactMap { n in model.speakerToken(lane, n).map { (id: n, token: $0) } }
        VStack(alignment: .leading, spacing: 10) {
            if model.audioURL(record, capture: lane.capture) != nil {
                MeetingPlayerBar(model: model, record: record, capture: lane.capture)
            }
            if !speakers.isEmpty {
                SpeakerChipRow(
                    rows: speakers,
                    canDelete: false,
                    onRename: { model.renameSpeaker(record.id, lane: lane.id, $0, to: $1) },
                    onDelete: { _ in },
                    onDeleteAll: {},
                    onMerge: { model.mergeSpeaker(record.id, lane: lane.id, $0, into: $1) },
                    voices: SpeakerVoice.choices(language: lane.languageCode.isEmpty ? nil : lane.languageCode),
                    voiceID: { lane.marks.voice(for: $0) },
                    onVoice: { model.setSpeakerVoice(record.id, lane: lane.id, $0, to: $1) }
                )
            }
            noteArea(lane, segs: segs)
            transcript(lane, segs: segs, speakers: speakers)
        }
        .padding(14)
    }

    @ViewBuilder
    private func noteArea(_ lane: MeetingRecord.Lane, segs: [MeetingRecord.Segment]) -> some View {
        let writing = model.noteWriting.contains(lane.id) || liveNote(lane)?.writing == true
        let error = model.noteErrors[lane.id] ?? liveNote(lane)?.error ?? ""
        if lane.note != nil || writing || !error.isEmpty {
            SessionNoteCard(
                page: lane.note,
                writing: writing,
                error: error,
                following: liveNote(lane)?.follow == true && model.isRecording(record),
                maxHeight: 240,
                onJump: { raw in
                    guard let id = UUID(uuidString: raw), let seg = segs.first(where: { $0.id == id }) else { return }
                    let next = CaptionJump(lane: lane.id, id: id, tick: (jump?.tick ?? 0) + 1)
                    jump = next
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        if jump?.tick == next.tick { jump = nil }
                    }
                    if model.audioURL(record, capture: lane.capture) != nil, !model.isRecording(record) {
                        model.play(record, capture: lane.capture, at: seg.start)
                    }
                },
                onRewrite: model.canWriteNote(record, lane: lane.id) ? { model.writeNote(record.id, lane: lane.id) } : nil
            )
        } else {
            HStack(spacing: 8) {
                Button(L("写一场笔记")) { model.writeNote(record.id, lane: lane.id) }
                    .disabled(!model.canWriteNote(record, lane: lane.id))
                Text(L("总结、议题、结论、待办和反复出现的词，用自己的 AI 密钥"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func liveNote(_ lane: MeetingRecord.Lane) -> SessionNoteSlot? {
        guard model.isLive(record), let kind = SystemAudioTranslateController.SourceKind(rawValue: lane.capture) else { return nil }
        return SystemAudioTranslateController.shared.lanes(kind).first { $0.id == lane.id }?.note
    }

    private func transcript(_ lane: MeetingRecord.Lane, segs: [MeetingRecord.Segment], speakers: [(id: Int, token: String)]) -> some View {
        let playingHere = model.playingCapture == lane.capture && model.isPlaying
        let current = playingHere ? segs.last(where: { $0.start <= model.playTime + 0.05 })?.id : nil
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(segs.enumerated()), id: \.element.id) { index, seg in
                        MeetingSegmentRow(
                            seg: seg,
                            lane: lane,
                            token: model.speakerToken(lane, seg.speaker),
                            voiceID: lane.marks.voice(for: seg.speaker),
                            showSpeaker: index == 0 || segs[index - 1].speaker != seg.speaker,
                            highlighted: seg.id == jump?.id,
                            playing: seg.id == current,
                            canPlay: model.audioURL(record, capture: lane.capture) != nil && !model.isRecording(record),
                            speakers: speakers,
                            onPlay: { model.play(record, capture: lane.capture, at: seg.start) },
                            onSpeaker: { model.setSpeaker(record.id, lane: lane.id, segment: seg.id, to: $0) },
                            newSpeaker: model.nextSpeaker(record, lane: lane.id)
                        )
                        .id(seg.id)
                        Divider().opacity(0.5)
                    }
                    if segs.isEmpty {
                        Text(L("这一路没有字幕"))
                            .foregroundStyle(.secondary)
                            .padding(20)
                    }
                }
            }
            .card(radius: 12)
            .onChange(of: jump) { _, target in
                guard let target else { return }
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(target.id, anchor: .center) }
            }
            .onChange(of: current) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }
}

private struct MeetingSegmentRow: View {
    var seg: MeetingRecord.Segment
    var lane: MeetingRecord.Lane
    var token: String?
    /// 这一位指定的声音。空的用默认。
    var voiceID: String?
    var showSpeaker: Bool
    var highlighted: Bool
    var playing: Bool
    var canPlay: Bool
    var speakers: [(id: Int, token: String)]
    var onPlay: () -> Void
    var onSpeaker: (Int) -> Void
    var newSpeaker: Int

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onPlay) {
                Text(MeetingExport.clock(seg.start))
                    .font(Theme.TypeScale.caption.monospaced())
                    .foregroundStyle(playing ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!canPlay)
            .help(canPlay ? L("从这一句开始放录音") : "")
            .frame(width: 58, alignment: .trailing)
            .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                if showSpeaker {
                    speakerMenu
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(seg.source)
                        .font(Theme.TypeScale.label)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !seg.source.isEmpty {
                        SpeakButton(
                            text: seg.source,
                            language: lane.languageCode.isEmpty ? nil : lane.languageCode,
                            help: L("朗读原文"),
                            tag: "meeting.\(seg.id).source",
                            voiceID: voiceID
                        )
                    }
                }
                ForEach(lane.bindings.filter { !$0.isSource }) { binding in
                    if let tr = seg.translations[binding.key], !tr.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(tr)
                                .font(Theme.TypeScale.label)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .help(binding.title)
                            SpeakButton(
                                text: tr,
                                language: LaneBinding(key: binding.key)?.target.appleCode,
                                tag: "meeting.\(seg.id).\(binding.key)",
                                voiceID: voiceID
                            )
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(highlighted ? 0.14 : (playing ? 0.07 : 0)))
        .animation(.easeOut(duration: 0.3), value: highlighted)
        .contextMenu { speakerItems }
    }

    @ViewBuilder
    private var speakerItems: some View {
        ForEach(speakers.filter { $0.id != seg.speaker }, id: \.id) { other in
            Button(String(format: L("改给 %@"), SpeakerMarkText.display(other.token))) { onSpeaker(other.id) }
        }
        Button(String(format: L("新的说话人 %@"), String(newSpeaker))) { onSpeaker(newSpeaker) }
        if seg.speaker > 0 {
            Button(L("不标说话人")) { onSpeaker(0) }
        }
    }

    @ViewBuilder
    private var speakerMenu: some View {
        Menu {
            ForEach(speakers.filter { $0.id != seg.speaker }, id: \.id) { other in
                Button(SpeakerMarkText.display(other.token)) { onSpeaker(other.id) }
            }
            Divider()
            Button(String(format: L("新的说话人 %@"), String(newSpeaker))) { onSpeaker(newSpeaker) }
            if seg.speaker > 0 {
                Button(L("不标说话人")) { onSpeaker(0) }
            }
        } label: {
            if let token {
                SpeakerChip(speaker: seg.speaker, token: token)
            } else {
                Text(L("标说话人"))
                    .font(Theme.TypeScale.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("把这一段改给另一位"))
    }
}

private struct MeetingPlayerBar: View {
    @ObservedObject var model: MeetingRecordsModel
    var record: MeetingRecord
    var capture: String

    var body: some View {
        let active = model.playingCapture == capture
        let recording = model.isRecording(record)
        HStack(spacing: 10) {
            Button {
                model.togglePlayback(record, capture: capture)
            } label: {
                Image(systemName: active && model.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 16)
            }
            .buttonStyle(.borderless)
            .disabled(recording)
            Text(MeetingExport.clock(active ? model.playTime : 0))
                .font(Theme.TypeScale.caption.monospaced())
                .foregroundStyle(.secondary)
            Slider(
                value: Binding(get: { active ? model.playTime : 0 }, set: { model.seek($0) }),
                in: 0...max(1, active ? model.playDuration : max(1, record.duration))
            )
            .disabled(!active)
            Text(MeetingExport.clock(active ? model.playDuration : record.duration))
                .font(Theme.TypeScale.caption.monospaced())
                .foregroundStyle(.secondary)
            if recording {
                Text(L("停下后才能放"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .well(radius: 10)
    }
}
