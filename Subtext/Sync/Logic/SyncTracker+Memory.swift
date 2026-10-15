import Foundation

/// What the memory step decided for one analysed window / tick (signature.md §5 `Report`
/// additions, kept beside WP0's `SyncTracker.Report` because that struct is frozen).
struct MemoryReport: Sendable, Equatable {
    /// The predicted cue's signature matched (r ≥ thr, |shift| ≤ 1 s, ≥ 2 s of speech).
    var confirmed = false
    var shiftSeconds: Double? = nil
    /// The signature-implied position was adopted because the envelope missed (bounded ±1 s).
    var adopted = false
    /// An unconfirmed candidate was injected (rewatch ledger peak, or two agreeing proposals).
    var seeded = false
    /// `seeded` from a *locked* state (a proposal-driven re-seed; the old lock is kept aside).
    var reseeded = false
    /// A memory-seeded candidate was rejected by the envelope and the previous lock restored.
    var restored = false
    /// A memory-seeded candidate was confirmed by the narrow envelope check on a short window.
    var quickConfirmed = false
    /// `tracker.hint` was set from the ledger (or the V1 direct phrase path) this step.
    var hinted = false
    /// A correction was proposed by another cue's signature (recorded as pending).
    var proposedCue: Int? = nil
    var r: Float? = nil
    var thr: Float = 0.65
    var note = ""
    var captured: [CueSignature] = []
    /// 10 s after a memory-seeded lock confirms ("Recognised from last time").
    var recognisedFromMemory = false
    /// Memory evidence suggests a shorter analysis window (critique C16); nil = caller's default.
    var suggestedWindowSeconds: Double? = nil
}

/// The audio-memory brain beside `SyncTracker` (signature.md §3): capture on the 1 Hz tick
/// (critique C10), signature confirm while locked / drifting (§3.3), the rewatch coarse-to-fine
/// search feeding the `EvidenceLedger` (§3.4), phrase candidates into the same ledger (§3.5), text
/// clusters (§3.6) and the suspect flag.
///
/// Rules it can never break (critique R7, D §6): memory may reset misses when it agrees, adopt a
/// position within ±1 s of the prediction (only the predicted cue, only while `.locked`, never
/// while drifting), vote into the ledger, and seed an *unconfirmed* candidate. It never writes a
/// confirmed lock on signature evidence alone and never loosens a measured threshold. The one
/// confirmed write it makes — `quickConfirm` — is V1's own narrow tracking acceptance (score,
/// onset score, ±1.5 s agreement) run on a 6–12 s window around a memory-seeded candidate.
///
/// Foundation only; runs on `analysisQueue` next to the tracker. WP7 owns one per session.
///
/// TODO(WP7) wiring (continuous mode): `analyse(mic:windowStart:now:mel:micRing:)` in place of
/// `tracker.analyse`, with the window sized by `suggestedWindowSeconds(at:)`; `captureOnTick` on
/// every 1 Hz tick; `addHint` in place of `tracker.addHint` (stamp with `transcriberStartWall +
/// phrase.start`). Locked-in mode: `captureOnTick` each tick (gated by `noteProbeHit` /
/// `noteCorrection` from the scheduler), `confirm(now:mel:micRing:envelopeMissed:)` after each
/// check-in or probe, `rewatchTick` on ticks while acquiring / lost / reacquiring, and
/// `scheduler.memoryConfirmed(media:at:now:)` when `confirmed` is true. Save `memory` through
/// `MemoryStore` when `dirty` (≤ once per 60 s) and at session end; `noteManualChange` on every
/// trim / seed / jump / seek.
final class MemoryTracker {
    // Knobs the spec leaves open (not in WP0's `Tuning`; values reported in the WP4 report).
    /// A signature hit votes once per cue per lookback window unless its offset moved by > 1 bin.
    static let voteDedupeSeconds = 8.0
    /// Narrow envelope check of a memory-seeded candidate: window since the evidence began.
    static let quickConfirmMinSeconds = 6.0
    static let quickConfirmMaxSeconds = 12.0
    /// The analysis window is anchored at the start of the memory evidence for this long, so
    /// paused-room or pre-skip audio does not drown the new position (then back to the default).
    static let windowAnchorSeconds = 60.0
    /// Seconds after "Recognised from last time" the UI may show it.
    static let recognisedSeconds = 10.0
    /// Measured cap on the adaptive confirm threshold (WP4 harness S1): the learn-pass reservoir
    /// (quiet room) gives p10 ≈ 0.94 → thr 0.79, above the right-cue r at rewatch noise 0.15
    /// (p10 0.74), while the best wrong cue never exceeds 0.65. Overrides `Tuning.memoryConfirmCap`
    /// (0.85) until the real-room `-replayMic` numbers set it. TODO(WP7): fold into `Tuning`.
    static let measuredConfirmCap: Float = 0.70
    /// Measured coarse-stage width (WP4 review, harness S1, 20 random starts × 3 noise levels):
    /// with `Tuning.memoryCoarseTop` 20 the true cue was inside the coarse top-K in 85–92 % of
    /// windows (two runs: 88/85/92 %, 91/89/91 %), under the spec's ≥ 90 % gate; with 40 it was
    /// 98/94/91 %. The fine stage doubles (≈ 9 → 12 ms per 1500 cues on a Mac), still far under
    /// the 400 ms step budget. Overrides the WP0 default at init. TODO(WP7): fold into `Tuning`.
    static let measuredCoarseTop = 40
    /// A predicted cue (≥ 2 s of speech) scoring below thr − memoryCorrectionDelta is a *clear
    /// miss*: capture is blocked for `captureCorrectionWindowSeconds`, and two consecutive clear
    /// misses on distinct cues mark the lock *stale*: the cold search runs while still locked
    /// and may re-seed (old lock kept aside) instead of waiting for V1's 30 s of stale "tracking"
    /// on a 60 s window after a skip (harness S2). Pushing the tracker into drifting instead was
    /// tried and removed: the ±15 s drift search on a window mixing two positions adopts wrong ones.
    static let clearMissesToDrift = 2
    /// Unexplained speech: the last 8 s hold ≥ 2 s of VAD speech, the lock predicts stored lines
    /// in that span, and none of them matches (no confirm, no weak agreement) for this long →
    /// the lock is stale (after a pause / skip the predicted lines are tens of seconds away, so
    /// the "clear miss" rule above fires late). Consequence is bounded: the cold search runs
    /// while locked and may re-seed an *unconfirmed* candidate, old lock kept aside (S2).
    static let unexplainedSpeechSeconds = 4.0
    /// Signature rate vote: ≥ 2 distinct confirmed signature positions spanning ≥ this many
    /// wall seconds give a media/wall slope (20 ms precision); it is snapped to a `searchRates`
    /// preset within `rateVoteTolerance` and applied only while `!rateConfirmed` (a memory-seeded
    /// lock carries the nominal rate; V1's `refitRate` needs 120 s). Harness S9.
    static let rateVoteMinSpanSeconds = 12.0
    static let rateVoteMinPoints = 3
    static let rateVoteLongSpanSeconds = 20.0
    static let rateVoteTolerance = 0.012
    /// Every point must sit within this of the fitted line (20 ms frames: the right rate fits to
    /// < 0.1 s; a wrong alignment or a mixed epoch does not).
    static let rateVoteMaxResidual = 0.12
    /// The nearest preset must be at least this much closer than the runner-up (unambiguous).
    static let rateVoteAmbiguityRatio = 2.0
    static let rateVoteRevoteSpanSeconds = 30.0

    let tracker: SyncTracker
    let cues: [Cue]
    let expectations: [CueExpectation]
    let speechCueIDs: Set<Int>
    let clusters: TextClusters
    let candidateMatcher: CandidateMatcher
    let trackID: UUID
    let sessionStart: Date
    private(set) var index: SignatureIndex

    /// `memory.enabled` (capture + confirm + search); `memory.rewatchSearch` gates the cold search.
    var enabled = true
    var rewatchSearch = true
    /// Set for the session after 2 memory-hinted windows failed (different cut, recap-heavy).
    private(set) var memorySuspect = false
    /// ownScoreP10 < 0.60 after 20 self-checks: cold search off, predicted-cue confirm only.
    private(set) var memoryWeak = false
    private(set) var hintFailures = 0
    /// Signatures captured or replaced since the last `MemoryStore.save`.
    private(set) var dirty = false
    private(set) var capturedCount = 0
    private(set) var replacedCount = 0
    private(set) var skippedQuieter = 0
    private(set) var reseedCount = 0
    private(set) var restoreCount = 0
    private(set) var quickConfirmCount = 0
    private(set) var recognisedFromMemoryUntil: Date?
    /// Harness / debug: last memory step's numbers.
    private(set) var lastReport = MemoryReport()
    /// Harness / debug: called with one line per decision the notes do not show (quick-confirm
    /// failures, rate votes). nil in the app.
    var trace: ((String) -> Void)?
    /// Last rewatch step's cost, ms (os_signpost lives in the engine; this is the number).
    private(set) var lastSearchMs = 0.0

