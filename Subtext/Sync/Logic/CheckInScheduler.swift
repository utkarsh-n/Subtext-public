import Foundation

// Pure Foundation. Compiled into the app and into Tools/synctest (Subtext/Sync/Logic/**).
//
// The session state machine of docs/v2/critique.md §4.2 (checkin.md §9 with the C3 merges):
// acquiring → lockedIn ⇄ checkingIn, held / resuming / probing, lost → reacquiring, plus the
// presence-driven ending/ended and micLost. It owns the trim-free `belief: PlaybackClock` and the
// `RateEstimator`, and only ever *emits* actions: the engine runs check-ins/probes/analyses and
// forwards `SessionAction`s to `SessionController`, the only writer of the display clock.
//
// Every `Date` passed in comes from the session `Timebase` (`SimTimebase` in the harness).
//
// TODO(WP7) wiring in SyncEngine (names from docs/v2/wp0-report.md):
//   onTick (1 Hz, analysisQueue)      → scheduler.tick(now:) → execute(actions)
//   .analyse(windowSeconds:)          → ring.latest → tracker.analyse → scheduler.didAnalyse(...)
//                                       (the V1 onLock path still applies acquiring locks)
//   .runCheckIn(req)                  → tracker.checkIn(req, ring:, now:) → scheduler.didCheckIn(...)
//   .runProbe(req)                    → tracker.probe(req, ring:, now:) → scheduler.didProbe(...)
//   .reacquire(hint:at:)              → tracker.resync(); hint.map { tracker.hint(mediaTime:at:) }
//   (the ring is never restarted: post-release audio is selected by `notBefore` on every
//    check-in / probe request, which keeps the audio between the release and its detection and
//    avoids re-stamping the ring from an instant that is already in the past)
//   .start/.stopTranscriber           → transcriber lifecycle (critique C9)
//   .session(action)                  → SessionController.apply(action:) on the main actor
//   PresenceTracker events (WP3)      → presenceHeld / presenceReleased / presenceEvidence / presenceWarn / presenceEnd
//   SessionController commands        → userPause / userResume / userNudged / userSeeded / userResync
//   SyncTracker+Memory confirm (WP4)  → memoryConfirmed(media:at:now:)
//   AudioCapture MicState             → micLost / micRecovered
//
// Ordering contract: apply the actions of one call in order, and queue the actions returned by
// a nested result (`didCheckIn` / `didProbe` / `didAnalyse`) *behind* the rest of the batch that
// issued the request (FIFO), never nested — a `.status(.checkingIn)` emitted by the tick that
// issued a check-in must reach SessionController before the `.status(.lockedIn)` of its result.
// The harness (`CheckInRun.execute`) does exactly this; a serial `analysisQueue` does it for free
// when each action is dispatched as its own block.
//
// Robustness to the presence tracker's event granularity: the scheduler goes probing → held on
// two absent ticks of its own and re-opens probing on `.present` evidence, and it accepts a
// second `presenceReleased` while already resuming / probing. WP7 therefore need not synthesise
// extra `released` events when `PresenceTracker` bounces probing → paused without emitting one.

final class CheckInScheduler {
    typealias State = SchedulerState

    struct Policy: Equatable {
        /// false = V1 continuous: stay in `acquiring`, analyse every 2 ticks, never settle.
        var lockedIn = true
        var interval: CheckInInterval = .adaptive
        /// Harness knob only (no UI): the 10 s probe while locked-in.
        var probe = true
        var speedWatching = false
    }

    enum Action: Equatable {
        /// V1 `tracker.analyse` on the latest `windowSeconds` (acquiring / reacquiring), then `didAnalyse`.
        case analyse(windowSeconds: Double)
        case runCheckIn(SyncTracker.CheckInRequest)
        case runProbe(SyncTracker.ProbeRequest)
        /// `tracker.resync()` and, with a hint, `tracker.hint(mediaTime:at:)` (reacquiring / full re-sync).
        case reacquire(hint: Double?, at: Date)
        case startTranscriber
        case stopTranscriber
        case session(SessionAction)
    }

    struct Stats: Equatable {
        var checkIns = 0
        var conclusive = 0
        var misses = 0
        var inconclusive = 0
        var tierCounts = [0, 0, 0, 0]
        var hypothesisWins: [String: Int] = [:]
        var probes = 0
        var probeHits = 0
        var probeAlarms = 0
        var correlations = 0
        var checkInMilliseconds = 0.0
        var corrections = 0
        var skippedByNudgeGuard = 0
        var pendingLarge = 0
        var verifies = 0
        var fullSearches = 0
        var residuals: [Double] = []
        var intervals: [Double] = []
        var lostEpisodes = 0
        var reacquires = 0
    }

    var policy: Policy
    /// A copy of the tracker's tuning (the engine keeps both in step; `adaptiveCapSeconds` is the UI knob).
    var tuning: SyncTracker.Tuning
    private(set) var state: State = .idle
    /// Trim-free belief about the film's position (critique D5). Frozen while held / probing.
    private(set) var belief: PlaybackClock
    private(set) var rate: RateEstimator
    /// Current adaptive interval (before the unconfirmed-rate clamp).
    private(set) var interval: Double
    private(set) var nextCheckIn: Date?
    private(set) var lastCheckIn: Date?
    /// t_lastGood: the last instant the position was confirmed by a check-in, probe hit or settle.
    private(set) var lastGoodAt: Date?
    private(set) var lastResidual: Double?
    private(set) var lastCorrection: Correction?
    private(set) var lastNote = ""
    private(set) var stats = Stats()
    private(set) var inFlight: SyncTracker.CheckInRequest?
    var log: [String] = []
    var debug = false

