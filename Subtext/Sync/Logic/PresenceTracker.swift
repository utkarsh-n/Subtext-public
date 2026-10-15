import Foundation

// The audio latch (docs/v2/latch.md §4, §7; critique C4/C5/C12/C13, D5). Foundation only.
//
// `PresenceTracker` answers one question every tick: is film content reaching the microphone?
// It turns the per-hop features of `ContentPresenceAnalyzer` plus the VAD speech bins and the
// subtitle prior into one of four pieces of evidence (present / absent / hold / none), runs
// the hold-with-hysteresis state machine, owns the quiet-seconds kill clock, and emits events
// for the scheduler: `held` (freeze the clock at onset − 0.5 s), `released` (sound is back;
// the scheduler runs `quickCheck` for tier A or probes), `warn` / `clearWarning` / `end`.
// It never touches a clock: `clockMedia` is only read to stamp `frozenMedia`.
//
// Cadence: the engine calls `analyse` every `presenceEveryTicks` (2) ticks while the latch is
// playing / suspect and on every 1 Hz tick otherwise (`wantsEveryTick`), so a release lands
// within one second of the sound coming back.

final class PresenceTracker {
    typealias Tuning = SyncTracker.Tuning

    /// What one tick feeds the latch.
    ///
    /// TODO(WP7) construction in `SyncEngine` on `analysisQueue` (the harness does exactly this in
    /// `Tools/synctest/ScenariosPresence.swift`, `runPresence`):
    ///   frames/framesStart   ← presenceRing.latest(seconds: presence.framesSecondsWanted)
    ///   hopSeconds           ← analyzer.hopSeconds
    ///   speechBins/binsStart ← ring.latest(seconds: tuning.presenceWindowSeconds)   (MicRing)
    ///   expectedPerSecond    ← tracker.state ∈ {locked, drifting}: for k in 0..<4,
    ///                          tracker.expectedSpeechFraction(from: lock.mediaTime(at: now−4+k),
    ///                                                         to: lock.mediaTime(at: now−3+k)); else nil
    ///   tracking             ← the last analyse/probe/check-in on audio ≤ 2 s old was a hit
    ///   trackerState/Confirmed ← tracker.state, tracker.lock?.confirmed ?? false
    ///   everLocked           ← tracker.lastConfirmedLockWall != nil
    ///   clockMedia           ← a snapshot of the display clock (SessionController.clock) read on
    ///                          the main actor before the tick; only `frozenMedia` is derived from it.
    /// Events → scheduler: .held(at:) → presenceHeld(at:now:); .released → tracker.quickCheck on
    /// ring audio since `returnWall` → presenceReleased(at:quickCheck:now:) (nil while < 4 s);
    /// features.evidence → presenceEvidence; .warn/.end → presenceWarn/presenceEnd.
    struct Input {
        /// The last `framesSecondsWanted` (12 s) of presence frames, oldest first.
        var frames: [PresenceFrame]
        /// Wall time of `frames[0]`.
        var framesStart: Date
        var hopSeconds: Double
        /// 10 ms VAD speech bins covering (at least) the last `presenceWindowSeconds`.
        var speechBins: [Float]
        /// Wall time of `speechBins[0]`.
        var binsStart: Date
        /// Expected speech fraction of the track for each 1 s slot ending at `now`, oldest
        /// first (as many as `presenceWindowSeconds`); nil unless the tracker is locked / drifting.
        var expectedPerSecond: [Double]?
        /// This tick's tracker agreement (a track / probe / check-in hit on recent audio).
        var tracking: Bool
        var trackerState: SyncTracker.State
        var trackerConfirmed: Bool
        /// `tracker.lastConfirmedLockWall != nil`.
        var everLocked: Bool
        var now: Date
        /// `ContentPresenceAnalyzer.validBands`: bands above Nyquist are excluded from every
        /// profile distance (latch.md §2.1; Bluetooth 8/16 kHz inputs).
        var validBands = SIMD8<Float>(repeating: 1)
    }

    enum Event: Sendable, Equatable {
        /// Freeze the display clock at `at` (= quiet onset − `onsetLeadSeconds`); `frozenMedia`
        /// is the clock's media time at that instant (`SessionAction.holdClock(at:reason: .auto)`).
        case held(frozenMedia: Double, at: Date)
        /// Sound is back. The clock stays frozen until the scheduler decides: tier A
        /// (`quickCheck` on audio after `returnWall` passes → `resumedOptimistically`) or probing.
        case released(frozenMedia: Double, pausedWall: Date, returnWall: Date)
        case warn(endsAt: Date)
        case clearWarning
        case end(EndReason)
    }

    struct Report: Sendable {
        let state: PresenceState
        let features: PresenceFeatures
        let flatness: Float
        /// The adaptive floor the features are measured against (nil until 1 s of hops).
        let floorDb: Float?
        let events: [Event]
        let quietSeconds: Double
        let dialogueMissing: Bool
        let contentAbsent: Bool
        let note: String
    }

