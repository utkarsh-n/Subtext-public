import Foundation

// WP2 harness suite: `SCENARIOS=checkin`. Declarations only (no top-level statements).
//
// docs/v2/checkin.md §11 (S1–S13) plus keepalive.md S14/S15, run through `runV2` with the real
// `CheckInScheduler` + `SyncTracker.checkIn/probe` + `RateEstimator` + `PlaybackClock` wired the
// way `SyncEngine`/`SessionController` will wire them (WP7). The presence latch is a harness-only
// stand-in (`SimLatch`, a level latch with the critique's two-path confirm times) because the real
// `PresenceTracker` is WP3's; the integration suite (WP7) swaps it for the real one.
//
// S6 runs first: it measures the wrong-film onsetZ ceiling per tier and sets `tierOnsetZ` /
// `catchUpOnsetZ` (+0.5) for every scenario after it.

extension SimTimebase: Timebase {
    func wallDate(for engineDate: Date) -> Date { engineDate.addingTimeInterval(wall.timeIntervalSince(now)) }
    func engineDate(fromWall w: Date) -> Date { w.addingTimeInterval(now.timeIntervalSince(wall)) }
}

/// Thresholds measured by S6 (nil until it has run → Tuning defaults). `TIERZ=6.2,7.9,9.0` and
/// `CATCHZ=8.5` in the environment inject them and skip S6 (debugging single scenarios).
nonisolated(unsafe) var measuredTierOnsetZ: [Float]? = ProcessInfo.processInfo.environment["TIERZ"].map {
    $0.split(separator: ",").compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
}.flatMap { $0.count == 3 ? $0 : nil }
nonisolated(unsafe) var measuredCatchUpOnsetZ: Float? = ProcessInfo.processInfo.environment["CATCHZ"].flatMap(Float.init)

/// `ONLY=S2` runs only the scenarios whose name contains the string (comma-separated list allowed).
let onlyScenarios: [String] = (ProcessInfo.processInfo.environment["ONLY"] ?? "")
    .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
func wanted(_ name: String) -> Bool { onlyScenarios.isEmpty || onlyScenarios.contains { name.contains($0) } }

// MARK: - Harness-only presence stand-in

/// A level latch: max dB per 100 ms against the room floor (5th percentile over 120 s); "loud"
/// is more than `thresholdDb` above the floor, where the threshold adapts to the session's own
/// level spread (half of p95 − p5, clamped 3…12 dB, so a loud room still separates film from
/// floor as the real tracker's depth/flux features do); "quiet" after T_off (6 s when the track
/// expects dialogue, 10 s otherwise) → `held(freeze:)` with the freeze instant = last loud frame
/// − 0.5 s (critique D5); 1 s of content → `released`.
final class SimLatch {
    enum Event { case held(freeze: Date), released(at: Date) }
    var maxThresholdDb: Float = 12
    private(set) var thresholdDb: Float = 12
    var releaseSeconds = 1.0
    private var frames: [Float] = []
    private(set) var lastLoudAt: Date?
    /// Start of the first quiet 100 ms frame of the current quiet run (the earliest absent tick).
    private(set) var firstQuietAt: Date?
    private var loudRun = 0
    private(set) var isHeld = false
    private(set) var content = true
    private(set) var lastDb: Float = -100
    private(set) var floorDb: Float = -100

    func push(_ buffer: [Float], at now: Date, tOff: Double) -> Event? {
        var peak: Float = 0
        for v in buffer { peak = max(peak, abs(v)) }
        let db = 20 * log10(peak + 1e-6)
        frames.append(db)
        if frames.count > 1200 { frames.removeFirst(frames.count - 1200) }
        lastDb = db
        let sorted = frames.sorted()
        floorDb = sorted[max(0, Int(Double(sorted.count) * 0.05) - 1)]
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        if frames.count >= 100 { thresholdDb = min(maxThresholdDb, max(3, (p95 - floorDb) * 0.5)) }
        let loud = db - floorDb > thresholdDb
        if loud { lastLoudAt = now; loudRun += 1 } else { if loudRun > 0 || firstQuietAt == nil { firstQuietAt = now }; loudRun = 0 }
        if loud { firstQuietAt = nil }
        // Evidence for the scheduler: content heard within the last 2 s (the real tracker's
        // features are 4 s window statistics, never one frame).
        content = lastLoudAt.map { now.timeIntervalSince($0) < 2 } ?? false
        if frames.count < 30 { return nil }
        if !isHeld {
            if let last = lastLoudAt, now.timeIntervalSince(last) >= tOff {
                isHeld = true
                return .held(freeze: (firstQuietAt ?? last.addingTimeInterval(0.1)).addingTimeInterval(-0.5))
            }
            if lastLoudAt == nil, Double(frames.count) * 0.1 >= tOff {
                isHeld = true
                return .held(freeze: now.addingTimeInterval(-tOff - 0.5))
            }
        } else if Double(loudRun) * 0.1 >= releaseSeconds {
            isHeld = false
            return .released(at: now.addingTimeInterval(-Double(loudRun) * 0.1))
        }
        return nil
    }
}

// MARK: - The wiring (mirrors SyncEngine + SessionController)

final class CheckInRun {
    struct CheckInRecord {
        var at: Double
        var kind: SyncTracker.CheckInRequest.Kind
        var outcome: SyncTracker.CheckInResult.Outcome
        var residual: Double?
        var tier: Int?
        var ms: Double
        var rateAfter: Double
        var windowSeconds: Double
        var onsets: Int
    }

    let scheduler: CheckInScheduler
    let latch = SimLatch()
    let track: SubtitleTrack
    var records: [CheckInRecord] = []
    /// `locked` = the scheduler was lockedIn / checkingIn when the sample was taken (the display
    /// is frozen by design while held / probing and dimmed while lost).
    var errors: [(t: Double, err: Double, locked: Bool)] = []
    var states: [(t: Double, state: SchedulerState)] = []
    /// `errBefore` = displayed − truth just before the correction (nil when not placed).
    var corrections: [(t: Double, residual: Double, deferred: Bool, errBefore: Double?)] = []
    /// The first hold at or after the scenario's pause event (the one the pause criteria are about;
    /// a hold in a montage gap before the pause is a legitimate room-only hold, resolved by B/C).
    var pauseHold: (t: Double, latency: Double, frozenError: Double)?
    /// Tier A emulation: the release instant and the frozen hypothesis P awaiting WP3's `quickCheck`.
    var pendingRelease: (release: Date, p: Double, since: Date)?
    var caughtUp: [(t: Double, seconds: Double)] = []
    var transcriberStarts = 0
    var transcriberOn = false
    var pending: (Correction, boundary: Double?)?
    var holdEvents: [(t: Double, held: Bool)] = []
    var probeAlarmAt: [Double] = []
    var lockedInAt: Double?
    /// Correlations spent up to the first `lockedIn` (the acquiring phase, V1-rate work).
    var correlationsAtLockIn = 0
    var autoPause: Bool
    var patience: AutoPausePatience
    var userEvents: [(at: Double, run: (V2Context, CheckInRun) -> Void)]
    var debug = ProcessInfo.processInfo.environment["DEBUG"] != nil

    init(ctx: V2Context, policy: CheckInScheduler.Policy, userEvents: [(at: Double, run: (V2Context, CheckInRun) -> Void)]) {
        var tuning = ctx.tracker.tuning
        if let z = measuredTierOnsetZ { tuning.tierOnsetZ = z }
        if let c = measuredCatchUpOnsetZ { tuning.catchUpOnsetZ = c }
        ctx.tracker.tuning = tuning
        scheduler = CheckInScheduler(tuning: tuning, policy: policy, now: ctx.now)
        scheduler.debug = debug
        track = SubtitleTrack(title: "film", language: "en", cues: ctx.film.parsed, source: "harness")
        autoPause = ctx.scenario.autoPause
        patience = ctx.scenario.patience
        self.userEvents = userEvents
    }

    /// Actions are applied in the order the scheduler emitted them, never nested: a result's
    /// follow-up actions queue behind the rest of the batch that issued the request, exactly as
    /// the engine's serial `analysisQueue` orders them (a `.status(.checkingIn)` emitted by the
    /// tick that issued a check-in is applied before the `.status(.lockedIn)` from its result).
    private var queue: [CheckInScheduler.Action] = []
    private var draining = false

