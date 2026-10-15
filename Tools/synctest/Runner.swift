import Darwin
import Foundation

// The V1 runner (unchanged behaviour) and the generic V2 runner skeleton.
// Declarations only (no top-level statements).

extension SubtitleTrack: IslandCueSource {
    var cueCount: Int { cues.count }
    func cueText(_ index: Int) -> String { cues[index].text }
    func cueEnd(_ index: Int) -> Double { cues[index].end }
}

// MARK: - V1

struct Outcome {
    var lockAfter: Double?
    var error: Double?
    var confirmedAfter: Double?
    var finalRate: Double
    /// Worst confirmed-lock error outside the 60 s after each event.
    var worst: Double
    /// Seconds from the end of each event until the lock is confirmed within 0.5 s of truth.
    var recovery: [Double?]
}

/// Plays "the room" into a V1 tracker (analyse every 2 s on a 60 s window) and reports lock
/// time and accuracy. Identical to the V1 harness.
func run(_ s: Scenario) -> Outcome {
    let parsed = film.parsed
    let tracker = SyncTracker(cues: parsed)
    if s.rate > 1.1 { tracker.tuning.searchRates += [1.25, 1.5, 1.75, 2.0] }
    let vad = VoiceActivityDetector(sampleRate: sampleRate)
    let ring = MicRing(seconds: 120)
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    ring.start(at: t0)
    let hop = 4800 // 100 ms buffers, as on the phone
    let windowSeconds = Double(ProcessInfo.processInfo.environment["WINDOW"] ?? "60")!
    var wallSamples = 0
    let totalWall = Int(s.seconds * sampleRate)
    var outcome = Outcome(lockAfter: nil, error: nil, confirmedAfter: nil, finalRate: 1, worst: 0, recovery: s.events.map { _ in nil })
    var nextAnalysis = 2.0
    var mediaPos = s.startAt
    var skipsDone = Set<Int>()
    func quietUntil(_ wall: Double) -> Bool {
        s.events.contains { if case .pause = $0 { return $0.contains(wall) } else { return false } }
    }
    func musicAt(_ wall: Double) -> Bool {
        s.events.contains { if case .music = $0 { return $0.contains(wall) } else { return false } }
    }
    while wallSamples < totalWall {
        var buf = roomNoise(hop, level: s.noise)
        for i in 0..<hop {
            let wall = Double(wallSamples + i) / sampleRate
            for (k, e) in s.events.enumerated() {
                if case .skip(let at, let by) = e, !skipsDone.contains(k), wall >= at { skipsDone.insert(k); mediaPos += by }
            }
            if !quietUntil(wall) {
                let idx = Int(mediaPos * sampleRate)
                if idx >= 0 && idx < film.samples.count { buf[i] += film.samples[idx] }
                mediaPos += s.rate / sampleRate
                if musicAt(wall) { buf[i] += musicSample(wall) }
            }
        }
        let frames = vad.process(buf)
        ring.append(frames.map(\.speech))
        wallSamples += hop
        let wallSeconds = Double(wallSamples) / sampleRate
        if let hintAt = s.hintAt, abs(wallSeconds - hintAt) < 0.05 {
            // The speech recogniser hears the line that just finished and reports it.
            if let i = parsed.lastIndex(where: { $0.start <= mediaPos }) {
                tracker.addHint(words: parsed[i].text.split(separator: " ").map(String.init), heardAt: t0.addingTimeInterval(wallSeconds))
            }
        }
        if wallSeconds >= nextAnalysis {
            nextAnalysis += 2
            let now = t0.addingTimeInterval(wallSeconds)
            guard let window = ring.latest(seconds: windowSeconds) else { continue }
            let report = tracker.analyse(mic: window.bins, windowStart: window.start, now: now)
            let truth = mediaPos
            if ProcessInfo.processInfo.environment["DEBUG"] != nil {
                print(String(format: "  t=%3.0f speech %.2f %@ state=%@ lock=%@ truth=%.1f", wallSeconds, report.speechFraction, report.note, "\(report.state)", report.lock.map { String(format: "%.1f", $0.mediaTime(at: now)) } ?? "-", truth))
            }
            if let lock = report.lock {
                let err = lock.mediaTime(at: now) - truth
                if outcome.lockAfter == nil { outcome.lockAfter = wallSeconds; outcome.error = err }
                if lock.confirmed, outcome.confirmedAfter == nil { outcome.confirmedAfter = wallSeconds }
                let settling = s.events.contains { wallSeconds >= eventStart($0) && wallSeconds < eventEnd($0) + 60 }
                if lock.confirmed, !settling { outcome.worst = max(outcome.worst, abs(err)) }
                for (k, e) in s.events.enumerated() where outcome.recovery[k] == nil && wallSeconds > eventEnd(e) + 0.5 {
                    if lock.confirmed, abs(err) < 0.5 { outcome.recovery[k] = wallSeconds - eventEnd(e) }
                }
            }
        }
    }
    outcome.finalRate = tracker.rate
    return outcome
}

