import Foundation

/// Ring of the last couple of minutes of 10 ms mel frames (24 floats each) plus one frame
/// log-energy per frame, stamped to the wall clock exactly like `MicRing`: `start(at:)` with
/// the wall time of the first frame, then frame *i* describes the same instant as `MicRing`
/// bin *i*. Written on `featureQueue`, read on `analysisQueue`.
///
/// Capacity 120 s × 100 frames × 24 floats ≈ 1.15 MB.
final class MelRing: @unchecked Sendable {
    static let bands = MelExtractor.bands
    static let frameSeconds = MelExtractor.hopSeconds

    private let lock = NSLock()
    private var frames: [Float]
    private var levels: [Float]
    private var write = 0
    private var total = 0
    private var startWall: Date?
    /// Capacity in frames.
    let capacity: Int

    init(seconds: Double = 120) {
        capacity = max(1, Int((seconds / Self.frameSeconds).rounded()))
        frames = [Float](repeating: 0, count: capacity * Self.bands)
        levels = [Float](repeating: 0, count: capacity)
    }

    /// Call once with the wall time the first frame represents (the same instant `MicRing.start`
    /// got, so the two rings stay index-aligned).
    func start(at wall: Date) {
        lock.lock(); defer { lock.unlock() }
        startWall = wall
        write = 0
        total = 0
    }

    func restart(at wall: Date) { start(at: wall) }

    /// Appends `count` frames (`count × bands` floats) and, optionally, their log-energies.
    func append(_ values: [Float], count: Int, levels newLevels: [Float] = []) {
        guard count > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        values.withUnsafeBufferPointer { src in
            for f in 0..<count {
                let dst = write * Self.bands
                for b in 0..<Self.bands { frames[dst + b] = src[f * Self.bands + b] }
                levels[write] = f < newLevels.count ? newLevels[f] : 0
                write = (write + 1) % capacity
                total += 1
            }
        }
    }

    var secondsRecorded: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(min(total, capacity)) * Self.frameSeconds
    }

    /// Wall time of the frame that would be written next (i.e. the end of what is stored).
    var endWall: Date? {
        lock.lock(); defer { lock.unlock() }
        return startWall?.addingTimeInterval(Double(total) * Self.frameSeconds)
    }

    /// Up to the last `seconds` of frames, their log-energies, and the wall time of the first.
    func latest(seconds: Double) -> (frames: [Float], levels: [Float], count: Int, start: Date)? {
        lock.lock(); defer { lock.unlock() }
        guard let startWall, total > 0 else { return nil }
        let n = min(total, capacity, Int((seconds / Self.frameSeconds).rounded()))
        guard n > 0 else { return nil }
        let first = total - n
        return (copyLocked(firstFrame: first, count: n), copyLevelsLocked(firstFrame: first, count: n), n,
                startWall.addingTimeInterval(Double(first) * Self.frameSeconds))
    }

    /// The frames for an absolute wall span, if the whole span is still in the ring.
    func window(from wallStart: Date, seconds: Double) -> (frames: [Float], levels: [Float], count: Int, start: Date)? {
        lock.lock(); defer { lock.unlock() }
        guard let startWall, total > 0, seconds > 0 else { return nil }
        let first = Int((wallStart.timeIntervalSince(startWall) / Self.frameSeconds).rounded())
        let n = Int((seconds / Self.frameSeconds).rounded())
        guard n > 0, first >= max(0, total - capacity), first + n <= total else { return nil }
        return (copyLocked(firstFrame: first, count: n), copyLevelsLocked(firstFrame: first, count: n), n,
                startWall.addingTimeInterval(Double(first) * Self.frameSeconds))
    }

    private func copyLocked(firstFrame: Int, count n: Int) -> [Float] {
        var out = [Float](repeating: 0, count: n * Self.bands)
        var idx = ((firstFrame % capacity) + capacity) % capacity
        out.withUnsafeMutableBufferPointer { dst in
            frames.withUnsafeBufferPointer { src in
                for i in 0..<n {
                    (dst.baseAddress! + i * Self.bands).update(from: src.baseAddress! + idx * Self.bands, count: Self.bands)
                    idx = (idx + 1) % capacity
                }
            }
        }
        return out
    }

    private func copyLevelsLocked(firstFrame: Int, count n: Int) -> [Float] {
        var out = [Float](repeating: 0, count: n)
        var idx = ((firstFrame % capacity) + capacity) % capacity
        for i in 0..<n { out[i] = levels[idx]; idx = (idx + 1) % capacity }
        return out
    }
}
