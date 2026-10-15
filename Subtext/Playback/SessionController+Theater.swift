import Foundation
import Observation

// WP5: the beacon's beat and the Theater's view of the session. New members only; the
// stored state and the V1 bodies live in SessionController.swift (WP0).

extension SessionController {
    /// One driver for the one session (`SessionController` is a singleton).
    static let beatDriver = BeatDriver()

    var beat: Int { Self.beatDriver.beat }

    var beaconStyle: BeaconStyle { BeaconStyle(phase: phase, isPaused: clock.isPaused) }

    /// The beacon pulses (1 Hz beats → pushes) only while the style says so, the activity is on
    /// and `island.pulse` is on. Off = static dot, zero extra updates.
    var beatShouldRun: Bool {
        isActive && liveActivityEnabled && islandPulse && beaconStyle.pulses
    }

    /// `snapshot()` with the live beat.
    ///
    /// TODO(WP7): `SessionController.snapshot()` (WP0) hard-codes `beat: 0`, and `contentState()`
    /// passes `showNextLine: true`. Replace those two values with `Self.beatDriver.beat` and
    /// `showNextLine` so that beat pushes reach the glass; until then every `onBeat` push is
    /// identical to the previous state and `LiveActivityController` drops it (static dot).
    func beatSnapshot() -> EngineSnapshot {
        var s = snapshot()
        s.beat = beat
        return s
    }

    /// The `IslandState` as WP5 means it: beat included, the next line only when the setting is on.
    func islandState(now: Date = .now) -> IslandState {
        guard let track else {
            return IslandState(currentText: "", nextText: "", cueIndex: 0, cueCount: 0, trim: trim, phase: phase,
                               isPaused: clock.isPaused, rate: clock.rate, pauseReason: pauseReason)
        }
        return IslandPresenter.state(track: track, media: mediaTime(at: now), snapshot: beatSnapshot(),
                                     options: PresenterOptions(showNextLine: showNextLine, showRing: islandRing), now: now)
    }

    /// Start or stop the beat for the current state. Called from the observation below on every
    /// phase / pause / setting change, and directly by the Theater after its own actions.
    func syncBeat() {
        let driver = Self.beatDriver
        if driver.onBeat == nil {
            driver.onBeat = { [weak self] in self?.pushState() }
        }
        driver.set(active: beatShouldRun)
    }

    /// Re-armed observation of everything `beatShouldRun` reads. Call once at launch
    /// (`SubtextApp.init`); it keeps itself alive.
    func startBeatObservation() {
        withObservationTracking {
            _ = self.isActive
            _ = self.liveActivityEnabled
            _ = self.islandPulse
            _ = self.autoSync
            _ = self.pauseReason
            _ = self.clock
            _ = self.engine.phase
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.syncBeat()
                self.startBeatObservation()
            }
        }
        syncBeat()
    }

    // MARK: Theater

    var theaterTextSize_: TheaterLogic.TextSize {
        get { TheaterLogic.TextSize(rawValue: theaterTextSize) ?? .large }
        set { theaterTextSize = newValue.rawValue }
    }

    /// Lines are drawn in the Theater: a lock landed, the user placed the clock, auto-sync is
    /// off, or the clock is held on a line.
    var theaterPlaced: Bool {
        isPlaced || !autoSync || clock.isPaused
    }

    /// Undo for the last `jump(toCue:)` is still open.
    var canUndoJump: Bool {
        guard let until = jumpUndoUntil else { return false }
        return Date.now <= until
    }
}
