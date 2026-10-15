import AVFoundation
import Foundation
import Speech
import os

private let log = Logger(subsystem: "com.utkarsh.subtext", category: "Speech")

/// Streams microphone audio through the on-device speech model and reports finished phrases
/// with the analyser-timeline second they ended at. Used only to narrow the search; the
/// words never leave the phone and are never stored.
final class LiveTranscriber {
    struct Phrase: Sendable {
        let words: [String]
        /// Seconds since the first buffer fed to the analyser at which the phrase *started*
        /// (min of the runs' `audioTimeRange.start`): when the words were spoken, which is what
        /// the `EvidenceLedger` stamps (signature.md §3.5). Equals `end` when no run carried a range.
        let start: Double
        /// Seconds since the first buffer fed to the analyser.
        let end: Double
    }

    static var isAvailable: Bool { SpeechTranscriber.isAvailable }

    static func supportedLocales() async -> [Locale] {
        guard SpeechTranscriber.isAvailable else { return [] }
        return await Array(SpeechTranscriber.supportedLocales).sorted { $0.identifier < $1.identifier }
    }

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var framesFed: AVAudioFramePosition = 0
    private(set) var isRunning = false

    func start(locale: Locale, inputFormat: AVAudioFormat, onPhrase: @escaping @Sendable (Phrase) -> Void) async throws {
        guard SpeechTranscriber.isAvailable else { return }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            log.warning("No speech model for \(locale.identifier, privacy: .public)")
            return
        }
        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            log.info("Installing speech model for \(supported.identifier, privacy: .public)")
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { return }
        converter = AVAudioConverter(from: inputFormat, to: format)
        targetFormat = format
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation
        self.analyzer = analyzer
        self.transcriber = transcriber
        framesFed = 0

        resultsTask = Task {
            do {
                for try await result in transcriber.results where result.isFinal {
                    let text = result.text
                    var words: [String] = []
                    var end = 0.0
                    var start = Double.infinity
                    for run in text.runs {
                        let piece = String(text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !piece.isEmpty else { continue }
                        words.append(piece)
                        if let range = run.audioTimeRange {
                            end = max(end, range.end.seconds)
                            start = min(start, range.start.seconds)
                        }
                    }
                    if end == 0 { end = result.range.end.seconds }
                    if !start.isFinite { start = result.range.start.seconds.isFinite ? result.range.start.seconds : end }
                    guard !words.isEmpty else { continue }
                    onPhrase(Phrase(words: words, start: min(start, end), end: end))
                }
            } catch {
                log.error("Transcriber ended: \(error.localizedDescription, privacy: .public)")
            }
        }
        try await analyzer.start(inputSequence: stream)
        isRunning = true
        log.info("Transcriber running in \(supported.identifier, privacy: .public)")
    }

    /// Called from the audio thread.
    func push(_ buffer: AVAudioPCMBuffer) {
        guard isRunning, let converter, let targetFormat, let continuation else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if consumed { outStatus.pointee = .noDataNow; return nil }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0 else { return }
        framesFed += AVAudioFramePosition(out.frameLength)
        continuation.yield(AnalyzerInput(buffer: out))
    }

    func stop() async {
        guard isRunning else { return }
        isRunning = false
        continuation?.finish()
        continuation = nil
        resultsTask?.cancel()
        resultsTask = nil
        if let analyzer { await analyzer.cancelAndFinishNow() }
        analyzer = nil
        transcriber = nil
        converter = nil
    }
}