    var tuning: Tuning
    var patience: AutoPausePatience = .normal
    /// Kill clock; nil = never.
    var autoKill: TimeInterval? = 20 * 60
    var treatMusicAsContent = true
    /// Off: the latch still runs (state, kill clock, status) but emits no `held`, and therefore
    /// no `released` either (`released` only ever follows a `held` of the same pause).
    var autoPauseEnabled = true

    private(set) var state: PresenceState = .playing
    private(set) var quietSeconds: Double = 0
    private(set) var tvSpeech = BandProfile()
    private(set) var tvGap = BandProfile()
    private(set) var roomOnly = BandProfile()
    private(set) var floorDb: Float?
    private(set) var sessionMinFloorDb: Float?
    private(set) var lastFeatures: PresenceFeatures?
    private(set) var lastEvidence: PresenceEvidence = .none
    /// Set once the two profiles are ready but never separate (|Δtv − Δroom| < 0.5 for 2 min
    /// of confirmed lock): distances are then ignored (latch.md, unverified items).
    private(set) var profilesUninformative = false

    // Floor: rolling 10th percentile of speechDb over the last 60 s of admitted hops.
    private var floorHistory: [Float] = []
    private var floorWrite = 0
    private var floorFilled = 0
    private var lastAdmittedSampleIndex = -1
    /// Newest hop seen above floor + absentPeakDb (the content-stopped instant is the next hop).
    private var lastLoudWall: Date?
    private var lastScannedSampleIndex = -1
    private var sessionStart: Date?
    private var lastNow: Date?
    // Flags.
    private var absentTicks = 0
    /// Consecutive music-like ticks (music-is-not-content needs persistence: a 4 s dialogue
    /// window's modulation ratio dips below 0.30 about one tick in five).
    private var musicLikeTicks = 0
    private var ledger: [(end: Date, expected: Bool, heard: Bool)] = []
    /// Newest slot's expected-dialogue value (the suspicion trigger).
    private var expectedNow: Double?
    private var dialogueMissing = false
    private var contentAbsent = false
    // Room profile learning.
    private var quietRunSeconds = 0.0
    private var learnRoomUntil: Date?
    private var roomRefreshPending = false
    private var uninformativeSeconds = 0.0
    private var userHeld = false
    private var nonPlayingSince: Date?
    /// The instant the latch confirmed the current pause (kept across `ending`, whose
    /// `PresenceState` case carries only `endsAt`); hypothesis C needs it on release.
    private var pausedWall: Date?
    /// A `held` was emitted for the current pause; `released` is only emitted after one, so the
    /// scheduler never sees a release for a clock it did not hold (never-locked sessions, auto-pause off).
    private var holdEmitted = false
    private var pendingEvents: [Event] = []

    /// Measured in the harness (Tools/synctest ScenariosPresence, DEBUG trace over noise
    /// 0.01 / 0.03 / 0.08): room-only flux spread Fx has p95 2.1–2.2 dB and max 2.5 dB at every
    /// noise level (it is level-independent), film dialogue ≥ 7.3 dB (p50 at noise 0.08). WP0's
    /// placeholder 1.5 dB sits below the room median (1.8 dB), so `absent` could only fire on
    /// lucky ticks. TODO(WP7): move into `SyncTracker.Tuning.absentFluxDb` when Tuning is frozen.
    static let measuredAbsentFluxDb: Float = 3.0

    init(tuning: Tuning = Tuning()) {
        var t = tuning
        if t.absentFluxDb == 1.5 { t.absentFluxDb = Self.measuredAbsentFluxDb }
        self.tuning = t
    }

    /// Seconds of `PresenceFrame`s to hand to `analyse` (window plus the onset look-back).
    var framesSecondsWanted: Double { max(tuning.presenceWindowSeconds, Self.onsetLookbackSeconds) }
    static let onsetLookbackSeconds = 12.0

    /// True while the latch is not playing / suspect: call `analyse` on every 1 Hz tick.
    var wantsEveryTick: Bool {
        if case .playing = state { return false }
        return true
    }

    private var confirmDialogueSeconds: Double {
        patience == .normal ? tuning.confirmDialogueSeconds : tuning.confirmDialogueSeconds * 2
    }

    private var confirmAbsentSeconds: Double {
        patience == .normal ? tuning.confirmAbsentSeconds : tuning.confirmAbsentSeconds * 2
    }

    /// Kill clock after the never-locked extension (scaled with the kill clock so harness
    /// overrides keep the ratio): nil = never.
    private func killAfter(everLocked: Bool) -> Double? {
        guard let k = autoKill, k > 0 else { return nil }
        if everLocked { return k }
        return k + tuning.neverLockedExtraSeconds * (k / (20 * 60))
    }