    private var tuning: SyncTracker.Tuning { tracker.tuning }
    private var lastManualChange: Date?
    private var lastProbeHit: Date?
    private var lastLargeCorrection: Date?
    private var consecutiveAgreeingHits = 0
    private var lastHitWall: Date?
    private var pendingReseed: (mediaAtWall: Double, wall: Date, cue: Int)?
    /// The confirmed lock set aside by a proposal-driven re-seed, restored if the candidate fails.
    private var preReseedLock: (lock: SyncTracker.Lock, state: SyncTracker.State, misses: Int)?
    private var memoryHintWall: Date?
    private var memoryEvidenceStart: Date?
    private var windowAnchor: Date?
    private var memorySeededCandidate = false
    private var seededAt: Date?
    private var rateCursor = 0
    private var roundRobin = false
    private var attemptedThisPass: Set<Int> = []
    private var ledgers: [Double: EvidenceLedger] = [:]
    /// Per search rate, Σ r and count of fine hits ≥ thr this epoch: the stretch that matches
    /// the film's real rate scores markedly higher (PAL: 0.85 vs 0.67 on the same lines), which
    /// picks the seed's rate (signature.md S9) where an 8 s offset cannot.
    private var rateEvidence: [Double: (sum: Float, n: Int)] = [:]
    /// A non-nominal rate needs this much more mean r than the nominal pass, on ≥ 2 hits.
    static let rateEvidenceMargin: Float = 0.10
    /// Looser margin for overriding V1's 12 s rate pick on a memory-hinted candidate (V1's pick
    /// is a coin toss there; a 0.06 stretch margin on ≥ 2 hits is not).
    static let rateAlignMargin: Float = 0.06
    /// A ledger peak is precise to about a second, so the hinted search it triggers looks
    /// ±10 s around it, not V1's ±60 s text-hint window: on 12 s of audio the wide window
    /// produced a confirmed +56 s candidate at noise 0.08 (harness S1, 1 run in 9).
    static let memoryHintRadiusSeconds = 10.0
    private var lastVote: [String: (wall: Date, bin: Int)] = [:]
    private var slowSteps = 0
    private var lastClearMiss: (wall: Date, cue: Int)?
    private var clearMissRun = 0
    private var staleSuspect = false
    private var unexplainedSince: Date?
    /// Set when the tracker (re)gains a lock; the next cold search starts from empty ledgers,
    /// because evidence gathered before that lock describes the old position.
    private var ledgersNeedReset = false
    private var lastObservedState: SyncTracker.State = .listening
    /// (wall, media, cue) of confirmed signature positions for the rate vote.
    private var ratePoints: [(wall: Date, media: Double, cue: Int)] = []
    private var rateVoteSpanApplied: Double?

    init(tracker: SyncTracker, cues: [Cue], language: String = "", memory: TrackMemory?, trackID: UUID, sessionStart: Date) {
        self.tracker = tracker
        self.cues = cues
        self.trackID = trackID
        self.sessionStart = sessionStart
        expectations = CueExpectations.build(cues, language: language)
        speechCueIDs = CueExpectations.speechCueIDs(expectations)
        clusters = TextClusters(cues: cues)
        candidateMatcher = CandidateMatcher(cues: cues)
        var m = memory ?? TrackMemory(trackID: trackID, cues: cues)
        m.lastUsed = sessionStart
        index = SignatureIndex(memory: m, cues: cues, clusters: clusters)
        tracker.tuning.memoryConfirmCap = min(tracker.tuning.memoryConfirmCap, Self.measuredConfirmCap)
        tracker.tuning.memoryCoarseTop = max(tracker.tuning.memoryCoarseTop, Self.measuredCoarseTop)
    }

    // MARK: Readouts

    var memory: TrackMemory { index.memory }
    var signatureCount: Int { index.count }
    /// Fraction of speech cues with a stored signature.
    var coverage: Double { index.coverage(speechCueIDs: speechCueIDs) }
    var thrConfirm: Float { index.thrConfirm(floor: tuning.memoryConfirmFloor, cap: tuning.memoryConfirmCap, delta: tuning.memoryConfirmDelta) }
    var ownScoreP10: Float? { index.memory.ownScoreP10 }
    /// The engine-note readout: "sig r 0.xx thr 0.yy".
    var noteReadout: String {
        if let r = lastReport.r { return String(format: "sig r %.2f thr %.2f", r, lastReport.thr) }
        return String(format: "sig thr %.2f · %d stored", thrConfirm, index.count)
    }
    var rewatchSearchAvailable: Bool {
        enabled && rewatchSearch && !memorySuspect && !memoryWeak
            && index.count >= tuning.memoryMinSignatures && coverage >= tuning.memoryMinCoverage
    }
    /// True while a memory-seeded candidate awaits the envelope.
    var hasMemoryCandidate: Bool { memorySeededCandidate && tracker.state == .candidate }

    func markSaved() { dirty = false }

    // MARK: Inputs from the engine / scheduler

    /// A user trim, seed, jump or seek: no capture for 10 s (`captureManualQuietSeconds`); any
    /// pending memory evidence is dropped (the user knows better).
    func noteManualChange(at wall: Date) {
        lastManualChange = wall
        attemptedThisPass = []
        pendingReseed = nil
        preReseedLock = nil
        memorySeededCandidate = false
        windowAnchor = nil
        memoryEvidenceStart = nil
        unexplainedSince = nil
        ratePoints = []
        rateVoteSpanApplied = nil
        rateEvidence = [:]
    }

    /// Locked-in mode: the probe (every 10 ticks) agreed with the prediction. TODO(WP7): call from
    /// the scheduler's probe result; with no probe the continuous-mode stability rule applies.
    func noteProbeHit(at wall: Date) {
        lastProbeHit = wall
    }

    /// Locked-in mode: a check-in correction of `seconds` was applied. TODO(WP7): call from the
    /// scheduler; > 0.5 s blocks capture for 10 s (critique C10) and clears the stability count.
    func noteCorrection(seconds: Double, at wall: Date) {
        if abs(seconds) > tuning.captureMaxCorrectionSeconds {
            lastLargeCorrection = wall
            consecutiveAgreeingHits = 0
            attemptedThisPass = []
        }
    }

    /// Recognised words, with the wall time they were *spoken* (`Phrase.start`). Replaces
    /// `SyncTracker.addHint`: the top-5 candidates vote into the ledger and the ledger's peak
    /// becomes the hint. An unambiguous phrase (V1's `locate` rule: confidence ≥ 1.5 over any
    /// cue > 60 s away) still hints directly, exactly as V1, so first-watch hints do not regress;
    /// a repeated line spreads its votes over its instances and abstains.
    @discardableResult
    func addHint(words: [String], heardAt wall: Date) -> Bool {
        let cands = candidateMatcher.candidates(words: words, limit: 5)
        guard let top = cands.first, top.score >= tuning.hintMinScore else { return false }
        let votes = cands.map { EvidenceLedger.Vote(cueIndex: $0.cueIndex, weight: Float($0.score / top.score), source: .phrase, strong: true) }
        let rate = tracker.rate
        ledger(for: rate).add(votes, heardAt: wall, sessionStart: sessionStart, rate: rate, cues: cues)
        var hinted = false
        if let hit = tracker.matcher.locate(words: words), hit.score >= tuning.hintMinScore, hit.confidence >= tuning.hintMinConfidence {
            // V1 direct path (unchanged numbers for the V1 hint scenarios). Not gated on
            // `memorySuspect`: the suspect flag silences *memory* and falls back to V1, and V1
            // includes phrase hints (signature.md §3.4.6; reviewer fix).
            tracker.hint = (hit.mediaTime, wall, hit.confidence)
            hinted = true
        }
        return publishPeak(at: wall, allowSeed: false).hinted || hinted
    }

    private func ledger(for rate: Double) -> EvidenceLedger {
        if let l = ledgers[rate] { return l }
        let l = EvidenceLedger()
        ledgers[rate] = l
        return l
    }

