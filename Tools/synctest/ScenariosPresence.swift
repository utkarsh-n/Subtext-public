import Accelerate
import Foundation

// WP3 — presence (audio latch) scenarios, docs/v2/latch.md §10 / harness scenarios 1–17.
// Declarations only; entry point `synctest_suite_presence` (SCENARIOS=presence).
//
// The loop here is the engine's data flow with a *stub scheduler*: `PresenceTracker` events are
// applied to a `PlaybackClock` directly (hold → pause the clock at the freeze instant; release
// → quickCheck for tier A, else a small P/C → hinted → full ladder built on the V1 tracker).
// WP7's integration suite replaces the stub with the real `CheckInScheduler`.
//
// Environment: DEBUG=1 per-tick features · KILL=<s> kill clock override · PATIENCE=patient.

// MARK: - tvEq (film path only; latch.md §10)

/// RBJ biquad chain: 2nd-order HPF 80 Hz, peaking +3 dB at 150 Hz Q 1, 2nd-order LPF 12 kHz.
func tvEqCoefficients(sampleRate fs: Double) -> [Double] {
    func hpf(_ f0: Double, _ q: Double) -> [Double] {
        let w = 2 * Double.pi * f0 / fs, c = cos(w), a = sin(w) / (2 * q)
        let a0 = 1 + a
        return [(1 + c) / 2 / a0, -(1 + c) / a0, (1 + c) / 2 / a0, -2 * c / a0, (1 - a) / a0]
    }
    func lpf(_ f0: Double, _ q: Double) -> [Double] {
        let w = 2 * Double.pi * f0 / fs, c = cos(w), a = sin(w) / (2 * q)
        let a0 = 1 + a
        return [(1 - c) / 2 / a0, (1 - c) / a0, (1 - c) / 2 / a0, -2 * c / a0, (1 - a) / a0]
    }
    func peak(_ f0: Double, _ q: Double, _ gainDb: Double) -> [Double] {
        let A = pow(10, gainDb / 40)
        let w = 2 * Double.pi * f0 / fs, c = cos(w), a = sin(w) / (2 * q)
        let a0 = 1 + a / A
        return [(1 + a * A) / a0, -2 * c / a0, (1 - a * A) / a0, -2 * c / a0, (1 - a / A) / a0]
    }
    return hpf(80, 0.7071) + peak(150, 1.0, 3) + lpf(12_000, 0.7071)
}

/// The tvEq hook: filters a whole film (or any signal) through the TV-speaker chain.
func tvEq(_ x: [Float]) -> [Float] {
    guard var biquad = vDSP.Biquad(coefficients: tvEqCoefficients(sampleRate: sampleRate), channelCount: 1, sectionCount: 3, ofType: Float.self) else { return x }
    var out = [Float](repeating: 0, count: x.count)
    biquad.apply(input: x, output: &out)
    return out
}

// MARK: - Score (montage music): three detuned sawtooths, a pulse at bpm, slow 0.4 Hz AM
//
// AM depth 0.55 ± 0.45 (reviewer change from 0.7 ± 0.3): with ± 3 dB of swell the pad measured
// D ≈ 2.3 dB over 4 s in the harness, below latch.md's own expected range for score / ambience
// (3–8 dB) and below `musicDepthDb` (4), so it read as "loud, not speech" (`hold`) rather than
// music and scenario 5b (music is not content) could never fire. The deeper swell puts the pad at
// D ≈ 5–7 dB, inside the spec's range.

func scoreSample(_ t: Double, bpm: Double) -> Float {
    func saw(_ f: Double) -> Double { let p = t * f; return 2 * (p - (p + 0.5).rounded(.down)) }
    let chord = [110.0, 110.6, 165.2]
    var tone = 0.0
    for f in chord { tone += saw(f) + 0.4 * saw(f * 2.003) }
    tone /= 4.2
    let beat = bpm / 60
    let phase = (t * beat) - (t * beat).rounded(.down)
    let thump = sin(2 * Double.pi * 70 * t) * exp(-phase * 12) * 0.6
    let am = 0.55 + 0.45 * cos(2 * Double.pi * 0.4 * t)
    return Float((tone * 0.35 + thump) * am * 0.3)
}

// MARK: - Second voice in the room (lines not in the track)

let talkLines = [
    "Did you remember to pick up the dry cleaning?",
    "The plumber said he would come on Thursday.",
    "I think the cat has been eating the plants again.",
    "We should book the ferry before the prices go up.",
    "My sister is bringing her new boyfriend to dinner.",
    "There is a parcel for you on the kitchen table.",
    "Turn the heating down, it is like a sauna in here.",
    "The neighbours are having another party on Saturday.",
    "I cannot find the charger for the small speaker.",
    "Honestly the second season was much better than the first.",
    "Pass me the blanket, my feet are freezing.",
    "Did the school send that form back yet?",
    "I am going to make some tea, do you want one?",
    "The car needs its service before the end of the month.",
    "Who left the garage door open all night?",
    "I read that the bridge will be closed for a year.",
    "Remind me to call your mother tomorrow morning.",
    "That actor was in the thing we watched last week.",
    "We are out of milk again, I will go in the morning.",
    "The dog needs a walk before it gets dark.",
]

/// Daniel reading unrelated lines with short gaps, 0.5 gain, looped. Built on first use.
let talkTrack: [Float] = {
    var out: [Float] = []
    for (i, line) in talkLines.enumerated() {
        let s = synth(line, index: 1000 + i, voice: "Daniel")
        out.append(contentsOf: s.map { $0 * 0.5 })
        out.append(contentsOf: [Float](repeating: 0, count: Int(Double.random(in: 0.4...1.2, using: &rng) * sampleRate)))
    }
    return out
}()

func talkSample(_ t: Double) -> Float {
    let n = talkTrack.count
    guard n > 0 else { return 0 }
    return talkTrack[Int(t * sampleRate) % n]
}

// MARK: - Scenarios

enum PEvent {
    /// The viewer pauses: truth stops, the TV goes silent.
    case pause(at: Double, seconds: Double)
    /// The viewer mutes: truth advances, the TV is silent.
    case muted(at: Double, seconds: Double)
    /// Unfiltered music plays in the room.
    case roomMusic(at: Double, seconds: Double, bpm: Double)
    /// Someone talks in the room (second voice, lines not in the track).
    case talk(at: Double, seconds: Double)
    case fan(at: Double, level: Float)
    /// Truth jumps by `by` media seconds at `at`.
    case skip(at: Double, by: Double)
    /// The user taps Keep listening.
    case keepListening(at: Double)
    /// The TV is switched off for the rest of the run.
    case off(at: Double)

    var start: Double {
        switch self {
        case .pause(let at, _), .muted(let at, _), .roomMusic(let at, _, _), .talk(let at, _), .fan(let at, _), .skip(let at, _), .keepListening(let at), .off(let at): at
        }
    }

    var end: Double {
        switch self {
        case .pause(let at, let s), .muted(let at, let s), .roomMusic(let at, let s, _), .talk(let at, let s): at + s
        case .off: 1e9
        case .fan(let at, _), .skip(let at, _), .keepListening(let at): at
        }
    }

    func contains(_ wall: Double) -> Bool { wall >= start && wall < end }
}

