import AppKit
import Combine
import Foundation

extension Notification.Name {
    /// `object` is the record's UUID when one record changed, nil when the list did.
    static let korgiMeetingRecordsChanged = Notification.Name("Korgino.meetingRecordsChanged")
}

private let meetingRecordQueue = DispatchQueue(label: "com.sliiu.Korgino.meetingrecord", qos: .utility)

/// 会议记录 as the live window writes it: one folder per session, saved a few seconds after each change.
extension SystemAudioTranslateController {
    static func recordAudioName(_ kind: SourceKind) -> String { "\(kind.rawValue).m4a" }

    /// Called at 开始, after the last session was saved and the window cleared.
    func beginRecord() {
        recordSaveTask?.cancel()
        recordSaveTask = nil
        recordID = nil
        recordFolder = nil
        recordStartedAt = nil
        recordEndedAt = nil
        recordTitle = ""
        recordKinds = SourceKind.allCases.filter { captures($0) }
        watchRecord()
        guard keepRecords else { return }
        let id = UUID()
        let now = Date()
        guard let folder = try? MeetingStore.makeFolder(id: id, startedAt: now) else { return }
        recordID = id
        recordFolder = folder
        recordStartedAt = now
    }

    /// Listening never began: drop the folder unless something was kept.
    func abandonRecordIfEmpty() {
        guard let folder = recordFolder else { return }
        if !recordHasSegments {
            try? MeetingStore.delete(folder)
            recordID = nil
            recordFolder = nil
        }
    }

    /// At 停止. Following notes get one last page; the record is saved once more when it lands.
    func finishRecord() {
        recordEndedAt = Date()
        finishFollowingNotes()
        guard let folder = recordFolder else { return }
        let hasAudio = recordings.values.contains { $0.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL }
        if !recordHasSegments, !hasAudio {
            try? MeetingStore.delete(folder)
            recordID = nil
            recordFolder = nil
            NotificationCenter.default.post(name: .korgiMeetingRecordsChanged, object: nil)
            return
        }
        saveRecordNow()
    }

    /// The 会议记录 window deleted this record: stop writing to it. The captions stay on screen.
    func forgetRecord(_ id: UUID) {
        guard recordID == id else { return }
        recordSaveTask?.cancel()
        recordSaveTask = nil
        if let folder = recordFolder?.standardizedFileURL {
            recordings = recordings.filter { $0.value.deletingLastPathComponent().standardizedFileURL != folder }
        }
        recordID = nil
        recordFolder = nil
    }

    /// At quit: close the recordings so the m4a files play, then write the record.
    func prepareForQuit() {
        for recorder in recorders.values { recorder.stop() }
        if isActive { recordEndedAt = Date() }
        saveRecordNow(sync: true)
    }

    func setRecordTitle(_ title: String) {
        recordTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        saveRecordNow()
    }

    private var recordHasSegments: Bool {
        recordKinds.contains { kind in
            !(kind == .system ? systemSegments : micSegments).isEmpty
        }
    }

    private func watchRecord() {
        guard recordSinks.isEmpty else { return }
        let poke: () -> Void = { [weak self] in
            MainActor.assumeIsolated { self?.scheduleRecordSave() }
        }
        recordSinks = [
            $systemSegments.dropFirst().sink { _ in poke() },
            $micSegments.dropFirst().sink { _ in poke() },
            $systemLanes.dropFirst().sink { _ in poke() },
            $micLanes.dropFirst().sink { _ in poke() },
        ]
    }

