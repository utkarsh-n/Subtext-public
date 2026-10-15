import Accelerate
import Foundation

/// 24-band log-mel features, one frame per 10 ms, mean-removed per frame (docs/v2/signature.md
/// §2.3, `featureVersion = 1`). Pure Accelerate, so the app and the harness compute stored
/// signatures and heard features with the very same code.
///
/// Pipeline per buffer: anti-aliased integer decimation to ~16 kHz (31-tap FIR, cutoff 7 kHz,
/// `vDSP_desamp`), 512-sample Hann frames centred on each 10 ms VAD bin (so frame *i* describes
/// the same instant as `MicRing` bin *i*), DCT-II power spectrum, 24 triangular mel filters over
/// 100–4000 Hz, `log10`, then subtract the frame's mean across bands (removes level and most
/// room / TV colouration). Nothing is allocated in `process`; all state is preallocated.
///
/// Runs on `featureQueue`, never on the tap (critique C4). Budget: ~10 ms CPU per 60 s of audio
/// on a Mac (prototype); the harness S7 line prints the current number.
final class MelExtractor {
    static let bands = 24
    static let fftSize = 512
    static let targetRate = 16_000.0
    static let hopSeconds = 0.01
    static let loHz = 100.0
    static let hiHz = 4000.0
    static let firTaps = 31
    static let featureVersion = 1

    let inputSampleRate: Double
    /// Integer decimation factor (3 for 48 kHz, 1 for 16 kHz, 3 for 44.1 kHz → 14.7 kHz).
    let decimation: Int
    /// Sample rate after decimation; the filterbank is built for this rate.
    let decimatedRate: Double
    /// Decimated samples per 10 ms frame.
    let hop: Int

    private let dct: vDSP.DCT
    private var window: [Float]
    /// 24 × fftSize mel filterbank (row-major).
    private var filterbank: [Float]
    private var fir: [Float]
    /// Raw input carried over between buffers (fewer than `decimation` samples) plus staging.
    private var rawCarry: [Float] = []
    private var rawStage: [Float]
    private var decimated: [Float]
    /// Decimated samples not yet consumed by a frame (preceded by the zero lead at reset).
    private var pending: [Float]
    private var frame: [Float]
    private var spectrum: [Float]
    private var energies: [Float]
    private var leadFrames: Int

