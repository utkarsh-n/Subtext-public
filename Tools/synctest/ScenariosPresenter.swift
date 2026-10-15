import Foundation

// WP5 — Island and Theater harness (docs/v2/island.md §8 scenarios P1–P11, B1–B2, L1).
// Declarations only; entry point `synctest_suite_presenter` (SCENARIOS=presenter).
//
// The film is replayed through the V1 tracker (runV2 with no analysis hook), the V1 phase
// mapping of SyncEngine is applied, a scripted BeatCadence drives `beat`, and IslandPresenter is
// sampled every 0.25 s. Every emitted IslandState is kept so the scenarios can assert on them.

// MARK: - Simulation pieces

/// `SyncEngine.apply(report)`'s mapping of tracker state → SyncPhase (V1).
private func v1Phase(_ state: SyncTracker.State) -> SyncPhase {
    switch state {
    case .listening: .listening
    case .searching, .candidate: .searching
    case .locked: .locked
    case .drifting: .drifting
    }
}

/// `BeatDriver` as the harness sees it: a counter that advances on the cadence while the
/// style pulses and the setting is on; `n` restarts on every activation (island.md §2.2).
private struct SimBeatDriver {
    var beat = 0
    private var n = 0
    private var active = false
    private var nextAt = 0.0
    private(set) var emitted: [Double] = []

    mutating func step(now: Double, active wanted: Bool) {
        if wanted {
            if !active { active = true; n = 0; nextAt = now }
            while now >= nextAt - 1e-9 {
                beat &+= 1
                n += 1
                emitted.append(nextAt)
                nextAt += BeatCadence.interval(afterBeat: n)
            }
        } else {
            active = false
        }
    }
}

private struct Sample {
    let t: Double
    let media: Double
    let state: IslandState
}

/// One presenter replay: the emitted states, the lock time and the displayed media per sample.
private struct PresenterRun {
    var samples: [Sample] = []
    var lockAt: Double?
    var confirmedAt: Double?
    var relistenAt: Double?
    var relockAt: Double?
    var finalState: IslandState?

    /// Consecutive distinct states, as `LiveActivityController` would push them.
    var distinct: [Sample] {
        var out: [Sample] = []
        for s in samples where out.last?.state != s.state { out.append(s) }
        return out
    }
}