    // Acquiring / settle.
    private var acquiringSince: Date?
    private var settleHits = 0
    private var firstConfirmedAt: Date?
    private var previousBelief: PlaybackClock?
    // Check-in episode.
    private var nextKind: SyncTracker.CheckInRequest.Kind = .scheduled
    private var checkInMisses = 0
    private var verifyStage = 0
    // Probe.
    private var lastProbeAt: Date?
    private var lastProbeHitAt: Date?
    private var probeMisses = 0
    private var probeResidualAlarms = 0
    // Hold / resume / probing.
    private var heldSince: Date?
    private var heldClock: PlaybackClock?
    private var releaseAt: Date?
    private var contentResumedAt: Date?
    private var resumeAttempts = 0
    private var resumeNextAt: Date?
    private var resumeUserOnly = false
    private var resumeBehind = 15.0
    private var probingAttempts = 0
    private var probingNextAt: Date?
    private var probingAbsentTicks = 0
    private var probingEvidenceSeconds = 0.0
    /// The scheduler itself went probing → held on absent evidence (the presence tracker may not
    /// emit a second `released` for that stretch, so `.present` evidence re-opens probing).
    private var selfHeldFromProbing = false
    private var evidence: PresenceEvidence = .none
    // Lost / reacquiring.
    private var lostMisses = 0
    private var lostRetry = 15.0
    private var transcriberOn = false
    /// When the transcriber was (re)started outside `acquiring` (probing fallback / reacquiring): ≤ 90 s (C9).
    private var transcriberSince: Date?
    /// A check-in request that was in flight when an event (hold, release, pause, re-sync, seed,
    /// mic loss, end) superseded it: its result is ignored when it arrives (reviewer fix).
    private var cancelled: SyncTracker.CheckInRequest?
    /// The state a `presenceWarn` interrupted, restored by `keepListening`.
    private var beforeEnding: State?
    private var endingPausedBelief = false
    // User.
    private var nudges: [(at: Date, seconds: Double)] = []
    private var lastNudgeAt: Date?
    private var lastResyncAt: Date?
    private var micLostAt: Date?
    private var tickCount = 0

    init(tuning: SyncTracker.Tuning, policy: Policy = Policy(), now: Date) {
        self.tuning = tuning
        self.policy = policy
        belief = PlaybackClock(media: 0, at: now, rate: 1, paused: true)
        rate = RateEstimator(tuning: tuning, speedWatching: policy.speedWatching)
        interval = tuning.adaptiveStartSeconds
    }

    // MARK: Session

    /// Start: `acquiring` with the transcriber on (V1 behaviour until the settle rule fires).
    func start(now: Date) -> [Action] {
        let old = state
        state = .acquiring(audioSeconds: 0)
        acquiringSince = now
        settleHits = 0
        firstConfirmedAt = nil
        previousBelief = nil
        belief = PlaybackClock(media: 0, at: now, rate: 1, paused: true)
        rate = RateEstimator(tuning: tuning, speedWatching: policy.speedWatching)
        interval = tuning.adaptiveStartSeconds
        nextCheckIn = nil
        lastCheckIn = nil
        lastGoodAt = nil
        lastResidual = nil
        lastCorrection = nil
        lastNote = ""
        stats = Stats()
        inFlight = nil
        cancelled = nil
        nextKind = .scheduled
        checkInMisses = 0
        verifyStage = 0
        lastProbeAt = nil
        lastProbeHitAt = nil
        probeMisses = 0
        probeResidualAlarms = 0
        heldSince = nil
        heldClock = nil
        releaseAt = nil
        contentResumedAt = nil
        resumeAttempts = 0
        resumeNextAt = nil
        resumeUserOnly = false
        probingAttempts = 0
        probingNextAt = nil
        probingAbsentTicks = 0
        probingEvidenceSeconds = 0
        selfHeldFromProbing = false
        evidence = .none
        lostMisses = 0
        lostRetry = tuning.lostRetrySeconds
        transcriberSince = nil
        beforeEnding = nil
        endingPausedBelief = false
        nudges = []
        lastNudgeAt = nil
        lastResyncAt = nil
        micLostAt = nil
        tickCount = 0
        transcriberOn = true
        return [.startTranscriber] + publish(old)
    }

    func stop() {
        state = .idle
        cancelInFlight()
        nextCheckIn = nil
    }

    /// Forgets the check-in in flight; its result, when it arrives, is ignored by `didCheckIn`.
    private func cancelInFlight() {
        if let req = inFlight { cancelled = req }
        inFlight = nil
    }

    /// Seconds until the next scheduled check-in (Island countdown), nil when none is due.
    func timeToNextCheckIn(now: Date) -> Double? {
        guard state == .lockedIn, let next = nextCheckIn else { return nil }
        return max(0, next.timeIntervalSince(now))
    }

    // MARK: Tick (1 Hz, from the tap)

    func tick(now: Date) -> [Action] {
        tickCount += 1
        let old = state
        var out: [Action] = []
        switch state {
        case .idle, .ended, .manual, .micLost, .ending, .held, .checkingIn:
            break
        case .acquiring:
            state = .acquiring(audioSeconds: now.timeIntervalSince(acquiringSince ?? now))
            if tickCount % 2 == 0 { out.append(.analyse(windowSeconds: 60)) }
        case .reacquiring(let since):
            if transcriberOn, now.timeIntervalSince(transcriberSince ?? since) >= tuning.reacquireTranscriberSeconds {
                transcriberOn = false
                out.append(.stopTranscriber)
            }
            if tickCount % 2 == 0 { out.append(.analyse(windowSeconds: 60)) }
        case .lockedIn:
            guard inFlight == nil else { break }
            // Probe every 10 s; after a miss the confirming probe comes at half the interval so a
            // skip raises the two-miss alarm within 25 s (checkin.md §8, S2).
            let probeGap = probeMisses > 0 ? tuning.probeIntervalSeconds / 2 : tuning.probeIntervalSeconds
            if policy.probe, nextKind == .scheduled,
               now.timeIntervalSince(lastProbeAt ?? .distantPast) >= probeGap {
                lastProbeAt = now
                out.append(.runProbe(SyncTracker.ProbeRequest(clock: belief, windowSeconds: tuning.probeWindowSeconds,
                                                              radius: tuning.probeRadiusSeconds, notBefore: contentResumedAt)))
            }
            if let next = nextCheckIn, now >= next {
                out += issueCheckIn(kind: nextKind, now: now)
            }
        case .resuming(let since, _):
            guard inFlight == nil else { break }
            if now.timeIntervalSince(since) >= tuning.resumeMaxAudioSeconds {
                out += enterProbing(now: now)
            } else if now.timeIntervalSince(since) >= tuning.resumeMinAudioSeconds, now >= (resumeNextAt ?? now) {
                out += issueCheckIn(kind: .resume, now: now)
            }
        case .probing:
            guard inFlight == nil else { break }
            if transcriberOn, let since = transcriberSince, now.timeIntervalSince(since) >= tuning.reacquireTranscriberSeconds {
                transcriberOn = false
                out.append(.stopTranscriber)
            }
            if probingAbsentTicks >= tuning.absentTicksToConfirm {
                // The sound went away again before anything was accepted: back to held.
                probingAbsentTicks = 0
                selfHeldFromProbing = true
                state = .held(source: .auto, since: heldSince ?? now)
                note(now, "probing: quiet again, held")
            } else if probingEvidenceSeconds >= tuning.probingLostAfterSeconds {
                out += enterLost(now: now)
            } else if now >= (probingNextAt ?? now) {
                out += issueCheckIn(kind: .probing, now: now)
            }
        case .lost:
            guard inFlight == nil else { break }
            if let next = nextCheckIn, now >= next {
                out += issueCheckIn(kind: .lost, now: now)
            }
        }
        return out + publish(old)
    }

