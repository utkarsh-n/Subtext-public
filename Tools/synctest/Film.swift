import AVFoundation
import Foundation

// Synthesises a film from made-up dialogue with the system voice and builds the matching SRT.
// Declarations only: `film` is a lazily initialised global, built on first access (main.swift
// touches it first so the "Film:" line prints before any table).

let lines = """
Where were you last night?
I told you, I was at the office until late.
The office closes at nine. I called at eleven.
Then I went for a walk. Is that a crime now?
Nobody said anything about a crime.
You didn't have to. It's in your voice.
Sit down. Please. We need to talk about your brother.
What about him?
He came by the house yesterday. He asked for money again.
How much this time?
Enough to make me think he's in real trouble.
He's always in trouble. That's his whole personality.
This felt different. He was scared.
Scared of what?
He wouldn't say. He just kept looking at the door.
Did you give it to him?
Half. I told him the rest comes when he tells me the truth.
That's the first smart thing anyone in this family has done in a year.
The ferry leaves at six. If we're going, we go now.
We're not going anywhere until I hear from Marcus.
Marcus isn't calling. Marcus is gone.
You don't know that.
I know what I saw at the harbour.
Tell me again. Slowly. Everything.
There was a van. Blue, no plates. Two men. One of them had the ledger.
The ledger from the safe?
The same one. Red cover, the corner burnt.
Then they already know about the account.
They know about all of it.
Pass the salt.
Is that really what you want to talk about right now?
I want to eat a meal in this house without a catastrophe. Once.
Fine. The salt.
Thank you.
The lighthouse keeper said the storm comes in tonight.
He says that every week.
This week he's right. Look at the sky.
Then the boats stay in and so do we.
Doctor, how long does she have?
I don't deal in guesses, Mr Hale.
Then deal in facts. How long?
Weeks. Perhaps a month if she rests.
She has never rested a day in her life.
Then teach her. You have the time, if nothing else.
Did you lock the back door?
I always lock the back door.
It was open this morning.
Then someone opened it.
That's what worries me.
The train to Lisbon runs twice a day. We take the morning one.
And if they're watching the station?
Then we take the afternoon one, from the next town.
You've thought about this.
I've thought about nothing else for six years.
Happy birthday, old man.
I'm forty-one. That's hardly old.
It is from where I'm standing.
Sign here, and here, and initial the third page.
What am I agreeing to?
That you were never in the building.
But I was in the building.
Not according to page three.
Mother, the car is here.
Let it wait. The car has waited before.
He says the roads will flood.
Then he can drive faster.
Do you remember the summer at the lake?
Every day of it.
You pushed me off the dock.
You deserved it. You'd read my letters.
I was nine.
You were a spy at nine.
We have forty seconds before the guard comes back.
That's thirty more than I need.
The key, Daniel. Where is the key?
In the clock. Behind the face.
I checked the clock.
Not that clock.
This is the part where you tell me it was all a misunderstanding.
There's no misunderstanding. I took the money.
Why?
Because nobody else was going to.
Can you hear that?
Hear what?
Exactly. The generator stopped.
Open the window, it's stifling in here.
If I open the window the papers go everywhere.
Then weigh them down with something heavy, like your conscience.
That's low, even for you.
I learned from the best.
The painting is a forgery.
It can't be. It was authenticated twice.
By the same man, both times, and he's on their payroll.
So the real one is—
Still in the vault, where it's been since nineteen fifty-two.
Get down!
What was that?
Stay low. Don't move until I say.
It's quiet now.
That's when they come.
"""

let voice = "Samantha"
let outDir = URL(fileURLWithPath: "Tools/synctest/out", isDirectory: true)
let sampleRate = 48_000.0
var rng = SystemRandomNumberGenerator()

