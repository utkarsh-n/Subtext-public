import Foundation

// Foundation only: compiled into the app, the widget and the macOS harness.

/// The beacon's colour. White = not trustworthy yet / human-owned; amber = trust the lines;
/// red = trouble. Opacity carries "how sure".
enum BeaconColor: Equatable, Sendable {
    case white(opacity: Double)
    case amber(opacity: Double)
    case red

    var isAmber: Bool { if case .amber = self { return true } else { return false } }
}

/// How the beacon is drawn for one `(phase, isPaused)` pair. The one table every surface
/// (Island, Lock Screen, Watch, Theater, status card) reads (docs/v2/island.md §1.4 with the
/// `recovering` / `ending` / `ended` rows from critique §4.2).
///
/// Filled = clock running under our control; hollow = clock held; pulses = receives beat
/// updates (in-app: breathes); glows = steady halo; blinksOnCue = one transition per line change.
struct BeaconStyle: Equatable, Sendable {
    let color: BeaconColor
    let pulses: Bool
    let glows: Bool
    let hollow: Bool
    let blinksOnCue: Bool
    let accessibilityLabel: String

    init(color: BeaconColor, pulses: Bool, glows: Bool, hollow: Bool, blinksOnCue: Bool, accessibilityLabel: String) {
        self.color = color
        self.pulses = pulses
        self.glows = glows
        self.hollow = hollow
        self.blinksOnCue = blinksOnCue
        self.accessibilityLabel = accessibilityLabel
    }

    init(phase: SyncPhase, isPaused: Bool) {
        switch (isPaused, phase) {
        case (_, .micLost):
            self.init(color: .red, pulses: false, glows: false, hollow: true, blinksOnCue: false, accessibilityLabel: "Microphone lost")
        case (_, .ended):
            self.init(color: .white(opacity: 0.35), pulses: false, glows: false, hollow: true, blinksOnCue: false, accessibilityLabel: "Ended")
        case (_, .ending):
            self.init(color: .amber(opacity: 0.6), pulses: false, glows: false, hollow: true, blinksOnCue: false, accessibilityLabel: "Ending soon")
        case (_, .recovering):
            // Sound is back after an auto-pause, clock still frozen: hollow but alive.
            self.init(color: .white(opacity: 0.85), pulses: true, glows: false, hollow: true, blinksOnCue: false, accessibilityLabel: "Catching up")
        case (_, .autoPaused):
            self.init(color: .amber(opacity: 0.6), pulses: false, glows: false, hollow: true, blinksOnCue: false, accessibilityLabel: "Paused, film is silent")
        case (true, _), (_, .paused):
            self.init(color: .white(opacity: 0.55), pulses: false, glows: false, hollow: true, blinksOnCue: false, accessibilityLabel: "Paused")
        case (_, .listening):
            self.init(color: .white(opacity: 0.45), pulses: true, glows: false, hollow: false, blinksOnCue: false, accessibilityLabel: "Listening")
        case (_, .searching), (_, .drifting):
            self.init(color: .white(opacity: 0.85), pulses: true, glows: false, hollow: false, blinksOnCue: false, accessibilityLabel: "Searching")
        case (_, .checkingIn):
            self.init(color: .amber(opacity: 1), pulses: true, glows: true, hollow: false, blinksOnCue: false, accessibilityLabel: "Checking sync")
        case (_, .locked):
            self.init(color: .amber(opacity: 1), pulses: false, glows: true, hollow: false, blinksOnCue: true, accessibilityLabel: "In sync")
        case (_, .manual):
            self.init(color: .white(opacity: 0.95), pulses: false, glows: false, hollow: false, blinksOnCue: false, accessibilityLabel: "Manual timing")
        }
    }

    /// Lines are drawn dimmed (0.55) in these states: the clock is held or the lock is doubtful.
    /// `.searching` is included because lines are only ever on screen in that phase while the
    /// lock is doubtful: a relisten, V1's unconfirmed candidate, or WP7's `reacquiring`
    /// (critique §4.2: "lines dimmed (isPlaced sticky)"). Unplaced searching has no lines to dim.
    static func dimsLines(phase: SyncPhase, isPaused: Bool) -> Bool {
        if isPaused { return true }
        switch phase {
        case .paused, .autoPaused, .recovering, .ending, .ended, .drifting, .searching: return true
        default: return false
        }
    }
}
