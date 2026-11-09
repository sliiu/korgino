import Foundation

/// 声纹分人：一句一个 256 维声纹，按到达顺序并进最像的那个人。已经给出的号不再改。
/// 像谁就并进谁；够长又谁都不像才算新的人；其余不给号。号从 1 起。
/// Thresholds after wquguru/cicada SpeakerID.swift (tuned on AMI meetings), Apache-2.0.
struct VoiceCluster: Codable, Equatable {
    /// Cosine to a voice's centroid at or above this joins it.
    static let join: Float = 0.5
    /// A clip shorter than `newSeconds` never starts a voice and joins only at this bar.
    /// Cicada uses the same bar as `join`; raise it if short lines land on the wrong person.
    static let joinShort: Float = 0.5
    /// A clip at least this long, below `startNew` to every voice, starts a new one.
    static let newSeconds = 2.0
    static let startNew: Float = 0.5
    static let maxSpeakers = 12

    /// Per voice, the sum of its unit voiceprints. Cosine to a sum is cosine to the mean.
    private(set) var sums: [[Float]] = []
    /// Clips per voice.
    private(set) var counts: [Int] = []
    /// 0-based voice → the voice it was merged into. A merged voice keeps its own centroid,
    /// so later clips like either side still match; the match is reported as the target.
    private(set) var mergedInto: [Int: Int] = [:]

    init() {}

    var speakerCount: Int { sums.count - mergedInto.count }

    /// 1-based speaker number for a voiceprint, or nil when unsure. Counts towards that speaker.
    mutating func label(_ v: [Float], seconds: Double) -> Int? {
        guard let u = Self.unit(v) else { return nil }
        if let d = sums.first?.count, d != u.count { return nil }
        let (best, sim) = closest(u)
        let short = seconds < Self.newSeconds
        if best >= 0, sim >= (short ? Self.joinShort : Self.join) {
            add(u, to: best)
            return resolve(best) + 1
        }
        guard !short, best < 0 || sim < Self.startNew, speakerCount < Self.maxSpeakers else { return nil }
        sums.append(u)
        counts.append(1)
        return sums.count
    }

    /// The user said two speakers are one: later clips like either get `into`. 1-based.
    mutating func merge(_ from: Int, into: Int) {
        let f = resolve(from - 1), t = resolve(into - 1)
        guard sums.indices.contains(f), sums.indices.contains(t), f != t else { return }
        mergedInto[f] = t
    }

    /// Where a 1-based number went after merges; nil if it never existed.
    func current(_ number: Int) -> Int? {
        let i = resolve(number - 1)
        return sums.indices.contains(i) ? i + 1 : nil
    }

    /// A whole file at once: one online pass in order, then each clip moves to its closest final voice.
    /// Numbers are renumbered 1, 2, 3… in order of first appearance.
    static func batch(_ items: [(v: [Float], seconds: Double)]) -> [Int?] {
        var c = VoiceCluster()
        let units = items.map { unit($0.v) }
        var first: [Int?] = []
        for (i, u) in units.enumerated() {
            first.append(u.flatMap { c.label($0, seconds: items[i].seconds) })
        }
        var refined: [Int?] = []
        for (i, u) in units.enumerated() {
            guard let u else { refined.append(nil); continue }
            let (best, sim) = c.closest(u)
            let bar = items[i].seconds < newSeconds ? joinShort : join
            refined.append(best >= 0 && sim >= bar ? best + 1 : first[i])
        }
        var renumber: [Int: Int] = [:]
        return refined.map { n in
            guard let n else { return nil }
            if let m = renumber[n] { return m }
            renumber[n] = renumber.count + 1
            return renumber[n]
        }
    }

    // MARK: Math

    private func resolve(_ i: Int) -> Int {
        var i = i, hops = 0
        while let next = mergedInto[i], hops < sums.count { i = next; hops += 1 }
        return i
    }

    private func closest(_ u: [Float]) -> (index: Int, sim: Float) {
        var best = -1, bestSim: Float = -1
        for (i, s) in sums.enumerated() {
            var dot: Float = 0, sq: Float = 0
            for k in 0..<min(u.count, s.count) {
                dot += u[k] * s[k]
                sq += s[k] * s[k]
            }
            guard sq > 0 else { continue }
            let sim = dot / sq.squareRoot()
            if sim > bestSim { bestSim = sim; best = i }
        }
        return (best, bestSim)
    }

    private mutating func add(_ u: [Float], to i: Int) {
        for k in sums[i].indices { sums[i][k] += u[k] }
        counts[i] += 1
    }

    private static func unit(_ v: [Float]) -> [Float]? {
        var sq: Float = 0
        for x in v { sq += x * x }
        guard !v.isEmpty, sq > 0, sq.isFinite else { return nil }
        let n = sq.squareRoot()
        return v.map { $0 / n }
    }
}
