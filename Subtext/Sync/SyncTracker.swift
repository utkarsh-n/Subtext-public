import Foundation

/// The sync brain: takes microphone speech windows and recognised words, decides where the
/// film is, and keeps deciding as it plays. Pure logic, no audio APIs, so it runs in the
/// macOS harness exactly as it runs on the phone.
///
/// States: searching (full-track correlation, helped by transcript hints) → candidate (a
/// match that still needs a second window to agree) → locked (narrow ±3 s tracking every
/// window) → drifting (a few misses; widen) → back to searching after persistent misses.
final class SyncTracker {
    struct Lock: Sendable, Equatable {
        /// Wall-clock instant this lock describes.
        let wallAnchor: Date
        /// Media time at that instant.
        let mediaAtAnchor: Double
        /// Playback speed relative to the subtitle track.
        let rate: Double
        let score: Float
        /// False while the match still awaits agreement from a second window.
        let confirmed: Bool

        func mediaTime(at wall: Date) -> Double {
            mediaAtAnchor + wall.timeIntervalSince(wallAnchor) * rate
        }
    }

    enum State: Sendable, Equatable { case listening, searching, candidate, locked, drifting }

    struct Report: Sendable {
        let state: State
        let lock: Lock?
        let speechFraction: Double
        let lastScore: Float?
        let note: String
    }

    struct Tuning {
        var minWindowSeconds = 12.0
        var minSpeechFraction = 0.06
        var maxSpeechFraction = 0.92
        /// Full-track search acceptance. Measured on synthetic films: the right film reaches
        /// onset-z ≥ 9.6 and envelope-z ≥ 5.8 with a minute of audio; wrong films never pass
        /// onset-z 7.7 or envelope-z 4.1.
        var searchScore: Float = 0.30
        var searchZ: Float = 4.5
        var searchOnsetZ: Float = 8.5
        var searchOnsetMargin: Float = 0.15
        var searchMinOnsets = 6
        /// Hinted (±60 s) search acceptance: far fewer candidate lags, so less luck to beat.
        var hintedScore: Float = 0.30
        var hintedOnsetZ: Float = 6.5
        var hintedOnsetMargin: Float = 0.10
        var hintedMinOnsets = 4
        /// Narrow tracking acceptance.
        var trackScore: Float = 0.30
        var trackOnsetScore: Float = 0.30
        var trackMinOnsetsForCheck = 5
        var trackRadiusSeconds = 3.0
        var driftRadiusSeconds = 15.0
        var missesBeforeDrift = 3
        var missesBeforeSearch = 6
        var hintWindowSeconds = 60.0
        var hintMaxAge = 25.0
        var hintMinConfidence = 1.5
        var hintMinScore = 3.0
        /// Playback speeds tried during a full search: nominal and the two PAL/NTSC transfers.
        /// Speed-watching rates are added when the user says so (each costs a full correlation).
        var searchRates: [Double] = [1, 25 / 23.976, 23.976 / 25]

        // MARK: V2 constants (names fixed in WP0; defaults per docs/v2/critique.md).
        // The V1 analyse() path above reads none of these, so S0/S13 numbers are unchanged.

