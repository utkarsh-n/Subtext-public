import AVFoundation
import Foundation
import os
#if canImport(UIKit)
import UIKit
#endif

private let log = Logger(subsystem: "com.utkarsh.subtext", category: "Audio")

enum AudioCaptureError: LocalizedError {
    /// The input node reports no sample rate / channels: no microphone is available.
    case inputUnavailable
    /// The tap stopped delivering buffers and two rebuilds did not bring it back.
    case deadTap
    /// `AVAudioSession` / `AVAudioEngine` refused (category, activation, start).
    case session(Error)

    var errorDescription: String? {
        switch self {
        case .inputUnavailable: "No microphone input is available."
        case .deadTap: "The microphone stopped delivering audio."
        case .session(let error): error.localizedDescription
        }
    }
}

/// Keeps the microphone open for the whole session, including in the background, and hands
/// every tap buffer to the engine (docs/v2/keepalive.md §4.1–4.2, §4.7; critique D1/D7, WP1).
///
/// The session is configured and activated once in `start()` (foreground) and deactivated only
/// in `stop()`: iOS does not let an app *begin* recording in the background (critique F1), so
/// the lineage "started in the foreground" is never surrendered. There is no release/reacquire
/// and no silent keep-alive (critique D1). Between check-ins the brain idles, not the hardware;
/// `setActivity(.idle)` is bookkeeping for the status copy and nothing else.
///
/// `micState` is set from what the engine is actually doing (buffers flowing, interrupted,
/// dead), never from the policy's intent (A D7): the copy cannot contradict the orange dot.
///
/// Threading: `start`, `stop`, `setActivity`, `recover` and every callback except the two
/// buffer callbacks run on the main thread. `onBuffer` / `onTimedBuffer` run on the audio
/// thread; do nothing there beyond the VAD and a memcpy into `SampleRing`.
final class AudioCapture {
    /// What the brain is doing with the open mic; maps onto the three running `MicState`s.
    enum Activity: Equatable {
        case listening   // continuous search / track (V1, acquiring)
        case idle        // locked-in between check-ins
        case checking    // a check-in / probe in progress
    }

    /// Why buffers stopped and whether they are back; `seconds` is the length of the gap so the
    /// scheduler can run a check-in with `behind = seconds + 5` (critique §4.2 `micLost`).
    enum InterruptionEvent: Equatable {
        case began
        case ended(seconds: Double, recovered: Bool)
    }

    // MARK: Constants

