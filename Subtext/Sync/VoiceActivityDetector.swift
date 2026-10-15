import Accelerate
import Foundation

/// Marks each 10 ms of microphone audio as speech or not.
///
/// Purely energy based, but with two references that make it hold up in a real room:
/// the noise floor is a rolling 20th percentile of recent frame levels (so it sits at the
/// level of the pauses between lines, not at the quietest instant ever heard), and a frame
/// must also be within `peakDrop` dB of the loudest recent frame (so faint noise just above
/// the floor is not speech). Hangover smoothing keeps syllable gaps from chopping a sentence.
/// Music fools it; that is a known limit.
final class VoiceActivityDetector {
    struct Frame {
        /// 1 = speech, 0 = not.
        let speech: Float
        /// Level in dB above the current noise floor, for a meter.
        let levelAboveFloor: Float
        /// Frame RMS level in dB (10·log10 of the mean square).
        let db: Float
        /// The rolling 20th-percentile noise floor in dB at this frame.
        let floorDb: Float
    }

    let sampleRate: Double
    let hop: Int

    /// dB above the floor before a frame can count as speech.
    var threshold: Float = 8
    /// Frames more than this far below the recent peak are never speech.
    var peakDrop: Float = 22
    var onsetFrames = 2
    var releaseFrames = 12
    /// Seconds of history behind the percentile floor.
    var floorWindowSeconds = 4.0

    private var carry: [Float] = []
    private var history: [Float]
    private var historyIndex = 0
    private var historyFilled = 0
    private var floorDb: Float = -60
    private var peakDb: Float = -100
    private var frameCount = 0
    private var onsetCount = 0
    private var releaseCount = 0
    private var active = false

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        hop = max(1, Int((sampleRate * SpeechEnvelope.binDuration).rounded()))
        history = [Float](repeating: -100, count: Int(floorWindowSeconds / SpeechEnvelope.binDuration))
    }

    func reset() {
        carry = []
        history = [Float](repeating: -100, count: history.count)
        historyIndex = 0
        historyFilled = 0
        floorDb = -60
        peakDb = -100
        frameCount = 0
        onsetCount = 0
        releaseCount = 0
        active = false
    }

    /// Feeds samples and returns one frame per completed 10 ms hop.
    func process(_ samples: UnsafeBufferPointer<Float>) -> [Frame] {
        var frames: [Frame] = []
        var buffer = carry
        buffer.append(contentsOf: samples)
        var offset = 0
        while buffer.count - offset >= hop {
            buffer.withUnsafeBufferPointer { ptr in
                frames.append(analyse(UnsafeBufferPointer(rebasing: ptr[offset..<(offset + hop)])))
            }
            offset += hop
        }
        carry = Array(buffer[offset...])
        return frames
    }

    func process(_ samples: [Float]) -> [Frame] {
        samples.withUnsafeBufferPointer { process($0) }
    }

    private func analyse(_ frame: UnsafeBufferPointer<Float>) -> Frame {
        var meanSquare: Float = 0
        vDSP_measqv(frame.baseAddress!, 1, &meanSquare, vDSP_Length(frame.count))
        let db = 10 * log10(max(meanSquare, 1e-10))

        history[historyIndex] = db
        historyIndex = (historyIndex + 1) % history.count
        historyFilled = min(history.count, historyFilled + 1)
        frameCount += 1
        // Refresh the percentile floor ten times a second; sorting 400 floats is cheap.
        if frameCount % 10 == 0 {
            let recent = historyFilled == history.count ? history : Array(history[0..<historyFilled])
            let sorted = recent.sorted()
            floorDb = sorted[max(0, Int(Double(sorted.count) * 0.2) - 1)]
        }
        // Peak decays 3 dB per second so a loud scene does not mute the quiet one after it.
        peakDb = max(db, peakDb - 0.03)

        let above = db - floorDb
        let loud = above > threshold && db > peakDb - peakDrop

        if loud {
            onsetCount += 1
            releaseCount = 0
            if onsetCount >= onsetFrames { active = true }
        } else {
            onsetCount = 0
            releaseCount += 1
            if releaseCount >= releaseFrames { active = false }
        }
        return Frame(speech: active ? 1 : 0, levelAboveFloor: max(0, above), db: db, floorDb: floorDb)
    }
}