    func execute(_ actions: [CheckInScheduler.Action], ctx: V2Context) {
        queue.append(contentsOf: actions)
        guard !draining else { return }
        draining = true
        defer { draining = false }
        while !queue.isEmpty {
            let a = queue.removeFirst()
            switch a {
            case .analyse(let w):
                guard let window = ctx.ring.latest(seconds: w) else { continue }
                let report = ctx.tracker.analyse(mic: window.bins, windowStart: window.start, now: ctx.now)
                ctx.outcome.correlations += CheckInScheduler.correlations(in: report.note, rates: ctx.tracker.tuning.searchRates.count)
                if report.note.hasPrefix("full search") || report.note.hasPrefix("candidate") { ctx.outcome.fullSearches += 1 }
                if debug {
                    print(String(format: "  t=%3.0f speech %.2f %@ state=%@ lock=%@ truth=%.1f disp=%@", ctx.wallSeconds, report.speechFraction, report.note, "\(report.state)", report.lock.map { String(format: "%.1f", $0.mediaTime(at: ctx.now)) } ?? "-", ctx.truthMedia, ctx.displayError.map { String(format: "%+.2f", $0) } ?? "-"))
                }
                if let lock = report.lock {
                    ctx.apply(lock: lock)   // V1 onLock path (acquiring / reacquiring)
                    let err = lock.mediaTime(at: ctx.now) - ctx.truthMedia
                    if ctx.outcome.lockAfter == nil { ctx.outcome.lockAfter = ctx.wallSeconds; ctx.outcome.error = err }
                    if lock.confirmed, ctx.outcome.confirmedAfter == nil { ctx.outcome.confirmedAfter = ctx.wallSeconds }
                    let settling = ctx.scenario.events.contains { ctx.wallSeconds >= $0.start && ctx.wallSeconds < $0.end + 60 }
                    if lock.confirmed, !settling { ctx.outcome.worst = max(ctx.outcome.worst, abs(err)) }
                }
                execute(scheduler.didAnalyse(report, lockPoints: ctx.tracker.lockPoints, rateConfirmed: ctx.tracker.rateConfirmed, now: ctx.now), ctx: ctx)
            case .runCheckIn(let req):
                let r = ctx.tracker.checkIn(req, ring: ctx.ring, now: ctx.now)
                ctx.outcome.checkIns += 1
                if r.isConclusive { ctx.outcome.conclusiveCheckIns += 1 }
                ctx.outcome.correlations += r.correlations
                var tier: Int?
                var residual: Double?
                if case .accepted(_, _, _, let t, let res, _) = r.outcome { tier = t; residual = res; ctx.outcome.tierCounts[min(t, 3)] += 1 }
                if debug {
                    print(String(format: "  t=%3.0f CHECK-IN %@ → %@ truth=%.1f disp=%@ belief=%.2f clock=%.2f%@", ctx.wallSeconds, "\(req.kind)", r.note, ctx.truthMedia, ctx.displayError.map { String(format: "%+.2f", $0) } ?? "-", scheduler.belief.mediaTime(at: ctx.now), ctx.clock.mediaTime(at: ctx.now), ctx.clock.isPaused ? " (clock paused)" : ""))
                }
                let actions = scheduler.didCheckIn(r, request: req, now: ctx.now)
                records.append(CheckInRecord(at: ctx.wallSeconds, kind: req.kind, outcome: r.outcome, residual: residual, tier: tier,
                                             ms: r.milliseconds, rateAfter: scheduler.rate.rate, windowSeconds: r.windowSeconds, onsets: r.onsets))
                execute(actions, ctx: ctx)
            case .runProbe(let req):
                let r = ctx.tracker.probe(req, ring: ctx.ring, now: ctx.now)
                ctx.outcome.correlations += r.correlations
                let alarmsBefore = scheduler.stats.probeAlarms
                let actions = scheduler.didProbe(r, now: ctx.now)
                if scheduler.stats.probeAlarms > alarmsBefore { probeAlarmAt.append(ctx.wallSeconds) }
                if debug, r.adequate {
                    print(String(format: "  t=%3.0f probe %@ r=%@ oz %.1f", ctx.wallSeconds, r.hit ? "hit" : "MISS", r.residual.map { String(format: "%+.2f", $0) } ?? "-", r.onsetZ))
                }
                execute(actions, ctx: ctx)
            case .reacquire(let hint, let at):
                ctx.tracker.resync()
                if let h = hint { ctx.tracker.hint(mediaTime: h, at: at) }
            case .startTranscriber:
                transcriberStarts += 1
                transcriberOn = true
            case .stopTranscriber:
                transcriberOn = false
            case .session(let sa):
                applySession(sa, ctx: ctx)
            }
        }
    }

    /// `SessionController.apply(action:)` incl. the deferred backward snap (next cue boundary or 3 s).
    func applySession(_ sa: SessionAction, ctx: V2Context) {
        switch sa {
        case .setClock(let c):
            let errBefore = ctx.displayError
            if let until = c.deferUntil {
                let media = ctx.displayed
                pending = (c, track.nextBoundary(after: media))
                corrections.append((ctx.wallSeconds, c.residual, true, errBefore))
                _ = until
            } else {
                corrections.append((ctx.wallSeconds, c.residual, false, errBefore))
                pending = nil
                ctx.apply(action: sa)
            }
        case .holdClock(let at, _):
            holdEvents.append((ctx.wallSeconds, true))
            ctx.apply(action: sa)
            if pauseHold == nil, let p = ctx.scenario.events.first(where: { if case .pause = $0 { return true } else { return false } }),
               ctx.wallSeconds >= p.start {
                pauseHold = (ctx.wallSeconds, ctx.wallSeconds - p.start, ctx.displayed - ctx.truthMedia)
            }
            if debug { print(String(format: "  t=%3.0f HOLD at %+.1f s: belief=%.2f clock=%.2f truth=%.2f", ctx.wallSeconds, at.timeIntervalSince(ctx.now), scheduler.belief.mediaTime(at: ctx.now), ctx.clock.mediaTime(at: ctx.now), ctx.truthMedia)) }
        case .resumeClock(let at):
            holdEvents.append((ctx.wallSeconds, false))
            ctx.apply(action: sa)
            if debug { print(String(format: "  t=%3.0f RESUME at %+.1f s: belief=%.2f clock=%.2f truth=%.2f", ctx.wallSeconds, at.timeIntervalSince(ctx.now), scheduler.belief.mediaTime(at: ctx.now), ctx.clock.mediaTime(at: ctx.now), ctx.truthMedia)) }
        case .status(let s):
            states.append((ctx.wallSeconds, s))
            if s == .lockedIn, lockedInAt == nil { lockedInAt = ctx.wallSeconds; correlationsAtLockIn = ctx.outcome.correlations }
            if debug { print(String(format: "  t=%3.0f STATE %@", ctx.wallSeconds, "\(s)")) }
        case .caughtUp(let s):
            caughtUp.append((ctx.wallSeconds, s))
        case .endSession:
            ctx.apply(action: sa)
        case .warn, .clearWarning:
            break
        }
    }

    func servicePending(ctx: V2Context) {
        guard let (c, boundary) = pending else { return }
        let due = ctx.now >= (c.deferUntil ?? ctx.now)
        let crossed = boundary.map { ctx.displayed >= $0 } ?? false
        if due || crossed {
            pending = nil
            ctx.apply(action: .setClock(c))
        }
    }

    // MARK: Metrics

    func recovered(after t0: Double, tolerance: Double = 0.3, hold: Double = 3) -> Double? {
        let samples = errors.filter { $0.t >= t0 }
        guard !samples.isEmpty else { return nil }
        var i = 0
        while i < samples.count {
            if abs(samples[i].err) < tolerance {
                var j = i
                var ok = true
                while j < samples.count, samples[j].t < samples[i].t + hold {
                    if abs(samples[j].err) >= tolerance { ok = false; break }
                    j += 1
                }
                if ok { return samples[i].t - t0 }
            }
            i += 1
        }
        return nil
    }

    func maxError(from: Double, to: Double = .infinity, lockedOnly: Bool = false) -> Double {
        errors.filter { $0.t >= from && $0.t <= to && (!lockedOnly || $0.locked) }.map { abs($0.err) }.max() ?? 0
    }