    // MARK: - Modulation

    /// Share of the amplitude-modulation spectrum of a dB envelope that lies in the syllabic
    /// 2–10 Hz band: mean removed, Hann, zero-padded to 128 points. 0 for a constant envelope.
    static func modulationRatio(_ speechDb: [Float], hopRate: Double) -> Float {
        let n = speechDb.count
        guard n >= 8, hopRate > 0 else { return 0 }
        var mean: Float = 0
        for v in speechDb { mean += v }
        mean /= Float(n)
        var x = [Float](repeating: 0, count: n)
        var energy: Float = 0
        for i in 0..<n {
            let w = 0.5 - 0.5 * cos(2 * Float.pi * Float(i) / Float(n - 1))
            x[i] = (speechDb[i] - mean) * w
            energy += x[i] * x[i]
        }
        guard energy > 1e-6 else { return 0 }
        var npad = 128
        while npad < n { npad *= 2 }
        let binHz = hopRate / Double(npad)
        var band: Float = 0, total: Float = 0
        let twoPiOverN = 2 * Float.pi / Float(npad)
        for k in 1...(npad / 2) {
            let f = Double(k) * binHz
            guard f >= 0.37, f <= 11.7 else { continue }
            var re: Float = 0, im: Float = 0
            let step = twoPiOverN * Float(k)
            for i in 0..<n {
                let a = step * Float(i)
                re += x[i] * cos(a)
                im -= x[i] * sin(a)
            }
            let p = re * re + im * im
            total += p
            if f >= 2, f <= 10 { band += p }
        }
        guard total > 1e-9 else { return 0 }
        return band / total
    }

    // MARK: - Tick

