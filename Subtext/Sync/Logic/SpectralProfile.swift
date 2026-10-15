import Foundation

// Session-learned band profiles (docs/v2/latch.md §3). Foundation only.
//
// A profile is the level-normalised shape of the eight band energies of `PresenceFrame`: the
// mean of B1…B5 is subtracted from every band before it is accumulated, so a volume change
// moves nothing and the profile encodes shape (the TV speaker's band-limiting and its
// 100–200 Hz bump, the room's colouration), never loudness. Three are learned per session by
// `PresenceTracker`: `tvSpeech` (hops under a confirmed lock with VAD speech inside a cue),
// `tvGap` (the TV's bed in subtitle gaps) and `roomOnly` (quiet, stationary stretches). They
// are a prior learned from what the phone actually hears, not a hard-coded TV signature.

struct BandProfile: Sendable, Equatable {
    private(set) var mean = SIMD8<Float>(repeating: 0)
    /// dB², floored at `varianceFloor` in `distance`.
    private(set) var variance = SIMD8<Float>(repeating: 4)
    /// Effective hops after exponential forgetting.
    private(set) var count: Float = 0
    /// ~10 min exponential forget.
    var forgetSeconds: Float = 600
    /// ≥ 20 s of evidence before the profile is consulted.
    var readySeconds: Float = 20
    /// Which bands take part (1) and which are above Nyquist (0).
    var validBands = SIMD8<Float>(repeating: 1)
    static let varianceFloor: Float = 1
    /// The bands the distance is measured over (B1…B5; B0 is rumble, B6/B7 are diagnostics).
    static let distanceMask = SIMD8<Float>(0, 1, 1, 1, 1, 1, 0, 0)

    /// Level-normalise: subtract the mean of the valid bands among B1…B5.
    static func normalised(_ bandDb: SIMD8<Float>, validBands: SIMD8<Float>) -> SIMD8<Float> {
        let mask = distanceMask * validBands
        let weight = (mask * mask).sum()
        guard weight > 0 else { return bandDb }
        let level = (bandDb * mask).sum() / weight
        return bandDb - SIMD8<Float>(repeating: level)
    }

    /// Adds one hop (`hopSeconds` long) with forgetting.
    mutating func add(_ bandDb: SIMD8<Float>, hopSeconds: Float) {
        let x = Self.normalised(bandDb, validBands: validBands)
        let hopsPerForget = forgetSeconds / max(hopSeconds, 1e-4)
        let decay = exp(-1 / hopsPerForget)
        let newCount = count * decay + 1
        let alpha = 1 / newCount
        if count == 0 {
            mean = x
            variance = SIMD8<Float>(repeating: 4)
        } else {
            let delta = x - mean
            mean += delta * alpha
            let delta2 = x - mean
            variance = variance * (1 - alpha) + delta * delta2 * alpha
        }
        count = newCount
    }

    /// sqrt(mean over the valid B1…B5 bands of (x − μ)² / max(σ², 1)), in Mahalanobis units.
    func distance(to bandDb: SIMD8<Float>) -> Float {
        let x = Self.normalised(bandDb, validBands: validBands)
        let mask = Self.distanceMask * validBands
        let n = mask.sum()
        guard n > 0 else { return 0 }
        let d = x - mean
        let floored = pointwiseMax(variance, SIMD8<Float>(repeating: Self.varianceFloor))
        let terms = d * d / floored * mask
        return (terms.sum() / n).squareRoot()
    }

    /// Seconds of evidence accumulated (after forgetting), for `hopSeconds` per hop.
    func seconds(hopSeconds: Float) -> Float { count * hopSeconds }

    func isReady(hopSeconds: Float) -> Bool { seconds(hopSeconds: hopSeconds) >= readySeconds }

    mutating func reset() {
        mean = SIMD8<Float>(repeating: 0)
        variance = SIMD8<Float>(repeating: 4)
        count = 0
    }
}