    func scheduleRecordSave() {
        guard recordID != nil else { return }
        recordSaveTask?.cancel()
        recordSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.saveRecordNow()
        }
    }

    /// `sync` only at quit, so the file is down before the process ends.
    func saveRecordNow(sync: Bool = false) {
        recordSaveTask?.cancel()
        recordSaveTask = nil
        guard let folder = recordFolder, let record = snapshotRecord() else { return }
        // Nothing heard yet: leave the folder without a record, so the list does not show an empty session.
        if record.segments.isEmpty, record.audio.isEmpty || isActive { return }
        let id = record.id
        if sync {
            meetingRecordQueue.sync { try? MeetingStore.save(record, in: folder) }
            return
        }
        meetingRecordQueue.async {
            try? MeetingStore.save(record, in: folder)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .korgiMeetingRecordsChanged, object: id)
            }
        }
    }

    func snapshotRecord() -> MeetingRecord? {
        guard let id = recordID, let started = recordStartedAt else { return nil }
        let cfg = AppConfig.shared
        var lanesOut: [MeetingRecord.Lane] = []
        var segmentsOut: [MeetingRecord.Segment] = []
        for kind in recordKinds {
            let segs = kind == .system ? systemSegments : micSegments
            for lane in lanes(kind) {
                let mine = segs.filter { $0.laneID == lane.id }
                var bindings = lane.bindings
                for seg in mine {
                    for key in seg.translations.keys.sorted() where !bindings.contains(where: { $0.key == key }) {
                        if let b = LaneBinding(key: key) { bindings.append(b) }
                    }
                }
                let asr = cfg.liveASRChoices().first { $0.id == lane.asrID }?.name ?? lane.asrID
                var renamed: [String: String] = [:]
                for (number, name) in lane.marks.renamed { renamed[String(number)] = name }
                var voices: [String: String] = [:]
                for (number, voice) in lane.marks.voices { voices[String(number)] = voice }
                lanesOut.append(MeetingRecord.Lane(
                    id: lane.id,
                    capture: kind.rawValue,
                    captureTitle: kind.title,
                    asrID: lane.asrID,
                    asrName: asr,
                    language: asrLanguage(for: kind).title,
                    languageCode: asrLanguage(for: kind).locale.identifier,
                    bindings: bindings.map { MeetingRecord.Binding(key: $0.key, title: LaneBindingNames.title($0)) },
                    marks: MeetingRecord.Marks(renamed: renamed, removed: lane.marks.removed.sorted(), voices: voices),
                    note: lane.note.page
                ))
                for seg in mine {
                    var translations: [String: String] = [:]
                    for (key, text) in seg.translations where seg.errors[key] == nil && !seg.loadingProviderIDs.contains(key) {
                        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !t.isEmpty, t != "—", t != L("翻译中…"), !t.hasPrefix(L("翻译失败")) else { continue }
                        translations[key] = t
                    }
                    segmentsOut.append(MeetingRecord.Segment(
                        id: seg.id,
                        laneID: lane.id,
                        start: seg.start,
                        end: seg.end,
                        speaker: seg.speaker,
                        source: seg.source,
                        translations: translations
                    ))
                }
            }
        }
        var audio: [String: String] = [:]
        if let folder = recordFolder {
            for kind in recordKinds {
                let name = Self.recordAudioName(kind)
                if FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
                    audio[kind.rawValue] = name
                }
            }
        }
        return MeetingRecord(
            id: id,
            title: recordTitle,
            startedAt: started,
            endedAt: isActive ? Date() : (recordEndedAt ?? Date()),
            lanes: lanesOut,
            segments: segmentsOut,
            audio: audio
        )
    }

    // MARK: Speakers

    func marksResolve(_ lane: UUID, _ kind: SourceKind, _ speaker: Int) -> Int {
        guard speaker > 0 else { return speaker }
        return lanes(kind).first { $0.id == lane }?.marks.resolve(speaker) ?? speaker
    }

    /// Joins two speakers of one lane. Past segments move now; later ones are mapped as they arrive.
    func mergeSpeaker(_ lane: UUID, _ kind: SourceKind, _ from: Int, into: Int) {
        guard from != into else { return }
        editLane(lane, kind) { $0.marks.merge(from, into: into) }
        func patch(_ arr: inout [LiveCaptionSegment]) {
            for i in arr.indices where arr[i].laneID == lane && arr[i].speaker == from {
                arr[i].speaker = into
            }
        }
        switch kind {
        case .system: patch(&systemSegments)
        case .microphone: patch(&micSegments)
        }
        if var draft = laneDrafts[lane], draft.speaker == from {
            draft.speaker = into
            laneDrafts[lane] = draft
        }
        refreshImmersiveOverlay()
    }

    func attachVoiceTagger(_ kind: SourceKind, to fan: LaneFan) {
        voiceTaggers[kind] = nil
        guard VoiceprintModel.shared.isReady else { return }
        let tagger = VoiceTagger()
        do {
            try tagger.prepare()
        } catch {
            return
        }
        fan.children.append(tagger)
        voiceTaggers[kind] = tagger
    }

    /// The voiceprint model names the speaker of a finished segment a moment after it lands.
    func tagVoice(_ seg: LiveCaptionSegment) {
        guard let tagger = voiceTaggers[seg.kind] else { return }
        let interp = lanes(seg.kind).contains { $0.id == seg.laneID && AppConfig.shared.isInterpASR($0.asrID) }
        guard !interp || reseparateInterp else { return }
        let id = seg.id
        let kind = seg.kind
        let lane = seg.laneID
        tagger.tag(start: seg.start, end: seg.end) { [weak self] number in
            guard let self, let number else { return }
            let speaker = self.marksResolve(lane, kind, number)
            func patch(_ arr: inout [LiveCaptionSegment]) {
                guard let i = arr.firstIndex(where: { $0.id == id }), arr[i].speaker != speaker else { return }
                arr[i].speaker = speaker
            }
            switch kind {
            case .system: patch(&self.systemSegments)
            case .microphone: patch(&self.micSegments)
            }
            if self.immersiveMode { self.refreshImmersiveOverlay() }
        }
    }
}
