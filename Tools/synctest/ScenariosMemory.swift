import AVFoundation
import Foundation

// WP4 — audio memory scenarios (docs/v2/signature.md §7, S0–S10) and `-replayMic`.
// Declarations only; entry point `synctest_suite_memory` (SCENARIOS=memory).
//
// The memory runner is its own loop (not `runV2`) because several scenarios need a *modified*
// film (a second take, a recap copy, padded cues), which `runV2` cannot take. It mirrors the
// engine: 100 ms buffers → VAD → MicRing, MelExtractor → MelRing, 1 Hz tick → capture,
// analyse every 2 s through `MemoryTracker.analyse` (rewatch search + V1 analyse + confirm).

// MARK: - Film variants

/// A room: an echo plus a one-pole low-pass on the film path (the tvEq hook).
func roomFilter(echo: Float, delaySeconds: Double, lowPass: Float, gain: Float = 1) -> ([Float]) -> [Float] {
    { x in
        let d = Int(delaySeconds * sampleRate)
        var out = [Float](repeating: 0, count: x.count)
        var y: Float = 0
        for i in 0..<x.count {
            let e = i >= d ? x[i - d] * echo : 0
            y += lowPass * ((x[i] + e) - y)
            out[i] = y * gain
        }
        return out
    }
}

/// A 6 dB low-shelf tilt (lows boosted relative to highs) and an overall gain, for S8.
func tiltFilter(lowShelfDb: Float, gainDb: Float) -> ([Float]) -> [Float] {
    { x in
        let boost = powf(10, lowShelfDb / 20) - 1
        let g = powf(10, gainDb / 20)
        var lp: Float = 0
        let a: Float = 0.12 // ≈ 1 kHz corner at 48 kHz
        var out = [Float](repeating: 0, count: x.count)
        for i in 0..<x.count {
            lp += a * (x[i] - lp)
            out[i] = (x[i] + boost * lp) * g
        }
        return out
    }
}

/// The base film with extra lines appended after its end: `(text, samples, sameAudioAsCue)`.
/// Cues are re-numbered; `parsed` is rebuilt the same way `Film.build` does.
func extendedFilm(_ base: Film, extras: [(text: String, samples: [Float])], gapBefore: Double = 6, gaps: [Double]? = nil) -> Film {
    var samples = base.samples
    var cues = base.cues
    var cursor = (base.cues.last?.end ?? 0) + gapBefore
    for (k, extra) in extras.enumerated() {
        let start = cursor
        let duration = Double(extra.samples.count) / sampleRate
        cues.append(Cue(id: cues.count, start: (start * 1000).rounded() / 1000, end: ((start + duration + 0.25) * 1000).rounded() / 1000, text: extra.text))
        let s0 = Int(start * sampleRate)
        if samples.count < s0 + extra.samples.count { samples.append(contentsOf: [Float](repeating: 0, count: s0 + extra.samples.count - samples.count)) }
        for (j, v) in extra.samples.enumerated() { samples[s0 + j] += v * 0.5 }
        cursor = start + duration + (gaps.map { $0[k % $0.count] } ?? 1.2)
    }
    samples.append(contentsOf: [Float](repeating: 0, count: Int(10 * sampleRate)))
    let srt = cues.map { "\($0.id + 1)\n\(srtTime($0.start)) --> \(srtTime($0.end))\n\($0.text)\n" }.joined(separator: "\n")
    let parsed = SubtitleParser.parse(text: srt, filename: "x.srt")
    return Film(texts: cues.map(\.text), samples: samples, cues: cues, parsed: parsed)
}

/// The raw (unmixed) samples of cue `i` of the base film, for identical-audio copies.
func cueSamples(_ base: Film, _ i: Int) -> [Float] {
    let c = base.cues[i]
    let s0 = Int(c.start * sampleRate), s1 = min(base.samples.count, Int((c.end - 0.25) * sampleRate))
    return Array(base.samples[s0..<s1]).map { $0 * 2 } // undo the 0.5 mix gain
}

// MARK: - Runner

struct MemScenario {
    var name: String
    var film: Film
    var startAt: Double
    var rate: Double = 1
    var noise: Float = 0.03
    var seconds: Double
    var events: [RoomEvent] = []
    var memory: TrackMemory? = nil
    var seedFromTruth = false
    /// Phrase hints: at wall second, the words of cue `cue` (what the recogniser would report).
    var hints: [(at: Double, cue: Int)] = []
    /// V1-style hint: at this wall second the recogniser reports the cue that is playing.
    var hintAt: Double? = nil
    var manualChangeAt: Double? = nil
    /// Harness-only: a spurious signature proposal at this wall second (R7 anchor discipline).
    var injectProposalAt: Double? = nil
    var rewatchSearch = true
    var keepFullMel = false
    var speedWatching = false
}

struct MemOutcome {
    var lockAfter: Double?
    var error: Double?
    var confirmedAfter: Double?
    var candidateAfter: Double?
    var worst: Double = 0
    var recovery: [Double?] = []
    var wrongConfirmed = 0
    var captured: [(cue: Int, at: Double)] = []
    var capturedBeforeConfirmed = 0
    var capturedNearManual = 0
    var capturedWhileNotLocked = 0
    var confirms = 0
    var adoptions = 0
    var seeds = 0
    var rejectedSeeds = 0
    /// Proposal-driven re-seeds from a locked state, and locks restored after a rejected one.
    var reseeds = 0
    var restores = 0
    var quickConfirms = 0
    /// Wall seconds of each re-seed.
    var reseedTimes: [Double] = []
    var hints = 0
    var proposals = 0
    var clusterNotes = 0
    var hintedWindows = 0
    var suspectAt: Double?
    var seedErrors: [Double] = []
    var melMs = 0.0
    var audioSeconds = 0.0
    var analyses = 0
    var coarseChecks = 0
    var coarseHits = 0
    /// Coarse hits at the tracker's configured top-K (`tuning.memoryCoarseTop`).
    var coarseHitsCfg = 0
    var maxErrWhileRepeat: Double = 0
    var finalRate = 1.0
    var mt: MemoryTracker!
    var mel: MelRing!
    var t0 = Date()
    /// (wall, media) truth samples per second, for offline tests.
    var truthTrace: [(wall: Double, media: Double)] = []
}