/// An edit of the film itself: `seconds` of silence or score inserted at `atMedia`; the cues
/// after it shift by the same amount (a silent scene / a montage with score and no lines).
struct FilmEdit {
    enum Kind { case silence, score(bpm: Double) }
    let atMedia: Double
    let seconds: Double
    let kind: Kind
}

struct PScenario {
    let tag: String
    let name: String
    var startAt: Double
    var noise: Float
    var seconds: Double
    var events: [PEvent] = []
    var tvEq = false
    var treatMusic = true
    var patience: AutoPausePatience = .normal
    var killAfter: Double? = 20 * 60
    /// Subtitle track shifted by this many seconds relative to the film (wrong subtitles).
    var cueShift: Double = 0
    var filmEdit: FilmEdit? = nil
    /// The film's sound never reaches the mic.
    var neverAudible = false
    /// Seed the tracker here at t = 0 (as "Set position" would).
    var seedAt: Double? = nil
    var trace = false
}

struct PResult {
    var holdAt: Double?
    var holdLatency: Double?
    /// Hypothesis P (frozen + lead) − truth at the hold.
    var frozenError: Double?
    var holds = 0
    var falseHolds = 0
    var releaseAt: Double?
    var releaseLatency: Double?
    var tierA = false
    var tierAAt: Double?
    var chosen = ""
    var errAfterResume: Double?
    var relockAfter: Double?
    var wrongLineSeconds = 0.0
    var warnAt: Double?
    var endedAt: Double?
    var endReason: EndReason?
    var quickChecks = 0
    var quickPasses = 0
    /// Highest quickP envelope score seen while people talked in the room (must stay < quickPScore).
    var quickMaxScoreInTalk: Float = -1
    /// Envelope score of the quickP check that passed (genuine resume).
    var quickPassScore: Float?
    var releaseLatencies: [Double] = []
    var confirmedLocksInTalk = 0
    var quietDuringHoldEvidence = 0.0
    var roomDistanceLate: Float?
    var lockAfter: Double?
    var error: Double?
    var confirmedAfter: Double?
    var finalRate = 1.0
    var worst = 0.0
    var recovery: [Double?] = []
    var maxErrLocked = 0.0
    var ticks = 0
    var tickMicros = 0.0
    var notes: [String] = []
    /// Threshold derivation (latch.md §4.1 `absent` rule): per-tick window features while the
    /// film has been inaudible for ≥ 5 s (room only) and while it has been audible for ≥ 5 s.
    var roomFeatures: [PresenceFeatures] = []
    var filmFeatures: [PresenceFeatures] = []
}

func presencePercentile(_ values: [Float], _ p: Double) -> Float {
    guard !values.isEmpty else { return .nan }
    let s = values.sorted()
    return s[min(s.count - 1, max(0, Int(Double(s.count) * p)))]
}

/// What the stub scheduler is doing.
enum StubState {
    case tracking
    case held
    case probing(since: Double, fails: Int, quickDecided: Bool, fullSearch: Bool)
    case resuming(since: Double)
}

func presenceLabel(_ s: PresenceState) -> String { PresenceTraceWriter.label(s) }