        // MARK: Check-ins and the scheduler (B §3–§9, A §3, critique C3)
        /// Minimum audio behind a check-in window (A). Windows shorter than this are `.tooShort`.
        var trackMinWindowSeconds = 8.0
        /// Routine check-in windows: W 30 s, extended to 45 s then 60 s by the evidence gate.
        var checkInWindowSeconds: [Double] = [30, 45, 60]
        /// Evidence gate: fewer onsets than this → extend the window, then `.inconclusive`.
        var checkInMinOnsets = 4
        /// T0 narrow ±4 s.
        var checkInNarrowRadius = 4.0
        /// T1 medium: ±max(10, 3 + 0.05 × Δt since last good), capped at ±45 s.
        var checkInMediumMin = 10.0
        var checkInMediumCap = 45.0
        var checkInMediumSlope = 0.05
        /// T2 asymmetric: ahead +60 s; behind = elapsed since last good + margin, cap 15 min.
        var checkInAheadSeconds = 60.0
        var checkInBehindCapSeconds = 900.0
        var lostBehindMargin = 10.0
        /// Tier R after a hold: [held − 15 s, held + 60 s].
        var postHoldBehind = 15.0
        var postHoldAhead = 60.0
        /// Resume hypotheses A/B searched at ±5 s.
        var hypothesisRadius = 5.0
        /// Per-tier onsetZ acceptance (T0 / T1 / T2), placeholders until harness S6 sets them.
        var tierOnsetZ: [Float] = [4.0, 5.5, 6.5]
        var tierMinOnsets = [4, 4, 5]
        var tierScore: Float = 0.30
        var tierOnsetScore: Float = 0.30
        var tierOnsetMargin: Float = 0.10
        /// Catch-up (behind > 60 s) acceptance: hinted + 0.5 (critique R1).
        var catchUpOnsetZ: Float = 7.0
        /// Large-delta rule (critique C3): ≤ 3 s apply; 3–8 s apply + verify at 6 s;
        /// > 8 s with evidence apply + verify; > 8 s without evidence → pending, confirm at +10 s.
        var checkInDeadband = 0.12
        var checkInConfirmAbove = 3.0
        var candidateVerifyDelta = 8.0
        var checkInVerifyDelay = 6.0
        var checkInVerifyRetryDelay = 10.0
        var checkInConfirmDelay = 10.0
        var checkInConfirmAgree = 1.0
        /// Deferred backward snap: 0.12 ≤ |r| < 1 s backward waits for a cue boundary or 3 s.
        var deferredSnapBelow = 1.0
        var deferredSnapMaxDelay = 3.0
        /// Nudge guard: skip |r| < 1 s corrections within 20 s of a user nudge.
        var nudgeGuardSeconds = 20.0
        var nudgeGuardBelow = 1.0
        /// Probe every 10 ticks: T0 ±4 s on the last 20 s; alarm on 2 misses or 2 × |r| ≥ 1 s.
        var probeIntervalSeconds = 10.0
        var probeWindowSeconds = 20.0
        var probeRadiusSeconds = 4.0
        var probeAlarmResidual = 1.0
        var probeAlarmCount = 2
        /// Adaptive cadence: 30 s → ×2 → cap (300 s, `tuning.adaptiveCap`; 120 s until rateConfirmed);
        /// ÷2 on 0.3–1.0 s residuals; reset to 30 s on ≥ 1 s, misses, rate change, hold, nudge, seed.
        var adaptiveStartSeconds = 30.0
        var adaptiveCapSeconds = 300.0
        var adaptiveCapUnconfirmedSeconds = 120.0
        var adaptiveGrowBelow = 0.3
        var adaptiveResetAbove = 1.0
        var adaptiveFloorSeconds = 30.0
        /// Settle rule: confirmed lock + 3 consecutive track hits < 0.5 s + ≥ 30 s tracked.
        var settleHits = 3
        var settleDelta = 0.5
        var settleMinTrackedSeconds = 30.0
        /// Seed / jump / seek → lockedIn with the first check-in at +15 s.
        var seedFirstCheckInSeconds = 15.0
        /// Retry schedule: inconclusive +15 s; miss 1 +10 s (W45); miss 2 +15 s (W60, behind ×2); miss 3 → lost.
        var inconclusiveRetrySeconds = 15.0
        var missRetrySeconds: [Double] = [10, 15]
        var missesBeforeLost = 3
        /// Lost: T2 every 15 s; 3 misses with content & evidence → reacquiring.
        var lostRetrySeconds = 15.0
        var lostMissesBeforeReacquire = 3
        /// Lost retry stretches to 30 s if a T2 step exceeds 400 ms on device (critique R8).
        var lostRetrySlowSeconds = 30.0
        var tierStepBudgetMs = 400.0
        /// Transcriber restarts in reacquiring / probing fallback for at most 90 s.
        var reacquireTranscriberSeconds = 90.0
        /// Resume after a hold: check-in at ≥ 12 s of post-release audio, attempts every 3 s to 30 s.
        var resumeMinAudioSeconds = 12.0
        var resumeAttemptStepSeconds = 3.0
        var resumeMaxAudioSeconds = 30.0
        var resumeAttemptsBeforeProbing = 2
        /// Island Play after a pause: behind = held duration + 5 s, large delta allowed immediately.
        var resumeBehindMargin = 5.0
        /// Probing: 30 s of adequate evidence without acceptance → lost.
        var probingLostAfterSeconds = 30.0
        /// Re-sync: wide pass T1 (±45 s) then T2 (±5 min symmetric) before a full search;
        /// two Re-syncs within 10 s → full search immediately.
        var resyncWideRadiusSeconds = 300.0
        var resyncDoubleTapSeconds = 10.0
        /// Tap gaps longer than this surface as `micLost`.
        var tapGapSeconds = 5.0

