import AVFoundation
import Foundation
import Observation
import os

private let log = Logger(subsystem: "com.utkarsh.subtext", category: "Sync")

/// Owns the microphone, the voice detector, the transcriber and the tracker, and turns
/// their output into lock events for the session.
///
/// WP0 (docs/v2/critique.md §5): the V2 observables, callbacks, mode, feature-queue hook and
/// the 1 Hz tap-driven tick are declared here with V1 bodies. The 2 s `analysisTimer` keeps
/// running until WP7 moves the analysis onto `onTick`.
@MainActor
@Observable
final class SyncEngine {
    /// Locked-in (scheduler-driven) or V1 continuous analysis every 2 s.
    enum Mode: Equatable, Sendable { case continuous, lockedIn }

    private(set) var phase: SyncPhase = .listening
    private(set) var lock: SyncTracker.Lock?
    private(set) var rate: Double = 1
    /// 0...1 meter of how far the room is above its noise floor.
    private(set) var micLevel: Double = 0
    private(set) var speechFraction: Double = 0
    private(set) var lastScore: Float?
    private(set) var note: String = ""
    private(set) var lastHeard: String = ""
    private(set) var isRunning = false
    private(set) var error: String?

    // MARK: V2 observables (published by WP7; V1 leaves them at their defaults)

    /// What the capture engine is actually doing (A D7: never the policy's intent).
    private(set) var micState: MicState = .listening
    private(set) var mode: Mode = .continuous
    private(set) var schedulerState: SchedulerState = .idle
    private(set) var presenceState: PresenceState = .playing
    private(set) var presenceFeatures: PresenceFeatures?
    private(set) var nextCheckInAt: Date?
    private(set) var lastCheckInAt: Date?
    /// The window a running check-in analyses (drives the draining ring).
    private(set) var checkInWindow: ClosedRange<Date>?
    /// measured − predicted of the last conclusive check-in, seconds.
    private(set) var lastResidual: Double?
    /// Seconds caught up by the last applied correction > 3 s (drives the "Caught up −38 s" toast).
    private(set) var lastCatchUp: Double?
    /// Fraction of speech cues with a stored audio signature for this track.
    private(set) var memoryCoverage: Double = 0
    /// True while the last analysed window was confirmed by audio memory.
    private(set) var memoryConfirmed = false
    /// The last check-in / presence tick found the room quiet (speech fraction below the gate).
    private(set) var roomQuiet = false
    /// 1 Hz ticks since `start` (tap-driven; also counts tap gaps for the watchdog).
    private(set) var tickCount = 0

    // MARK: Callbacks

    var onLock: ((SyncTracker.Lock) -> Void)?
    /// Clock / UI actions from the scheduler, applied by `SessionController` (critique D5).
    var onAction: ((SessionAction) -> Void)?
    /// Presence latch reports, for the status card and the kill clock UI.
    var onPresence: ((PresenceState, PresenceFeatures?) -> Void)?
    /// 1 Hz tick derived from the tap callback (critique D2), delivered on `analysisQueue`.
    /// `date` is the wall time of the tick. WP7 hangs presence, probes, check-ins and capture off it.
    /// Set it before `start` (main actor); it is read off the main actor, hence `nonisolated(unsafe)`.
    @ObservationIgnored nonisolated(unsafe) var onTick: ((Date) -> Void)?
    /// Raw mono samples of every tap buffer, delivered synchronously on the audio thread right
    /// after the VAD. WP1's `SampleRing` memcpy's them; `featureQueue` drains the ring into the
    /// presence analyser (WP3) and the mel extractor (WP4). Do no work here beyond the copy.
    /// Set it before `start` (main actor); it is read on the audio thread.
    @ObservationIgnored nonisolated(unsafe) var onFeatureSamples: ((UnsafeBufferPointer<Float>, Double) -> Void)?

    // MARK: Settings forwards (bodies in WP7)

    var lockedInEnabled = true
    var checkInInterval: CheckInInterval = .adaptive
    var autoPauseEnabled = true
    var autoPausePatience: AutoPausePatience = .normal
    /// 0 = never.
    var autoEndMinutes = 20
    var treatMusicAsContent = true
    var memoryEnabled = true
    var memoryRewatchSearch = true
    var adaptiveCap: Double = 300 {
        didSet { analysisQueue.async { [tracker, adaptiveCap] in tracker?.tuning.adaptiveCapSeconds = adaptiveCap } }
    }
    var useTextExpectations = false

    // MARK: Internals