func runMemory(_ s: MemScenario, repeatWindow: ClosedRange<Double>? = nil, debug: Bool = ProcessInfo.processInfo.environment["DEBUG"] != nil) -> MemOutcome {
    let cues = s.film.parsed
    let tracker = SyncTracker(cues: cues)
    if s.rate > 1.1 || s.speedWatching { tracker.tuning.searchRates += [1.25, 1.5, 1.75, 2.0] }
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let mt = MemoryTracker(tracker: tracker, cues: cues, memory: s.memory, trackID: UUID(), sessionStart: t0)
    mt.rewatchSearch = s.rewatchSearch
    var traceWall = 0.0
    if debug { mt.trace = { print(String(format: "  t=%3.0f   ↳ %@", traceWall, $0)) } }
    let vad = VoiceActivityDetector(sampleRate: sampleRate)
    let ring = MicRing(seconds: 120)
    let mel = MelRing(seconds: s.keepFullMel ? s.seconds + 10 : 120)
    let extractor = MelExtractor(inputSampleRate: sampleRate)
    ring.start(at: t0)
    mel.start(at: t0)
    var out = MemOutcome(recovery: s.events.map { _ in nil })
    out.mt = mt
    out.mel = mel
    out.t0 = t0
    let hop = 4800
    let total = Int(s.seconds * sampleRate)
    var wallSamples = 0
    var truth = s.startAt
    var started = Set<Int>()
    var nextTick = 1.0, nextAnalysis = 2.0, nextTrace = 0.0
    var melFrames: [Float] = []
    var melLevels: [Float] = []
    var hintsDone = Set<Int>()
    var manualDone = false, injectDone = false
    var confirmedLockState = false
    if s.seedFromTruth {
        tracker.seed(mediaTime: truth, at: t0)
        confirmedLockState = true
        out.lockAfter = 0; out.confirmedAfter = 0; out.error = 0
    }
    func settling(_ wall: Double) -> Bool { s.events.contains { wall >= $0.start && wall < $0.end + 60 } }
    while wallSamples < total {
        var buf = roomNoise(hop, level: s.noise)
        for i in 0..<hop {
            let wall = Double(wallSamples + i) / sampleRate
            for (k, e) in s.events.enumerated() where !started.contains(k) && wall >= e.start {
                started.insert(k)
                if case .skip(_, let by) = e { truth += by }
            }
            let paused = s.events.contains { if case .pause = $0 { return $0.contains(wall) } else { return false } }
            let silent = s.events.contains { switch $0 { case .silence, .muted: return $0.contains(wall); default: return false } }
            if !paused {
                if !silent {
                    let idx = Int(truth * sampleRate)
                    if idx >= 0 && idx < s.film.samples.count { buf[i] += s.film.samples[idx] }
                }
                truth += s.rate / sampleRate
            }
            for e in s.events where e.contains(wall) {
                if case .music(_, _, let bpm) = e { buf[i] += musicSample(wall, bpm: bpm ?? 120) }
                if case .chatter = e { buf[i] += chatterSample(wall) }
            }
        }
        let frames = vad.process(buf)
        ring.append(frames.map(\.speech))
        melFrames.removeAll(keepingCapacity: true)
        melLevels.removeAll(keepingCapacity: true)
        let tm = Date()
        let n = buf.withUnsafeBufferPointer { extractor.process($0, into: &melFrames, levels: &melLevels) }
        out.melMs += Date().timeIntervalSince(tm) * 1000
        mel.append(melFrames, count: n, levels: melLevels)
        wallSamples += hop
        out.audioSeconds = Double(wallSamples) / sampleRate
        let wallSeconds = out.audioSeconds
        let now = t0.addingTimeInterval(wallSeconds)
        traceWall = wallSeconds

        if wallSeconds >= nextTrace { nextTrace += 1; out.truthTrace.append((wallSeconds, truth)) }
        if let hintAt = s.hintAt, abs(wallSeconds - hintAt) < 0.05, let i = cues.lastIndex(where: { $0.start <= truth }) {
            // As the V1 runner: the recogniser hears the line that just finished and reports it.
            mt.addHint(words: cues[i].text.split(separator: " ").map(String.init), heardAt: now)
        }
        for (k, h) in s.hints.enumerated() where !hintsDone.contains(k) && wallSeconds >= h.at {
            hintsDone.insert(k)
            if mt.addHint(words: cues[h.cue].text.split(separator: " ").map(String.init), heardAt: now.addingTimeInterval(-cues[h.cue].duration)) { out.hints += 1 }
            if debug { print(String(format: "  t=%3.0f hint cue %d → %@", wallSeconds, h.cue, mt.ledgerPeak(at: now).map { String(format: "peak %.1f conf %.1f cues %d media %.1f", $0.peak.weight, $0.peak.confidence, $0.peak.distinctCues, $0.media) } ?? "no peak")) }
        }
        if let m = s.manualChangeAt, !manualDone, wallSeconds >= m { manualDone = true; mt.noteManualChange(at: now) }
        if let at = s.injectProposalAt, !injectDone, wallSeconds >= at {
            injectDone = true
            mt.injectProposal(cue: min(cues.count - 1, (tracker.predictedCueIndex(at: now, cues: cues) ?? 0) + 40), mediaAtWall: truth + 120, at: now)
        }
        if wallSeconds >= nextTick {
            nextTick += 1
            let captured = mt.captureOnTick(now: now, mel: mel, micRing: ring)
            for c in captured {
                out.captured.append((c.cueID, wallSeconds))
                if !confirmedLockState { out.capturedBeforeConfirmed += 1 }
                if let m = s.manualChangeAt, wallSeconds >= m, wallSeconds < m + 10 { out.capturedNearManual += 1 }
                if !(tracker.state == .locked && tracker.lock?.confirmed == true) { out.capturedWhileNotLocked += 1 }
            }
            // The engine runs the rewatch search on every 1 Hz tick while acquiring / lost
            // (signature.md §3.4 "every analysis tick"); the 2 s analyse covers even seconds.
            if Int(wallSeconds.rounded()) % 2 == 1 {
                let mr = mt.rewatchTick(now: now, mel: mel, micRing: ring)
                if mr.seeded, let l = tracker.lock { out.seeds += 1; out.seedErrors.append(l.mediaTime(at: now) - truth); if out.candidateAfter == nil { out.candidateAfter = wallSeconds } }
                if mr.reseeded { out.reseeds += 1; out.reseedTimes.append(wallSeconds) }
                if mr.hinted { out.hints += 1 }
                if debug, !mr.note.isEmpty { print(String(format: "  t=%3.0f tick | %@ state=%@ truth=%.1f", wallSeconds, mr.note, "\(tracker.state)", truth)) }
            }
        }
        if wallSeconds >= nextAnalysis {
            nextAnalysis += 2
            let window = mt.suggestedWindowSeconds(at: now) ?? 60
            guard let w = ring.latest(seconds: window) else { continue }
            // Coarse-stage recall while still searching: is a cue that really played in the last
            // 8 s inside the coarse top-20?
            if mt.rewatchSearchAvailable, tracker.state == .searching || tracker.state == .listening, let mw = mel.latest(seconds: 8), mw.count >= 400 {
                let (f20, c20) = SignatureIndex.to20ms(frames10: mw.frames, count: mw.count)
                let (h, hc) = SignatureIndex.stretch(frames: f20, count: c20, rate: s.rate)
                // Recall at the spec's top-20 and at the top-K the tracker actually runs
                // (`tuning.memoryCoarseTop`, 40 after `MemoryTracker.measuredCoarseTop`).
                let cfgTop = tracker.tuning.memoryCoarseTop
                let ranked = mt.index.coarseSearch(heard: h, heardCount: hc, top: max(20, cfgTop)).map(\.cueID)
                let top20 = Set(ranked.prefix(20)), topCfg = Set(ranked.prefix(cfgTop))
                let lo = truth - 8 * s.rate
                let inWindow = mt.index.cueIDs.filter { cues[$0].start >= lo && cues[$0].end <= truth }
                if !inWindow.isEmpty {
                    out.coarseChecks += 1
                    if inWindow.contains(where: { top20.contains($0) }) { out.coarseHits += 1 }
                    if inWindow.contains(where: { topCfg.contains($0) }) { out.coarseHitsCfg += 1 }
                }
            }
            let wasCandidateSeed = mt.lastReport.seeded
            let (report, mr) = mt.analyse(mic: w.bins, windowStart: w.start, now: now, mel: mel, micRing: ring)
            out.analyses += 1
            if mr.confirmed { out.confirms += 1 }
            if mr.adopted { out.adoptions += 1 }
            if mr.hinted { out.hints += 1 }
            if mr.proposedCue != nil { out.proposals += 1 }
            if mr.note.contains("position unknown") { out.clusterNotes += 1 }
            if report.note.hasPrefix("hinted search") { out.hintedWindows += 1 }
            if mr.seeded, let l = tracker.lock { out.seeds += 1; out.seedErrors.append(l.mediaTime(at: now) - truth); if out.candidateAfter == nil { out.candidateAfter = wallSeconds } }
            if mr.reseeded { out.reseeds += 1; out.reseedTimes.append(wallSeconds) }
            if mr.restored { out.restores += 1 }
            if mr.quickConfirmed { out.quickConfirms += 1 }
            if wasCandidateSeed, report.lock == nil || mr.restored { out.rejectedSeeds += 1 }
            if mt.memorySuspect, out.suspectAt == nil { out.suspectAt = wallSeconds }
            if debug {
                print(String(format: "  t=%3.0f w%2.0f sp %.2f %@ | %@ state=%@ lock=%@ truth=%.1f err=%@", wallSeconds, window, report.speechFraction, report.note, mr.note, "\(report.state)", report.lock.map { String(format: "%.1f%@", $0.mediaTime(at: now), $0.confirmed ? "" : "?") } ?? "-", truth, report.lock.map { String(format: "%+.2f", $0.mediaTime(at: now) - truth) } ?? "-"))
            }
            if let lock = report.lock {
                let err = lock.mediaTime(at: now) - truth
                if out.lockAfter == nil { out.lockAfter = wallSeconds; out.error = err }
                if lock.confirmed {
                    if out.confirmedAfter == nil { out.confirmedAfter = wallSeconds }
                    confirmedLockState = true
                    if !settling(wallSeconds) {
                        out.worst = max(out.worst, abs(err))
                        if abs(err) > 1.5 { out.wrongConfirmed += 1 }
                    }
                    if let rw = repeatWindow, rw.contains(truth) { out.maxErrWhileRepeat = max(out.maxErrWhileRepeat, abs(err)) }
                    for (k, e) in s.events.enumerated() where out.recovery[k] == nil && wallSeconds > e.end + 0.5 {
                        if abs(err) < 0.5 { out.recovery[k] = wallSeconds - e.end }
                    }
                }
            }
        }
    }
    out.finalRate = tracker.rate
    return out
}

