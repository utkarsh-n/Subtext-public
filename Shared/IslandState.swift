import Foundation

/// Why the display clock is frozen. `.auto` is the presence latch; `.user` is a button.
enum PauseReason: String, Codable, Hashable, Sendable {
    case none, user, auto
}

/// Which date-relative ring the expanded Island / Lock Screen draws around the beacon.
enum RingKind: String, Codable, Hashable, Sendable {
    case none, listening, schedule, checkIn
}

/// Everything the Live Activity renders. This is `SubtextActivityAttributes.ContentState`.
/// Foundation only, so the harness can assert on it (docs/v2/island.md §1.2 + critique §4.2).
///
/// Rules: `currentText`/`nextText` are "" between lines, never a placeholder; `trim` is
/// rounded to 0.1 s before it gets here; `beat` is 0 whenever the beacon does not pulse.
struct IslandState: Codable, Hashable, Sendable {
    /// The line on screen right now ("" between lines).
    var currentText: String
    /// The line that follows ("" unless Settings "Show the next line" is on).
    var nextText: String
    var cueIndex: Int
    var cueCount: Int
    /// Seconds the user has nudged on top of auto sync. Positive = later.
    var trim: Double
    var phase: SyncPhase
    var isPaused: Bool
    /// Playback speed relative to the subtitle track (1.0 nominal).
    var rate: Double
    /// Pulse counter while listening/searching/checking; 0 otherwise.
    var beat: Int = 0
    /// `ClosedRange<Date>` encoded as two optionals (Codable-friendly).
    var ringStart: Date? = nil
    var ringEnd: Date? = nil
    var ringKind: RingKind = .none
    /// Lock Screen countdown text while locked-in.
    var nextCheckInAt: Date? = nil
    var pauseReason: PauseReason = .none
    /// Auto-end countdown target while `phase == .ending`.
    var endsAt: Date? = nil

    var ring: ClosedRange<Date>? {
        guard let a = ringStart, let b = ringEnd, b > a else { return nil }
        return a...b
    }
}

extension Double {
    /// "+0.4s" / "−1.2s" / "0.0s"
    var trimLabel: String {
        let rounded = (self * 10).rounded() / 10
        if rounded == 0 { return "0.0s" }
        return String(format: "%@%.1fs", rounded > 0 ? "+" : "−", abs(rounded))
    }
}
