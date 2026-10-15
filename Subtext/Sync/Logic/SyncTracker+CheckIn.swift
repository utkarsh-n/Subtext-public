import Foundation

// Pure Foundation (+ the Accelerate-backed Correlator). Compiled into the app and into
// Tools/synctest (Subtext/Sync/Logic/**).
//
// docs/v2/checkin.md §4 with the critique's C3/C11 merges: one check-in = one ring slice, the
// evidence gate (W 30 → 45 → 60 s), the hypothesis stage (resume A/B, probing P/C, pending
// large-delta confirmation) and the tier ladder T0 → T1 → T2 → T3 on that window. The tracker's
// `lock` is never mutated here: the result is applied through the scheduler's belief clock and
// `SessionAction.setClock` (critique D5).

extension SyncTracker {
    /// One search range of the ladder, relative to the primary hypothesis.
    enum SearchTier: Equatable {
        /// T0: ±`checkInNarrowRadius` (4 s).
        case narrow
        /// T1: ±radius (±max(10, 3 + 0.05 × Δt), cap 45).
        case medium(radius: Double)
        /// T2 / tier R: `[predicted − behind, predicted + ahead]`.
        case asymmetric(behind: Double, ahead: Double)
        /// T3: the whole track at every `searchRates` entry, V1 full-search acceptance.
        case full

        /// Index into `tuning.tierOnsetZ` / `tierMinOnsets` (T3 uses V1 search thresholds).
        var index: Int {
            switch self {
            case .narrow: 0
            case .medium: 1
            case .asymmetric: 2
            case .full: 3
            }
        }
    }

    /// An alternative belief about where the film is: a trim-free clock, evaluated at the window start.
    struct Hypothesis: Equatable {
        var name: String
        var clock: PlaybackClock
    }

    struct CheckInRequest: Equatable {
        enum Kind: Equatable {
            case scheduled
            case probeAlarm
            case nudge
            case forced
            /// Verification 6 s (then 10 s) after a large correction: T0 on the last 20 s.
            case verify
            /// Second look at a pending > 8 s delta with no evidence: apply only if it agrees.
            case confirm(delta: Double)
            /// After a hold: hypotheses A/B (±5 s) then tier R.
            case resume
            /// Probing with the clock frozen: hypotheses P/C (±3 s), then tier R, then the ladder.
            case probing
            /// `lost`: T2 with the growing behind radius (and T3 from the second miss).
            case lost
            /// Re-sync single tap: T1 ±45 s then T2 ±5 min before any full search.
            case resync
        }

        var kind: Kind
        /// `hypotheses[0]` is the belief; the others are alternatives. Each gets a ±`hypothesisRadius`
        /// search under the T0 rule before the tiers run around `hypotheses[0]`.
        var hypotheses: [Hypothesis]
        /// nil → no hypothesis stage (the tiers run around `hypotheses[0]` only).
        var hypothesisRadius: Double?
        /// Candidate rates for stretch votes (T0/T1 and the hypothesis stage). Empty = current rate only.
        var rates: [Double] = []
        var tiers: [SearchTier]
        /// Evidence-gate ladder of window lengths, tried in order until one has enough evidence.
        var windowSeconds: [Double]
        /// Bins before this instant are never used (post-release audio only).
        var notBefore: Date? = nil
        /// Island Play / user resume: a > 8 s delta is applied without the +10 s confirmation.
        var allowLargeImmediately = false
        /// A miss on a window with fewer onsets than this is reported `.inconclusive` (thin
        /// evidence is not proof of a wrong position; the retry gets a longer window). 0 = off.
        var missMinOnsets = 0
        /// Catch-up: `behind > 60 s` uses `catchUpOnsetZ` on T2 (critique R1).
        var issuedAt: Date

        var rate: Double { hypotheses.first?.clock.rate ?? 1 }

        func predicted(at wall: Date) -> Double { hypotheses.first?.clock.mediaTime(at: wall) ?? 0 }
    }

    struct CheckInResult {
        enum Outcome: Equatable {
            /// `residual` = measured − predicted at `windowStart` (primary hypothesis). `hypothesis`
            /// is the index of the winning alternative (0 = belief) when the hypothesis stage won.
            case accepted(mediaAtStart: Double, rate: Double, score: Float, tier: Int, residual: Double, hypothesis: Int?)
            case inconclusive(String)
            case miss
        }

        var outcome: Outcome
        var windowStart: Date
        var windowSeconds: Double
        var onsets: Int
        var speechFraction: Double
        /// Best-onsetZ candidate rate among `request.rates` at T0 (a stretch vote), when it was accepted.
        var votedRate: Double?
        /// Max onsetZ seen per tier index (also for rejected matches): harness S6 sets `tierOnsetZ` from it.
        var tierMaxOnsetZ: [Int: Float] = [:]
        var correlations = 0
        var milliseconds = 0.0
        var note = ""