extension MemoryTracker {
    /// Harness-only: pretend another cue's signature proposed a correction (R7 test). A single
    /// proposal must never move a confirmed lock; the predicted cue's next confirm clears it.
    func injectProposal(cue: Int, mediaAtWall: Double, at wall: Date) {
        injectPendingProposal(cue: cue, mediaAtWall: mediaAtWall, at: wall)
    }
}

// MARK: - Offline measurements

/// Rank test (S1): for each stored cue that fully played in a run without events, an 8 s heard
/// block (the live lookback) starting 0.3 s before its signature is scored against every stored
/// signature that fits inside it (as the live confirm / search paths do). Returns (rank-1 count,
/// tried, right r values, best-wrong r values).
func rankTest(_ o: MemOutcome, scenario s: MemScenario, index: SignatureIndex) -> (rank1: Int, tried: Int, right: [Float], wrong: [Float]) {
    var rank1 = 0, tried = 0
    var right: [Float] = [], wrong: [Float] = []
    let cues = s.film.parsed
    for id in index.cueIDs {
        guard let e = index.entries[id] else { continue }
        let sigStart = e.startMedia
        let sigSeconds = Double(e.frameCount) * CueSignature.frameSeconds
        guard sigSeconds + 0.6 <= 8 else { continue }
        let wallStart = (sigStart - 0.3 - s.startAt) / s.rate
        let wallSeconds = 8.0 / s.rate
        guard wallStart >= 0, wallStart + wallSeconds <= s.seconds - 0.5 else { continue }
        guard let w = o.mel.window(from: o.t0.addingTimeInterval(wallStart), seconds: wallSeconds) else { continue }
        let (f20, c20) = SignatureIndex.to20ms(frames10: w.frames, count: w.count)
        let (h, hc) = SignatureIndex.stretch(frames: f20, count: c20, rate: s.rate)
        let ranked = index.rankAll(heard: h, heardCount: hc, trueStart: 15, shift: 15)
        guard let first = ranked.first, let own = ranked.first(where: { $0.cueID == id }) else { continue }
        tried += 1
        if first.cueID == id { rank1 += 1 } else if ProcessInfo.processInfo.environment["DEBUG"] != nil {
            print(String(format: "  rank miss: own cue %d r %.2f, best cue %d r %.2f \"%@\" vs \"%@\"", id, own.r, first.cueID, first.r, cues[id].text.prefix(30) as CVarArg, cues[first.cueID].text.prefix(30) as CVarArg))
        }
        right.append(own.r)
        if let bw = ranked.first(where: { $0.cueID != id && abs(cues[$0.cueID].start - cues[id].start) > 2 }) { wrong.append(bw.r) }
    }
    return (rank1, tried, right, wrong)
}

func percentile(_ v: [Float], _ p: Double) -> Float {
    guard !v.isEmpty else { return .nan }
    let s = v.sorted()
    return s[min(s.count - 1, max(0, Int(Double(s.count) * p)))]
}

func memFmt(_ v: Double?, _ f: String = "%.0f") -> String { v.map { String(format: f, $0) } ?? "never" }

// MARK: - The suite

let roomA = roomFilter(echo: 0.3, delaySeconds: 0.05, lowPass: 0.2)
let roomB = roomFilter(echo: 0.15, delaySeconds: 0.08, lowPass: 0.35)

/// Learn pass: the whole film from the start in room A, V1 lock, capture on tick.
func learnPass(_ theFilm: Film, name: String, noise: Float = 0.03, filter: (([Float]) -> [Float])? = roomA, seed: Bool = false, print doPrint: Bool = true) -> (TrackMemory, MemOutcome) {
    let f = filter.map { theFilm.filtered($0) } ?? theFilm
    let s = MemScenario(name: name, film: f, startAt: 0, noise: noise, seconds: theFilm.seconds, seedFromTruth: seed)
    let o = runMemory(s)
    let mt = o.mt!
    let speechIDs = mt.speechCueIDs
    let lockedFrom = o.confirmedAfter ?? .infinity
    let playedWhileLocked = speechIDs.filter { theFilm.parsed[$0].start >= lockedFrom + 6 && theFilm.parsed[$0].end < theFilm.seconds - 2 }
    let coveredPlayed = playedWhileLocked.filter { mt.memory.cues[$0] != nil }.count
    if doPrint {
        print(String(format: "%@: lock@%@ confirm@%@ captured %d cues (%d%% of %d speech cues that played while locked), %d B/cue, %.0f B per media second, before-confirm %d, not-locked %d, mel %.1f ms per 60 s",
                     name, memFmt(o.lockAfter), memFmt(o.confirmedAfter), mt.memory.cues.count,
                     playedWhileLocked.isEmpty ? 0 : coveredPlayed * 100 / playedWhileLocked.count, playedWhileLocked.count,
                     mt.memory.cues.isEmpty ? 0 : mt.memory.byteCount / mt.memory.cues.count,
                     Double(mt.memory.byteCount) / max(1, mt.memory.cues.values.reduce(0) { $0 + $1.seconds }),
                     o.capturedBeforeConfirmed, o.capturedWhileNotLocked, o.melMs / o.audioSeconds * 60))
    }
    return (mt.memory, o)
}

@_cdecl("synctest_suite_memory")
public func synctestSuiteMemory() {
    if let path = ProcessInfo.processInfo.environment["REPLAY_MIC"] ?? replayMicArgument() {
        replayMic(path: path)
        return
    }
    let only = (ProcessInfo.processInfo.environment["MEM"] ?? "").split(separator: ",").map { String($0).lowercased() }
    func want(_ s: String) -> Bool { only.isEmpty || only.contains(s.lowercased()) }
    print("\n=== WP4 audio memory ===")
    let cues = film.parsed

    // S1 learn pass + codec round trip.
    let (memoryA, learn) = learnPass(film, name: "S1 learn (room A, noise 0.03)")
    do {
        let data = MemoryCodec.encode(memoryA)
        let back = try! MemoryCodec.decode(data)
        let same = back.cues == memoryA.cues && back.cueTextHash == memoryA.cueTextHash
        print("S1 codec: \(data.count) bytes, \(back.cues.count) cues, round trip \(same ? "OK" : "MISMATCH"), header \"\(String(decoding: data.prefix(30), as: UTF8.self))…\"")
    }
    _ = learn

    if want("s1") { runS1(memoryA) }
    if want("s2") { runS2(memoryA) }
    if want("s3") { runS3() }
    if want("s4") { runS4() }
    if want("s5") { runS5(memoryA) }
    if want("s7") { runS7(memoryA) }
    if want("s8") { runS8(memoryA) }
    if want("s9") { runS9(memoryA) }
    if want("s10") { runS10(memoryA) }
    if want("s6") { runS6() }
    if want("s0") { runS0() }
    _ = cues
}