    // MARK: Analyse (acquiring / reacquiring)

    /// Result of a V1 `tracker.analyse` call. Mirrors the lock into `belief` and applies the settle
    /// rule (confirmed + 3 consecutive track hits < 0.5 s + ≥ 30 s tracked; reacquiring: confirmed).
    func didAnalyse(_ report: SyncTracker.Report, lockPoints: [(wall: Date, media: Double)], rateConfirmed: Bool,
                    now: Date) -> [Action] {
        let old = state
        var out: [Action] = []
        if report.note.hasPrefix("full search") || report.note.hasPrefix("candidate") { stats.fullSearches += 1 }
        stats.correlations += Self.correlations(in: report.note, rates: tuning.searchRates.count)
        switch state {
        case .acquiring, .reacquiring:
            break
        default:
            return []
        }
        guard let lock = report.lock else {
            settleHits = 0
            firstConfirmedAt = nil
            previousBelief = nil
            return []
        }
        let newBelief = PlaybackClock(media: lock.mediaTime(at: now), at: now, rate: lock.rate, paused: false)
        if lock.confirmed {
            if firstConfirmedAt == nil { firstConfirmedAt = now }
            if report.note == "tracking", let prev = previousBelief {
                let delta = abs(newBelief.mediaTime(at: now) - prev.mediaTime(at: now))
                settleHits = delta < tuning.settleDelta ? settleHits + 1 : 0
            }
        } else {
            firstConfirmedAt = nil
            settleHits = 0
        }
        previousBelief = newBelief
        belief = newBelief
        guard policy.lockedIn, lock.confirmed, report.state == .locked else { return [] }
        let tracked = now.timeIntervalSince(firstConfirmedAt ?? now)
        let settled: Bool
        if case .reacquiring = state { settled = true } else {
            settled = settleHits >= tuning.settleHits && tracked >= tuning.settleMinTrackedSeconds
        }
        guard settled else { return [] }
        rate.adopt(points: lockPoints, rate: lock.rate, confirmed: rateConfirmed)
        lastGoodAt = now
        if case .reacquiring = state { stats.reacquires += 1 }
        out += enterLockedIn(now: now, reset: true, verify: false)
        note(now, "settled: lockedIn at \(fmt(belief.mediaTime(at: now))) rate \(fmt(rate.rate, 4))")
        return out + publish(old)
    }

    // MARK: Check-ins

    private func candidateRates() -> [Double] { rate.confirmed ? [] : rate.presets }

    private func clampedInterval() -> Double? {
        let base: Double
        switch policy.interval {
        case .adaptive: base = interval
        case .manual: return nil
        default: base = policy.interval.fixedSeconds ?? interval
        }
        if rate.confirmed { return policy.interval == .adaptive ? min(base, tuning.adaptiveCapSeconds) : base }
        let cap = policy.probe ? tuning.adaptiveCapUnconfirmedSeconds : tuning.adaptiveFloorSeconds
        return min(base, cap)
    }

    private func shifted(_ clock: PlaybackClock, by seconds: Double) -> PlaybackClock {
        var c = clock
        c.shift(by: seconds)
        return c
    }

