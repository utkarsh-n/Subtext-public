import Accelerate
import Foundation
import os

// Content-presence features (docs/v2/latch.md §2). Foundation + Accelerate only: compiled into
// the app and into Tools/synctest.
//
// An honest note on the "frequencies and EMF emissions the TV emits" (latch.md §0): an iPhone
// cannot sense them. The magnetometer measures the Earth's field (a TV's power supply and
// speaker magnets are nanotesla-scale at couch distance, and B ∝ 1/R³); iOS exposes no RF or
// Wi-Fi spectrum scanning; and a paused TV emits the same fields as a playing one, because the
// panel, backlight, PSU, HDMI link and amplifier all stay powered. The only quantity in the
// room that changes between playing and paused is the sound, so the "signature of the TV" this
// file learns is acoustic: the band shape of what the TV speaker puts into the room
// (`BandProfile`, SpectralProfile.swift), and the one real "modulation of the available
// signal" is the 2–10 Hz syllabic amplitude modulation of the heard audio (`PresenceTracker`).
//
// Threading: `ContentPresenceAnalyzer.process` runs on `SyncEngine.featureQueue`, fed from the
// `onFeatureSamples` hook (never on the tap itself); it allocates nothing per hop. `PresenceRing`
// is written there and read on `analysisQueue`, same lock pattern as `MicRing`.

/// One 2048-sample hop of band features.
struct PresenceFrame: Sendable {
    /// Index of the hop's first sample since the analyser was created / reset.
    let sampleIndex: Int
    /// dB of the 300–3000 Hz bands (B2 ∪ B3): the scalar whose time series carries syllables.
    let speechDb: Float
    /// Band energies in dB: B0 50–120, B1 120–300, B2 300–1000, B3 1000–3000, B4 3000–6000,
    /// B5 6000–10000, B6 10000–16000, B7 16000–20000 Hz.
    let bandDb: SIMD8<Float>
    /// Spectral flatness over 300–6000 Hz, in [0, 1]: → 1 noise-like, → 0 tonal.
    let flatness: Float
    /// ‖bandDb(B1…B5) − previous bandDb(B1…B5)‖₂.
    let flux: Float
    /// Diagnostic: mains-hum prominence (50/60/100/120 Hz bins over their neighbours), dB.
    let hum: Float
}

/// Per-hop spectral features of the microphone signal: one 2048-point real FFT every 42.7 ms
/// at 48 kHz, eight band energies, spectral flatness, flux and a hum diagnostic. Band edges
/// are computed from the actual sample rate; bands above Nyquist are flagged invalid
/// (`validBands`) and excluded from every profile distance.
final class ContentPresenceAnalyzer {
    static let hop = 2048
    static let log2n: vDSP_Length = 11
    static let bandEdgesHz: [(Float, Float)] = [
        (50, 120), (120, 300), (300, 1000), (1000, 3000), (3000, 6000), (6000, 10000), (10000, 16000), (16000, 20000),
    ]

    let sampleRate: Double
    /// 1 where the band lies below Nyquist, else 0.
    let validBands: SIMD8<Float>
    /// Seconds per hop (2048 / sampleRate).
    var hopSeconds: Double { Double(Self.hop) / sampleRate }
    /// Hops per second.
    var hopRate: Double { sampleRate / Double(Self.hop) }