func replayMicArgument() -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "-replayMic"), i + 1 < args.count else { return nil }
    return args[i + 1]
}

// MARK: S1 — learn then rewatch

func runS1(_ memory: TrackMemory) {
    print("\nS1 rewatch (room B), 20 random starts per noise level (no memory: V1 first lock 16–38 s):")
    print("noise   rank-1   right r mean/p10   best-wrong p90/max   thr    cand≤8s  conf≤8s  conf≤14s  wrong  seeds/rej  quick  coarse recall @20/@cfg  confirm@ median")
    var minRightP10: Float = 1, maxWrong: Float = 0, cfgTop = 0
    for noise in [Float(0.01), 0.08, 0.15] {
        var rank1 = 0, tried = 0
        var right: [Float] = [], wrong: [Float] = []
        var cand8 = 0, conf8 = 0, conf14 = 0, wrongLocks = 0, seeds = 0, rejected = 0, quick = 0, cc = 0, ch = 0, chCfg = 0
        var locks: [Double] = []
        var thr: Float = 0
        var rng2 = SystemRandomNumberGenerator()
        for _ in 0..<20 {
            let start = Double.random(in: 20...(film.seconds - 90), using: &rng2)
            let s = MemScenario(name: "rewatch", film: film.filtered(roomB), startAt: start, noise: noise, seconds: 60, memory: memory, keepFullMel: true)
            let o = runMemory(s)
            let r = rankTest(o, scenario: s, index: o.mt.index)
            rank1 += r.rank1; tried += r.tried; right += r.right; wrong += r.wrong
            if let c = o.candidateAfter, c <= 8 { cand8 += 1 }
            if let c = o.confirmedAfter { if c <= 8 { conf8 += 1 }; if c <= 14 { conf14 += 1 }; locks.append(c) }
            wrongLocks += o.wrongConfirmed
            seeds += o.seeds; rejected += o.rejectedSeeds; quick += o.quickConfirms
            cc += o.coarseChecks; ch += o.coarseHits; chCfg += o.coarseHitsCfg
            thr = o.mt.thrConfirm
            cfgTop = o.mt.tracker.tuning.memoryCoarseTop
        }
        locks.sort()
        minRightP10 = min(minRightP10, percentile(right, 0.10))
        maxWrong = max(maxWrong, wrong.max() ?? 0)
        print(String(format: "%.2f   %3d/%-3d   %.2f / %.2f          %.2f / %.2f      %.2f   %2d/20    %2d/20    %2d/20     %d      %d/%d     %2d     %3d%% / %3d%% (%d)      %@",
                     noise, rank1, tried, right.isEmpty ? 0 : right.reduce(0, +) / Float(right.count), percentile(right, 0.10),
                     percentile(wrong, 0.90), wrong.max() ?? 0, thr, cand8, conf8, conf14, wrongLocks, seeds, rejected, quick,
                     cc == 0 ? 0 : ch * 100 / cc, cc == 0 ? 0 : chCfg * 100 / cc, cc, locks.isEmpty ? "never" : String(format: "%.0f s", locks[locks.count / 2])))
    }
    print("  (cand: memory-seeded candidate; conf: the envelope confirmed it — V1's narrow tracking rule on the 6–12 s of audio since the first signature hit; 'quick' counts those short-window confirms; coarse recall at the spec's top-20 and at the tracker's top-\(cfgTop))")
    // The confirm threshold is adaptive (clamp(p10 − 0.15, floor, cap)); the one measured
    // number is the cap (`MemoryTracker.measuredConfirmCap`, overriding Tuning.memoryConfirmCap):
    // it must sit above every wrong cue and below the right cue's p10 at the noisiest room.
    let learnP10 = memory.ownScoreP10 ?? 0.80
    let uncapped = max(0.50, learnP10 - 0.15)
    let cap = MemoryTracker.measuredConfirmCap
    let capOK = maxWrong + 0.03 <= cap && cap <= minRightP10 - 0.03
    print(String(format: "  confirm cap derivation: learn-pass ownScoreP10 %.2f → uncapped thr %.2f; rewatch right-cue p10 min %.2f, best-wrong max %.2f over the three rooms → cap must satisfy %.2f ≤ cap ≤ %.2f; measuredConfirmCap %.2f (Tuning.memoryConfirmCap %.2f) → %@",
                 learnP10, uncapped, minRightP10, maxWrong, maxWrong + 0.03, minRightP10 - 0.03, cap, SyncTracker.Tuning().memoryConfirmCap, capOK ? "OK" : "CHECK"))
}

// MARK: S2 — check-in after pause / skip with memory, and the anchor-discipline tests

func runS2(_ memory: TrackMemory) {
    print("\nS2 pause / skip with memory (V1 baseline recovery 40–54 s):")
    print("scenario                       lock@   confirm@  worst   recovery   seeds/rej   hints  confirms  adopt  wrongLocks  reseeds/restored  quick")
    let scenarios: [MemScenario] = [
        MemScenario(name: "pause 90s at 60s", film: film.filtered(roomB), startAt: 100, noise: 0.03, seconds: 300, events: [.pause(at: 60, seconds: 90)], memory: memory),
        MemScenario(name: "skip ahead 30s at 70s", film: film.filtered(roomB), startAt: 60, noise: 0.03, seconds: 200, events: [.skip(at: 70, by: 30)], memory: memory),
        MemScenario(name: "skip back 20s at 70s", film: film.filtered(roomB), startAt: 120, noise: 0.03, seconds: 200, events: [.skip(at: 70, by: -20)], memory: memory),
        MemScenario(name: "music over a gap, 40s", film: film.filtered(roomB), startAt: film.cues[16].end - 20, noise: 0.03, seconds: 160, events: [.music(at: 20, seconds: 40)], memory: memory),
        MemScenario(name: "no memory: pause 90s", film: film.filtered(roomB), startAt: 100, noise: 0.03, seconds: 300, events: [.pause(at: 60, seconds: 90)], memory: nil),
    ]
    for s in scenarios {
        let o = runMemory(s)
        print(s.name.padding(toLength: 30, withPad: " ", startingAt: 0) + pad(memFmt(o.lockAfter), 6) + pad(memFmt(o.confirmedAfter), 10) + pad(String(format: "%.2f", o.worst), 8)
              + pad(o.recovery.map { memFmt($0) }.joined(separator: ","), 10) + pad("\(o.seeds)/\(o.rejectedSeeds)", 11) + pad("\(o.hints)", 7) + pad("\(o.confirms)", 9) + pad("\(o.adoptions)", 6) + pad("\(o.wrongConfirmed)", 11)
              + pad("\(o.reseeds)/\(o.restores)", 17) + pad("\(o.quickConfirms)", 7))
    }
    // R7 anchor discipline: one spurious proposal must never move a confirmed lock. (a) a 5 s
    // glitch of audio from 200 s later (a recap-style cut), (b) an injected single proposal at a
    // position 120 s away. Pass: no re-seed from the locked state, 0 wrong confirmed locks, and
    // the lock is within 0.5 s of truth 20 s after the event (worst outside settling ≤ 0.5 s).
    let glitch = MemScenario(name: "spurious: 5 s of wrong audio at 90 s", film: film.filtered(roomB), startAt: 60, noise: 0.03, seconds: 150,
                             events: [.skip(at: 90, by: 200), .skip(at: 95, by: -200)], memory: memory)
    let og = runMemory(glitch)
    let inject = MemScenario(name: "spurious: injected proposal at 90 s", film: film.filtered(roomB), startAt: 60, noise: 0.03, seconds: 150, memory: memory, injectProposalAt: 90)
    let oi = runMemory(inject)
    for (s, o) in [(glitch, og), (inject, oi)] {
        let ok = o.reseeds == 0 && o.wrongConfirmed == 0 && o.worst <= 0.5
        print(s.name.padding(toLength: 40, withPad: " ", startingAt: 0) + String(format: "lock@%@ worst %.2f cold seeds %d, proposals %d, re-seeds %d (restored %d) confirms %d wrongLocks %d → %@",
                                                                                   memFmt(o.lockAfter), o.worst, o.seeds, o.proposals, o.reseeds, o.restores, o.confirms, o.wrongConfirmed,
                                                                                   ok ? "lock unchanged OK" : (o.restores == o.reseeds && o.wrongConfirmed == 0 && o.worst <= 0.5 ? "re-seed rejected and restored (bounded)" : "LOCK MOVED")))
    }
}