/// Replays `scenario` and samples the presenter every 0.25 s. `wrongCues` swaps the tracker for
/// one built on a different film (P11). `relistenAfterLock` scripts a relisten (P5).
private func replay(_ scenario: ScenarioV2, track: SubtitleTrack, wrongCues: [Cue]? = nil,
                    relistenAfterLock: Double? = nil, showNextLine: Bool = false) -> PresenterRun {
    var run = PresenterRun()
    var beats = SimBeatDriver()
    var hooks = V2Hooks()
    let sessionStart = Date(timeIntervalSince1970: 1_000_000)
    // The track the island shows: the real one, or the wrong-film cues when replaying P11.
    let shownTrack = wrongCues.map { SubtitleTrack(title: "wrong", language: "en", cues: $0, source: "harness") } ?? track
    let wrongTracker = wrongCues.map { SyncTracker(cues: $0) }
    var placedSticky = false
    var lastPhase: SyncPhase = .listening
    hooks.setup = { ctx in
        // `SessionController.start` runs the clock from 0; the V2 runner's unseeded clock starts
        // paused, which would draw every state hollow. Mirror the app.
        ctx.clock = PlaybackClock(media: 0, at: ctx.now, rate: 1, paused: false)
    }
    if let wrongTracker {
        hooks.onAnalysisWindow = { ctx, bins, start in
            let report = wrongTracker.analyse(mic: bins, windowStart: start, now: ctx.now)
            if let lock = report.lock {
                ctx.isPlaced = true
                ctx.clock.set(media: lock.mediaTime(at: ctx.now), at: ctx.now, rate: lock.rate)
                if ctx.clock.isPaused { ctx.clock.resume(at: ctx.now) }
            }
        }
    }
    hooks.onSamples = { ctx, _ in
        let t = ctx.timebase.elapsed
        let tracker = wrongTracker ?? ctx.tracker
        // V1 placed rule, made sticky once a lock has landed (critique §4.2 / WP7's isPlaced).
        if ctx.isPlaced, tracker.lock != nil || tracker.state == .locked { placedSticky = true }
        if run.lockAt == nil, tracker.lock != nil { run.lockAt = t }
        if run.confirmedAt == nil, tracker.lock?.confirmed == true { run.confirmedAt = t }
        if let after = relistenAfterLock, run.relistenAt == nil, let l = run.confirmedAt, t >= l + after {
            run.relistenAt = t
            tracker.relisten(center: ctx.displayed, at: ctx.now)
        }
        let phase = v1Phase(tracker.state)
        if run.relistenAt != nil, run.relockAt == nil, phase == .locked, lastPhase != .locked { run.relockAt = t }
        lastPhase = phase
        let isPaused = ctx.clock.isPaused
        let style = BeaconStyle(phase: phase, isPaused: isPaused)
        beats.step(now: t, active: style.pulses)
        // Sample every buffer (100 ms): finer than island.md's 0.25 s, which is not a multiple of
        // the buffer, so every distinct state the scheduler could push is caught.
        let snapshot = EngineSnapshot(phase: phase, isPaused: isPaused, placed: placedSticky, beat: beats.beat,
                                      trim: ctx.trim, rate: ctx.clock.rate, sessionStart: sessionStart,
                                      checkInWindow: nil, lastCheckInAt: nil, nextCheckInAt: nil)
        let media = ctx.displayed
        let state = IslandPresenter.state(track: shownTrack, media: media, snapshot: snapshot,
                                          options: PresenterOptions(showNextLine: showNextLine, showRing: true),
                                          now: sessionStart.addingTimeInterval(t))
        run.samples.append(Sample(t: t, media: media, state: state))
    }
    hooks.finish = { ctx in
        // end(): lines go blank.
        let snapshot = EngineSnapshot(phase: .listening, isPaused: false, placed: false, beat: beats.beat,
                                      trim: 0, rate: 1, sessionStart: sessionStart,
                                      checkInWindow: nil, lastCheckInAt: nil, nextCheckInAt: nil)
        run.finalState = IslandPresenter.state(track: shownTrack, media: ctx.displayed, snapshot: snapshot,
                                               options: PresenterOptions(), now: sessionStart.addingTimeInterval(ctx.timebase.elapsed))
    }
    _ = runV2(scenario, hooks: hooks)
    return run
}

/// The wrong film of `runWrongFilmCheck`: same line lengths in a different order, fresh gaps.
private func makeWrongCues() -> [Cue] {
    var wrong: [Cue] = []
    var t = 5.0
    for (i, c) in film.parsed.shuffled(using: &rng).enumerated() {
        wrong.append(Cue(id: i, start: t, end: t + c.duration, text: c.text))
        t += c.duration + Double.random(in: 0.3...2.5, using: &rng) + (i % 17 == 16 ? Double.random(in: 8...20, using: &rng) : 0)
    }
    return wrong
}

private func containsForbidden(_ text: String) -> String? {
    IslandLayout.forbiddenStrings.first { text == $0 || text.contains($0) }
}

private func fmt(_ v: Double, _ digits: Int = 2) -> String { String(format: "%.\(digits)f", v) }

private struct Row {
    let id: String
    let pass: Bool
    let detail: String
}

// MARK: - Suite