    private func buildRequest(kind: SyncTracker.CheckInRequest.Kind, now: Date) -> SyncTracker.CheckInRequest {
        let sinceGood = max(0, now.timeIntervalSince(lastGoodAt ?? now))
        let medium = min(tuning.checkInMediumCap, max(tuning.checkInMediumMin, 3 + tuning.checkInMediumSlope * sinceGood))
        let ladderWindows = tuning.checkInWindowSeconds
        switch kind {
        case .scheduled, .probeAlarm, .nudge, .forced:
            let attempt = checkInMisses + 1
            var behind = min(tuning.checkInBehindCapSeconds, sinceGood + tuning.lostBehindMargin)
            if attempt >= 3 { behind = min(tuning.checkInBehindCapSeconds, behind * 2) }
            var tiers: [SyncTracker.SearchTier] = [.narrow, .medium(radius: medium), .asymmetric(behind: behind, ahead: tuning.checkInAheadSeconds)]
            if attempt >= 2 { tiers.append(.full) }
            let windows = Array(ladderWindows.dropFirst(min(attempt - 1, ladderWindows.count - 1)))
            return .init(kind: kind, hypotheses: [.init(name: "belief", clock: belief)], hypothesisRadius: nil,
                         rates: candidateRates(), tiers: tiers, windowSeconds: windows, notBefore: contentResumedAt,
                         allowLargeImmediately: kind == .forced, issuedAt: now)
        case .verify:
            // T0 on the last 20 s (A); the evidence ladder extends it to 30/45 s and a miss on a
            // window with < 6 onsets is inconclusive (retry +10 s), never a demotion toward lost.
            return .init(kind: .verify, hypotheses: [.init(name: "belief", clock: belief)], hypothesisRadius: nil, rates: candidateRates(),
                         tiers: [.narrow], windowSeconds: [tuning.probeWindowSeconds] + ladderWindows.prefix(2), notBefore: contentResumedAt,
                         missMinOnsets: tuning.searchMinOnsets, issuedAt: now)
        case .confirm(let delta):
            return .init(kind: kind, hypotheses: [.init(name: "belief", clock: belief), .init(name: "pending", clock: shifted(belief, by: delta))],
                         hypothesisRadius: tuning.checkInNarrowRadius, rates: [], tiers: [], windowSeconds: ladderWindows,
                         notBefore: contentResumedAt, missMinOnsets: tuning.searchMinOnsets, issuedAt: now)
        case .resume:
            let heldDuration = max(0, (releaseAt ?? now).timeIntervalSince(heldSince ?? releaseAt ?? now))
            var hyps: [SyncTracker.Hypothesis] = [.init(name: "A", clock: belief)]
            if !resumeUserOnly { hyps.append(.init(name: "B", clock: shifted(belief, by: heldDuration * belief.rate))) }
            return .init(kind: .resume, hypotheses: hyps, hypothesisRadius: tuning.hypothesisRadius, rates: candidateRates(),
                         tiers: [.asymmetric(behind: resumeBehind, ahead: tuning.postHoldAhead)], windowSeconds: ladderWindows,
                         notBefore: releaseAt, allowLargeImmediately: true, issuedAt: now)
        case .probing:
            let release = releaseAt ?? now
            var p = heldClock ?? belief
            p.resume(at: release)
            let heldDuration = max(0, release.timeIntervalSince(heldSince ?? release))
            let c = shifted(p, by: heldDuration * p.rate)
            var tiers: [SyncTracker.SearchTier] = []
            if probingAttempts >= 1 { tiers.append(.asymmetric(behind: tuning.postHoldBehind, ahead: tuning.postHoldAhead)) }
            if probingAttempts >= 2 {
                tiers.append(.medium(radius: tuning.checkInMediumCap))
                tiers.append(.asymmetric(behind: min(tuning.checkInBehindCapSeconds, sinceGood + tuning.lostBehindMargin), ahead: tuning.checkInAheadSeconds))
            }
            return .init(kind: .probing, hypotheses: [.init(name: "P", clock: p), .init(name: "C", clock: c)],
                         hypothesisRadius: tuning.reacquireRadiusSeconds, rates: candidateRates(), tiers: tiers,
                         windowSeconds: ladderWindows, notBefore: release, allowLargeImmediately: true, issuedAt: now)
        case .lost:
            // T2 with the growing behind radius, then T3 (V1 full-search thresholds, applied with a
            // verify at 6 s): a far skip or a rewind beyond the behind radius is found on the first
            // lost check-in instead of waiting for reacquiring (S2c, S1d).
            let behind = min(tuning.checkInBehindCapSeconds, sinceGood + tuning.lostBehindMargin)
            let tiers: [SyncTracker.SearchTier] = [.asymmetric(behind: behind, ahead: tuning.checkInAheadSeconds), .full]
            return .init(kind: .lost, hypotheses: [.init(name: "belief", clock: belief)], hypothesisRadius: nil, rates: candidateRates(),
                         tiers: tiers, windowSeconds: ladderWindows, notBefore: contentResumedAt, allowLargeImmediately: true, issuedAt: now)
        case .resync:
            return .init(kind: .resync, hypotheses: [.init(name: "belief", clock: belief)], hypothesisRadius: nil, rates: candidateRates(),
                         tiers: [.medium(radius: tuning.checkInMediumCap), .asymmetric(behind: tuning.resyncWideRadiusSeconds, ahead: tuning.resyncWideRadiusSeconds)],
                         windowSeconds: [ladderWindows.first ?? 30], notBefore: contentResumedAt, allowLargeImmediately: true, issuedAt: now)
        }
    }

    private func issueCheckIn(kind: SyncTracker.CheckInRequest.Kind, now: Date) -> [Action] {
        let req = buildRequest(kind: kind, now: now)
        inFlight = req
        lastCheckIn = now
        stats.checkIns += 1
        if state == .lockedIn { state = .checkingIn(attempt: checkInMisses + 1) }
        note(now, "check-in \(kind) W\(req.windowSeconds.map { Int($0) }) tiers \(req.tiers.count) hyps \(req.hypotheses.map(\.name))")
        return [.runCheckIn(req)]
    }

    /// Asks for a check-in now (Island Re-sync single tap goes through `userResync`; this is the
    /// "Check now" / nudge-burst / mic-recovery path). `allowLarge` lets a > 8 s delta apply at once.
    func requestCheckIn(allowLarge: Bool, now: Date) -> [Action] {
        let old = state
        guard inFlight == nil else { return [] }
        var out: [Action] = []
        switch state {
        case .lockedIn:
            checkInMisses = 0
            out += issueCheckIn(kind: allowLarge ? .forced : .nudge, now: now)
        case .lost:
            // Bring the next lost check-in forward; a `.forced` request's retry path would
            // otherwise promote lost → lockedIn on an inconclusive window (reviewer fix).
            out += issueCheckIn(kind: .lost, now: now)
        default:
            break
        }
        return out + publish(old)
    }

    func didCheckIn(_ result: SyncTracker.CheckInResult, request: SyncTracker.CheckInRequest, now: Date) -> [Action] {
        let old = state
        if let c = cancelled, c == request {
            // Superseded by a hold / release / pause / re-sync / seed / mic event while it ran:
            // applying it now would overwrite the newer state (a held clock would resume).
            cancelled = nil
            stats.correlations += result.correlations
            note(now, "stale \(request.kind) result ignored")
            return []
        }
        inFlight = nil
        stats.correlations += result.correlations
        stats.checkInMilliseconds += result.milliseconds
        lastNote = result.note
        var out: [Action] = []
        note(now, "result \(request.kind): \(result.note) [W\(Int(result.windowSeconds)) n\(result.onsets) \(fmt(result.milliseconds, 1)) ms]")
        // Critique R8: a lost step over the tier budget stretches the lost cadence to 30 s.
        if case .lost = request.kind {
            lostRetry = result.milliseconds > tuning.tierStepBudgetMs ? tuning.lostRetrySlowSeconds : tuning.lostRetrySeconds
        }

        switch result.outcome {
        case .inconclusive:
            stats.inconclusive += 1
            out += retry(after: .inconclusive, request: request, now: now)
        case .miss:
            if evidence == .absent {
                // Misses while the latch says "no content" are not counted (checkin.md §4).
                stats.inconclusive += 1
                out += retry(after: .inconclusive, request: request, now: now)
            } else {
                stats.misses += 1
                stats.conclusive += 1
                out += retry(after: .miss, request: request, now: now)
            }
        case .accepted(let mediaAtStart, let measuredRate, _, let tier, let residual, let hypothesis):
            stats.conclusive += 1
            stats.tierCounts[min(tier, 3)] += 1
            if let h = hypothesis { stats.hypothesisWins[request.hypotheses[h].name, default: 0] += 1 }
            if case .confirm(let delta) = request.kind, hypothesis != 1 {
                // The belief hypothesis won (|r| < the ±4 s hypothesis radius): the pending delta was
                // a fluke and this is an ordinary T0 hit on the belief, applied as such (reviewer fix:
                // a 1–4 s residual here used to be counted as a miss).
                note(now, "pending delta \(fmt(delta)) rejected; belief confirmed (r \(fmt(residual)))")
                out += apply(mediaAtStart: mediaAtStart, measuredRate: measuredRate, residual: residual, tier: tier,
                             result: result, request: request, evidenceBacked: true, now: now)
                return out + publish(old)
            }
            out += apply(mediaAtStart: mediaAtStart, measuredRate: measuredRate, residual: residual, tier: tier,
                         result: result, request: request, evidenceBacked: evidenceBacked(request), now: now)
        }
        return out + publish(old)
    }

