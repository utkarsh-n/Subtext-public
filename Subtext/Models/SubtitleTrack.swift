import Foundation

/// One line of subtitles and when it is on screen, in seconds from the start of the track.
struct Cue: Codable, Hashable, Identifiable, Sendable {
    let id: Int
    let start: Double
    let end: Double
    let text: String

    var duration: Double { max(0, end - start) }
}

struct SubtitleTrack: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var title: String
    /// BCP-47-ish language code of the subtitle text ("en", "hi", "es"...).
    var language: String
    var cues: [Cue]
    /// Where it came from: a filename or "OpenSubtitles".
    var source: String
    var addedAt: Date

    init(id: UUID = UUID(), title: String, language: String, cues: [Cue], source: String, addedAt: Date = .now) {
        self.id = id
        self.title = title
        self.language = language
        self.cues = cues
        self.source = source
        self.addedAt = addedAt
    }

    var duration: Double { cues.last?.end ?? 0 }

    /// Index of the cue on screen at `time`, if any.
    func cueIndex(at time: Double) -> Int? {
        var lo = 0, hi = cues.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let cue = cues[mid]
            if time < cue.start { hi = mid - 1 }
            else if time >= cue.end { lo = mid + 1 }
            else { return mid }
        }
        return nil
    }

    /// Index of the first cue that starts at or after `time`.
    func nextCueIndex(after time: Double) -> Int? {
        var lo = 0, hi = cues.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if cues[mid].start < time { lo = mid + 1 } else { hi = mid }
        }
        return lo < cues.count ? lo : nil
    }

    /// The next moment the on-screen text changes after `time`.
    func nextBoundary(after time: Double) -> Double? {
        if let current = cueIndex(at: time) {
            let end = cues[current].end
            if let next = nextCueIndex(after: time), cues[next].start < end, cues[next].start > time {
                return cues[next].start
            }
            return end
        }
        if let next = nextCueIndex(after: time) { return cues[next].start }
        return nil
    }
}

// MARK: - Parsing

enum SubtitleParseError: LocalizedError {
    case undecodable
    case noCues

    var errorDescription: String? {
        switch self {
        case .undecodable: "The file is not text Subtext can read."
        case .noCues: "No subtitle lines were found in the file."
        }
    }
}

enum SubtitleParser {
    static func parse(data: Data, filename: String) throws -> [Cue] {
        guard let text = decode(data) else { throw SubtitleParseError.undecodable }
        let cues = parse(text: text, filename: filename)
        guard !cues.isEmpty else { throw SubtitleParseError.noCues }
        return cues
    }

    static func parse(text raw: String, filename: String = "") -> [Cue] {
        let text = raw.hasPrefix("\u{FEFF}") ? String(raw.dropFirst()) : raw
        let ext = (filename as NSString).pathExtension.lowercased()
        let head = text.prefix(400)
        let cues: [Cue]
        if ext == "ass" || ext == "ssa" || head.contains("[Script Info]") || head.contains("[Events]") {
            cues = parseASS(text)
        } else if ext == "vtt" || head.hasPrefix("WEBVTT") {
            cues = parseVTT(text)
        } else {
            cues = parseSRT(text)
        }
        return finish(cues)
    }

    private static func decode(_ data: Data) -> String? {
        for encoding in [String.Encoding.utf8, .utf16, .windowsCP1252, .isoLatin1] {
            if let s = String(data: data, encoding: encoding) { return s }
        }
        return nil
    }

    /// Sort, re-number, drop empties and cues with nonsense timing.
    private static func finish(_ cues: [Cue]) -> [Cue] {
        cues
            .filter { !$0.text.isEmpty && $0.end > $0.start && $0.start >= 0 }
            .sorted { $0.start < $1.start }
            .enumerated()
            .map { Cue(id: $0.offset, start: $0.element.start, end: $0.element.end, text: $0.element.text) }
    }

    // "\r\n" is a single Character in Swift, so split on the newline property, never on "\n".
    private static func lines(_ text: String) -> [String] {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
    }

