import Foundation

// The V1 scenarios, the wrong-film check, the full-search cost line and the matcher probes.
// Output is byte-for-byte the V1 harness table (modulo the random room).

let scenariosV1: [Scenario] = {
    let cues = film.cues
    return [
        Scenario(name: "quiet room, start 2:00", startAt: 120, rate: 1, noise: 0.01, seconds: 120),
        Scenario(name: "quiet room, start 5:30", startAt: 330, rate: 1, noise: 0.01, seconds: 90),
        Scenario(name: "noisy room, start 0:45", startAt: 45, rate: 1, noise: 0.08, seconds: 120),
        Scenario(name: "noisy room, start 4:10", startAt: 250, rate: 1, noise: 0.08, seconds: 120),
        Scenario(name: "very noisy, start 1:30", startAt: 90, rate: 1, noise: 0.15, seconds: 120),
        Scenario(name: "PAL speedup 1.0427, 4 min", startAt: 60, rate: 25 / 23.976, noise: 0.03, seconds: 240),
        Scenario(name: "1.5x speed-watch, 3 min", startAt: 30, rate: 1.5, noise: 0.03, seconds: 180),
        Scenario(name: "start in a long gap", startAt: cues[16].end + 2, rate: 1, noise: 0.03, seconds: 120),
        Scenario(name: "with speech hint at 14s", startAt: 200, rate: 1, noise: 0.03, seconds: 90, hintAt: 14),
        Scenario(name: "noisy + hint at 14s", startAt: 300, rate: 1, noise: 0.08, seconds: 90, hintAt: 14),
        Scenario(name: "pause 90s at 60s", startAt: 100, rate: 1, noise: 0.03, seconds: 300, events: [.pause(at: 60, seconds: 90)]),
        Scenario(name: "skip ahead 30s at 70s", startAt: 60, rate: 1, noise: 0.03, seconds: 200, events: [.skip(at: 70, by: 30)]),
        Scenario(name: "skip back 20s at 70s", startAt: 120, rate: 1, noise: 0.03, seconds: 200, events: [.skip(at: 70, by: -20)]),
        Scenario(name: "music over a gap, 40s", startAt: cues[16].end - 20, rate: 1, noise: 0.03, seconds: 160, events: [.music(at: 20, seconds: 40)]),
        Scenario(name: "PAL drift 8 min", startAt: 10, rate: 25 / 23.976, noise: 0.03, seconds: 400),
    ]
}()

func runV1Scenarios() {
    print("scenario".padding(toLength: 30, withPad: " ", startingAt: 0) + "   lock@s    err s  confirm@s     rate  worst s  recovery s")
    for s in scenariosV1 {
        let r = run(s)
        print(s.name.padding(toLength: 30, withPad: " ", startingAt: 0)
              + pad(r.lockAfter.map { String(format: "%.0f", $0) } ?? "never", 9)
              + pad(r.error.map { String(format: "%+.2f", $0) } ?? "-", 9)
              + pad(r.confirmedAfter.map { String(format: "%.0f", $0) } ?? "never", 11)
              + pad(String(format: "%.4f", r.finalRate), 9)
              + pad(String(format: "%.2f", r.worst), 9)
              + (r.recovery.isEmpty ? "" : "  " + r.recovery.map { $0.map { String(format: "%.0f", $0) } ?? "never" }.joined(separator: ",")))
    }
    runWrongFilmCheck()
    runMatcherProbes()
}