// MARK: - V2 skeleton

/// A simulated monotonic time base (docs/v2/checkin.md §2) plus a wall clock that `.wallStep`
/// can jump. Engine code sees `now`; the Island would see `wall`. WP2 adds `extension
/// SimTimebase: Timebase` in its scenario file.
final class SimTimebase {
    private(set) var now: Date
    private(set) var wall: Date
    let origin: Date

    init(origin: Date = Date(timeIntervalSince1970: 1_000_000)) {
        self.origin = origin
        now = origin
        wall = origin
    }

    func advance(by seconds: Double) {
        now = now.addingTimeInterval(seconds)
        wall = wall.addingTimeInterval(seconds)
    }

    func stepWall(by seconds: Double) { wall = wall.addingTimeInterval(seconds) }

    var elapsed: Double { now.timeIntervalSince(origin) }
}

/// A V2 scenario: V1's fields plus the seed, policy and presence knobs the specs list.
struct ScenarioV2 {
    let name: String
    let startAt: Double
    let rate: Double
    let noise: Float
    let seconds: Double
    var hintAt: Double? = nil
    var events: [RoomEvent] = []
    /// Seed the clock at this media time at t = 0 (as "Set position" / a relaunch would).
    var seedAt: Double? = nil
    var seedRate: Double? = nil
    /// nil = V1 continuous; otherwise the locked-in policy the scheduler hook should apply.
    var lockedIn = true
    var checkInInterval: CheckInInterval = .adaptive
    var probe = true
    var autoPause = true
    var patience: AutoPausePatience = .normal
    /// Kill clock in seconds (nil = off). `KILL=` in the environment overrides it.
    var killAfter: Double? = 20 * 60
    var treatMusicAsContent = true
    /// Film-path filter (the tvEq hook); nil = unfiltered.
    var filmFilter: (([Float]) -> [Float])? = nil
}

/// Numbers every V2 scenario reports (docs/v2/checkin.md §10, latch.md §10, island.md §8).
struct OutcomeV2 {
    var lockAfter: Double?
    var error: Double?
    var confirmedAfter: Double?
    var finalRate: Double = 1
    var worst: Double = 0
    var recovery: [Double?] = []
    /// Seconds from a pause event to the hold.
    var holdLatency: Double?
    /// Displayed − truth at the instant the clock froze.
    var frozenError: Double?
    var checkIns = 0
    var conclusiveCheckIns = 0
    var tierCounts = [0, 0, 0, 0]
    var fullSearches = 0
    var correlations = 0
    var falseHolds = 0
    var missedHolds = 0
    var autoPauses = 0
    var maxErrorLocked: Double = 0
    var meanError: Double = 0
    var errorSamples = 0
    var sigmaT: Double?
    var ended = false
    var endedAt: Double?
    var notes: [String] = []

    var conclusiveFraction: Double { checkIns == 0 ? 0 : Double(conclusiveCheckIns) / Double(checkIns) }
}