    private func evidenceBacked(_ request: SyncTracker.CheckInRequest) -> Bool {
        if request.allowLargeImmediately { return true }
        switch request.kind {
        case .scheduled, .verify: return false
        default: return true
        }
    }

    private enum RetryReason { case inconclusive, miss }

    private func retry(after reason: RetryReason, request: SyncTracker.CheckInRequest, now: Date) -> [Action] {
        var out: [Action] = []
        switch request.kind {
        case .scheduled, .probeAlarm, .nudge, .forced, .confirm:
            if reason == .miss {
                checkInMisses += 1
                interval = tuning.adaptiveStartSeconds
                if checkInMisses >= tuning.missesBeforeLost {
                    out += enterLost(now: now)
                    return out
                }
                let delay = tuning.missRetrySeconds[min(checkInMisses - 1, tuning.missRetrySeconds.count - 1)]
                nextCheckIn = now.addingTimeInterval(delay)
                if case .confirm = request.kind { nextKind = .scheduled } else { nextKind = request.kind }
            } else {
                nextCheckIn = now.addingTimeInterval(tuning.inconclusiveRetrySeconds)
                nextKind = request.kind
            }
            state = .lockedIn
        case .verify:
            if reason == .miss {
                verifyStage += 1
                if verifyStage >= 3 {
                    out += enterLost(now: now)
                    return out
                }
                nextCheckIn = now.addingTimeInterval(tuning.checkInVerifyRetryDelay)
            } else {
                nextCheckIn = now.addingTimeInterval(tuning.inconclusiveRetrySeconds)
            }
            nextKind = .verify
            state = .lockedIn
        case .resume:
            if reason == .miss { resumeAttempts += 1 }
            if resumeAttempts >= tuning.resumeAttemptsBeforeProbing {
                out += enterProbing(now: now)
            } else {
                resumeNextAt = now.addingTimeInterval(tuning.resumeAttemptStepSeconds)
                if case .resuming(let since, _) = state { state = .resuming(since: since, attempt: resumeAttempts) }
            }
        case .probing:
            if reason == .miss { probingAttempts += 1 }
            if reason == .miss, probingAttempts >= 2, !transcriberOn {
                // Hinted fallback (critique C9 / §4.2): the transcriber comes back after the first
                // ladder miss, for ≤ 90 s; its hint narrows T3 (`SyncTracker.checkIn` hinted path).
                transcriberOn = true
                transcriberSince = now
                out.append(.startTranscriber)
            }
            probingNextAt = now.addingTimeInterval(tuning.resumeAttemptStepSeconds)
        case .lost:
            if reason == .miss, evidence != .absent {
                lostMisses += 1
                if case .lost(let since, _) = state { state = .lost(since: since, misses: lostMisses) }
                if lostMisses >= tuning.lostMissesBeforeReacquire {
                    out += enterReacquiring(now: now)
                    return out
                }
            }
            nextCheckIn = now.addingTimeInterval(lostRetry)
            nextKind = .lost
            if case .lost = state, transcriberOn, let since = transcriberSince,
               now.timeIntervalSince(since) >= tuning.reacquireTranscriberSeconds {
                transcriberOn = false
                out.append(.stopTranscriber)
            }
        case .resync:
            out += enterAcquiring(now: now, hint: nil)
        }
        return out
    }

    /// Applies an accepted check-in: rate point / vote, nudge guard, dead band, large-delta rule,
    /// deferred backward snap, then back to `lockedIn` with the adapted interval.
    private func apply(mediaAtStart: Double, measuredRate: Double, residual: Double, tier: Int,
                       result: SyncTracker.CheckInResult, request: SyncTracker.CheckInRequest, evidenceBacked: Bool,
                       now: Date) -> [Action] {
        var out: [Action] = []
        let delta = abs(residual)
        let wasRecovering: Bool = {
            switch state {
            case .resuming, .probing, .lost, .held: return true
            default: return false
            }
        }()

        // Large delta without evidence: pending, confirm at +10 s (critique C3 / A).
        if delta > tuning.candidateVerifyDelta, !evidenceBacked {
            stats.pendingLarge += 1
            nextKind = .confirm(delta: residual)
            nextCheckIn = now.addingTimeInterval(tuning.checkInConfirmDelay)
            state = .lockedIn
            note(now, "pending large delta \(fmt(residual)); confirm at +\(Int(tuning.checkInConfirmDelay)) s")
            return out
        }

        // Rate: a new segment on any snap > 2 s, then the point and the stretch vote. A T3 full
        // search chose among every `searchRates` entry on a 30–60 s window: its rate is adopted
        // at once (V1 semantics); narrower tiers only vote.
        if delta > tuning.rateSegmentSnapSeconds { rate.newSegment() }
        var rateChanged = false
        if tier == 3, abs(measuredRate - rate.rate) > 1e-9 {
            rate.set(rate: measuredRate, confirmed: rate.confirmed)
            rateChanged = true
        }
        if let v = result.votedRate { rateChanged = rate.vote(rate: v) || rateChanged }
        rateChanged = rate.add(t: result.windowStart, media: mediaAtStart) || rateChanged
        let newRate = rate.rate

        // Nudge guard: |r| < 1 s within 20 s of a user nudge is skipped (the point still counts).
        let guarded = (lastNudgeAt.map { now.timeIntervalSince($0) < tuning.nudgeGuardSeconds } ?? false)
            && delta < tuning.nudgeGuardBelow && !wasRecovering
        if guarded { stats.skippedByNudgeGuard += 1 }

        var verify = false
        let mediaNow = mediaAtStart + now.timeIntervalSince(result.windowStart) * newRate
        if (delta >= tuning.checkInDeadband || rateChanged || belief.isPaused), !guarded {
            if belief.isPaused { belief.resume(at: now); out.append(.session(.resumeClock(at: now))) }
            belief.set(media: mediaNow, at: now, rate: newRate)
            let deferUntil = residual < 0 && delta >= tuning.checkInDeadband && delta < tuning.deferredSnapBelow
                ? now.addingTimeInterval(tuning.deferredSnapMaxDelay) : nil
            let correction = Correction(media: mediaNow, at: now, rate: newRate, residual: residual, deferUntil: deferUntil)
            lastCorrection = correction
            if delta >= tuning.checkInDeadband || rateChanged {
                stats.corrections += 1
                out.append(.session(.setClock(correction)))
            }
            if delta > tuning.checkInConfirmAbove || tier == 3 { verify = request.kind != .verify }
            if wasRecovering, delta >= tuning.checkInConfirmAbove { out.append(.session(.caughtUp(seconds: residual))) }
        }
        lastResidual = residual
        stats.residuals.append(residual)
        lastGoodAt = now
        checkInMisses = 0
        lostMisses = 0
        if request.kind != .verify { verifyStage = 0 }

        let forced: Bool = {
            switch request.kind {
            case .scheduled, .verify: return false
            default: return true
            }
        }()
        let reset = wasRecovering || forced || delta >= tuning.adaptiveResetAbove || tier >= 2 || rateChanged
        if !reset, request.kind == .scheduled {
            if delta < tuning.adaptiveGrowBelow {
                interval = min(tuning.adaptiveCapSeconds, interval * 2)
            } else {
                interval = max(tuning.adaptiveFloorSeconds, interval / 2)
            }
        }
        out += enterLockedIn(now: now, reset: reset, verify: verify)
        return out
    }

