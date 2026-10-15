import CryptoKit
import Foundation

/// What one subtitle line sounded like: 24 mel bands at 20 ms, Int8 at 0.05 log10 units, with
/// a 0.3 s lead-in and lead-out (docs/v2/signature.md §4). ≈ 3.6 KB per cue measured (24 bands
/// × 50 frames/s × Int8 = 1.2 KB per media second, plus lead-in/out). Band energies
/// only; nothing can be played back.
struct CueSignature: Sendable, Equatable {
    static let frameSeconds = 0.02
    static let quantum: Float = 0.05
    static let defaultLeadFrames = 15

    var cueID: Int
    /// 20 ms frames including lead-in / lead-out.
    var frameCount: Int
    var leadInFrames: Int = CueSignature.defaultLeadFrames
    /// `frameCount × 24`, row-major, 0.05 log10 units.
    var frames: [Int8]
    /// Mean VAD level above the floor inside the cue, dB (the replace-policy key).
    var speechLevelDb: Float
    var captureCount: UInt8
    var rateAtCapture: Float
    var capturedAt: Date
    /// Seconds of VAD speech inside the cue when it was captured (cluster rule: < 1.5 s never acts alone).
    var speechSeconds: Float = 0

    /// Media time of frame 0 (cue.start − lead-in).
    func startMedia(cueStart: Double) -> Double { cueStart - Double(leadInFrames) * Self.frameSeconds }
    var seconds: Double { Double(frameCount) * Self.frameSeconds }
    var byteCount: Int { frames.count + 32 }

    /// Quantises averaged 20 ms frames (`frameCount × bands` floats) to the stored form.
    static func quantise(_ values: [Float]) -> [Int8] {
        values.map { Int8(max(-127, min(127, ($0 / quantum).rounded()))) }
    }

    /// Dequantised frames as floats (what `SignatureIndex` scores against).
    var floatFrames: [Float] { frames.map { Float($0) * Self.quantum } }
}

/// Everything remembered about one track: signatures keyed by cue index plus the self-check
/// reservoir that sets the per-track confirm threshold.
struct TrackMemory: Sendable {
    static let featureVersion = MelExtractor.featureVersion
    static let reservoirSize = 64

    var trackID: UUID
    /// SHA-256 over "\(start)|\(end)|\(text)\n" for every cue; mismatch on load → discard.
    var cueTextHash: Data
    var cues: [Int: CueSignature] = [:]
    /// Reservoir (≤ 64) of confirmed-hit Pearson r values from self-checks.
    var ownScores: [Float] = []
    var ownScoreSeen: Int = 0
    var lastUsed: Date = .now

    init(trackID: UUID, cueTextHash: Data) {
        self.trackID = trackID
        self.cueTextHash = cueTextHash
    }

    init(trackID: UUID, cues: [Cue]) {
        self.init(trackID: trackID, cueTextHash: Self.hash(cues))
    }

    static func hash(_ cues: [Cue]) -> Data {
        var h = SHA256()
        for c in cues { h.update(data: Data("\(c.start)|\(c.end)|\(c.text)\n".utf8)) }
        return Data(h.finalize())
    }

    /// 10th percentile of the reservoir once ≥ 20 samples exist.
    var ownScoreP10: Float? {
        guard ownScores.count >= 20 else { return nil }
        let s = ownScores.sorted()
        return s[max(0, Int(Double(s.count) * 0.1) - 1)]
    }

    /// Per-track adaptive confirm threshold: clamp((p10 ?? 0.80) − delta, floor, cap).
    func thrConfirm(floor: Float = 0.50, cap: Float = 0.85, delta: Float = 0.15) -> Float {
        min(cap, max(floor, (ownScoreP10 ?? 0.80) - delta))
    }

    /// Reservoir sampling so the threshold tracks the whole watch, not the last minute.
    mutating func recordOwnScore(_ r: Float) {
        ownScoreSeen += 1
        if ownScores.count < Self.reservoirSize {
            ownScores.append(r)
        } else {
            let j = Int.random(in: 0..<ownScoreSeen)
            if j < Self.reservoirSize { ownScores[j] = r }
        }
    }

    /// Fraction of `cueCount` cues (or of `speechCueIDs` when given) that have a signature.
    func coverage(cueCount: Int, speechCueIDs: Set<Int>? = nil) -> Double {
        if let ids = speechCueIDs {
            guard !ids.isEmpty else { return 0 }
            return Double(cues.keys.filter { ids.contains($0) }.count) / Double(ids.count)
        }
        return cueCount == 0 ? 0 : Double(cues.count) / Double(cueCount)
    }

    var byteCount: Int { cues.values.reduce(64) { $0 + $1.byteCount } }
}

/// Little-endian binary with a one-line plain-text header so a stray file is self-describing.
enum MemoryCodec {
    static let header = "Subtext audio memory v1 — band energies only, not a recording. Safe to delete.\n"
    static let magic: UInt32 = 0x4D455831 // "MEX1"