    private let fft: FFTSetup
    private var window: [Float]
    private var windowed: [Float]
    private var splitRe: [Float]
    private var splitIm: [Float]
    private var power: [Float]
    private var logPower: [Float]
    private let bandBins: [Range<Int>]
    private let flatnessBins: Range<Int>
    private let humBins: [Int]
    private var previousBand = SIMD8<Float>(repeating: 0)
    private var havePrevious = false
    private var carry: [Float]
    private var carryCount = 0
    private var sampleIndex = 0
    /// Scratch for the hum diagnostic's ±3 neighbours (no per-hop allocation).
    private var humScratch = [Float](repeating: 0, count: 6)

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        let n = Self.hop
        let half = n / 2
        fft = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        windowed = [Float](repeating: 0, count: n)
        splitRe = [Float](repeating: 0, count: half)
        splitIm = [Float](repeating: 0, count: half)
        power = [Float](repeating: 0, count: half)
        logPower = [Float](repeating: 0, count: half)
        carry = [Float](repeating: 0, count: n)
        let binHz = Float(sampleRate) / Float(n)
        let nyquist = Float(sampleRate) / 2
        var valid = SIMD8<Float>(repeating: 0)
        var ranges: [Range<Int>] = []
        for (i, edge) in Self.bandEdgesHz.enumerated() {
            let lo = max(1, Int((edge.0 / binHz).rounded(.up)))
            let hi = min(half, Int((min(edge.1, nyquist) / binHz).rounded(.down)))
            if edge.0 < nyquist, hi > lo {
                ranges.append(lo..<hi)
                valid[i] = 1
            } else {
                ranges.append(0..<0)
            }
        }
        bandBins = ranges
        validBands = valid
        let flo = max(1, Int((300 / binHz).rounded(.up)))
        let fhi = min(half, Int((min(6000, nyquist) / binHz).rounded(.down)))
        flatnessBins = flo..<max(flo + 1, fhi)
        humBins = [50, 60, 100, 120].map { Int(($0 / binHz).rounded()) }.filter { $0 >= 1 && $0 < half }
    }

    deinit { vDSP_destroy_fftsetup(fft) }

    /// Forget the carry-over and the flux history; `sampleIndex` restarts at 0.
    func reset() {
        carryCount = 0
        sampleIndex = 0
        havePrevious = false
        previousBand = SIMD8<Float>(repeating: 0)
    }

    /// Feeds samples (any length) and returns one frame per completed 2048-sample hop.
    /// Carry-over like the VAD; the per-hop path allocates nothing (the result array is the
    /// only allocation, sized by the number of completed hops).
    func process(_ samples: UnsafeBufferPointer<Float>) -> [PresenceFrame] {
        var frames: [PresenceFrame] = []
        let n = Self.hop
        var offset = 0
        let count = samples.count
        guard let base = samples.baseAddress, count > 0 else { return frames }
        // Top up the carry first.
        if carryCount > 0 {
            let take = min(n - carryCount, count)
            carry.withUnsafeMutableBufferPointer { c in
                c.baseAddress!.advanced(by: carryCount).update(from: base, count: take)
            }
            carryCount += take
            offset = take
            if carryCount == n {
                carry.withUnsafeBufferPointer { frames.append(analyse($0)) }
                carryCount = 0
            } else {
                return frames
            }
        }
        while count - offset >= n {
            frames.append(analyse(UnsafeBufferPointer(start: base + offset, count: n)))
            offset += n
        }
        let rest = count - offset
        if rest > 0 {
            carry.withUnsafeMutableBufferPointer { c in c.baseAddress!.update(from: base + offset, count: rest) }
            carryCount = rest
        }
        return frames
    }

    func process(_ samples: [Float]) -> [PresenceFrame] {
        samples.withUnsafeBufferPointer { process($0) }
    }

    private func analyse(_ frame: UnsafeBufferPointer<Float>) -> PresenceFrame {
        let n = Self.hop
        let half = n / 2
        let index = sampleIndex
        sampleIndex += n
        vDSP_vmul(frame.baseAddress!, 1, window, 1, &windowed, 1, vDSP_Length(n))
        splitRe.withUnsafeMutableBufferPointer { re in
            splitIm.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                windowed.withUnsafeBufferPointer { w in
                    w.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { c in
                        vDSP_ctoz(c, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(fft, &split, 1, Self.log2n, FFTDirection(kFFTDirection_Forward))
                // The packed Nyquist term sits in imag[0]; drop it before the magnitudes.
                im[0] = 0
                power.withUnsafeMutableBufferPointer { p in
                    vDSP_zvmags(&split, 1, p.baseAddress!, 1, vDSP_Length(half))
                }
            }
        }
        var band = SIMD8<Float>(repeating: -120)
        for (i, r) in bandBins.enumerated() where !r.isEmpty {
            var sum: Float = 0
            power.withUnsafeBufferPointer { p in
                vDSP_sve(p.baseAddress! + r.lowerBound, 1, &sum, vDSP_Length(r.count))
            }
            band[i] = 10 * log10(max(sum, 1e-12))
        }
        // speechDb: B2 ∪ B3 summed in the power domain.
        var speechPower: Float = 0
        for i in 2...3 where !bandBins[i].isEmpty {
            var sum: Float = 0
            power.withUnsafeBufferPointer { p in
                vDSP_sve(p.baseAddress! + bandBins[i].lowerBound, 1, &sum, vDSP_Length(bandBins[i].count))
            }
            speechPower += sum
        }
        let speechDb = 10 * log10(max(speechPower, 1e-12))
        // Flatness over 300–6000 Hz: exp(mean(ln P)) / mean(P).
        var flatness: Float = 1
        let fc = flatnessBins.count
        if fc > 1 {
            var countI = Int32(fc)
            power.withUnsafeMutableBufferPointer { p in
                // Floor the power so log is finite.
                var floorV: Float = 1e-12
                vDSP_vthr(p.baseAddress! + flatnessBins.lowerBound, 1, &floorV, p.baseAddress! + flatnessBins.lowerBound, 1, vDSP_Length(fc))
                logPower.withUnsafeMutableBufferPointer { lp in
                    vvlogf(lp.baseAddress!, p.baseAddress! + flatnessBins.lowerBound, &countI)
                    var meanLog: Float = 0, meanP: Float = 0
                    vDSP_meanv(lp.baseAddress!, 1, &meanLog, vDSP_Length(fc))
                    vDSP_meanv(p.baseAddress! + flatnessBins.lowerBound, 1, &meanP, vDSP_Length(fc))
                    flatness = meanP > 0 ? min(1, max(0, exp(meanLog) / meanP)) : 1
                }
            }
        }
        // Flux over B1…B5.
        var flux: Float = 0
        if havePrevious {
            var acc: Float = 0
            for i in 1...5 where validBands[i] == 1 {
                let d = band[i] - previousBand[i]
                acc += d * d
            }
            flux = acc.squareRoot()
        }
        previousBand = band
        havePrevious = true
        // Hum diagnostic: the hum bin over the median of ±3 neighbours, in dB.
        var hum: Float = -60
        for b in humBins {
            var k = 0
            for d in -3...3 where d != 0 {
                let j = b + d
                if j >= 1 && j < half {
                    // Insertion sort into the scratch (≤ 6 values): the median is scratch[k / 2].
                    var i = k
                    let v = power[j]
                    while i > 0, humScratch[i - 1] > v { humScratch[i] = humScratch[i - 1]; i -= 1 }
                    humScratch[i] = v
                    k += 1
                }
            }
            guard k > 0 else { continue }
            let median = humScratch[k / 2]
            let v = 10 * log10(max(power[b], 1e-12) / max(median, 1e-12))
            hum = max(hum, v)
        }
        return PresenceFrame(sampleIndex: index, speechDb: speechDb, bandDb: band, flatness: flatness, flux: flux, hum: hum)
    }
}

/// Ring of the last couple of minutes of `PresenceFrame`s, stamped to the wall clock through
/// `start(at:)` (the wall time of sample index 0, the same anchor `MicRing.start(at:)` gets).
final class PresenceRing: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var frames: [PresenceFrame]
    private var write = 0
    private var total = 0
    private var startWall: Date?
    let capacity: Int
    let sampleRate: Double

    init(seconds: Double = 120, sampleRate: Double = 48_000) {
        self.sampleRate = sampleRate
        capacity = max(16, Int((seconds * sampleRate / Double(ContentPresenceAnalyzer.hop)).rounded(.up)))
        frames = [PresenceFrame](repeating: PresenceFrame(sampleIndex: 0, speechDb: -120, bandDb: SIMD8<Float>(repeating: -120), flatness: 1, flux: 0, hum: -60), count: capacity)
    }

    /// Call once with the wall time of the analyser's sample index 0.
    func start(at wall: Date) {
        lock.withLock {
            startWall = wall
            write = 0
            total = 0
        }
    }

    /// Discard everything heard so far. The wall anchor of sample index 0 is kept, so frames
    /// appended afterwards stay consistent with the analyser's running `sampleIndex`; `wall`
    /// is accepted for symmetry with `MicRing.restart(at:)` and only replaces the anchor when
    /// none was set. Rule for the engine: `ContentPresenceAnalyzer.reset()` restarts
    /// `sampleIndex` at 0, so it must be followed by `start(at:)` with the wall time of the next
    /// buffer, never by `restart(at:)`.
    func restart(at wall: Date) {
        lock.withLock {
            if startWall == nil { startWall = wall }
            write = 0
            total = 0
        }
    }

    func append(_ newFrames: [PresenceFrame]) {
        guard !newFrames.isEmpty else { return }
        lock.withLock {
            for f in newFrames {
                frames[write] = f
                write = (write + 1) % capacity
                total += 1
            }
        }
    }

    var secondsRecorded: Double {
        lock.withLock { Double(min(total, capacity)) * Double(ContentPresenceAnalyzer.hop) / sampleRate }
    }

    /// Up to the last `seconds` of frames and the wall time of the first one returned.
    func latest(seconds: Double) -> (frames: [PresenceFrame], start: Date)? {
        lock.withLock {
            guard let startWall, total > 0 else { return nil }
            let want = Int((seconds * sampleRate / Double(ContentPresenceAnalyzer.hop)).rounded())
            let n = min(total, capacity, max(1, want))
            var out: [PresenceFrame] = []
            out.reserveCapacity(n)
            var idx = (write - n + capacity) % capacity
            for _ in 0..<n {
                out.append(frames[idx])
                idx = (idx + 1) % capacity
            }
            return (out, startWall.addingTimeInterval(Double(out[0].sampleIndex) / sampleRate))
        }
    }
}