        var isConclusive: Bool {
            if case .inconclusive = outcome { return false }
            return true
        }
    }

    struct ProbeRequest: Equatable {
        var clock: PlaybackClock
        var windowSeconds: Double
        var radius: Double
        /// Bins before this instant are never used (post-release audio only).
        var notBefore: Date? = nil
    }

    struct ProbeResult: Equatable {
        /// False when the window had too little evidence (not a miss either).
        var adequate: Bool
        var hit: Bool
        /// measured − predicted at the window start, when `hit`.
        var residual: Double?
        var onsetZ: Float
        var correlations: Int
    }

    // MARK: Ring entry points

    /// Slices the ring per the evidence-gate ladder and runs the check-in on the first window with
    /// enough evidence. Windows shorter than `trackMinWindowSeconds` or with thin evidence at every
    /// length are `.inconclusive` (never a miss, never a state change).
    func checkIn(_ req: CheckInRequest, ring: MicRing, now: Date) -> CheckInResult {
        var lastReason = "no audio"
        var lastStart = now
        var lastSeconds = 0.0
        var lastOnsets = 0
        var lastFraction = 0.0
        var triedLength = -1.0
        for w in req.windowSeconds {
            guard var (bins, start) = ring.latest(seconds: w) else { continue }
            if let nb = req.notBefore, start < nb {
                let drop = min(bins.count, SpeechEnvelope.bin(for: nb.timeIntervalSince(start)))
                bins.removeFirst(drop)
                start = start.addingTimeInterval(Double(drop) * SpeechEnvelope.binDuration)
            }
            let seconds = Double(bins.count) * SpeechEnvelope.binDuration
            if abs(seconds - triedLength) < 0.05 { continue }   // the ring had no more to give
            triedLength = seconds
            let (ok, reason, onsets, fraction) = evidence(bins)
            lastReason = reason; lastStart = start; lastSeconds = seconds; lastOnsets = onsets; lastFraction = fraction
            if ok { return checkIn(req, window: bins, windowStart: start, now: now) }
        }
        return CheckInResult(outcome: .inconclusive(lastReason), windowStart: lastStart, windowSeconds: lastSeconds,
                             onsets: lastOnsets, speechFraction: lastFraction, note: "inconclusive: \(lastReason)")
    }

    /// Probe: T0 ±`radius` on the last `windowSeconds`; never applies anything.
    func probe(_ req: ProbeRequest, ring: MicRing, now: Date) -> ProbeResult {
        guard var (bins, start) = ring.latest(seconds: req.windowSeconds) else {
            return ProbeResult(adequate: false, hit: false, residual: nil, onsetZ: 0, correlations: 0)
        }
        if let nb = req.notBefore, start < nb {
            let drop = min(bins.count, SpeechEnvelope.bin(for: nb.timeIntervalSince(start)))
            bins.removeFirst(drop)
            start = start.addingTimeInterval(Double(drop) * SpeechEnvelope.binDuration)
        }
        let (ok, _, _, _) = evidence(bins)
        guard ok else { return ProbeResult(adequate: false, hit: false, residual: nil, onsetZ: 0, correlations: 0) }
        let predicted = req.clock.mediaTime(at: start)
        guard let m = search(bins, rate: req.clock.rate, centre: predicted, behind: req.radius, ahead: req.radius) else {
            return ProbeResult(adequate: true, hit: false, residual: nil, onsetZ: 0, correlations: 1)
        }
        let hit = accepts(m, tier: 0, behind: req.radius)
        return ProbeResult(adequate: true, hit: hit, residual: hit ? m.mediaTime - predicted : nil, onsetZ: m.onsetZ, correlations: 1)
    }

    // MARK: One window

    /// The check-in proper on one window (already past the evidence gate). `milliseconds` is the
    /// wall time of the hypothesis stage and the tier ladder (the "ms per check-in" number).
    func checkIn(_ req: CheckInRequest, window: [Float], windowStart: Date, now: Date) -> CheckInResult {
        let started = Date()
        var result = checkInBody(req, window: window, windowStart: windowStart, now: now)
        result.milliseconds = Date().timeIntervalSince(started) * 1000
        return result
    }