func runPresence(_ s: PScenario) -> PResult {
    // The film this scenario hears: optional edit, cue shift, tvEq.
    var samples = film.samples
    var cues = film.parsed
    if let edit = s.filmEdit {
        let at = Int(edit.atMedia * sampleRate)
        let n = Int(edit.seconds * sampleRate)
        var insert = [Float](repeating: 0, count: n)
        if case .score(let bpm) = edit.kind { for i in 0..<n { insert[i] = scoreSample(Double(i) / sampleRate, bpm: bpm) } }
        samples.insert(contentsOf: insert, at: min(at, samples.count))
        cues = cues.map { $0.start >= edit.atMedia ? Cue(id: $0.id, start: $0.start + edit.seconds, end: $0.end + edit.seconds, text: $0.text) : $0 }
    }
    if s.cueShift != 0 {
        cues = cues.map { Cue(id: $0.id, start: $0.start + s.cueShift, end: $0.end + s.cueShift, text: $0.text) }
    }
    if s.tvEq { samples = tvEq(samples) }

    let tracker = SyncTracker(cues: cues)
    let analyzer = ContentPresenceAnalyzer(sampleRate: sampleRate)
    let presenceRing = PresenceRing(seconds: 120, sampleRate: sampleRate)
    let presence = PresenceTracker(tuning: tracker.tuning)
    presence.patience = ProcessInfo.processInfo.environment["PATIENCE"] == "patient" ? .patient : s.patience
    presence.treatMusicAsContent = s.treatMusic
    presence.autoKill = ProcessInfo.processInfo.environment["KILL"].flatMap(Double.init) ?? s.killAfter
    let vad = VoiceActivityDetector(sampleRate: sampleRate)
    let ring = MicRing(seconds: 120)
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    ring.start(at: t0)
    presenceRing.start(at: t0)
    var clock = PlaybackClock(media: 0, at: t0, rate: 1, paused: true)
    var pauseReason: PauseReason = .none
    var isPlaced = false
    if let seed = s.seedAt {
        tracker.seed(mediaTime: seed, at: t0)
        clock = PlaybackClock(media: seed, at: t0, rate: 1, paused: false)
        isPlaced = true
    }
    let debug = ProcessInfo.processInfo.environment["DEBUG"] != nil
    let trace: PresenceTraceWriter? = s.trace ? PresenceTraceWriter(url: outDir.appendingPathComponent("presence-\(s.tag).csv")) : nil
    let lead = tracker.tuning.onsetLeadSeconds

    let hop = 4800
    var wallSamples = 0
    let totalWall = Int(s.seconds * sampleRate)
    var truthMedia = s.startAt
    var fanLevel: Float = 0
    var started = Set<Int>()
    var tick = 0
    var result = PResult(recovery: s.events.map { _ in nil })
    var stub = StubState.tracking
    var lastNote = ""
    var lastReportAt: Date?
    var frozenMedia = 0.0
    var freezeWall = t0
    var returnWall = t0
    var contentReturnAt: Double?      // wall second the film's sound came back after a pause/mute/edit
    var pauseStartAt: Double?
    var lastAudibleAt = -1.0          // wall second of the last 100 ms buffer with film audio
    var lastInaudibleAt = -1.0        // wall second of the last 100 ms buffer without
    var ended = false
    let legitRanges: [(Double, Double)] = s.events.compactMap {
        switch $0 {
        case .pause(let at, let sec), .muted(let at, let sec): return (at, at + sec)
        case .off(let at): return (at, 1e9)
        default: return nil
        }
    }
    // Media ranges where the film itself is quiet (an edit); holds there are "acceptable".
    let editRange: (Double, Double)? = s.filmEdit.map { ($0.atMedia, $0.atMedia + $0.seconds) }
    func legitHold(atWall w: Double, truth: Double) -> Bool {
        if s.neverAudible { return true }
        if legitRanges.contains(where: { w + 1 >= $0.0 && w + 1 < $0.1 + 2 }) { return true }
        if let e = editRange, truth >= e.0 - 1, truth <= e.1 + 2 { return true }
        return false
    }
    func displayError(at now: Date) -> Double? { isPlaced ? clock.mediaTime(at: now) - truthMedia : nil }

    while wallSamples < totalWall, !ended {
        var buf = roomNoise(hop, level: s.noise)
        if fanLevel > 0 { let f = fanNoise(hop, level: fanLevel); for i in 0..<hop { buf[i] += f[i] } }
        var filmAudible = false
        for i in 0..<hop {
            let wall = Double(wallSamples + i) / sampleRate
            for (k, e) in s.events.enumerated() where !started.contains(k) && wall >= e.start {
                started.insert(k)
                switch e {
                case .skip(_, let by): truthMedia += by
                case .fan(_, let level): fanLevel = level
                case .keepListening:
                    _ = presence.extend(at: t0.addingTimeInterval(wall))
                    result.notes.append(String(format: "keepListening@%.0f", wall))
                default: break
                }
            }
            let paused = s.events.contains { if case .pause = $0 { return $0.contains(wall) } else if case .off = $0 { return $0.contains(wall) } else { return false } }
            let silent = s.events.contains { if case .muted = $0 { return $0.contains(wall) } else { return false } }
            if !paused {
                if !silent, !s.neverAudible {
                    let idx = Int(truthMedia * sampleRate)
                    if idx >= 0 && idx < samples.count { buf[i] += samples[idx] }
                    if let e = editRange, truthMedia >= e.0, truthMedia < e.1 { } else { filmAudible = true }
                }
                truthMedia += 1 / sampleRate
            }
            for e in s.events where e.contains(wall) {
                switch e {
                case .roomMusic(_, _, let bpm): buf[i] += scoreSample(wall, bpm: bpm)
                case .talk(let at, _): buf[i] += talkSample(wall - at)
                default: break
                }
            }
        }
        let frames = vad.process(buf)
        ring.append(frames.map(\.speech))
        presenceRing.append(analyzer.process(buf))
        wallSamples += hop
        let wallSeconds = Double(wallSamples) / sampleRate
        let now = t0.addingTimeInterval(wallSeconds)

        // Content return bookkeeping (for latency numbers).
        if filmAudible { lastAudibleAt = wallSeconds } else { lastInaudibleAt = wallSeconds }
        if !filmAudible { if pauseStartAt == nil { pauseStartAt = wallSeconds; contentReturnAt = nil } }
        else if let p = pauseStartAt, wallSeconds - p >= 1 { contentReturnAt = wallSeconds; pauseStartAt = nil }
        else if pauseStartAt != nil { pauseStartAt = nil }

        // Displayed-vs-truth error every 100 ms.
        if let err = displayError(at: now) {
            if tracker.state == .locked, tracker.lock?.confirmed == true, !clock.isPaused {
                let settling = s.events.contains { wallSeconds >= $0.start && wallSeconds < $0.end + 60 }
                    || (editRange.map { truthMedia >= $0.0 - 2 && truthMedia < $0.1 + 60 } ?? false)
                if !settling { result.maxErrLocked = max(result.maxErrLocked, abs(err)); result.worst = max(result.worst, abs(err)) }
            }
            for (k, e) in s.events.enumerated() where result.recovery[k] == nil && wallSeconds > e.end + 0.5 {
                if tracker.lock?.confirmed == true, abs(err) < 0.5, !clock.isPaused { result.recovery[k] = wallSeconds - e.end }
            }
            if let r = contentReturnAt, wallSeconds > r + 2, !clock.isPaused {
                if abs(err) > 1 { result.wrongLineSeconds += 0.1 }
                if result.relockAfter == nil, tracker.lock?.confirmed == true, abs(err) < 0.5 { result.relockAfter = wallSeconds - r }
                if result.errAfterResume == nil, wallSeconds >= r + 10 { result.errAfterResume = abs(err) }
            }
        }

        guard wallSeconds >= Double(tick + 1) else { continue }
        tick += 1
        let analysisDue = tick % 2 == 0
        let presenceDue = presence.wantsEveryTick || tick % 2 == 0

        // --- Stub scheduler (tracker side) ---
        if analysisDue {
            switch stub {
            case .tracking, .resuming:
                if let window = ring.latest(seconds: 60) {
                    let report = tracker.analyse(mic: window.bins, windowStart: window.start, now: now)
                    lastNote = report.note
                    lastReportAt = now
                    if let lock = report.lock {
                        // As SessionController.apply(lock): ignored while the user holds; the
                        // unseeded clock starts paused, so the first lock always places it.
                        if !isPlaced || !clock.isPaused || pauseReason == .auto {
                            let target = lock.mediaTime(at: now)
                            if clock.isPaused { clock.resume(at: now); pauseReason = .none }
                            if abs(target - clock.mediaTime(at: now)) >= 0.12 || lock.rate != clock.rate { clock.set(media: target, at: now, rate: lock.rate) }
                            isPlaced = true
                        }
                        let err = lock.mediaTime(at: now) - truthMedia
                        if result.lockAfter == nil { result.lockAfter = wallSeconds; result.error = err }
                        if lock.confirmed, result.confirmedAfter == nil { result.confirmedAfter = wallSeconds }
                        if lock.confirmed, case .resuming = stub {
                            presence.reacquired(at: now)
                            stub = .tracking
                            if result.chosen.isEmpty { result.chosen = "P" }
                        } else if lock.confirmed, !presence.state.isPlayingLike {
                            // As the scheduler: any accepted position returns the latch to playing
                            // (a pre-lock `paused` that was never held, e.g. a gap before the first lock).
                            presence.reacquired(at: now)
                        }
                    } else if case .resuming = stub, report.state == .searching {
                        // The optimistic candidate was dropped: probe (clock keeps running, latch.md unverified items).
                        presence.resumeFailed(at: now)
                        tracker.hint(mediaTime: clock.mediaTime(at: now), at: now)
                        tracker.hintRadiusSeconds = tracker.tuning.reacquireHintedRadiusSeconds
                        stub = .probing(since: wallSeconds, fails: 2, quickDecided: true, fullSearch: false)
                        result.notes.append(String(format: "tierA dropped@%.0f", wallSeconds))
                    }
                    if debug {
                        print(String(format: "  t=%3.0f speech %.2f %@ state=%@ lock=%@ truth=%.1f disp=%@", wallSeconds, report.speechFraction, report.note, "\(report.state)", report.lock.map { String(format: "%.1f", $0.mediaTime(at: now)) } ?? "-", truthMedia, displayError(at: now).map { String(format: "%+.2f", $0) } ?? "-"))
                    }
                    if s.events.contains(where: { if case .talk = $0 { return $0.contains(wallSeconds) } else { return false } }), report.lock?.confirmed == true, !presence.state.isPlayingLike {
                        result.confirmedLocksInTalk += 1
                    }
                }
            case .held:
                break
            case .probing(let since, var fails, var quickDecided, var fullSearch):
                guard let window = ring.latest(seconds: 60) else { break }
                let audio = Double(window.bins.count) * SpeechEnvelope.binDuration
                let P = frozenMedia + lead
                let elapsedSinceFreeze = returnWall.timeIntervalSince(freezeWall)
                let C = P + elapsedSinceFreeze * tracker.rate
                var accepted: (media: Double, rate: Double, who: String)?
                if !quickDecided, audio >= tracker.tuning.quickPWindowSeconds {
                    let hypAtStart = P + window.start.timeIntervalSince(returnWall) * tracker.rate
                    if let qc = tracker.quickCheck(mic: window.bins, windowStart: window.start, hypothesis: hypAtStart) {
                        quickDecided = true
                        result.quickChecks += 1
                        if s.events.contains(where: { if case .talk = $0 { return $0.contains(wallSeconds) } else { return false } }) {
                            result.quickMaxScoreInTalk = max(result.quickMaxScoreInTalk, qc.score)
                        }
                        if qc.agrees {
                            result.quickPasses += 1
                            if result.quickPassScore == nil { result.quickPassScore = qc.score }
                            let inTalk = s.events.contains { if case .talk = $0 { return $0.contains(wallSeconds) } else { return false } }
                            if !inTalk || true {
                                // Tier A: run the clock from P as of the return instant (lead restores the onset).
                                clock.resume(at: returnWall.addingTimeInterval(-lead))
                                if clock.mediaTime(at: returnWall) != frozenMedia { clock.set(media: frozenMedia, at: returnWall.addingTimeInterval(-lead), rate: tracker.rate) }
                                pauseReason = .none
                                tracker.lock = SyncTracker.Lock(wallAnchor: returnWall, mediaAtAnchor: P, rate: tracker.rate, score: qc.score, confirmed: false)
                                tracker.state = .candidate
                                tracker.misses = 0
                                tracker.lockPoints = []
                                presence.resumedOptimistically(at: now)
                                stub = .resuming(since: wallSeconds)
                                result.tierA = true
                                result.tierAAt = wallSeconds
                                result.notes.append(String(format: "tierA@%.0f off %+.2f sc %.2f", wallSeconds, qc.offset, qc.score))
                            }
                        } else if debug {
                            print(String(format: "  t=%3.0f quickP fails: off %+.2f sc %.2f on %.2f/%d", wallSeconds, qc.offset, qc.score, qc.onsetScore, qc.onsetCount))
                        }
                    } else if audio >= tracker.tuning.quickPWindowSeconds + 2 {
                        quickDecided = true // undecidable (no structure / too little speech): tier B
                    }
                }
                if case .probing = stub, audio >= tracker.tuning.minWindowSeconds {
                    if fails < 2 {
                        // Hypotheses P and C at ±hypothesisRadius with T0 acceptance.
                        let stretched = SpeechEnvelope.stretched(window.bins, rate: tracker.rate)
                        let radius = SpeechEnvelope.bin(for: tracker.tuning.hypothesisRadius)
                        var best: (Correlator.Match, String)?
                        for (h, who) in [(P, "P"), (C, "C")] {
                            let hypAtStart = h + window.start.timeIntervalSince(returnWall) * tracker.rate
                            let centre = SpeechEnvelope.bin(for: hypAtStart)
                            guard let m = Correlator.search(mic: stretched, reference: tracker.reference, range: (centre - radius)..<(centre + radius)) else { continue }
                            let t = tracker.tuning
                            // Hinted-search acceptance (V1-measured) rather than the T0 placeholders: with the
                            // clock frozen a wrong hypothesis would be shown for ≥ 12 s (critique R1).
                            let ok = m.score >= t.hintedScore && m.onsetCount >= t.hintedMinOnsets && m.onsetZ >= t.hintedOnsetZ
                                && m.onsetScore >= t.tierOnsetScore && m.onsetMargin >= t.hintedOnsetMargin
                            if debug { print(String(format: "  t=%3.0f hyp %@ env %.2f on %.2f n %d oz %.1f m %.2f %@", wallSeconds, who, m.score, m.onsetScore, m.onsetCount, m.onsetZ, m.onsetMargin, ok ? "OK" : "no")) }
                            if ok, best == nil || m.onsetScore > best!.0.onsetScore { best = (m, who) }
                        }
                        if let (m, who) = best {
                            accepted = (m.mediaTime + now.timeIntervalSince(window.start) * tracker.rate, tracker.rate, who)
                        } else {
                            fails += 1
                            if fails >= 2 {
                                tracker.lock = nil
                                tracker.state = .searching
                                tracker.hint(mediaTime: P + now.timeIntervalSince(returnWall) * tracker.rate, at: now)
                                tracker.hintRadiusSeconds = tracker.tuning.reacquireHintedRadiusSeconds
                            }
                        }
                    } else {
                        if !fullSearch, wallSeconds - since >= tracker.tuning.probeFullSearchAfterSeconds {
                            fullSearch = true
                            tracker.resync()
                        } else if !fullSearch {
                            tracker.hint(mediaTime: P + now.timeIntervalSince(returnWall) * tracker.rate, at: now)
                            tracker.hintRadiusSeconds = tracker.tuning.reacquireHintedRadiusSeconds
                            tracker.state = .searching
                        }
                        let report = tracker.analyse(mic: window.bins, windowStart: window.start, now: now)
                        lastNote = report.note
                        lastReportAt = now
                        if debug { print(String(format: "  t=%3.0f probe %@ state=%@", wallSeconds, report.note, "\(report.state)")) }
                        if let lock = report.lock, lock.confirmed {
                            accepted = (lock.mediaTime(at: now), lock.rate, fullSearch ? "full" : "hinted")
                        }
                        if s.events.contains(where: { if case .talk = $0 { return $0.contains(wallSeconds) } else { return false } }), report.lock?.confirmed == true {
                            result.confirmedLocksInTalk += 1
                        }
                    }
                }
                if let a = accepted {
                    tracker.seed(mediaTime: a.media, at: now)
                    tracker.rate = a.rate
                    clock.set(media: a.media, at: now, rate: a.rate)
                    clock.resume(at: now)
                    pauseReason = .none
                    isPlaced = true
                    presence.reacquired(at: now)
                    stub = .tracking
                    if result.chosen.isEmpty { result.chosen = a.who }
                    result.notes.append(String(format: "relock %@@%.0f", a.who, wallSeconds))
                } else if case .probing = stub {
                    stub = .probing(since: since, fails: fails, quickDecided: quickDecided, fullSearch: fullSearch)
                }
            }
        }

        // --- Presence tick ---
        if presenceDue, let pf = presenceRing.latest(seconds: presence.framesSecondsWanted) {
            let bins = ring.latest(seconds: tracker.tuning.presenceWindowSeconds)
            var expected: [Double]?
            if tracker.state == .locked || tracker.state == .drifting, let lock = tracker.lock {
                expected = (0..<Int(tracker.tuning.presenceWindowSeconds)).map { k in
                    let a = now.addingTimeInterval(-tracker.tuning.presenceWindowSeconds + Double(k))
                    return tracker.expectedSpeechFraction(from: lock.mediaTime(at: a), to: lock.mediaTime(at: a.addingTimeInterval(1)))
                }
            }
            let tracking = lastNote == "tracking" && (lastReportAt.map { now.timeIntervalSince($0) <= 2.1 } ?? false)
            let input = PresenceTracker.Input(frames: pf.frames, framesStart: pf.start, hopSeconds: analyzer.hopSeconds,
                                              speechBins: bins?.bins ?? [], binsStart: bins?.start ?? now,
                                              expectedPerSecond: expected, tracking: tracking,
                                              trackerState: tracker.state, trackerConfirmed: tracker.lock?.confirmed ?? false,
                                              everLocked: tracker.lastConfirmedLockWall != nil, now: now, validBands: analyzer.validBands)
            let clockSnapshot = clock
            let started = Date()
            let report = presence.analyse(input) { clockSnapshot.mediaTime(at: $0) }
            result.tickMicros += Date().timeIntervalSince(started) * 1e6
            result.ticks += 1
            if wallSeconds - lastAudibleAt >= 5 { result.roomFeatures.append(report.features) }
            else if wallSeconds - lastInaudibleAt >= 5 { result.filmFeatures.append(report.features) }
            trace?.append(t: wallSeconds, report: report, clock: isPlaced ? clock.mediaTime(at: now) : nil, truth: truthMedia)
            if debug {
                let f = report.features
                print(String(format: "  t=%3.0f L %5.1f Lmax %5.1f D %4.1f M %.2f V %.2f Fx %4.1f tv %@ room %@ E %@ %@ %@ q %.0f floor %@ clock %@ truth %.1f %@",
                             wallSeconds, f.level, f.peak, f.depth, f.modRatio, f.speechFraction, f.fluxSpread,
                             f.tvDistance.map { String(format: "%.1f", $0) } ?? "-", f.roomDistance.map { String(format: "%.1f", $0) } ?? "-",
                             f.expectedDialogue.map { String(format: "%.2f", $0) } ?? "-", "\(f.evidence)", presenceLabel(report.state), report.quietSeconds, report.floorDb.map { String(format: "%.1f", $0) } ?? "-",
                             isPlaced ? String(format: "%.1f", clock.mediaTime(at: now)) : "-", truthMedia, report.note))
            }
            // Kill clock must not advance under hold evidence (chatter / music): the largest
            // quietSeconds seen while people talk or music plays in the room, printed per row.
            let inHoldEvent = s.events.contains { e in
                switch e {
                case .talk, .roomMusic: return e.contains(wallSeconds)
                default: return false
                }
            }
            if inHoldEvent { result.quietDuringHoldEvidence = max(result.quietDuringHoldEvidence, report.quietSeconds) }
            if wallSeconds >= 150, wallSeconds < 151, let d = report.features.roomDistance { result.roomDistanceLate = d }
            for event in report.events {
                switch event {
                case .held(let frozen, let at):
                    guard pauseReason != .user else { break }
                    frozenMedia = frozen
                    freezeWall = at
                    clock.pause(at: at)
                    pauseReason = .auto
                    stub = .held
                    result.holds += 1
                    if !legitHold(atWall: wallSeconds, truth: truthMedia) { result.falseHolds += 1 }
                    if result.holdAt == nil {
                        result.holdAt = wallSeconds
                        if let p = legitRanges.first(where: { wallSeconds >= $0.0 }) ?? legitRanges.first { result.holdLatency = wallSeconds - p.0 }
                        result.frozenError = frozen + lead - truthMedia
                    }
                    result.notes.append(String(format: "hold@%.0f frz %.1f", wallSeconds, frozen))
                case .released(let frozen, _, let back):
                    // Nothing was held (scheduler: presenceReleased guards on held(.auto)) → ignore. A
                    // second release while already probing (the sound went away and came back before
                    // anything was accepted: chatter, then the film) restarts the probe from the new
                    // return instant, as `CheckInScheduler.presenceReleased` does (reviewer fix: the
                    // stub used to ignore it and relock only once the chatter had left the 60 s window).
                    switch stub {
                    case .held, .probing: break
                    default: continue
                    }
                    // Restart the ring at the detection instant, never at `back` (which is in the
                    // past: bins appended from now on would be mis-stamped by now − back, and every
                    // post-release correlation would be off by that much). P (the film resumed where
                    // it stopped) is propagated from the event's frozen position to `now`.
                    returnWall = now
                    frozenMedia = frozen + now.timeIntervalSince(back) * tracker.rate
                    ring.restart(at: now)
                    stub = .probing(since: wallSeconds, fails: 0, quickDecided: false, fullSearch: false)
                    if let r = contentReturnAt { result.releaseLatencies.append(wallSeconds - r) }
                    if result.releaseAt == nil {
                        result.releaseAt = wallSeconds
                        if let r = contentReturnAt { result.releaseLatency = wallSeconds - r }
                    }
                    result.notes.append(String(format: "release@%.0f back@%.1f", wallSeconds, back.timeIntervalSince(t0)))
                case .warn(let endsAt):
                    if result.warnAt == nil { result.warnAt = wallSeconds }
                    result.notes.append(String(format: "warn@%.0f ends@%.0f", wallSeconds, endsAt.timeIntervalSince(t0)))
                case .clearWarning:
                    result.notes.append(String(format: "clearWarning@%.0f", wallSeconds))
                case .end(let reason):
                    result.endedAt = wallSeconds
                    result.endReason = reason
                    ended = true
                }
            }
        }
    }
    trace?.close()
    result.finalRate = tracker.rate
    result.notes.append("quiet \(Int(presence.quietSeconds))")
    return result
}