/// Everything a V2 scenario run owns. Hooks mutate it; packages stash their own objects
/// (scheduler, presence tracker, memory) in `extras`.
final class V2Context {
    let scenario: ScenarioV2
    let film: Film
    let timebase: SimTimebase
    let tracker: SyncTracker
    let vad: VoiceActivityDetector
    let ring: MicRing
    /// The display clock, trim-free (as `SessionController.clock`); `trim` is kept separately.
    var clock: PlaybackClock
    var trim = 0.0
    var pauseReason: PauseReason = .none
    var isPlaced = false
    /// Truth: where the film really is and whether it is playing.
    var truthMedia: Double
    var truthPlaying = true
    var truthAudible = true
    var wallSeconds = 0.0
    var tick = 0
    var outcome: OutcomeV2
    var extras: [String: Any] = [:]
    var log: [String] = []

    init(scenario: ScenarioV2, film: Film) {
        self.scenario = scenario
        self.film = film
        timebase = SimTimebase()
        tracker = SyncTracker(cues: film.parsed)
        if scenario.rate > 1.1 { tracker.tuning.searchRates += [1.25, 1.5, 1.75, 2.0] }
        vad = VoiceActivityDetector(sampleRate: sampleRate)
        ring = MicRing(seconds: 120)
        ring.start(at: timebase.now)
        truthMedia = scenario.startAt
        clock = PlaybackClock(media: scenario.seedAt ?? 0, at: timebase.now, rate: scenario.seedRate ?? 1, paused: scenario.seedAt == nil)
        outcome = OutcomeV2(recovery: scenario.events.map { _ in nil })
        if let seed = scenario.seedAt {
            tracker.seed(mediaTime: seed, at: timebase.now)
            if let r = scenario.seedRate { tracker.rate = r }
            isPlaced = true
        }
    }

    var now: Date { timebase.now }
    /// Displayed media time (clock + trim).
    var displayed: Double { clock.mediaTime(at: now) + trim }
    /// Displayed − truth, nil until placed.
    var displayError: Double? { isPlaced ? displayed - truthMedia : nil }

    /// Applies a lock the way `SessionController.apply(lock)` does (0.12 s dead band, ignored
    /// while the clock is paused).
    func apply(lock: SyncTracker.Lock) {
        isPlaced = true
        guard !clock.isPaused else { return }
        let target = lock.mediaTime(at: now)
        if abs(target - clock.mediaTime(at: now)) < 0.12, lock.rate == clock.rate { return }
        clock.set(media: target, at: now, rate: lock.rate)
    }

    /// Applies a scheduler action the way `SessionController.apply(action:)` does.
    func apply(action: SessionAction) {
        switch action {
        case .setClock(let c):
            clock.set(media: c.media + now.timeIntervalSince(c.at) * c.rate, at: now, rate: c.rate)
            if clock.isPaused, pauseReason == .auto { clock.resume(at: now); pauseReason = .none }
            isPlaced = true
        case .holdClock(let at, let reason):
            guard pauseReason != .user else { return }
            if !clock.isPaused { outcome.autoPauses += reason == .auto ? 1 : 0 }
            clock.pause(at: at)
            pauseReason = reason
            if outcome.holdLatency == nil, let p = scenario.events.first(where: { if case .pause = $0 { return true } else { return false } }) {
                outcome.holdLatency = wallSeconds - p.start
                outcome.frozenError = displayed - truthMedia
            }
        case .resumeClock(let at):
            guard pauseReason != .user else { return }
            clock.resume(at: at)
            pauseReason = .none
        case .endSession:
            outcome.ended = true
            outcome.endedAt = wallSeconds
        case .status, .warn, .clearWarning, .caughtUp:
            break
        }
    }
}

/// The places WP2–WP4 plug into the V2 runner. Every hook is optional; with none set the runner
/// is V1 (analyse every 2 s, locks applied to the clock).
struct V2Hooks {
    /// Called once after the context is built (create the scheduler / presence tracker / memory).
    var setup: ((V2Context) -> Void)?
    /// Every 100 ms buffer with the raw mono samples the mic heard (feeds presence / mel).
    var onSamples: ((V2Context, [Float]) -> Void)?
    /// 1 Hz, after the buffer that completed the second (the engine's tap-driven tick).
    var onTick: ((V2Context) -> Void)?
    /// Every 2 s with the 60 s window (V1 cadence). nil = V1 analyse + apply(lock).
    var onAnalysisWindow: ((V2Context, [Float], Date) -> Void)?
    /// When a room event begins (nudges, wall steps and skips are applied by the runner first).
    var onEvent: ((V2Context, RoomEvent) -> Void)?
    /// After the run, before the outcome is returned.
    var finish: ((V2Context) -> Void)?
}

