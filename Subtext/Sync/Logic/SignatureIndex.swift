import Accelerate
import Foundation

/// In-memory, score-ready form of a `TrackMemory`: per cue a normalised float block (frames × 24
/// at 20 ms) and an 8-band / 100 ms thumbnail for the coarse rewatch search (signature.md §4).
///
/// All scores are Pearson r of flattened blocks, so night-to-night level differences do not
/// matter. ~1.5 MB per two-hour film.
final class SignatureIndex {
    static let bands = MelExtractor.bands
    static let thumbBands = 8
    /// 20 ms frames per thumbnail frame (100 ms).
    static let thumbStride = 5
    /// Coarse shift grid in thumbnail frames (200 ms).
    static let coarseStep = 2

    struct Score: Sendable, Equatable {
        let cueID: Int
        let r: Float
        /// Index in the heard 20 ms frame array where the signature's frame 0 aligns.
        let position: Int
        /// `position − predicted position` (confirm only; 0 for searches).
        let shiftFrames: Int
        var shiftSeconds: Double { Double(shiftFrames) * CueSignature.frameSeconds }
    }

    struct Entry {
        let cueID: Int
        /// Media time of frame 0.
        let startMedia: Double
        let frameCount: Int
        /// Band-centred, mean-0 / unit-norm frames (frameCount × bands); the raw frames are not
        /// kept (≈ 17 KB per cue at 20 ms × 24 bands × Float), so a 1500-cue index is ~30 MB.
        let normalised: [Float]
        let thumbCount: Int
        let thumb: [Float]
        let speechSeconds: Float
        /// Clustered text or < 1.5 s of speech: can vote, never act alone (signature.md §3.6).
        let weak: Bool
    }

    private(set) var entries: [Int: Entry] = [:]
    let cueStarts: [Double]
    let cueCount: Int
    private(set) var memory: TrackMemory

    var count: Int { entries.count }
    var cueIDs: [Int] { entries.keys.sorted() }

    init(memory: TrackMemory, cues: [Cue], clusters: TextClusters? = nil) {
        self.memory = memory
        cueStarts = cues.map(\.start)
        cueCount = cues.count
        for (id, sig) in memory.cues where id >= 0 && id < cues.count {
            entries[id] = Self.makeEntry(sig, cueStart: cues[id].start, clustered: clusters?.clusterOf[id] != nil)
        }
    }

    /// Adds or replaces one signature (after a capture) so the index stays live within a session.
    func insert(_ sig: CueSignature, cueStart: Double, clustered: Bool) {
        memory.cues[sig.cueID] = sig
        entries[sig.cueID] = Self.makeEntry(sig, cueStart: cueStart, clustered: clustered)
    }

    func recordOwnScore(_ r: Float) { memory.recordOwnScore(r) }

    func thrConfirm(floor: Float, cap: Float, delta: Float) -> Float { memory.thrConfirm(floor: floor, cap: cap, delta: delta) }

    func coverage(speechCueIDs: Set<Int>?) -> Double { memory.coverage(cueCount: cueCount, speechCueIDs: speechCueIDs) }

    private static func makeEntry(_ sig: CueSignature, cueStart: Double, clustered: Bool) -> Entry {
        let raw = sig.floatFrames
        let (thumb, thumbCount) = thumbnail(frames20: raw, count: sig.frameCount)
        return Entry(cueID: sig.cueID, startMedia: sig.startMedia(cueStart: cueStart), frameCount: sig.frameCount,
                     normalised: normalise(bandCentred(raw, frames: sig.frameCount, bands: bands)), thumbCount: thumbCount,
                     thumb: normalise(bandCentred(thumb, frames: thumbCount, bands: thumbBands)),
                     speechSeconds: sig.speechSeconds, weak: clustered || sig.speechSeconds < 1.5)
    }

    /// Subtracts each band's mean over the block's frames (cepstral-mean style). The extractor
    /// already removes each frame's mean across bands (level); this removes the static spectral
    /// shape every frame of one voice in one room shares, so only the time–frequency *modulation*
    /// of the line is left to correlate. Without it, any two lines of the same voice correlate
    /// at r ≈ 0.85 through that shared shape (measured in the WP4 harness, S1 best-wrong).
    static func bandCentred(_ v: [Float], frames: Int, bands: Int) -> [Float] {
        guard frames > 0, v.count >= frames * bands else { return v }
        var out = v
        out.withUnsafeMutableBufferPointer { o in
            for b in 0..<bands {
                var mean: Float = 0
                vDSP_meanv(o.baseAddress! + b, vDSP_Stride(bands), &mean, vDSP_Length(frames))
                var neg = -mean
                vDSP_vsadd(o.baseAddress! + b, vDSP_Stride(bands), &neg, o.baseAddress! + b, vDSP_Stride(bands), vDSP_Length(frames))
            }
        }
        return out
    }