    func analyse(_ input: Input, clockMedia: (Date) -> Double) -> Report {
        var events = pendingEvents
        pendingEvents = []
        let now = input.now
        if sessionStart == nil { sessionStart = now }
        let dt = lastNow.map { max(0, now.timeIntervalSince($0)) } ?? 0
        lastNow = now
        let hop = Float(input.hopSeconds)
        let hopRate = 1 / max(input.hopSeconds, 1e-4)
        let windowHops = max(1, Int((tuning.presenceWindowSeconds / max(input.hopSeconds, 1e-4)).rounded()))
        let window = Array(input.frames.suffix(windowHops))
        if tvSpeech.validBands != input.validBands {
            tvSpeech.validBands = input.validBands
            tvGap.validBands = input.validBands
            roomOnly.validBands = input.validBands
        }

        // 1. Floor history: admit new hops unless the previous tick saw content while playing.
        let bootstrapping = now.timeIntervalSince(sessionStart ?? now) < tuning.roomBootstrapSeconds + tuning.presenceWindowSeconds
        let playingLike: Bool
        switch state {
        case .playing, .suspect, .resuming: playingLike = true
        default: playingLike = false
        }
        let admit = bootstrapping || !(playingLike && lastEvidence == .present)
        if admit {
            if floorHistory.isEmpty {
                floorHistory = [Float](repeating: 0, count: max(16, Int(tuning.presenceFloorSeconds / max(input.hopSeconds, 1e-4))))
            }
            for f in input.frames where f.sampleIndex > lastAdmittedSampleIndex {
                floorHistory[floorWrite] = f.speechDb
                floorWrite = (floorWrite + 1) % floorHistory.count
                floorFilled = min(floorHistory.count, floorFilled + 1)
                lastAdmittedSampleIndex = f.sampleIndex
            }
        } else if let last = input.frames.last {
            lastAdmittedSampleIndex = max(lastAdmittedSampleIndex, last.sampleIndex)
        }
        if floorFilled >= max(8, Int(1 / max(input.hopSeconds, 1e-4))) {
            let recent = floorFilled == floorHistory.count ? floorHistory : Array(floorHistory[0..<floorFilled])
            let sorted = recent.sorted()
            let idx = min(sorted.count - 1, max(0, Int(Double(sorted.count) * tuning.presenceFloorPercentile)))
            floorDb = sorted[idx]
            sessionMinFloorDb = min(sessionMinFloorDb ?? sorted[idx], sorted[idx])
        }
        let floor = floorDb ?? (window.map(\.speechDb).min() ?? -60)
        scanLoudHops(input: input, floor: floor)

        // 2. Window features.
        var f = PresenceFeatures()
        var flatness: Float = 1
        if !window.isEmpty {
            let s = window.map(\.speechDb)
            let sorted = s.sorted()
            let median = sorted[sorted.count / 2]
            let p90 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))]
            let mean = s.reduce(0, +) / Float(s.count)
            var varAcc: Float = 0
            for v in s { varAcc += (v - mean) * (v - mean) }
            let depth = (varAcc / Float(s.count)).squareRoot()
            f.level = median - floor
            f.peak = p90 - floor
            f.depth = depth
            f.modRatio = depth >= tuning.musicDepthDb ? Self.modulationRatio(Array(s.suffix(96)), hopRate: hopRate) : 0
            let fx = window.map(\.flux)
            let fxMean = fx.reduce(0, +) / Float(fx.count)
            var fxVar: Float = 0
            for v in fx { fxVar += (v - fxMean) * (v - fxMean) }
            f.fluxSpread = (fxVar / Float(fx.count)).squareRoot()
            flatness = window.map(\.flatness).reduce(0, +) / Float(window.count)
        }
        f.speechFraction = input.speechBins.isEmpty ? 0 : Float(input.speechBins.filter { $0 == 1 }.count) / Float(input.speechBins.count)
        if let e = input.expectedPerSecond, !e.isEmpty { f.expectedDialogue = e.reduce(0, +) / Double(e.count) }
        // Profile distances (mean over the window's hops), only when ready and informative.
        let tvReady = tvSpeech.isReady(hopSeconds: hop) || tvGap.isReady(hopSeconds: hop)
        let roomReady = roomOnly.isReady(hopSeconds: hop)
        if !window.isEmpty, !profilesUninformative {
            if tvReady {
                var acc: Float = 0
                for fr in window {
                    var d = Float.greatestFiniteMagnitude
                    if tvSpeech.isReady(hopSeconds: hop) { d = min(d, tvSpeech.distance(to: fr.bandDb)) }
                    if tvGap.isReady(hopSeconds: hop) { d = min(d, tvGap.distance(to: fr.bandDb)) }
                    acc += d
                }
                f.tvDistance = acc / Float(window.count)
            }
            if roomReady {
                var acc: Float = 0
                for fr in window { acc += roomOnly.distance(to: fr.bandDb) }
                f.roomDistance = acc / Float(window.count)
            }
            if let tv = f.tvDistance, let room = f.roomDistance, input.trackerState == .locked, input.trackerConfirmed {
                if abs(tv - room) < 0.5 { uninformativeSeconds += dt } else { uninformativeSeconds = 0 }
                if uninformativeSeconds >= 120 { profilesUninformative = true; f.tvDistance = nil; f.roomDistance = nil }
            }
        }

        // 3. Evidence (latch.md §4.1; absent takes precedence, then present, hold, none).
        let tracking = input.tracking
        let L = f.level, Lmax = f.peak, D = f.depth, M = f.modRatio, V = f.speechFraction, Fx = f.fluxSpread
        let dTv = f.tvDistance, dRoom = f.roomDistance
        let speechLike = V >= tuning.holdSpeechFraction && M >= tuning.holdModRatio
        let musicLike = D >= tuning.musicDepthDb && M < tuning.musicModRatioMax && flatness < tuning.musicFlatnessMax
        var absent = L <= tuning.absentLevelDb && Lmax <= tuning.absentPeakDb && D < tuning.absentDepthDb && Fx < tuning.absentFluxDb
            && (dRoom == nil || dRoom! <= tuning.absentRoomDistance) && (dTv == nil || dTv! >= tuning.absentTvDistance)
        var musicAbsent = false
        musicLikeTicks = musicLike && !speechLike ? musicLikeTicks + 1 : 0
        if !treatMusicAsContent, musicLikeTicks >= 3, !absent { absent = true; musicAbsent = true } // music is not content: the latch idles
        var present = false
        if !absent {
            // Tracker agreement is evidence only while speech is actually being heard: the
            // tracking window is 20–60 s long and keeps correlating for a while after the TV
            // goes silent (measured in the harness: ~30 s with the V1 60 s window).
            present = (tracking && V >= tuning.holdSpeechFraction)
                || (D >= tuning.presentDepthDb && Fx >= tuning.presentFluxDb && (dTv == nil || dTv! <= tuning.presentTvDistance))
                || (Lmax >= tuning.presentPeakDb && dTv != nil && dRoom != nil && dTv! + 1 < dRoom!)
                || (treatMusicAsContent && musicLike && (dTv == nil || dTv! <= 2.5))
            if present, speechLike, !tracking { present = false } // speech not attributed to the film is a hold
        }
        var evidence: PresenceEvidence = .none
        if absent { evidence = .absent }
        else if present { evidence = .present }
        else if (speechLike && !tracking) || Lmax >= tuning.presentPeakDb { evidence = .hold }
        f.evidence = evidence
        lastEvidence = evidence
        lastFeatures = f

        // 4. Flags. Expected silence (locked, the track says no dialogue over the window) is not
        // track-independent pause evidence: the next due cue decides, via dialogueMissing
        // (latch.md decision 10: the track is a prior; a montage makes the latch patient).
        let expectedQuiet = input.trackerState == .locked && input.trackerConfirmed && (f.expectedDialogue ?? 1) < 0.1
        switch evidence {
        case .absent:
            if !expectedQuiet || musicAbsent { absentTicks += 1 }
        case .present: absentTicks = 0
        case .hold, .none: break
        }
        contentAbsent = absentTicks >= tuning.absentTicksToConfirm
        updateLedger(input: input, musicLike: musicLike, dt: dt)

        // 5. Profiles.
        learnProfiles(input: input, window: window, floor: floor, features: f, musicLike: musicLike, dt: dt, now: now)

        // 6. State machine.
        var note = ""
        let holdEvidence = evidence == .present || evidence == .hold
        let quietEvidence = evidence == .absent || evidence == .none
        let kill = killAfter(everLocked: input.everLocked)
        let endReason: EndReason = input.everLocked ? .silence(minutes: Int(((autoKill ?? 0) / 60).rounded())) : .neverHeard

        switch state {
        case .playing, .resuming:
            if tracking { quietSeconds = 0 }
            // Suspicion (no UI change): the two confirmed flags, or a first absent tick, or dialogue
            // expected right now and nothing heard. From here the latch runs at 1 Hz until it decides.
            let dialogueUnheard = (expectedNow ?? 0) >= 0.5 && !holdEvidence
            if dialogueMissing || contentAbsent || absentTicks >= 1 || dialogueUnheard {
                let onset = quietOnset(input: input, floor: floor, now: now)
                state = .suspect(since: onset)
                note = (dialogueMissing ? "suspect: dialogue expected, nothing heard" : "suspect: room only")
                    + String(format: " (onset −%.1f s, floor %.1f dB)", now.timeIntervalSince(onset), floor)
            }
        case .suspect(let since):
            if holdEvidence {
                state = .playing
                holdEmitted = false
                absentTicks = 0
                dialogueMissing = false
                contentAbsent = false
                note = "content back, not a pause"
            } else {
                let quietFor = now.timeIntervalSince(since)
                let byDialogue = dialogueMissing && quietFor >= confirmDialogueSeconds
                let byAbsent = contentAbsent && evidence == .absent && (!expectedQuiet || musicAbsent) && quietFor >= confirmAbsentSeconds
                if byDialogue || byAbsent {
                    let freezeAt = since.addingTimeInterval(-tuning.onsetLeadSeconds)
                    let frozen = clockMedia(freezeAt)
                    state = .paused(frozenMedia: frozen, since: now)
                    pausedWall = now
                    quietSeconds = max(quietSeconds, quietFor) // the whole suspect stretch was quiet
                    roomRefreshPending = true
                    // A hold is emitted only when there is a clock to freeze: the tracker is locked,
                    // drifting or running an unconfirmed candidate (a seed also sets `.locked`, and an
                    // optimistic tier-A resume runs the clock from a candidate; latch.md §4.5). Before
                    // the first lock the latch still goes `paused` so the never-locked kill clock runs (§7).
                    let holdable = input.trackerState == .locked || input.trackerState == .drifting || input.trackerState == .candidate
                    if holdable, autoPauseEnabled || userHeld {
                        events.append(.held(frozenMedia: frozen, at: freezeAt))
                        holdEmitted = true
                    }
                    note = byDialogue ? "paused (dialogue missing \(Int(quietFor)) s)" : "paused (room only \(Int(quietFor)) s)"
                } else {
                    note = "suspect \(Int(quietFor)) s"
                }
            }
        case .paused(let frozen, let since):
            if holdEvidence {
                let back = returnWall(input: input, floor: floor, window: window, now: now)
                state = .probing(frozenMedia: frozen, pausedWall: since, since: now)
                if holdEmitted { events.append(.released(frozenMedia: frozen, pausedWall: since, returnWall: back)) }
                absentTicks = 0
                note = evidence == .present ? "sound is back" : "hearing something, not yet the film"
            } else {
                if quietEvidence { quietSeconds += dt }
                if let kill, quietSeconds >= kill - tuning.warnBeforeSeconds {
                    let endsAt = now.addingTimeInterval(max(0, kill - quietSeconds))
                    state = .ending(frozenMedia: frozen, endsAt: endsAt)
                    events.append(.warn(endsAt: endsAt))
                    note = "ending soon"
                } else {
                    note = "paused, quiet \(Int(quietSeconds)) s"
                }
            }
        case .probing(let frozen, let pausedWall, _):
            if evidence == .absent, absentTicks >= tuning.absentTicksToConfirm {
                state = .paused(frozenMedia: frozen, since: pausedWall)
                note = "quiet again"
            } else {
                note = "probing"
            }
        case .ending(let frozen, let endsAt):
            if holdEvidence {
                let back = returnWall(input: input, floor: floor, window: window, now: now)
                let since = pausedWall ?? endsAt
                state = .probing(frozenMedia: frozen, pausedWall: since, since: now)
                events.append(.clearWarning)
                if holdEmitted { events.append(.released(frozenMedia: frozen, pausedWall: since, returnWall: back)) }
                absentTicks = 0
                note = "sound is back"
            } else {
                if quietEvidence { quietSeconds += dt }
                if let kill, quietSeconds >= kill {
                    state = .ended(reason: endReason)
                    events.append(.end(endReason))
                    note = "ended"
                } else {
                    note = "ending in \(Int(max(0, endsAt.timeIntervalSince(now)))) s"
                }
            }
        case .ended:
            note = "ended"
        }
        // The user's own pause keeps the quiet clock running (critique D5, C decision 6).
        if userHeld, quietEvidence {
            switch state {
            case .paused, .ending, .ended: break
            default: quietSeconds += dt
            }
        }
        // Never-locked sessions: non-playing for the extended kill clock → ended, whatever the chatter.
        if case .playing = state { nonPlayingSince = nil } else if nonPlayingSince == nil { nonPlayingSince = now }
        if !input.everLocked, let kill, let since = nonPlayingSince, now.timeIntervalSince(since) >= kill {
            switch state {
            case .ended: break
            default:
                state = .ended(reason: .neverHeard)
                events.append(.end(.neverHeard))
                note = "ended: never heard the film"
            }
        }
        return Report(state: state, features: f, flatness: flatness, floorDb: floorDb, events: events, quietSeconds: quietSeconds,
                      dialogueMissing: dialogueMissing, contentAbsent: contentAbsent, note: note)
    }

    // MARK: - Scheduler and user calls

    /// Scheduler: `quickCheck` on post-release audio agreed with hypothesis P → the clock runs.
    func resumedOptimistically(at wall: Date) {
        if case .probing(let frozen, let pausedWall, _) = state {
            state = .resuming(frozenMedia: frozen, pausedWall: pausedWall)
        }
    }

    /// Scheduler accepted a position (any tier) → playing; the quiet clock resets.
    func reacquired(at wall: Date) {
        state = .playing
        holdEmitted = false
        quietSeconds = 0
        absentTicks = 0
        dialogueMissing = false
        contentAbsent = false
        ledger.removeAll()
        nonPlayingSince = nil
    }

    /// Scheduler: the optimistic resume was not confirmed → probing (the clock is its business).
    func resumeFailed(at wall: Date) {
        if case .resuming(let frozen, let pausedWall) = state {
            state = .probing(frozenMedia: frozen, pausedWall: pausedWall, since: wall)
        }
    }

    /// Island Play / Resume while auto-paused: the user asserts hypothesis P.
    func userResumed(at wall: Date) {
        userHeld = false
        switch state {
        case .paused(let frozen, let pausedWall), .probing(let frozen, let pausedWall, _):
            state = .resuming(frozenMedia: frozen, pausedWall: pausedWall)
        case .ending(let frozen, let endsAt):
            state = .resuming(frozenMedia: frozen, pausedWall: pausedWall ?? endsAt)
            pendingEvents.append(.clearWarning)
        default: break
        }
        quietSeconds = 0
    }

    /// Manual pause: the latch's hold / release are ignored by the controller while the user
    /// holds; the quiet clock still counts (the user asked silence to end the session).
    func userPaused(at wall: Date) {
        userHeld = true
    }

    /// Any island button: resets the quiet clock, clears a warning.
    @discardableResult
    func userTouched(at wall: Date) -> [Event] {
        quietSeconds = 0
        if case .ending(let frozen, let endsAt) = state {
            state = .paused(frozenMedia: frozen, since: pausedWall ?? endsAt)
            return [.clearWarning]
        }
        return []
    }

    /// KeepListening: quiet clock back to 0; the warning is withdrawn.
    @discardableResult
    func extend(at wall: Date) -> [Event] {
        quietSeconds = 0
        nonPlayingSince = wall
        if case .ending(let frozen, _) = state {
            state = .paused(frozenMedia: frozen, since: pausedWall ?? wall)
            return [.clearWarning]
        }
        return []
    }

    /// "Learn this room": the next `seconds` of hops go into `roomOnly` whatever they look like.
    func learnRoom(seconds: Double, at wall: Date = .now) {
        learnRoomUntil = wall.addingTimeInterval(seconds)
    }

    // MARK: - Internals

    /// Earliest instant the content stopped: the last hop in the look-back above the floor by
    /// `absentPeakDb`, plus one hop; the look-back start when nothing in it was above.
    /// Earliest instant the content stopped: one hop after the newest hop seen above the floor
    /// by `absentPeakDb`. Tracked incrementally over every hop (`scanLoudHops`), so it is not
    /// limited to the frames handed to this tick; clamped to the last 10 min and to `now`.
    private func quietOnset(input: Input, floor: Float, now: Date) -> Date {
        let hop = input.hopSeconds
        guard let loud = lastLoudWall else { return input.framesStart }
        return min(now, max(now.addingTimeInterval(-600), loud.addingTimeInterval(hop)))
    }

    /// Advances `lastLoudWall` over the hops not scanned yet.
    private func scanLoudHops(input: Input, floor: Float) {
        let hop = input.hopSeconds
        let base = input.frames.first?.sampleIndex ?? 0
        for fr in input.frames where fr.sampleIndex > lastScannedSampleIndex {
            if fr.speechDb > floor + tuning.absentPeakDb {
                lastLoudWall = input.framesStart.addingTimeInterval(Double(fr.sampleIndex - base) / Double(ContentPresenceAnalyzer.hop) * hop)
            }
        }
        if let last = input.frames.last { lastScannedSampleIndex = max(lastScannedSampleIndex, last.sampleIndex) }
    }

    /// First hop in the window that rose above the floor by `presentPeakDb` and stayed up:
    /// at least half of the following second above floor + `absentPeakDb` (a single noise hop
    /// over the floor is not a return).
    private func returnWall(input: Input, floor: Float, window: [PresenceFrame], now: Date) -> Date {
        let hop = input.hopSeconds
        let base = input.frames.first?.sampleIndex ?? 0
        let second = max(1, Int((1 / max(hop, 1e-4)).rounded()))
        for (i, fr) in window.enumerated() where fr.speechDb > floor + tuning.presentPeakDb {
            let rest = window[i..<min(window.count, i + second)]
            let up = rest.filter { $0.speechDb > floor + tuning.absentPeakDb }.count
            if up * 2 >= rest.count {
                return input.framesStart.addingTimeInterval(Double(fr.sampleIndex - base) / Double(ContentPresenceAnalyzer.hop) * hop)
            }
        }
        return now.addingTimeInterval(-tuning.presenceWindowSeconds)
    }

    /// Sliding 8 s ledger of 1 s slots {expected cue on, heard speech}; fires when ≥ 4 s were
    /// expected and ≥ 75 % of them went unheard; clears when the last 2 s contain ≥ 1 s heard.
    private func updateLedger(input: Input, musicLike: Bool, dt: Double) {
        let slots = max(0, min(Int(dt.rounded()), Int(tuning.presenceWindowSeconds)))
        guard slots > 0 else { return }
        let binsPerSlot = Int((1 / SpeechEnvelope.binDuration).rounded())
        for k in 0..<slots {
            // Slot k counted from the oldest of the `slots` newest.
            let slotEnd = input.now.addingTimeInterval(-Double(slots - 1 - k))
            let slotStart = slotEnd.addingTimeInterval(-1)
            var heard = false
            if !input.speechBins.isEmpty {
                let b0 = Int(slotStart.timeIntervalSince(input.binsStart) / SpeechEnvelope.binDuration)
                let lo = max(0, b0), hi = min(input.speechBins.count, b0 + binsPerSlot)
                if hi > lo {
                    var speech = 0
                    for i in lo..<hi where input.speechBins[i] == 1 { speech += 1 }
                    heard = Double(speech) / Double(hi - lo) >= 0.2
                }
            }
            if !treatMusicAsContent, musicLike { heard = false }
            var expected = false
            if let e = input.expectedPerSecond, !e.isEmpty {
                let idx = e.count - slots + k
                if idx >= 0, idx < e.count { expected = e[idx] >= 0.5 }
            }
            ledger.append((slotEnd, expected, heard))
        }
        let keep = Int(tuning.ledgerSeconds)
        if ledger.count > keep { ledger.removeFirst(ledger.count - keep) }
        expectedNow = input.expectedPerSecond?.last
        guard input.expectedPerSecond != nil else { dialogueMissing = false; return }
        // Slots that ended before the content stopped carry no information about a pause, so the
        // ratio runs over the slots after the last loud hop (the sliding 8 s ledger still bounds it).
        let onset = lastLoudWall ?? .distantPast
        let since = ledger.filter { $0.end.timeIntervalSince(onset) >= 1 }
        let expected = since.filter(\.expected).count
        let missed = since.filter { $0.expected && !$0.heard }.count
        let recentHeard = ledger.suffix(2).filter(\.heard).count
        if recentHeard >= 1 { dialogueMissing = false }
        else if Double(expected) >= tuning.minExpectedSeconds, Double(missed) / Double(max(1, expected)) >= tuning.missedExpectedRatio { dialogueMissing = true }
    }

    private func learnProfiles(input: Input, window: [PresenceFrame], floor: Float, features f: PresenceFeatures, musicLike: Bool, dt: Double, now: Date) {
        let hop = Float(input.hopSeconds)
        guard !window.isEmpty else { return }
        // Only the hops newer than the previous tick's window.
        let newHops = window.suffix(max(1, min(window.count, Int((dt / max(input.hopSeconds, 1e-4)).rounded()))))
        let base = input.frames.first?.sampleIndex ?? 0
        func wallOf(_ fr: PresenceFrame) -> Date {
            input.framesStart.addingTimeInterval(Double(fr.sampleIndex - base) / Double(ContentPresenceAnalyzer.hop) * input.hopSeconds)
        }
        func vadSpeech(at wall: Date) -> Float? {
            let i = Int(wall.timeIntervalSince(input.binsStart) / SpeechEnvelope.binDuration)
            guard i >= 0, i < input.speechBins.count else { return nil }
            return input.speechBins[i]
        }
        func expected(at wall: Date) -> Double? {
            guard let e = input.expectedPerSecond, !e.isEmpty else { return nil }
            let back = now.timeIntervalSince(wall)
            let idx = e.count - 1 - Int(back.rounded(.down))
            guard idx >= 0, idx < e.count else { return nil }
            return e[idx]
        }
        let locked = input.trackerState == .locked && input.trackerConfirmed
        if locked, f.evidence == .present || f.evidence == .hold {
            for fr in newHops {
                let w = wallOf(fr)
                guard let v = vadSpeech(at: w), let e = expected(at: w) else { continue }
                if v == 1, e >= 0.9 { tvSpeech.add(fr.bandDb, hopSeconds: hop) }
                else if v == 0, e <= 0.0, fr.speechDb - floor >= 4 { tvGap.add(fr.bandDb, hopSeconds: hop) }
            }
        }
        // Room-only: 10 s of quiet, stationary, near-floor audio; the first 3 s of the session;
        // the first quiet stretch after a confirmed auto-pause; a manual capture.
        let quiet = f.depth < 2.5 && f.fluxSpread < 1.5 && f.level < 4
        if quiet { quietRunSeconds += dt } else { quietRunSeconds = 0 }
        let sinceStart = now.timeIntervalSince(sessionStart ?? now)
        var learn = false
        if sinceStart <= tuning.roomBootstrapSeconds + tuning.presenceWindowSeconds, f.evidence != .present { learn = true }
        if quietRunSeconds >= tuning.roomLearnSeconds { learn = true }
        if roomRefreshPending, f.evidence == .absent {
            if case .paused = state { learn = true; roomRefreshPending = false }
        }
        if let until = learnRoomUntil {
            if now <= until { learn = true } else { learnRoomUntil = nil }
        }
        if learn { for fr in newHops { roomOnly.add(fr.bandDb, hopSeconds: hop) } }
    }
}