    /// Best peak across the per-rate ledgers. An 8 s window cannot tell 1.0 from a PAL rate
    /// (4 % is 0.3 s), so the nominal-rate ledger wins whenever it has a valid peak within
    /// `ratePreferenceSeconds` of the best one; V1's `refitRate` learns the true rate later.
    /// A speed-watching rate (≥ 1.2) is different enough to be trusted on its own.
    static let ratePreferenceSeconds = 2.0
    func ledgerPeak(at now: Date) -> (peak: EvidenceLedger.Peak, rate: Double, media: Double)? {
        var best: (EvidenceLedger.Peak, Double, Double)?
        for (rate, l) in ledgers {
            guard let p = l.peak(at: now) else { continue }
            if best == nil || p.weight > best!.0.weight {
                best = (p, rate, l.mediaTime(for: p, at: now, sessionStart: sessionStart, rate: rate))
            }
        }
        guard let b = best else { return nil }
        if let preferred = preferredRate(), preferred != 1, preferred < 1.2, let l = ledgers[preferred], let p = l.peak(at: now) {
            // The stretch whose signatures matched best this epoch (≥ 2 hits, +0.06 mean r).
            let media = l.mediaTime(for: p, at: now, sessionStart: sessionStart, rate: preferred)
            if abs(media - b.2) <= Self.ratePreferenceSeconds { return (p, preferred, media) }
        }
        if tracker.rate != 1, tracker.rate < 1.2, let l = ledgers[tracker.rate], let p = l.peak(at: now) {
            // The tracker already learned a PAL-class rate (V1 search or refit): keep it.
            let media = l.mediaTime(for: p, at: now, sessionStart: sessionStart, rate: tracker.rate)
            if abs(media - b.2) <= Self.ratePreferenceSeconds { return (p, tracker.rate, media) }
        }
        if b.1 != 1, b.1 < 1.2, let l = ledgers[1], let p = l.peak(at: now) {
            let media = l.mediaTime(for: p, at: now, sessionStart: sessionStart, rate: 1)
            if abs(media - b.2) <= Self.ratePreferenceSeconds { return (p, 1, media) }
        }
        if b.1 != 1, b.1 < 1.2 {
            // No nominal-rate peak: use the peak's position but the nominal rate.
            return (b.0, 1, b.2)
        }
        return b
    }

    /// The search rate whose fine hits scored best this epoch, when it beats the nominal pass
    /// by `rateEvidenceMargin` on ≥ 2 hits; nil = no opinion.
    func preferredRate(margin: Float = MemoryTracker.rateEvidenceMargin) -> Double? {
        let nominal = rateEvidence[1].map { $0.n > 0 ? $0.sum / Float($0.n) : 0 } ?? 0
        var best: (rate: Double, mean: Float)?
        for (rate, ev) in rateEvidence where ev.n >= 2 {
            let mean = ev.sum / Float(ev.n)
            if best == nil || mean > best!.mean { best = (rate, mean) }
        }
        guard let b = best else { return nil }
        if b.rate == 1 { return 1 }
        return b.mean >= nominal + margin ? b.rate : nil
    }

    // MARK: Analysis (drop-in for `tracker.analyse`)

    /// Runs the rewatch search (while searching / drifting), the narrow envelope check of a
    /// memory-seeded candidate, the V1 `analyse`, then the signature confirm step (while locked /
    /// drifting). `mel` and `micRing` are the live rings.
    func analyse(mic: [Float], windowStart: Date, now: Date, mel: MelRing, micRing: MicRing) -> (report: SyncTracker.Report, memory: MemoryReport) {
        var mr = MemoryReport(thr: thrConfirm)
        if let a = windowAnchor, now.timeIntervalSince(a) >= Self.windowAnchorSeconds { windowAnchor = nil }
        if enabled, tracker.state == .listening || tracker.state == .searching || tracker.state == .drifting || (staleSuspect && tracker.state == .locked) {
            let search = rewatchStep(now: now, mel: mel, micRing: micRing)
            mr.hinted = search.hinted
            mr.seeded = search.seeded
            mr.reseeded = search.seeded && preReseedLock != nil
            if !search.note.isEmpty { mr.note = search.note }
        }
        // The narrow envelope check may run in the very step that seeded (the 6–12 s of audio
        // since the evidence began are already in the ring); waiting a step only costs 2 s.
        if hasMemoryCandidate, seededAt != nil, quickConfirm(now: now, micRing: micRing, mel: mel) {
            mr.quickConfirmed = true
            mr.note += (mr.note.isEmpty ? "" : " · ") + "memory candidate confirmed by envelope (short window)"
        }
        let wasCandidateFromMemory = hasMemoryCandidate
        let before = tracker.lock
        if wasCandidateFromMemory, let anchor = windowAnchor, now.timeIntervalSince(anchor) < Self.quickConfirmMaxSeconds {
            // The envelope has not yet heard 12 s since the memory evidence began; judging the
            // candidate on a window that still holds the paused room / pre-skip audio would
            // discard it for the wrong reason. The narrow check above decides at 6–12 s; past
            // 12 s V1's analyse takes over on the anchored window.
            mr.thr = thrConfirm
            mr.suggestedWindowSeconds = suggestedWindowSeconds(at: now)
            lastReport = mr
            return (tracker.report(SpeechEnvelope.speechFraction(mic), "memory candidate · waiting for the envelope" + (mr.note.isEmpty ? "" : " · " + mr.note)), mr)
        }
        var report = tracker.analyse(mic: mic, windowStart: windowStart, now: now)
        if let n = alignHintedCandidateRate(report: report) { report = tracker.report(report.speechFraction, report.note + n) }
        if observe(report: report, previous: before, windowStart: windowStart, now: now, memoryCandidate: wasCandidateFromMemory) {
            mr.restored = true
            report = tracker.report(report.speechFraction, report.note + " · memory candidate rejected, lock restored")
        }
        if enabled, report.state == .locked || report.state == .drifting, index.count > 0, tracker.lock != nil {
            let envelopeMissed = report.note.hasPrefix("missed")
            let c = confirmStep(now: now, mel: mel, micRing: micRing, envelopeMissed: envelopeMissed)
            mr.confirmed = c.confirmed
            mr.shiftSeconds = c.shiftSeconds
            mr.adopted = c.adopted
            mr.seeded = mr.seeded || c.seeded
            mr.reseeded = mr.reseeded || c.seeded
            mr.proposedCue = c.proposedCue
            mr.r = c.r
            if !c.note.isEmpty { mr.note = c.note }
        }
        mr.thr = thrConfirm
        mr.recognisedFromMemory = recognisedFromMemoryUntil.map { now < $0 } ?? false
        mr.suggestedWindowSeconds = suggestedWindowSeconds(at: now)
        lastReport = mr
        let finalReport = (mr.adopted || mr.seeded || mr.quickConfirmed) ? tracker.report(report.speechFraction, report.note + " · " + mr.note) : report
        return (finalReport, mr)
    }

    /// A candidate from a memory-hinted V1 search takes memory's rate: V1 picks the rate by the
    /// best z over 12 s of audio, which cannot tell 1.0 from a PAL rate (S1 at noise 0.08: a
    /// candidate at the right place with rate 0.959 drifted 1.5 s in 35 s). The per-rate
    /// stretch evidence (`preferredRate`) decides, nominal when it has no opinion; the rate vote
    /// and V1's `refitRate` still correct it later. Unconfirmed candidates only.
    private func alignHintedCandidateRate(report: SyncTracker.Report) -> String? {
        guard memoryHintWall != nil, report.state == .candidate, let lock = report.lock, !lock.confirmed, !memorySeededCandidate else { return nil }
        let want = preferredRate(margin: Self.rateAlignMargin) ?? 1
        guard lock.rate != want else { return nil }
        tracker.rate = want
        tracker.lock = SyncTracker.Lock(wallAnchor: lock.wallAnchor, mediaAtAnchor: lock.mediaAtAnchor, rate: want, score: lock.score, confirmed: false)
        return String(format: " · memory rate %.4f (V1 picked %.4f)", want, lock.rate)
    }

    /// Analysis window the caller should use while memory evidence is fresh: just the audio since
    /// the evidence began (≥ the correlator minimum, ≤ 60 s), so a window full of paused room or
    /// pre-skip audio does not drown a memory-seeded position. nil = caller's default.
    func suggestedWindowSeconds(at now: Date) -> Double? {
        guard let anchor = windowAnchor, now.timeIntervalSince(anchor) < Self.windowAnchorSeconds else { return nil }
        return max(tuning.minWindowSeconds, min(60, now.timeIntervalSince(anchor)))
    }

