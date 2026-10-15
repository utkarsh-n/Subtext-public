import Foundation

/// Offset histogram shared by recognised phrases and signature hits (signature.md §3.5,
/// Wang-style time-offset clustering applied to cues). Each vote says "cue *c* was heard at
/// wall *w*", which under rate *r* implies the film offset `cues[c].start − (w − sessionStart)·r`.
/// Votes for the same place in the film pile into the same 1 s bin; a repeated line spreads its
/// votes over its instances and produces no peak — abstain, don't guess.
///
/// Peak rule (decided here, see the WP4 report): the *weight* of a bin is the sum over the bin
/// and its two neighbours, so two observations that straddle a bin edge (rate / timing jitter)
/// still count as two. One observation (full weight + two halves) sums to 2.0, two agreeing
/// ones to ≥ 3.5; the 2.5 floor therefore means "at least two independent observations", which
/// is the spec's intent (a lone phrase or a lone signature never makes a peak) and keeps the
/// 1.5× ratio rule for repeats.
final class EvidenceLedger {
    enum Source: Sendable, Equatable { case phrase, signature, cluster }

    struct Vote: Sendable, Equatable {
        let cueIndex: Int
        let weight: Float
        let source: Source
        /// Can seed on its own merits: a phrase, or a signature that is neither clustered nor short.
        let strong: Bool
        init(cueIndex: Int, weight: Float, source: Source, strong: Bool = false) {
            self.cueIndex = cueIndex
            self.weight = weight
            self.source = source
            self.strong = strong
        }
    }

    struct Peak: Sendable, Equatable {
        /// Film offset: media time at `sessionStart` under the voted rate.
        let offsetSeconds: Double
        /// Three-bin sum at the peak.
        let weight: Float
        /// Peak over the best three-bin sum outside ±`exclusionBins` (10 when nothing competes).
        let confidence: Float
        /// Distinct cues that voted into the peak bin and its neighbours.
        let distinctCues: Int
        /// Of those, the ones that voted as `strong`.
        let distinctStrongCues: Int
    }

    var binSeconds = 1.0
    var halfLifeSeconds = 40.0
    /// Peak rule: three-bin weight ≥ `minPeakWeight` and ≥ `minRatio` × the best three-bin
    /// weight outside ±`exclusionBins`.
    var minPeakWeight: Float = 2.5
    var minRatio: Float = 1.5
    var exclusionBins = 5

    private struct Entry { var weight: Float; var cues: Set<Int>; var strong: Set<Int> = [] }
    private var bins: [Int: Entry] = [:]
    private var lastDecay: Date?
    private(set) var voteCount = 0

    func reset() {
        bins = [:]
        lastDecay = nil
        voteCount = 0
    }

    /// The bin a vote for `cue` heard at `wall` would land in.
    func bin(forCue cue: Int, heardAt wall: Date, sessionStart: Date, rate: Double, cues: [Cue]) -> Int {
        guard cue >= 0, cue < cues.count else { return 0 }
        let elapsed = wall.timeIntervalSince(sessionStart) * rate
        return Int(((cues[cue].start - elapsed) / binSeconds).rounded())
    }

    /// Adds votes heard at `wall`. Each vote goes to bin `round(offset / binSeconds)` with full
    /// weight and to both neighbours with half weight.
    func add(_ votes: [Vote], heardAt wall: Date, sessionStart: Date, rate: Double, cues: [Cue]) {
        decay(to: wall)
        for v in votes where v.cueIndex >= 0 && v.cueIndex < cues.count && v.weight > 0 {
            let bin = bin(forCue: v.cueIndex, heardAt: wall, sessionStart: sessionStart, rate: rate, cues: cues)
            deposit(bin, v.weight, v.cueIndex, v.strong)
            deposit(bin - 1, v.weight * 0.5, v.cueIndex, v.strong)
            deposit(bin + 1, v.weight * 0.5, v.cueIndex, v.strong)
            voteCount += 1
        }
    }

    private func deposit(_ bin: Int, _ w: Float, _ cue: Int, _ strong: Bool) {
        var e = bins[bin] ?? Entry(weight: 0, cues: [])
        e.weight += w
        e.cues.insert(cue)
        if strong { e.strong.insert(cue) }
        bins[bin] = e
    }

    private func decay(to now: Date) {
        guard let last = lastDecay else { lastDecay = now; return }
        let dt = now.timeIntervalSince(last)
        // A vote stamped earlier than the last decay (a phrase's *start* time arrives after the
        // ledger already decayed to a later `now`) must not move the decay clock backwards, or
        // the next call decays the same interval twice (reviewer fix).
        guard dt > 0 else { return }
        let factor = Float(pow(0.5, dt / halfLifeSeconds))
        for (k, var e) in bins {
            e.weight *= factor
            if e.weight < 0.05 { bins[k] = nil } else { bins[k] = e }
        }
        lastDecay = now
    }

    private func sum3(_ b: Int) -> Float {
        (bins[b - 1]?.weight ?? 0) + (bins[b]?.weight ?? 0) + (bins[b + 1]?.weight ?? 0)
    }

    /// The peak bin if it passes the weight and ratio rules, else nil.
    func peak(at now: Date) -> Peak? {
        decay(to: now)
        guard !bins.isEmpty else { return nil }
        var bestBin = 0, best: Float = -1
        for k in bins.keys {
            let s = sum3(k)
            if s > best || (s == best && k < bestBin) { best = s; bestBin = k }
        }
        guard best >= minPeakWeight else { return nil }
        var runnerUp: Float = 0
        for k in bins.keys where abs(k - bestBin) > exclusionBins {
            runnerUp = max(runnerUp, sum3(k))
        }
        let confidence = runnerUp > 0 ? best / runnerUp : 10
        guard confidence >= minRatio else { return nil }
        // Refine the offset as the weight-centred position over the peak and its neighbours.
        var num = 0.0, den = 0.0
        var cues: Set<Int> = []
        var strong: Set<Int> = []
        for d in -1...1 {
            if let e = bins[bestBin + d] {
                num += Double(bestBin + d) * Double(e.weight)
                den += Double(e.weight)
                cues.formUnion(e.cues)
                strong.formUnion(e.strong)
            }
        }
        let offset = (den > 0 ? num / den : Double(bestBin)) * binSeconds
        return Peak(offsetSeconds: offset, weight: best, confidence: min(10, confidence), distinctCues: cues.count, distinctStrongCues: strong.count)
    }

    /// Media time implied by a peak at `now`.
    func mediaTime(for peak: Peak, at now: Date, sessionStart: Date, rate: Double) -> Double {
        peak.offsetSeconds + now.timeIntervalSince(sessionStart) * rate
    }
}