    private func enterLockedIn(now: Date, reset: Bool, verify: Bool) -> [Action] {
        var out: [Action] = []
        if reset { interval = tuning.adaptiveStartSeconds }
        if transcriberOn { transcriberOn = false; out.append(.stopTranscriber) }
        transcriberSince = nil
        state = .lockedIn
        probeMisses = 0
        probeResidualAlarms = 0
        lastProbeAt = now
        if verify {
            verifyStage = max(verifyStage, 1)
            stats.verifies += 1
            nextKind = .verify
            nextCheckIn = now.addingTimeInterval(tuning.checkInVerifyDelay)
        } else {
            nextKind = .scheduled
            if let secs = clampedInterval() {
                nextCheckIn = now.addingTimeInterval(secs)
                stats.intervals.append(secs)
            } else {
                nextCheckIn = nil
            }
        }
        return out
    }

    /// `lost`: t_lastGood kept, the clock runs on the fitted rate from where it stood (critique
    /// §4.2), lines dimmed by the phase; T2 (+ T3) every 15 s until accepted or reacquiring.
    private func enterLost(now: Date) -> [Action] {
        var out: [Action] = []
        state = .lost(since: now, misses: 0)
        stats.lostEpisodes += 1
        lostMisses = 0
        checkInMisses = 0
        verifyStage = 0
        interval = tuning.adaptiveStartSeconds
        nextKind = .lost
        nextCheckIn = now.addingTimeInterval(lostRetry)
        if belief.isPaused {
            belief.resume(at: now)
            out.append(.session(.resumeClock(at: now)))
        }
        selfHeldFromProbing = false
        note(now, "lost")
        return out
    }

    private func enterReacquiring(now: Date) -> [Action] {
        state = .reacquiring(since: now)
        settleHits = 0
        firstConfirmedAt = nil
        previousBelief = nil
        transcriberOn = true
        transcriberSince = now
        nextCheckIn = nil
        note(now, "reacquiring from \(fmt(belief.mediaTime(at: now)))")
        return [.reacquire(hint: belief.mediaTime(at: now), at: now), .startTranscriber]
    }

    private func enterAcquiring(now: Date, hint: Double?) -> [Action] {
        state = .acquiring(audioSeconds: 0)
        acquiringSince = now
        settleHits = 0
        firstConfirmedAt = nil
        previousBelief = nil
        transcriberOn = true
        transcriberSince = nil
        nextCheckIn = nil
        checkInMisses = 0
        verifyStage = 0
        rate.newSegment()
        return [.reacquire(hint: hint, at: now), .startTranscriber]
    }

    // MARK: Probe

    func didProbe(_ result: SyncTracker.ProbeResult, now: Date) -> [Action] {
        let old = state
        stats.probes += 1
        stats.correlations += result.correlations
        guard result.adequate else { return [] }
        if result.hit {
            stats.probeHits += 1
            lastProbeHitAt = now
            probeMisses = 0
            if let r = result.residual, abs(r) >= tuning.probeAlarmResidual { probeResidualAlarms += 1 } else { probeResidualAlarms = 0 }
        } else {
            probeMisses += 1
        }
        var out: [Action] = []
        if (probeMisses >= tuning.probeAlarmCount || probeResidualAlarms >= tuning.probeAlarmCount),
           state == .lockedIn, inFlight == nil {
            note(now, "probe alarm (misses \(probeMisses), |r|≥1 ×\(probeResidualAlarms))")
            probeMisses = 0
            probeResidualAlarms = 0
            stats.probeAlarms += 1
            checkInMisses = 0
            out += issueCheckIn(kind: .probeAlarm, now: now)
        }
        return out + publish(old)
    }

    // MARK: Presence (WP3 PresenceTracker events)

    /// The latch confirmed a pause; `freeze` is the instant to pause at (earliest absent tick − 0.5 s).
    func presenceHeld(at freeze: Date, now: Date) -> [Action] {
        let old = state
        switch state {
        case .lockedIn, .checkingIn, .resuming, .probing, .lost:
            break
        default:
            return []
        }
        cancelInFlight()
        var out: [Action] = []
        if !belief.isPaused {
            belief.pause(at: freeze)
            heldSince = freeze
            out.append(.session(.holdClock(at: freeze, reason: .auto)))
        }
        heldClock = belief
        state = .held(source: .auto, since: heldSince ?? freeze)
        if transcriberOn { transcriberOn = false; out.append(.stopTranscriber) }
        nextCheckIn = nil
        note(now, "held(auto) at \(fmt(belief.mediaTime(at: now)))")
        return out + publish(old)
    }