// MARK: S3 — repeated lines, different take

func runS3() {
    let repeats = [24, 34, 42, 57, 85] // long lines
    let voice2 = "Daniel"
    let extras = repeats.map { (film.parsed[$0].text, synth(film.parsed[$0].text, index: $0, voice: voice2)) }
    let f2 = extendedFilm(film, extras: extras)
    let clusters = TextClusters(cues: f2.parsed)
    let (mem, _) = learnPass(f2, name: "S3 learn (film + 5 second-take repeats)", print: false)
    // Rewatch: start 30 s before the repeats.
    let repeatStart = f2.parsed[film.parsed.count].start
    let repeatEnd = f2.parsed.last!.end
    let s = MemScenario(name: "S3 rewatch", film: f2.filtered(roomB), startAt: repeatStart - 30, noise: 0.03, seconds: repeatEnd - repeatStart + 35, memory: mem, keepFullMel: true)
    let o = runMemory(s, repeatWindow: repeatStart...repeatEnd)
    // Own-take vs other-take r on the heard second take.
    var own: [Float] = [], other: [Float] = []
    let index = o.mt.index
    for (k, orig) in repeats.enumerated() {
        let dup = film.parsed.count + k
        guard let e = index.entries[dup], index.entries[orig] != nil else { continue }
        let wallStart = (e.startMedia - 0.3 - s.startAt)
        guard let w = o.mel.window(from: o.t0.addingTimeInterval(wallStart), seconds: Double(e.frameCount) * 0.02 + 0.6) else { continue }
        let (h, hc) = SignatureIndex.to20ms(frames10: w.frames, count: w.count)
        let ranked = index.rankAll(heard: h, heardCount: hc, trueStart: 15, shift: 15)
        if let a = ranked.first(where: { $0.cueID == dup }) { own.append(a.r) }
        if let b = ranked.first(where: { $0.cueID == orig }) { other.append(b.r) }
    }
    let sep = ((Double((own.min() ?? 0) - (other.max() ?? 0)) * 100).rounded() / 100)
    print(String(format: "\nS3 repeated lines, second take: clusters %d (%@) · lock@%@ · max error while the duplicates play %.2f s (want ≤ 0.5) · own-take r %.2f–%.2f vs other-take %.2f–%.2f · separation %.2f (want ≥ 0.15) · wrongLocks %d → %@",
                 clusters.members.count, clusters.members.map { "\($0)" }.joined(separator: " "), memFmt(o.lockAfter), o.maxErrWhileRepeat,
                 own.min() ?? 0, own.max() ?? 0, other.min() ?? 0, other.max() ?? 0, sep, o.wrongConfirmed,
                 (o.maxErrWhileRepeat <= 0.5 && sep >= 0.15 && o.wrongConfirmed == 0) ? "OK" : "CHECK"))
}

// MARK: S4 — repeated lines, identical audio

/// Lines that are not in the film, spoken by the film's voice: the context that tells a recap
/// from the scene it recaps. Cached under indices ≥ 200 so they never collide with cue files.
let s4ContextLines = [
    "The harbour master keeps a second ledger.",
    "Nobody mentioned a second ledger to me.",
    "Because nobody thought to ask him.",
    "We should have asked him before the ferry left.",
    "We are asking him now, and he is not answering.",
    "Then we wait on the quay until he does.",
]

func runS4() {
    // A recap: cue 40 copied verbatim after the film, followed by three new lines; then the
    // 3-line exchange 24–26 two minutes later, again followed by three new lines.
    let ctx = s4ContextLines.enumerated().map { ($0.element, synth($0.element, index: 200 + $0.offset)) }
    let recap = [(film.parsed[40].text, cueSamples(film, 40))] + Array(ctx[0..<3])
    let exchange = [24, 25, 26].map { (film.parsed[$0].text, cueSamples(film, $0)) } + Array(ctx[3..<6])
    var f2 = extendedFilm(film, extras: recap, gapBefore: 6)
    f2 = extendedFilm(f2, extras: exchange, gapBefore: 120)
    let n = film.parsed.count
    let clusters = TextClusters(cues: f2.parsed)
    let (mem, _) = learnPass(f2, name: "S4 learn", print: false)
    // (a) a lone repeated phrase → no hint.
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let tracker = SyncTracker(cues: f2.parsed)
    let mt = MemoryTracker(tracker: tracker, cues: f2.parsed, memory: nil, trackID: UUID(), sessionStart: t0)
    let lone = mt.addHint(words: f2.parsed[40].text.split(separator: " ").map(String.init), heardAt: t0.addingTimeInterval(30))
    let lonePeak = mt.ledgerPeak(at: t0.addingTimeInterval(30))
    // (b) the preceding neighbour phrase then the repeat → hint on the right instance.
    let mt2 = MemoryTracker(tracker: SyncTracker(cues: f2.parsed), cues: f2.parsed, memory: nil, trackID: UUID(), sessionStart: t0)
    let secondInstance = n + 4 // the exchange's first line (cue 24's twin): after the recap and its 3 context lines
    // Hear cue 39 (neighbour of the first instance) then cue 40 at the matching gap: → first instance.
    let gap = f2.parsed[40].start - f2.parsed[39].start
    mt2.addHint(words: f2.parsed[39].text.split(separator: " ").map(String.init), heardAt: t0.addingTimeInterval(30))
    let hinted = mt2.addHint(words: f2.parsed[40].text.split(separator: " ").map(String.init), heardAt: t0.addingTimeInterval(30 + gap))
    let hintMedia = tracker2Hint(mt2)
    let landedOn = hintMedia.flatMap { m in f2.parsed.firstIndex { m >= $0.start - 1 && m < $0.end + 1 } }
    print(String(format: "\nS4 identical audio: clusters %d; lone repeated phrase → hint %@ (peak %@, want none); neighbour then repeat → hint %@ on cue %@ (want 40 ±1) %@",
                 clusters.members.count, lone ? "YES" : "none", lonePeak.map { String(format: "conf %.1f", $0.peak.confidence) } ?? "none",
                 hinted ? "YES" : "none", landedOn.map(String.init) ?? "-", (!lone && hinted && landedOn.map { abs($0 - 40) <= 1 } == true) ? "OK" : "CHECK"))
    // (c) rewatch starting right at the recap / the repeated exchange with memory: the twin must
    // be reported as "cluster, position unknown", no false jump to the first instance, and the
    // context lines that follow resolve the position (confirmed lock within 0.5 s of truth).
    let recapStart = f2.parsed[n].start
    let s = MemScenario(name: "S4 rewatch at the recap", film: f2.filtered(roomB), startAt: recapStart - 1, noise: 0.03, seconds: 45, memory: mem)
    let o = runMemory(s)
    let s2 = MemScenario(name: "S4 rewatch at the exchange", film: f2.filtered(roomB), startAt: f2.parsed[secondInstance].start - 1, noise: 0.03, seconds: 45, memory: mem)
    let o2 = runMemory(s2)
    for (sc, oo) in [(s, o), (s2, o2)] {
        print(String(format: "  %@: lock@%@ confirm@%@ err %@ seeds %d/%d rejected, cluster notes %d, wrongLocks %d, worst %.2f → %@",
                     sc.name, memFmt(oo.lockAfter), memFmt(oo.confirmedAfter), memFmt(oo.error, "%+.2f"), oo.seeds, oo.rejectedSeeds, oo.clusterNotes, oo.wrongConfirmed, oo.worst,
                     oo.wrongConfirmed == 0 ? (oo.confirmedAfter != nil && oo.worst <= 0.5 ? "no false jump, resolved by context" : "no false jump (not resolved in 45 s)") : "FALSE JUMP"))
    }
}

