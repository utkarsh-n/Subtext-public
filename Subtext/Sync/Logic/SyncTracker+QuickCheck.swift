import Foundation

// Tier A of the auto-pause resume (docs/v2/latch.md §2.2 F9, §5; critique C11/C12): one cheap
// single-hypothesis check that what is heard since the sound came back agrees with hypothesis P
// (the film resumed where it stopped). It never creates a lock on its own: the scheduler runs
// the clock optimistically from P and confirms with a check-in on ≥ 12 s of audio (WP2).

extension SyncTracker {
    struct QuickCheck: Sendable, Equatable {
        /// True when the best lag within ±`quickPRadiusSeconds` of P passes the thresholds.
        let agrees: Bool
        /// Best lag − P, seconds.
        let offset: Double
        let score: Float
        let onsetScore: Float
        let onsetCount: Int
        let seconds: Double
    }

    /// Correlates `mic` (0/1 bins from `windowStart`, which should be the instant the sound
    /// came back) against the reference over lags ±`quickPRadiusSeconds` around `hypothesis`
    /// (the media time at `windowStart`). Returns nil when it cannot be decided yet: fewer than
    /// `quickPWindowSeconds` of audio, too little speech, or a reference stretch with no
    /// structure (all cue or all gap, where any sound would agree). Passes when the envelope
    /// score ≥ `quickPScore`, the peak is interior to the radius, and ≥ 1 heard onset lands on a
    /// cue start (onset score ≥ `quickPOnsetScore`).
    func quickCheck(mic: [Float], windowStart: Date, hypothesis: Double) -> QuickCheck? {
        let seconds = Double(mic.count) * SpeechEnvelope.binDuration
        guard seconds >= tuning.quickPWindowSeconds else { return nil }
        let fraction = SpeechEnvelope.speechFraction(mic)
        guard fraction >= tuning.minSpeechFraction else { return nil }
        let stretched = SpeechEnvelope.stretched(mic, rate: rate)
        let centre = SpeechEnvelope.bin(for: hypothesis)
        let radius = max(1, SpeechEnvelope.bin(for: tuning.quickPRadiusSeconds))
        // The reference under the window must contain both cue and gap, or alignment means nothing.
        let refLo = max(0, centre - radius), refHi = min(reference.count, centre + radius + stretched.count)
        guard refHi > refLo else { return nil }
        var speechBins = 0
        for i in refLo..<refHi where reference.envelope[i] == 1 { speechBins += 1 }
        let refFraction = Double(speechBins) / Double(refHi - refLo)
        guard refFraction >= 0.1, refFraction <= 0.9 else { return nil }
        guard let m = Correlator.search(mic: stretched, reference: reference, range: (centre - radius)..<(centre + radius + 1)) else { return nil }
        // A peak on the search boundary means the true peak lies outside ±radius (P is wrong by
        // more than the radius, e.g. a pause that fell inside a subtitle gap): never tier A.
        let interior = abs(m.mediaTime - hypothesis) < tuning.quickPRadiusSeconds - SpeechEnvelope.binDuration
        // At least one heard onset must land on a cue start: on a 4 s window the envelope score
        // alone passed on audio from 300 s away (harness scenario 13), the onset feature did not.
        let agrees = interior && m.score >= tuning.quickPScore && m.onsetCount >= 1 && m.onsetScore >= tuning.quickPOnsetScore
        return QuickCheck(agrees: agrees, offset: m.mediaTime - hypothesis, score: m.score, onsetScore: m.onsetScore, onsetCount: m.onsetCount, seconds: seconds)
    }
}
