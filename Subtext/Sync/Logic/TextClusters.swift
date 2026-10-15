import Foundation

/// Groups cues whose text repeats (identical token sequence, then Jaccard ≥ 0.8 on token sets)
/// so a signature or phrase hit on a repeated line is never allowed to act alone
/// (signature.md §3.6). Cues with fewer than 3 tokens are never grouped. Typical film: 1–3 % of
/// long cues.
struct TextClusters: Sendable {
    /// cueIndex → cluster id, only for cues that have at least one near-duplicate.
    let clusterOf: [Int: Int]
    let members: [[Int]]

    var jaccardThreshold: Double { 0.8 }

    init(cues: [Cue]) {
        let tokens = cues.map { TranscriptMatcher.tokens($0.text) }
        var groups: [[Int]] = []
        var groupOf = [Int](repeating: -1, count: cues.count)
        // 1. Identical token sequences.
        var bySequence: [String: Int] = [:]
        for (i, t) in tokens.enumerated() where t.count >= 3 {
            let key = t.joined(separator: " ")
            if let g = bySequence[key] {
                groups[g].append(i)
                groupOf[i] = g
            } else {
                bySequence[key] = groups.count
                groupOf[i] = groups.count
                groups.append([i])
            }
        }
        // 2. Merge groups whose representative token sets overlap by Jaccard ≥ 0.8.
        let sets = tokens.map { Set($0) }
        var parent = Array(0..<groups.count)
        func find(_ x: Int) -> Int { var x = x; while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }; return x }
        let reps = groups.map { $0[0] }
        for a in 0..<reps.count {
            for b in (a + 1)..<max(a + 1, reps.count) {
                let sa = sets[reps[a]], sb = sets[reps[b]]
                let inter = sa.intersection(sb).count
                let union = sa.union(sb).count
                guard union > 0, Double(inter) / Double(union) >= 0.8 else { continue }
                let ra = find(a), rb = find(b)
                if ra != rb { parent[rb] = ra }
            }
        }
        var merged: [Int: [Int]] = [:]
        for g in 0..<groups.count { merged[find(g), default: []].append(contentsOf: groups[g]) }
        var members: [[Int]] = []
        var clusterOf: [Int: Int] = [:]
        for (_, list) in merged.sorted(by: { $0.key < $1.key }) where list.count >= 2 {
            let sorted = list.sorted()
            for i in sorted { clusterOf[i] = members.count }
            members.append(sorted)
        }
        self.members = members
        self.clusterOf = clusterOf
    }

    func isClustered(_ cue: Int) -> Bool { clusterOf[cue] != nil }

    /// The other members of `cue`'s cluster (empty when it has none).
    func siblings(of cue: Int) -> [Int] {
        guard let c = clusterOf[cue] else { return [] }
        return members[c].filter { $0 != cue }
    }
}