    private let capture = AudioCapture()
    private let transcriber = LiveTranscriber()
    private let ring = MicRing(seconds: 120)
    private let analysisQueue = DispatchQueue(label: "com.utkarsh.subtext.analysis", qos: .userInitiated)
    /// Serial queue that drains the sample ring into the feature extractors (critique C4).
    let featureQueue = DispatchQueue(label: "com.utkarsh.subtext.features", qos: .userInitiated)
    private var tracker: SyncTracker?
    private var vad: VoiceActivityDetector?
    private var analysisTimer: Timer?
    private var transcriberStartWall: Date?
    private var levelAccumulator: Float = 0
    private var levelFrames = 0
    /// Tick bookkeeping, touched only from the tap callback (same pattern as `vad`).
    private var lastTickWall: Date?
    private var lastBufferWall: Date?

    var windowSeconds: Double = 60
    #if DEBUG
    /// `-recordMic` launch argument: the first 40 s of microphone audio go to Documents/mic.caf.
    private var recorder: AVAudioFile?
    private var recordedFrames: AVAudioFramePosition = 0
    #endif
    var analysisInterval: Double = 2
    var speedWatching = false {
        didSet { analysisQueue.async { [tracker, speedWatching] in tracker?.tuning.searchRates = Self.rates(speedWatching: speedWatching) } }
    }

    private static func rates(speedWatching: Bool) -> [Double] {
        speedWatching ? [1, 25 / 23.976, 23.976 / 25, 1.25, 1.5, 1.75, 2.0] : [1, 25 / 23.976, 23.976 / 25]
    }

