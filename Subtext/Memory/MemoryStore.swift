import Foundation
import os

private let log = Logger(subsystem: "com.utkarsh.subtext", category: "Memory")

/// Per-track audio memory on disk: `Application Support/Memory/<trackUUID>.memory`
/// (signature.md §4). Never a recording — band energies only, with a plain-text first line.
/// App only (not compiled into the harness). Writes are atomic on a utility queue, at most once
/// per 60 s while locked and always at session end (`save(_:force: true)`).
///
/// TODO(WP7): `SessionController.start` → `MemoryStore.shared.load(trackID:cues:)` into
/// `MemoryTracker`; `SyncEngine` forwards captures (`memoryTracker.dirty`) → `save`; `end()` →
/// `save(force: true)`; `Library.remove` → `forget`; Settings "Forget all" → `forgetAll()`.
final class MemoryStore: @unchecked Sendable {
    static let shared = MemoryStore()

    /// Per-track cap (oldest captures dropped first); global LRU cap by `lastUsed`.
    static let perTrackCapBytes = 8 * 1024 * 1024
    static let globalCapBytes = 150 * 1024 * 1024
    static let minSaveInterval: TimeInterval = 60

    let directory: URL
    private let queue = DispatchQueue(label: "com.utkarsh.subtext.memory", qos: .utility)
    private var lastSave: [UUID: Date] = [:]
    private var pendingRetry: [UUID: TrackMemory] = [:]

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Memory", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    func url(for trackID: UUID) -> URL { directory.appendingPathComponent("\(trackID.uuidString).memory") }

    /// Loads the track's memory if its feature version and cue-text hash still match the cues;
    /// otherwise the file is discarded (track re-timed or replaced) and nil is returned.
    func load(trackID: UUID, cues: [Cue]) -> TrackMemory? {
        let file = url(for: trackID)
        guard let data = try? Data(contentsOf: file) else { return nil }
        do {
            var m = try MemoryCodec.decode(data)
            guard m.cueTextHash == TrackMemory.hash(cues) else {
                log.notice("Memory for \(trackID.uuidString, privacy: .public) discarded: cues changed")
                try? FileManager.default.removeItem(at: file)
                return nil
            }
            m.lastUsed = .now
            return m
        } catch {
            log.error("Memory for \(trackID.uuidString, privacy: .public) unreadable (\(String(describing: error), privacy: .public)); discarded")
            try? FileManager.default.removeItem(at: file)
            return nil
        }
    }

    /// Debounced atomic write (≤ once per 60 s unless `force`). Failures are kept for a retry on
    /// the next `save` / `retryPending` (session end, next foreground).
    func save(_ memory: TrackMemory, force: Bool = false) {
        queue.async { [self] in
            if !force, let last = lastSave[memory.trackID], Date.now.timeIntervalSince(last) < Self.minSaveInterval {
                pendingRetry[memory.trackID] = memory
                return
            }
            write(memory)
        }
    }

    /// Writes whatever `save` deferred (call at session end and on foreground).
    func retryPending() {
        queue.async { [self] in
            for (_, m) in pendingRetry { write(m) }
        }
    }

    private func write(_ memory: TrackMemory) {
        var m = memory
        m.lastUsed = .now
        Self.enforcePerTrackCap(&m)
        let data = MemoryCodec.encode(m)
        do {
            try data.write(to: url(for: m.trackID), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            lastSave[m.trackID] = .now
            pendingRetry[m.trackID] = nil
            enforceGlobalCap(keeping: m.trackID)
        } catch {
            log.error("Memory write failed: \(error.localizedDescription, privacy: .public)")
            pendingRetry[m.trackID] = m
        }
    }

    func forget(trackID: UUID) {
        queue.async { [self] in
            try? FileManager.default.removeItem(at: url(for: trackID))
            lastSave[trackID] = nil
            pendingRetry[trackID] = nil
        }
    }

    func forgetAll() {
        queue.async { [self] in
            for f in files() { try? FileManager.default.removeItem(at: f) }
            lastSave = [:]
            pendingRetry = [:]
        }
    }

    /// Bytes on disk for one track (0 when none).
    func size(trackID: UUID) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url(for: trackID).path)[.size] as? Int) ?? 0
    }

    func totalSize() -> Int { files().reduce(0) { $0 + ((try? FileManager.default.attributesOfItem(atPath: $1.path)[.size] as? Int) ?? 0) } }

    private func files() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "memory" }
    }

    /// Drops the oldest captures until the track fits 8 MB. (Thinning long cues to a 50 ms stride
    /// first, per the spec, is a known gap.)
    static func enforcePerTrackCap(_ m: inout TrackMemory) {
        guard m.byteCount > perTrackCapBytes else { return }
        let order = m.cues.values.sorted { $0.capturedAt < $1.capturedAt }
        var bytes = m.byteCount
        for sig in order where bytes > perTrackCapBytes {
            m.cues[sig.cueID] = nil
            bytes -= sig.byteCount
        }
    }

    /// Global 150 MB LRU by modification date (≈ `lastUsed`), never evicting the current track.
    private func enforceGlobalCap(keeping current: UUID) {
        var entries: [(url: URL, size: Int, date: Date)] = files().map { f in
            let attrs = (try? FileManager.default.attributesOfItem(atPath: f.path)) ?? [:]
            return (f, (attrs[.size] as? Int) ?? 0, (attrs[.modificationDate] as? Date) ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > Self.globalCapBytes else { return }
        entries.sort { $0.date < $1.date }
        for e in entries where total > Self.globalCapBytes && e.url.lastPathComponent != "\(current.uuidString).memory" {
            try? FileManager.default.removeItem(at: e.url)
            total -= e.size
        }
    }
}