    /// The latch released. `quickCheck` is WP3's tier-A verdict on hypothesis P (nil = not run → resuming).
    /// Also accepted while already resuming / probing (the sound went away and came back before
    /// anything was accepted): the attempt restarts from the new release instant.
    func presenceReleased(at release: Date, quickCheck: Bool?, now: Date) -> [Action] {
        let old = state
        var out: [Action] = []
        switch state {
        case .held(.auto, _):
            break
        case .resuming, .probing:
            cancelInFlight()
            if !belief.isPaused {
                // Resuming optimistically from P: the sound went away again, so P was wrong or the
                // film paused once more; freeze at the frozen position and probe from here. The
                // display clock was `resume(at: releaseAt)` from that same position, so pausing it
                // at `releaseAt` freezes it there too (reviewer fix: `now` left it ahead by the
                // optimistic stretch until the next accepted check-in).
                belief = heldClock ?? belief
                out.append(.session(.holdClock(at: releaseAt ?? now, reason: .auto)))
            }
        default:
            return []
        }
        selfHeldFromProbing = false
        releaseAt = release
        contentResumedAt = release
        rate.newSegment()
        resumeUserOnly = false
        resumeBehind = tuning.postHoldBehind
        if quickCheck ?? true {
            out += enterResuming(at: release, now: now)
        } else {
            out += enterProbing(now: max(release, now))
        }
        return out + publish(old)
    }

    /// Per presence tick (every 2 ticks): the latest evidence, for the probing rules and miss counting.
    func presenceEvidence(_ e: PresenceEvidence, now: Date) -> [Action] {
        evidence = e
        if case .probing = state {
            if e == .absent { probingAbsentTicks += 1 } else { probingAbsentTicks = 0 }
            if e == .present || e == .hold { probingEvidenceSeconds += Double(tuning.presenceEveryTicks) }
        } else if case .held(.auto, _) = state, selfHeldFromProbing, e == .present {
            // The sound is back after a quiet stretch the scheduler held on its own: probe again
            // from now without waiting for a `released` the presence tracker may never send.
            let old = state
            selfHeldFromProbing = false
            releaseAt = now
            contentResumedAt = now
            let out = enterProbing(now: now, fresh: false)
            note(now, "probing again (sound back)")
            return out + publish(old)
        }
        return []
    }

    /// The kill clock's 2-minute warning (critique §4.2 `ending`). Normally arrives while held;
    /// the never-locked / missed-hold cases arrive from acquiring / lockedIn / lost, where the
    /// display clock is frozen too (`isPaused` is true for `.ending`) and restored by `keepListening`.
    func presenceWarn(endsAt: Date, now: Date) -> [Action] {
        let old = state
        switch state {
        case .ended, .manual, .micLost, .ending: return []
        default: break
        }
        cancelInFlight()
        var out: [Action] = []
        beforeEnding = state
        endingPausedBelief = false
        if !belief.isPaused {
            belief.pause(at: now)
            endingPausedBelief = true
            out.append(.session(.holdClock(at: now, reason: .auto)))
        }
        state = .ending(endsAt: endsAt)
        out.append(.session(.warn(endsAt: endsAt)))
        return out + publish(old)
    }

    /// KeepListeningIntent / present evidence during the warning: back to where the warning
    /// interrupted (held(.auto) after a hold; the running state otherwise, clock resumed).
    func keepListening(now: Date) -> [Action] {
        let old = state
        guard case .ending = state else { return [] }
        var out: [Action] = [.session(.clearWarning)]
        let previous = beforeEnding ?? .held(source: .auto, since: heldSince ?? now)
        beforeEnding = nil
        switch previous {
        case .held:
            state = previous
        case .probing, .idle, .ended, .manual, .micLost, .ending:
            state = .held(source: .auto, since: heldSince ?? now)
        case .checkingIn:
            state = .lockedIn
        default:
            state = previous
        }
        if endingPausedBelief, !state.isPaused, belief.isPaused {
            belief.resume(at: now)
            out.append(.session(.resumeClock(at: now)))
        }
        endingPausedBelief = false
        if state == .lockedIn {
            nextKind = .scheduled
            nextCheckIn = clampedInterval().map { now.addingTimeInterval($0) }
        }
        return out + publish(old)
    }

    func presenceEnd(_ reason: EndReason, now: Date) -> [Action] {
        let old = state
        state = .ended(reason: reason)
        cancelInFlight()
        nextCheckIn = nil
        return [.session(.endSession(reason))] + publish(old)
    }

    private func enterResuming(at release: Date, now: Date) -> [Action] {
        selfHeldFromProbing = false
        belief.resume(at: release)
        resumeAttempts = 0
        resumeNextAt = release.addingTimeInterval(tuning.resumeMinAudioSeconds)
        state = .resuming(since: release, attempt: 0)
        note(now, "resuming from \(fmt(belief.mediaTime(at: release)))")
        return [.session(.resumeClock(at: release))]
    }

    /// `fresh` = a new episode (after a release); false keeps the attempt count and the 30 s
    /// evidence budget across a quiet-again / sound-back bounce inside one episode.
    private func enterProbing(now: Date, fresh: Bool = true) -> [Action] {
        var out: [Action] = []
        if !belief.isPaused {
            belief.pause(at: now)
            out.append(.session(.holdClock(at: now, reason: .auto)))
        }
        if releaseAt == nil { releaseAt = now }
        if fresh {
            probingAttempts = 0
            probingEvidenceSeconds = 0
        }
        // The first probing check-in needs `trackMinWindowSeconds` of post-release audio.
        probingNextAt = max(now.addingTimeInterval(tuning.resumeAttemptStepSeconds),
                            (releaseAt ?? now).addingTimeInterval(tuning.trackMinWindowSeconds))
        probingAbsentTicks = 0
        state = .probing(since: now)
        note(now, "probing")
        return out
    }

    // MARK: Memory (WP4)

    /// A signature confirmation while locked-in: counts as a good point (rescues an inconclusive window).
    func memoryConfirmed(media: Double, at wall: Date, now: Date) -> [Action] {
        guard state == .lockedIn else { return [] }
        lastGoodAt = now
        rate.add(t: wall, media: media)
        return []
    }