    init(inputSampleRate: Double) {
        self.inputSampleRate = inputSampleRate
        decimation = max(1, Int((inputSampleRate / Self.targetRate).rounded()))
        decimatedRate = inputSampleRate / Double(decimation)
        hop = max(1, Int((decimatedRate * Self.hopSeconds).rounded()))
        dct = vDSP.DCT(count: Self.fftSize, transformType: .II)!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: Self.fftSize, isHalfWindow: false)
        filterbank = Self.makeFilterbank(sampleRate: decimatedRate)
        fir = Self.makeLowPass(taps: Self.firTaps, cutoffHz: 7000, sampleRate: inputSampleRate)
        rawStage = [Float](repeating: 0, count: 8192 + Self.firTaps)
        decimated = [Float](repeating: 0, count: 8192 / decimation + 2)
        pending = []
        pending.reserveCapacity(Self.fftSize + 8192)
        frame = [Float](repeating: 0, count: Self.fftSize)
        spectrum = [Float](repeating: 0, count: Self.fftSize)
        energies = [Float](repeating: 0, count: Self.bands)
        leadFrames = 0
        reset()
    }

    func reset() {
        rawCarry.removeAll(keepingCapacity: true)
        pending.removeAll(keepingCapacity: true)
        // Frame i is centred on decimated sample i·hop + hop/2; the window half-width is 256,
        // so the first frame needs 256 − hop/2 samples of (zero) history.
        let lead = Self.fftSize / 2 - hop / 2
        pending.append(contentsOf: [Float](repeating: 0, count: lead))
        leadFrames = 0
    }

    /// Feeds raw mono samples at `inputSampleRate` and appends `bands` floats per completed
    /// 10 ms frame to `out`. Returns the number of frames appended. Allocation-free after warm-up.
    @discardableResult
    func process(_ samples: UnsafeBufferPointer<Float>, into out: inout [Float]) -> Int {
        var levels: [Float] = []
        return process(samples, into: &out, levels: &levels, wantLevels: false)
    }

    /// As `process(_:into:)`, and also appends one frame log-energy (`log10` of the mean mel
    /// energy) per frame to `levels`, for the capture path's `speechLevelDb` (signature.md §3.2).
    @discardableResult
    func process(_ samples: UnsafeBufferPointer<Float>, into out: inout [Float], levels: inout [Float], wantLevels: Bool = true) -> Int {
        guard let base = samples.baseAddress, samples.count > 0 else { return 0 }
        // 1. Decimate (FIR + drop) into `pending`.
        if decimation == 1 {
            pending.append(contentsOf: UnsafeBufferPointer(start: base, count: samples.count))
        } else {
            let needed = rawCarry.count + samples.count
            if rawStage.count < needed { rawStage = [Float](repeating: 0, count: needed) }
            rawStage.withUnsafeMutableBufferPointer { st in
                if !rawCarry.isEmpty { rawCarry.withUnsafeBufferPointer { st.baseAddress!.update(from: $0.baseAddress!, count: $0.count) } }
                (st.baseAddress! + rawCarry.count).update(from: base, count: samples.count)
            }
            let outCount = (needed - Self.firTaps) / decimation + 1
            if outCount > 0 {
                if decimated.count < outCount { decimated = [Float](repeating: 0, count: outCount) }
                rawStage.withUnsafeBufferPointer { st in
                    fir.withUnsafeBufferPointer { f in
                        decimated.withUnsafeMutableBufferPointer { d in
                            vDSP_desamp(st.baseAddress!, vDSP_Stride(decimation), f.baseAddress!, d.baseAddress!, vDSP_Length(outCount), vDSP_Length(Self.firTaps))
                        }
                    }
                }
                pending.append(contentsOf: decimated[0..<outCount])
                let consumed = outCount * decimation
                let keep = needed - consumed
                rawCarry = Array(rawStage[consumed..<(consumed + keep)])
            } else {
                rawCarry = Array(rawStage[0..<needed])
            }
        }
        // 2. Frames.
        var produced = 0
        var offset = 0
        while pending.count - offset >= Self.fftSize {
            pending.withUnsafeBufferPointer { p in
                frame.withUnsafeMutableBufferPointer { fr in
                    vDSP_vmul(p.baseAddress! + offset, 1, window, 1, fr.baseAddress!, 1, vDSP_Length(Self.fftSize))
                }
            }
            dct.transform(frame, result: &spectrum)
            vDSP.square(spectrum, result: &spectrum)
            filterbank.withUnsafeBufferPointer { fb in
                spectrum.withUnsafeBufferPointer { sp in
                    energies.withUnsafeMutableBufferPointer { en in
                        vDSP_mmul(fb.baseAddress!, 1, sp.baseAddress!, 1, en.baseAddress!, 1, vDSP_Length(Self.bands), 1, vDSP_Length(Self.fftSize))
                    }
                }
            }
            var floor: Float = 1e-9
            vDSP_vthr(energies, 1, &floor, &energies, 1, vDSP_Length(Self.bands))
            var n = Int32(Self.bands)
            vvlog10f(&energies, energies, &n)
            var mean: Float = 0
            vDSP_meanv(energies, 1, &mean, vDSP_Length(Self.bands))
            var negMean = -mean
            vDSP_vsadd(energies, 1, &negMean, &energies, 1, vDSP_Length(Self.bands))
            out.append(contentsOf: energies)
            if wantLevels { levels.append(mean) }
            produced += 1
            offset += hop
        }
        if offset > 0 { pending.removeFirst(offset) }
        return produced
    }

    // MARK: Tables

    private static func hzToMel(_ hz: Double) -> Double { 2595 * log10(1 + hz / 700) }
    private static func melToHz(_ mel: Double) -> Double { 700 * (pow(10, mel / 2595) - 1) }

    /// Triangular filters on a mel scale over `loHz`…`hiHz`, against the DCT-II coefficient
    /// grid (coefficient k ↔ k · rate / (2 · fftSize) Hz). Each filter is normalised to unit area.
    static func makeFilterbank(sampleRate: Double) -> [Float] {
        let n = fftSize
        var bank = [Float](repeating: 0, count: bands * n)
        let edges = (0...(bands + 1)).map { melToHz(hzToMel(loHz) + (hzToMel(hiHz) - hzToMel(loHz)) * Double($0) / Double(bands + 1)) }
        let hzPerBin = sampleRate / (2 * Double(n))
        for b in 0..<bands {
            let lo = edges[b], centre = edges[b + 1], hi = edges[b + 2]
            var sum: Float = 0
            for k in 0..<n {
                let f = Double(k) * hzPerBin
                var w = 0.0
                if f > lo && f < centre { w = (f - lo) / (centre - lo) } else if f >= centre && f < hi { w = (hi - f) / (hi - centre) }
                bank[b * n + k] = Float(w)
                sum += Float(w)
            }
            if sum > 0 { for k in 0..<n { bank[b * n + k] /= sum } }
        }
        return bank
    }

    /// Windowed-sinc low-pass FIR (Hamming), normalised to unit DC gain.
    static func makeLowPass(taps: Int, cutoffHz: Double, sampleRate: Double) -> [Float] {
        let fc = min(0.499, cutoffHz / sampleRate)
        let m = taps - 1
        var h = [Float](repeating: 0, count: taps)
        var sum = 0.0
        for i in 0..<taps {
            let x = Double(i) - Double(m) / 2
            let sinc = x == 0 ? 2 * fc : sin(2 * .pi * fc * x) / (.pi * x)
            let w = 0.54 - 0.46 * cos(2 * .pi * Double(i) / Double(m))
            h[i] = Float(sinc * w)
            sum += sinc * w
        }
        for i in 0..<taps { h[i] /= Float(sum) }
        return h
    }
}

