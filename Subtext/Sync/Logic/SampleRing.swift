import Foundation
import os

/// Ring of the last couple of seconds of raw mono Float samples.
///
/// Written on the audio thread from `SyncEngine.onFeatureSamples` (a memcpy, nothing else),
/// drained on `featureQueue` by the presence analyser (WP3) and the mel extractor (WP4)
/// (docs/v2/critique.md C4: one ring, one serial feature queue). Foundation + os only, so it
/// compiles into the macOS harness (`SCENARIOS=audio`; `Tools/synctest/audio/run.sh` runs the same
/// checks standalone).
///
/// Two readers are served from one ring:
/// - `drain()` is the FIFO view: every sample exactly once, in order, with an explicit count of
///   samples lost when the consumer fell more than one ring behind.
/// - `latest(seconds:)` is the snapshot view: the most recent `seconds` of audio, regardless of
///   what has been drained, for a consumer that wants a window rather than a stream.
///
/// The sample rate is only known once the first tap buffer arrives, so the ring reconfigures
/// itself (and discards its content) when `append(_:sampleRate:)` sees a different rate.
final class SampleRing: @unchecked Sendable {
    /// Seconds of audio the ring holds (critique C4: 2 s).
    let seconds: Double
    private let lock = OSAllocatedUnfairLock()
    private var buffer: [Float]
    private var rate: Double
    private var capacity: Int
    private var write = 0
    /// Samples ever appended since the last reset.
    private var total = 0
    /// Samples consumed by `drain` since the last reset.
    private var consumed = 0
    private var dropped = 0
    private var drainScheduled = false

    init(seconds: Double = 2, sampleRate: Double = 16_000) {
        self.seconds = seconds
        rate = sampleRate
        capacity = max(1, Int((seconds * sampleRate).rounded(.up)))
        buffer = [Float](repeating: 0, count: capacity)
    }

    // MARK: Writing (audio thread)

    /// Copy `samples` in. If `sampleRate` differs from the ring's, the ring is resized for the
    /// new rate and everything heard so far is discarded (the rate only changes on a rebuild).
    func append(_ samples: UnsafeBufferPointer<Float>, sampleRate: Double) {
        // lock()/unlock() rather than withLock: the pointer is not Sendable and must not be
        // captured by a @Sendable closure.
        lock.lock()
        defer { lock.unlock() }
        if sampleRate != rate, sampleRate > 0 { reconfigureLocked(sampleRate: sampleRate) }
        appendLocked(samples)
    }

    /// Copy `samples` in at the ring's current rate.
    func append(_ samples: UnsafeBufferPointer<Float>) {
        lock.lock()
        defer { lock.unlock() }
        appendLocked(samples)
    }

    func append(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { append($0) }
    }

    private func appendLocked(_ samples: UnsafeBufferPointer<Float>) {
        guard let base = samples.baseAddress, samples.count > 0 else { return }
        var source = base
        var remaining = samples.count
        if remaining >= capacity {
            // More than a whole ring in one call: only the tail can survive.
            source += remaining - capacity
            remaining = capacity
            total += samples.count - capacity
        }
        buffer.withUnsafeMutableBufferPointer { dst in
            let first = min(remaining, capacity - write)
            dst.baseAddress!.advanced(by: write).update(from: source, count: first)
            if remaining > first {
                dst.baseAddress!.update(from: source + first, count: remaining - first)
            }
        }
        write = (write + remaining) % capacity
        total += remaining
        // Anything the reader has not consumed and that is now overwritten is lost for good.
        if total - consumed > capacity {
            dropped += total - consumed - capacity
            consumed = total - capacity
        }
    }

    private func reconfigureLocked(sampleRate: Double) {
        rate = sampleRate
        capacity = max(1, Int((seconds * sampleRate).rounded(.up)))
        buffer = [Float](repeating: 0, count: capacity)
        write = 0
        total = 0
        consumed = 0
    }

    /// Discard everything heard so far (session start, rebuilds). Keeps the drop counter.
    func reset() {
        lock.withLock {
            write = 0
            total = 0
            consumed = 0
        }
    }

    // MARK: Reading (feature queue)

    var sampleRate: Double { lock.withLock { rate } }

    /// Samples appended since the last `drain`, capped at one ring.
    var unreadCount: Int { lock.withLock { min(total - consumed, capacity) } }

    /// Seconds of audio currently held (≤ `seconds`).
    var secondsAvailable: Double { lock.withLock { Double(min(total, capacity)) / rate } }

    /// Samples overwritten before any `drain` consumed them, since init.
    var droppedSamples: Int { lock.withLock { dropped } }

    /// Every sample not yet drained, oldest first. Empty when there is nothing new.
    func drain() -> [Float] {
        lock.withLock {
            let n = min(total - consumed, capacity)
            guard n > 0 else { return [] }
            var out = [Float](repeating: 0, count: n)
            let start = (write - n + capacity) % capacity
            copyLocked(from: start, count: n, into: &out)
            consumed = total
            return out
        }
    }

    /// The most recent `seconds` of audio (fewer if the ring has not filled yet), oldest first.
    /// Does not consume anything.
    func latest(seconds window: Double) -> [Float] {
        lock.withLock {
            let n = min(total, capacity, Int((window * rate).rounded()))
            guard n > 0 else { return [] }
            var out = [Float](repeating: 0, count: n)
            let start = (write - n + capacity) % capacity
            copyLocked(from: start, count: n, into: &out)
            return out
        }
    }

    private func copyLocked(from start: Int, count n: Int, into out: inout [Float]) {
        buffer.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                let first = min(n, capacity - start)
                dst.baseAddress!.update(from: src.baseAddress! + start, count: first)
                if n > first {
                    dst.baseAddress!.advanced(by: first).update(from: src.baseAddress!, count: n - first)
                }
            }
        }
    }

    // MARK: Feed

    /// A closure for `SyncEngine.onFeatureSamples`: appends on the audio thread and schedules
    /// one drain on `queue` (never more than one in flight, so a slow consumer coalesces
    /// buffers instead of queueing them). `consumer` receives the drained samples and the
    /// sample rate on `queue`.
    ///
    ///     let ring = SampleRing()
    ///     engine.onFeatureSamples = ring.feed(on: engine.featureQueue) { samples, rate in … }
    ///
    /// TODO(WP7): wire this in `SyncEngine.start` and fan `consumer` out to the presence
    /// analyser (WP3) and the mel extractor (WP4).
    func feed(on queue: DispatchQueue, consumer: @escaping ([Float], Double) -> Void) -> (UnsafeBufferPointer<Float>, Double) -> Void {
        { [self] samples, sampleRate in
            lock.lock()
            if sampleRate != rate, sampleRate > 0 { reconfigureLocked(sampleRate: sampleRate) }
            appendLocked(samples)
            let schedule = !drainScheduled
            drainScheduled = true
            lock.unlock()
            guard schedule else { return }
            queue.async { [self] in
                lock.withLock { drainScheduled = false }
                let drained = drain()
                guard !drained.isEmpty else { return }
                consumer(drained, self.sampleRate)
            }
        }
    }
}
