import Foundation

// Pure Foundation. Compiled into the app and into Tools/synctest (Subtext/Sync/Logic/**).
//
// WP0 fixes the names of the states and actions that cross package boundaries so that
// WP1–WP6 can compile against them. Owners:
//   MicState        — set by AudioCapture (WP1). Do not redefine it there; adopt this one.
//   SchedulerState  — CheckInScheduler (WP2) may `typealias State = SchedulerState` or map onto it.
//   PresenceState / PresenceFeatures / PresenceEvidence / EndReason — PresenceTracker (WP3) likewise.
//   SessionAction   — emitted by the engine, applied by SessionController (WP7 wires the bodies).
//   Correction, CheckInInterval, AutoPausePatience — session-level value types (critique §4.3, §5).

/// What the capture engine is actually doing (never the policy's intent; critique C1, A D7).
enum MicState: Equatable, Sendable {
    /// Input running; continuous search/track.
    case listening
    /// Input running; brain idle between check-ins (locked-in).
    case openIdle
    /// Input running; a check-in is in progress.
    case checking
    /// The system took the session (call, Siri).
    case interrupted
    /// Could not (re)open; reason for the UI.
    case unavailable(String)

    /// Status copy per docs/v2/keepalive.md §8 (minus `.released`, cut by critique D1).
    var copy: String {
        switch self {
        case .listening: "Listening to the room"
        case .openIdle: "Locked in · mic open, idle"
        case .checking: "Checking…"
        case .interrupted: "Paused by a call or Siri"
        case .unavailable(let reason): reason + " Open Subtext to re-sync."
        }
    }
}

/// Why a session ended on its own.
enum EndReason: Sendable, Equatable {
    case silence(minutes: Int)
    case neverHeard
    case timeLimit
}

/// The session state machine of critique §4.2. Owned by `CheckInScheduler` (WP2); the engine
/// publishes it and `SessionController` maps it to `SyncPhase` via `phase`.
enum SchedulerState: Sendable, Equatable {
    case idle
    /// V1 listening/searching/candidate. `audioSeconds` decides listening vs searching.
    case acquiring(audioSeconds: Double)
    case lockedIn
    case checkingIn(attempt: Int)
    case held(source: PauseReason, since: Date)
    case resuming(since: Date, attempt: Int)
    case probing(since: Date)
    case lost(since: Date, misses: Int)
    case reacquiring(since: Date)
    case ending(endsAt: Date)
    case ended(reason: EndReason)
    case manual
    case micLost

    /// The §4.2 table. `minAudio` is the tracker's `minWindowSeconds`.
    func phase(minAudio: Double = 12) -> SyncPhase {
        switch self {
        case .idle: .listening
        case .acquiring(let s): s < minAudio ? .listening : .searching
        case .lockedIn, .resuming: .locked
        case .checkingIn: .checkingIn
        case .held(let source, _): source == .auto ? .autoPaused : .paused
        case .probing: .recovering
        case .lost: .drifting
        case .reacquiring: .searching
        case .ending: .ending
        case .ended: .ended
        case .manual: .manual
        case .micLost: .micLost
        }
    }

    var isPaused: Bool {
        switch self {
        case .held, .probing, .ending, .ended: true
        default: false
        }
    }
}

/// One tick's classification of what the mic hears (docs/v2/latch.md §4.1).
enum PresenceEvidence: Sendable, Equatable { case present, absent, hold, none }

/// Per-tick presence features (docs/v2/latch.md §2.2), for the debug row and the harness.
struct PresenceFeatures: Sendable, Equatable {
    var level: Float = 0
    var peak: Float = 0
    var depth: Float = 0
    var modRatio: Float = 0
    var speechFraction: Float = 0
    var fluxSpread: Float = 0
    var tvDistance: Float? = nil
    var roomDistance: Float? = nil
    var expectedDialogue: Double? = nil
    var evidence: PresenceEvidence = .none
}

/// The latch state machine of docs/v2/latch.md §4.4 (owned by `PresenceTracker`, WP3).
enum PresenceState: Sendable, Equatable {
    case playing
    case suspect(since: Date)
    case paused(frozenMedia: Double, since: Date)
    case resuming(frozenMedia: Double, pausedWall: Date)
    case probing(frozenMedia: Double, pausedWall: Date, since: Date)
    case ending(frozenMedia: Double, endsAt: Date)
    case ended(reason: EndReason)
}

/// A measured clock correction waiting to be applied (docs/v2/checkin.md §5). Backward
/// corrections < 1 s are deferred to the next cue boundary or 3 s, whichever comes first.
struct Correction: Sendable, Equatable {
    /// Media time at `at`.
    var media: Double
    var at: Date
    var rate: Double
    /// measured − predicted, propagated to `at`.
    var residual: Double
    /// Apply no later than this (nil = now).
    var deferUntil: Date? = nil
}

/// Clock / UI actions the engine's scheduler asks `SessionController` to perform. The engine
/// executes its own actions (check-ins, probes, transcriber, capture) and forwards these.
/// `SessionController` is the only writer of the display clock (critique D5).
enum SessionAction: Sendable, Equatable {
    case setClock(Correction)
    case holdClock(at: Date, reason: PauseReason)
    case resumeClock(at: Date)
    case status(SchedulerState)
    case warn(endsAt: Date)
    case clearWarning
    case endSession(EndReason)
    /// Seconds caught up after a pause (drives the "Caught up −38 s" toast).
    case caughtUp(seconds: Double)
}

/// `lockedIn.checkIn` setting values (critique §4.3).
enum CheckInInterval: String, CaseIterable, Codable, Sendable {
    case adaptive = "adaptive"
    case s30 = "30"
    case m1 = "60"
    case m2 = "120"
    case m5 = "300"
    case manual = "manual"

    /// Fixed interval in seconds; nil for adaptive and manual.
    var fixedSeconds: Double? {
        switch self {
        case .adaptive, .manual: nil
        default: Double(rawValue)
        }
    }
}

/// `autoPause.patience` setting values: confirm times 6 s / 10 s (normal) or 12 s / 20 s (patient).
enum AutoPausePatience: String, CaseIterable, Codable, Sendable {
    case normal, patient

    var confirmDialogueSeconds: Double { self == .normal ? 6 : 12 }
    var confirmAbsentSeconds: Double { self == .normal ? 10 : 20 }
}