private func tracker2Hint(_ mt: MemoryTracker) -> Double? { mt.tracker.hint?.mediaTime }

// MARK: S5 — wrong film with memory

func runS5(_ memory: TrackMemory) {
    // Film B: the same lines in another order, a different voice, fresh gaps. Memory and cues
    // stay film A's; the tracker must never accept a memory hint or seed.
    var order = Array(0..<film.parsed.count)
    order.shuffle(using: &rng)
    let extras = order.prefix(40).map { (film.parsed[$0].text, synth(film.parsed[$0].text, index: $0, voice: "Daniel")) }
    let filmB = extendedFilm(Film(texts: [], samples: [], cues: [], parsed: []), extras: extras, gapBefore: 3)
    let s = MemScenario(name: "S5", film: Film(texts: film.texts, samples: filmB.samples, cues: film.cues, parsed: film.parsed), startAt: 0, noise: 0.02, seconds: 150, memory: memory)
    let o = runMemory(s)
    // Any confirmed lock on the wrong film is wrong (the truth clock is meaningless here, so
    // `wrongConfirmed`'s |err| > 1.5 s rule would under-count).
    let wrong = o.confirmedAfter == nil ? 0 : 1
    print(String(format: "\nS5 wrong film with memory: seeds %d (confirmed wrong locks %d, want 0; lock@%@ confirm@%@), hints %d, hinted windows %d, memorySuspect at %@ (want ≤ 4 hinted windows), confirms %d → %@",
                 o.seeds, wrong, memFmt(o.lockAfter), memFmt(o.confirmedAfter), o.hints, o.hintedWindows, memFmt(o.suspectAt), o.confirms,
                 (wrong == 0 && (o.suspectAt != nil || o.hints == 0)) ? "OK" : "CHECK"))
}

// MARK: S6 — text expectations A/B

func runS6() {
    // Padded SRT: end = speechEnd + U(0.3, 1.5), min display 1.5 s, plus 10 non-speech cues.
    var padded: [Cue] = []
    for c in film.cues {
        let speechEnd = c.end - 0.25
        let end = max(c.start + 1.5, speechEnd + Double.random(in: 0.3...1.5, using: &rng))
        padded.append(Cue(id: 0, start: c.start, end: min(end, (film.cues.first { $0.start > c.start }?.start ?? end + 1) - 0.05), text: c.text))
    }
    let markers = ["[music]", "(sighs)", "♪ ♪", "[door closes]", "(laughs)", "♪ la la ♪", "[thunder]", "(coughs)", "[MUSIC PLAYING]", "(gasps)"]
    for (k, m) in markers.enumerated() {
        let i = 9 * k + 5
        guard i + 1 < film.cues.count else { break }
        let gapStart = film.cues[i].end + 0.2, gapEnd = film.cues[i + 1].start - 0.1
        if gapEnd - gapStart > 0.8 { padded.append(Cue(id: 0, start: gapStart, end: gapEnd, text: m)) }
    }
    padded = padded.sorted { $0.start < $1.start }.enumerated().map { Cue(id: $0.offset, start: $0.element.start, end: $0.element.end, text: $0.element.text) }
    let exp = CueExpectations.build(padded, language: "en")
    let refOff = Correlator.Reference(cues: padded)
    let refOn = Correlator.Reference(cues: padded, expectations: exp)
    let nonSpeech = exp.filter { $0.kind == .nonSpeech }.count
    print("\nS6 text expectations A/B on a padded SRT (\(padded.count) cues, \(nonSpeech) non-speech, syllables of cue 0 = \(exp[0].syllables)):")
    print("scenario                      lock@ off   on   err off    on")
    var regress = 0
    let tuning = SyncTracker.Tuning()
    for s in scenariosV1 where s.events.isEmpty && s.hintAt == nil {
        let r = runReferenceAB(s, cues: padded, refOff: refOff, refOn: refOn, tuning: tuning)
        if let a = r.lockOff, let b = r.lockOn, b > a + 2 { regress += 1 }
        if r.lockOff != nil, r.lockOn == nil { regress += 1 }
        print(s.name.padding(toLength: 30, withPad: " ", startingAt: 0) + pad(memFmt(r.lockOff), 8) + pad(memFmt(r.lockOn), 6) + pad(memFmt(r.errOff, "%+.2f"), 9) + pad(memFmt(r.errOn, "%+.2f"), 7))
    }
    // Wrong-film statistic with both references.
    let w = wrongFilmStats(cues: padded, expectations: exp)
    print(String(format: "wrong film: off onsetZ max %.1f envZ max %.2f | on onsetZ max %.1f envZ max %.2f (V1 ceilings 7.7 / 4.1; thresholds 8.5 / 4.5)", w.offOnsetZ, w.offZ, w.onOnsetZ, w.onZ))
    let newOnsetZ = w.onOnsetZ + 0.8, newZ = w.onZ + 0.4
    print(String(format: "re-derived for the flag: searchOnsetZ %.1f (now %.1f), searchZ %.1f (now %.1f); lock regressions %d → %@",
                 newOnsetZ, tuning.searchOnsetZ, newZ, tuning.searchZ, regress,
                 (regress == 0 && w.onOnsetZ <= 7.7 && w.onZ <= 4.1) ? "flag may ship on" : "flag stays off (default false)"))
}

/// Plays a V1 scenario on `cues` and reports the first accepted full-search window for both
/// references (the tracker's reference is fixed at init, so the "on" variant is evaluated with
/// the same acceptance rule on the same windows).
func runReferenceAB(_ s: Scenario, cues: [Cue], refOff: Correlator.Reference, refOn: Correlator.Reference, tuning: SyncTracker.Tuning) -> (lockOff: Double?, lockOn: Double?, errOff: Double?, errOn: Double?) {
    let vad = VoiceActivityDetector(sampleRate: sampleRate)
    let ring = MicRing(seconds: 120)
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    ring.start(at: t0)
    var wallSamples = 0
    var media = s.startAt
    var lockOff: Double?, lockOn: Double?, errOff: Double?, errOn: Double?
    var next = 2.0
    func accepted(_ m: Correlator.Match) -> Bool {
        m.score >= tuning.searchScore && m.zScore >= tuning.searchZ && m.onsetCount >= tuning.searchMinOnsets && m.onsetZ >= tuning.searchOnsetZ && m.onsetMargin >= tuning.searchOnsetMargin
    }
    while wallSamples < Int(s.seconds * sampleRate), lockOff == nil || lockOn == nil {
        var buf = roomNoise(4800, level: s.noise)
        for i in 0..<4800 {
            let idx = Int(media * sampleRate)
            if idx < film.samples.count { buf[i] += film.samples[idx] }
            media += s.rate / sampleRate
        }
        ring.append(vad.process(buf).map(\.speech))
        wallSamples += 4800
        let wall = Double(wallSamples) / sampleRate
        guard wall >= next else { continue }
        next += 2
        guard let w = ring.latest(seconds: 60), Double(w.bins.count) * 0.01 >= 12 else { continue }
        let fr = SpeechEnvelope.speechFraction(w.bins)
        guard fr >= tuning.minSpeechFraction, fr <= tuning.maxSpeechFraction else { continue }
        let truthAtStart = media - wall * s.rate + Double(wallSamples - w.bins.count * 480) / sampleRate * s.rate
        for (ref, isOn) in [(refOff, false), (refOn, true)] {
            if isOn ? lockOn != nil : lockOff != nil { continue }
            var best: Correlator.Match?
            for rate in tuning.searchRates + (s.rate > 1.1 ? [1.25, 1.5, 1.75, 2.0] : []) {
                let st = SpeechEnvelope.stretched(w.bins, rate: rate)
                guard let m = Correlator.search(mic: st, reference: ref, range: 0..<ref.count) else { continue }
                if best == nil || m.zScore > best!.zScore { best = m }
            }
            if let m = best, accepted(m) {
                if isOn { lockOn = wall; errOn = m.mediaTime - truthAtStart } else { lockOff = wall; errOff = m.mediaTime - truthAtStart }
            }
        }
    }
    return (lockOff, lockOn, errOff, errOn)
}

