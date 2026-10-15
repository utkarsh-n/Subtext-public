import Foundation
import os

/// Ring of the last couple of minutes of 10 ms speech bins, stamped to the wall clock.
/// Written from the audio thread, read from the analysis queue.
final class MicRing: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var bins: [Float]
    private var write = 0
    private var total = 0
    private var startWall: Date?
    let capacity: Int

    init(seconds: Double = 120) {
        capacity = SpeechEnvelope.bin(for: seconds)
        bins = [Float](repeating: 0, count: capacity)
    }

    /// Call once with the wall time the first bin represents.
    func start(at wall: Date) {
        lock.withLock {
            startWall = wall
            write = 0
            total = 0
        }
    }

    /// Discard everything heard so far and stamp the next bin with `wall`. Used on a resume
    /// after an auto-pause so the correlator never sees paused-room audio. Same as `start(at:)`,
    /// named for intent.
    func restart(at wall: Date) {
        start(at: wall)
    }

    func append(_ values: [Float]) {
        lock.withLock {
            for v in values {
                bins[write] = v
                write = (write + 1) % capacity
                total += 1
            }
        }
    }

    var secondsRecorded: Double {
        lock.withLock { Double(min(total, capacity)) * SpeechEnvelope.binDuration }
    }

    /// Up to the last `seconds` of bins and the wall time of the first one returned.
    func latest(seconds: Double) -> (bins: [Float], start: Date)? {
        lock.withLock {
            guard let startWall, total > 0 else { return nil }
            let n = min(total, capacity, SpeechEnvelope.bin(for: seconds))
            var out = [Float](repeating: 0, count: n)
            var idx = (write - n + capacity) % capacity
            for i in 0..<n {
                out[i] = bins[idx]
                idx = (idx + 1) % capacity
            }
            let firstBin = total - n
            return (out, startWall.addingTimeInterval(Double(firstBin) * SpeechEnvelope.binDuration))
        }
    }
}
