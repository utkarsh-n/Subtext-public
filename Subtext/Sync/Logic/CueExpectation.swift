import Foundation

/// What the cue *text* says the audio should look like (signature.md §2.2): whether it is
/// speech at all, how long the speech probably lasts (4 syl/s), and where sub-onsets fall.
///
/// `kind` detection runs everywhere (the capture path skips `[music]` / `♪` cues regardless of
/// the flag). Duration and sub-onset expectations feed the reference only behind
/// `Tuning.useTextExpectations` (default **false**, critique R14) and only for Latin-script tracks.
struct CueExpectation: Sendable, Equatable {
    enum Kind: UInt8, Sendable { case speech, nonSpeech, continuation }
    let kind: Kind
    let syllables: Int
    /// cue.start + leading pause (0.25 s when the text begins with "…" / "...").
    let speechStart: Double
    /// speechStart + min(duration, clamp(syllables / 4, 0.3, duration) × 1.25).
    let speechEnd: Double
    /// Absolute media times of secondary onsets (sentence breaks, speaker dashes).
    let subOnsets: [Double]
    /// 1.0 speech after ≥ 0.25 s gap, 0.4 continuation, 0 nonSpeech.
    let onsetWeight: Float
}

enum CueExpectations {
    static let syllablesPerSecond = 4.0
    static let minGap = 0.25

    static func build(_ cues: [Cue], language: String = "") -> [CueExpectation] {
        var out: [CueExpectation] = []
        out.reserveCapacity(cues.count)
        var previous: Cue?
        let latin = isLatinScript(language: language, sample: cues.prefix(50).map(\.text).joined(separator: " "))
        for cue in cues {
            defer { previous = cue }
            let body = stripSpeaker(cue.text)
            if isNonSpeech(body) {
                out.append(CueExpectation(kind: .nonSpeech, syllables: 0, speechStart: cue.start, speechEnd: cue.start, subOnsets: [], onsetWeight: 0))
                continue
            }
            let gap = cue.start - (previous?.end ?? -10)
            let prevText = previous.map { stripSpeaker($0.text) } ?? ""
            let prevOpen = !prevText.isEmpty && !(prevText.last.map { ".!?…".contains($0) } ?? true)
            let startsLower = body.first.map { $0.isLowercase } ?? false
            let continuation = startsLower || (prevOpen && gap < minGap)
            let kind: CueExpectation.Kind = continuation ? .continuation : .speech
            let syl = syllables(body)
            let lead = body.hasPrefix("…") || body.hasPrefix("...") ? 0.25 : 0
            let speechStart = cue.start + lead
            let duration = max(0, cue.end - speechStart)
            let speechEnd: Double
            if latin {
                let expected = min(duration, max(0.3, min(duration, Double(syl) / syllablesPerSecond)) * 1.25)
                speechEnd = speechStart + expected
            } else {
                speechEnd = cue.end
            }
            var subOnsets: [Double] = []
            if latin {
                // Sentence breaks and speaker dashes after the first line.
                var cumulative = 0
                let lines = body.split(whereSeparator: \.isNewline).map(String.init)
                for (li, line) in lines.enumerated() {
                    if li > 0, line.hasPrefix("-") || line.hasPrefix("–") {
                        subOnsets.append(speechStart + Double(cumulative) / syllablesPerSecond)
                    }
                    let sentences = line.split { ".?!…".contains($0) }.map(String.init)
                    for (si, sentence) in sentences.enumerated() {
                        if si > 0 { subOnsets.append(speechStart + Double(cumulative) / syllablesPerSecond) }
                        cumulative += syllables(sentence)
                    }
                }
                subOnsets = subOnsets.filter { $0 > speechStart + minGap && $0 < speechEnd - 0.1 }
            }
            out.append(CueExpectation(kind: kind, syllables: syl, speechStart: speechStart, speechEnd: speechEnd, subOnsets: subOnsets,
                                      onsetWeight: kind == .continuation ? 0.4 : (gap >= minGap ? 1.0 : 0.4)))
        }
        return out
    }

