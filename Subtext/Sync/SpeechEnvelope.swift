import Foundation

/// Time discretised into 10 ms bins, each marked speech or silence.
///
/// This is the whole trick behind ffsubsync-style syncing: the subtitle track becomes a
/// binary signal (a cue is on screen → someone is talking), the microphone becomes another,
/// and the offset that best overlaps them is where we are in the film.
enum SpeechEnvelope {
    static let binDuration: Double = 0.01

    static func bin(for seconds: Double) -> Int { Int((seconds / binDuration).rounded(.down)) }
    static func seconds(for bin: Int) -> Double { Double(bin) * binDuration }

    /// Reference signal for a track: +1 while a cue is on screen, −1 otherwise.
    ///
    /// Using ±1 for the reference and 0/1 for the microphone means the correlation score
    /// rewards heard speech that lands on a cue and punishes heard speech that lands in
    /// a gap, while silence contributes nothing either way.
    static func reference(for cues: [Cue], tailSeconds: Double = 10) -> [Float] {
        guard let last = cues.map(\.end).max() else { return [] }
        let count = bin(for: last + tailSeconds) + 1
        var bins = [Float](repeating: -1, count: count)
        for cue in cues {
            let lo = max(0, bin(for: cue.start))
            let hi = min(count - 1, bin(for: cue.end))
            guard hi >= lo else { continue }
            for i in lo...hi { bins[i] = 1 }
        }
        return bins
    }

    /// Fraction of bins that are speech.
    static func speechFraction(_ bins: [Float], speechValue: Float = 1) -> Double {
        guard !bins.isEmpty else { return 0 }
        return Double(bins.filter { $0 == speechValue }.count) / Double(bins.count)
    }

    /// Fraction of a ±1 reference envelope that is speech (== 1) over media seconds `[from, to)`.
    /// Bins outside the reference count as silence. Used by the presence latch's dialogue prior
    /// and the check-in hold gate (one helper for A's SilenceWatch E and B's expectedCueSeconds).
    static func expectedSpeechFraction(reference: [Float], from: Double, to: Double) -> Double {
        guard to > from, !reference.isEmpty else { return 0 }
        let lo = bin(for: from), hi = bin(for: to)
        guard hi > lo else { return 0 }
        let a = max(0, lo), b = min(reference.count, hi)
        guard b > a else { return 0 }
        var speech = 0
        for i in a..<b where reference[i] == 1 { speech += 1 }
        return Double(speech) / Double(hi - lo)
    }

    /// Resamples a microphone window from wall-clock bins into media-time bins when the
    /// film is playing at `rate` (1.0427 for a 23.976 → 25 fps transfer, 1.5 for speed-watching).
    static func stretched(_ bins: [Float], rate: Double) -> [Float] {
        guard rate != 1, rate > 0, !bins.isEmpty else { return bins }
        let count = Int(Double(bins.count) * rate)
        var out = [Float](repeating: 0, count: count)
        for j in 0..<count {
            let i = min(bins.count - 1, Int(Double(j) / rate))
            out[j] = bins[i]
        }
        return out
    }
}

// MARK: - Onsets

extension SpeechEnvelope {
    /// Bins where speech begins after at least `minGapBins` of silence.
    static func onsets(in bins: [Float], minGapBins: Int = 30) -> [Int] {
        var result: [Int] = []
        var silentRun = minGapBins
        for (i, b) in bins.enumerated() {
            if b == 1 {
                if silentRun >= minGapBins { result.append(i) }
                silentRun = 0
            } else {
                silentRun += 1
            }
        }
        return result
    }

    /// Reference onset train: a triangle of half-width `halfWidth` bins at the start of each cue
    /// that follows a real gap (cues that merely continue a sentence are skipped).
    static func onsetReference(for cues: [Cue], count: Int, halfWidth: Int = 25, minGap: Double = 0.25) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        var previousEnd = -1.0
        for cue in cues {
            defer { previousEnd = max(previousEnd, cue.end) }
            guard cue.start - previousEnd >= minGap else { continue }
            let centre = bin(for: cue.start)
            for d in -halfWidth...halfWidth {
                let i = centre + d
                guard i >= 0, i < count else { continue }
                out[i] = max(out[i], 1 - Float(abs(d)) / Float(halfWidth + 1))
            }
        }
        return out
    }

    /// Microphone onset train as impulses.
    static func onsetSignal(for bins: [Float]) -> (signal: [Float], count: Int) {
        var out = [Float](repeating: 0, count: bins.count)
        let found = onsets(in: bins)
        for i in found { out[i] = 1 }
        return (out, found.count)
    }
}