    private func checkInBody(_ req: CheckInRequest, window: [Float], windowStart: Date, now: Date) -> CheckInResult {
        let seconds = Double(window.count) * SpeechEnvelope.binDuration
        let (ok, reason, onsets, fraction) = evidence(window)
        var result = CheckInResult(outcome: .inconclusive(reason), windowStart: windowStart, windowSeconds: seconds,
                                   onsets: onsets, speechFraction: fraction)
        guard ok, let primary = req.hypotheses.first else {
            result.note = "inconclusive: \(reason)"
            return result
        }
        let predicted = primary.clock.mediaTime(at: windowStart)
        let currentRate = primary.clock.rate
        let candidateRates = req.rates.isEmpty ? [currentRate] : uniqueRates([currentRate] + req.rates)

        // Hypothesis stage: every hypothesis at ±radius, the T0 rule, best onsetZ wins, ties to the first.
        if let radius = req.hypothesisRadius {
            var best: (index: Int, match: Correlator.Match, rate: Double)?
            var bestZ: Float = -.infinity
            for (i, h) in req.hypotheses.enumerated() {
                let centre = h.clock.mediaTime(at: windowStart)
                for r in candidateRates {
                    guard let m = search(window, rate: r, centre: centre, behind: radius, ahead: radius) else { continue }
                    result.correlations += 1
                    result.tierMaxOnsetZ[0] = max(result.tierMaxOnsetZ[0] ?? -.infinity, m.onsetZ)
                    guard accepts(m, tier: 0, behind: radius), m.onsetZ > bestZ else { continue }
                    bestZ = m.onsetZ
                    best = (i, m, r)
                }
            }
            if let best {
                let tier = 0
                let residual = best.match.mediaTime - predicted
                if candidateRates.count > 1 { result.votedRate = best.rate }
                result.outcome = .accepted(mediaAtStart: best.match.mediaTime, rate: best.rate, score: best.match.score,
                                           tier: tier, residual: residual, hypothesis: best.index)
                result.note = String(format: "hypothesis %@ r %+.2f oz %.1f score %.2f n %d", req.hypotheses[best.index].name,
                                     residual, best.match.onsetZ, best.match.score, best.match.onsetCount)
                return result
            }
        }

        // Tier ladder around the primary hypothesis; stop at the first acceptance.
        for tier in req.tiers {
            switch tier {
            case .full:
                // T3 = V1's full / hinted search (checkin.md §4): a fresh transcript hint narrows the
                // range to ±hintWindowSeconds around it with the hinted thresholds, exactly as
                // `analyse` does, so the transcriber restarted for probing / lost is of use here.
                var range = 0..<reference.count
                var hinted = false
                if let hint, now.timeIntervalSince(hint.wall) < tuning.hintMaxAge {
                    let centre = SpeechEnvelope.bin(for: hint.mediaTime + windowStart.timeIntervalSince(hint.wall))
                    let radius = SpeechEnvelope.bin(for: hintRadiusSeconds ?? tuning.hintWindowSeconds)
                    let lo = max(0, centre - radius), hi = min(reference.count, centre + radius)
                    if hi > lo + 1 { range = lo..<hi; hinted = true }
                }
                var best: (match: Correlator.Match, rate: Double)?
                for r in tuning.searchRates {
                    let stretched = SpeechEnvelope.stretched(window, rate: r)
                    guard let m = Correlator.search(mic: stretched, reference: reference, range: range) else { continue }
                    result.correlations += 1
                    if best == nil || m.onsetZ > best!.match.onsetZ { best = (m, r) }
                }
                guard let (m, r) = best else { continue }
                result.tierMaxOnsetZ[3] = max(result.tierMaxOnsetZ[3] ?? -.infinity, m.onsetZ)
                let accepted = hinted
                    ? (m.score >= tuning.hintedScore && m.onsetCount >= tuning.hintedMinOnsets
                       && m.onsetZ >= tuning.hintedOnsetZ && m.onsetMargin >= tuning.hintedOnsetMargin)
                    : (m.score >= tuning.searchScore && m.zScore >= tuning.searchZ
                       && m.onsetCount >= tuning.searchMinOnsets && m.onsetZ >= tuning.searchOnsetZ
                       && m.onsetMargin >= tuning.searchOnsetMargin)
                if accepted {
                    let residual = m.mediaTime - predicted
                    result.outcome = .accepted(mediaAtStart: m.mediaTime, rate: r, score: m.score, tier: 3, residual: residual, hypothesis: nil)
                    result.note = String(format: "T3 %@ r %+.1f oz %.1f z %.1f score %.2f rate %.3f", hinted ? "hinted" : "full", residual, m.onsetZ, m.zScore, m.score, r)
                    return result
                }
            case .narrow, .medium, .asymmetric:
                let (behind, ahead): (Double, Double) = {
                    switch tier {
                    case .narrow: return (tuning.checkInNarrowRadius, tuning.checkInNarrowRadius)
                    case .medium(let r): return (r, r)
                    case .asymmetric(let b, let a): return (b, a)
                    case .full: return (0, 0)
                    }
                }()
                let rates = tier.index <= 1 ? candidateRates : [currentRate]
                var best: (match: Correlator.Match, rate: Double)?
                for r in rates {
                    guard let m = search(window, rate: r, centre: predicted, behind: behind, ahead: ahead) else { continue }
                    result.correlations += 1
                    if best == nil || m.onsetZ > best!.match.onsetZ { best = (m, r) }
                }
                guard let (m, r) = best else { continue }
                result.tierMaxOnsetZ[tier.index] = max(result.tierMaxOnsetZ[tier.index] ?? -.infinity, m.onsetZ)
                if accepts(m, tier: tier.index, behind: behind) {
                    let residual = m.mediaTime - predicted
                    if rates.count > 1 { result.votedRate = r }
                    result.outcome = .accepted(mediaAtStart: m.mediaTime, rate: r, score: m.score, tier: tier.index, residual: residual, hypothesis: nil)
                    result.note = String(format: "T%d r %+.2f oz %.1f score %.2f n %d rate %.3f", tier.index, residual, m.onsetZ, m.score, m.onsetCount, r)
                    return result
                }
            }
        }
        let seen = result.tierMaxOnsetZ.keys.sorted().map { String(format: "T%d %.1f", $0, result.tierMaxOnsetZ[$0]!) }.joined(separator: " ")
        if onsets < req.missMinOnsets {
            result.outcome = .inconclusive("thin miss (\(onsets) onsets)")
            result.note = "inconclusive: thin miss (n \(onsets), \(seen))"
            return result
        }
        result.outcome = .miss
        result.note = "miss (n \(onsets), \(seen))"
        return result
    }

