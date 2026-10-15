import Foundation

// Foundation only: compiled into the app, the widget and the macOS harness.
// The per-state layout table of the Live Activity as data (docs/v2/island.md §1.6, critique C7,
// C16), so the harness can assert on it without SwiftUI.

/// The one prominent control in the Island's control row.
enum ProminentAction: Equatable, Sendable, CaseIterable {
    /// `ResyncIntent`: locked → wide pass then full; twice within 10 s → full.
    case resync
    /// `ResumeIntent`: idempotent resume (held clock; while auto-paused asserts hypothesis P).
    case resume
    /// `ResyncIntent` from manual: re-enables auto-sync (resync already sets `autoSync = true`).
    case listen
    /// `TogglePauseIntent` drawn prominent: while listening/searching the only action that makes
    /// sense is to freeze the clock (critique C7: no "Listen" button on the island).
    case pause
    /// `KeepListeningIntent`: the auto-end warning row.
    case keepListening
    /// A `Link` to `subtext://theater`: capture is dead, only the app can fix it.
    case openApp
    /// No prominent control (ended).
    case none

    /// Button label. ≤ 7 characters whenever the row also carries nudges, so it never wraps at
    /// 371 pt; the `keepListening` row has no nudges and may be longer.
    var label: String {
        switch self {
        case .resync: "Re-sync"
        case .resume: "Resume"
        case .listen: "Listen"
        case .pause: "Pause"
        case .keepListening: "Keep listening"
        case .openApp: "Open"
        case .none: ""
        }
    }

    var symbol: String {
        switch self {
        case .resync: "arrow.triangle.2.circlepath"
        case .resume: "play.fill"
        case .listen: "ear"
        case .pause: "pause.fill"
        case .keepListening: "ear.badge.waveform"
        case .openApp: "arrow.up.forward.app"
        case .none: ""
        }
    }
}

struct ControlPlan: Equatable, Sendable {
    /// The four nudge buttons (−½ −.1 · +.1 +½) flank the prominent control.
    var nudges: Bool
    var prominent: ProminentAction
    /// A small trailing pause button (`TogglePauseIntent`).
    var pauseButton: Bool

    var hasControls: Bool { nudges || pauseButton || prominent != .none }
}

enum IslandLayout {
    /// Width of the clear spacer in compact trailing when there is no line. 44 = fixed slot fallback
    /// if the resize at each line boundary looks jittery on device (island.md §0).
    static let compactEmptyWidth: Double = 6
    static let compactMaxWidth: Double = 96
    /// The expanded / Lock Screen cue slot never collapses, so nothing is needed to fill it.
    static let cueMinHeight: Double = 26
    /// Beacon core sizes per surface.
    static let beaconCompact: Double = 9
    static let beaconMinimal: Double = 8
    static let beaconExpanded: Double = 12
    static let beaconWatch: Double = 7
    static let beaconTheater: Double = 14

    /// Compact trailing: the current line on one row, or nil = render the clear spacer.
    /// Never a word. In landscape on iOS 27 (`limitedWidth`) the pill cannot grow, so only the dot.
    static func compactTrailing(_ s: IslandState, limitedWidth: Bool) -> String? {
        if limitedWidth || s.currentText.isEmpty { return nil }
        return s.currentText.replacingOccurrences(of: "\n", with: " ")
    }

    /// (primary, secondary). `primary == nil` → empty slot of `cueMinHeight`.
    static func cueBlock(_ s: IslandState) -> (primary: String?, secondary: String?) {
        let p = s.currentText.isEmpty ? nil : s.currentText
        let n = s.nextText.isEmpty ? nil : s.nextText
        return (p, n)
    }

    /// The expanded trailing label: a trim (human correction) or a rate; nil when both nominal.
    static func trailingLabel(_ s: IslandState) -> String? {
        if s.trim != 0 { return s.trim.trimLabel }
        if s.rate != 1 { return String(format: "%.2f×", s.rate) }
        return nil
    }

    /// Whether the cue text is drawn dimmed (held clock, doubtful lock).
    static func dimsText(_ s: IslandState) -> Bool {
        BeaconStyle.dimsLines(phase: s.phase, isPaused: s.isPaused)
    }