/// The feature pump WP7 hangs off `SyncEngine.onFeatureSamples` → `featureQueue`: raw mono
/// samples in, 10 ms mel frames (plus frame log-energies) into a `MelRing`. The extractor is
/// built lazily for the first sample rate seen and rebuilt (ring restarted) if the rate changes
/// after an engine rebuild. Call `push` only on the serial `featureQueue`; `ring.start(at:)`
/// must be given the same wall stamp as `MicRing.start(at:)` so the two rings stay aligned.
///
/// TODO(WP7): in `SyncEngine.start`: `melFeed = MelFeed(ring: melRing)`; in the tap after the
/// VAD, `onFeatureSamples` copies into WP1's `SampleRing`, and `featureQueue.async` drains it
/// with `melFeed.push(sampleRing.drain(), sampleRate:)` (after the presence analyser). Memory
/// off → do not push (no `MelRing`, no file).
final class MelFeed {
    let ring: MelRing
    private(set) var extractor: MelExtractor?
    private(set) var sampleRate: Double = 0
    private var frames: [Float] = []
    private var levels: [Float] = []
    /// Accumulated extraction cost, ms, and audio seconds fed (for the `os_signpost`-free readout).
    private(set) var costMs = 0.0
    private(set) var audioSeconds = 0.0

    init(ring: MelRing) {
        self.ring = ring
        frames.reserveCapacity(64 * MelExtractor.bands)
        levels.reserveCapacity(64)
    }

    /// Feed one buffer's worth of mono samples at `sampleRate`.
    func push(_ samples: [Float], sampleRate: Double) {
        samples.withUnsafeBufferPointer { push($0, sampleRate: sampleRate) }
    }

    func push(_ samples: UnsafeBufferPointer<Float>, sampleRate: Double, wall: Date? = nil) {
        guard sampleRate > 0, samples.count > 0 else { return }
        if extractor == nil || self.sampleRate != sampleRate {
            extractor = MelExtractor(inputSampleRate: sampleRate)
            self.sampleRate = sampleRate
            if let wall { ring.restart(at: wall) }
        }
        guard let extractor else { return }
        frames.removeAll(keepingCapacity: true)
        levels.removeAll(keepingCapacity: true)
        let started = Date()
        let n = extractor.process(samples, into: &frames, levels: &levels)
        costMs += Date().timeIntervalSince(started) * 1000
        audioSeconds += Double(samples.count) / sampleRate
        ring.append(frames, count: n, levels: levels)
    }

    /// Mel cost in ms per 60 s of audio so far (the S7 number, live).
    var msPer60s: Double { audioSeconds > 0 ? costMs / audioSeconds * 60 : 0 }

    func reset() {
        extractor?.reset()
        costMs = 0
        audioSeconds = 0
    }
}
