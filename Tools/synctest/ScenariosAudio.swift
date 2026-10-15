import Foundation

// WP1 audio-layer harness suite: `SCENARIOS=audio Tools/synctest.sh`.
//
// Only `SampleRing` is harnessable (AudioCapture is AVFoundation and lives in the app target);
// these checks are the contract the feature consumers (WP3 presence, WP4 mel) rely on:
//   1  FIFO: every appended sample drained exactly once, in order, across the wrap point
//   2  snapshot: latest(seconds:) returns the most recent window without consuming
//   3  overrun: a consumer that falls more than one ring behind loses exactly the oldest
//      samples, and droppedSamples counts them
//   4  oversized append: a single append larger than the ring keeps its tail
//   5  reconfigure: a new sample rate resizes the ring and discards its contents
//   6  feed: the onFeatureSamples-shaped closure appends on one thread and drains on a
//      serial queue with at most one drain in flight; nothing lost, nothing duplicated
//   7  cost: µs per 100 ms append at 48 kHz (memcpy only; the audio thread budget)
//
// Declarations only (critique §5: top-level statements live in main.swift). The same checks run
// standalone with swiftc via Tools/synctest/audio/run.sh, which compiles this file, SampleRing
// and a three-line main.swift.

enum SampleRingChecks {
    private static var checks = 0
    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        checks += 1
        if !ok { failures += 1 }
        print("  \(ok ? "ok  " : "FAIL") \(name)\(detail.isEmpty ? "" : "  (\(detail))")")
    }

    /// Deterministic sample stream: sample i has value Float(i).
    private static func chunk(_ from: Int, _ count: Int) -> [Float] { (from..<(from + count)).map(Float.init) }

    /// Runs every check, prints one row each and a summary line; returns the failure count.
    @discardableResult
    static func run() -> Int {
        checks = 0
        failures = 0
        print("SampleRing smoke test")

        // 1 FIFO across the wrap point. Capacity 2 s × 1000 Hz = 2000; append 100-sample buffers.
        do {
            let ring = SampleRing(seconds: 2, sampleRate: 1000)
            var next = 0
            var drained: [Float] = []
            for i in 0..<55 {                       // 5500 samples: wraps twice
                ring.append(chunk(next, 100))
                next += 100
                if i % 3 == 2 { drained += ring.drain() }   // drain every third buffer (≤ 300 unread)
            }
            drained += ring.drain()
            let expected = chunk(0, 5500)
            check("fifo in order across wrap", drained == expected, "\(drained.count) samples, dropped \(ring.droppedSamples)")
            check("drain when empty returns nothing", ring.drain().isEmpty)
            check("secondsAvailable saturates at capacity", ring.secondsAvailable == 2.0, "\(ring.secondsAvailable)")
        }

        // 2 Snapshot of the most recent window, independent of draining.
        do {
            let ring = SampleRing(seconds: 2, sampleRate: 1000)
            for i in 0..<30 { ring.append(chunk(i * 100, 100)) }   // 3000 samples; ring holds 1000..2999
            let last = ring.latest(seconds: 0.5)
            check("latest(0.5 s) is the newest 500 samples", last == chunk(2500, 500), "first \(last.first ?? -1) last \(last.last ?? -1)")
            check("latest does not consume", ring.unreadCount == 2000, "unread \(ring.unreadCount)")
            let whole = ring.latest(seconds: 10)
            check("latest(10 s) is capped at the ring", whole == chunk(1000, 2000))
            let empty = SampleRing(seconds: 2, sampleRate: 1000)
            check("latest on an empty ring is empty", empty.latest(seconds: 1).isEmpty)
        }

        // 3 Overrun: consumer falls 3 s behind on a 2 s ring.
        do {
            let ring = SampleRing(seconds: 2, sampleRate: 1000)
            for i in 0..<30 { ring.append(chunk(i * 100, 100)) }   // 3000 samples, none drained
            let got = ring.drain()
            check("overrun keeps the newest ring-full", got == chunk(1000, 2000), "\(got.count) samples")
            check("droppedSamples counts the lost oldest", ring.droppedSamples == 1000, "\(ring.droppedSamples)")
            ring.append(chunk(3000, 100))
            check("after an overrun the stream continues", ring.drain() == chunk(3000, 100))
            check("dropped is cumulative, not reset by drain", ring.droppedSamples == 1000)
        }

        // 4 One append larger than the whole ring keeps only its tail.
        do {
            let ring = SampleRing(seconds: 2, sampleRate: 1000)
            ring.append(chunk(0, 100))
            ring.append(chunk(100, 2500))
            let got = ring.drain()
            check("oversized append keeps its tail", got == chunk(600, 2000), "\(got.count) samples, dropped \(ring.droppedSamples)")
            check("oversized append counts the drop", ring.droppedSamples == 600)
        }

        // 5 Reconfigure on a sample-rate change.
        do {
            let ring = SampleRing(seconds: 2, sampleRate: 1000)
            ring.append(chunk(0, 500))
            chunk(0, 300).withUnsafeBufferPointer { ring.append($0, sampleRate: 500) }
            check("rate change resizes and discards", ring.sampleRate == 500 && ring.drain() == chunk(0, 300), "rate \(ring.sampleRate)")
            for i in 0..<20 { ring.append(chunk(i * 100, 100)) }
            check("capacity follows the new rate (2 s × 500 Hz)", ring.unreadCount == 1000, "unread \(ring.unreadCount)")
        }

        // 6 Feed: producer thread appends 10 ms buffers at 16 kHz; consumer on a serial queue.
        do {
            let ring = SampleRing(seconds: 2, sampleRate: 16_000)
            let queue = DispatchQueue(label: "features")
            let gate = DispatchSemaphore(value: 0)
            var received: [Float] = []
            var drains = 0
            var maxInFlight = 0
            var inFlight = 0
            let inFlightLock = NSLock()
            let feed = ring.feed(on: queue) { samples, _ in
                inFlightLock.lock(); inFlight += 1; maxInFlight = max(maxInFlight, inFlight); inFlightLock.unlock()
                received += samples
                drains += 1
                usleep(3000)      // slower than the producer's 1 ms period, so buffers must coalesce
                inFlightLock.lock(); inFlight -= 1; inFlightLock.unlock()
                if received.count == 16_000 * 3 { gate.signal() }
            }
            let producer = Thread {
                var next = 0
                for _ in 0..<300 {                        // 3 s of 10 ms buffers
                    let buf = chunk(next, 160)
                    buf.withUnsafeBufferPointer { feed($0, 16_000) }
                    next += 160
                    usleep(1000)                          // 1 ms per 10 ms buffer: 10× real time
                }
            }
            producer.start()
            let finished = gate.wait(timeout: .now() + 10) == .success
            queue.sync {}
            check("feed delivers every sample once, in order", finished && received == chunk(0, 48_000), "\(received.count) samples in \(drains) drains, dropped \(ring.droppedSamples)")
            check("at most one drain in flight on the serial queue", maxInFlight == 1, "max \(maxInFlight)")
            check("drains coalesce (fewer drains than buffers)", drains < 300, "\(drains) drains for 300 buffers")
        }

        // 7 Cost of the audio-thread append: 4800 samples (100 ms at 48 kHz).
        do {
            let ring = SampleRing(seconds: 2, sampleRate: 48_000)
            let buf = chunk(0, 4800)
            var best = Double.infinity
            for _ in 0..<200 {
                let t0 = DispatchTime.now().uptimeNanoseconds
                buf.withUnsafeBufferPointer { ring.append($0, sampleRate: 48_000) }
                best = min(best, Double(DispatchTime.now().uptimeNanoseconds - t0) / 1000)
                _ = ring.drain()
            }
            check("append of 100 ms @ 48 kHz under 50 µs", best < 50, String(format: "best %.1f µs", best))
        }

        print("SampleRing: \(checks - failures)/\(checks) OK")
        return failures
    }
}

@_cdecl("synctest_suite_audio")
public func synctestSuiteAudio() {
    SampleRingChecks.run()
}