    /// The control row per state (critique §4.2 table + C7).
    static func controls(_ s: IslandState) -> ControlPlan {
        switch (s.isPaused, s.phase) {
        case (_, .micLost):
            return ControlPlan(nudges: false, prominent: .openApp, pauseButton: false)
        case (_, .ended):
            return ControlPlan(nudges: false, prominent: .none, pauseButton: false)
        case (_, .ending):
            return ControlPlan(nudges: false, prominent: .keepListening, pauseButton: false)
        case (true, _), (_, .autoPaused), (_, .paused), (_, .recovering):
            return ControlPlan(nudges: true, prominent: .resume, pauseButton: false)
        case (_, .listening), (_, .searching):
            return ControlPlan(nudges: true, prominent: .pause, pauseButton: false)
        case (_, .locked), (_, .checkingIn), (_, .drifting):
            return ControlPlan(nudges: true, prominent: .resync, pauseButton: true)
        case (_, .manual):
            return ControlPlan(nudges: true, prominent: .listen, pauseButton: true)
        }
    }

    /// A short caption drawn *under* the cue slot (never in it; critique C16) for states a dot
    /// alone cannot explain. nil for the live states. Stale rendering adds its own caption.
    static func caption(_ s: IslandState) -> String? {
        switch (s.isPaused, s.phase) {
        case (_, .micLost): return "Microphone lost · open Subtext"
        case (_, .ended): return "Ended — nothing heard for a while"
        case (_, .ending): return "Ending soon"
        case (_, .autoPaused): return "Paused · catches up when the film does"
        case (_, .recovering): return "Catching up"
        default: return nil
        }
    }

    static let staleCaption = "Open Subtext to resume"

    /// Words that must never appear in `currentText` / `nextText` (harness P1).
    static let forbiddenStrings = ["…", "Waiting", "Listening to the room", "Finding your place", "Searching", "Listening", "Paused"]

    /// The scheduler's sleep until a cue boundary: slightly early so the push lands on the glass
    /// on time (island.md §2.3, harness L1). Never below 0.03 s, never above 1 s.
    static func boundaryWait(boundary: Double, media: Double, rate: Double, leadSeconds: Double) -> Double {
        let raw = (boundary - media) / max(0.1, rate) + 0.01 - leadSeconds
        return min(1.0, max(0.03, raw))
    }
}

// MARK: - Beat cadence

/// The beat schedule while the beacon pulses: 1 Hz for the first `fastBeats` beats of an
/// activation, then 0.33 Hz (island.md §2.2). Pure, so the harness scripts it (B1).
enum BeatCadence {
    static let fastInterval: Double = 1.0
    static let slowInterval: Double = 3.0
    static let fastBeats = 90

    /// Seconds to wait after the `n`-th beat of the current activation (`n` counts from 1).
    static func interval(afterBeat n: Int) -> Double {
        n < fastBeats ? fastInterval : slowInterval
    }
}

// MARK: - Update coalescing model

/// The push-spacing rule of `LiveActivityController` as a pure value (harness B2): identical
/// states are dropped, pushes are ≥ `minSpacing` apart, and a push that arrives too soon waits
/// for the trailing edge (only the newest one survives, states being absolute).
struct UpdateCoalescer<State: Equatable> {
    static var minSpacing: Double { 0.25 }

    private(set) var lastSent: State?
    private(set) var lastSentAt: Double = -.infinity
    private(set) var pending: State?
    private(set) var flushAt: Double?
    private(set) var sends: [(at: Double, state: State)] = []

    init() {}

    /// Offer `state` at time `now`. Returns true when it was sent immediately.
    @discardableResult
    mutating func update(_ state: State, now: Double) -> Bool {
        if let at = flushAt, now >= at {
            // The trailing edge is due: this newest state is the one to push.
            pending = state
            flush(now: now)
            return true
        }
        guard state != lastSent else { return false }
        if now - lastSentAt >= Self.minSpacing {
            pending = nil
            flushAt = nil
            send(state, now: now)
            return true
        }
        pending = state
        if flushAt == nil { flushAt = lastSentAt + Self.minSpacing }
        return false
    }

    /// Deliver a pending trailing-edge push whose time has come.
    mutating func flush(now: Double) {
        guard let at = flushAt, now >= at else { return }
        flushAt = nil
        guard let p = pending else { return }
        pending = nil
        if p != lastSent { send(p, now: max(at, min(now, at + Self.minSpacing))) }
    }

    private mutating func send(_ state: State, now: Double) {
        lastSent = state
        lastSentAt = now
        sends.append((now, state))
    }
}