        // MARK: Rate estimation (B §6, critique D8)
        /// Dense segments (≥ 6 points within 15 min) use V1 least squares; sparse ones Theil–Sen.
        var rateDenseMinPoints = 6
        var rateDenseMaxSpanSeconds = 900.0
        var rateSparseMaxPoints = 8
        var rateSparseMinSpanSeconds = 90.0
        /// |slope − preset| < 0.004 → preset; free slope only after 3 consecutive non-preset fits.
        var ratePresetTolerance = 0.004
        var rateFreeSlopeFits = 3
        /// rateConfirmed = ≥ 6 points over ≥ 120 s (A) or two consecutive stretch votes (B).
        var rateConfirmedMinPoints = 6
        var rateConfirmedMinSpanSeconds = 120.0
        var rateStretchVotes = 2
        /// Any snap larger than this starts a new rate segment.
        var rateSegmentSnapSeconds = 2.0

        // MARK: Presence (C §4, §11; the critique's freeze instant is onset − 0.5 s)
        var presenceWindowSeconds = 4.0
        var presenceFloorPercentile = 0.10
        var presenceFloorSeconds = 60.0
        var absentLevelDb: Float = 3
        var absentPeakDb: Float = 6
        var absentDepthDb: Float = 3
        var absentFluxDb: Float = 1.5
        var absentRoomDistance: Float = 1.5
        var absentTvDistance: Float = 3.0
        var presentDepthDb: Float = 5
        var presentFluxDb: Float = 3
        var presentPeakDb: Float = 8
        var presentTvDistance: Float = 2.0
        var holdSpeechFraction: Float = 0.15
        var holdModRatio: Float = 0.35
        var musicDepthDb: Float = 4
        var musicModRatioMax: Float = 0.30
        var musicFlatnessMax: Float = 0.5
        var missedExpectedRatio = 0.75
        var minExpectedSeconds = 4.0
        var ledgerSeconds = 8.0
        /// Normal 6 s / 10 s; patient 12 s / 20 s (`AutoPausePatience`).
        var confirmDialogueSeconds = 6.0
        var confirmAbsentSeconds = 10.0
        var absentTicksToConfirm = 2
        /// Freeze instant = earliest absent tick − onsetLeadSeconds (critique D5).
        var onsetLeadSeconds = 0.5
        /// Tier A optimistic resume: ±0.5 s single-lag check on the last 4 s.
        var quickPScore: Float = 0.45
        var quickPOnsetScore: Float = 0.5
        var quickPRadiusSeconds = 0.5
        var quickPWindowSeconds = 4.0
        var reacquireRadiusSeconds = 3.0
        var reacquireHintedRadiusSeconds = 90.0
        var probeFullSearchAfterSeconds = 30.0
        var probeHoldAfterSeconds = 60.0
        /// Auto-end: warning 120 s before the kill clock; never-locked sessions end at killAfter + 10 min.
        var warnBeforeSeconds = 120.0
        var neverLockedExtraSeconds = 600.0
        var sessionTimeLimitSeconds = 7 * 3600.0 + 55 * 60
        var endedActivityLingerSeconds = 15 * 60.0
        var roomLearnSeconds = 10.0
        var roomBootstrapSeconds = 3.0
        var profileReadySeconds = 20.0
        var profileForgetSeconds = 600.0
        var presenceEveryTicks = 2