@_cdecl("synctest_suite_presenter")
public func synctestSuitePresenter() {
    var rows: [Row] = []
    let track = SubtitleTrack(title: "film", language: "en", cues: film.parsed, source: "harness")
    let sessionStart = Date(timeIntervalSince1970: 1_000_000)

    // Replays shared by several scenarios.
    let quiet = replay(ScenarioV2(name: "quiet room, start 2:00", startAt: 120, rate: 1, noise: 0.01, seconds: 150),
                       track: track, relistenAfterLock: 30)
    let quietNext = replay(ScenarioV2(name: "quiet room, next line", startAt: 120, rate: 1, noise: 0.01, seconds: 60),
                           track: track, showNextLine: true)
    let wrong = replay(ScenarioV2(name: "wrong film", startAt: 100, rate: 1, noise: 0.02, seconds: 150),
                       track: track, wrongCues: makeWrongCues())
    let allSamples = quiet.samples + quietNext.samples + wrong.samples

    // P1 — placeholders never reach the cue slots.
    do {
        var hits: [String] = []
        for s in allSamples {
            if let f = containsForbidden(s.state.currentText) { hits.append("current '\(f)' @\(fmt(s.t, 1))") }
            if let f = containsForbidden(s.state.nextText) { hits.append("next '\(f)' @\(fmt(s.t, 1))") }
        }
        var combos = 0
        for phase in SyncPhase.allCases {
            for paused in [false, true] {
                for text in ["", "x"] {
                    for placed in [false, true] {
                        combos += 1
                        let state = IslandState(currentText: placed ? text : "", nextText: placed ? text : "", cueIndex: 0, cueCount: 1,
                                                trim: 0, phase: phase, isPaused: paused, rate: 1)
                        for limited in [false, true] {
                            if let t = IslandLayout.compactTrailing(state, limitedWidth: limited), let f = containsForbidden(t) {
                                hits.append("compactTrailing '\(f)' \(phase)/\(paused)")
                            }
                        }
                        let block = IslandLayout.cueBlock(state)
                        if let p = block.primary, let f = containsForbidden(p) { hits.append("cueBlock primary '\(f)' \(phase)/\(paused)") }
                        if let n = block.secondary, let f = containsForbidden(n) { hits.append("cueBlock secondary '\(f)' \(phase)/\(paused)") }
                        // The presenter itself, with an unplaced track: text must be "".
                        let snap = EngineSnapshot(phase: phase, isPaused: paused, placed: false, beat: 3, trim: 0, rate: 1,
                                                  sessionStart: sessionStart, checkInWindow: nil, lastCheckInAt: nil, nextCheckInAt: nil)
                        let st = IslandPresenter.state(track: track, media: film.parsed[3].start + 0.2, snapshot: snap,
                                                       options: PresenterOptions(showNextLine: true), now: sessionStart)
                        if !st.currentText.isEmpty || !st.nextText.isEmpty { hits.append("unplaced text \(phase)/\(paused)") }
                    }
                }
            }
        }
        rows.append(Row(id: "P1 placeholders", pass: hits.isEmpty,
                        detail: "\(hits.count) hits over \(allSamples.count) states + \(combos) phase×paused×text×placed combos" + (hits.isEmpty ? "" : ": " + hits.prefix(3).joined(separator: "; "))))
    }

    // P2 — search cadence: ≤ 60 distinct states/min while pulsing for the first 90 s, ≤ 20 after;
    // beat parity alternates between consecutive distinct states; beat 0 when not pulsing.
    do {
        var problems: [String] = []
        var perMinuteEarly = 0, perMinuteLate = 0
        for (name, run) in [("quiet", quiet), ("wrong", wrong)] {
            let distinct = run.distinct
            var parityBreaks = 0
            var beatNonZero = 0
            var textPushes = 0
            var previous: Sample?
            for s in distinct {
                let style = BeaconStyle(phase: s.state.phase, isPaused: s.state.isPaused)
                if !style.pulses, s.state.beat != 0 { beatNonZero += 1 }
                if let p = previous, style.pulses, BeaconStyle(phase: p.state.phase, isPaused: p.state.isPaused).pulses,
                   s.state.beat != 0, p.state.beat != 0 {
                    if s.state.beat == p.state.beat {
                        // A push without a beat: a cue boundary while a candidate lock shows
                        // lines (searching + placed). Legitimate; counted, not a parity break.
                        textPushes += 1
                    } else if s.state.beat % 2 == p.state.beat % 2 {
                        parityBreaks += 1   // a beat was skipped or doubled between pushes
                    }
                }
                previous = s
            }
            if textPushes > 4 { problems.append("\(name): \(textPushes) non-beat pushes while pulsing") }
            // Per-minute counts restricted to pulsing states.
            let pulsing = distinct.filter { BeaconStyle(phase: $0.state.phase, isPaused: $0.state.isPaused).pulses }
            let early = pulsing.filter { $0.t < 60 }.count
            let late = pulsing.filter { $0.t >= 90 && $0.t < 150 }.count
            perMinuteEarly = max(perMinuteEarly, early)
            perMinuteLate = max(perMinuteLate, late)
            if early > 60 { problems.append("\(name): \(early) states in minute 1") }
            if run.lockAt == nil || run.lockAt! > 150, late > 20 { problems.append("\(name): \(late) states in 90–150 s") }
            if parityBreaks > 0 { problems.append("\(name): \(parityBreaks) parity breaks") }
            if beatNonZero > 0 { problems.append("\(name): \(beatNonZero) non-pulsing states with beat ≠ 0") }
        }
        rows.append(Row(id: "P2 search cadence", pass: problems.isEmpty,
                        detail: "max \(perMinuteEarly)/min first minute, \(perMinuteLate)/min after 90 s (wrong film), beat parity alternates, beat 0 when not pulsing" + (problems.isEmpty ? "" : "; " + problems.joined(separator: "; "))))
    }

    // P3 — locked cadence: after the first confirmed lock, distinct states per minute ≤ boundaries + 1.
    do {
        var worst = 0, boundariesWorst = 0
        var fails: [String] = []
        if let l = quiet.confirmedAt {
            let relisten = quiet.relistenAt ?? .infinity
            let distinct = quiet.distinct
            var m = 0
            while true {
                let a = l + Double(m) * 60, b = a + 60
                let window = distinct.filter { $0.t >= a && $0.t < b && $0.t < relisten }
                let locked = window.filter { $0.state.phase == .locked }
                if locked.isEmpty { break }
                let samplesIn = quiet.samples.filter { $0.t >= a && $0.t < b && $0.t < relisten }
                guard let first = samplesIn.first, let last = samplesIn.last else { break }
                // Cue starts and ends inside the media span the minute covered.
                let boundaries = film.parsed.reduce(0) { n, c in
                    n + ((c.start > first.media && c.start <= last.media) ? 1 : 0) + ((c.end > first.media && c.end <= last.media) ? 1 : 0)
                }
                if locked.count > boundaries + 1 { fails.append("minute \(m): \(locked.count) states vs \(boundaries) boundaries") }
                worst = max(worst, locked.count); boundariesWorst = max(boundariesWorst, boundaries)
                m += 1
            }
        } else {
            fails.append("never locked")
        }
        rows.append(Row(id: "P3 locked cadence", pass: fails.isEmpty,
                        detail: "≤ \(worst) states/min against \(boundariesWorst) boundaries" + (fails.isEmpty ? "" : "; " + fails.joined(separator: "; "))))
    }

    // P4 — blank between lines: fraction of locked instants with "" == track gap fraction ± 2 %.
    do {
        let relisten = quiet.relistenAt ?? .infinity
        let locked = quiet.samples.filter { $0.state.phase == .locked && $0.t < relisten && $0.t > (quiet.confirmedAt ?? 0) }
        var detail = "never locked"
        var pass = false
        if let first = locked.first, let last = locked.last, last.media > first.media + 10 {
            let blank = Double(locked.filter { $0.state.currentText.isEmpty }.count) / Double(locked.count)
            let span = last.media - first.media
            var covered = 0.0
            for c in film.parsed {
                let a = max(c.start, first.media), b = min(c.end, last.media)
                if b > a { covered += b - a }
            }
            let gap = 1 - covered / span
            pass = abs(blank - gap) <= 0.02
            detail = "blank \(fmt(blank * 100, 1)) % vs gap \(fmt(gap * 100, 1)) % over \(fmt(span, 0)) s"
        }
        rows.append(Row(id: "P4 blank between lines", pass: pass, detail: detail))
    }

    // P5 — isPlaced persistence through a relisten; "" after end().
    do {
        var fails = 0, checked = 0
        var detail = "no relisten scripted"
        var pass = false
        if let r = quiet.relistenAt {
            let until = quiet.relockAt ?? .infinity
            for s in quiet.samples where s.t >= r && s.t < until {
                guard track.cueIndex(at: s.media) != nil else { continue }
                checked += 1
                if s.state.currentText.isEmpty { fails += 1 }
            }
            let blankAfterEnd = quiet.finalState?.currentText == "" && quiet.finalState?.nextText == ""
            pass = fails == 0 && checked > 0 && blankAfterEnd
            detail = "relisten @\(fmt(r, 0)) s, \(checked) in-cue samples kept text (\(fails) blank), relock \(quiet.relockAt.map { "@" + fmt($0, 0) + " s" } ?? "never"), end() → \"\""
        }
        rows.append(Row(id: "P5 isPlaced persistence", pass: pass, detail: detail))
    }

    // P6 — ring invariants over every phase × paused × showRing × date combination.
    do {
        var fails: [String] = []
        var combos = 0
        let now = sessionStart.addingTimeInterval(20)
        let dateSets: [(String, ClosedRange<Date>?, Date?, Date?, Date)] = [
            ("none", nil, nil, nil, now),
            ("all", sessionStart.addingTimeInterval(18)...sessionStart.addingTimeInterval(22), sessionStart.addingTimeInterval(10), sessionStart.addingTimeInterval(70), now),
            ("inverted", sessionStart.addingTimeInterval(70)...sessionStart.addingTimeInterval(70), sessionStart.addingTimeInterval(70), sessionStart.addingTimeInterval(10), now),
            ("late", nil, nil, nil, sessionStart.addingTimeInterval(50)),
        ]
        for phase in SyncPhase.allCases {
            for paused in [false, true] {
                for showRing in [false, true] {
                    for (name, window, last, next, at) in dateSets {
                        combos += 1
                        let snap = EngineSnapshot(phase: phase, isPaused: paused, placed: true, beat: 0, trim: 0, rate: 1,
                                                  sessionStart: sessionStart, checkInWindow: window, lastCheckInAt: last, nextCheckInAt: next)
                        let st = IslandPresenter.state(track: track, media: 10, snapshot: snap,
                                                       options: PresenterOptions(showRing: showRing), now: at)
                        let tag = "\(phase)/\(paused)/\(showRing)/\(name)"
                        if let a = st.ringStart, let b = st.ringEnd, b <= a { fails.append("ringEnd ≤ ringStart \(tag)") }
                        if (st.ringStart == nil) != (st.ringEnd == nil) { fails.append("half ring \(tag)") }
                        if st.ringKind != .none, st.ring == nil { fails.append("kind without ring \(tag)") }
                        if st.ringKind == .none, st.ring != nil { fails.append("ring without kind \(tag)") }
                        if !showRing, st.ringKind != .none { fails.append("ring with showRing off \(tag)") }
                        if paused, st.ringKind != .none { fails.append("ring while paused \(tag)") }
                        switch st.ringKind {
                        case .listening:
                            if !(phase == .listening || phase == .searching) { fails.append("listening ring in \(tag)") }
                            if at.timeIntervalSince(sessionStart) >= 45 { fails.append("listening ring after 45 s \(tag)") }
                        case .checkIn:
                            if phase != .checkingIn || window == nil { fails.append("checkIn ring in \(tag)") }
                        case .schedule:
                            if phase != .locked || last == nil || next == nil { fails.append("schedule ring in \(tag)") }
                        case .none:
                            if showRing, !paused {
                                if phase == .checkingIn, let w = window, w.upperBound > w.lowerBound { fails.append("missing checkIn ring \(tag)") }
                                if phase == .locked, let l = last, let n = next, n > l { fails.append("missing schedule ring \(tag)") }
                                if (phase == .listening || phase == .searching), at.timeIntervalSince(sessionStart) < 45 { fails.append("missing listening ring \(tag)") }
                            }
                        }
                        if st.nextCheckInAt != nil, (paused || phase != .locked) { fails.append("nextCheckInAt leaked \(tag)") }
                        if st.endsAt != nil, phase != .ending { fails.append("endsAt leaked \(tag)") }
                    }
                }
            }
        }
        rows.append(Row(id: "P6 ring invariants", pass: fails.isEmpty, detail: "\(combos) combos, \(fails.count) violations" + (fails.isEmpty ? "" : ": " + fails.prefix(3).joined(separator: "; "))))
    }

    // P7 — trim rounding: 101 trims → ≤ 11 distinct states.
    do {
        var states = Set<IslandState>()
        for i in 0...100 {
            let snap = EngineSnapshot(phase: .locked, isPaused: false, placed: true, beat: 0, trim: Double(i) / 100, rate: 1,
                                      sessionStart: sessionStart, checkInWindow: nil, lastCheckInAt: nil, nextCheckInAt: nil)
            states.insert(IslandPresenter.state(track: track, media: film.parsed[3].start + 0.1, snapshot: snap, options: PresenterOptions(), now: sessionStart.addingTimeInterval(100)))
        }
        rows.append(Row(id: "P7 trim rounding", pass: states.count <= 11, detail: "\(states.count) distinct states for 101 trims"))
    }

    // P8 — trim detents.
    do {
        var fails: [String] = []
        var detentChanges = 0
        var changePositions: [Double] = []
        var previousDetent: Int?
        var dx = -600.0
        while dx <= 600 {
            let (v, d) = TheaterLogic.trim(startTrim: 0, translationX: dx)
            let expected = max(-30, min(30, (-dx / 160 * 10 + 0.5).rounded(.down) / 10))
            if abs(v - expected) > 1e-9 { fails.append("dx \(dx): \(v) vs \(expected)") }
            if let p = previousDetent, p != d { detentChanges += 1; changePositions.append(dx) }
            previousDetent = d
            dx += 2
        }
        // Detent changes 16 pt apart (2 pt steps → every 8th step) within the unclamped range.
        let spacings = zip(changePositions.dropFirst(), changePositions).map { $0 - $1 }
        let badSpacing = spacings.filter { abs($0 - 16) > 1e-9 }.count
        if badSpacing > 0 { fails.append("\(badSpacing) detent spacings ≠ 16 pt") }
        // Zero crossing: sweeping right (trim decreasing) and left, once each; from +0.3 never.
        func crossings(from start: Double, direction: Double) -> Int {
            var n = 0
            var last = TheaterLogic.trim(startTrim: start, translationX: 0).value
            var x = 0.0
            while abs(x) <= 600 {
                let v = TheaterLogic.trim(startTrim: start, translationX: x).value
                if v != last, TheaterLogic.crossedZero(from: last, to: v) { n += 1 }
                last = v
                x += 2 * direction
            }
            return n
        }
        let rightFromMinus = crossings(from: -0.5, direction: -1)   // −0.5 → +… passes 0 once
        let leftFromPlus = crossings(from: 0.5, direction: 1)       // +0.5 → −… passes 0 once
        let fromPlusRight = crossings(from: 0.3, direction: -1)     // +0.3 dragging right: away from 0
        if rightFromMinus != 1 { fails.append("crossings −0.5→ = \(rightFromMinus)") }
        if leftFromPlus != 1 { fails.append("crossings +0.5→ = \(leftFromPlus)") }
        if fromPlusRight != 0 { fails.append("crossings from +0.3 right = \(fromPlusRight)") }
        rows.append(Row(id: "P8 trim detents", pass: fails.isEmpty, detail: "\(detentChanges) detent changes over 1200 pt, spacing 16 pt, zero crossings 1/1/0" + (fails.isEmpty ? "" : "; " + fails.prefix(3).joined(separator: "; "))))
    }

    // P9 — reel.
    do {
        var fails: [String] = []
        var checked = 0
        for c in film.parsed {
            for edge in [c.start, c.end] {
                for d in [-0.05, 0.05] {
                    let media = edge + d
                    checked += 1
                    let reel = TheaterLogic.reel(track: track, media: media, placed: true, offset: 0)
                    let current = track.cueIndex(at: media)
                    let next: Int? = current.map { $0 + 1 < film.parsed.count ? $0 + 1 : nil } ?? track.nextCueIndex(after: media)
                    if reel.current != current { fails.append("current @\(fmt(media)) \(String(describing: reel.current)) vs \(String(describing: current))") }
                    if reel.next != next { fails.append("next @\(fmt(media)) \(String(describing: reel.next)) vs \(String(describing: next))") }
                    if let cur = current, reel.row(.current) != cur { fails.append("current row @\(fmt(media))") }
                    if current == nil, reel.row(.current) != nil { fails.append("current row between lines @\(fmt(media))") }
                }
            }
        }
        let unplaced = TheaterLogic.reel(track: track, media: 100, placed: false, offset: 0)
        if !unplaced.rows.isEmpty || unplaced.current != nil || unplaced.next != nil { fails.append("unplaced rows not empty") }
        if TheaterLogic.reelOffset(translationY: 56) != -1 { fails.append("offset(+56) ≠ −1") }
        if TheaterLogic.reelOffset(translationY: 112) != -2 { fails.append("offset(+112) ≠ −2") }
        if TheaterLogic.reelOffset(translationY: -56) != 1 { fails.append("offset(−56) ≠ 1") }
        for dy in stride(from: -27.0, through: 27.0, by: 1) where TheaterLogic.reelOffset(translationY: dy) != 0 { fails.append("offset(\(dy)) ≠ 0") }
        // Dragging one row down from a line shows the previous line as the centre.
        let mid = film.parsed[10].start + 0.1
        let shifted = TheaterLogic.reel(track: track, media: mid, placed: true, offset: -1)
        if shifted.centre != 9 || shifted.row(.current) != 9 { fails.append("offset −1 centre \(String(describing: shifted.centre))") }
        rows.append(Row(id: "P9 reel", pass: fails.isEmpty, detail: "\(checked) boundary probes, offsets ok" + (fails.isEmpty ? "" : "; " + fails.prefix(3).joined(separator: "; "))))
    }

    // P10 — control plan table (critique §4.2 + C7).
    do {
        var fails: [String] = []
        func expect(_ phase: SyncPhase, _ paused: Bool, _ plan: ControlPlan) {
            let st = IslandState(currentText: "", nextText: "", cueIndex: 0, cueCount: 0, trim: 0, phase: phase, isPaused: paused, rate: 1)
            let got = IslandLayout.controls(st)
            if got != plan { fails.append("\(phase)/\(paused): \(got) vs \(plan)") }
            if got.nudges, got.prominent.label.count > 7 { fails.append("\(phase)/\(paused): label '\(got.prominent.label)' > 7 chars with nudges") }
        }
        for paused in [false, true] {
            expect(.micLost, paused, ControlPlan(nudges: false, prominent: .openApp, pauseButton: false))
            expect(.ended, paused, ControlPlan(nudges: false, prominent: .none, pauseButton: false))
            expect(.ending, paused, ControlPlan(nudges: false, prominent: .keepListening, pauseButton: false))
            expect(.paused, paused, ControlPlan(nudges: true, prominent: .resume, pauseButton: false))
            expect(.autoPaused, paused, ControlPlan(nudges: true, prominent: .resume, pauseButton: false))
            expect(.recovering, paused, ControlPlan(nudges: true, prominent: .resume, pauseButton: false))
        }
        expect(.listening, false, ControlPlan(nudges: true, prominent: .pause, pauseButton: false))
        expect(.searching, false, ControlPlan(nudges: true, prominent: .pause, pauseButton: false))
        expect(.locked, false, ControlPlan(nudges: true, prominent: .resync, pauseButton: true))
        expect(.checkingIn, false, ControlPlan(nudges: true, prominent: .resync, pauseButton: true))
        expect(.drifting, false, ControlPlan(nudges: true, prominent: .resync, pauseButton: true))
        expect(.manual, false, ControlPlan(nudges: true, prominent: .listen, pauseButton: true))
        for phase in [SyncPhase.listening, .searching, .locked, .checkingIn, .drifting, .manual] {
            expect(phase, true, ControlPlan(nudges: true, prominent: .resume, pauseButton: false))
        }
        rows.append(Row(id: "P10 control plan", pass: fails.isEmpty, detail: "\(SyncPhase.allCases.count * 2) rows checked" + (fails.isEmpty ? "" : "; " + fails.prefix(3).joined(separator: "; "))))
    }

    // P11 — wrong film: never amber.
    do {
        let amber = wrong.samples.filter { BeaconStyle(phase: $0.state.phase, isPaused: $0.state.isPaused).color.isAmber }.count
        let placed = wrong.samples.filter { !$0.state.currentText.isEmpty }.count
        rows.append(Row(id: "P11 wrong film", pass: amber == 0 && placed == 0, detail: "\(amber) amber states, \(placed) placed states over \(wrong.samples.count) samples"))
    }

    // B1 — BeatDriver scripted cadence.
    do {
        let script: [(SyncPhase, Bool, Double)] = [(.listening, false, 10), (.searching, false, 100), (.locked, false, 120),
                                                   (.checkingIn, false, 15), (.locked, false, 60), (.paused, true, 30)]
        var driver = SimBeatDriver()
        var t = 0.0
        var perSegment: [Int] = []
        for (phase, paused, seconds) in script {
            let before = driver.emitted.count
            let end = t + seconds
            while t < end - 1e-9 {
                driver.step(now: t, active: BeaconStyle(phase: phase, isPaused: paused).pulses)
                t += 0.1
                t = (t * 10).rounded() / 10
            }
            perSegment.append(driver.emitted.count - before)
        }
        let searchBeats = perSegment[0] + perSegment[1]
        let fast = driver.emitted.prefix(90)
        let fastSpacingOK = zip(fast.dropFirst(), fast).allSatisfy { abs($0 - $1 - 1) < 1e-6 }
        let slow = Array(driver.emitted[90..<searchBeats])
        let slowSpacingOK = zip(slow.dropFirst(), slow).allSatisfy { abs($0 - $1 - 3) < 1e-6 }
        // 90 beats at 1 s (t = 0…89) then every 3 s (92…107) inside the 110 s: 96. island.md's
        // "≈ 97" is an estimate; 96 is what its own BeatDriver loop emits.
        let pass = searchBeats == 96 && fastSpacingOK && slowSpacingOK && perSegment[2] == 0 && perSegment[3] == 15 && perSegment[4] == 0 && perSegment[5] == 0
        rows.append(Row(id: "B1 beat cadence", pass: pass, detail: "listening+searching \(searchBeats) beats (90 @1 s, then @3 s), locked \(perSegment[2]), checkingIn \(perSegment[3]), locked \(perSegment[4]), paused \(perSegment[5])"))
    }

    // B2 — coalescing.
    do {
        var c = UpdateCoalescer<Int>()
        for i in 0..<20 { c.update(i + 1, now: Double(i) * 0.5 / 19) }
        c.flush(now: 2)
        let sends = c.sends
        let spacingOK = zip(sends.dropFirst(), sends).allSatisfy { $0.at - $1.at >= 0.25 - 1e-9 }
        let pass = sends.count <= 3 && sends.last?.state == 20 && spacingOK
        rows.append(Row(id: "B2 coalescing", pass: pass, detail: "\(sends.count) sends for 20 updates in 0.5 s, last = \(sends.last.map { String($0.state) } ?? "-"), min spacing ok \(spacingOK)"))
    }

    // L1 — lead compensation.
    do {
        let w = IslandLayout.boundaryWait(boundary: 1.0, media: 0, rate: 1, leadSeconds: 0.15)
        var floorOK = true
        var d = 0.0
        while d <= 0.5 { if IslandLayout.boundaryWait(boundary: d, media: 0, rate: 1, leadSeconds: 0.4) < 0.03 { floorOK = false }; d += 0.01 }
        let pass = abs(w - 0.86) <= 0.01 && floorOK
        rows.append(Row(id: "L1 lead compensation", pass: pass, detail: "wait \(fmt(w, 3)) s for a boundary 1.0 s away (want 0.86), floor 0.03 s ok \(floorOK)"))
    }

    print("Presenter suite (quiet room lock@\(quiet.lockAt.map { fmt($0, 0) } ?? "never") confirm@\(quiet.confirmedAt.map { fmt($0, 0) } ?? "never"); wrong film lock@\(wrong.lockAt.map { fmt($0, 0) } ?? "never"))")
    print("scenario                      result  detail")
    for r in rows {
        print(r.id.padding(toLength: 30, withPad: " ", startingAt: 0) + (r.pass ? "PASS    " : "FAIL    ") + r.detail)
    }
    let failed = rows.filter { !$0.pass }.count
    print("Presenter: \(rows.count - failed)/\(rows.count) passed")
}