    // MARK: User

    func userPause(now: Date) -> [Action] {
        let old = state
        switch state {
        case .idle, .ended, .manual, .micLost, .held(.user, _), .acquiring, .reacquiring:
            return []
        default:
            break
        }
        cancelInFlight()
        var out: [Action] = []
        if !belief.isPaused {
            belief.pause(at: now)
            heldSince = now
            out.append(.session(.holdClock(at: now, reason: .user)))
        }
        heldClock = belief
        state = .held(source: .user, since: heldSince ?? now)
        if transcriberOn { transcriberOn = false; out.append(.stopTranscriber) }
        nextCheckIn = nil
        return out + publish(old)
    }

    /// Island Play / ResumeIntent: hypothesis A only, tier R with behind = held duration + 5 s,
    /// large deltas allowed immediately (critique C3 / C5).
    func userResume(now: Date) -> [Action] {
        let old = state
        guard case .held(let source, let since) = state else { return [] }
        releaseAt = now
        contentResumedAt = now
        rate.newSegment()
        resumeUserOnly = true
        resumeBehind = max(tuning.postHoldBehind, now.timeIntervalSince(since) + tuning.resumeBehindMargin)
        _ = source
        return enterResuming(at: now, now: now) + publish(old)
    }

    /// A trim nudge: arms the nudge guard; a burst > 1 s within 10 s forces a check-in.
    func userNudged(seconds: Double, now: Date) -> [Action] {
        let old = state
        lastNudgeAt = now
        nudges.append((now, seconds))
        nudges.removeAll { now.timeIntervalSince($0.at) > 10 }
        let burst = abs(nudges.reduce(0) { $0 + $1.seconds })
        var out: [Action] = []
        if burst > tuning.nudgeGuardBelow, state == .lockedIn, inFlight == nil {
            nudges = []
            checkInMisses = 0
            out += issueCheckIn(kind: .nudge, now: now)
        }
        return out + publish(old)
    }

    /// "Tap the line" / "Set position" / jump / seek / relaunch seed: the engine has already seeded
    /// the tracker; the scheduler goes straight to `lockedIn` with the first check-in at +15 s.
    func userSeeded(media: Double, rate seededRate: Double?, now: Date) -> [Action] {
        let old = state
        var out: [Action] = []
        belief = PlaybackClock(media: media, at: now, rate: seededRate ?? rate.rate, paused: false)
        rate.newSegment()
        if let r = seededRate { rate.set(rate: r, confirmed: false) }
        lastGoodAt = now
        cancelInFlight()
        checkInMisses = 0
        verifyStage = 0
        guard policy.lockedIn else {
            if case .idle = state { state = .acquiring(audioSeconds: 0); acquiringSince = now }
            return out + publish(old)
        }
        interval = tuning.adaptiveStartSeconds
        if transcriberOn { transcriberOn = false; out.append(.stopTranscriber) }
        state = .lockedIn
        lastProbeAt = now
        nextKind = .scheduled
        nextCheckIn = now.addingTimeInterval(tuning.seedFirstCheckInSeconds)
        return out + publish(old)
    }

    /// Island Re-sync: locked → wide pass (T1 ±45 s, T2 ±5 min) then full; twice in 10 s → full.
    func userResync(now: Date) -> [Action] {
        let old = state
        var out: [Action] = []
        let doubleTap = lastResyncAt.map { now.timeIntervalSince($0) < tuning.resyncDoubleTapSeconds } ?? false
        lastResyncAt = now
        cancelInFlight()
        if doubleTap || !policy.lockedIn {
            out += enterAcquiring(now: now, hint: nil)
            return out + publish(old)
        }
        switch state {
        case .lockedIn, .checkingIn, .lost:
            if belief.isPaused { belief.resume(at: now) }
            checkInMisses = 0
            out += issueCheckIn(kind: .resync, now: now)
            state = .checkingIn(attempt: 1)
        case .held, .resuming, .probing, .ending:
            if belief.isPaused { belief.resume(at: now); out.append(.session(.resumeClock(at: now))) }
            out += enterAcquiring(now: now, hint: nil)
        default:
            out += enterAcquiring(now: now, hint: nil)
        }
        return out + publish(old)
    }

    /// `autoSync` off → manual (engine stopped; the user drives).
    func userManual(now: Date) -> [Action] {
        let old = state
        state = .manual
        cancelInFlight()
        nextCheckIn = nil
        return publish(old)
    }

    // MARK: Mic

    func micLost(now: Date) -> [Action] {
        let old = state
        switch state {
        case .idle, .ended, .manual, .micLost: return []
        default: break
        }
        micLostAt = now
        cancelInFlight()
        state = .micLost
        return publish(old)
    }

    /// Capture is back: a forced check-in with behind = gap + 5 s when a position is known, else acquiring.
    func micRecovered(now: Date) -> [Action] {
        let old = state
        guard state == .micLost else { return [] }
        var out: [Action] = []
        if lastGoodAt != nil, policy.lockedIn {
            state = .lockedIn
            if belief.isPaused { belief.resume(at: micLostAt ?? now) }
            checkInMisses = 0
            out += issueCheckIn(kind: .forced, now: now)
        } else {
            out += enterAcquiring(now: now, hint: nil)
        }
        return out + publish(old)
    }

    // MARK: Helpers

    /// Correlations a V1 `analyse` report cost: 1 for a track/drift pass, one per search rate for
    /// a full / hinted search (accepted or not), 0 when it returned before correlating.
    static func correlations(in note: String, rates: Int) -> Int {
        if note.hasPrefix("tracking") || note.hasPrefix("missed") { return 1 }
        if note.hasPrefix("full search") || note.hasPrefix("hinted search") || note.hasPrefix("candidate") { return rates }
        return 0
    }

    private func publish(_ old: State) -> [Action] {
        guard old != state else { return [] }
        if case .acquiring = old, case .acquiring = state, old.phase(minAudio: tuning.minWindowSeconds) == state.phase(minAudio: tuning.minWindowSeconds) {
            return []
        }
        return [.session(.status(state))]
    }

    private func note(_ now: Date, _ text: String) {
        log.append(text)
        if debug { print("    sched \(text)") }
    }

    private func fmt(_ v: Double, _ digits: Int = 2) -> String { String(format: "%.\(digits)f", v) }
}