        // MARK: Audio memory (D §3, §5; capture-on-tick per critique C10)
        var useTextExpectations = false
        var memoryConfirmFloor: Float = 0.50
        var memoryConfirmCap: Float = 0.85
        var memoryConfirmDelta: Float = 0.15
        var memoryMargin: Float = 0.10
        var memoryCorrectionDelta: Float = 0.20
        var memoryAgreeSeconds = 1.0
        var memoryReseedAgreeCount = 2
        var memoryReseedAgreeSeconds = 1.5
        var memoryMinSignatures = 30
        var memoryMinCoverage = 0.25
        var memoryHintFailuresBeforeSuspect = 2
        var memoryConfirmMinSpeechSeconds = 2.0
        var memoryLockedRadiusSeconds = 3.0
        var memoryDriftRadiusSeconds = 15.0
        var memoryLookbackSeconds = 8.0
        var memoryCoarseTop = 20
        var memorySearchStepBudgetMs = 400.0
        var memorySearchDisableMs = 800.0
        var captureMinSpeechFraction = 0.30
        var captureMinSeconds = 0.6
        var captureLeadSeconds = 0.3
        var captureStability = 3
        var captureReplaceDeltaDb: Float = 3
        /// Capture gate while locked-in: last probe hit ≤ 10 s old, no correction > 0.5 s in 10 s.
        var captureMaxProbeAgeSeconds = 10.0
        var captureMaxCorrectionSeconds = 0.5
        var captureCorrectionWindowSeconds = 10.0
        var captureManualQuietSeconds = 10.0
        /// Relisten (Theater long-press): hinted search ±60 s around the predicted time.
        var relistenRadiusSeconds = 60.0
    }

    var tuning = Tuning()
    // Internal (not private) so the WP2–WP4 extensions in Sync/Logic can reach them.
    var state: State = .listening
    var lock: Lock?
    var rate: Double = 1
    /// A's rule: ≥ 6 lock points spanning ≥ 120 s (set in `refitRate`, cleared in `resync`).
    /// WP2's RateEstimator may also set it from two consecutive stretch votes.
    var rateConfirmed = false
    /// Wall time of the last confirmed lock adoption (seed, confirm, confirmed track hit).
    var lastConfirmedLockWall: Date?

    let reference: Correlator.Reference
    let matcher: TranscriptMatcher
    var hint: (mediaTime: Double, wall: Date, confidence: Double)?
    /// Overrides `tuning.hintWindowSeconds` for the next hinted search (relisten); nil = default.
    var hintRadiusSeconds: Double?
    var misses = 0
    var lockPoints: [(wall: Date, media: Double)] = []
    var lastScore: Float?

    init(cues: [Cue]) {
        reference = Correlator.Reference(cues: cues)
        matcher = TranscriptMatcher(cues: cues)
    }

    var referenceBinCount: Int { reference.count }

    // MARK: Inputs

    /// Recognised words, with the wall-clock time the last of them was spoken.
    func addHint(words: [String], heardAt wall: Date) {
        guard let hit = matcher.locate(words: words),
              hit.score >= tuning.hintMinScore,
              hit.confidence >= tuning.hintMinConfidence else { return }
        hint = (hit.mediaTime, wall, hit.confidence)
    }

    /// The user (or a confirmed external source) says the film is at `mediaTime` right now.
    func seed(mediaTime: Double, at wall: Date) {
        lock = Lock(wallAnchor: wall, mediaAtAnchor: mediaTime, rate: rate, score: 1, confirmed: true)
        lockPoints = [(wall, mediaTime)]
        misses = 0
        state = .locked
        lastConfirmedLockWall = wall
    }

    func resync() {
        lock = nil
        hint = nil
        hintRadiusSeconds = nil
        lockPoints = []
        misses = 0
        rate = 1
        rateConfirmed = false
        state = .searching
    }