/// Plays a V2 scenario through the hooks, samples displayed-vs-truth error every 100 ms, and
/// returns the outcome. Pauses stop the truth clock; silence/muted advance it silently; music,
/// chatter and the fan are added to the room; skips move the truth; nudges move the trim;
/// wall steps jump `timebase.wall` only.
func runV2(_ s: ScenarioV2, hooks: V2Hooks = V2Hooks()) -> OutcomeV2 {
    let theFilm = s.filmFilter.map { film.filtered($0) } ?? film
    let ctx = V2Context(scenario: s, film: theFilm)
    let killOverride = ProcessInfo.processInfo.environment["KILL"].flatMap(Double.init)
    if let k = killOverride { ctx.extras["killAfter"] = k } else if let k = s.killAfter { ctx.extras["killAfter"] = k }
    hooks.setup?(ctx)
    let hop = 4800
    let windowSeconds = Double(ProcessInfo.processInfo.environment["WINDOW"] ?? "60")!
    let totalWall = Int(s.seconds * sampleRate)
    var wallSamples = 0
    var nextAnalysis = 2.0
    var nextTick = 1.0
    var started = Set<Int>()
    var fanLevel: Float = 0
    var errorSum = 0.0
    let debug = ProcessInfo.processInfo.environment["DEBUG"] != nil
    while wallSamples < totalWall {
        var buf = roomNoise(hop, level: s.noise)
        if fanLevel > 0 { let f = fanNoise(hop, level: fanLevel); for i in 0..<hop { buf[i] += f[i] } }
        for i in 0..<hop {
            let wall = Double(wallSamples + i) / sampleRate
            for (k, e) in s.events.enumerated() where !started.contains(k) && wall >= e.start {
                started.insert(k)
                switch e {
                case .skip(_, let by): ctx.truthMedia += by
                case .nudge(_, let secs): ctx.trim += secs
                case .wallStep(_, let secs): ctx.timebase.stepWall(by: secs)
                case .fan(_, let level): fanLevel = level
                default: break
                }
                ctx.wallSeconds = wall
                hooks.onEvent?(ctx, e)
            }
            let paused = s.events.contains { if case .pause = $0 { return $0.contains(wall) } else { return false } }
            let silent = s.events.contains {
                switch $0 { case .silence, .muted: return $0.contains(wall); default: return false }
            }
            ctx.truthPlaying = !paused
            ctx.truthAudible = !paused && !silent
            if !paused {
                if !silent {
                    let idx = Int(ctx.truthMedia * sampleRate)
                    if idx >= 0 && idx < theFilm.samples.count { buf[i] += theFilm.samples[idx] }
                }
                ctx.truthMedia += s.rate / sampleRate
            }
            for e in s.events where e.contains(wall) {
                switch e {
                case .music(_, _, let bpm): buf[i] += musicSample(wall, bpm: bpm ?? 120)
                case .chatter: buf[i] += chatterSample(wall)
                default: break
                }
            }
        }
        let frames = ctx.vad.process(buf)
        ctx.ring.append(frames.map(\.speech))
        hooks.onSamples?(ctx, buf)
        wallSamples += hop
        ctx.timebase.advance(by: Double(hop) / sampleRate)
        ctx.wallSeconds = Double(wallSamples) / sampleRate
        let wallSeconds = ctx.wallSeconds

        // Displayed-vs-truth error, every 100 ms.
        if let err = ctx.displayError {
            errorSum += abs(err)
            ctx.outcome.errorSamples += 1
            if ctx.tracker.state == .locked, ctx.tracker.lock?.confirmed == true, !ctx.clock.isPaused {
                let settling = s.events.contains { wallSeconds >= $0.start && wallSeconds < $0.end + 60 }
                if !settling { ctx.outcome.maxErrorLocked = max(ctx.outcome.maxErrorLocked, abs(err)) }
            }
            for (k, e) in s.events.enumerated() where ctx.outcome.recovery[k] == nil && wallSeconds > e.end + 0.5 {
                if ctx.tracker.lock?.confirmed == true, abs(err) < 0.5 { ctx.outcome.recovery[k] = wallSeconds - e.end }
            }
        }

        if let hintAt = s.hintAt, abs(wallSeconds - hintAt) < 0.05,
           let i = theFilm.parsed.lastIndex(where: { $0.start <= ctx.truthMedia }) {
            ctx.tracker.addHint(words: theFilm.parsed[i].text.split(separator: " ").map(String.init), heardAt: ctx.now)
        }
        if wallSeconds >= nextTick {
            nextTick += 1
            ctx.tick += 1
            hooks.onTick?(ctx)
        }
        if wallSeconds >= nextAnalysis {
            nextAnalysis += 2
            guard let window = ctx.ring.latest(seconds: windowSeconds) else { continue }
            if let custom = hooks.onAnalysisWindow {
                custom(ctx, window.bins, window.start)
            } else {
                let report = ctx.tracker.analyse(mic: window.bins, windowStart: window.start, now: ctx.now)
                ctx.outcome.correlations += 1
                if report.note.hasPrefix("full search") || report.note.hasPrefix("candidate") { ctx.outcome.fullSearches += 1 }
                if debug {
                    print(String(format: "  t=%3.0f speech %.2f %@ state=%@ lock=%@ truth=%.1f disp=%@", wallSeconds, report.speechFraction, report.note, "\(report.state)", report.lock.map { String(format: "%.1f", $0.mediaTime(at: ctx.now)) } ?? "-", ctx.truthMedia, ctx.displayError.map { String(format: "%+.2f", $0) } ?? "-"))
                }
                if let lock = report.lock {
                    ctx.apply(lock: lock)
                    let err = lock.mediaTime(at: ctx.now) - ctx.truthMedia
                    if ctx.outcome.lockAfter == nil { ctx.outcome.lockAfter = wallSeconds; ctx.outcome.error = err }
                    if lock.confirmed, ctx.outcome.confirmedAfter == nil { ctx.outcome.confirmedAfter = wallSeconds }
                    let settling = s.events.contains { wallSeconds >= $0.start && wallSeconds < $0.end + 60 }
                    if lock.confirmed, !settling { ctx.outcome.worst = max(ctx.outcome.worst, abs(err)) }
                }
            }
        }
    }
    ctx.outcome.finalRate = ctx.tracker.rate
    ctx.outcome.meanError = ctx.outcome.errorSamples == 0 ? 0 : errorSum / Double(ctx.outcome.errorSamples)
    hooks.finish?(ctx)
    return ctx.outcome
}