    enum DecodeError: Error { case badHeader, badVersion, truncated, badRecord }

    static func encode(_ m: TrackMemory) -> Data {
        var d = Data(header.utf8)
        d.appendLE(magic)
        d.appendLE(UInt32(TrackMemory.featureVersion))
        d.append(contentsOf: withUnsafeBytes(of: m.trackID.uuid) { Array($0) })
        d.appendLE(UInt32(m.cueTextHash.count))
        d.append(m.cueTextHash)
        d.appendLE(Float64(m.lastUsed.timeIntervalSince1970))
        d.appendLE(UInt32(m.ownScoreSeen))
        d.appendLE(UInt32(m.ownScores.count))
        for s in m.ownScores { d.appendLE(s) }
        d.appendLE(UInt32(m.cues.count))
        for id in m.cues.keys.sorted() {
            let c = m.cues[id]!
            d.appendLE(Int32(c.cueID))
            d.appendLE(Int32(c.frameCount))
            d.appendLE(Int16(c.leadInFrames))
            d.appendLE(c.speechLevelDb)
            d.append(c.captureCount)
            d.appendLE(c.rateAtCapture)
            d.appendLE(Float64(c.capturedAt.timeIntervalSince1970))
            d.appendLE(c.speechSeconds)
            d.appendLE(UInt32(c.frames.count))
            c.frames.withUnsafeBytes { d.append(contentsOf: $0) }
        }
        return d
    }

    static func decode(_ data: Data) throws -> TrackMemory {
        guard let nl = data.firstIndex(of: 0x0A) else { throw DecodeError.badHeader }
        var r = Reader(data: data, offset: nl + 1)
        guard try r.u32() == magic else { throw DecodeError.badHeader }
        guard try r.u32() == UInt32(TrackMemory.featureVersion) else { throw DecodeError.badVersion }
        let uuidBytes = try r.bytes(16)
        let uuid = uuidBytes.withUnsafeBytes { UUID(uuid: $0.load(as: uuid_t.self)) }
        let hashLen = Int(try r.u32())
        let hash = Data(try r.bytes(hashLen))
        var m = TrackMemory(trackID: uuid, cueTextHash: hash)
        m.lastUsed = Date(timeIntervalSince1970: try r.f64())
        m.ownScoreSeen = Int(try r.u32())
        let scoreCount = Int(try r.u32())
        m.ownScores = try (0..<scoreCount).map { _ in try r.f32() }
        let cueCount = Int(try r.u32())
        for _ in 0..<cueCount {
            let id = Int(try r.i32())
            let frameCount = Int(try r.i32())
            let lead = Int(try r.i16())
            let level = try r.f32()
            let count = try r.u8()
            let rate = try r.f32()
            let at = Date(timeIntervalSince1970: try r.f64())
            let speech = try r.f32()
            let n = Int(try r.u32())
            guard n == frameCount * MelExtractor.bands else { throw DecodeError.badRecord }
            let frames = try r.bytes(n).map { Int8(bitPattern: $0) }
            m.cues[id] = CueSignature(cueID: id, frameCount: frameCount, leadInFrames: lead, frames: frames, speechLevelDb: level,
                                      captureCount: count, rateAtCapture: rate, capturedAt: at, speechSeconds: speech)
        }
        return m
    }

    private struct Reader {
        let data: Data
        var offset: Int
        mutating func bytes(_ n: Int) throws -> [UInt8] {
            guard n >= 0, offset + n <= data.count else { throw DecodeError.truncated }
            let start = data.startIndex + offset
            defer { offset += n }
            return Array(data[start..<(start + n)])
        }
        mutating func u8() throws -> UInt8 { try bytes(1)[0] }
        mutating func u32() throws -> UInt32 { try bytes(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian } }
        mutating func i32() throws -> Int32 { try bytes(4).withUnsafeBytes { $0.loadUnaligned(as: Int32.self).littleEndian } }
        mutating func i16() throws -> Int16 { try bytes(2).withUnsafeBytes { $0.loadUnaligned(as: Int16.self).littleEndian } }
        mutating func f32() throws -> Float { Float(bitPattern: try bytes(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }) }
        mutating func f64() throws -> Double { Double(bitPattern: try bytes(8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).littleEndian }) }
    }
}

private extension Data {
    mutating func appendLE(_ v: UInt32) { var x = v.littleEndian; Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) } }
    mutating func appendLE(_ v: Int32) { var x = v.littleEndian; Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) } }
    mutating func appendLE(_ v: Int16) { var x = v.littleEndian; Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) } }
    mutating func appendLE(_ v: Float) { appendLE(v.bitPattern) }
    mutating func appendLE(_ v: Float64) { var x = v.bitPattern.littleEndian; Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) } }
}
