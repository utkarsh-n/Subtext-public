import Foundation

/// Finds roughly where a few recognised words fall in the subtitle text.
///
/// Word bigrams and trigrams from every cue go into an index weighted by rarity, so
/// "I don't know" barely counts and "the Sheriff's brother" pins a scene. The answer
/// is only a neighbourhood; the correlator does the fine alignment.
struct TranscriptMatcher: Sendable {
    struct Hit: Sendable {
        let cueIndex: Int
        let mediaTime: Double
        let score: Double
        let runnerUp: Double
        var confidence: Double { runnerUp > 0 ? score / runnerUp : (score > 0 ? 10 : 0) }
    }

    private let cues: [Cue]
    private let trigrams: [String: [Int]]
    private let bigrams: [String: [Int]]

    init(cues: [Cue]) {
        self.cues = cues
        var tri: [String: [Int]] = [:]
        var bi: [String: [Int]] = [:]
        for (index, cue) in cues.enumerated() {
            let words = Self.tokens(cue.text)
            if words.count >= 3 {
                for i in 0...(words.count - 3) {
                    tri[words[i] + " " + words[i + 1] + " " + words[i + 2], default: []].append(index)
                }
            }
            if words.count >= 2 {
                for i in 0...(words.count - 2) {
                    bi[words[i] + " " + words[i + 1], default: []].append(index)
                }
            }
        }
        trigrams = tri
        bigrams = bi
    }

    static func tokens(_ text: String) -> [String] {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber && $0 != "'" }
            .map { $0.replacingOccurrences(of: "'", with: "") }
            .filter { !$0.isEmpty }
    }

    /// Scores every cue against the recognised words and returns the standout, if any.
    func locate(words rawWords: [String]) -> Hit? {
        let words = rawWords.flatMap { Self.tokens($0) }
        guard words.count >= 2 else { return nil }
        var votes: [Int: Double] = [:]

        func vote(_ key: String, in index: [String: [Int]], weight: Double) {
            guard let hits = index[key] else { return }
            let w = weight / sqrt(Double(hits.count))
            for cue in hits {
                votes[cue, default: 0] += w
                votes[cue - 1, default: 0] += w * 0.35
                votes[cue + 1, default: 0] += w * 0.35
            }
        }
        if words.count >= 3 {
            for i in 0...(words.count - 3) { vote(words[i] + " " + words[i + 1] + " " + words[i + 2], in: trigrams, weight: 3) }
        }
        for i in 0...(words.count - 2) { vote(words[i] + " " + words[i + 1], in: bigrams, weight: 1) }

        guard let best = votes.max(by: { $0.value < $1.value }), best.key >= 0, best.key < cues.count else { return nil }
        let bestTime = cues[best.key].start
        let runnerUp = votes
            .filter { $0.key >= 0 && $0.key < cues.count && abs(cues[$0.key].start - bestTime) > 60 }
            .map(\.value)
            .max() ?? 0
        return Hit(cueIndex: best.key, mediaTime: bestTime, score: best.value, runnerUp: runnerUp)
    }
}
