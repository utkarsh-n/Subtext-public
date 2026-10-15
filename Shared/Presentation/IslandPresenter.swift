import Foundation

// Foundation only: this file compiles into the app, the widget and the macOS harness.
// No SwiftUI / WidgetKit imports here or in any other file under Shared/Presentation.

/// The cue lookups the presenter needs, so it does not depend on `SubtitleTrack` (which is
/// app-only). `SubtitleTrack` conforms in `SessionController.swift` (app) and
/// `Tools/synctest/Runner.swift` (harness).
protocol IslandCueSource {
    var cueCount: Int { get }
    func cueIndex(at media: Double) -> Int?
    func nextCueIndex(after media: Double) -> Int?
    func cueText(_ index: Int) -> String
    func cueEnd(_ index: Int) -> Double
}

/// What the presenter needs from the session and engine at one instant.
struct EngineSnapshot: Sendable {
    var phase: SyncPhase
    var isPaused: Bool
    /// Lines are shown (a lock has landed, the user placed the clock, or auto-sync is off).
    var placed: Bool
    var beat: Int
    var trim: Double
    var rate: Double
    var sessionStart: Date
    var checkInWindow: ClosedRange<Date>?
    var lastCheckInAt: Date?
    var nextCheckInAt: Date?
    var pauseReason: PauseReason = .none
    var endsAt: Date? = nil
}

struct PresenterOptions: Sendable {
    var showNextLine = false
    var showRing = true
    var listeningBudget: TimeInterval = 45
}

/// Turns a session snapshot into the `IslandState` the Live Activity renders
/// (docs/v2/island.md §1.5, critique §4.2).
///
/// Invariants the harness asserts (P1, P4–P7): text is "" unless `placed` and never a
/// placeholder; `trim` is rounded to 0.1; `beat` is frozen at 0 unless `BeaconStyle.pulses`;
/// a ring only in the three live states with `ringEnd > ringStart`; `nextCheckInAt` only while
/// locked and running; `endsAt` only while ending. All dates are wall dates (critique C16: the
/// engine's monotonic dates are converted at the boundary, before they get here).
enum IslandPresenter {
    /// Phases whose beacon pulses (receives beat updates).
    static func pulses(_ phase: SyncPhase, isPaused: Bool) -> Bool {
        BeaconStyle(phase: phase, isPaused: isPaused).pulses
    }

    static func state(track: some IslandCueSource, media: Double, snapshot s: EngineSnapshot,
                      options o: PresenterOptions, now: Date) -> IslandState {
        let current = s.placed ? track.cueIndex(at: media) : nil
        let next: Int? = {
            guard s.placed else { return nil }
            if let c = current { return track.nextCueIndex(after: track.cueEnd(c) - 0.001).flatMap { $0 > c ? $0 : nil } }
            return track.nextCueIndex(after: media)
        }()

        var ring: ClosedRange<Date>? = nil
        var kind = RingKind.none
        if o.showRing {
            switch (s.isPaused, s.phase) {
            case (false, .checkingIn):
                if let w = s.checkInWindow, w.upperBound > w.lowerBound { ring = w; kind = .checkIn }
            case (false, .locked):
                if let a = s.lastCheckInAt, let b = s.nextCheckInAt, b > a { ring = a...b; kind = .schedule }
            case (false, .listening), (false, .searching):
                let end = s.sessionStart.addingTimeInterval(o.listeningBudget)
                if end > now, end > s.sessionStart { ring = s.sessionStart...end; kind = .listening }
            default:
                break
            }
        }

        let style = BeaconStyle(phase: s.phase, isPaused: s.isPaused)
        return IslandState(
            currentText: current.map { track.cueText($0) } ?? "",
            nextText: o.showNextLine ? (next.map { track.cueText($0) } ?? "") : "",
            cueIndex: current ?? next ?? 0,
            cueCount: track.cueCount,
            trim: (s.trim * 10).rounded() / 10,
            phase: s.phase,
            isPaused: s.isPaused,
            rate: s.rate,
            beat: style.pulses ? s.beat : 0,
            ringStart: ring?.lowerBound,
            ringEnd: ring?.upperBound,
            ringKind: kind,
            nextCheckInAt: (!s.isPaused && s.phase == .locked) ? s.nextCheckInAt : nil,
            pauseReason: s.pauseReason,
            endsAt: s.phase == .ending ? s.endsAt : nil)
    }
}
