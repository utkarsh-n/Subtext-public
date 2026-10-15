import Foundation

/// How confident the app is that the subtitles are in step with the room, as shown to the
/// user (Island, Lock Screen, Watch, in-app). One enum for every surface; Foundation only so
/// it compiles into the app, the widget and the macOS harness.
///
/// Mapping from the session state machine (docs/v2/critique.md §4.2):
/// acquiring → listening/searching · lockedIn/resuming → locked · checkingIn → checkingIn ·
/// held(.user) → paused · held(.auto) → autoPaused · probing → recovering · lost → drifting ·
/// reacquiring → searching · ending → ending · ended → ended · manual → manual · micLost → micLost.
enum SyncPhase: String, Codable, Hashable, Sendable, CaseIterable {
    /// Microphone running, not enough audio heard yet.
    case listening
    /// Looking for a match (full or hinted correlation; also the tracker's candidate state).
    case searching
    /// Matched and tracking, or locked-in with scheduled check-ins.
    case locked
    /// A timed narrow re-correlation is running (≤ 2 s).
    case checkingIn
    /// The user froze the clock.
    case paused
    /// The engine froze the clock: the room went quiet where the film should be playing.
    case autoPaused
    /// Sound is back after an auto-pause but not yet identified; the clock stays frozen.
    case recovering
    /// Was locked, recent windows disagree; widening the search. Lines stay, dimmed.
    case drifting
    /// Auto-end warning: nothing heard for a long time, ending soon unless told otherwise.
    case ending
    /// The session ended on its own (silence or the 8 h limit).
    case ended
    /// Auto-sync turned off; the user drives timing by hand.
    case manual
    /// Capture is not running: interruption, route loss or permission revoked.
    case micLost

    var label: String {
        switch self {
        case .listening: "Listening"
        case .searching: "Searching"
        case .locked: "In sync"
        case .checkingIn: "Checking sync"
        case .paused: "Paused"
        case .autoPaused: "Paused — film is silent"
        case .recovering: "Catching up"
        case .drifting: "Drifting"
        case .ending: "Ending soon"
        case .ended: "Ended"
        case .manual: "Manual"
        case .micLost: "Microphone lost"
        }
    }

    var symbol: String {
        switch self {
        case .listening: "ear"
        case .searching: "waveform.badge.magnifyingglass"
        case .locked: "checkmark.circle.fill"
        case .checkingIn: "waveform.circle"
        case .paused: "pause.circle.fill"
        case .autoPaused: "pause.circle"
        case .recovering: "arrow.clockwise.circle"
        case .drifting: "arrow.left.arrow.right.circle"
        case .ending: "timer"
        case .ended: "stop.circle"
        case .manual: "hand.raised.fill"
        case .micLost: "mic.slash"
        }
    }

    /// The clock is held (frozen) in this phase.
    var holdsClock: Bool {
        switch self {
        case .paused, .autoPaused, .recovering, .ending, .ended: true
        default: false
        }
    }
}
