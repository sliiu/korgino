import Foundation

/// 综合笔记：系统声音和麦克风两条采集合成的一页。
/// 两边各取第一路，按时间排在一起，每段前写明是哪条采集，交给和一场笔记同一个写法。
extension SystemAudioTranslateController {
    /// Both captures are on. One capture alone already has its 一场笔记.
    var offersCombinedNote: Bool { captureSystem && captureMicrophone }

    func canWriteCombinedNote() -> Bool {
        offersCombinedNote && !combinedNote.writing && combinedBrief().hasCue
    }

    func writeCombinedNote(following: Bool? = nil) {
        let brief = combinedBrief()
        guard brief.hasCue else { return }
        combinedNoteTask?.cancel()
        combinedNote.generation += 1
        let generation = combinedNote.generation
        combinedNote.open = true
        combinedNote.writing = true
        combinedNote.error = ""
        combinedNote.follow = following ?? isActive
        combinedNote.attemptedAt = Date()
        combinedNoteTask = Task { @MainActor in
            let result = await SessionNoteWriter.write(brief)
            guard self.combinedNote.generation == generation else { return }
            self.combinedNote.writing = false
            switch result {
            case .success(let page):
                self.combinedNote.page = page
                self.combinedNote.error = ""
            case .failure(let failure):
                self.combinedNote.error = failure.message
            }
            self.combinedNoteTask = nil
        }
    }

    func closeCombinedNote() {
        combinedNoteTask?.cancel()
        combinedNoteTask = nil
        combinedNote.generation += 1
        combinedNote.open = false
        combinedNote.writing = false
        combinedNote.follow = false
        combinedNote.error = ""
    }

    /// New session or cleared captions: the page no longer matches anything on screen.
    func dismissCombinedNote() {
        combinedNoteTask?.cancel()
        combinedNoteTask = nil
        let generation = combinedNote.generation + 1
        combinedNote = SessionNoteSlot()
        combinedNote.generation = generation
    }

    /// Same pace as a following 一场笔记: enough new segments and a minute since the last ask.
    func refreshCombinedNote() {
        guard isActive, offersCombinedNote, combinedNote.open, combinedNote.follow, !combinedNote.writing else { return }
        let done = combinedNote.page?.cueCount ?? 0
        let since = Date().timeIntervalSince(combinedNote.attemptedAt ?? .distantPast)
        guard since >= Self.noteInterval, combinedBrief().cueCount - done >= Self.noteStep else { return }
        writeCombinedNote(following: true)
    }

    /// At 停止: one last page when something new settled.
    func finishCombinedNote() {
        guard combinedNote.open, combinedNote.follow else { return }
        if !combinedNote.writing, combinedBrief().cueCount > (combinedNote.page?.cueCount ?? 0) {
            writeCombinedNote(following: false)
        } else {
            combinedNote.follow = false
        }
    }

    /// The lane a cited segment lives on, for jumping back to it.
    func combinedSegmentLane(_ id: UUID) -> UUID? {
        (systemSegments.first { $0.id == id } ?? micSegments.first { $0.id == id })?.laneID
    }

    func combinedBrief() -> SessionNoteBrief {
        var cues: [(start: TimeInterval, cue: SessionNoteCue)] = []
        var preferredID: String?
        for kind in SourceKind.allCases where captures(kind) {
            // Further lanes on one capture hear the same speech; the first one speaks for it.
            guard let lane = lanes(kind).first else { continue }
            let binding = noteBinding(lane)
            if preferredID == nil, !binding.isSource { preferredID = binding.id }
            for seg in (kind == .system ? systemSegments : micSegments) where seg.laneID == lane.id {
                let translation: String? = {
                    if binding.isSource { return seg.source }
                    let raw = seg.translations[binding.key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return raw.isEmpty ? nil : raw
                }()
                let speaker = markToken(lane: lane.id, kind: kind, speaker: seg.speaker) ?? ""
                cues.append((seg.start, SessionNoteCue(
                    id: seg.id.uuidString,
                    mark: speaker.isEmpty ? kind.title : "\(kind.title) \(speaker)",
                    source: seg.source,
                    translation: translation,
                    waiting: noteWaiting(seg, binding: binding)
                )))
            }
        }
        cues.sort { $0.start < $1.start }
        let binding = SessionNoteBinding(
            id: preferredID ?? SessionNoteBinding.source.id,
            key: "combined",
            isSource: false,
            translatesToNative: true
        )
        var brief = SessionNote.brief(cues.map(\.cue), binding: binding)
        if preferredID == nil { brief.serviceID = nil }
        return brief
    }
}
