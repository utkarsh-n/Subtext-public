import Accelerate
import Foundation

/// Slides a microphone speech window along the subtitle envelope and reports where it fits.
///
/// Two features are correlated. The on/off envelope (is anyone talking) is tolerant of
/// detector errors but, in dense dialogue, many lags look alike. Speech onsets (someone
/// *starts* talking after a pause, lined up with a cue appearing) are sparse and sharp, so a
/// wrong lag scores near zero. A match must satisfy both.
enum Correlator {
    struct Match: Sendable {
        /// Media bin the first microphone bin lines up with.
        let bin: Int
        /// Envelope agreement minus disagreement over the window, in [−1, 1]. ~0 at a random lag.
        let score: Float
        /// Envelope peak's distance above the rest of the searched range, in standard deviations.
        let zScore: Float
        /// Envelope peak minus the best competing envelope peak more than two seconds away.
        let margin: Float
        /// Share of heard speech onsets that land on a cue start, in [0, 1].
        let onsetScore: Float
        /// Onset peak minus the best competing onset peak more than two seconds away.
        let onsetMargin: Float
        let onsetCount: Int
        /// How many standard deviations the onset score sits above what a random lag would
        /// score with this many onsets. The one number that scales with evidence.
        let onsetZ: Float

        var mediaTime: Double { SpeechEnvelope.seconds(for: bin) }
    }

    /// Weight of a heard-silence bin relative to a heard-speech bin.
    static var silenceWeight: Float = 0.7

    /// Precomputed per-track signals.
    struct Reference: Sendable {
        let envelope: [Float]
        let onsets: [Float]
        var count: Int { envelope.count }

        init(cues: [Cue]) {
            envelope = SpeechEnvelope.reference(for: cues)
            onsets = SpeechEnvelope.onsetReference(for: cues, count: envelope.count)
        }
    }

    /// Cross-correlates `mic` (0/1 bins, already stretched to media rate) against the
    /// reference for start positions in `range`. The winning lag is chosen by the onset
    /// feature when there are enough onsets, otherwise by the envelope.
    static func search(mic: [Float], reference: Reference, range: Range<Int>) -> Match? {
        let window = mic.count
        guard window > 0, reference.count > 0 else { return nil }
        let lo = max(0, range.lowerBound)
        let hi = min(reference.count - 1, range.upperBound)
        guard hi > lo else { return nil }
        let lagCount = hi - lo

        // Envelope: speech → +1, silence → −silenceWeight.
        var signed = [Float](repeating: 0, count: window)
        var scale = 1 + silenceWeight
        var shift = -silenceWeight
        vDSP_vsmsa(mic, 1, &scale, &shift, &signed, 1, vDSP_Length(window))
        var weightSum: Float = 0
        vDSP_svemg(signed, 1, &weightSum, vDSP_Length(window))
        guard weightSum > 0 else { return nil }
        let envelopeScores = correlate(filter: signed, reference: reference.envelope, lo: lo, lagCount: lagCount, normaliser: weightSum)

        let (onsetSignal, onsetCount) = SpeechEnvelope.onsetSignal(for: mic)
        let onsetScores = onsetCount > 0
            ? correlate(filter: onsetSignal, reference: reference.onsets, lo: lo, lagCount: lagCount, normaliser: Float(onsetCount))
            : nil

        let exclusion = SpeechEnvelope.bin(for: 2)
        let envelopePeak = peak(of: envelopeScores, exclusion: exclusion)
        let onsetPeak = onsetScores.map { peak(of: $0, exclusion: exclusion) }

        // Pick the lag: onsets when there are enough of them to be meaningful.
        let chosen = (onsetCount >= 4 ? onsetPeak?.index : nil) ?? envelopePeak.index
        let onsetAtChosen = onsetScores?[chosen] ?? 0
        let onsetMargin = onsetPeak.map { $0.index == chosen ? $0.margin : onsetAtChosen - $0.value } ?? 0
        let envelopeAtChosen = envelopeScores[chosen]
        let envelopeMargin = envelopePeak.index == chosen ? envelopePeak.margin : envelopeAtChosen - envelopePeak.value
        let z = envelopePeak.std > 1e-6 ? (envelopeAtChosen - envelopePeak.mean) / envelopePeak.std : 0

        // Random-lag baseline for the onset feature: the mean and spread of the reference
        // onset train over the searched span, as seen by `onsetCount` independent draws.
        var onsetZ: Float = 0
        if onsetCount > 0 {
            let span = min(reference.count, hi + window) - lo
            var mean: Float = 0, std: Float = 0
            reference.onsets.withUnsafeBufferPointer { ptr in
                vDSP_normalize(ptr.baseAddress! + lo, 1, nil, 1, &mean, &std, vDSP_Length(span))
            }
            let se = std / Float(onsetCount).squareRoot()
            onsetZ = se > 1e-6 ? (onsetAtChosen - mean) / se : 0
        }
        return Match(bin: lo + chosen, score: envelopeAtChosen, zScore: z, margin: envelopeMargin,
                     onsetScore: onsetAtChosen, onsetMargin: onsetMargin, onsetCount: onsetCount, onsetZ: onsetZ)
    }

    /// C[n] = Σ_p ref[lo+n+p]·filter[p] / normaliser for n in 0..<lagCount.
    private static func correlate(filter: [Float], reference: [Float], lo: Int, lagCount: Int, normaliser: Float) -> [Float] {
        let window = filter.count
        let needed = lagCount + window - 1
        var segment = [Float](repeating: 0, count: needed)
        let available = min(needed, reference.count - lo)
        if available > 0 { segment.replaceSubrange(0..<available, with: reference[lo..<(lo + available)]) }
        var scores = [Float](repeating: 0, count: lagCount)
        vDSP_conv(segment, 1, filter, 1, &scores, 1, vDSP_Length(lagCount), vDSP_Length(window))
        var inverse = 1 / normaliser
        vDSP_vsmul(scores, 1, &inverse, &scores, 1, vDSP_Length(lagCount))
        return scores
    }

    private struct Peak {
        let index: Int
        let value: Float
        let margin: Float
        let mean: Float
        let std: Float
    }

    private static func peak(of scores: [Float], exclusion: Int) -> Peak {
        let n = scores.count
        var mean: Float = 0, std: Float = 0
        vDSP_normalize(scores, 1, nil, 1, &mean, &std, vDSP_Length(n))
        var value: Float = 0
        var index: vDSP_Length = 0
        vDSP_maxvi(scores, 1, &value, &index, vDSP_Length(n))
        let p = Int(index)
        var runnerUp: Float = -1
        if p - exclusion > 0 {
            var m: Float = 0
            vDSP_maxv(scores, 1, &m, vDSP_Length(p - exclusion))
            runnerUp = max(runnerUp, m)
        }
        if p + exclusion < n - 1 {
            var m: Float = 0
            scores.withUnsafeBufferPointer { ptr in
                vDSP_maxv(ptr.baseAddress! + p + exclusion, 1, &m, vDSP_Length(n - p - exclusion))
            }
            runnerUp = max(runnerUp, m)
        }
        return Peak(index: p, value: value, margin: value - runnerUp, mean: mean, std: std)
    }
}