    func start(cues: [Cue], language: String = "", audioLocale: Locale, useSpeech: Bool) async {
        stop()
        error = nil
        guard await AudioCapture.requestPermission() else {
            error = "Microphone access is needed to follow what is playing."
            micState = .unavailable("Microphone access is needed to follow what is playing.")
            return
        }
        let tracker = SyncTracker(cues: cues)
        tracker.tuning.searchRates = Self.rates(speedWatching: speedWatching)
        tracker.tuning.adaptiveCapSeconds = adaptiveCap
        tracker.tuning.useTextExpectations = useTextExpectations
        self.tracker = tracker
        phase = .listening
        schedulerState = .acquiring(audioSeconds: 0)
        presenceState = .playing
        presenceFeatures = nil
        lock = nil
        rate = 1
        tickCount = 0
        lastTickWall = nil
        lastBufferWall = nil
        nextCheckInAt = nil
        lastCheckInAt = nil
        checkInWindow = nil
        lastResidual = nil
        lastCatchUp = nil
        memoryCoverage = 0
        memoryConfirmed = false
        roomQuiet = false
        var firstBuffer = true
        capture.onBuffer = { [weak self] buffer in
            guard let self else { return }
            let bufferWall = Date.now
            if firstBuffer {
                firstBuffer = false
                // Buffers arrive ~100 ms after capture; stamp the ring accordingly.
                let wall = bufferWall.addingTimeInterval(-Double(buffer.frameLength) / buffer.format.sampleRate)
                self.ring.start(at: wall)
                self.transcriberStartWall = wall
                self.vad = VoiceActivityDetector(sampleRate: buffer.format.sampleRate)
                self.lastTickWall = bufferWall
            }
            #if DEBUG
            if CommandLine.arguments.contains("-recordMic") {
                if self.recorder == nil, self.recordedFrames == 0 {
                    let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("mic.caf")
                    self.recorder = try? AVAudioFile(forWriting: url, settings: buffer.format.settings)
                }
                if let recorder = self.recorder, self.recordedFrames < AVAudioFramePosition(40 * buffer.format.sampleRate) {
                    try? recorder.write(from: buffer)
                    self.recordedFrames += AVAudioFramePosition(buffer.frameLength)
                } else {
                    self.recorder = nil
                }
            }
            #endif
            guard let vad = self.vad, let channel = buffer.floatChannelData?[0] else { return }
            let samples = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
            let frames = vad.process(samples)
            self.ring.append(frames.map(\.speech))
            self.onFeatureSamples?(samples, buffer.format.sampleRate)
            let level = frames.map(\.levelAboveFloor).max() ?? 0
            Task { @MainActor in self.micLevel = min(1, Double(level) / 25) }
            self.transcriber.push(buffer)
            self.tick(at: bufferWall)
        }
        do {
            try capture.start()
        } catch {
            self.error = error.localizedDescription
            micState = .unavailable(error.localizedDescription)
            return
        }
        isRunning = true
        micState = .listening
        mode = .continuous

        if useSpeech, let inputFormat = capture.inputFormat {
            do {
                try await transcriber.start(locale: audioLocale, inputFormat: inputFormat) { [weak self] phrase in
                    Task { @MainActor in self?.handle(phrase) }
                }
            } catch {
                log.error("Transcriber failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        // V1 cadence. WP7 moves the analysis onto `onTick` and removes this timer.
        analysisTimer = Timer.scheduledTimer(withTimeInterval: analysisInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.analyse() }
        }
    }

    func stop() {
        analysisTimer?.invalidate()
        analysisTimer = nil
        if capture.isRunning { capture.stop() }
        Task { await transcriber.stop() }
        isRunning = false
        tracker = nil
        vad = nil
        phase = .listening
        micLevel = 0
        mode = .continuous
        schedulerState = .idle
        presenceState = .playing
        presenceFeatures = nil
        nextCheckInAt = nil
        lastCheckInAt = nil
        checkInWindow = nil
        roomQuiet = false
    }

    /// `wide`: try the T1/T2 wide pass around the current position before a full search
    /// (critique C7). WP0 body: V1 full search regardless; WP7 wires the wide pass.
    func resync(wide: Bool = false) {
        analysisQueue.async { [tracker] in tracker?.resync() }
        phase = .searching
        lock = nil
        // WP0 runs V1's full search either way, so the V1 note stays; WP7 sets
        // "Listening again nearby" once the wide pass exists.
        note = "Listening again"
    }

    func seed(mediaTime: Double) {
        let now = Date.now
        analysisQueue.async { [tracker] in tracker?.seed(mediaTime: mediaTime, at: now) }
        phase = .locked
    }

    /// The user says the current lines are right (Theater: tap the current line).
    func confirm() {
        analysisQueue.async { [tracker] in tracker?.confirm() }
        if lock != nil { phase = .locked }
    }

    /// Theater long-press: hinted search around `center` while the old lock keeps the clock.
    func relisten(center: Double) {
        let now = Date.now
        analysisQueue.async { [tracker] in tracker?.relisten(center: center, at: now) }
        phase = .searching
        note = "Listening again around here"
    }

    /// A hinted seed after a relaunch (`session.last`): the first search is ±60 s, not full.
    func seedHint(mediaTime: Double) {
        let now = Date.now
        analysisQueue.async { [tracker] in tracker?.hint(mediaTime: mediaTime, at: now) }
    }

    // MARK: Scheduler hooks (bodies in WP7; no-ops keep V1 behaviour)

    /// Island Re-sync / Play while locked-in: run a check-in now. `force` = second tap → full search.
    func requestCheckIn(force: Bool) {}
    /// `.lockedIn` idles the transcriber and the 2 s analysis; `.continuous` is V1.
    func setMode(_ mode: Mode) { self.mode = mode }
    /// Auto-end warning → "Keep listening": reset the quiet clock.
    func extendKill() {}
    /// Status card "Learn this room": capture the room-only profile for a few seconds.
    func learnRoom() {}

    // MARK: Tick

    /// Called on the audio thread for every tap buffer; coalesces to 1 Hz on `analysisQueue`.
    private func tick(at wall: Date) {
        if let last = lastBufferWall, wall.timeIntervalSince(last) > 5 {
            log.warning("Tap gap of \(wall.timeIntervalSince(last), privacy: .public) s")
        }
        lastBufferWall = wall
        guard let last = lastTickWall else { lastTickWall = wall; return }
        guard wall.timeIntervalSince(last) >= 1.0 else { return }
        lastTickWall = wall
        Task { @MainActor in self.tickCount += 1 }
        analysisQueue.async { [weak self] in self?.onTick?(wall) }
    }

    private func handle(_ phrase: LiveTranscriber.Phrase) {
        guard let start = transcriberStartWall else { return }
        let wall = start.addingTimeInterval(phrase.end)
        lastHeard = phrase.words.suffix(8).joined(separator: " ")
        analysisQueue.async { [tracker] in tracker?.addHint(words: phrase.words, heardAt: wall) }
    }

    private func analyse() {
        guard let tracker, let window = ring.latest(seconds: windowSeconds) else { return }
        let now = Date.now
        analysisQueue.async { [weak self] in
            let report = tracker.analyse(mic: window.bins, windowStart: window.start, now: now)
            Task { @MainActor in self?.apply(report) }
        }
    }

    private func apply(_ report: SyncTracker.Report) {
        speechFraction = report.speechFraction
        lastScore = report.lastScore
        note = report.note
        switch report.state {
        case .listening: phase = .listening
        case .searching: phase = .searching
        case .candidate: phase = .searching
        case .locked: phase = .locked
        case .drifting: phase = .drifting
        }
        if let newLock = report.lock, newLock != lock {
            lock = newLock
            rate = newLock.rate
            onLock?(newLock)
        } else if report.lock == nil {
            lock = nil
        }
    }
}