    /// Lock-stability bookkeeping, the suspect flag, and restore-on-reject. Returns true when a
    /// rejected memory candidate had its previous lock restored.
    private func observe(report: SyncTracker.Report, previous: SyncTracker.Lock?, windowStart: Date, now: Date, memoryCandidate: Bool) -> Bool {
        var restored = false
        if report.state == .locked, lastObservedState != .locked { ledgersNeedReset = true; unexplainedSince = nil }
        if report.lock == nil, previous != nil {
            // The lock was lost: its signature positions are no longer evidence for anything.
            ratePoints = []
            rateVoteSpanApplied = nil
            unexplainedSince = nil
        }
        if report.state == .drifting || report.state == .searching || report.state == .listening, !memorySeededCandidate {
            // The anchored (short) window exists for judging a memory-seeded candidate on
            // post-event audio only; V1's ±15 s drift search on a 12 s window adopts wrong
            // positions (S9 trace), so outside that epoch the window is V1's.
            windowAnchor = nil
        }
        lastObservedState = report.state
        if report.note == "tracking", let lock = report.lock, lock.confirmed {
            if let prev = previous, prev.confirmed, abs(prev.mediaTime(at: windowStart) - lock.mediaTime(at: windowStart)) < tuning.settleDelta {
                consecutiveAgreeingHits += 1
            } else {
                consecutiveAgreeingHits = 1
            }
            lastHitWall = now
            if memorySeededCandidate || memoryHintWall != nil {
                hintFailures = 0
                if memorySeededCandidate {
                    recognisedFromMemoryUntil = now.addingTimeInterval(Self.recognisedSeconds)
                    // The seed's own signature positions already span the two cues: vote now.
                    rateVote(now: now)
                }
                memorySeededCandidate = false
                memoryHintWall = nil
                memoryEvidenceStart = nil
                preReseedLock = nil
            }
        } else {
            if report.note.hasPrefix("tracking") == false, report.state != .locked { consecutiveAgreeingHits = 0 }
            if report.note.hasPrefix("missed") { consecutiveAgreeingHits = 0 }
        }
        if let prev = previous, let lock = report.lock, prev != lock, abs(prev.mediaTime(at: now) - lock.mediaTime(at: now)) > 2 {
            attemptedThisPass = []
        }
        if report.lock == nil { attemptedThisPass = [] }
        // Suspect flag: a memory-hinted search or memory-seeded candidate that the envelope rejected.
        let hintedFailed = memoryHintWall != nil && report.note.hasPrefix("hinted search")
        let candidateRejected = memoryCandidate && report.lock == nil
        if candidateRejected, let pre = preReseedLock {
            // Anchor discipline: a re-seed that the envelope rejects costs nothing but the
            // candidate window; the confirmed lock it displaced comes back.
            tracker.lock = pre.lock
            tracker.state = pre.state == .locked ? .locked : .drifting
            tracker.misses = pre.misses
            preReseedLock = nil
            restoreCount += 1
            restored = true
        }
        if hintedFailed || candidateRejected {
            hintFailures += 1
            if candidateRejected { memorySeededCandidate = false; windowAnchor = nil; memoryEvidenceStart = nil; staleSuspect = false; clearMissRun = 0; unexplainedSince = nil; ratePoints = []; rateVoteSpanApplied = nil }
            if hintFailures >= tuning.memoryHintFailuresBeforeSuspect {
                memorySuspect = true
                tracker.hint = nil
                memoryHintWall = nil
                memoryEvidenceStart = nil
                windowAnchor = nil
            }
        }
        if let p10 = index.memory.ownScoreP10, p10 < 0.60 { memoryWeak = true }
        return restored
    }

    // MARK: Memory-assisted confirm of a seeded candidate

    /// V1's narrow tracking acceptance (±3 s, `trackScore` / `trackOnsetScore`, agreement < 1.5 s)
    /// on the 6–12 s of audio since the memory evidence began. The envelope confirms; memory only
    /// said where to look and let the window start at the evidence instead of 12 s later.
    static let quickConfirmMinOnsets = 2
    static let quickConfirmOnsetScore: Float = 0.5

    /// Every stored cue the lock predicts inside the last 8 s with ≥ 2 s of speech must score
    /// ≥ thr within ±1 s of its predicted place; at least one must be scorable.
    private func signaturesAgree(lock: SyncTracker.Lock, mel: MelRing, micRing: MicRing) -> Bool {
        guard let w = mel.latest(seconds: tuning.memoryLookbackSeconds), let micW = micRing.latest(seconds: tuning.memoryLookbackSeconds + 1) else { return false }
        let heardStartMedia = lock.mediaTime(at: w.start)
        let heardEndMedia = heardStartMedia + Double(w.count) * MelRing.frameSeconds * lock.rate
        let (f20, c20) = SignatureIndex.to20ms(frames10: w.frames, count: w.count)
        let (heard, heardCount) = SignatureIndex.stretch(frames: f20, count: c20, rate: lock.rate)
        let maxShift = Int(tuning.memoryAgreeSeconds / CueSignature.frameSeconds)
        let thr = thrConfirm
        var scorable = 0
        for id in index.cueIDs {
            let cue = cues[id]
            guard cue.start >= heardStartMedia - 0.5, cue.end <= heardEndMedia else { continue }
            let s0 = wall(forMedia: cue.start, lock: lock), s1 = wall(forMedia: cue.end, lock: lock)
            guard Self.speechSeconds(in: micW, from: s0, to: s1) * lock.rate >= tuning.memoryConfirmMinSpeechSeconds else { continue }
            guard let sc = index.confirm(heard: heard, heardCount: heardCount, heardStartMedia: heardStartMedia, cueID: id, maxShiftFrames: maxShift) else { continue }
            scorable += 1
            if sc.r < thr { return false }
        }
        return scorable > 0
    }

    private func quickConfirm(now: Date, micRing: MicRing, mel: MelRing) -> Bool {
        guard let lock = tracker.lock, let anchor = windowAnchor else { return false }
        let seconds = min(Self.quickConfirmMaxSeconds, now.timeIntervalSince(anchor))
        guard seconds >= Self.quickConfirmMinSeconds, let w = micRing.latest(seconds: seconds) else { return false }
        let fraction = SpeechEnvelope.speechFraction(w.bins)
        guard fraction >= tuning.minSpeechFraction, fraction <= tuning.maxSpeechFraction else { return false }
        let predicted = lock.mediaTime(at: w.start)
        let predictedBin = SpeechEnvelope.bin(for: predicted)
        let radius = SpeechEnvelope.bin(for: tuning.trackRadiusSeconds)
        // V1's narrow tracking acceptance at the candidate's own rate (a 6–12 s window cannot
        // rank 1.0 against a PAL rate; the stretch evidence, the signature rate vote and
        // `refitRate` set the rate later — see the S9 note in the WP4 report).
        // Stricter than V1's 60 s rule because the window is short: the envelope must agree
        // (score) *and* the onsets must land (≥ 2 heard onsets, onset score ≥ 0.5), and every
        // stored line the candidate predicts inside the window must match its signature at the
        // predicted place (r ≥ thr, |shift| ≤ 1 s). Rate: the candidate's (nominal) one.
        let stretched = SpeechEnvelope.stretched(w.bins, rate: lock.rate)
        guard let m = Correlator.search(mic: stretched, reference: tracker.reference, range: (predictedBin - radius)..<(predictedBin + radius)) else {
            trace?("quickConfirm: no correlation"); return false
        }
        guard m.score >= tuning.trackScore, m.onsetCount >= Self.quickConfirmMinOnsets, m.onsetScore >= Self.quickConfirmOnsetScore,
              abs(m.mediaTime - predicted) < 1.5 else {
            trace?(String(format: "quickConfirm: envelope %.1f s score %.2f onsets %d onsetScore %.2f Δ %+.2f → no", seconds, m.score, m.onsetCount, m.onsetScore, m.mediaTime - predicted))
            return false
        }
        guard signaturesAgree(lock: lock, mel: mel, micRing: micRing) else { trace?("quickConfirm: envelope ok, signatures disagree or none scorable"); return false }
        tracker.lastScore = m.score
        tracker.adopt(mediaAtStart: m.mediaTime, windowStart: w.start, score: m.score, confirmed: true)
        quickConfirmCount += 1
        unexplainedSince = nil
        staleSuspect = false
        clearMissRun = 0
        _ = rateVote(now: now)
        recognisedFromMemoryUntil = now.addingTimeInterval(Self.recognisedSeconds)
        memorySeededCandidate = false
        memoryHintWall = nil
        preReseedLock = nil
        hintFailures = 0
        consecutiveAgreeingHits = 1
        lastHitWall = now
        return true
    }

    // Note (WP4 report): a one-off rate re-vote on the first ≥ 30 s window after a memory-seeded
    // confirm was tried and removed — V1's ±3 s tracking correlation cannot rank 1.0 against a
    // PAL rate reliably on 30 s and the flips cost more than the drift. A memory-seeded lock keeps
    // the nominal rate until `refitRate` (≥ 6 points over ≥ 120 s) or WP2's RateEstimator sets it.

    // MARK: Capture (critique C10: on the 1 Hz tick while locked, gated on probe freshness)

    /// The capture gate: confirmed lock, no manual change for 10 s, and either three agreeing
    /// track hits in the last 10 s (continuous mode) or a fresh probe hit with no correction
    /// > 0.5 s in the last 10 s (locked-in mode).
    func captureGate(at now: Date) -> Bool {
        guard enabled, tracker.state == .locked, let lock = tracker.lock, lock.confirmed else { return false }
        if let m = lastManualChange, now.timeIntervalSince(m) < tuning.captureManualQuietSeconds { return false }
        if index.count > 0, let cm = lastClearMiss, now.timeIntervalSince(cm.wall) < tuning.captureCorrectionWindowSeconds { return false }
        let stable = consecutiveAgreeingHits >= tuning.captureStability && (lastHitWall.map { now.timeIntervalSince($0) <= tuning.captureMaxProbeAgeSeconds } ?? false)
        let probeFresh = (lastProbeHit.map { now.timeIntervalSince($0) <= tuning.captureMaxProbeAgeSeconds } ?? false)
            && (lastLargeCorrection.map { now.timeIntervalSince($0) > tuning.captureCorrectionWindowSeconds } ?? true)
        return stable || probeFresh
    }