    // MARK: Pieces

    /// The evidence gate: enough audio, a plausible speech fraction, ≥ `checkInMinOnsets` onsets.
    func evidence(_ bins: [Float]) -> (ok: Bool, reason: String, onsets: Int, fraction: Double) {
        let seconds = Double(bins.count) * SpeechEnvelope.binDuration
        let fraction = SpeechEnvelope.speechFraction(bins)
        let onsets = SpeechEnvelope.onsets(in: bins).count
        if seconds < tuning.trackMinWindowSeconds { return (false, "too short (\(Int(seconds)) s)", onsets, fraction) }
        if fraction < tuning.minSpeechFraction { return (false, "too little speech", onsets, fraction) }
        if fraction > tuning.maxSpeechFraction { return (false, "constant noise", onsets, fraction) }
        if onsets < tuning.checkInMinOnsets { return (false, "\(onsets) onsets", onsets, fraction) }
        return (true, "", onsets, fraction)
    }

    /// One correlation of the window (stretched to `rate`) over media `[centre − behind, centre + ahead]`.
    func search(_ window: [Float], rate: Double, centre: Double, behind: Double, ahead: Double) -> Correlator.Match? {
        let stretched = SpeechEnvelope.stretched(window, rate: rate)
        let c = SpeechEnvelope.bin(for: centre)
        let lo = max(0, c - SpeechEnvelope.bin(for: behind))
        let hi = min(reference.count, c + SpeechEnvelope.bin(for: ahead) + 1)
        guard hi > lo + 1 else { return nil }
        return Correlator.search(mic: stretched, reference: reference, range: lo..<hi)
    }

    /// Per-tier acceptance (checkin.md §4): score, and when onsets suffice onsetScore/onsetZ/margin.
    /// A behind radius over 60 s (catch-up) uses `catchUpOnsetZ` instead of the tier's threshold.
    func accepts(_ m: Correlator.Match, tier: Int, behind: Double) -> Bool {
        let k = min(max(tier, 0), 2)
        let minOnsets = tuning.tierMinOnsets[min(k, tuning.tierMinOnsets.count - 1)]
        var z = tuning.tierOnsetZ[min(k, tuning.tierOnsetZ.count - 1)]
        if behind > tuning.checkInAheadSeconds { z = max(z, tuning.catchUpOnsetZ) }
        guard m.score >= tuning.tierScore, m.onsetCount >= minOnsets else { return false }
        return m.onsetScore >= tuning.tierOnsetScore && m.onsetZ >= z && m.onsetMargin >= tuning.tierOnsetMargin
    }

    private func uniqueRates(_ rates: [Double]) -> [Double] {
        var out: [Double] = []
        for r in rates where !out.contains(where: { abs($0 - r) < 1e-6 }) { out.append(r) }
        return out
    }
}