    /// A relaunch seed or an escalation hint: the next search is hinted (±`hintWindowSeconds`)
    /// around `mediaTime` as of `wall`, and widens to full after `hintMaxAge`.
    func hint(mediaTime: Double, at wall: Date, confidence: Double = 10) {
        hint = (mediaTime, wall, confidence)
    }

    /// The user says the current lines are right: confirm the lock, clear misses.
    func confirm() {
        guard let lock else { return }
        self.lock = Lock(wallAnchor: lock.wallAnchor, mediaAtAnchor: lock.mediaAtAnchor, rate: lock.rate,
                         score: lock.score, confirmed: true)
        misses = 0
        state = .locked
        lastConfirmedLockWall = lock.wallAnchor
    }

    /// Theater long-press: a hinted search of ±`radius` around `center` while the old lock keeps
    /// driving the clock. The next `analyse` takes the hinted path because `state == .searching`.
    func relisten(center: Double, at wall: Date, radius: Double? = nil) {
        hint = (center, wall, 10)
        hintRadiusSeconds = radius ?? tuning.relistenRadiusSeconds
        misses = 0
        state = .searching
    }

    /// Fraction of the reference envelope that is speech over media `[from, to)`.
    func expectedSpeechFraction(from: Double, to: Double) -> Double {
        SpeechEnvelope.expectedSpeechFraction(reference: reference.envelope, from: from, to: to)
    }

    func predictedMediaTime(at wall: Date) -> Double? { lock?.mediaTime(at: wall) }

    // MARK: Analysis

    /// `mic` is 0/1 bins in wall-clock time starting at `windowStart`.
    func analyse(mic: [Float], windowStart: Date, now: Date) -> Report {
        let seconds = Double(mic.count) * SpeechEnvelope.binDuration
        let fraction = SpeechEnvelope.speechFraction(mic)

        guard seconds >= tuning.minWindowSeconds else {
            if state == .listening || state == .searching { state = .searching }
            return report(fraction, "need \(Int(tuning.minWindowSeconds))s of audio")
        }
        guard fraction >= tuning.minSpeechFraction else {
            return report(fraction, "too little speech")
        }
        guard fraction <= tuning.maxSpeechFraction else {
            return report(fraction, "constant noise")
        }

        if let lock, state != .searching {
            let stretched = SpeechEnvelope.stretched(mic, rate: lock.rate)
            let predictedBin = SpeechEnvelope.bin(for: lock.mediaTime(at: windowStart))
            let radius = SpeechEnvelope.bin(for: state == .drifting ? tuning.driftRadiusSeconds : tuning.trackRadiusSeconds)
            let range = (predictedBin - radius)..<(predictedBin + radius)
            if let match = Correlator.search(mic: stretched, reference: reference, range: range),
               match.score >= tuning.trackScore,
               match.onsetCount < tuning.trackMinOnsetsForCheck || match.onsetScore >= tuning.trackOnsetScore {
                lastScore = match.score
                let agrees = abs(match.mediaTime - lock.mediaTime(at: windowStart)) < 1.5
                adopt(mediaAtStart: match.mediaTime, windowStart: windowStart, score: match.score,
                      confirmed: lock.confirmed || agrees)
                return report(fraction, "tracking")
            }
            misses += 1
            lastScore = nil
            if misses >= tuning.missesBeforeSearch {
                state = .searching
                lockPoints = []
            } else if misses >= tuning.missesBeforeDrift || !lock.confirmed {
                // An unconfirmed candidate that misses once is not worth keeping.
                if !lock.confirmed { self.lock = nil; state = .searching } else { state = .drifting }
            }
            return report(fraction, "missed \(misses)")
        }

        // Full or hinted search, trying each plausible playback speed.
        var range = 0..<reference.count
        var hinted = false
        if let hint, now.timeIntervalSince(hint.wall) < tuning.hintMaxAge {
            let elapsed = windowStart.timeIntervalSince(hint.wall)
            let centre = SpeechEnvelope.bin(for: hint.mediaTime + elapsed)
            let radius = SpeechEnvelope.bin(for: hintRadiusSeconds ?? tuning.hintWindowSeconds)
            range = max(0, centre - radius)..<min(reference.count, centre + radius)
            hinted = true
        }
        var best: (match: Correlator.Match, rate: Double)?
        for candidate in tuning.searchRates {
            let stretched = SpeechEnvelope.stretched(mic, rate: candidate)
            guard let m = Correlator.search(mic: stretched, reference: reference, range: range) else { continue }
            if best == nil || m.zScore > best!.match.zScore { best = (m, candidate) }
        }
        guard let (match, matchRate) = best else {
            return report(fraction, "no correlation")
        }
        lastScore = match.score
        let accepted = hinted
            ? (match.score >= tuning.hintedScore && match.onsetCount >= tuning.hintedMinOnsets
               && match.onsetZ >= tuning.hintedOnsetZ && match.onsetMargin >= tuning.hintedOnsetMargin)
            : (match.score >= tuning.searchScore && match.zScore >= tuning.searchZ
               && match.onsetCount >= tuning.searchMinOnsets && match.onsetZ >= tuning.searchOnsetZ
               && match.onsetMargin >= tuning.searchOnsetMargin)
        guard accepted else {
            state = .searching
            return report(fraction, String(format: "%@ search: env %.2f z %.1f m %.2f | onset %.2f m %.2f n %d oz %.1f", hinted ? "hinted" : "full", match.score, match.zScore, match.margin, match.onsetScore, match.onsetMargin, match.onsetCount, match.onsetZ))
        }
        misses = 0
        lockPoints = []
        hintRadiusSeconds = nil
        rate = matchRate
        lock = Lock(wallAnchor: windowStart, mediaAtAnchor: match.mediaTime, rate: rate, score: match.score, confirmed: false)
        lockPoints.append((windowStart, match.mediaTime))
        state = .candidate
        return report(fraction, String(format: "candidate env %.2f z %.1f | onset %.2f m %.2f n %d rate %.3f", match.score, match.zScore, match.onsetScore, match.onsetMargin, match.onsetCount, matchRate))
    }