// MARK: - Trace writer (`-traceFeatures`)

/// Per-tick CSV of the presence features, the same columns as the harness's `DEBUG=1` line, so
/// real-room values (TV playing / paused / muted / people talking) can be compared with harness
/// values before `Tuning` is frozen (latch.md decision 9). Pure Foundation; the engine opens it
/// under `-traceFeatures` (DEBUG) in WP7 and the harness writes one for a scenario.
final class PresenceTraceWriter {
    static let header = "t,L,Lmax,D,M,V,Fx,flat,dTv,dRoom,E,evidence,state,quiet,dialogueMissing,contentAbsent,clock,truth"
    private let handle: FileHandle
    private var pending: [String] = []

    init?(url: URL) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: url) else { return nil }
        handle = h
        pending.append(Self.header)
    }

    func append(t: Double, report: PresenceTracker.Report, clock: Double?, truth: Double?) {
        let f = report.features
        func s(_ v: Float?) -> String { v.map { String(format: "%.2f", $0) } ?? "" }
        func d(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "" }
        let line = [String(format: "%.1f", t), s(f.level), s(f.peak), s(f.depth), s(f.modRatio), s(f.speechFraction), s(f.fluxSpread),
                    s(report.flatness), s(f.tvDistance), s(f.roomDistance), d(f.expectedDialogue), "\(f.evidence)",
                    Self.label(report.state), String(format: "%.0f", report.quietSeconds),
                    report.dialogueMissing ? "1" : "0", report.contentAbsent ? "1" : "0", d(clock), d(truth)].joined(separator: ",")
        pending.append(line)
        if pending.count >= 32 { flush() }
    }

    static func label(_ state: PresenceState) -> String {
        switch state {
        case .playing: "playing"
        case .suspect: "suspect"
        case .paused: "paused"
        case .resuming: "resuming"
        case .probing: "probing"
        case .ending: "ending"
        case .ended: "ended"
        }
    }

    func flush() {
        guard !pending.isEmpty else { return }
        let text = pending.joined(separator: "\n") + "\n"
        pending.removeAll()
        if let data = text.data(using: .utf8) { handle.write(data) }
    }

    func close() {
        flush()
        try? handle.close()
    }
}
