import Foundation

// Pure Foundation. Compiled into the app and into Tools/synctest (Subtext/Sync/Logic/**).
//
// docs/v2/checkin.md §2, critique R13: every `Date` the engine, the scheduler, the belief clock
// and the rate estimator see comes from one monotonic `Timebase`, never from `Date.now`. The
// only wall-clock conversion is at the Island boundary (`wallDate(for:)`), because
// `Text(timerInterval:)` needs wall dates. The harness supplies `SimTimebase` (Runner.swift) and
// adopts this protocol in `Tools/synctest/ScenariosCheckIn.swift`.

/// The engine's source of time. `now` must be monotonic within a session; a wall-clock step
/// (`NSSystemClockDidChange`) must not move it.
protocol Timebase: AnyObject {
    /// Monotonic session time expressed as a `Date` (origin + elapsed `ContinuousClock` time).
    var now: Date { get }
    /// Wall-clock date for an engine date (Island presenter only; critique C16).
    func wallDate(for engineDate: Date) -> Date
    /// Engine date for a wall-clock date (`NowPlayingView` `TimelineView` dates).
    func engineDate(fromWall wall: Date) -> Date
}

/// `origin + (ContinuousClock.now − originInstant)`. `ContinuousClock` keeps incrementing while
/// the system sleeps, so a locked phone does not stretch or shrink engine time.
final class SystemTimebase: Timebase {
    let origin: Date
    private let originInstant: ContinuousClock.Instant
    /// wall − engine, measured at session start and whenever the system clock changes
    /// (`remeasureWallOffset()`; the engine calls it from `NSSystemClockDidChange`).
    private(set) var wallOffset: TimeInterval = 0

    init(origin: Date = Date()) {
        self.origin = origin
        originInstant = ContinuousClock.now
    }

    /// Seconds since the session started, from the continuous clock.
    var elapsed: TimeInterval {
        Self.seconds(originInstant.duration(to: ContinuousClock.now))
    }

    var now: Date { origin.addingTimeInterval(elapsed) }

    func remeasureWallOffset() {
        wallOffset = Date().timeIntervalSince(now)
    }

    func wallDate(for engineDate: Date) -> Date { engineDate.addingTimeInterval(wallOffset) }

    func engineDate(fromWall wall: Date) -> Date { wall.addingTimeInterval(-wallOffset) }

    static func seconds(_ d: Duration) -> TimeInterval {
        let c = d.components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}
