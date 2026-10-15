import Foundation

// The room: noise floor, music, a second voice, a fan, and the things a viewer does.
// Declarations only (no top-level statements).

/// Brown + white noise at `level`: the room's floor.
func roomNoise(_ n: Int, level: Float) -> [Float] {
    var out = [Float](repeating: 0, count: n)
    var brown: Float = 0
    for i in 0..<n {
        let white = Float.random(in: -1...1, using: &rng)
        brown = (brown + 0.02 * white) / 1.02
        out[i] = (white * 0.3 + brown * 3) * level
    }
    return out
}

/// A steadier, browner noise than the floor: an HVAC fan or a fridge (depth < 2 dB).
func fanNoise(_ n: Int, level: Float) -> [Float] {
    var out = [Float](repeating: 0, count: n)
    var brown: Float = 0
    for i in 0..<n {
        let white = Float.random(in: -1...1, using: &rng)
        brown = (brown + 0.01 * white) / 1.01
        out[i] = (white * 0.1 + brown * 6) * level
    }
    return out
}

/// Simple synthetic music: a slow arpeggio with a steady pulse, band-limited like a TV speaker.
/// `bpm` sets the pulse (120 = the V1 2 Hz beat).
func musicSample(_ t: Double, bpm: Double = 120) -> Float {
    let chord: [Double] = [220, 277.18, 329.63, 440]
    let note = chord[Int(t * 4) % chord.count]
    let beat = 0.5 + 0.5 * cos(2 * Double.pi * (bpm / 60) * t)
    let tone = sin(2 * Double.pi * note * t) + 0.5 * sin(2 * Double.pi * note * 2 * t) + 0.25 * sin(2 * Double.pi * note * 3 * t)
    return Float(tone * beat * 0.12)
}

/// Unrelated speech in the room: film dialogue from a far-away position, so it is real speech
/// that never correlates with the truth position. WP3 may swap in a second `say` voice reading
/// lines that are not in the track (`synth(_:index:voice:)` supports that).
func chatterSample(_ t: Double) -> Float {
    let n = film.samples.count
    guard n > 0 else { return 0 }
    let idx = (Int((t * 1.07 + 173.0) * sampleRate) % n + n) % n
    return film.samples[idx] * 0.8
}

/// Things that happen in the room while the tracker listens. Wall seconds from scenario start.
enum RoomEvent {
    /// The viewer pauses the film at this wall second for this long; the TV goes silent.
    case pause(at: Double, seconds: Double)
    /// The viewer skips forward (or back, negative) by this many media seconds.
    case skip(at: Double, by: Double)
    /// The TV plays music with no dialogue for this long (over whatever the film is doing).
    case music(at: Double, seconds: Double, bpm: Double? = nil)
    /// The film plays on but its audio is silent (a silent scene): truth advances, mic hears the room.
    case silence(at: Double, seconds: Double)
    /// The viewer mutes the TV: same as `.silence`, named for the viewer's intent.
    case muted(at: Double, seconds: Double)
    /// People talk in the room over whatever the film is doing.
    case chatter(at: Double, seconds: Double)
    /// A fan switches on at `at` and stays on.
    case fan(at: Double, level: Float)
    /// The user nudges the trim by `seconds` at `at`.
    case nudge(at: Double, seconds: Double)
    /// The wall clock steps by `seconds` at `at`; the monotonic feed continues unchanged.
    case wallStep(at: Double, seconds: Double)

    var start: Double {
        switch self {
        case .pause(let at, _), .skip(let at, _), .music(let at, _, _), .silence(let at, _), .muted(let at, _),
             .chatter(let at, _), .fan(let at, _), .nudge(let at, _), .wallStep(let at, _):
            return at
        }
    }

    var end: Double {
        switch self {
        case .pause(let at, let s), .music(let at, let s, _), .silence(let at, let s), .muted(let at, let s), .chatter(let at, let s):
            return at + s
        case .skip(let at, _), .fan(let at, _), .nudge(let at, _), .wallStep(let at, _):
            return at
        }
    }

    func contains(_ wall: Double) -> Bool { wall >= start && wall < end }
}

func eventStart(_ e: RoomEvent) -> Double { e.start }
func eventEnd(_ e: RoomEvent) -> Double { e.end }

/// A V1 scenario: the room plays the film from `startAt` at `rate` with `noise` for `seconds`.
struct Scenario {
    let name: String
    let startAt: Double
    let rate: Double
    let noise: Float
    let seconds: Double
    /// Feed the words of the cue playing at this wall second as a transcript hint.
    var hintAt: Double? = nil
    var events: [RoomEvent] = []
}

/// Ordered segments for presence scenarios (docs/v2/latch.md §10). `events(startAt:)` turns a
/// timeline into `RoomEvent`s for the runner; `.talk` and `.loudRoom` map onto chatter / noise.
struct Timeline {
    enum Kind: Equatable {
        case play
        case pause
        case muted
        case music(bpm: Double)
        case talk(lines: Int)
        case fan(level: Float)
        case loudRoom(level: Float)
        case off
    }
    struct Segment: Equatable {
        let kind: Kind
        let seconds: Double
    }
    var segments: [Segment]

    var seconds: Double { segments.reduce(0) { $0 + $1.seconds } }

    func events() -> [RoomEvent] {
        var out: [RoomEvent] = []
        var t = 0.0
        for seg in segments {
            switch seg.kind {
            case .play: break
            case .pause: out.append(.pause(at: t, seconds: seg.seconds))
            case .muted: out.append(.muted(at: t, seconds: seg.seconds))
            case .music(let bpm): out.append(.music(at: t, seconds: seg.seconds, bpm: bpm))
            case .talk: out.append(.chatter(at: t, seconds: seg.seconds))
            case .fan(let level): out.append(.fan(at: t, level: level))
            case .loudRoom(let level): out.append(.fan(at: t, level: level * 3))
            case .off: out.append(.pause(at: t, seconds: 1e9))
            }
            t += seg.seconds
        }
        return out
    }
}