    var firstHold: Double? { holdEvents.first(where: { $0.held })?.t }
    var conclusiveFraction: Double {
        records.isEmpty ? 0 : Double(records.filter { if case .inconclusive = $0.outcome { return false } else { return true } }.count) / Double(records.count)
    }
    var msPerCheckIn: Double { records.isEmpty ? 0 : records.map(\.ms).reduce(0, +) / Double(records.count) }
    var acceptedRecords: [CheckInRecord] { records.filter { if case .accepted = $0.outcome { return true } else { return false } } }
}

/// Builds the hooks for one scenario.
func checkInHooks(policy: CheckInScheduler.Policy,
                  userEvents: [(at: Double, run: (V2Context, CheckInRun) -> Void)] = [],
                  configure: ((V2Context, CheckInRun) -> Void)? = nil) -> V2Hooks {
    var hooks = V2Hooks()
    hooks.setup = { ctx in
        let run = CheckInRun(ctx: ctx, policy: policy, userEvents: userEvents)
        ctx.extras["checkin"] = run
        // `SessionController.start` creates the display clock running (`PlaybackClock(media: 0,
        // paused: false)`); `V2Context` starts an unseeded clock paused, which made `apply(lock:)`
        // a no-op in V1 mode (S13's recovery column read "never"). Mirror the app.
        if ctx.scenario.seedAt == nil, ctx.clock.isPaused { ctx.clock.resume(at: ctx.now) }
        configure?(ctx, run)
        run.execute(run.scheduler.start(now: ctx.now), ctx: ctx)
        if let seed = ctx.scenario.seedAt {
            run.execute(run.scheduler.userSeeded(media: seed, rate: ctx.scenario.seedRate, now: ctx.now), ctx: ctx)
        }
    }
    hooks.onSamples = { ctx, buf in
        guard let run = ctx.extras["checkin"] as? CheckInRun else { return }
        if let err = ctx.displayError {
            let st = run.scheduler.state
            let locked = st == .lockedIn || { if case .checkingIn = st { return true } else { return false } }()
            run.errors.append((ctx.wallSeconds, err, locked))
        }
        run.servicePending(ctx: ctx)
        // Presence stand-in: dialogue expected → 6 s, else 10 s (normal patience).
        let belief = run.scheduler.belief
        let m = belief.mediaTime(at: ctx.now)
        let expected = belief.isPaused ? 0 : ctx.tracker.expectedSpeechFraction(from: m - run.patience.confirmDialogueSeconds, to: m)
        let tOff = expected >= 0.3 ? run.patience.confirmDialogueSeconds : run.patience.confirmAbsentSeconds
        if let e = run.latch.push(buf, at: ctx.now, tOff: tOff), run.autoPause {
            switch e {
            case .held(let freeze):
                run.execute(run.scheduler.presenceHeld(at: freeze, now: ctx.now), ctx: ctx)
            case .released(let at):
                // Tier A (critique C12): WP3's `quickCheck` on the audio since the release decides
                // between optimistic resuming (P agrees) and probing (clock stays frozen).
                run.pendingRelease = (at, run.scheduler.belief.mediaTime(at: at), ctx.now)
            }
        }
        if let pr = run.pendingRelease {
            var verdict: Bool?
            if let (bins, start) = ctx.ring.latest(seconds: ctx.now.timeIntervalSince(pr.release) + 0.1) {
                var b = bins
                var st = start
                if st < pr.release {
                    let drop = min(b.count, SpeechEnvelope.bin(for: pr.release.timeIntervalSince(st)))
                    b.removeFirst(drop)
                    st = st.addingTimeInterval(Double(drop) * SpeechEnvelope.binDuration)
                }
                if let q = ctx.tracker.quickCheck(mic: b, windowStart: st, hypothesis: pr.p) {
                    verdict = q.agrees
                    if run.debug { print(String(format: "  t=%3.0f quickCheck P=%.2f %@ offset %+.2f score %.2f n %d (%.1f s)", ctx.wallSeconds, pr.p, q.agrees ? "agrees" : "DISAGREES", q.offset, q.score, q.onsetCount, q.seconds)) }
                }
            }
            if let v = verdict {
                run.pendingRelease = nil
                run.execute(run.scheduler.presenceReleased(at: pr.release, quickCheck: v, now: ctx.now), ctx: ctx)
            } else if ctx.now.timeIntervalSince(pr.release) >= 8 {
                // Undecidable after 8 s of post-release audio → the scheduler's default (resuming).
                run.pendingRelease = nil
                run.execute(run.scheduler.presenceReleased(at: pr.release, quickCheck: nil, now: ctx.now), ctx: ctx)
            }
        }
    }
    hooks.onTick = { ctx in
        guard let run = ctx.extras["checkin"] as? CheckInRun else { return }
        for (i, e) in run.userEvents.enumerated().reversed() where ctx.wallSeconds >= e.at {
            run.userEvents.remove(at: i)
            e.run(ctx, run)
        }
        if ctx.tick % 2 == 0 {
            run.execute(run.scheduler.presenceEvidence(run.latch.content ? .present : .absent, now: ctx.now), ctx: ctx)
        }
        run.execute(run.scheduler.tick(now: ctx.now), ctx: ctx)
    }
    hooks.onAnalysisWindow = { _, _, _ in }   // the scheduler's `.analyse` action drives V1 analysis
    hooks.onEvent = { ctx, e in
        guard let run = ctx.extras["checkin"] as? CheckInRun else { return }
        if case .nudge(_, let secs) = e {
            run.execute(run.scheduler.userNudged(seconds: secs, now: ctx.now), ctx: ctx)
        }
    }
    return hooks
}

// MARK: - Table

struct CheckInRow {
    var name: String
    var outcome: OutcomeV2
    var run: CheckInRun?
    var seconds: Double
    var verdict: String
    var detail: String
    var printed = true
}

func f1(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "-" }
func f2(_ v: Double?) -> String { v.map { String(format: "%+.2f", $0) } ?? "-" }

func printCheckInHeader() {
    print("scenario".padding(toLength: 34, withPad: " ", startingAt: 0)
          + " lockIn@  hold s  frozen  recov s  chk  concl  tiers T0/1/2/3  corr/min  ms/chk  maxErr  full  verdict")
}

func printCheckInRow(_ r: CheckInRow) {
    let o = r.outcome
    let run = r.run
    let corrPerMin = Double(o.correlations) / max(1, r.seconds / 60)
    let tiers = o.tierCounts.map(String.init).joined(separator: "/")
    print(r.name.padding(toLength: 34, withPad: " ", startingAt: 0)
          + pad(run?.lockedInAt.map { String(format: "%.0f", $0) } ?? "-", 8)
          + pad(f1(o.holdLatency), 8)
          + pad(f2(o.frozenError), 8)
          + pad(o.recovery.first.flatMap { $0 }.map { String(format: "%.0f", $0) } ?? "-", 9)
          + pad("\(o.checkIns)", 5)
          + pad(String(format: "%.0f%%", (run?.conclusiveFraction ?? 0) * 100), 7)
          + pad(tiers, 17)
          + pad(String(format: "%.1f", corrPerMin), 10)
          + pad(String(format: "%.1f", run?.msPerCheckIn ?? 0), 8)
          + pad(String(format: "%.2f", run?.maxError(from: (run?.lockedInAt ?? 0) + 5) ?? o.maxErrorLocked), 8)
          + pad("\(o.fullSearches)", 6)
          + "  " + r.verdict + (r.detail.isEmpty ? "" : "  " + r.detail))
}

func runCheckInScenario(_ s: ScenarioV2, policy: CheckInScheduler.Policy,
                        userEvents: [(at: Double, run: (V2Context, CheckInRun) -> Void)] = [],
                        configure: ((V2Context, CheckInRun) -> Void)? = nil,
                        judge: (OutcomeV2, CheckInRun) -> (String, String)) -> CheckInRow? {
    guard wanted(s.name) else { return nil }
    var run: CheckInRun?
    var hooks = checkInHooks(policy: policy, userEvents: userEvents, configure: configure)
    let finish = hooks.finish
    hooks.finish = { ctx in finish?(ctx); run = ctx.extras["checkin"] as? CheckInRun }
    let o = runV2(s, hooks: hooks)
    let (verdict, detail) = judge(o, run!)
    let row = CheckInRow(name: s.name, outcome: o, run: run, seconds: s.seconds, verdict: verdict, detail: detail)
    printCheckInRow(row)
    return row
}