/// A false-lock check: a *different* film with the same statistics (same line lengths in a
/// different order, fresh gaps) must never lock while the real film plays.
func runWrongFilmCheck() {
    let parsed = film.parsed
    var wrongCues: [Cue] = []
    var t = 5.0
    for (i, c) in parsed.shuffled(using: &rng).enumerated() {
        wrongCues.append(Cue(id: i, start: t, end: t + c.duration, text: c.text))
        t += c.duration + Double.random(in: 0.3...2.5, using: &rng) + (i % 17 == 16 ? Double.random(in: 8...20, using: &rng) : 0)
    }
    let shuffledCues = wrongCues
    let wrongTracker = SyncTracker(cues: wrongCues)
    let vad = VoiceActivityDetector(sampleRate: sampleRate)
    let ring = MicRing(seconds: 120)
    let t0 = Date(timeIntervalSince1970: 2_000_000)
    ring.start(at: t0)
    var wallSamples = 0, locks = 0, analyses = 0
    var worstZ: Float = 0, worstMargin: Float = -1, worstScore: Float = -1, worstOnset: Float = -1, worstOnsetMargin: Float = -1, worstOnsetZ: Float = -9
    let windowSeconds = Double(ProcessInfo.processInfo.environment["WINDOW"] ?? "60")!
    let wrongRef = Correlator.Reference(cues: shuffledCues)
    while wallSamples < Int(150 * sampleRate) {
        var buf = roomNoise(4800, level: 0.02)
        for i in 0..<4800 { let idx = Int((100 + Double(wallSamples + i) / sampleRate) * sampleRate); if idx < film.samples.count { buf[i] += film.samples[idx] } }
        ring.append(vad.process(buf).map(\.speech))
        wallSamples += 4800
        if wallSamples % Int(2 * sampleRate) == 0, let w = ring.latest(seconds: windowSeconds) {
            analyses += 1
            let r = wrongTracker.analyse(mic: w.bins, windowStart: w.start, now: t0.addingTimeInterval(Double(wallSamples) / sampleRate))
            if r.lock?.confirmed == true { locks += 1 }
            if analyses >= 6, let m = Correlator.search(mic: w.bins, reference: wrongRef, range: 0..<Int.max) {
                worstZ = max(worstZ, m.zScore); worstMargin = max(worstMargin, m.margin); worstScore = max(worstScore, m.score)
                worstOnset = max(worstOnset, m.onsetScore); worstOnsetMargin = max(worstOnsetMargin, m.onsetMargin); worstOnsetZ = max(worstOnsetZ, m.onsetZ)
                if ProcessInfo.processInfo.environment["DEBUG"] != nil, analyses == 40 {
                    let micOnsets = SpeechEnvelope.onsets(in: w.bins)
                    let refStarts = wrongCues.map { SpeechEnvelope.bin(for: $0.start) }
                    var hits = 0
                    var detail: [String] = []
                    for o in micOnsets {
                        let target = m.bin + o
                        let nearest = refStarts.min { abs($0 - target) < abs($1 - target) }!
                        let d = nearest - target
                        if abs(d) <= 25 { hits += 1 }
                        detail.append("\(o):\(d)")
                    }
                    print("  WRONG@40: lag bin \(m.bin) onsetScore \(m.onsetScore) n \(micOnsets.count) hits≤25 \(hits); mic onset→nearest ref start distance: " + detail.joined(separator: " "))
                    // How special is this lag? Count lags whose onset score beats 0.5.
                    let (sig, n) = SpeechEnvelope.onsetSignal(for: w.bins)
                    var above = 0
                    var checked = 0
                    var lag = 0
                    while lag + w.bins.count < wrongRef.count {
                        var sum: Float = 0
                        for o in micOnsets { sum += wrongRef.onsets[lag + o] }
                        if sum / Float(n) > 0.5 { above += 1 }
                        checked += 1
                        lag += 5
                    }
                    _ = sig
                    print("  WRONG@40: \(above) of \(checked) sampled lags score > 0.5")
                }
            }
        }
    }
    print("Wrong-film check: \(locks) confirmed locks in \(analyses) analyses (want 0); best wrong env \(String(format: "%.2f", worstScore)) z \(String(format: "%.2f", worstZ)) m \(String(format: "%.2f", worstMargin)) | onset \(String(format: "%.2f", worstOnset)) m \(String(format: "%.2f", worstOnsetMargin)) oz \(String(format: "%.1f", worstOnsetZ))")
    // Cost of a full search over a two-hour film.
    let longCues = (0..<2400).map { i in Cue(id: i, start: Double(i) * 3 + Double.random(in: 0...1, using: &rng), end: Double(i) * 3 + 2.2, text: "x") }
    let longRef = Correlator.Reference(cues: longCues)
    let probe = Array(longRef.envelope[500_000..<503_000]).map { $0 == 1 ? Float(1) : 0 }
    let started = Date()
    _ = Correlator.search(mic: probe, reference: longRef, range: 0..<longRef.count)
    print(String(format: "Full search over %.0f min of film: %.0f ms per rate (Mac)", Double(longRef.count) / 6000, Date().timeIntervalSince(started) * 1000))
}

/// Transcript matcher: recognised words with typical errors should land on the right cue.
func runMatcherProbes() {
    let matcher = TranscriptMatcher(cues: film.parsed)
    let probes: [(String, Int)] = [
        ("there was a van blue no plates two men", 24),
        ("the lighthouse keeper said the storm comes tonight", 34),
        ("sign here and here and initial the third page", 57),
        ("still in the vault where its been since nineteen fifty two", 95),
    ]
    for (phrase, expected) in probes {
        let hit = matcher.locate(words: phrase.split(separator: " ").map(String.init))
        let ok = hit.map { abs($0.cueIndex - expected) <= 1 } ?? false
        print("Matcher: \"\(phrase.prefix(40))…\" → cue \(hit?.cueIndex ?? -1) (want \(expected)) conf \(String(format: "%.1f", hit?.confidence ?? 0)) \(ok ? "OK" : "MISS")")
    }
}