    // MARK: Frame helpers (shared by capture and scoring so both sides are computed identically)

    /// 10 ms frames → 20 ms frames by averaging pairs (odd trailing frame dropped).
    static func to20ms(frames10: [Float], count: Int) -> (frames: [Float], count: Int) {
        let n = count / 2
        var out = [Float](repeating: 0, count: n * bands)
        frames10.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for f in 0..<n {
                    let a = src.baseAddress! + 2 * f * bands
                    vDSP_vadd(a, 1, a + bands, 1, dst.baseAddress! + f * bands, 1, vDSP_Length(bands))
                }
                var half: Float = 0.5
                vDSP_vsmul(dst.baseAddress!, 1, &half, dst.baseAddress!, 1, vDSP_Length(n * bands))
            }
        }
        return (out, n)
    }

    /// Wall-time frames → media-time frames when the film plays at `rate` (nearest frame).
    static func stretch(frames: [Float], count: Int, rate: Double) -> (frames: [Float], count: Int) {
        guard rate != 1, rate > 0, count > 0 else { return (frames, count) }
        let n = Int(Double(count) * rate)
        var out = [Float](repeating: 0, count: n * bands)
        frames.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for k in 0..<n {
                    let i = min(count - 1, Int(Double(k) / rate))
                    (dst.baseAddress! + k * bands).update(from: src.baseAddress! + i * bands, count: bands)
                }
            }
        }
        return (out, n)
    }

    /// 24-band / 20 ms → 8-band / 100 ms (mean of 3 bands × 5 frames).
    static func thumbnail(frames20: [Float], count: Int) -> (frames: [Float], count: Int) {
        let n = count / thumbStride
        var out = [Float](repeating: 0, count: n * thumbBands)
        let perBand = bands / thumbBands
        for t in 0..<n {
            for b in 0..<thumbBands {
                var s: Float = 0
                for f in 0..<thumbStride {
                    let base = (t * thumbStride + f) * bands + b * perBand
                    for k in 0..<perBand { s += frames20[base + k] }
                }
                out[t * thumbBands + b] = s / Float(thumbStride * perBand)
            }
        }
        return (out, n)
    }

    static func normalise(_ v: [Float]) -> [Float] {
        guard !v.isEmpty else { return v }
        var mean: Float = 0
        vDSP_meanv(v, 1, &mean, vDSP_Length(v.count))
        var out = [Float](repeating: 0, count: v.count)
        var neg = -mean
        vDSP_vsadd(v, 1, &neg, &out, 1, vDSP_Length(v.count))
        var ss: Float = 0
        vDSP_svesq(out, 1, &ss, vDSP_Length(out.count))
        guard ss > 1e-12 else { return out }
        var inv = 1 / ss.squareRoot()
        vDSP_vsmul(out, 1, &inv, &out, 1, vDSP_Length(out.count))
        return out
    }

    /// Pearson r of a band-centred, mean-0 / unit-norm block `a` (`frames × bands`) against the
    /// raw block at `b`, with `b` band-centred implicitly: because every band of `a` sums to zero,
    /// Σ a·(b − m_band) = Σ a·b, and Var(b − m_band) = Σ b² − frames · Σ m_band². Cost beyond the
    /// dot product: `bands` strided sums.
    @inline(__always)
    static func pearson(normalised a: UnsafePointer<Float>, raw b: UnsafePointer<Float>, frames: Int, bands: Int) -> Float {
        let n = frames * bands
        var dot: Float = 0, ss: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(n))
        vDSP_svesq(b, 1, &ss, vDSP_Length(n))
        var meansSq: Float = 0
        for k in 0..<bands {
            var m: Float = 0
            vDSP_meanv(b + k, vDSP_Stride(bands), &m, vDSP_Length(frames))
            meansSq += m * m
        }
        let varB = ss - Float(frames) * meansSq
        guard varB > 1e-9 else { return 0 }
        return dot / varB.squareRoot()
    }

    /// Pearson r of two raw blocks of `frames` frames (harness helper).
    static func pearson(raw a: [Float], _ b: [Float], frames: Int) -> Float {
        let na = normalise(bandCentred(Array(a.prefix(frames * bands)), frames: frames, bands: bands))
        return na.withUnsafeBufferPointer { pa in b.withUnsafeBufferPointer { pb in pearson(normalised: pa.baseAddress!, raw: pb.baseAddress!, frames: frames, bands: bands) } }
    }

    // MARK: Scoring

    /// Scores `cueID`'s signature against `heard` (20 ms frames at media rate, `heardCount` of
    /// them, the first describing media time `heardStartMedia`) at shifts ±`maxShiftFrames`
    /// around where the lock predicts it. Returns the best shift, or nil when the signature does
    /// not fit entirely inside the heard block at any shift.
    func confirm(heard: [Float], heardCount: Int, heardStartMedia: Double, cueID: Int, maxShiftFrames: Int) -> Score? {
        guard let e = entries[cueID] else { return nil }
        let p0 = Int(((e.startMedia - heardStartMedia) / CueSignature.frameSeconds).rounded())
        return best(entry: e, heard: heard, heardCount: heardCount, positions: (p0 - maxShiftFrames)...(p0 + maxShiftFrames), predicted: p0)
    }

    private func best(entry e: Entry, heard: [Float], heardCount: Int, positions: ClosedRange<Int>, predicted: Int, step: Int = 1) -> Score? {
        var bestR: Float = -2
        var bestP = 0
        e.normalised.withUnsafeBufferPointer { a in
            heard.withUnsafeBufferPointer { h in
                var p = positions.lowerBound
                while p <= positions.upperBound {
                    defer { p += step }
                    guard p >= 0, p + e.frameCount <= heardCount else { continue }
                    let r = Self.pearson(normalised: a.baseAddress!, raw: h.baseAddress! + p * Self.bands, frames: e.frameCount, bands: Self.bands)
                    if r > bestR { bestR = r; bestP = p }
                }
            }
        }
        guard bestR > -2 else { return nil }
        return Score(cueID: e.cueID, r: bestR, position: bestP, shiftFrames: bestP - predicted)
    }

    /// Coarse rewatch search: thumbnails of every signature over the heard block on a 200 ms
    /// grid; the best `top` cues (one position each).
    func coarseSearch(heard: [Float], heardCount: Int, top: Int) -> [Score] {
        let (thumb, thumbCount) = Self.thumbnail(frames20: heard, count: heardCount)
        var scores: [Score] = []
        scores.reserveCapacity(entries.count)
        thumb.withUnsafeBufferPointer { h in
            for e in entries.values where e.thumbCount >= 4 && e.thumbCount <= thumbCount {
                var bestR: Float = -2, bestP = 0
                e.thumb.withUnsafeBufferPointer { a in
                    var p = 0
                    while p + e.thumbCount <= thumbCount {
                        let r = Self.pearson(normalised: a.baseAddress!, raw: h.baseAddress! + p * Self.thumbBands, frames: e.thumbCount, bands: Self.thumbBands)
                        if r > bestR { bestR = r; bestP = p }
                        p += Self.coarseStep
                    }
                }
                if bestR > -2 { scores.append(Score(cueID: e.cueID, r: bestR, position: bestP * Self.thumbStride, shiftFrames: 0)) }
            }
        }
        return Array(scores.sorted { $0.r > $1.r }.prefix(top))
    }

    /// Fine stage: full-resolution Pearson at ±`radiusFrames` (20 ms grid) around each coarse hit.
    func fineScore(heard: [Float], heardCount: Int, candidates: [Score], radiusFrames: Int = 12) -> [Score] {
        candidates.compactMap { c in
            guard let e = entries[c.cueID] else { return nil }
            return best(entry: e, heard: heard, heardCount: heardCount, positions: (c.position - radiusFrames)...(c.position + radiusFrames), predicted: c.position)
        }
        .sorted { $0.r > $1.r }
    }

    /// Harness rank test (signature.md S1): the heard block starting `trueStart` frames before
    /// the true position of a cue is scored against every stored signature, each slid
    /// ±`shift` frames and — exactly as the live confirm / search paths — only at positions where
    /// the whole signature fits inside the block. Returns the ranked list, best first; signatures
    /// that fit nowhere are left out.
    func rankAll(heard: [Float], heardCount: Int, trueStart: Int, shift: Int = 15) -> [Score] {
        var out: [Score] = []
        for e in entries.values {
            if let s = best(entry: e, heard: heard, heardCount: heardCount, positions: (trueStart - shift)...(trueStart + shift), predicted: trueStart) {
                out.append(s)
            }
        }
        return out.sorted { $0.r > $1.r }
    }
}