// MARK: - Suite dispatch

/// Scenario suites the packages add. A suite is a C-named entry point in its own file:
///
///     @_cdecl("synctest_suite_checkin") public func synctestSuiteCheckIn() { ... }
///
/// main.swift looks it up by name (`SCENARIOS=checkin`), so nobody edits main.swift after WP0.
let knownSuites = ["checkin", "presence", "memory", "presenter", "integration"]

func runSuite(_ name: String) -> Bool {
    guard let handle = dlopen(nil, RTLD_NOW), let sym = dlsym(handle, "synctest_suite_\(name)") else { return false }
    let entry = unsafeBitCast(sym, to: (@convention(c) () -> Void).self)
    entry()
    return true
}

/// Proves the lookup works (`SCENARIOS=selftest`).
@_cdecl("synctest_suite_selftest")
public func synctestSuiteSelftest() {
    let r = runV2(ScenarioV2(name: "selftest", startAt: 120, rate: 1, noise: 0.01, seconds: 60))
    print("Selftest: V2 runner lock@\(r.lockAfter.map { String(format: "%.0f", $0) } ?? "never") err \(r.error.map { String(format: "%+.2f", $0) } ?? "-") correlations \(r.correlations) samples \(r.errorSamples)")
}

func pad(_ v: String, _ n: Int) -> String { String(repeating: " ", count: max(0, n - v.count)) + v }