    private static func blocks(_ text: String) -> [[String]] {
        var result: [[String]] = []
        var current: [String] = []
        for line in lines(text) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty { result.append(current); current = [] }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    // MARK: SRT

    private static func parseSRT(_ text: String) -> [Cue] {
        var cues: [Cue] = []
        for block in blocks(text) {
            guard let timeLine = block.firstIndex(where: { $0.contains("-->") }) else { continue }
            guard let (start, end) = parseTimeLine(block[timeLine]) else { continue }
            let body = block[(timeLine + 1)...].joined(separator: "\n")
            cues.append(Cue(id: cues.count, start: start, end: end, text: clean(body)))
        }
        return cues
    }

    // MARK: WebVTT

    private static func parseVTT(_ text: String) -> [Cue] {
        var cues: [Cue] = []
        for block in blocks(text) {
            guard let first = block.first else { continue }
            if first.hasPrefix("WEBVTT") || first.hasPrefix("NOTE") || first.hasPrefix("STYLE") || first.hasPrefix("REGION") { continue }
            guard let timeLine = block.firstIndex(where: { $0.contains("-->") }) else { continue }
            guard let (start, end) = parseTimeLine(block[timeLine]) else { continue }
            let body = block[(timeLine + 1)...].joined(separator: "\n")
            cues.append(Cue(id: cues.count, start: start, end: end, text: clean(body)))
        }
        return cues
    }

    /// "00:01:02,345 --> 00:01:04.000 position:10%" → (62.345, 64.0)
    private static func parseTimeLine(_ line: String) -> (Double, Double)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2 else { return nil }
        let startText = parts[0].trimmingCharacters(in: .whitespaces)
        let endText = parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? ""
        guard let start = parseTimestamp(startText), let end = parseTimestamp(endText) else { return nil }
        return (start, end)
    }

    /// Accepts h:mm:ss,mmm / hh:mm:ss.mmm / mm:ss.mmm / h:mm:ss.cc
    static func parseTimestamp(_ text: String) -> Double? {
        let normalized = text.replacingOccurrences(of: ",", with: ".")
        let pieces = normalized.split(separator: ":").map(String.init)
        guard (2...3).contains(pieces.count) else { return nil }
        var seconds = 0.0
        for piece in pieces {
            guard let value = Double(piece.trimmingCharacters(in: .whitespaces)) else { return nil }
            seconds = seconds * 60 + value
        }
        return seconds
    }

    // MARK: ASS / SSA

    private static func parseASS(_ text: String) -> [Cue] {
        var cues: [Cue] = []
        var format: [String] = ["Layer", "Start", "End", "Style", "Name", "MarginL", "MarginR", "MarginV", "Effect", "Text"]
        var inEvents = false
        for line in lines(text) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                inEvents = trimmed.lowercased() == "[events]"
                continue
            }
            guard inEvents else { continue }
            if trimmed.lowercased().hasPrefix("format:") {
                format = trimmed.dropFirst(7).components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                continue
            }
            guard trimmed.lowercased().hasPrefix("dialogue:") else { continue }
            let payload = String(trimmed.dropFirst(9)).trimmingCharacters(in: .whitespaces)
            let fields = payload.components(separatedBy: ",")
            guard fields.count >= format.count,
                  let startIdx = format.firstIndex(of: "Start"),
                  let endIdx = format.firstIndex(of: "End"),
                  let textIdx = format.firstIndex(of: "Text") else { continue }
            guard let start = parseTimestamp(fields[startIdx]), let end = parseTimestamp(fields[endIdx]) else { continue }
            let body = fields[textIdx...].joined(separator: ",")
            let unescaped = body
                .replacingOccurrences(of: "\\N", with: "\n")
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\h", with: " ")
            cues.append(Cue(id: cues.count, start: start, end: end, text: clean(unescaped)))
        }
        return cues
    }

    // MARK: Text cleanup

    private static let tagPattern = try! NSRegularExpression(pattern: "<[^>]+>|\\{[^}]*\\}")
    private static let entityMap = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&nbsp;": " "]

    static func clean(_ raw: String) -> String {
        var s = tagPattern.stringByReplacingMatches(in: raw, range: NSRange(raw.startIndex..., in: raw), withTemplate: "")
        for (entity, char) in entityMap { s = s.replacingOccurrences(of: entity, with: char) }
        let cleanedLines = s
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return cleanedLines.joined(separator: "\n")
    }
}