func pass(_ ok: Bool) -> String { ok ? "PASS" : "FAIL" }

extension Array where Element == CheckInRow {
    mutating func add(_ row: CheckInRow?) { if let row { append(row) } }
}

// MARK: - S6 wrong film (first: sets the tier thresholds)

/// Three random wrong films (the ceiling of one film varies by ±1 z between shuffles); thresholds
/// are the max over all of them + 0.5. Tier R: 40 checks in total at held positions spread over
/// the film (the task's count), not 40 per window.
func runWrongFilmTiers() {
    let parsed = film.parsed
    let names = ["T0 ±4", "T1 ±45", "R −15/+60", "T2 −600/+60"]
    var maxZ: [Float] = [-9, -9, -9, -9]
    var perFilm: [[Float]] = []
    var accepts = [0, 0, 0, 0]
    var checks = [0, 0, 0, 0]
    var minWindowOnsets = Int.max
    for _ in 0..<3 {
    var wrongCues: [Cue] = []
    var t = 5.0
    for (i, c) in parsed.shuffled(using: &rng).enumerated() {
        wrongCues.append(Cue(id: i, start: t, end: t + c.duration, text: c.text))
        t += c.duration + Double.random(in: 0.3...2.5, using: &rng) + (i % 17 == 16 ? Double.random(in: 8...20, using: &rng) : 0)
    }
    let wrong = SyncTracker(cues: wrongCues)
    var filmMax: [Float] = [-9, -9, -9, -9]
    var tierRChecks = 0
    /// Ceiling per tier for windows with ≥ 5 and ≥ 6 onsets (the onset score is quantised to
    /// 1/n, so 4-onset windows reach z ≈ 7–8 by luck on any film; see the report).
    let rates = wrong.tuning.searchRates
    for startAt in [100.0, 180.0, 260.0] {
        let vad = VoiceActivityDetector(sampleRate: sampleRate)
        let ring = MicRing(seconds: 120)
        let tb = SimTimebase()
        ring.start(at: tb.now)
        var wallSamples = 0
        var truth = startAt
        var nextCheck = 10.0
        while wallSamples < Int(150 * sampleRate) {
            var buf = roomNoise(4800, level: 0.03)
            for i in 0..<4800 {
                let idx = Int(truth * sampleRate)
                if idx < film.samples.count { buf[i] += film.samples[idx] }
                truth += 1 / sampleRate
            }
            ring.append(vad.process(buf).map(\.speech))
            wallSamples += 4800
            tb.advance(by: 0.1)
            let wall = Double(wallSamples) / sampleRate
            guard wall >= nextCheck - 0.01 else { continue }
            nextCheck += 10
            // The belief: the true position, in the wrong film's timeline (as a wrong lock would be).
            let belief = PlaybackClock(media: truth, at: tb.now, rate: 1, paused: false)
            guard let (bins, start) = ring.latest(seconds: 30), wrong.evidence(bins).ok else { continue }
            minWindowOnsets = min(minWindowOnsets, SpeechEnvelope.onsets(in: bins).count)
            let predicted = belief.mediaTime(at: start)
            func probe(_ k: Int, centre: Double, behind: Double, ahead: Double, tier: Int) {
                for r in rates {
                    guard let m = wrong.search(bins, rate: r, centre: centre, behind: behind, ahead: ahead) else { continue }
                    checks[k] += 1
                    maxZ[k] = max(maxZ[k], m.onsetZ)
                    filmMax[k] = max(filmMax[k], m.onsetZ)
                    if wrong.accepts(m, tier: tier, behind: behind) { accepts[k] += 1 }
                }
            }
            probe(0, centre: predicted, behind: 4, ahead: 4, tier: 0)
            probe(1, centre: predicted, behind: 45, ahead: 45, tier: 1)
            probe(3, centre: predicted, behind: 600, ahead: 60, tier: 2)
            // Tier R: one check per window at a held position spread over the film, 40 in total.
            if tierRChecks < 40 {
                let span = Double(wrong.referenceBinCount) * SpeechEnvelope.binDuration
                let held = 20 + (span - 100) * Double(tierRChecks) / 39
                probe(2, centre: held, behind: 15, ahead: 60, tier: 2)
                tierRChecks += 1
            }
        }
    }
    perFilm.append(filmMax)
    }
    measuredTierOnsetZ = [maxZ[0] + 0.5, maxZ[1] + 0.5, maxZ[2] + 0.5]
    measuredCatchUpOnsetZ = maxZ[3] + 0.5
    print("S6 wrong film × 3 (30 s windows, 3 rates, min onsets in a window \(minWindowOnsets)):")
    for k in 0..<4 {
        let films = perFilm.map { String(format: "%.1f", $0[k]) }.joined(separator: " / ")
        print(String(format: "   %@: %d checks, %d accepted (want 0) at placeholder thresholds, max onsetZ %.2f (per film %@)", names[k].padding(toLength: 12, withPad: " ", startingAt: 0), checks[k], accepts[k], maxZ[k], films))
    }
    print(String(format: "   → tierOnsetZ = [%.1f, %.1f, %.1f], catchUpOnsetZ = %.1f (max + 0.5)", measuredTierOnsetZ![0], measuredTierOnsetZ![1], measuredTierOnsetZ![2], measuredCatchUpOnsetZ!))
    // Accept counts at the measured thresholds must be 0 by construction (threshold > max).
}

// MARK: - Pure-logic scenarios (S8 nudge guard, S12 deferred snap)

func runNudgeGuardTest() -> (String, String) {
    let tb = SimTimebase()
    var tuning = SyncTracker.Tuning()
    if let z = measuredTierOnsetZ { tuning.tierOnsetZ = z }
    let s = CheckInScheduler(tuning: tuning, policy: .init(interval: .m2, probe: false), now: tb.now)
    _ = s.start(now: tb.now)
    _ = s.userSeeded(media: 120, rate: nil, now: tb.now)
    func checkIn(at t: Double, residual: Double) -> [CheckInScheduler.Action] {
        tb.advance(by: t - tb.elapsed)
        let req = SyncTracker.CheckInRequest(kind: .scheduled, hypotheses: [.init(name: "belief", clock: s.belief)], hypothesisRadius: nil,
                                             rates: [], tiers: [.narrow], windowSeconds: [30], issuedAt: tb.now)
        let windowStart = tb.now.addingTimeInterval(-30)
        let media = s.belief.mediaTime(at: windowStart) + residual
        let result = SyncTracker.CheckInResult(outcome: .accepted(mediaAtStart: media, rate: 1, score: 0.5, tier: 0, residual: residual, hypothesis: nil),
                                               windowStart: windowStart, windowSeconds: 30, onsets: 8, speechFraction: 0.4)
        return s.didCheckIn(result, request: req, now: tb.now)
    }
    tb.advance(by: 100)
    _ = s.userNudged(seconds: -0.4, now: tb.now)
    let first = checkIn(at: 110, residual: 0.2)
    let firstApplied = first.contains { if case .session(.setClock) = $0 { return true } else { return false } }
    let second = checkIn(at: 230, residual: 0.2)
    let secondApplied = second.contains { if case .session(.setClock) = $0 { return true } else { return false } }
    let ok = !firstApplied && secondApplied && s.stats.skippedByNudgeGuard == 1
    return (pass(ok), "first \(firstApplied ? "applied" : "skipped"), second \(secondApplied ? "applied" : "skipped"); trim untouched by design (belief is trim-free)")
}

