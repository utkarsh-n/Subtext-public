import AVFoundation
import Foundation
// Feeds a real microphone recording through the detector and the tracker against film.srt.
let file = try! AVAudioFile(forReading: URL(fileURLWithPath: CommandLine.arguments[1]))
let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
try! file.read(into: buf)
let samples = Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
let sr = file.processingFormat.sampleRate
print(String(format: "%.1fs at %.0f Hz, peak %.3f", Double(samples.count) / sr, sr, samples.map(abs).max()!))
let vad = VoiceActivityDetector(sampleRate: sr)
let frames = vad.process(samples)
var line = ""
for s in 0..<(frames.count / 100) {
    let a = frames[(s * 100)..<((s + 1) * 100)]
    line += String(format: "%2d:%3.0f%% ", s, Double(a.filter { $0.speech == 1 }.count))
    if s % 8 == 7 { print(line); line = "" }
}
print(line)
let bins = frames.map(\.speech)
print(String(format: "overall speech fraction %.2f, onsets %d", SpeechEnvelope.speechFraction(bins), SpeechEnvelope.onsets(in: bins).count))

let srt = try! String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)
let cues = SubtitleParser.parse(text: srt, filename: "film.srt")
let ref = Correlator.Reference(cues: cues)
for seconds in [20, 30, 40] where bins.count >= seconds * 100 {
    let window = Array(bins.suffix(seconds * 100))
    if let m = Correlator.search(mic: window, reference: ref, range: 0..<ref.count) {
        print(String(format: "last %ds → media %.1fs | env %.2f z %.1f m %.2f | onset %.2f m %.2f n %d oz %.1f", seconds, m.mediaTime, m.score, m.zScore, m.margin, m.onsetScore, m.onsetMargin, m.onsetCount, m.onsetZ))
    }
}
// And the tracker as the app runs it: every 2 s on what has been heard so far (up to 60 s).
let tracker = SyncTracker(cues: cues)
let t0 = Date(timeIntervalSince1970: 0)
var t = 2
while t * 100 <= bins.count {
    let window = Array(bins.prefix(t * 100).suffix(6000))
    let start = t0.addingTimeInterval(Double(t) - Double(window.count) / 100)
    let r = tracker.analyse(mic: window, windowStart: start, now: t0.addingTimeInterval(Double(t)))
    if t % 4 == 0 || r.lock != nil {
        print(String(format: "tracker t=%2d %@ %@%@", t, "\(r.state)", r.note, r.lock.map { String(format: " → media %.1f at now", $0.mediaTime(at: t0.addingTimeInterval(Double(t)))) } ?? ""))
    }
    t += 2
}

// Ground truth: playback started near media 150 s a few seconds before the recording.
if let m = Correlator.search(mic: bins, reference: ref, range: SpeechEnvelope.bin(for: 140)..<SpeechEnvelope.bin(for: 200)) {
    print(String(format: "neighbourhood 140–200 → media %.1fs | env %.2f m %.2f | onset %.2f m %.2f n %d oz %.1f", m.mediaTime, m.score, m.margin, m.onsetScore, m.onsetMargin, m.onsetCount, m.onsetZ))
    let offset = m.bin
    print("sec  mic%  ref%   (ref aligned at the neighbourhood match)")
    for s in 0..<(bins.count / 100) {
        let micPct = bins[(s * 100)..<((s + 1) * 100)].filter { $0 == 1 }.count
        let r = ref.envelope[(offset + s * 100)..<(offset + (s + 1) * 100)].filter { $0 == 1 }.count
        let bar = String(repeating: "#", count: micPct / 10) + String(repeating: " ", count: 10 - micPct / 10)
        let rbar = String(repeating: "=", count: r / 10)
        print(String(format: "%3d  %3d%%  %3d%%  |%@| |%@", s, micPct, r, bar, rbar))
    }
}
