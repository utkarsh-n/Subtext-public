import Foundation

/// Sequence-aware transcript matching (signature.md §3.5): instead of one best cue, the top few
/// cues by n-gram vote, which the `EvidenceLedger` turns into an offset histogram over the last
/// 40 s of phrases. `TranscriptMatcher.locate` stays for the V1 path and the harness probes.
///
/// `TranscriptMatcher`'s index is private, so this keeps an index of its own built with the same
/// tokeniser and the same rarity weights; `TranscriptMatcher.candidates(words:cues:)` is the
/// convenience spelling.
struct CandidateMatcher: Sendable {
    struct Candidate: Sendable, Equatable {
        let cueIndex: Int
        let score: Double
    }

    let cueCount: Int
    private let trigrams: [String: [Int]]
    private let bigrams: [String: [Int]]

    init(cues: [Cue]) {
        cueCount = cues.count
        var tri: [String: [Int]] = [:]
        var bi: [String: [Int]] = [:]
        for (index, cue) in cues.enumerated() {
            let words = TranscriptMatcher.tokens(cue.text)
            if words.count >= 3 {
                for i in 0...(words.count - 3) { tri[words[i] + " " + words[i + 1] + " " + words[i + 2], default: []].append(index) }
            }
            if words.count >= 2 {
                for i in 0...(words.count - 2) { bi[words[i] + " " + words[i + 1], default: []].append(index) }
            }
        }
        trigrams = tri
        bigrams = bi
    }

    /// The top `limit` cues by vote (same n-gram votes as `locate`, ±1 cue spill), best first.
    func candidates(words rawWords: [String], limit: Int = 5) -> [Candidate] {
        let words = rawWords.flatMap { TranscriptMatcher.tokens($0) }
        guard words.count >= 2 else { return [] }
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
        return votes
            .filter { $0.key >= 0 && $0.key < cueCount && $0.value > 0 }
            .sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
            .prefix(limit)
            .map { Candidate(cueIndex: $0.key, score: $0.value) }
    }
}

extension TranscriptMatcher {
    /// Top-5 cues for a phrase, as `(cueIndex, score)` (signature.md §3.5). Builds a throwaway
    /// index; callers that match repeatedly keep a `CandidateMatcher`.
    static func candidates(words: [String], cues: [Cue]) -> [(cueIndex: Int, score: Double)] {
        CandidateMatcher(cues: cues).candidates(words: words).map { ($0.cueIndex, $0.score) }
    }
}