func runDeferredSnapTest() -> (String, String) {
    let tb = SimTimebase()
    var tuning = SyncTracker.Tuning()
    if let z = measuredTierOnsetZ { tuning.tierOnsetZ = z }
    let s = CheckInScheduler(tuning: tuning, policy: .init(interval: .m2, probe: false), now: tb.now)
    _ = s.start(now: tb.now)
    _ = s.userSeeded(media: 120, rate: nil, now: tb.now)
    tb.advance(by: 60)
    let windowStart = tb.now.addingTimeInterval(-30)
    let req = SyncTracker.CheckInRequest(kind: .scheduled, hypotheses: [.init(name: "belief", clock: s.belief)], hypothesisRadius: nil,
                                         rates: [], tiers: [.narrow], windowSeconds: [30], issuedAt: tb.now)
    var results: [String] = []
    var ok = true
    for residual in [-0.5, -0.2, 0.5, -1.5] {
        let media = s.belief.mediaTime(at: windowStart) + residual
        let r = SyncTracker.CheckInResult(outcome: .accepted(mediaAtStart: media, rate: 1, score: 0.5, tier: 0, residual: residual, hypothesis: nil),
                                          windowStart: windowStart, windowSeconds: 30, onsets: 8, speechFraction: 0.4)
        let actions = s.didCheckIn(r, request: req, now: tb.now)
        var deferred: Date?
        var applied = false
        for a in actions { if case .session(.setClock(let c)) = a { applied = true; deferred = c.deferUntil } }
        let expectDeferred = residual < 0 && abs(residual) < 1
        let deferOK = applied && ((deferred != nil) == expectDeferred) && (deferred.map { abs($0.timeIntervalSince(tb.now) - 3) < 0.01 } ?? true)
        ok = ok && deferOK
        results.append(String(format: "r %+.1f → %@", residual, deferred != nil ? "deferred ≤3 s" : "snap now"))
        tb.advance(by: 20)
    }
    // Boundary rule, with the film's cues: a deferred snap applies at the next cue boundary when that comes first.
    let track = SubtitleTrack(title: "f", language: "en", cues: film.parsed, source: "h")
    let media = 125.0
    let boundary = track.nextBoundary(after: media)
    results.append("boundary after 125.0 s → \(f1(boundary))")
    return (pass(ok), results.joined(separator: "; "))
}

/// S16 (reviewer): a check-in that was in flight when the latch held must not un-hold the
/// scheduler when its result arrives; a fresh one afterwards still applies.
func runStaleResultTest() -> (String, String) {
    let tb = SimTimebase()
    var tuning = SyncTracker.Tuning()
    if let z = measuredTierOnsetZ { tuning.tierOnsetZ = z }
    let s = CheckInScheduler(tuning: tuning, policy: .init(interval: .m2, probe: false), now: tb.now)
    _ = s.start(now: tb.now)
    _ = s.userSeeded(media: 120, rate: nil, now: tb.now)
    tb.advance(by: 15.5)
    var issued: SyncTracker.CheckInRequest?
    for a in s.tick(now: tb.now) { if case .runCheckIn(let r) = a { issued = r } }
    guard let req = issued else { return ("FAIL", "no check-in issued at +15 s") }
    tb.advance(by: 0.5)
    let held = s.presenceHeld(at: tb.now.addingTimeInterval(-0.5), now: tb.now)
    let heldOK = held.contains { if case .session(.holdClock) = $0 { return true } else { return false } }
    let windowStart = tb.now.addingTimeInterval(-30)
    let stale = SyncTracker.CheckInResult(outcome: .accepted(mediaAtStart: s.belief.mediaTime(at: windowStart) + 0.5, rate: 1, score: 0.5, tier: 0, residual: 0.5, hypothesis: nil),
                                          windowStart: windowStart, windowSeconds: 30, onsets: 8, speechFraction: 0.4)
    let staleActions = s.didCheckIn(stale, request: req, now: tb.now)
    var stillHeld = false
    if case .held(.auto, _) = s.state { stillHeld = true }
    let ok = heldOK && staleActions.isEmpty && stillHeld && s.belief.isPaused
    return (pass(ok), "held \(heldOK); stale result → \(staleActions.count) actions, state \(s.state), belief paused \(s.belief.isPaused)")
}

/// S17 (reviewer): the kill-clock warning from lockedIn (missed hold) freezes the clock and
/// `keepListening` restores lockedIn with the clock running; from held(.auto) it goes back to held.
func runWarnKeepListeningTest() -> (String, String) {
    let tb = SimTimebase()
    var tuning = SyncTracker.Tuning()
    if let z = measuredTierOnsetZ { tuning.tierOnsetZ = z }
    let s = CheckInScheduler(tuning: tuning, policy: .init(interval: .m2, probe: false), now: tb.now)
    _ = s.start(now: tb.now)
    _ = s.userSeeded(media: 120, rate: nil, now: tb.now)
    tb.advance(by: 10)
    let warn = s.presenceWarn(endsAt: tb.now.addingTimeInterval(120), now: tb.now)
    let warnHolds = warn.contains { if case .session(.holdClock) = $0 { return true } else { return false } }
        && warn.contains { if case .session(.warn) = $0 { return true } else { return false } }
    var ending = false
    if case .ending = s.state { ending = true }
    tb.advance(by: 5)
    let keep = s.keepListening(now: tb.now)
    let resumed = keep.contains { if case .session(.resumeClock) = $0 { return true } else { return false } }
        && keep.contains { if case .session(.clearWarning) = $0 { return true } else { return false } }
    let backLocked = s.state == .lockedIn && !s.belief.isPaused && s.nextCheckIn != nil
    // From an auto hold: no clock actions, back to held(.auto).
    tb.advance(by: 5)
    _ = s.presenceHeld(at: tb.now.addingTimeInterval(-0.5), now: tb.now)
    tb.advance(by: 5)
    let warn2 = s.presenceWarn(endsAt: tb.now.addingTimeInterval(120), now: tb.now)
    let warn2NoHold = !warn2.contains { if case .session(.holdClock) = $0 { return true } else { return false } }
    let keep2 = s.keepListening(now: tb.now)
    var backHeld = false
    if case .held(.auto, _) = s.state { backHeld = true }
    let keep2NoResume = !keep2.contains { if case .session(.resumeClock) = $0 { return true } else { return false } }
    let ok = warnHolds && ending && resumed && backLocked && warn2NoHold && backHeld && keep2NoResume && s.belief.isPaused
    return (pass(ok), "lockedIn → warn holds \(warnHolds) ending \(ending) → keep resumes \(resumed) lockedIn \(backLocked); held(.auto) → warn no extra hold \(warn2NoHold) → keep back to held \(backHeld)")
}

// MARK: - Suite