    // MARK: Internals

    func adopt(mediaAtStart: Double, windowStart: Date, score: Float, confirmed: Bool) {
        misses = 0
        if confirmed { lastConfirmedLockWall = windowStart }
        lockPoints.append((windowStart, mediaAtStart))
        let cutoff = windowStart.addingTimeInterval(-15 * 60)
        lockPoints.removeAll { $0.wall < cutoff }
        if lockPoints.count > 60 { lockPoints.removeFirst(lockPoints.count - 60) }
        refitRate()
        lock = Lock(wallAnchor: windowStart, mediaAtAnchor: mediaAtStart, rate: rate, score: score, confirmed: confirmed)
        state = confirmed ? .locked : .candidate
    }

    /// Least-squares slope of media time against wall time over recent locks → playback rate.
    func refitRate() {
        guard lockPoints.count >= 6, let first = lockPoints.first, let last = lockPoints.last,
              last.wall.timeIntervalSince(first.wall) >= 120 else { return }
        rateConfirmed = true
        let xs = lockPoints.map { $0.wall.timeIntervalSince(first.wall) }
        let ys = lockPoints.map(\.media)
        let n = Double(xs.count)
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        var cov = 0.0, varX = 0.0
        for i in 0..<xs.count {
            cov += (xs[i] - mx) * (ys[i] - my)
            varX += (xs[i] - mx) * (xs[i] - mx)
        }
        guard varX > 0 else { return }
        var slope = cov / varX
        slope = min(2.0, max(0.5, slope))
        if abs(slope - 1) < 0.004 { slope = 1 }
        rate = rate * 0.6 + slope * 0.4
        if abs(rate - 1) < 0.002 { rate = 1 }
    }

    func report(_ fraction: Double, _ note: String) -> Report {
        Report(state: state, lock: lock, speechFraction: fraction, lastScore: lastScore, note: note)
    }
}