func wrongFilmStats(cues: [Cue], expectations: [CueExpectation]) -> (offOnsetZ: Float, offZ: Float, onOnsetZ: Float, onZ: Float) {
    var wrong: [Cue] = []
    var t = 5.0
    for (i, c) in cues.shuffled(using: &rng).enumerated() {
        wrong.append(Cue(id: i, start: t, end: t + c.duration, text: c.text))
        t += c.duration + Double.random(in: 0.3...2.5, using: &rng) + (i % 17 == 16 ? Double.random(in: 8...20, using: &rng) : 0)
    }
    let wexp = CueExpectations.build(wrong, language: "en")
    let refOff = Correlator.Reference(cues: wrong), refOn = Correlator.Reference(cues: wrong, expectations: wexp)
    let vad = VoiceActivityDetector(sampleRate: sampleRate)
    let ring = MicRing(seconds: 120)
    ring.start(at: Date(timeIntervalSince1970: 2_000_000))
    var wallSamples = 0, analyses = 0
    var offO: Float = -9, offZ: Float = -9, onO: Float = -9, onZ: Float = -9
    while wallSamples < Int(150 * sampleRate) {
        var buf = roomNoise(4800, level: 0.02)
        for i in 0..<4800 { let idx = Int((100 + Double(wallSamples + i) / sampleRate) * sampleRate); if idx < film.samples.count { buf[i] += film.samples[idx] } }
        ring.append(vad.process(buf).map(\.speech))
        wallSamples += 4800
        if wallSamples % Int(2 * sampleRate) == 0, let w = ring.latest(seconds: 60) {
            analyses += 1
            guard analyses >= 6 else { continue }
            if let m = Correlator.search(mic: w.bins, reference: refOff, range: 0..<Int.max) { offO = max(offO, m.onsetZ); offZ = max(offZ, m.zScore) }
            if let m = Correlator.search(mic: w.bins, reference: refOn, range: 0..<Int.max) { onO = max(onO, m.onsetZ); onZ = max(onZ, m.zScore) }
        }
    }
    _ = expectations
    return (offO, offZ, onO, onZ)
}

// MARK: S7 — cost

func runS7(_ memory: TrackMemory) {
    let extractor = MelExtractor(inputSampleRate: sampleRate)
    var out: [Float] = []
    out.reserveCapacity(6000 * 24)
    let probe = Array(film.samples[0..<Int(60 * sampleRate)])
    let t = Date()
    var i = 0
    while i + 4800 <= probe.count {
        probe.withUnsafeBufferPointer { p in _ = extractor.process(UnsafeBufferPointer(rebasing: p[i..<(i + 4800)]), into: &out) }
        i += 4800
    }
    let melMs = Date().timeIntervalSince(t) * 1000
    // A synthetic 1500-cue track with ~3 s signatures.
    var cues1500: [Cue] = []
    var big = TrackMemory(trackID: UUID(), cueTextHash: Data())
    for k in 0..<1500 {
        let start = Double(k) * 4.8 + 2
        cues1500.append(Cue(id: k, start: start, end: start + 3, text: "line \(k)"))
        let frames = 30 + 150
        var vals = [Float](repeating: 0, count: frames * 24)
        for j in 0..<vals.count { vals[j] = Float.random(in: -1.5...1.5, using: &rng) }
        big.cues[k] = CueSignature(cueID: k, frameCount: frames, frames: CueSignature.quantise(vals), speechLevelDb: 20, captureCount: 1, rateAtCapture: 1, capturedAt: .now, speechSeconds: 2.5)
    }
    let index = SignatureIndex(memory: big, cues: cues1500)
    var heard = [Float](repeating: 0, count: 400 * 24)
    for j in 0..<heard.count { heard[j] = Float.random(in: -1.5...1.5, using: &rng) }
    let ts = Date()
    var steps = 0
    for _ in 0..<5 {
        let coarse = index.coarseSearch(heard: heard, heardCount: 400, top: 20)
        _ = index.fineScore(heard: heard, heardCount: 400, candidates: coarse)
        steps += 1
    }
    let stepMs = Date().timeIntervalSince(ts) * 1000 / Double(steps)
    let tc = Date()
    for id in 0..<20 { _ = index.confirm(heard: heard, heardCount: 400, heardStartMedia: cues1500[id].start - 2, cueID: id, maxShiftFrames: 150) }
    let confirmMs = Date().timeIntervalSince(tc) * 1000 / 20
    let perCue = memory.cues.isEmpty ? 0 : memory.byteCount / memory.cues.count
    let perSec = Double(memory.byteCount) / max(1, memory.cues.values.reduce(0) { $0 + $1.seconds })
    print(String(format: "\nS7 cost (Mac): MelExtractor %.1f ms per 60 s of audio; coarse+fine rewatch step %.0f ms per 1500 cues on an 8 s window (budget 400 ms); confirm ±3 s %.2f ms per cue; %d B per cue, %.0f B per media second (%d cues, %d B); 1500-cue index ≈ %.1f MB",
                 melMs, stepMs, confirmMs, perCue, perSec, memory.cues.count, memory.byteCount, Double(big.byteCount) / 1e6))
}

// MARK: S8 — room change

func runS8(_ memory: TrackMemory) {
    let s = MemScenario(name: "S8", film: film.filtered(tiltFilter(lowShelfDb: 6, gainDb: -12)), startAt: 100, noise: 0.03, seconds: 120, memory: memory, keepFullMel: true)
    let o = runMemory(s)
    let r = rankTest(o, scenario: s, index: o.mt.index)
    let thr = o.mt.thrConfirm
    let above = r.right.filter { $0 >= thr }.count
    print(String(format: "\nS8 room change (+6 dB low shelf, −12 dB): r ≥ thr %.2f on %d/%d cues at the true position (%d%%, want ≥ 80%%); rank-1 %d/%d; right r p10 %.2f; lock@%@ confirm@%@ worst %.2f → %@",
                 thr, above, r.tried, r.tried == 0 ? 0 : above * 100 / r.tried, r.rank1, r.tried, percentile(r.right, 0.10), memFmt(o.lockAfter), memFmt(o.confirmedAfter), o.worst,
                 r.tried > 0 && above * 100 / r.tried >= 80 ? "OK" : "UI copy → 'faster next time in the same room'"))
}

// MARK: S9 — PAL and speed-watch rewatch

func runS9(_ memory: TrackMemory) {
    print("\nS9 rate rewatch (memory stored at 1.0):")
    for (name, rate, speed) in [("PAL 1.0427", 25 / 23.976, false), ("1.5x speed-watch", 1.5, true)] {
        let s = MemScenario(name: name, film: film.filtered(roomB), startAt: 60, rate: rate, noise: 0.03, seconds: 180, memory: memory, speedWatching: speed)
        let o = runMemory(s)
        print(String(format: "  %@: lock@%@ confirm@%@ seeds %d/%d rate %.4f worst %.2f (want ≤ 0.1) confirms %d wrongLocks %d → %@",
                     name, memFmt(o.lockAfter), memFmt(o.confirmedAfter), o.seeds, o.rejectedSeeds, o.finalRate, o.worst, o.confirms, o.wrongConfirmed,
                     (o.confirmedAfter != nil && o.worst <= 0.1 && o.wrongConfirmed == 0) ? "OK" : "CHECK"))
    }
}