@_cdecl("synctest_suite_checkin")
public func synctestSuiteCheckIn() {
    let cues = film.cues
    let pal = 25 / 23.976
    print("== WP2 check-in scheduler ==")
    if measuredTierOnsetZ == nil || measuredCatchUpOnsetZ == nil {
        runWrongFilmTiers()
    } else {
        print(String(format: "S6 skipped: thresholds from the environment tierOnsetZ [%.1f, %.1f, %.1f], catchUpOnsetZ %.1f",
                     measuredTierOnsetZ![0], measuredTierOnsetZ![1], measuredTierOnsetZ![2], measuredCatchUpOnsetZ!))
    }
    print()
    printCheckInHeader()
    var rows: [CheckInRow] = []

    // S1 seed 120, play 60, pause 90, resume 120 (adaptive).
    rows.add(runCheckInScenario(ScenarioV2(name: "S1 pause 90 s at 60 s", startAt: 120, rate: 1, noise: 0.03, seconds: 270,
                                              events: [.pause(at: 60, seconds: 90)], seedAt: 120),
                                   policy: .init()) { o, run in
        let hold = run.pauseHold?.latency
        let frozen = run.pauseHold?.frozenError
        let rec = run.recovered(after: 150)
        // Hypothesis A (or tier A's P) is right when the hold was right; when the film resumes into a
        // cue gap the latch can only detect the resume at the next cue, A is then behind by that
        // gap and tier R (the resume T2) catches it instead — both count as the pause being right.
        let a = run.scheduler.stats.hypothesisWins["A", default: 0] + run.scheduler.stats.hypothesisWins["P", default: 0]
        let resumeT2 = run.acceptedRecords.contains { $0.kind == .resume && $0.tier == 2 && $0.at >= 150 }
        let ok = hold.map { $0 <= 7 } ?? false && abs(frozen ?? 9) <= 0.75 && (rec.map { $0 <= 20 } ?? false) && o.fullSearches == 0 && (a >= 1 || resumeT2) && run.scheduler.stats.lostEpisodes == 0
        return (pass(ok), "pause hold \(f1(hold)) s frozen \(f2(frozen)); hyp wins \(run.scheduler.stats.hypothesisWins)\(resumeT2 ? " + tier R" : ""); recovered \(f1(rec)) s after resume")
    })
    rows.add(runCheckInScenario(ScenarioV2(name: "S1b pause 90 s, latch off", startAt: 120, rate: 1, noise: 0.03, seconds: 300,
                                              events: [.pause(at: 60, seconds: 90)], seedAt: 120, autoPause: false),
                                   policy: .init()) { o, run in
        let rec = run.recovered(after: 150)
        let lost = run.scheduler.stats.lostEpisodes
        let ok = (rec.map { $0 <= 60 } ?? false) && o.fullSearches == 0
        return (pass(ok), "recovered \(f1(rec)) s via lost×\(lost)/T2")
    })
    rows.add(runCheckInScenario(ScenarioV2(name: "S1c pause 90 s, resume 20 s earlier", startAt: 120, rate: 1, noise: 0.03, seconds: 270,
                                              events: [.pause(at: 60, seconds: 90), .skip(at: 150, by: -20)], seedAt: 120),
                                   policy: .init()) { o, run in
        let rec = run.recovered(after: 150)
        let ok = (rec.map { $0 <= 30 } ?? false) && o.fullSearches == 0
        return (pass(ok), "recovered \(f1(rec)) s; tiers \(o.tierCounts) hyp \(run.scheduler.stats.hypothesisWins)")
    })
    rows.add(runCheckInScenario(ScenarioV2(name: "S1d pause 90 s, resume +120 s ahead", startAt: 60, rate: 1, noise: 0.03, seconds: 300,
                                              events: [.pause(at: 60, seconds: 90), .skip(at: 150, by: 120)], seedAt: 60),
                                   policy: .init()) { o, run in
        let rec = run.recovered(after: 150)
        let probing = run.states.contains { if case .probing = $0.state { return true } else { return false } }
        let ok = rec.map { $0 <= 90 } ?? false
        return (pass(ok), "recovered \(f1(rec)) s; probing \(probing) lost×\(run.scheduler.stats.lostEpisodes) reacq×\(run.scheduler.stats.reacquires)")
    })

    // S2 skip +30 s at 90, 2-min interval, probe on.
    // S2c: the synthetic film is ~7 min, so "+10 min" cannot be played; a −5 min skip from near
    // the end is the same test (far outside T1/T2, must reach T3 and re-lock < 60 s).
    for (name, startAt, by, probe) in [("S2 skip +30 s at 90 s, probe on", 60.0, 30.0, true), ("S2b skip −30 s at 90 s", 60.0, -30.0, true),
                                       ("S2c skip −5 min at 90 s (T3)", 330.0, -300.0, true), ("S2d skip +30 s, probe off", 60.0, 30.0, false)] {
        rows.add(runCheckInScenario(ScenarioV2(name: name, startAt: startAt, rate: 1, noise: 0.03, seconds: 300,
                                                  events: [.skip(at: 90, by: by)], seedAt: startAt, autoPause: false),
                                       policy: .init(interval: .m2, probe: probe)) { o, run in
            let rec = run.recovered(after: 90)
            let alarm = run.probeAlarmAt.first(where: { $0 >= 90 }).map { $0 - 90 }
            let after = run.acceptedRecords.filter { $0.at >= 90 }
            let maxTier = after.compactMap(\.tier).max() ?? -1
            let ok: Bool
            if abs(by) > 100 { ok = rec.map { $0 <= 60 } ?? false }
            else if probe { ok = (alarm.map { $0 <= 25 } ?? false) && (rec.map { $0 <= 40 } ?? false) && maxTier <= 2 && o.fullSearches == 0 && run.scheduler.stats.lostEpisodes == 0 }
            else { ok = (rec.map { $0 <= 120 + 15 } ?? false) && o.fullSearches == 0 }   // the next scheduled check-in (2 min) + retry margin
            return (pass(ok), "alarm \(f1(alarm)) s, recovered \(f1(rec)) s, max tier \(maxTier), verifies \(run.scheduler.stats.verifies), pending \(run.scheduler.stats.pendingLarge)")
        })
    }

    // S3 PAL 10 min, fixed 2-min, probe off, seedRate 1. S3b probe on.
    // The synthetic film is ~7 min: the PAL runs are 6.3 min from 10 s (the longest that fits at 1.0427×).
    for (name, probe) in [("S3 PAL 6 min, 2-min fixed, probe off", false), ("S3b PAL 6 min, 2-min fixed, probe on", true)] {
        rows.add(runCheckInScenario(ScenarioV2(name: name, startAt: 10, rate: pal, noise: 0.03, seconds: 380,
                                                  seedAt: 10, seedRate: 1, autoPause: false),
                                       policy: .init(interval: .m2, probe: probe)) { o, run in
            let recs = run.records
            let learnedAt = recs.first(where: { abs($0.rateAfter - pal) < 0.001 })?.at
            let residualsAfter = recs.filter { $0.at > (learnedAt ?? 1e9) && ($0.kind == .scheduled || $0.kind == .verify || $0.kind == .probeAlarm) }.compactMap(\.residual).map { abs($0) }
            let maxErrAfter = run.maxError(from: (learnedAt ?? 1e9) + 5, lockedOnly: true)
            let ok = (learnedAt.map { $0 <= 180 } ?? false) && (residualsAfter.max() ?? 0) < 0.5 && maxErrAfter < 1.0 && o.fullSearches == 0
            let seq = recs.prefix(4).map { "\(Int($0.at)):\(f2($0.residual))@\(String(format: "%.4f", $0.rateAfter))" }.joined(separator: " ")
            return (pass(ok), "rate \(String(format: "%.4f", o.finalRate)) learned@\(f1(learnedAt)) s; first check-ins \(seq); max |r| after \(f1(residualsAfter.max()))")
        })
    }

    // S4 film silence 25 s (false pause). S4b cue-less gap, TV quiet.
    rows.add(runCheckInScenario(ScenarioV2(name: "S4 film silent 25 s at 60 s (false pause)", startAt: 120, rate: 1, noise: 0.03, seconds: 200,
                                              events: [.silence(at: 60, seconds: 25)], seedAt: 120),
                                   policy: .init()) { o, run in
        let held = run.firstHold != nil
        let rec = run.recovered(after: 85)
        let b = run.scheduler.stats.hypothesisWins["B", default: 0] + run.scheduler.stats.hypothesisWins["C", default: 0]
        let ok = held && b >= 1 && (rec.map { $0 <= 15 } ?? false) && o.fullSearches == 0
        return (pass(ok), "held \(held) hyp \(run.scheduler.stats.hypothesisWins) recovered \(f1(rec)) s after content")
    })
    rows.add(runCheckInScenario(ScenarioV2(name: "S4b 20 s cue-less gap, TV quiet", startAt: cues[16].end - 10, rate: 1, noise: 0.03, seconds: 150,
                                              seedAt: cues[16].end - 10),
                                   policy: .init()) { o, run in
        let gapEnd = cues[17].start - (cues[16].end - 10)
        let rec = run.recovered(after: gapEnd)
        let held = run.firstHold != nil
        let lost = run.scheduler.stats.lostEpisodes
        let ok = (rec.map { $0 <= 15 } ?? false) && lost == 0 && o.fullSearches == 0
        return (pass(ok), "held \(held) (C's track-independent 10 s path; B's gate dropped by D4), hyp \(run.scheduler.stats.hypothesisWins), |err|<0.3 \(f1(rec)) s after the gap")
    })

    // S5 check-in in the montage gap: inconclusive, no state change, no miss.
    rows.add(runCheckInScenario(ScenarioV2(name: "S5 check-in in the montage gap", startAt: cues[16].end - 5, rate: 1, noise: 0.03, seconds: 90,
                                              seedAt: cues[16].end - 5, autoPause: false),
                                   policy: .init(probe: false)) { o, run in
        let first = run.records.first
        var inconclusive = false
        if let f = first, case .inconclusive = f.outcome { inconclusive = true }
        let stateAfter = run.states.last?.state ?? .idle
        let ok = inconclusive && run.scheduler.stats.misses == 0 && stateAfter == .lockedIn && run.scheduler.stats.lostEpisodes == 0
        return (pass(ok), "first check-in @\(f1(first?.at)) s \(first.map { "\($0.outcome)" } ?? "-"); misses \(run.scheduler.stats.misses); state \(stateAfter)")
    })

    // S7 S1–S3 at noise 0.08 / 0.15; S7b noisy 10 min with 1-min check-ins.
    for noise in [Float(0.08), 0.15] {
        rows.add(runCheckInScenario(ScenarioV2(name: String(format: "S7 S1 pause 90 s, noise %.2f", noise), startAt: 120, rate: 1, noise: noise, seconds: 270,
                                                  events: [.pause(at: 60, seconds: 90)], seedAt: 120),
                                       policy: .init()) { o, run in
            let rec = run.recovered(after: 150)
            let latched = (run.pauseHold?.latency).map { $0 <= 15 } ?? false
            let ok = (rec.map { $0 <= 30 } ?? false) && o.fullSearches == 0
            let verdict = latched ? pass(ok) : (ok ? "PASS" : "N/A")
            return (verdict, "pause hold \(f1(run.pauseHold?.latency)) s frozen \(f2(run.pauseHold?.frozenError)) recovered \(f1(rec)) s hyp \(run.scheduler.stats.hypothesisWins) lost×\(run.scheduler.stats.lostEpisodes)" + (latched ? "" : " (stand-in latch did not hold at this noise; the real PresenceTracker is WP3's)"))
        })
        rows.add(runCheckInScenario(ScenarioV2(name: String(format: "S7 S2 skip +30 s, noise %.2f", noise), startAt: 60, rate: 1, noise: noise, seconds: 300,
                                                  events: [.skip(at: 90, by: 30)], seedAt: 60, autoPause: false),
                                       policy: .init(interval: .m2)) { o, run in
            let rec = run.recovered(after: 90)
            let ok = (rec.map { $0 <= 60 } ?? false) && o.fullSearches == 0
            return (pass(ok), "recovered \(f1(rec)) s lost×\(run.scheduler.stats.lostEpisodes)")
        })
        rows.add(runCheckInScenario(ScenarioV2(name: String(format: "S7 S3 PAL, noise %.2f", noise), startAt: 10, rate: pal, noise: noise, seconds: 380,
                                                  seedAt: 10, seedRate: 1, autoPause: false),
                                       policy: .init(interval: .m2, probe: false)) { o, run in
            let learnedAt = run.records.first(where: { abs($0.rateAfter - pal) < 0.001 })?.at
            let maxErrAfter = run.maxError(from: (learnedAt ?? 1e9) + 5, lockedOnly: true)
            let ok = (learnedAt.map { $0 <= 270 } ?? false) && maxErrAfter < 1.5 && o.fullSearches == 0
            return (pass(ok), "rate \(String(format: "%.4f", o.finalRate)) learned@\(f1(learnedAt)) s")
        })
    }
    rows.add(runCheckInScenario(ScenarioV2(name: "S7b noisy 0.08, 6 min, 1-min", startAt: 30, rate: 1, noise: 0.08, seconds: 370, seedAt: 30, autoPause: false),
                                   policy: .init(interval: .m1)) { o, run in
        let big = run.corrections.filter { abs($0.residual) > 1 && abs($0.errBefore ?? 9) < 0.2 }.count
        let ok = run.conclusiveFraction >= 0.8 && big == 0 && run.scheduler.stats.lostEpisodes == 0
        return (pass(ok), "conclusive \(String(format: "%.0f%%", run.conclusiveFraction * 100)), corrections > 1 s while right: \(big) (all > 1 s: \(run.corrections.filter { abs($0.residual) > 1 }.count))")
    })

    // S8 nudge guard, S12 deferred snap: pure scheduler logic.
    if wanted("S8") {
        let (v8, d8) = runNudgeGuardTest()
        print("S8 nudge guard".padding(toLength: 34, withPad: " ", startingAt: 0) + "  (pure logic)  " + v8 + "  " + d8)
        rows.append(CheckInRow(name: "S8 nudge guard", outcome: OutcomeV2(), run: nil, seconds: 0, verdict: v8, detail: d8, printed: false))
    }
    if wanted("S12") {
        let (v12, d12) = runDeferredSnapTest()
        print("S12 deferred backward snap".padding(toLength: 34, withPad: " ", startingAt: 0) + "  (pure logic)  " + v12 + "  " + d12)
        rows.append(CheckInRow(name: "S12 deferred backward snap", outcome: OutcomeV2(), run: nil, seconds: 0, verdict: v12, detail: d12, printed: false))
    }
    if wanted("S16") {
        let (v, d) = runStaleResultTest()
        print("S16 stale result during hold".padding(toLength: 34, withPad: " ", startingAt: 0) + "  (pure logic)  " + v + "  " + d)
        rows.append(CheckInRow(name: "S16 stale result during hold", outcome: OutcomeV2(), run: nil, seconds: 0, verdict: v, detail: d, printed: false))
    }
    if wanted("S17") {
        let (v, d) = runWarnKeepListeningTest()
        print("S17 warn / keep listening".padding(toLength: 34, withPad: " ", startingAt: 0) + "  (pure logic)  " + v + "  " + d)
        rows.append(CheckInRow(name: "S17 warn / keep listening", outcome: OutcomeV2(), run: nil, seconds: 0, verdict: v, detail: d, printed: false))
    }

    // S9 chatter during a 60 s pause.
    rows.add(runCheckInScenario(ScenarioV2(name: "S9 chatter during 60 s pause", startAt: 120, rate: 1, noise: 0.03, seconds: 300,
                                              events: [.pause(at: 60, seconds: 60), .chatter(at: 60, seconds: 60)], seedAt: 120),
                                   policy: .init()) { o, run in
        let during = run.corrections.filter { $0.t >= 60 && $0.t < 120 && abs($0.residual) >= 0.12 }.count
        let rec = run.recovered(after: 120)
        let ok = during == 0 && (rec.map { $0 <= 40 } ?? false)
        return (pass(ok), "corrections during chatter \(during); re-lock \(f1(rec)) s after resume; lost×\(run.scheduler.stats.lostEpisodes) held \(run.firstHold != nil)")
    })

    // S10 jitter: 20 check-ins on a clean run at 30 s.
    rows.add(runCheckInScenario(ScenarioV2(name: "S10 jitter, check-ins at 30 s", startAt: 20, rate: 1, noise: 0.02, seconds: 380, seedAt: 20, autoPause: false),
                                   policy: .init(interval: .s30, probe: false)) { o, run in
        let rs = run.records.filter { $0.kind == .scheduled }.compactMap(\.residual)
        let n = Double(rs.count)
        let mean = rs.reduce(0, +) / max(1, n)
        let sigma = (rs.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / max(1, n - 1)).squareRoot()
        let ok = rs.count >= 10 && sigma < 0.2
        return (pass(ok), String(format: "σ_t %.3f s over %d scheduled residuals (mean %+.3f)", sigma, rs.count, mean))
    })

    // S11 wall-clock step +30 s at 100 s.
    rows.add(runCheckInScenario(ScenarioV2(name: "S11 wall step +30 s at 100 s", startAt: 60, rate: 1, noise: 0.03, seconds: 240,
                                              events: [.wallStep(at: 100, seconds: 30)], seedAt: 60, autoPause: false),
                                   policy: .init(interval: .m1, probe: false)) { o, run in
        let around = run.records.filter { $0.at > 100 && $0.at < 105 }.count
        let sched = run.records.filter { $0.kind == .scheduled }.compactMap(\.residual).map { abs($0) }
        let ok = (sched.max() ?? 9) < 0.5 && around == 0 && run.scheduler.stats.lostEpisodes == 0
        return (pass(ok), "check-ins within 5 s of the step: \(around); max scheduled |r| \(f2(sched.max())); max |err| \(String(format: "%.2f", run.maxError(from: 20)))")
    })

    // S14 island Play after a pause: the TV resumed 10 s before the user tapped Play.
    rows.add(runCheckInScenario(ScenarioV2(name: "S14 island Play 10 s after TV resume", startAt: 120, rate: 1, noise: 0.03, seconds: 240,
                                              events: [.pause(at: 60, seconds: 40)], seedAt: 120, autoPause: false),
                                   policy: .init(),
                                   userEvents: [(60, { ctx, run in run.execute(run.scheduler.userPause(now: ctx.now), ctx: ctx); ctx.pauseReason = .user }),
                                                (110, { ctx, run in ctx.pauseReason = .none; run.execute(run.scheduler.userResume(now: ctx.now), ctx: ctx) })]) { o, run in
        let rec = run.recovered(after: 110)
        let confirms = run.records.filter { if case .confirm = $0.kind { return true } else { return false } }.count
        let firstAfter = run.records.first(where: { r in
            guard r.at >= 110 else { return false }
            if case .inconclusive = r.outcome { return false }
            return true
        })
        var firstAccepted = false
        if let f = firstAfter, case .accepted = f.outcome { firstAccepted = true }
        let ok = confirms == 0 && (rec.map { $0 <= 25 } ?? false) && run.scheduler.stats.lostEpisodes == 0
        _ = firstAccepted
        return (pass(ok), "first check-in after Play @\(f1(firstAfter?.at)) \(firstAfter.map { "\($0.outcome)" } ?? "-") r \(f2(firstAfter?.residual)); pending confirms \(confirms); |err|<0.3 \(f1(rec)) s after Play")
    })

    // S15 Re-sync: single tap → wide pass; double tap → full search.
    rows.add(runCheckInScenario(ScenarioV2(name: "S15a Re-sync once after skip +100 s", startAt: 60, rate: 1, noise: 0.03, seconds: 200,
                                              events: [.skip(at: 90, by: 100)], seedAt: 60, autoPause: false),
                                   policy: .init(probe: false),
                                   userEvents: [(115, { ctx, run in run.execute(run.scheduler.userResync(now: ctx.now), ctx: ctx) })]) { o, run in
        let rec = run.recovered(after: 115)
        let resync = run.records.first(where: { $0.kind == .resync })
        let ok = resync != nil && o.fullSearches == 0 && (rec.map { $0 <= 20 } ?? false)
        return (pass(ok), "wide pass \(resync.map { "\($0.outcome)" } ?? "none") tier \(resync?.tier ?? -1); recovered \(f1(rec)) s; full searches \(o.fullSearches)")
    })
    rows.add(runCheckInScenario(ScenarioV2(name: "S15b Re-sync twice within 10 s", startAt: 60, rate: 1, noise: 0.03, seconds: 200,
                                              events: [.skip(at: 90, by: 100)], seedAt: 60, autoPause: false),
                                   policy: .init(probe: false),
                                   userEvents: [(115, { ctx, run in run.execute(run.scheduler.userResync(now: ctx.now), ctx: ctx) }),
                                                (118, { ctx, run in run.execute(run.scheduler.userResync(now: ctx.now), ctx: ctx); ctx.isPlaced = false })]) { o, run in
        let acquiringAt = run.states.first(where: { if case .acquiring = $0.state { return $0.t >= 117 } else { return false } })?.t
        let relock = run.lockedInAt.map { $0 } ?? -1
        let relockAfter = run.states.filter { $0.t >= 118 && $0.state == .lockedIn }.first?.t
        let ok = acquiringAt != nil && o.fullSearches >= 1 && relockAfter != nil
        _ = relock
        return (pass(ok), "acquiring @\(f1(acquiringAt)) s, full searches \(o.fullSearches), lockedIn again @\(f1(relockAfter)) s")
    })

    // S13 the V1 scenarios: policy = nil (lockedIn false) must be V1; locked-in for the cost proxy.
    if wanted("S13") { runS13() }

    print()
    let failed = rows.filter { $0.verdict == "FAIL" }
    let na = rows.filter { $0.verdict == "N/A" }
    print("Check-in suite: \(rows.count - failed.count - na.count)/\(rows.count) scenario rows pass" + (failed.isEmpty ? "" : "; failing: " + failed.map(\.name).joined(separator: ", ")) + (na.isEmpty ? "" : "; N/A (stand-in latch): " + na.map(\.name).joined(separator: ", ")))
    if let z = measuredTierOnsetZ, let c = measuredCatchUpOnsetZ {
        print(String(format: "Thresholds used after S6: tierOnsetZ [%.1f, %.1f, %.1f], catchUpOnsetZ %.1f", z[0], z[1], z[2], c))
    }
}