    /// Call once per 1 Hz tick. Slices the mel ring at the predicted span of every cue that has
    /// finished ≥ 1 s ago and has not been tried in this pass; returns what was stored.
    @discardableResult
    func captureOnTick(now: Date, mel: MelRing, micRing: MicRing) -> [CueSignature] {
        guard captureGate(at: now), let lock = tracker.lock, let melEnd = mel.endWall else { return [] }
        let lead = tuning.captureLeadSeconds
        let lookback = min(20.0, mel.secondsRecorded, micRing.secondsRecorded)
        guard lookback >= 4 else { return [] }
        let endMedia = lock.mediaTime(at: melEnd.addingTimeInterval(-1.0))
        let startMedia = lock.mediaTime(at: melEnd.addingTimeInterval(-lookback))
        guard let micWindow = micRing.latest(seconds: lookback) else { return [] }
        var out: [CueSignature] = []
        var i = firstCue(startingAtOrAfter: startMedia)
        while i < cues.count, cues[i].start - lead < endMedia {
            defer { i += 1 }
            let cue = cues[i]
            guard !attemptedThisPass.contains(i) else { continue }
            let speechEnd = tuning.useTextExpectations ? min(cue.end, expectations[i].speechEnd) : cue.end
            let spanStart = cue.start - lead, spanEnd = speechEnd + lead
            guard spanEnd <= endMedia else { continue }      // not finished ≥ 1 s ago yet
            guard spanStart >= startMedia else { attemptedThisPass.insert(i); continue } // already scrolled out
            attemptedThisPass.insert(i)
            guard expectations[i].kind != .nonSpeech, speechEnd - cue.start >= tuning.captureMinSeconds else { continue }
            if let sig = capture(cue: i, spanStart: spanStart, spanEnd: spanEnd, lock: lock, mel: mel, micWindow: micWindow, now: now) {
                out.append(sig)
            }
        }
        return out
    }