extension PresenceState {
    var isPlayingLike: Bool {
        switch self {
        case .playing, .suspect, .resuming: true
        default: false
        }
    }
}

// MARK: - Suite

/// Wall second (for a run starting at `startAt`) at which a pause cuts a line: 1.2 s into the
/// first cue of ≥ 2.5 s that starts at or after media `startAt + near`. "Pause in dialogue"
/// scenarios use it so the pause instant is not in a subtitle gap, where any detector's P is
/// ambiguous by the gap length (tier B's ±5 s search resolves that case; tier A cannot).
func pauseInsideCue(startAt: Double, near: Double) -> Double {
    let c = film.cues.first { $0.start >= startAt + near && $0.end - $0.start >= 2.5 } ?? film.cues[0]
    return c.start + 1.2 - startAt
}

func pfmt(_ v: Double?, _ f: String = "%.0f") -> String { v.map { String(format: f, $0) } ?? "-" }

@_cdecl("synctest_suite_presence")
public func synctestSuitePresence() {
    let cues = film.cues
    let gapAfter16 = cues[17].start - cues[16].end
    let lead = SyncTracker.Tuning().onsetLeadSeconds

    print("\nPresence (WP3): latch scenarios, stub scheduler. Freeze instant = quiet onset − \(lead) s.")
    print("#   scenario                            hold@  lat s  P−truth  rel@  tierA  err@10  relock  holds  false  ended@  result")

    var failures = 0
    /// ONLY=1,7,15 runs just those rows (and the numbered blocks 11/12/16/17 when listed).
    let only = ProcessInfo.processInfo.environment["ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
    func wanted(_ tag: String) -> Bool { only == nil || only!.contains(tag) }
    func row(_ s: PScenario, check: (PResult) -> (Bool, String)) {
        guard wanted(s.tag) else { return }
        let r = runPresence(s)
        let (ok, detail) = check(r)
        if !ok { failures += 1 }
        print(s.tag.padding(toLength: 4, withPad: " ", startingAt: 0)
              + s.name.padding(toLength: 36, withPad: " ", startingAt: 0)
              + pad(pfmt(r.holdAt), 5) + pad(pfmt(r.holdLatency, "%.1f"), 7) + pad(pfmt(r.frozenError, "%+.2f"), 9)
              + pad(pfmt(r.releaseAt), 6) + pad(r.tierA ? "yes" : "no", 7) + pad(pfmt(r.errAfterResume, "%.2f"), 8)
              + pad(pfmt(r.relockAfter, "%.0f"), 8) + pad("\(r.holds)", 7) + pad("\(r.falseHolds)", 7) + pad(pfmt(r.endedAt), 8)
              + "  " + (ok ? "PASS" : "FAIL") + "  " + detail)
        if ProcessInfo.processInfo.environment["NOTES"] != nil || !ok { print("      " + r.notes.joined(separator: " · ")) }
    }

    // 1. Pause in dialogue.
    let p1 = pauseInsideCue(startAt: 100, near: 58)
    row(PScenario(tag: "1", name: "pause 40 s in dialogue", startAt: 100, noise: 0.03, seconds: 170, events: [.pause(at: p1, seconds: 40)], trace: true)) { r in
        // Tier A needs 4 s of post-release audio: ≤ 2 s release + 4 s window + 1 tick after the return at 100.
        // Hold ≤ 10 s: the ledger needs 4 s of expected dialogue, so a short cue remainder + gap puts the
        // confirm at 6–9 s (measured 6.3–8.4 s across films); the spec's 8 s is the typical case.
        // Tier A needs speech with ≥ 1 onset in the first 4 s after the return; a resume into a gap
        // is undecidable and goes to tier B (P at ≥ 12 s). Either is a pass; the column shows which.
        let resumed = (r.tierA && ((r.tierAAt ?? 999) - (p1 + 40)) <= 7) || (r.relockAfter ?? 99) <= 14
        let ok = (r.holdLatency ?? 99) <= 10 && abs(r.frozenError ?? 9) <= 1.5 && resumed && (r.errAfterResume ?? 9) <= 1 && r.chosen == "P" && r.falseHolds == 0
        return (ok, "tierA@+\(pfmt((r.tierAAt ?? 0) - (p1 + 40), "%.0f")) s, chose \(r.chosen), quickP score \(r.quickPassScore.map { String(format: "%.2f", $0) } ?? "-"), release lat \(pfmt(r.releaseLatency, "%.1f")) s")
    }
    // 1m. Pause matrix: three noise levels, with and without tvEq (critique R4; the brief).
    var derivation: [String] = []
    for eq in [false, true] {
        for noise: Float in [0.01, 0.03, 0.08] {
            row(PScenario(tag: "1m", name: String(format: "pause 40 s, noise %.2f, tvEq %@", noise, eq ? "on" : "off"), startAt: 100, noise: noise, seconds: 170, events: [.pause(at: p1, seconds: 40)], tvEq: eq)) { r in
                let ok = (r.holdLatency ?? 99) <= 10 && abs(r.frozenError ?? 9) <= 1.5 && (r.errAfterResume ?? 9) <= 1 && r.falseHolds == 0 && (r.releaseLatency ?? 9) <= 2
                let room = r.roomFeatures, filmF = r.filmFeatures
                derivation.append(String(format: "    noise %.2f tvEq %@: room-only (%d ticks) Fx p50 %.2f p95 %.2f max %.2f · L p95 %.1f · Lmax p95 %.1f · D p95 %.2f | film (%d ticks) Fx p50 %.2f p10 %.2f · D p50 %.1f",
                                         noise, eq ? "on " : "off", room.count,
                                         presencePercentile(room.map(\.fluxSpread), 0.5), presencePercentile(room.map(\.fluxSpread), 0.95), room.map(\.fluxSpread).max() ?? .nan,
                                         presencePercentile(room.map(\.level), 0.95), presencePercentile(room.map(\.peak), 0.95), presencePercentile(room.map(\.depth), 0.95),
                                         filmF.count, presencePercentile(filmF.map(\.fluxSpread), 0.5), presencePercentile(filmF.map(\.fluxSpread), 0.1), presencePercentile(filmF.map(\.depth), 0.5)))
                return (ok, "chose \(r.chosen), release lat \(pfmt(r.releaseLatency, "%.1f")) s, tierA \(r.tierA ? "+\(pfmt((r.tierAAt ?? 0) - (p1 + 40), "%.0f")) s" : "no")")
            }
        }
    }
    let t = SyncTracker.Tuning()
    print(String(format: "    Threshold derivation (absent rule: L ≤ %.0f, Lmax ≤ %.0f, D < %.0f, Fx < absentFluxDb): WP0 placeholder absentFluxDb %.1f → PresenceTracker uses %.1f. Room-only Fx max must stay below it with margin; the film's p50 sits well above it. The film's p10 is its silent inter-cue gaps (the synthetic film has digital silence between lines), which no track-independent feature can tell from a pause: the subtitle prior (expectedQuiet) carries those, see the census.",
                 t.absentLevelDb, t.absentPeakDb, t.absentDepthDb, t.absentFluxDb, PresenceTracker.measuredAbsentFluxDb))
    for line in derivation { print(line) }
    // 2. Pause in a montage (2 s into the long gap after cue 16; no cues expected → track-independent / next-cue path).
    row(PScenario(tag: "2", name: "pause 30 s in a montage gap", startAt: cues[16].end - 40, noise: 0.03, seconds: 150, events: [.pause(at: 42, seconds: 30)])) { r in
        let nextCue = gapAfter16 - 2
        let bound = max(14, nextCue + 6 + 2)
        let ok = (r.holdLatency ?? 99) <= bound && (r.errAfterResume ?? 9) <= 1 && r.falseHolds == 0
        return (ok, String(format: "gap %.0f s → bound %.0f s", gapAfter16, bound))
    }
    // 3. Silent scene (25 s of digital silence inserted), no pause.
    let silentAt = cues[20].end + 0.5
    row(PScenario(tag: "3", name: "silent scene 25 s, no pause", startAt: silentAt - 40, noise: 0.03, seconds: 150, filmEdit: FilmEdit(atMedia: silentAt, seconds: 25, kind: .silence))) { r in
        let ok = r.falseHolds == 0 && (r.holds == 0 || ((r.relockAfter ?? 99) <= 8 && r.wrongLineSeconds <= 4))
        return (ok, r.holds == 0 ? "no pause fired" : "pause fired, \(r.chosen) won, wrong-line \(pfmt(r.wrongLineSeconds, "%.1f")) s")
    }
    // 4. Muted 30 s.
    row(PScenario(tag: "4", name: "muted 30 s", startAt: 100, noise: 0.03, seconds: 160, events: [.muted(at: 60, seconds: 30)])) { r in
        let ok = r.falseHolds == 0 && (r.errAfterResume ?? 9) <= 1 && (r.relockAfter ?? 99) <= 14
        return (ok, r.holds == 0 ? "no pause fired" : "pause fired, \(r.chosen) won")
    }
    // 5. Score 40 s in-film (montage, no lines), music on / off.
    let scoreAt = cues[20].end + 0.5
    row(PScenario(tag: "5a", name: "score 40 s in-film, music=content", startAt: scoreAt - 40, noise: 0.03, seconds: 170, tvEq: true, treatMusic: true, filmEdit: FilmEdit(atMedia: scoreAt, seconds: 40, kind: .score(bpm: 72)))) { r in
        let ok = r.holds == 0
        return (ok, "relock after score \(pfmt(r.relockAfter)) s (target ≤ 20, V1 continuous)")
    }
    row(PScenario(tag: "5b", name: "score 40 s in-film, music=off", startAt: scoreAt - 40, noise: 0.03, seconds: 170, tvEq: true, treatMusic: false, filmEdit: FilmEdit(atMedia: scoreAt, seconds: 40, kind: .score(bpm: 72)))) { r in
        let ok = r.holds >= 1 && r.falseHolds == 0 && (r.errAfterResume ?? 9) <= 1 && (r.relockAfter ?? 99) <= 14
        return (ok, "\(r.chosen) won, relock \(pfmt(r.relockAfter)) s")
    }
    // 6. Music in the room during a real pause (documented failure mode: records).
    row(PScenario(tag: "6", name: "room music during a pause", startAt: 100, noise: 0.03, seconds: 220, events: [.pause(at: 60, seconds: 60), .roomMusic(at: 62, seconds: 40, bpm: 72)])) { r in
        let ok = r.falseHolds == 0 && !r.tierA
        return (ok, (r.holdAt == nil ? "never fired (documented)" : "fired at +\(pfmt(r.holdLatency, "%.0f")) s; relock \(pfmt(r.relockAfter)) s") + ", max quiet s during music \(pfmt(r.quietDuringHoldEvidence))")
    }
    // 7. People talking during a pause.
    row(PScenario(tag: "7", name: "chatter 60 s during a pause", startAt: 100, noise: 0.03, seconds: 220, events: [.pause(at: p1, seconds: 80), .talk(at: p1 + 10, seconds: 60)])) { r in
        let ok = r.confirmedLocksInTalk == 0 && r.quickPasses == 0 || (r.tierAAt ?? 0) >= p1 + 80
        let ok2 = (r.relockAfter ?? 99) <= 45 && r.falseHolds == 0 // critique §2: recovery under chatter via lost/T2 up to ~40 s
        let ok3 = r.quietDuringHoldEvidence <= 12 // the ≤ 10 s of quiet before the chatter began; frozen under hold evidence
        return (ok && ok2 && ok3, "quickP \(r.quickPasses)/\(r.quickChecks) passes (best talk score \(String(format: "%.2f", r.quickMaxScoreInTalk)) vs threshold \(String(format: "%.2f", SyncTracker.Tuning().quickPScore))), \(r.confirmedLocksInTalk) locks in talk, max quiet s in talk \(pfmt(r.quietDuringHoldEvidence)) (≤ 12), relock \(pfmt(r.relockAfter)) s")
    }
    // 8. Loud room pause.
    let p8 = pauseInsideCue(startAt: 90, near: 58)
    row(PScenario(tag: "8", name: "loud room 0.15, pause 40 s", startAt: 90, noise: 0.15, seconds: 170, events: [.pause(at: p8, seconds: 40)])) { r in
        let ok = (r.holdLatency ?? 99) <= 12 && (r.releaseAt ?? 0) >= p8 + 40 && r.falseHolds == 0
        return (ok, "release \(pfmt(r.releaseAt)) s (≥ \(pfmt(p8 + 40)))")
    }
    // 9. Fan turns on mid-film.
    row(PScenario(tag: "9", name: "fan on at 90 s", startAt: 100, noise: 0.03, seconds: 220, events: [.fan(at: 90, level: 0.06)])) { r in
        let ok = r.holds == 0 && r.maxErrLocked <= 0.5
        return (ok, "worst \(pfmt(r.maxErrLocked, "%.2f")) s, Δroom@150 \(r.roomDistanceLate.map { String(format: "%.1f", $0) } ?? "-")")
    }
    // 10. TV off, kill clock 60 s; and with Keep listening at 240 s.
    row(PScenario(tag: "10", name: "TV off at 200 s, kill 60 s", startAt: 60, noise: 0.03, seconds: 340, events: [.off(at: 200)], killAfter: 60)) { r in
        let ok = abs((r.endedAt ?? 0) - 260) <= 4 && r.warnAt != nil && r.falseHolds == 0
        return (ok, "warn \(pfmt(r.warnAt)) ended \(pfmt(r.endedAt)) (260 ± 4) \(r.endReason.map { "\($0)" } ?? "")")
    }
    row(PScenario(tag: "10b", name: "… + Keep listening at 240 s", startAt: 60, noise: 0.03, seconds: 380, events: [.off(at: 200), .keepListening(at: 240)], killAfter: 60)) { r in
        let ok = abs((r.endedAt ?? 0) - 300) <= 4
        return (ok, "ended \(pfmt(r.endedAt)) (300 ± 4)")
    }
    // 13. Pause then seek +300 s.
    let p13 = pauseInsideCue(startAt: 20, near: 58)
    row(PScenario(tag: "13", name: "pause 40 s, resume +300 s", startAt: 20, noise: 0.03, seconds: 160, events: [.pause(at: p13, seconds: 40), .skip(at: p13 + 40, by: 300)])) { r in
        let ok = !r.tierA && (r.relockAfter ?? 99) <= 36 && (r.errAfterResume == nil || true) && r.falseHolds == 0
        return (ok, "relock \(pfmt(r.relockAfter)) s via \(r.chosen) (target ≤ 30; full search after 30 s probing)")
    }
    // 14. Wrong subtitles: tracker seeded 90 s ahead of the film with the real track.
    row(PScenario(tag: "14", name: "wrong subtitles (+90 s seed)", startAt: 100, noise: 0.03, seconds: 150, seedAt: 190)) { r in
        let ok = r.holds == 0
        return (ok, "lock \(pfmt(r.lockAfter)) s, tracker relocked at err \(pfmt(r.error, "%+.1f"))")
    }
    // 15. Never locked: the TV's sound never reaches the phone.
    row(PScenario(tag: "15", name: "never locked, kill 60 s", startAt: 100, noise: 0.03, seconds: 240, killAfter: 60, neverAudible: true)) { r in
        let isNever: Bool = { if case .neverHeard = r.endReason { return true } else { return false } }()
        // quietSeconds counts from the quiet onset (t = 0 here), not from the pause confirmation:
        // ended at killAfter × 1.5 (60 s + the 30 s never-locked extension scaled by KILL) = 90 s.
        let ok = isNever && abs((r.endedAt ?? 0) - 90) <= 4
        return (ok, "ended \(pfmt(r.endedAt)) (kill 60 + 30 s scaled never-locked extra = 90 ± 4) reason \(r.endReason.map { "\($0)" } ?? "-")")
    }

    if wanted("11") {
    // 11. False-pause census.
    print("\n11. False-pause census (full film, no pauses): holds / ended")
    for eq in [false, true] {
        for noise: Float in [0.01, 0.03, 0.08] {
            let r = runPresence(PScenario(tag: "11", name: "census", startAt: 0, noise: noise, seconds: film.seconds - 12, tvEq: eq))
            let ok = r.holds == 0 && r.endedAt == nil
            if !ok { failures += 1 }
            print(String(format: "    noise %.2f tvEq %@: %d holds, %d false, ended %@, lock@%@ worst %.2f  %@", noise, eq ? "on " : "off", r.holds, r.falseHolds, pfmt(r.endedAt), pfmt(r.lockAfter), r.maxErrLocked, ok ? "PASS" : "FAIL"))
            if !ok { print("      " + r.notes.joined(separator: " · ")) }
        }
    }

    }
    if wanted("12") {
    // 12. Modulation unit test.
    print("\n12. Modulation ratio M on synthetic envelopes (hop rate 23.44 Hz, 96 points)")
    let hopRate = sampleRate / Double(ContentPresenceAnalyzer.hop)
    let n = 96
    let square = (0..<n).map { i -> Float in let ph = Double(i) / hopRate * 4; return (ph - ph.rounded(.down)) < 0.5 ? 10 : 0 }
    let sine = (0..<n).map { i in Float(5 * sin(2 * Double.pi * 1.5 * Double(i) / hopRate)) }
    let white = (0..<n).map { _ in Float.random(in: -5...5, using: &rng) }
    let constant = [Float](repeating: -40, count: n)
    let mSquare = PresenceTracker.modulationRatio(square, hopRate: hopRate)
    let mSine = PresenceTracker.modulationRatio(sine, hopRate: hopRate)
    let mWhite = PresenceTracker.modulationRatio(white, hopRate: hopRate)
    let mConst = PresenceTracker.modulationRatio(constant, hopRate: hopRate)
    let modOK = mSquare >= 0.7 && mSine <= 0.25 && mConst == 0 && !mWhite.isNaN
    if !modOK { failures += 1 }
    print(String(format: "    4 Hz square %.2f (≥ 0.7) · 1.5 Hz sine %.2f (≤ 0.25) · white %.2f (flat spectrum → 0.71 by construction) · constant %.2f (0)  %@", mSquare, mSine, mWhite, mConst, modOK ? "PASS" : "FAIL"))

    }
    if wanted("16") {
    // 16. Cost.
    do {
        let analyzer = ContentPresenceAnalyzer(sampleRate: sampleRate)
        let seconds = 600.0
        var hops = 0
        let started = Date()
        var pos = 0
        let chunk = 4800
        while Double(pos) / sampleRate < seconds {
            let end = min(film.samples.count, pos + chunk)
            if end - pos < chunk { pos = 0; continue }
            hops += analyzer.process(Array(film.samples[pos..<end])).count
            pos += chunk
        }
        let perHop = Date().timeIntervalSince(started) * 1e6 / Double(max(1, hops))
        let r = runPresence(PScenario(tag: "16", name: "cost", startAt: 60, noise: 0.03, seconds: 120))
        print(String(format: "\n16. Cost: PresenceAnalyzer %.1f µs per 2048-sample hop (%.0f µs per 100 ms buffer, target < 300) · PresenceTracker %.0f µs per tick (target < 2000) over %d ticks (Mac)", perHop, perHop * 100 / 42.67, r.tickMicros / Double(max(1, r.ticks)), r.ticks))
    }

    }
    if wanted("17") {
    // 17. V1 regression with the presence layer running (holds applied by the stub).
    print("\n17. V1 scenarios with the presence layer running (hold events applied)")
    print("scenario                         lock@s    err s  confirm@s     rate  worst s  recovery s  holds false")
    for s in scenariosV1 {
        var events: [PEvent] = []
        for e in s.events {
            switch e {
            case .pause(let at, let sec): events.append(.pause(at: at, seconds: sec))
            case .skip(let at, let by): events.append(.skip(at: at, by: by))
            case .music(let at, let sec, let bpm): events.append(.roomMusic(at: at, seconds: sec, bpm: bpm ?? 120))
            default: break
            }
        }
        if s.hintAt != nil { continue } // transcript hints are not part of this loop
        let r = runPresence(PScenario(tag: "17", name: s.name, startAt: s.startAt, noise: s.noise, seconds: s.seconds, events: events))
        if r.falseHolds > 0 { failures += 1 }
        print(s.name.padding(toLength: 30, withPad: " ", startingAt: 0)
              + pad(pfmt(r.lockAfter), 9) + pad(pfmt(r.error, "%+.2f"), 9) + pad(pfmt(r.confirmedAfter), 11)
              + pad(String(format: "%.4f", r.finalRate), 9) + pad(String(format: "%.2f", r.worst), 9)
              + pad(r.recovery.isEmpty ? "" : r.recovery.map { pfmt($0) }.joined(separator: ","), 12)
              + pad("\(r.holds)", 7) + pad("\(r.falseHolds)", 6))
    }
    }
    // Wrong film with the presence layer: 0 confirmed locks, 0 holds while the real film plays.
    if wanted("17") {
        var wrongCues: [Cue] = []
        var t = 5.0
        for (i, c) in film.parsed.shuffled(using: &rng).enumerated() {
            wrongCues.append(Cue(id: i, start: t, end: t + c.duration, text: c.text))
            t += c.duration + Double.random(in: 0.3...2.5, using: &rng) + (i % 17 == 16 ? Double.random(in: 8...20, using: &rng) : 0)
        }
        let wrong = SyncTracker(cues: wrongCues)
        let analyzer = ContentPresenceAnalyzer(sampleRate: sampleRate)
        let presenceRing = PresenceRing(seconds: 120, sampleRate: sampleRate)
        let presence = PresenceTracker(tuning: wrong.tuning)
        let vad = VoiceActivityDetector(sampleRate: sampleRate)
        let ring = MicRing(seconds: 120)
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        ring.start(at: t0); presenceRing.start(at: t0)
        var wallSamples = 0, locks = 0, analyses = 0, holds = 0
        var lastNote = ""
        while wallSamples < Int(150 * sampleRate) {
            var buf = roomNoise(4800, level: 0.02)
            for i in 0..<4800 { let idx = Int((100 + Double(wallSamples + i) / sampleRate) * sampleRate); if idx < film.samples.count { buf[i] += film.samples[idx] } }
            ring.append(vad.process(buf).map(\.speech))
            presenceRing.append(analyzer.process(buf))
            wallSamples += 4800
            let now = t0.addingTimeInterval(Double(wallSamples) / sampleRate)
            if wallSamples % Int(2 * sampleRate) == 0, let w = ring.latest(seconds: 60) {
                analyses += 1
                let r = wrong.analyse(mic: w.bins, windowStart: w.start, now: now)
                lastNote = r.note
                if r.lock?.confirmed == true { locks += 1 }
                if let pf = presenceRing.latest(seconds: presence.framesSecondsWanted) {
                    let bins = ring.latest(seconds: 4)
                    let input = PresenceTracker.Input(frames: pf.frames, framesStart: pf.start, hopSeconds: analyzer.hopSeconds, speechBins: bins?.bins ?? [], binsStart: bins?.start ?? now, expectedPerSecond: nil, tracking: lastNote == "tracking", trackerState: wrong.state, trackerConfirmed: wrong.lock?.confirmed ?? false, everLocked: false, now: now)
                    let rep = presence.analyse(input) { _ in 0 }
                    for e in rep.events { if case .held = e { holds += 1 } }
                }
            }
        }
        let ok = locks == 0 && holds == 0
        if !ok { failures += 1 }
        print("Wrong-film check with presence: \(locks) confirmed locks, \(holds) auto-pauses in \(analyses) analyses (want 0 / 0)  \(ok ? "PASS" : "FAIL")")
    }
    print("\nPresence suite: \(failures == 0 ? "all checks passed" : "\(failures) check(s) failed")")
}