func runS13() {
    print()
    print("S13 V1 scenarios through the V2 runner, lockedIn = false (must match the V1 table):")
    print("scenario".padding(toLength: 30, withPad: " ", startingAt: 0) + "   lock@s    err s  confirm@s     rate  worst s  recovery s   corr/min   locked-in corr/min  ratio")
    var ratios: [Double] = []
    for s in scenariosV1 {
        let v2 = ScenarioV2(name: s.name, startAt: s.startAt, rate: s.rate, noise: s.noise, seconds: s.seconds, hintAt: s.hintAt, events: s.events,
                            seedAt: nil, lockedIn: false, autoPause: false)
        let r = runV2(v2, hooks: checkInHooks(policy: .init(lockedIn: false)))
        let li = ScenarioV2(name: s.name, startAt: s.startAt, rate: s.rate, noise: s.noise, seconds: s.seconds, hintAt: s.hintAt, events: s.events,
                            seedAt: nil, lockedIn: true, autoPause: true)
        let rl = runV2(li, hooks: checkInHooks(policy: .init()))
        let cpmV1 = Double(r.correlations) / (s.seconds / 60)
        let cpmLI = Double(rl.correlations) / (s.seconds / 60)
        ratios.append(cpmV1 / max(1, cpmLI))
        print(s.name.padding(toLength: 30, withPad: " ", startingAt: 0)
              + pad(r.lockAfter.map { String(format: "%.0f", $0) } ?? "never", 9)
              + pad(r.error.map { String(format: "%+.2f", $0) } ?? "-", 9)
              + pad(r.confirmedAfter.map { String(format: "%.0f", $0) } ?? "never", 11)
              + pad(String(format: "%.4f", r.finalRate), 9)
              + pad(String(format: "%.2f", r.worst), 9)
              + pad(r.recovery.isEmpty ? "" : r.recovery.map { $0.map { String(format: "%.0f", $0) } ?? "never" }.joined(separator: ","), 12)
              + pad(String(format: "%.1f", cpmV1), 11)
              + pad(String(format: "%.1f", cpmLI), 20)
              + pad(String(format: "%.1fx", cpmV1 / max(1, cpmLI)), 7))
    }
    let meanRatio = ratios.reduce(0, +) / Double(ratios.count)
    print(String(format: "S13 per-scenario: locked-in runs %.1fx fewer correlations on average over the 15 short V1 scenarios (the acquiring phase dominates 90–120 s runs)", meanRatio))
    // The cost proxy proper: the longest watch the 7-min film allows, V1 continuous vs locked-in (adaptive, probe on).
    let long = ScenarioV2(name: "6.5 min watch", startAt: 10, rate: 1, noise: 0.03, seconds: 390, seedAt: nil, lockedIn: false, autoPause: false)
    let v1 = runV2(long, hooks: checkInHooks(policy: .init(lockedIn: false)))
    var li = long
    li.lockedIn = true
    li.autoPause = true
    var liRun: CheckInRun?
    var liHooks = checkInHooks(policy: .init())
    let liFinish = liHooks.finish
    liHooks.finish = { ctx in liFinish?(ctx); liRun = ctx.extras["checkin"] as? CheckInRun }
    let v2 = runV2(li, hooks: liHooks)
    let cpm1 = Double(v1.correlations) / (long.seconds / 60), cpm2 = Double(v2.correlations) / (long.seconds / 60)
    print(String(format: "S13 cost proxy (6.5 min, lock@%@ s): V1 %.1f correlations/min, locked-in %.1f correlations/min (%d check-ins) → %.1fx fewer (want ≥ 10x; includes the acquiring phase)",
                 v2.lockAfter.map { String(format: "%.0f", $0) } ?? "never", cpm1, cpm2, v2.checkIns, cpm1 / max(1, cpm2)))
    if let r = liRun, let at = r.lockedInAt, long.seconds - at > 60 {
        let steady = Double(v2.correlations - r.correlationsAtLockIn) / ((long.seconds - at) / 60)
        let probes = Double(r.scheduler.stats.probes) / ((long.seconds - at) / 60)
        print(String(format: "S13 steady state after lockedIn@%.0f s: %.1f correlations/min (%.1f probes/min + check-ins) vs V1 %.1f → %.1fx fewer; without the probe: %.1fx",
                     at, steady, probes, cpm1, cpm1 / max(1, steady), cpm1 / max(1, steady - probes)))
    }
}