    /// Tap buffer length; the IO buffer request matches (≈ 10 wake-ups/s).
    static let bufferDuration: Double = 0.1
    /// No buffer for this long after a (re)start → `rebuildTap()`, then a full engine rebuild.
    static let bufferWatchdogSeconds: TimeInterval = 1.5
    /// No buffer for this long → `micState = .interrupted`, `onTapGap` (critique D2; equals
    /// `Tuning.tapGapSeconds`, which this layer cannot see).
    static let tapGapSeconds: TimeInterval = 5
    /// No buffer for this long after both rebuilds → `.unavailable` (A §4.7 `.deadTap`).
    static let deadTapSeconds: TimeInterval = 10
    static let preferredSampleRate: Double = 16_000
    /// Foreground retry delay after a failed interruption resume (`interruptionFailed`).
    static let foregroundRetrySeconds: TimeInterval = 3
    #if DEBUG
    /// `-recordMic [seconds]`: raw microphone audio to Documents/mic.caf (default 180 s).
    static let defaultRecordSeconds: Double = 180
    /// The requested length, parsed once: the tap must not allocate per buffer (critique C4).
    private static let recordSeconds: Double? = {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "-recordMic") else { return nil }
        return args.indices.contains(index + 1) ? Double(args[index + 1]) ?? AudioCapture.defaultRecordSeconds : AudioCapture.defaultRecordSeconds
    }()
    #endif

    // MARK: Callbacks

    /// V1 path: every tap buffer, on the audio thread. `SyncEngine` drives the VAD, the ring,
    /// the transcriber and the 1 Hz tick from here. TODO(WP7): move to `onTimedBuffer`.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// V2 path: the same buffer with the tap's `AVAudioTime` (host time + sample time), on the
    /// audio thread. Lets the engine stamp the rings from the audio clock rather than `Date.now`.
    var onTimedBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?
    /// `micState` changed (main thread). TODO(WP7): `SyncEngine.micState = $0`; `.interrupted` /
    /// `.unavailable` → scheduler `micLost`.
    var onStateChange: ((MicState) -> Void)?
    /// A system interruption or a dead tap began / ended (main thread). On `.ended(recovered:
    /// true)` the scheduler runs a check-in with `behind = seconds + 5`.
    var onInterruption: ((InterruptionEvent) -> Void)?
    /// The tap has delivered nothing for more than `tapGapSeconds` (main thread). Also reflected
    /// as `micState == .interrupted` and an `onInterruption(.began)` if none was in flight.
    var onTapGap: ((TimeInterval) -> Void)?
    /// A rebuild changed the input format (sample rate / channels). The engine rebuilds its VAD
    /// and restarts the transcriber only when the rate changed (main thread).
    var onFormatChange: ((AVAudioFormat) -> Void)?
    /// `AVAudioApplication` input mute changed (Control Center, or the DEBUG experiment). A muted
    /// mic must never read as a film pause (A §4.7; WP3 presence consumes it). Main thread.
    var onInputMuteChange: ((Bool) -> Void)?
    /// The delayed "your app was suspended" interruption (legacy key, iOS ≤ 15 era; kept for
    /// completeness). Treat as a relaunch → hinted re-acquire (A §6). Main thread.
    var onWasSuspended: (() -> Void)?

    // MARK: State

    /// Meaningful while `isRunning`; after `stop()` it keeps its last value.
    private(set) var micState: MicState = .unavailable("Microphone is not open.")
    /// `start()` succeeded and `stop()` has not been called: the session is active.
    private(set) var isRunning = false
    /// Format of the buffers handed to the callbacks, valid once started; updated on rebuilds.
    private(set) var inputFormat: AVAudioFormat?
    /// Read-backs after activation (A U6: the requests are best effort; log and expose them).
    private(set) var sessionSampleRate: Double = 0
    private(set) var ioBufferDuration: Double = 0
    private(set) var isInputMuted = false
    /// Tap / engine rebuilds since `start()` (debug row).
    private(set) var rebuildCount = 0
    /// Host time and sample time of the most recent tap buffer, for consumers that want the
    /// audio clock without being on the tap.
    var lastBufferTime: AVAudioTime? { bufferClock.withLock { $0.time } }
    /// Wall time of the most recent tap buffer.
    var lastBufferAt: Date { bufferClock.withLock { $0.wall } }
    /// The honest definition of "the mic is open": engine running, tap installed, buffers
    /// arriving within the watchdog interval.
    var isInputRunning: Bool {
        engine.isRunning && tapInstalled && Date.now.timeIntervalSince(lastBufferAt) < Self.bufferWatchdogSeconds
    }

    private var engine = AVAudioEngine()
    private var tapInstalled = false
    private var activity: Activity = .listening
    private var observers: [NSObjectProtocol] = []
    private var watchdog: DispatchSourceTimer?
    /// Wall time of the last recovery action (start, rebuild) or of the last buffer seen by the
    /// watchdog; the ladder measures from here.
    private var armedAt = Date.distantPast
    private var startedAt = Date.distantPast
    /// 0 none · 1 tap rebuilt · 2 engine rebuilt · 3 given up (`.deadTap`).
    private var recoveryAttempts = 0
    private var tapGapSignalled = false
    private var lastGoodBufferAt: Date?
    private var interruptedAt: Date?
    /// Set when a recovery failed in the background; `recover()` retries on `didBecomeActive`.
    private var needsRecovery = false
    private let bufferClock = OSAllocatedUnfairLock<(wall: Date, time: AVAudioTime?)>(initialState: (.distantPast, nil))
    #if DEBUG
    private let inputMuteExperiment = CommandLine.arguments.contains("-inputMuteExperiment")
    private var mutedAt: Date?
    private var muteExperimentReported = false
    /// Guards the three recorder fields: written on the audio thread in `record`, closed on the
    /// main thread in `stop()`.
    private let recorderLock = OSAllocatedUnfairLock()
    private var recorder: AVAudioFile?
    private var recordedFrames: AVAudioFramePosition = 0
    private var recordingDone = false
    #endif

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    // MARK: Session start / stop

    /// Session start (foreground only; A §4.2). Configures and activates the shared session,
    /// installs the tap, starts the engine, arms the watchdog and installs the observers.
    func start() throws {
        if isRunning { stop() }
        let session = AVAudioSession.sharedInstance()
        try configureSession(session)
        isRunning = true
        startedAt = .now
        activity = .listening
        recoveryAttempts = 0
        tapGapSignalled = false
        lastGoodBufferAt = nil
        interruptedAt = nil
        needsRecovery = false
        rebuildCount = 0
        bufferClock.withLock { $0 = (.distantPast, nil) }
        isInputMuted = AVAudioApplication.shared.isInputMuted
        #if DEBUG
        // No tap exists yet, so this is the one place the recorder state can be reset without
        // the recorder lock.
        recorderLock.withLock { recorder = nil; recordedFrames = 0; recordingDone = false }
        #endif
        do {
            try startEngine()
        } catch {
            isRunning = false
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            publish(.unavailable(error.localizedDescription))
            throw error
        }
        installObservers()
        publish(state(for: activity))
    }

    /// End: removes the tap, stops the engine, drops the observers and performs the session's
    /// only `setActive(false)`.
    func stop() {
        watchdog?.cancel()
        watchdog = nil
        tearDownEngine()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        isRunning = false
        interruptedAt = nil
        needsRecovery = false
        #if DEBUG
        // Close the file under the lock: removeTap does not wait for an in-flight tap block.
        recorderLock.withLock { recorder = nil; recordingDone = true }
        #endif
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        log.info("Capture stopped (\(self.rebuildCount, privacy: .public) rebuilds this session)")
    }

    /// Bookkeeping only: the three running `MicState`s. Does not touch the session or the
    /// engine (critique D1: the mic hardware stays open between check-ins).
    func setActivity(_ activity: Activity) {
        self.activity = activity
        #if DEBUG
        if inputMuteExperiment, isRunning {
            // Ship step 4 experiment (i): does the background recording grant survive
            // `setInputMuted(true)` between check-ins, and do buffers keep coming?
            try? setInputMuted(activity == .idle)
        }
        #endif
        guard isRunning, interruptedAt == nil, !tapGapSignalled, recoveryAttempts < 3 else { return }
        publish(state(for: activity))
    }

    /// Retry after a failed background recovery (`didBecomeActive`; A §4.5 / §4.7). Also
    /// called automatically from the `UIApplication.didBecomeActiveNotification` observer.
    func recover() {
        guard isRunning, needsRecovery || recoveryAttempts >= 3 || micState.isUnavailable else { return }
        log.info("Recovering capture in the foreground")
        let gap = Date.now.timeIntervalSince(lastGoodBufferAt ?? lastBufferAt)
        do {
            try configureSession(AVAudioSession.sharedInstance())
            try rebuildEngine()
            needsRecovery = false
            recoveryAttempts = 0
            tapGapSignalled = false
            lastGoodBufferAt = nil
            publish(state(for: activity))
            onInterruption?(.ended(seconds: gap, recovered: true))
        } catch {
            log.error("Recovery failed: \(error.localizedDescription, privacy: .public)")
            publish(.unavailable("Mic couldn't reopen. " + error.localizedDescription))
        }
    }

    /// `AVAudioApplication` mute: input is silenced while IO continues (WWDC23 10233). Only
    /// the DEBUG experiment calls this; Control Center mute arrives through the notification.
    func setInputMuted(_ muted: Bool) throws {
        try AVAudioApplication.shared.setInputMuted(muted)
        #if DEBUG
        mutedAt = muted ? .now : nil
        muteExperimentReported = false
        #endif
        log.info("setInputMuted(\(muted, privacy: .public)) → isInputMuted \(AVAudioApplication.shared.isInputMuted, privacy: .public)")
    }

    // MARK: Session

    private func configureSession(_ session: AVAudioSession) throws {
        do {
            // V1's options, kept on purpose (critique R11): .measurement for un-AGC'd levels,
            // .mixWithOthers so the film's audio apps are not interrupted.
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker])
        } catch {
            throw AudioCaptureError.session(error)
        }
        preferBuiltInMic(session)
        // Best effort (QA1631: preferences are honoured more often when requested before
        // activation); the real values are read back below and nothing depends on them.
        try? session.setPreferredSampleRate(Self.preferredSampleRate)
        try? session.setPreferredIOBufferDuration(Self.bufferDuration)
        do {
            try session.setActive(true)
        } catch {
            throw AudioCaptureError.session(error)
        }
        sessionSampleRate = session.sampleRate
        ioBufferDuration = session.ioBufferDuration
        let inputs = session.currentRoute.inputs.map(\.portName).joined(separator: ", ")
        log.info("Session active: \(session.sampleRate, privacy: .public) Hz (asked \(Self.preferredSampleRate, privacy: .public)), IO buffer \(session.ioBufferDuration * 1000, format: .fixed(precision: 1), privacy: .public) ms (asked \(Self.bufferDuration * 1000, privacy: .public)), input: \(inputs, privacy: .public)")
    }

    private func preferBuiltInMic(_ session: AVAudioSession) {
        if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try? session.setPreferredInput(builtIn)
        }
    }

    // MARK: Engine and tap

    /// Install the tap with the *current* hardware format, prepare, start, arm the watchdog.
    private func startEngine() throws {
        let input = engine.inputNode
        // Apple's documented "input enabled" test: a nonzero rate and channel count.
        let hardware = input.inputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else {
            throw AudioCaptureError.inputUnavailable
        }
        let format = input.outputFormat(forBus: 0)
        let formatChanged = inputFormat.map { $0 != format } ?? false
        inputFormat = format
        input.removeTap(onBus: 0)
        let frames = AVAudioFrameCount(Self.bufferDuration * format.sampleRate)
        input.installTap(onBus: 0, bufferSize: frames, format: format) { [weak self] buffer, when in
            self?.handleTap(buffer, when)
        }
        tapInstalled = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            tapInstalled = false
            throw AudioCaptureError.session(error)
        }
        armWatchdog()
        log.info("Engine started: tap \(format.sampleRate, privacy: .public) Hz × \(format.channelCount, privacy: .public) ch, \(frames, privacy: .public) frames/buffer")
        if formatChanged { onFormatChange?(format) }
    }

    private func tearDownEngine() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning { engine.stop() }
    }

    /// removeTap → stop → installTap with the current format → prepare → start → watchdog
    /// (A §4.7). A bare `engine.start()` leaves a dead tap after calls on some devices.
    private func rebuildTap() throws {
        rebuildCount += 1
        tearDownEngine()
        try startEngine()
    }

    /// Drop the engine entirely and build a new one (`mediaServicesWereReset`, second watchdog
    /// failure). The configuration-change observer matches by identity against `engine` at
    /// delivery time, so it follows the new instance.
    private func rebuildEngine() throws {
        rebuildCount += 1
        tearDownEngine()
        engine = AVAudioEngine()
        try startEngine()
    }

    /// Audio thread.
    private func handleTap(_ buffer: AVAudioPCMBuffer, _ when: AVAudioTime) {
        bufferClock.withLock { $0 = (.now, when) }
        #if DEBUG
        record(buffer)
        #endif
        onBuffer?(buffer)
        onTimedBuffer?(buffer, when)
    }

    // MARK: Watchdog

    private func armWatchdog() {
        watchdog?.cancel()
        armedAt = .now
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.watchdogTick() }
        timer.resume()
        watchdog = timer
    }

    /// The ladder (A §4.7 + critique D2): 1.5 s → rebuild tap; 1.5 s more → rebuild engine;
    /// 5 s since the last buffer → `.interrupted` + `onTapGap`; 10 s → `.unavailable`.
    private func watchdogTick() {
        guard isRunning, interruptedAt == nil else { return }
        let now = Date.now
        let last = lastBufferAt
        #if DEBUG
        reportMuteExperiment(now: now, lastBuffer: last)
        #endif
        if last > armedAt {
            // Buffers have flowed since the last action: healthy, or just recovered.
            if recoveryAttempts > 0 || tapGapSignalled {
                let gap = now.timeIntervalSince(lastGoodBufferAt ?? armedAt)
                log.info("Tap recovered after \(gap, format: .fixed(precision: 1), privacy: .public) s (\(self.recoveryAttempts, privacy: .public) rebuild(s))")
                let signalled = tapGapSignalled
                recoveryAttempts = 0
                tapGapSignalled = false
                lastGoodBufferAt = nil
                needsRecovery = false
                publish(state(for: activity))
                if signalled { onInterruption?(.ended(seconds: gap, recovered: true)) }
            }
            armedAt = last
            return
        }
        let sinceAction = now.timeIntervalSince(armedAt)
        let sinceBuffer = now.timeIntervalSince(max(last, startedAt))
        if sinceAction > Self.bufferWatchdogSeconds, recoveryAttempts < 2 {
            recoveryAttempts += 1
            lastGoodBufferAt = lastGoodBufferAt ?? (last > startedAt ? last : startedAt)
            do {
                if recoveryAttempts == 1 {
                    log.warning("No buffer for \(sinceAction, format: .fixed(precision: 1), privacy: .public) s; rebuilding the tap")
                    try rebuildTap()
                } else {
                    log.warning("Tap still silent; rebuilding the engine")
                    try rebuildEngine()
                }
            } catch {
                log.error("Rebuild failed: \(error.localizedDescription, privacy: .public)")
                armedAt = now
            }
        }
        if sinceBuffer > Self.tapGapSeconds, !tapGapSignalled {
            tapGapSignalled = true
            log.error("Tap gap of \(sinceBuffer, format: .fixed(precision: 1), privacy: .public) s")
            publish(.interrupted)
            onInterruption?(.began)
            onTapGap?(sinceBuffer)
        }
        if sinceBuffer > Self.deadTapSeconds, recoveryAttempts == 2 {
            recoveryAttempts = 3
            needsRecovery = true
            log.error("Dead tap: no audio for \(sinceBuffer, format: .fixed(precision: 1), privacy: .public) s after two rebuilds")
            publish(.unavailable(AudioCaptureError.deadTap.localizedDescription))
        }
    }

    // MARK: Observers (A §4.7, installed once in start(), removed in stop())

    private func installObservers() {
        let center = NotificationCenter.default
        func observe(_ name: Notification.Name, _ handler: @escaping (Notification) -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in handler(note) })
        }

        // Interruptions. iOS 27 models them as deactivation / resumption (the legacy
        // notification is deprecated there); iOS 26 and earlier use interruptionNotification.
        #if compiler(>=6.4)
        // Compile check: the iOS 27 lifecycle API ships with the Xcode 27 toolchain (Swift 6.4).
        // Older toolchains build the legacy path only.
        if #available(iOS 27, *) {
            observe(AVAudioSession.didBecomeInactiveNotification) { [weak self] note in
                guard let self, let context = note.userInfo?[AVAudioSession.deactivationContextKey] as? AVAudioSession.DeactivationContext else { return }
                switch context.source {
                case .system:
                    self.interruptionBegan()
                case .app:
                    // Our own stop(); nothing to do.
                    break
                @unknown default:
                    self.interruptionBegan()
                }
            }
            observe(AVAudioSession.resumptionRecommendationNotification) { [weak self] note in
                guard let self, let context = note.userInfo?[AVAudioSession.resumptionContextKey] as? AVAudioSession.ResumptionContext else { return }
                switch context.recommendation {
                case .shouldResume:
                    self.resumeAfterInterruption(activate: .asynchronous)
                case .shouldNotResume:
                    log.warning("System recommends not resuming the session")
                    self.interruptionFailed("Mic was taken by a call.", retry: false)
                @unknown default:
                    self.resumeAfterInterruption(activate: .asynchronous)
                }
            }
            observe(AVAudioSession.didBecomeActiveNotification) { _ in
                log.info("Session became active")
            }
        } else {
            installLegacyInterruptionObserver(observe)
        }
        #else
        installLegacyInterruptionObserver(observe)
        #endif

        observe(AVAudioSession.routeChangeNotification) { [weak self] note in
            guard let self, self.isRunning else { return }
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            let reason = AVAudioSession.RouteChangeReason(rawValue: raw) ?? .unknown
            switch reason {
            case .categoryChange:
                // The category never changes after start() (critique C16); nothing to do.
                return
            case .oldDeviceUnavailable, .newDeviceAvailable, .override, .routeConfigurationChange, .wakeFromSleep:
                self.preferBuiltInMic(AVAudioSession.sharedInstance())
                guard self.interruptedAt == nil, !self.engine.isRunning else { return }
                log.info("Route change (\(raw, privacy: .public)) with the engine stopped; rebuilding the tap")
                self.attempt("route change") { try self.rebuildTap() }
            default:
                return
            }
        }

        observe(.AVAudioEngineConfigurationChange) { [weak self] note in
            guard let self, self.isRunning, self.interruptedAt == nil,
                  let changed = note.object as? AVAudioEngine, changed === self.engine else { return }
            log.info("Engine configuration changed; rebuilding the tap")
            // Never deallocate the engine inside this handler: rebuildTap keeps the instance.
            self.attempt("configuration change") { try self.rebuildTap() }
        }

        observe(AVAudioSession.mediaServicesWereResetNotification) { [weak self] _ in
            guard let self, self.isRunning else { return }
            log.error("Media services were reset; rebuilding the engine")
            self.attempt("media services reset", background: "Audio system was reset.") {
                // A reset ends any interruption in flight; the watchdog ladder runs again from here.
                self.interruptedAt = nil
                try self.configureSession(AVAudioSession.sharedInstance())
                try self.rebuildEngine()
            }
        }

        observe(AVAudioApplication.inputMuteStateChangeNotification) { [weak self] note in
            guard let self else { return }
            let muted = (note.userInfo?[AVAudioApplication.muteStateKey] as? NSNumber)?.boolValue
                ?? AVAudioApplication.shared.isInputMuted
            self.isInputMuted = muted
            log.info("Input mute changed: \(muted, privacy: .public)")
            self.onInputMuteChange?(muted)
        }

        #if canImport(UIKit)
        observe(UIApplication.didBecomeActiveNotification) { [weak self] _ in
            self?.recover()
        }
        #endif
    }

    private func installLegacyInterruptionObserver(_ observe: (Notification.Name, @escaping (Notification) -> Void) -> Void) {
        observe(AVAudioSession.interruptionNotification) { [weak self] note in
            guard let self, let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            switch type {
            case .began:
                // Reason 1 == appWasSuspended (deprecated, iOS ≤ 15): the delayed "you were
                // suspended" notice after a relaunch. Treat as a relaunch, not an interruption.
                if let reason = note.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt, reason == 1 {
                    log.warning("Session was deactivated while the app was suspended")
                    self.onWasSuspended?()
                    return
                }
                self.interruptionBegan()
            case .ended:
                // With or without .shouldResume: we are mixable and user-driven, so we always
                // try (A §4.7).
                self.resumeAfterInterruption(activate: .synchronous)
            @unknown default:
                break
            }
        }
    }

    // MARK: Interruptions

    private enum Activation { case synchronous, asynchronous }

    private func interruptionBegan() {
        guard isRunning, interruptedAt == nil else { return }
        interruptedAt = .now
        watchdog?.cancel()
        watchdog = nil
        lastGoodBufferAt = lastBufferAt > startedAt ? lastBufferAt : startedAt
        log.info("Interrupted")
        publish(.interrupted)
        onInterruption?(.began)
    }

    /// `setActive(true)` (iOS ≤ 26) or `activate(options:)` (iOS 27) followed by a **full**
    /// tap rebuild (A §4.7).
    private func resumeAfterInterruption(activate: Activation) {
        guard isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        switch activate {
        case .synchronous:
            do {
                try session.setActive(true)
                finishResume()
            } catch {
                log.error("setActive after interruption failed: \(error.localizedDescription, privacy: .public)")
                interruptionFailed("Mic was taken by a call.")
            }
        case .asynchronous:
            #if compiler(>=6.4)
            if #available(iOS 27, *) {
                session.activate(options: []) { [weak self] activated, error in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        if activated {
                            self.finishResume()
                        } else {
                            log.error("activate after interruption failed: \(error?.localizedDescription ?? "unknown", privacy: .public)")
                            self.interruptionFailed("Mic was taken by a call.")
                        }
                    }
                }
                return
            }
            #endif
            resumeAfterInterruption(activate: .synchronous)
        }
    }

    private func finishResume() {
        let seconds = interruptedAt.map { Date.now.timeIntervalSince($0) } ?? 0
        interruptedAt = nil
        do {
            try rebuildTap()
            // The ladder starts afresh from this rebuild: a later tap gap must be measured from
            // here, not from the interruption that has just ended.
            recoveryAttempts = 0
            tapGapSignalled = false
            lastGoodBufferAt = nil
            needsRecovery = false
            log.info("Interruption ended after \(seconds, format: .fixed(precision: 1), privacy: .public) s; tap rebuilt")
            publish(state(for: activity))
            onInterruption?(.ended(seconds: seconds, recovered: true))
        } catch {
            log.error("Rebuild after interruption failed: \(error.localizedDescription, privacy: .public)")
            interruptionFailed("Mic couldn't restart after the interruption.")
        }
    }

    /// A resume after an interruption failed. Background: `.unavailable(reason)` until
    /// `recover()` runs on the next `didBecomeActive` (A §4.7). Foreground: stay `.interrupted`
    /// and retry once after `foregroundRetrySeconds` (A §4.7 "retry"); if that fails too,
    /// `recover()` publishes `.unavailable` and the card tap / `didBecomeActive` retry.
    /// `reason` is a plain sentence: `MicState.copy` (WP0) appends "Open Subtext to re-sync."
    private func interruptionFailed(_ reason: String, retry: Bool = true) {
        let seconds = interruptedAt.map { Date.now.timeIntervalSince($0) } ?? 0
        interruptedAt = nil
        needsRecovery = true
        recoveryAttempts = 3
        if retry, !isInBackground {
            publish(.interrupted)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.foregroundRetrySeconds) { [weak self] in self?.recover() }
        } else {
            publish(.unavailable(reason))
        }
        onInterruption?(.ended(seconds: seconds, recovered: false))
    }

    /// Run a recovery step; on failure in the foreground keep `.interrupted` (the watchdog and
    /// `didBecomeActive` retry), in the background go `.unavailable` with `background` copy.
    private func attempt(_ what: String, background: String = "Mic was lost in the background.", _ body: () throws -> Void) {
        do {
            try body()
            if !tapGapSignalled { publish(state(for: activity)) }
        } catch {
            log.error("Recovery after \(what, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            needsRecovery = true
            if isInBackground {
                recoveryAttempts = 3
                publish(.unavailable(background))
            } else {
                publish(.interrupted)
            }
        }
    }

    private var isInBackground: Bool {
        #if canImport(UIKit)
        if Thread.isMainThread {
            return MainActor.assumeIsolated { UIApplication.shared.applicationState == .background }
        }
        return false
        #else
        return false
        #endif
    }

    // MARK: State

    private func state(for activity: Activity) -> MicState {
        switch activity {
        case .listening: .listening
        case .idle: .openIdle
        case .checking: .checking
        }
    }

    private func publish(_ state: MicState) {
        guard state != micState else { return }
        micState = state
        log.info("Mic state → \(String(describing: state), privacy: .public)")
        onStateChange?(state)
    }

    // MARK: DEBUG launch arguments

    #if DEBUG
    /// `-recordMic [seconds]`: the first `seconds` (default 180) of microphone audio go to
    /// Documents/mic.caf for `-replayMic` (WP4) and the real-room comparison (critique WP7).
    /// Audio thread. TODO(WP7): remove the 40 s V1 recorder in `SyncEngine.start`, which writes
    /// the same file.
    private func record(_ buffer: AVAudioPCMBuffer) {
        recorderLock.lock()
        defer { recorderLock.unlock() }
        guard !recordingDone else { return }
        guard let seconds = Self.recordSeconds else { recordingDone = true; return }
        if recorder == nil {
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("mic.caf")
            recorder = try? AVAudioFile(forWriting: url, settings: buffer.format.settings)
            guard recorder != nil else { recordingDone = true; return }
            log.info("Recording \(seconds, privacy: .public) s of microphone audio to \(url.lastPathComponent, privacy: .public)")
        }
        if recordedFrames < AVAudioFramePosition(seconds * buffer.format.sampleRate) {
            try? recorder?.write(from: buffer)
            recordedFrames += AVAudioFramePosition(buffer.frameLength)
        } else {
            recorder = nil
            recordingDone = true
            log.info("Recording finished (\(self.recordedFrames, privacy: .public) frames)")
        }
    }

    /// Experiment (i): three seconds after muting, log whether the tap kept delivering.
    private func reportMuteExperiment(now: Date, lastBuffer: Date) {
        guard inputMuteExperiment, let mutedAt, !muteExperimentReported, now.timeIntervalSince(mutedAt) > 3 else { return }
        muteExperimentReported = true
        let flowing = now.timeIntervalSince(lastBuffer) < 1
        log.info("inputMuteExperiment: isInputMuted \(AVAudioApplication.shared.isInputMuted, privacy: .public), buffers still flowing after 3 s: \(flowing, privacy: .public)")
    }
    #endif
}

private extension MicState {
    var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }
}