    /// `[music]`, `(sighs)`, `♪ … ♪`, ALL-CAPS SFX.
    static func isNonSpeech(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return true }
        if t.contains("♪") || t.contains("♫") { return true }
        if let f = t.first, let l = t.last, (f == "[" && l == "]") || (f == "(" && l == ")") { return true }
        if t.hasPrefix("#") && t.hasSuffix("#") { return true }
        let letters = t.filter(\.isLetter)
        if letters.count >= 6, !letters.contains(where: \.isLowercase), t.allSatisfy({ $0.isUppercase || $0.isWhitespace || ".!?,-'".contains($0) }) { return true }
        return false
    }

    /// Removes `NAME:` speaker labels at the start of each line.
    static func stripSpeaker(_ text: String) -> String {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map { line -> String in
            let s = String(line)
            if let colon = s.firstIndex(of: ":"), s.distance(from: s.startIndex, to: colon) <= 20 {
                let label = s[s.startIndex..<colon]
                if !label.isEmpty, label.allSatisfy({ $0.isUppercase || $0.isWhitespace || $0 == "." }) {
                    return s[s.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
            }
            return s
        }.joined(separator: "\n")
    }

    /// Latin: vowel groups per token (−1 for English trailing silent "e"), min 1 per token.
    /// Devanagari / Gujarati: aksharas. CJK: 1 per character. Unknown: characters ÷ 3.
    static func syllables(_ text: String) -> Int {
        var total = 0
        for token in text.split(whereSeparator: { !$0.isLetter }) {
            guard let first = token.first?.unicodeScalars.first else { continue }
            switch first.value {
            case 0x0900...0x0DFF: total += aksharas(token)
            case 0x3040...0x30FF, 0x4E00...0x9FFF, 0xAC00...0xD7AF: total += token.count
            default:
                if first.value < 0x0250 || (0x1E00...0x1EFF).contains(first.value) {
                    total += latinSyllables(String(token))
                } else {
                    total += max(1, token.count / 3)
                }
            }
        }
        return total
    }

    private static let vowels = Set("aeiouyáéíóúàèìòùâêîôûäëïöüãõåæøœ")

    private static func latinSyllables(_ token: String) -> Int {
        let s = token.lowercased()
        var count = 0
        var inGroup = false
        for ch in s {
            if vowels.contains(ch) {
                if !inGroup { count += 1; inGroup = true }
            } else {
                inGroup = false
            }
        }
        if s.count > 2, s.hasSuffix("e"), !s.hasSuffix("le") { count -= 1 }
        return max(1, count)
    }

    /// Independent vowels + consonants not followed by a virama, for Devanagari (0x0900) and
    /// Gujarati (0x0A80) blocks (and the other Indic blocks by the same offsets).
    private static func aksharas(_ token: Substring) -> Int {
        let scalars = Array(token.unicodeScalars)
        var count = 0
        for (i, sc) in scalars.enumerated() {
            let base = sc.value & ~0x7F
            let off = sc.value - base
            let isVirama = off == 0x4D
            let isConsonant = (0x15...0x39).contains(off)
            let isIndependentVowel = (0x05...0x14).contains(off)
            if isIndependentVowel { count += 1; continue }
            if isConsonant {
                let next = i + 1 < scalars.count ? scalars[i + 1].value - base : 0
                if next != 0x4D, !isVirama { count += 1 }
            }
        }
        return max(1, count)
    }

    static func isLatinScript(language: String, sample: String) -> Bool {
        let code = language.lowercased().prefix(2)
        if ["hi", "gu", "mr", "ne", "bn", "pa", "ta", "te", "kn", "ml", "ja", "zh", "ko", "ar", "he", "ru", "uk", "el", "th"].contains(String(code)) { return false }
        let letters = sample.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return true }
        let latin = letters.filter { $0.value < 0x0250 || (0x1E00...0x1EFF).contains($0.value) }.count
        return Double(latin) / Double(letters.count) >= 0.8
    }

    /// Indices of cues that are speech (not `nonSpeech`), the denominator of memory coverage.
    static func speechCueIDs(_ expectations: [CueExpectation]) -> Set<Int> {
        Set(expectations.enumerated().filter { $0.element.kind != .nonSpeech }.map(\.offset))
    }
}

// MARK: - Reference overloads (signature.md §2.2)

extension SpeechEnvelope {
    /// Reference envelope with text expectations: +1 from `speechStart` to `speechEnd`, 0 from
    /// `speechEnd` to `cue.end`, −1 in gaps; `nonSpeech` cues contribute 0 over their span.
    static func reference(for cues: [Cue], expectations: [CueExpectation], tailSeconds: Double = 10) -> [Float] {
        guard let last = cues.map(\.end).max() else { return [] }
        let count = bin(for: last + tailSeconds) + 1
        var bins = [Float](repeating: -1, count: count)
        for (i, cue) in cues.enumerated() {
            let e = i < expectations.count ? expectations[i] : nil
            let lo = max(0, bin(for: cue.start))
            let hi = min(count - 1, bin(for: cue.end))
            guard hi >= lo else { continue }
            if let e, e.kind == .nonSpeech {
                for k in lo...hi where bins[k] < 0 { bins[k] = 0 }
                continue
            }
            let sLo = e.map { max(lo, bin(for: $0.speechStart)) } ?? lo
            let sHi = e.map { min(hi, bin(for: $0.speechEnd)) } ?? hi
            for k in lo...hi where bins[k] < 1 { bins[k] = (k >= sLo && k <= sHi) ? 1 : 0 }
        }
        return bins
    }

    /// Onset train with per-cue weights and secondary triangles (0.5 × weight) at sub-onsets.
    static func onsetReference(for cues: [Cue], expectations: [CueExpectation], count: Int, halfWidth: Int = 25) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        func triangle(at centre: Int, height: Float) {
            guard height > 0 else { return }
            for d in -halfWidth...halfWidth {
                let i = centre + d
                guard i >= 0, i < count else { continue }
                out[i] = max(out[i], height * (1 - Float(abs(d)) / Float(halfWidth + 1)))
            }
        }
        for (i, cue) in cues.enumerated() {
            guard i < expectations.count else { triangle(at: bin(for: cue.start), height: 1); continue }
            let e = expectations[i]
            triangle(at: bin(for: e.speechStart), height: e.onsetWeight)
            for s in e.subOnsets { triangle(at: bin(for: s), height: 0.5 * e.onsetWeight) }
        }
        return out
    }
}

extension Correlator.Reference {
    /// A reference built from text expectations (nil → the V1 reference, unchanged).
    init(cues: [Cue], expectations: [CueExpectation]?) {
        if let expectations {
            let env = SpeechEnvelope.reference(for: cues, expectations: expectations)
            self.init(envelope: env, onsets: SpeechEnvelope.onsetReference(for: cues, expectations: expectations, count: env.count))
        } else {
            self.init(cues: cues)
        }
    }

    init(envelope: [Float], onsets: [Float]) {
        self.envelope = envelope
        self.onsets = onsets
    }
}
