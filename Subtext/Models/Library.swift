import Foundation
import Observation
import os

private let log = Logger(subsystem: "com.utkarsh.subtext", category: "Library")

/// Subtitle tracks the user has imported, one JSON file each under Documents/Tracks.
@MainActor
@Observable
final class Library {
    static let shared = Library()

    private(set) var tracks: [SubtitleTrack] = []

    private let folder: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("Tracks", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private init() { load() }

    func load() {
        let decoder = JSONDecoder()
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        tracks = files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in (try? Data(contentsOf: url)).flatMap { try? decoder.decode(SubtitleTrack.self, from: $0) } }
            .sorted { $0.addedAt > $1.addedAt }
    }

    @discardableResult
    func add(_ track: SubtitleTrack) -> SubtitleTrack {
        tracks.removeAll { $0.id == track.id }
        tracks.insert(track, at: 0)
        save(track)
        return track
    }

    func rename(_ track: SubtitleTrack, to title: String) {
        guard let i = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        tracks[i].title = title
        save(tracks[i])
    }

    func remove(_ track: SubtitleTrack) {
        tracks.removeAll { $0.id == track.id }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(track.id.uuidString).json"))
    }

    /// Reads a subtitle file (from Files, a share, or a download) and adds it.
    func importFile(at url: URL, titleOverride: String? = nil, language: String? = nil, source: String? = nil) throws -> SubtitleTrack {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        return try importData(data, filename: url.lastPathComponent, titleOverride: titleOverride, language: language, source: source)
    }

    func importData(_ data: Data, filename: String, titleOverride: String? = nil, language: String? = nil, source: String? = nil) throws -> SubtitleTrack {
        let cues = try SubtitleParser.parse(data: data, filename: filename)
        let title = titleOverride ?? Self.prettyTitle(from: filename)
        let track = SubtitleTrack(title: title, language: language ?? Self.guessLanguage(from: filename), cues: cues, source: source ?? filename)
        return add(track)
    }

    private func save(_ track: SubtitleTrack) {
        let encoder = JSONEncoder()
        do {
            let data = try encoder.encode(track)
            try data.write(to: folder.appendingPathComponent("\(track.id.uuidString).json"), options: .atomic)
        } catch {
            log.error("Save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// "The.Office.S02E01.1080p.WEB.en.srt" → "The Office S02E01"
    static func prettyTitle(from filename: String) -> String {
        var name = (filename as NSString).deletingPathExtension
        for lang in ["en", "eng", "hi", "es", "fr", "gu"] where name.lowercased().hasSuffix("." + lang) {
            name = String(name.dropLast(lang.count + 1))
        }
        let junk = ["1080p", "720p", "2160p", "4k", "web", "web-dl", "webrip", "bluray", "brrip", "hdtv", "x264", "x265", "h264", "h265", "hevc", "aac", "dts", "amzn", "nf", "dsnp", "proper", "repack"]
        let words = name
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map(String.init)
        var kept: [String] = []
        for word in words {
            if junk.contains(word.lowercased()) { break }
            if word.hasPrefix("-") { break }
            kept.append(word)
        }
        let result = kept.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? name : result
    }

    static func guessLanguage(from filename: String) -> String {
        let base = (filename as NSString).deletingPathExtension.lowercased()
        let parts = base.split(separator: ".").map(String.init)
        if let last = parts.last, (2...3).contains(last.count), Locale.LanguageCode(last).isISOLanguage {
            return String(last.prefix(2))
        }
        return "en"
    }
}