// MARK: S10 — capture hygiene

func runS10(_ memory: TrackMemory) {
    let s = MemScenario(name: "S10", film: film.filtered(roomA), startAt: film.cues[16].end - 50, noise: 0.03, seconds: 200,
                        events: [.music(at: 50, seconds: 40)], memory: nil, manualChangeAt: 60)
    let o = runMemory(s)
    // Second passes: quieter (−6 dB) must not replace; louder (+6 dB) must.
    let quiet = learnPass(film, name: "S10 quiet pass", filter: roomFilter(echo: 0.3, delaySeconds: 0.05, lowPass: 0.2, gain: 0.5), print: false)
    let loud = learnPass(film, name: "S10 loud pass", filter: roomFilter(echo: 0.3, delaySeconds: 0.05, lowPass: 0.2, gain: 2), print: false)
    func replay(_ base: TrackMemory, _ pass: MemOutcome, gain: Float) -> (replaced: Int, kept: Int) {
        let f = film.filtered(roomFilter(echo: 0.3, delaySeconds: 0.05, lowPass: 0.2, gain: gain))
        let s2 = MemScenario(name: "replace", film: f, startAt: 0, noise: 0.03, seconds: film.seconds, memory: base)
        let o2 = runMemory(s2)
        return (o2.mt.replacedCount, o2.mt.skippedQuieter)
    }
    let q = replay(memory, quiet.1, gain: 0.5)
    let l = replay(memory, loud.1, gain: 2)
    print(String(format: "\nS10 capture hygiene: captured %d; within 10 s of the trim %d (want 0); while not locked/confirmed %d (want 0); before confirm %d (want 0). Second pass −6 dB: replaced %d, kept %d (want 0 replaced); +6 dB: replaced %d, kept %d (want mostly replaced) → %@",
                 o.captured.count, o.capturedNearManual, o.capturedWhileNotLocked, o.capturedBeforeConfirmed, q.replaced, q.kept, l.replaced, l.kept,
                 (o.capturedNearManual == 0 && o.capturedWhileNotLocked == 0 && o.capturedBeforeConfirmed == 0 && q.replaced == 0 && l.replaced > l.kept) ? "OK" : "CHECK"))
}

// MARK: S0 — regression with the memory path present but empty

func runS0() {
    print("\nS0 regression through MemoryTracker.analyse with no memory file (first watch: capture + confirm run live) beside V1's run() on the same film:")
    print("scenario                         lock@s    err s  confirm@s     rate  worst s  recovery s   | V1 lock@s  worst s  recovery s")
    for v in scenariosV1 {
        let s = MemScenario(name: v.name, film: film, startAt: v.startAt, rate: v.rate, noise: v.noise, seconds: v.seconds, events: v.events, hintAt: v.hintAt)
        let o = runMemory(s)
        let r = run(v)
        print(v.name.padding(toLength: 30, withPad: " ", startingAt: 0) + pad(memFmt(o.lockAfter), 9) + pad(memFmt(o.error, "%+.2f"), 9) + pad(memFmt(o.confirmedAfter), 11)
              + pad(String(format: "%.4f", o.finalRate), 9) + pad(String(format: "%.2f", o.worst), 9)
              + pad(o.recovery.isEmpty ? "" : o.recovery.map { memFmt($0) }.joined(separator: ","), 12)
              + "   |" + pad(memFmt(r.lockAfter), 10) + pad(String(format: "%.2f", r.worst), 9)
              + pad(r.recovery.isEmpty ? "" : r.recovery.map { $0.map { String(format: "%.0f", $0) } ?? "never" }.joined(separator: ","), 12))
    }
}

// MARK: -replayMic

/// Feeds a phone capture (CAF/WAV) through VAD + MelExtractor + tracker (+ memory when
/// `REPLAY_MEMORY=<file>`) against `REPLAY_SRT` (default: the synthetic film's cues) and prints
/// per-window numbers: speech fraction, tracker note, sig r / thr, mel cost.
func replayMic(path: String) {
    guard let audio = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { print("replayMic: cannot read \(path)"); return }
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: audio.processingFormat.sampleRate, channels: 1, interleaved: false)!
    let buf = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length))!
    try! audio.read(into: buf)
    var mono = [Float](repeating: 0, count: Int(buf.frameLength))
    if let ch = buf.floatChannelData { for i in 0..<mono.count { mono[i] = ch[0][i] } }
    let rate = format.sampleRate
    let cues: [Cue]
    if let srt = ProcessInfo.processInfo.environment["REPLAY_SRT"], let data = FileManager.default.contents(atPath: srt) {
        cues = (try? SubtitleParser.parse(data: data, filename: srt)) ?? film.parsed
    } else {
        cues = film.parsed
    }
    var memory: TrackMemory?
    if let mp = ProcessInfo.processInfo.environment["REPLAY_MEMORY"], let data = FileManager.default.contents(atPath: mp) { memory = try? MemoryCodec.decode(data) }
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let tracker = SyncTracker(cues: cues)
    let mt = MemoryTracker(tracker: tracker, cues: cues, memory: memory, trackID: memory?.trackID ?? UUID(), sessionStart: t0)
    let vad = VoiceActivityDetector(sampleRate: rate)
    let ring = MicRing(seconds: 120), mel = MelRing(seconds: 120)
    let extractor = MelExtractor(inputSampleRate: rate)
    ring.start(at: t0); mel.start(at: t0)
    let hop = Int(rate / 10)
    var i = 0, melMs = 0.0, nextTick = 1.0, nextAnalysis = 2.0
    var frames: [Float] = [], levels: [Float] = []
    print("replayMic: \(path) \(String(format: "%.1f", Double(mono.count) / rate)) s at \(Int(rate)) Hz, \(cues.count) cues, memory \(memory.map { "\($0.cues.count) cues" } ?? "none")")
    while i + hop <= mono.count {
        let slice = Array(mono[i..<(i + hop)])
        ring.append(vad.process(slice).map(\.speech))
        frames.removeAll(keepingCapacity: true); levels.removeAll(keepingCapacity: true)
        let t = Date()
        let n = slice.withUnsafeBufferPointer { extractor.process($0, into: &frames, levels: &levels) }
        melMs += Date().timeIntervalSince(t) * 1000
        mel.append(frames, count: n, levels: levels)
        i += hop
        let wall = Double(i) / rate
        let now = t0.addingTimeInterval(wall)
        if wall >= nextTick { nextTick += 1; let c = mt.captureOnTick(now: now, mel: mel, micRing: ring); if !c.isEmpty { print(String(format: "  t=%4.0f captured cues %@", wall, c.map { "\($0.cueID)" }.joined(separator: ","))) } }
        if wall >= nextAnalysis, let w = ring.latest(seconds: mt.suggestedWindowSeconds(at: now) ?? 60) {
            nextAnalysis += 2
            let (r, m) = mt.analyse(mic: w.bins, windowStart: w.start, now: now, mel: mel, micRing: ring)
            print(String(format: "  t=%4.0f speech %.2f %@ state=%@ lock=%@ | %@ %@", wall, r.speechFraction, r.note, "\(r.state)", r.lock.map { String(format: "%.1f", $0.mediaTime(at: now)) } ?? "-", mt.noteReadout, m.note))
        }
    }
    print(String(format: "replayMic: MelExtractor %.1f ms per 60 s; %d signatures stored; thr %.2f; ownScoreP10 %@", melMs / (Double(mono.count) / rate) * 60, mt.signatureCount, mt.thrConfirm, mt.ownScoreP10.map { String(format: "%.2f", $0) } ?? "n/a"))
    if let outPath = ProcessInfo.processInfo.environment["REPLAY_SAVE"] { try? MemoryCodec.encode(mt.memory).write(to: URL(fileURLWithPath: outPath)) }
}