/// Renders one line with `say` (cached under Tools/synctest/out) and returns its samples.
func synth(_ text: String, index: Int, voice: String = voice) -> [Float] {
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let file = outDir.appendingPathComponent(voice == "Samantha" ? "cue\(index).caf" : "cue\(index)-\(voice).caf")
    if !FileManager.default.fileExists(atPath: file.path) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-v", voice, "-o", file.path, "--data-format=LEF32@48000", text]
        try! p.run(); p.waitUntilExit()
    }
    let audio = try! AVAudioFile(forReading: file)
    let buf = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length))!
    try! audio.read(into: buf)
    return Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
}

func srtTime(_ t: Double) -> String {
    let ms = Int((t * 1000).rounded())
    return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
}

/// The synthetic film: audio, the cues it was built from, and the cues read back from its SRT.
struct Film {
    let texts: [String]
    /// Mono 48 kHz samples of the whole film (dialogue at 0.5 gain, 10 s of silence at the end).
    let samples: [Float]
    let cues: [Cue]
    /// `cues` after a round trip through `SubtitleParser` (what the app would see).
    let parsed: [Cue]

    var seconds: Double { Double(samples.count) / sampleRate }

    /// A copy whose film path went through `filter` (e.g. a TV speaker EQ, the "tvEq" hook of
    /// docs/v2/latch.md §10). Room noise is added by the runner afterwards and stays unfiltered.
    func filtered(_ filter: ([Float]) -> [Float]) -> Film {
        Film(texts: texts, samples: filter(samples), cues: cues, parsed: parsed)
    }

    /// Lines placed with natural gaps, SRT timings taken from the audio. Also writes film.caf
    /// and film.srt so the film can be played at a phone or simulator microphone.
    static func build() -> Film {
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        var film: [Float] = []
        var cues: [Cue] = []
        var cursor = 3.0
        let texts = lines.split(separator: "\n").map(String.init)
        for (i, text) in texts.enumerated() {
            let samples = synth(text, index: i)
            let start = cursor
            let duration = Double(samples.count) / sampleRate
            cues.append(Cue(id: i, start: (start * 1000).rounded() / 1000, end: ((start + duration + 0.25) * 1000).rounded() / 1000, text: text))
            let startSample = Int(start * sampleRate)
            if film.count < startSample + samples.count { film.append(contentsOf: [Float](repeating: 0, count: startSample + samples.count - film.count)) }
            for (j, s) in samples.enumerated() { film[startSample + j] += s * 0.5 }
            // Scene gaps: mostly short, sometimes a long quiet stretch (a "montage").
            let gap = Double.random(in: 0.3...2.5, using: &rng) + (i % 17 == 16 ? Double.random(in: 8...20, using: &rng) : 0)
            cursor = start + duration + gap
        }
        film.append(contentsOf: [Float](repeating: 0, count: Int(10 * sampleRate)))
        let filmSeconds = Double(film.count) / sampleRate
        do {
            let url = outDir.appendingPathComponent("film.caf")
            if !FileManager.default.fileExists(atPath: url.path) {
                let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
                let out = try AVAudioFile(forWriting: url, settings: format.settings)
                let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(film.count))!
                buf.frameLength = AVAudioFrameCount(film.count)
                film.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: film.count) }
                try out.write(from: buf)
            }
        } catch {
            print("film.caf not written: \(error)")
        }
        let srt = cues.map { "\($0.id + 1)\n\(srtTime($0.start)) --> \(srtTime($0.end))\n\($0.text)\n" }.joined(separator: "\n")
        try! srt.write(to: outDir.appendingPathComponent("film.srt"), atomically: true, encoding: .utf8)

        // Round-trip the parser on the SRT we just wrote.
        let parsed = SubtitleParser.parse(text: srt, filename: "film.srt")
        precondition(parsed.count == cues.count, "parser lost cues: \(parsed.count) vs \(cues.count)")
        precondition(abs(parsed[5].start - cues[5].start) < 0.002, "parser timing mismatch")
        print("Film: \(texts.count) lines, \(String(format: "%.0f", filmSeconds))s. Parser round-trip OK.")
        return Film(texts: texts, samples: film, cues: cues, parsed: parsed)
    }
}

/// The film every scenario plays, built once.
let film = Film.build()