    private func firstCue(startingAtOrAfter media: Double) -> Int {
        var lo = 0, hi = cues.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if cues[mid].start - tuning.captureLeadSeconds < media { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private func wall(forMedia media: Double, lock: SyncTracker.Lock) -> Date {
        lock.wallAnchor.addingTimeInterval((media - lock.mediaAtAnchor) / lock.rate)
    }

    private func capture(cue i: Int, spanStart: Double, spanEnd: Double, lock: SyncTracker.Lock, mel: MelRing,
                         micWindow: (bins: [Float], start: Date), now: Date) -> CueSignature? {
        let cue = cues[i]
        let wallStart = wall(forMedia: spanStart, lock: lock)
        let wallSeconds = (spanEnd - spanStart) / lock.rate
        guard let w = mel.window(from: wallStart, seconds: wallSeconds) else { return nil }
        // VAD inside the cue (wall span of [cue.start, speechEnd]).
        let cueWallStart = wall(forMedia: cue.start, lock: lock)
        let cueWallEnd = wall(forMedia: spanEnd - tuning.captureLeadSeconds, lock: lock)
        let b0 = Int((cueWallStart.timeIntervalSince(micWindow.start) / SpeechEnvelope.binDuration).rounded())
        let b1 = Int((cueWallEnd.timeIntervalSince(micWindow.start) / SpeechEnvelope.binDuration).rounded())
        guard b0 >= 0, b1 <= micWindow.bins.count, b1 > b0 else { return nil }
        var speechBins = 0
        for k in b0..<b1 where micWindow.bins[k] == 1 { speechBins += 1 }
        let fraction = Double(speechBins) / Double(b1 - b0)
        let speechSeconds = Double(speechBins) * SpeechEnvelope.binDuration * lock.rate   // media seconds
        guard fraction >= tuning.captureMinSpeechFraction, speechSeconds >= tuning.captureMinSeconds else { return nil }
        // Level above the local floor: mean frame log-energy over the speech frames minus the
        // window's 10th percentile, in dB.
        let mb0 = Int((wallStart.timeIntervalSince(micWindow.start) / SpeechEnvelope.binDuration).rounded())
        let micSlice = Array(micWindow.bins[max(0, mb0)..<min(micWindow.bins.count, max(0, mb0) + w.count)])
        let levelDb = Self.speechLevelDb(levels: w.levels, count: w.count, micBins: micSlice)
        // Heard frames are wall-time; signatures are stored at media rate 1.0.
        let (f20, c20) = SignatureIndex.to20ms(frames10: w.frames, count: w.count)
        let (fm, cm) = SignatureIndex.stretch(frames: f20, count: c20, rate: lock.rate)
        guard cm >= 2 * CueSignature.defaultLeadFrames + 10 else { return nil }
        var sig = CueSignature(cueID: i, frameCount: cm, leadInFrames: CueSignature.defaultLeadFrames, frames: CueSignature.quantise(fm),
                               speechLevelDb: levelDb, captureCount: 1, rateAtCapture: Float(lock.rate), capturedAt: now,
                               speechSeconds: Float(speechSeconds))
        if var old = index.memory.cues[i] {
            if levelDb >= old.speechLevelDb + tuning.captureReplaceDeltaDb {
                sig.captureCount = old.captureCount &+ 1
                replacedCount += 1
            } else {
                old.captureCount = old.captureCount &+ 1
                index.insert(old, cueStart: cue.start, clustered: clusters.isClustered(i))
                skippedQuieter += 1
                dirty = true
                return nil
            }
        } else {
            capturedCount += 1
        }
        index.insert(sig, cueStart: cue.start, clustered: clusters.isClustered(i))
        dirty = true
        return sig
    }

    /// Mean log-energy of the frames the VAD marked as speech minus the window's 10th-percentile
    /// log-energy, as dB (10·log10). Frames and mic bins are index-aligned.
    static func speechLevelDb(levels: [Float], count: Int, micBins: [Float]) -> Float {
        guard count > 0, !levels.isEmpty else { return 0 }
        let sorted = levels.prefix(count).sorted()
        let floor = sorted[max(0, Int(Double(sorted.count) * 0.1) - 1)]
        var sum: Float = 0, n = 0
        for k in 0..<min(count, micBins.count) where micBins[k] == 1 { sum += levels[k]; n += 1 }
        guard n > 0 else { return 0 }
        return 10 * (sum / Float(n) - floor)
    }

    // MARK: Confirm step (signature.md §3.3)

    private struct ConfirmResult {
        var confirmed = false, adopted = false, seeded = false
        var shiftSeconds: Double?
        var proposedCue: Int?
        var r: Float?
        var note = ""
    }

    /// Scores the stored cues the lock predicts in the last 8 s of the mel ring. Public so the
    /// locked-in check-in (WP7) can call it on its own window after the envelope step.
    func confirm(now: Date, mel: MelRing, micRing: MicRing, envelopeMissed: Bool) -> MemoryReport {
        var mr = MemoryReport(thr: thrConfirm)
        guard enabled, index.count > 0, tracker.lock != nil, tracker.state == .locked || tracker.state == .drifting else { lastReport = mr; return mr }
        let c = confirmStep(now: now, mel: mel, micRing: micRing, envelopeMissed: envelopeMissed)
        mr.confirmed = c.confirmed; mr.adopted = c.adopted; mr.seeded = c.seeded; mr.reseeded = c.seeded; mr.shiftSeconds = c.shiftSeconds
        mr.proposedCue = c.proposedCue; mr.r = c.r; mr.note = c.note; mr.thr = thrConfirm
        lastReport = mr
        return mr
    }

    private func confirmStep(now: Date, mel: MelRing, micRing: MicRing, envelopeMissed: Bool) -> ConfirmResult {
        var result = ConfirmResult()
        guard let lock = tracker.lock, let w = mel.latest(seconds: tuning.memoryLookbackSeconds),
              let micW = micRing.latest(seconds: tuning.memoryLookbackSeconds + 1) else { return result }
        let drifting = tracker.state == .drifting
        let radius = drifting ? tuning.memoryDriftRadiusSeconds : tuning.memoryLockedRadiusSeconds
        let maxShift = Int(radius / CueSignature.frameSeconds)
        let heardStartMedia = lock.mediaTime(at: w.start)
        let heardEndMedia = heardStartMedia + Double(w.count) * MelRing.frameSeconds * lock.rate
        let (f20, c20) = SignatureIndex.to20ms(frames10: w.frames, count: w.count)
        let (heard, heardCount) = SignatureIndex.stretch(frames: f20, count: c20, rate: lock.rate)
        let thr = thrConfirm

        // Predicted cues: every stored signature whose predicted span touches the heard block.
        // Only those with ≥ 2 s of VAD speech can *confirm*; the rest are still "predicted" (so
        // they are never mistaken for a correction) and may agree weakly.
        var predictedIDs: Set<Int> = []
        var predictedBest: SignatureIndex.Score?       // confirm-eligible (≥ 2 s speech)
        var weakAgree: SignatureIndex.Score?           // short cue at the predicted place
        for id in index.cueIDs {
            let cue = cues[id]
            guard cue.end >= heardStartMedia, cue.start <= heardEndMedia else { continue }
            predictedIDs.insert(id)
            guard cue.start >= heardStartMedia - 0.5, cue.end <= heardEndMedia,
                  let sc = index.confirm(heard: heard, heardCount: heardCount, heardStartMedia: heardStartMedia, cueID: id, maxShiftFrames: maxShift) else { continue }
            let s0 = wall(forMedia: cue.start, lock: lock), s1 = wall(forMedia: cue.end, lock: lock)
            if Self.speechSeconds(in: micW, from: s0, to: s1) * lock.rate >= tuning.memoryConfirmMinSpeechSeconds {
                if predictedBest == nil || sc.r > predictedBest!.r { predictedBest = sc }
            } else if sc.r >= thr, abs(sc.shiftSeconds) <= tuning.memoryAgreeSeconds {
                if weakAgree == nil || sc.r > weakAgree!.r { weakAgree = sc }
            }
        }
        if let best = predictedBest {
            result.r = best.r
            if best.r >= thr, abs(best.shiftSeconds) <= tuning.memoryAgreeSeconds {
                result.confirmed = true
                result.shiftSeconds = best.shiftSeconds
                index.recordOwnScore(best.r)
                dirty = true
                tracker.misses = 0
                pendingReseed = nil
                clearMissRun = 0
                staleSuspect = false
                unexplainedSince = nil
                result.note = String(format: "sig confirm cue %d r %.2f thr %.2f shift %+.2f", best.cueID, best.r, thr, best.shiftSeconds)
                if envelopeMissed, !drifting {
                    // The envelope missed (music / laughter under the line): adopt the signature's
                    // position as a tracking hit, bounded to ±1 s around the prediction.
                    let mediaAtStart = heardStartMedia - best.shiftSeconds
                    tracker.adopt(mediaAtStart: mediaAtStart, windowStart: w.start, score: best.r, confirmed: true)
                    result.adopted = true
                    result.note += " adopted"
                }
                addRatePoint(cue: best.cueID, position: best.position, windowStart: w.start, rate: lock.rate)
                if let rn = rateVote(now: now) { result.note += rn }
                return result
            }
        }
        if let wa = weakAgree {
            // A short line at the predicted place agrees: nothing to correct, nothing to confirm.
            // It does not clear the unexplained-speech clock either: short signatures reach
            // r ≈ 0.8 against other speech (S2 trace), so only a confirm-eligible line explains.
            result.r = wa.r
            pendingReseed = nil
            result.note = String(format: "sig short cue %d agrees r %.2f (no action)", wa.cueID, wa.r)
            if !drifting, let u = noteUnexplained(w: w, micW: micW, predictedIDs: predictedIDs, now: now) { result.note += " · " + u }
            return result
        }
        // Proposal: the predicted cue is scorable and clearly wrong (while locked; while drifting
        // the prediction may simply be out of range) and another cue in range is clearly right.
        let predictedMax = predictedBest?.r ?? -1
        guard predictedMax < thr - tuning.memoryCorrectionDelta else {
            // Near-agreement (thr − 0.2 ≤ r < thr): not a miss, not unexplained (PAL mismatch
            // before the rate vote, a noisy line) — the next step decides. Its position still
            // feeds the rate vote (the fit's residual check rejects a misaligned one), so a
            // wrong-rate lock, under which r sits just below thr, gets its rate corrected.
            unexplainedSince = nil
            if let best = predictedBest {
                result.note = String(format: "sig cue %d r %.2f < thr %.2f", best.cueID, best.r, thr)
                if abs(best.shiftSeconds) <= tuning.memoryAgreeSeconds {
                    addRatePoint(cue: best.cueID, position: best.position, windowStart: w.start, rate: lock.rate)
                    if let rn = rateVote(now: now) { result.note += rn }
                }
            }
            return result
        }
        if let best = predictedBest {
            // A clear miss of a predicted line: no capture for a while; two in a row on distinct
            // cues mean the lock is stale → drifting now (the envelope and the search decide).
            if let last = lastClearMiss, last.cue != best.cueID { clearMissRun += 1 } else if lastClearMiss == nil { clearMissRun = 1 }
            lastClearMiss = (now, best.cueID)
            result.note = String(format: "sig clear miss cue %d r %.2f (%d)", best.cueID, best.r, clearMissRun)
            if clearMissRun >= Self.clearMissesToDrift, !staleSuspect {
                // The lock looks stale: let the cold search run while locked; a peak backed by
                // two distinct strong cues away from the prediction re-seeds (old lock kept aside).
                staleSuspect = true
                ledgersNeedReset = true
                result.note += " → stale, searching"
            }
        } else if !drifting {
            if let u = noteUnexplained(w: w, micW: micW, predictedIDs: predictedIDs, now: now) { result.note = u }
        }
        guard drifting || predictedBest != nil else { return result }
        var others: [SignatureIndex.Score] = []
        for id in index.cueIDs where !predictedIDs.contains(id) {
            let cue = cues[id]
            guard cue.end + radius >= heardStartMedia, cue.start - radius <= heardEndMedia else { continue }
            guard let sc = index.confirm(heard: heard, heardCount: heardCount, heardStartMedia: heardStartMedia, cueID: id, maxShiftFrames: maxShift) else { continue }
            others.append(sc)
        }
        others.sort { $0.r > $1.r }
        guard let top = others.first, top.r >= thr else { return result }
        let runnerUp = others.dropFirst().first?.r ?? -1
        if clusters.isClustered(top.cueID),
           let twin = others.dropFirst().first(where: { clusters.clusterOf[$0.cueID] == clusters.clusterOf[top.cueID] }), abs(twin.r - top.r) < 0.08 {
            // Cluster, position unknown: 0.3 × r to each member's offset.
            let votes = [top, twin].map { EvidenceLedger.Vote(cueIndex: $0.cueID, weight: 0.3 * $0.r, source: .cluster) }
            ledger(for: lock.rate).add(votes, heardAt: now, sessionStart: sessionStart, rate: lock.rate, cues: cues)
            result.note = String(format: "sig cluster, position unknown (cues %d/%d r %.2f/%.2f)", top.cueID, twin.cueID, top.r, twin.r)
            return result
        }
        guard top.r - runnerUp >= tuning.memoryMargin else { return result }
        if let entry = index.entries[top.cueID], entry.weak {
            // Clustered or short: votes, never a proposal on its own.
            ledger(for: lock.rate).add([EvidenceLedger.Vote(cueIndex: top.cueID, weight: 0.5 * top.r, source: .signature)],
                                       heardAt: now, sessionStart: sessionStart, rate: lock.rate, cues: cues)
            result.note = String(format: "sig weak cue %d r %.2f → ledger", top.cueID, top.r)
            return result
        }
        let proposedMediaAtStart = index.entries[top.cueID]!.startMedia - Double(top.position) * CueSignature.frameSeconds
        let proposedNow = proposedMediaAtStart + now.timeIntervalSince(w.start) * lock.rate
        let delta = proposedNow - lock.mediaTime(at: now)
        guard abs(delta) > tuning.memoryAgreeSeconds else {
            // The "other" cue says we are where we already are: agreement, not a correction.
            result.r = top.r
            result.note = String(format: "sig cue %d agrees r %.2f (%+.2f s, no action)", top.cueID, top.r, delta)
            return result
        }
        result.proposedCue = top.cueID
        result.r = top.r
        // Anchor discipline: a single proposal never moves a confirmed lock. Two consecutive
        // proposals from *different* cues that agree within 1.5 s re-seed an unconfirmed
        // candidate; the old lock is kept aside and restored if the envelope rejects it.
        if let p = pendingReseed, p.cue != top.cueID,
           abs((p.mediaAtWall + now.timeIntervalSince(p.wall) * lock.rate) - proposedNow) <= tuning.memoryReseedAgreeSeconds {
            preReseedLock = (lock, tracker.state, tracker.misses)
            tracker.lock = SyncTracker.Lock(wallAnchor: w.start, mediaAtAnchor: proposedMediaAtStart, rate: lock.rate, score: top.r, confirmed: false)
            tracker.state = .candidate
            tracker.misses = 0
            tracker.lockPoints = []
            pendingReseed = nil
            memorySeededCandidate = true
            seededAt = now
            memoryHintWall = now
            memoryEvidenceStart = p.wall.addingTimeInterval(-tuning.memoryLookbackSeconds)
            windowAnchor = memoryEvidenceStart
            reseedCount += 1
            result.seeded = true
            result.note = String(format: "sig reseed → candidate cue %d r %.2f (%+.1f s)", top.cueID, top.r, delta)
        } else {
            pendingReseed = (proposedNow, now, top.cueID)
            result.note = String(format: "sig proposal cue %d r %.2f (%+.1f s, pending)", top.cueID, top.r, delta)
        }
        return result
    }

    /// Unexplained speech: ≥ 2 s of speech in the block, stored lines predicted in it, and none
    /// of them confirmed where the lock says (after a pause / skip the predicted lines are tens
    /// of seconds away, so their spans are silent and no clear miss fires). Returns a note.
    private func noteUnexplained(w: (frames: [Float], levels: [Float], count: Int, start: Date), micW: (bins: [Float], start: Date),
                                 predictedIDs: Set<Int>, now: Date) -> String? {
        let blockEnd = w.start.addingTimeInterval(Double(w.count) * MelRing.frameSeconds)
        let speechInBlock = Self.speechSeconds(in: micW, from: w.start, to: blockEnd)
        guard !predictedIDs.isEmpty, speechInBlock >= tuning.memoryConfirmMinSpeechSeconds else {
            unexplainedSince = nil
            return nil
        }
        if unexplainedSince == nil { unexplainedSince = now }
        if !staleSuspect, let u = unexplainedSince, now.timeIntervalSince(u) >= Self.unexplainedSpeechSeconds {
            staleSuspect = true
            ledgersNeedReset = true
            return String(format: "sig unexplained speech %.1f s → stale, searching", speechInBlock)
        }
        return staleSuspect ? "sig stale, searching" : String(format: "sig unexplained speech %.1f s", speechInBlock)
    }

    // MARK: Signature rate vote

    private func addRatePoint(cue: Int, position: Int, windowStart: Date, rate: Double) {
        guard let e = index.entries[cue] else { return }
        let wall = windowStart.addingTimeInterval(Double(position) * CueSignature.frameSeconds / rate)
        ratePoints.removeAll { $0.cue == cue }
        ratePoints.append((wall, e.startMedia, cue))
        if ratePoints.count > 16 { ratePoints.removeFirst(ratePoints.count - 16) }
    }

    /// Media/wall slope over the confirmed signature positions, snapped to a `searchRates`
    /// preset and applied to the lock while `rateConfirmed` is false. The lock is re-anchored at
    /// the latest signature position (within ±1 s of the prediction by construction), so this
    /// is the spec's "adopt the signature-implied position", plus a preset rate. Returns a note
    /// when the rate changed. TODO(WP7): in locked-in mode WP2's `RateEstimator` gets the same
    /// points through `scheduler.memoryConfirmed(media:at:now:)`; this path is for continuous mode.
    @discardableResult
    private func rateVote(now: Date) -> String? {
        guard !tracker.rateConfirmed, let lock = tracker.lock, lock.confirmed, tracker.state == .locked, ratePoints.count >= 2 else { return nil }
        let sorted = ratePoints.sorted { $0.wall < $1.wall }
        guard let first = sorted.first, let last = sorted.last else { return nil }
        let span = last.wall.timeIntervalSince(first.wall)
        guard span >= Self.rateVoteMinSpanSeconds, sorted.count >= Self.rateVoteMinPoints || span >= Self.rateVoteLongSpanSeconds else {
            trace?(String(format: "rate vote: %d points over %.1f s, waiting", sorted.count, span)); return nil
        }
        if let applied = rateVoteSpanApplied, span < max(2 * applied, Self.rateVoteRevoteSpanSeconds) { return nil }
        let xs = sorted.map { $0.wall.timeIntervalSince(first.wall) }
        let ys = sorted.map(\.media)
        let n = Double(xs.count)
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        var cov = 0.0, varX = 0.0
        for i in 0..<xs.count { cov += (xs[i] - mx) * (ys[i] - my); varX += (xs[i] - mx) * (xs[i] - mx) }
        guard varX > 0 else { return nil }
        let slope = cov / varX
        let intercept = my - slope * mx
        let maxResidual = zip(xs, ys).map { abs($1 - (intercept + slope * $0)) }.max() ?? 0
        guard maxResidual <= Self.rateVoteMaxResidual else {
            trace?(String(format: "rate vote: slope %.4f over %.0f s (%d points) inconsistent (max residual %.2f s)", slope, span, sorted.count, maxResidual)); return nil
        }
        let presets = tuning.searchRates.sorted { abs($0 - slope) < abs($1 - slope) }
        let detail = sorted.map { String(format: "(%.1f, %.2f, c%d)", $0.wall.timeIntervalSince(sessionStart), $0.media, $0.cue) }.joined(separator: " ")
        guard let preset = presets.first, abs(preset - slope) <= Self.rateVoteTolerance else {
            trace?(String(format: "rate vote: slope %.4f over %.0f s (%d points) matches no preset %@", slope, span, sorted.count, detail)); return nil
        }
        if presets.count > 1, abs(presets[1] - slope) < Self.rateVoteAmbiguityRatio * abs(preset - slope) {
            trace?(String(format: "rate vote: slope %.4f over %.0f s (%d points) ambiguous %@", slope, span, sorted.count, detail)); return nil
        }
        rateVoteSpanApplied = span
        trace?(String(format: "rate vote: slope %.4f over %.0f s (%d points) → preset %.4f (lock rate %.4f) %@", slope, span, sorted.count, preset, tracker.rate, detail))
        guard preset != tracker.rate else { return nil }
        tracker.rate = preset
        tracker.lock = SyncTracker.Lock(wallAnchor: last.wall, mediaAtAnchor: last.media, rate: preset, score: lock.score, confirmed: true)
        tracker.lockPoints = []
        return String(format: " · sig rate %.4f over %.0f s → %.4f", slope, span, preset)
    }

    /// Harness-only (R7 test): records a pending proposal as if another cue's signature had
    /// proposed it. A single proposal never moves a confirmed lock; the next predicted-cue
    /// confirm clears it, and only a second agreeing proposal from a different cue would seed an
    /// unconfirmed candidate.
    func injectPendingProposal(cue: Int, mediaAtWall: Double, at wall: Date) {
        pendingReseed = (mediaAtWall, wall, cue)
    }

    private static func speechSeconds(in w: (bins: [Float], start: Date), from: Date, to: Date) -> Double {
        let b0 = max(0, Int((from.timeIntervalSince(w.start) / SpeechEnvelope.binDuration).rounded()))
        let b1 = min(w.bins.count, Int((to.timeIntervalSince(w.start) / SpeechEnvelope.binDuration).rounded()))
        guard b1 > b0 else { return 0 }
        var n = 0
        for k in b0..<b1 where w.bins[k] == 1 { n += 1 }
        return Double(n) * SpeechEnvelope.binDuration
    }

    // MARK: Rewatch cold start (signature.md §3.4)

    private struct SearchResult { var hinted = false, seeded = false; var note = "" }

    /// One coarse→fine step on the last 4–8 s of mel, votes into the ledger, publishes the peak
    /// as a hint / candidate. Public for WP7's tick. Every search rate is tried per step while
    /// the step stays under `memorySearchStepBudgetMs`; over it the rates go round-robin, and
    /// two steps over `memorySearchDisableMs` switch the search off for the session.
    @discardableResult
    func rewatchTick(now: Date, mel: MelRing, micRing: MicRing) -> MemoryReport {
        var mr = MemoryReport(thr: thrConfirm)
        guard enabled, tracker.state == .listening || tracker.state == .searching || tracker.state == .drifting || (staleSuspect && tracker.state == .locked) else { return mr }
        let s = rewatchStep(now: now, mel: mel, micRing: micRing)
        mr.hinted = s.hinted; mr.seeded = s.seeded; mr.note = s.note
        mr.reseeded = s.seeded && preReseedLock != nil
        mr.suggestedWindowSeconds = suggestedWindowSeconds(at: now)
        lastReport = mr
        return mr
    }

    private func rewatchStep(now: Date, mel: MelRing, micRing: MicRing) -> SearchResult {
        var result = SearchResult()
        guard rewatchSearchAvailable else { return result }
        if ledgersNeedReset {
            // Evidence gathered while (and before) the last lock describes the old position.
            for l in ledgers.values { l.reset() }
            lastVote = [:]
            ledgersNeedReset = false
            clearMissRun = 0
            ratePoints = []
            rateVoteSpanApplied = nil
            rateEvidence = [:]
            // A new search epoch: the analysis window anchors at *this* epoch's first evidence.
            if !memorySeededCandidate { windowAnchor = nil; memoryEvidenceStart = nil }
        }
        guard let w = mel.latest(seconds: tuning.memoryLookbackSeconds), Double(w.count) * MelRing.frameSeconds >= 4,
              let micW = micRing.latest(seconds: tuning.memoryLookbackSeconds) else { return result }
        guard Self.speechSeconds(in: micW, from: w.start, to: w.start.addingTimeInterval(Double(w.count) * MelRing.frameSeconds)) >= 0.5 else { return result }
        let allRates = tuning.searchRates
        let rates: [Double]
        if roundRobin {
            rates = [allRates[rateCursor % max(1, allRates.count)]]
            rateCursor += 1
        } else {
            rates = allRates
        }
        let pointRate = rates.contains(tracker.rate) ? tracker.rate : 1
        let started = Date()
        let (f20, c20) = SignatureIndex.to20ms(frames10: w.frames, count: w.count)
        let thr = thrConfirm
        var hits = 0
        var clusterNote = ""
        var earliestEvidence: Date?
        for rate in rates {
            let (heard, heardCount) = SignatureIndex.stretch(frames: f20, count: c20, rate: rate)
            let coarse = index.coarseSearch(heard: heard, heardCount: heardCount, top: tuning.memoryCoarseTop)
            let fine = index.fineScore(heard: heard, heardCount: heardCount, candidates: coarse)
            // Two cluster members within 0.08 on the same heard span: "cluster, position unknown" —
            // 0.3 × r to each member's offset, source .cluster, and neither acts alone (§3.6).
            var clusterHandled: Set<Int> = []
            if fine.count >= 2 {
                for a in fine where a.r >= thr && clusters.isClustered(a.cueID) && !clusterHandled.contains(a.cueID) {
                    let twins = fine.filter { $0.cueID != a.cueID && clusters.clusterOf[$0.cueID] == clusters.clusterOf[a.cueID] && abs($0.r - a.r) < 0.08 }
                    guard !twins.isEmpty else { continue }
                    for m in [a] + twins {
                        clusterHandled.insert(m.cueID)
                        let heardAt = w.start.addingTimeInterval((Double(m.position + CueSignature.defaultLeadFrames) * CueSignature.frameSeconds) / rate)
                        vote(cue: m.cueID, weight: 0.3 * m.r, source: .cluster, heardAt: heardAt, rate: rate)
                    }
                    if clusterNote.isEmpty { clusterNote = String(format: " · cluster, position unknown (cues %@)", ([a] + twins).map { "\($0.cueID)" }.joined(separator: "/")) }
                }
            }
            for sc in fine where sc.r >= thr {
                let ev = rateEvidence[rate] ?? (0, 0)
                rateEvidence[rate] = (ev.sum + sc.r, ev.n + 1)
            }
            for sc in fine where sc.r >= thr && !clusterHandled.contains(sc.cueID) {
                guard let e = index.entries[sc.cueID] else { continue }
                let heardAt = w.start.addingTimeInterval((Double(sc.position + CueSignature.defaultLeadFrames) * CueSignature.frameSeconds) / rate)
                if vote(cue: sc.cueID, weight: e.weak ? 0.5 * sc.r : sc.r, source: .signature, heardAt: heardAt, rate: rate, strong: !e.weak) {
                    hits += 1
                    if rate == pointRate { addRatePoint(cue: sc.cueID, position: sc.position, windowStart: w.start, rate: rate) }
                    let evidenceAt = heardAt.addingTimeInterval(-Double(CueSignature.defaultLeadFrames) * CueSignature.frameSeconds)
                    if earliestEvidence == nil || evidenceAt < earliestEvidence! { earliestEvidence = evidenceAt }
                }
            }
        }
        lastSearchMs = Date().timeIntervalSince(started) * 1000
        if lastSearchMs > tuning.memorySearchDisableMs {
            slowSteps += 1
            if slowSteps >= 2 { rewatchSearch = false; result.note = "memory search too slow"; return result }
        } else if lastSearchMs > tuning.memorySearchStepBudgetMs {
            roundRobin = true
        }
        if let e = earliestEvidence, memoryEvidenceStart == nil || e < memoryEvidenceStart! {
            memoryEvidenceStart = e
        }
        let pub = publishPeak(at: now, allowSeed: true)
        result.hinted = pub.hinted
        result.seeded = pub.seeded
        if hits > 0 || pub.hinted || !clusterNote.isEmpty {
            result.note = String(format: "sig search %d hits ≥ %.2f (%d rate%@, %.0f ms)%@%@", hits, thr, rates.count, rates.count == 1 ? "" : "s", lastSearchMs, clusterNote, pub.note)
        }
        return result
    }

    /// One vote into the per-rate ledger, deduplicated: the same cue votes once per lookback
    /// window per rate unless its implied offset moved by more than one bin (a sliding 8 s
    /// window sees the same line for 8 s; that is one observation, not four).
    @discardableResult
    private func vote(cue: Int, weight: Float, source: EvidenceLedger.Source, heardAt: Date, rate: Double, strong: Bool = false) -> Bool {
        let l = ledger(for: rate)
        let bin = l.bin(forCue: cue, heardAt: heardAt, sessionStart: sessionStart, rate: rate, cues: cues)
        let key = "\(cue)@\(rate)"
        if let last = lastVote[key], heardAt.timeIntervalSince(last.wall) < Self.voteDedupeSeconds, abs(last.bin - bin) <= 1 { return false }
        lastVote[key] = (heardAt, bin)
        l.add([EvidenceLedger.Vote(cueIndex: cue, weight: weight, source: source, strong: strong)], heardAt: heardAt, sessionStart: sessionStart, rate: rate, cues: cues)
        return true
    }

    /// The ledger peak → `tracker.hint`; with ≥ 2 distinct cues (and `allowSeed`) also an
    /// unconfirmed candidate the next envelope window must confirm.
    private func publishPeak(at now: Date, allowSeed: Bool) -> (hinted: Bool, seeded: Bool, note: String) {
        guard let (peak, rate, media) = ledgerPeak(at: now), Double(peak.confidence) >= tuning.hintMinConfidence else { return (false, false, "") }
        var note = String(format: " · peak %.1f conf %.1f cues %d (%d strong) → %.1f", peak.weight, peak.confidence, peak.distinctCues, peak.distinctStrongCues, media)
        if memorySuspect { return (false, false, note + " (suspect)") }
        // Drifting: a peak far from the prediction turns drifting into a hinted search (the
        // envelope decides; the lock is kept for the display until it does).
        if tracker.state == .drifting, let lock = tracker.lock {
            guard peak.distinctCues >= 2, abs(media - lock.mediaTime(at: now)) > tuning.memoryLockedRadiusSeconds else { return (false, false, note) }
            tracker.state = .searching
            tracker.lockPoints = []
        }
        if tracker.state == .candidate, !memorySeededCandidate { return (false, false, note) }
        if tracker.state == .locked {
            guard staleSuspect, allowSeed, let lock = tracker.lock, peak.distinctStrongCues >= 2,
                  abs(media - lock.mediaTime(at: now)) > tuning.memoryLockedRadiusSeconds else { return (false, false, note) }
            preReseedLock = (lock, tracker.state, tracker.misses)
            tracker.lock = SyncTracker.Lock(wallAnchor: now, mediaAtAnchor: media, rate: rate, score: min(1, peak.weight / 4), confirmed: false)
            tracker.rate = rate
            tracker.lockPoints = []
            tracker.misses = 0
            tracker.state = .candidate
            memorySeededCandidate = true
            seededAt = now
            memoryHintWall = now
            // The analysis window anchors at this seed's first evidence (never earlier: a window
            // that straddles the skip / pause would judge the candidate on the old position).
            windowAnchor = memoryEvidenceStart ?? now.addingTimeInterval(-tuning.memoryLookbackSeconds)
            staleSuspect = false
            reseedCount += 1
            return (true, true, note + String(format: " stale lock re-seeded (%+.1f s, rate %.4f)", media - lock.mediaTime(at: now), rate))
        }
        tracker.hint(mediaTime: media, at: now, confidence: Double(peak.confidence))
        if index.count > 0 {
            // A peak that signatures may have shaped: narrow hinted search, and a failure of
            // that search counts toward `memorySuspect`.
            tracker.hintRadiusSeconds = Self.memoryHintRadiusSeconds
            memoryHintWall = now
        } else {
            // First watch, phrases only: V1's ±60 s hinted path, never a memory failure
            // (reviewer fix — two short early windows used to silence phrase hints for the
            // whole session through `memorySuspect`).
            tracker.hintRadiusSeconds = nil
        }
        var seeded = false
        // Seeding needs two distinct *strong* cues (not clustered, ≥ 1.5 s of speech): three
        // twins of one repeated exchange are one piece of evidence, not three (§3.6).
        if allowSeed, peak.distinctStrongCues >= 2, tracker.state != .candidate {
            tracker.lock = SyncTracker.Lock(wallAnchor: now, mediaAtAnchor: media, rate: rate, score: min(1, peak.weight / 4), confirmed: false)
            tracker.rate = rate
            tracker.lockPoints = []
            tracker.misses = 0
            tracker.state = .candidate
            memorySeededCandidate = true
            seededAt = now
            preReseedLock = nil
            windowAnchor = memoryEvidenceStart ?? now.addingTimeInterval(-tuning.memoryLookbackSeconds)
            seeded = true
            note += String(format: " seeded (rate %.4f)", rate)
        }
        return (true, seeded, note)
    }
}

// MARK: - Tracker helpers

extension SyncTracker {
    /// Expectation kinds for the capture gate are computed by `MemoryTracker`; this is the one
    /// tracker-side helper the memory step needs: the cue the lock predicts at `wall`.
    func predictedCueIndex(at wall: Date, cues: [Cue]) -> Int? {
        guard let media = predictedMediaTime(at: wall) else { return nil }
        var lo = 0, hi = cues.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if media < cues[mid].start { hi = mid - 1 } else if media >= cues[mid].end { lo = mid + 1 } else { return mid }
        }
        return nil
    }
}
