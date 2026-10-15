import Foundation

/// The beat behind the beacon's bloom while it pulses: 1 Hz for the first 90 beats of an
/// activation, then every 3 s (`BeatCadence`, docs/v2/island.md §2.2). Each beat is one Live
/// Activity push. Zero beats while locked, paused, manual or when `island.pulse` is off.
@MainActor
final class BeatDriver {
    private var task: Task<Void, Never>?
    /// Monotonic counter; the Island blooms on even beats and clears on odd ones.
    private(set) var beat = 0
    /// Beats of the current activation (resets when the driver restarts).
    private(set) var beatsThisRun = 0
    var onBeat: (() -> Void)?

    var isActive: Bool { task != nil }

    func set(active: Bool) {
        if active {
            guard task == nil else { return }
            beatsThisRun = 0
            task = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    self.beat &+= 1
                    self.beatsThisRun += 1
                    self.onBeat?()
                    let wait = BeatCadence.interval(afterBeat: self.beatsThisRun)
                    try? await Task.sleep(for: .seconds(wait))
                }
            }
        } else {
            task?.cancel()
            task = nil
        }
    }

    deinit {
        task?.cancel()
    }
}
