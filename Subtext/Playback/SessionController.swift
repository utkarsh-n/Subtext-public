import Foundation
import Observation
import os

private let log = Logger(subsystem: "com.utkarsh.subtext", category: "Session")

/// A viewing session: one subtitle track, a media clock, the sync engine feeding that clock,
/// and the Live Activity that shows the current line.
///
/// `SessionController` is the only writer of the display `clock`, `trim`, `pauseReason` and
/// `isPlaced` (docs/v2/critique.md D5). Stored properties are internal so WP7's
/// `SessionController+Session.swift` can reach them. WP0 keeps every body at V1 behaviour.
@MainActor
@Observable
final class SessionController {
    static let shared = SessionController()

    var track: SubtitleTrack?
    var clock = PlaybackClock()
    /// Seconds the user has nudged on top of auto sync. Positive shows lines later.
    var trim: Double = 0
    var currentIndex: Int?
    var isActive = false
    /// Lines are shown: a lock landed, the user placed the clock, or auto-sync is off. Sticky
    /// across `relisten()` (lines keep running on the old clock); cleared by `resync()` in WP0
    /// (V1 blanks the lines during a full search; WP7 keeps it for the wide pass) and in `end()`.
    var isPlaced = false
    var pauseReason: PauseReason = .none
    var sessionStart: Date = .now
    /// Last user nudge / trim drag (nudge guard: corrections < 1 s are skipped for 20 s).
    var lastNudgeAt: Date?
    /// A backward correction waiting for a cue boundary or its deadline (B §5).
    var pendingCorrection: Correction?
    /// Auto-end countdown target while the phase is `.ending`.
    var endsAt: Date?

    /// Off → lines stay (manual); on again → lines hidden until the next lock lands (V1).
    var autoSync = true { didSet { if !autoSync { isPlaced = true; engine.stop() } else if isActive { isPlaced = false; restartEngine() }; refresh() } }
    var liveActivityEnabled = true { didSet { liveActivityEnabled ? refresh(force: true) : activity.end() } }
    var useSpeech = true
    /// Adds 1.25×–2× to the speeds the search tries, for people who watch fast.
    var speedWatching = false { didSet { UserDefaults.standard.set(speedWatching, forKey: "speedWatching"); engine.speedWatching = speedWatching } }
    var audioLocale: Locale = .current {
        didSet { UserDefaults.standard.set(audioLocale.identifier, forKey: "audioLocale") }
    }

    // MARK: Settings (critique §4.3; UserDefaults-backed, read once at init)

    var lockedInEnabled = true { didSet { store(lockedInEnabled, "lockedIn.enabled"); engine.lockedInEnabled = lockedInEnabled } }
    var lockedInCheckIn: CheckInInterval = .adaptive { didSet { store(lockedInCheckIn.rawValue, "lockedIn.checkIn"); engine.checkInInterval = lockedInCheckIn } }
    var autoPauseEnabled = true { didSet { store(autoPauseEnabled, "autoPause.enabled"); engine.autoPauseEnabled = autoPauseEnabled } }
    var autoPausePatience: AutoPausePatience = .normal { didSet { store(autoPausePatience.rawValue, "autoPause.patience"); engine.autoPausePatience = autoPausePatience } }
    /// 0 = never.
    var autoEndMinutes = 20 { didSet { store(autoEndMinutes, "autoEnd.minutes"); engine.autoEndMinutes = autoEndMinutes } }
    var treatMusicAsContent = true { didSet { store(treatMusicAsContent, "treatMusicAsContent"); engine.treatMusicAsContent = treatMusicAsContent } }
    var memoryEnabled = true { didSet { store(memoryEnabled, "memory.enabled"); engine.memoryEnabled = memoryEnabled } }
    var memoryRewatchSearch = true { didSet { store(memoryRewatchSearch, "memory.rewatchSearch"); engine.memoryRewatchSearch = memoryRewatchSearch } }
    var islandPulse = true { didSet { store(islandPulse, "island.pulse") } }
    var islandRing = true { didSet { store(islandRing, "island.ring"); refresh() } }
    var showNextLine = false { didSet { store(showNextLine, "island.showNextLine"); refresh() } }
    /// Cue boundaries are pushed this much early to absorb update-to-glass latency.
    var leadSeconds: Double = 0.15 { didSet { store(leadSeconds, "island.leadSeconds") } }
    var theaterTextSize = "large" { didSet { store(theaterTextSize, "theater.textSize") } }
    var theaterKeepAwake = true { didSet { store(theaterKeepAwake, "theater.keepAwake") } }
    var theaterHaptics = true { didSet { store(theaterHaptics, "theater.haptics") } }
    var theaterAllowLandscape = true { didSet { store(theaterAllowLandscape, "theater.allowLandscape") } }
    var debugShowEngine = false { didSet { store(debugShowEngine, "debug.showEngine") } }
    var legendSeen = false { didSet { store(legendSeen, "legend.seen") } }
    /// `{trackID, media, wall, rate, reason}` for "Resume last session" / hinted relaunch.
    var sessionLast: Data? { didSet { UserDefaults.standard.set(sessionLast, forKey: "session.last") } }
    var tuningUseTextExpectations = false { didSet { store(tuningUseTextExpectations, "tuning.useTextExpectations"); engine.useTextExpectations = tuningUseTextExpectations } }
    var tuningAdaptiveCap: Double = 300 { didSet { store(tuningAdaptiveCap, "tuning.adaptiveCap"); engine.adaptiveCap = tuningAdaptiveCap } }

    let engine = SyncEngine()
    let activity = LiveActivityController()
    var scheduler: Task<Void, Never>?
    var generation = 0
    /// Undo state for `jump(toCue:)`, valid for 3 s.
    var previousClock: PlaybackClock?
    var previousTrim: Double = 0
    var jumpUndoUntil: Date?
    var lastResyncAt: Date?

    private init() {
        let d = UserDefaults.standard
        if let id = d.string(forKey: "audioLocale") { audioLocale = Locale(identifier: id) }
        speedWatching = d.bool(forKey: "speedWatching")
        lockedInEnabled = Self.read("lockedIn.enabled", true)
        lockedInCheckIn = CheckInInterval(rawValue: Self.read("lockedIn.checkIn", "adaptive")) ?? .adaptive
        autoPauseEnabled = Self.read("autoPause.enabled", true)
        autoPausePatience = AutoPausePatience(rawValue: Self.read("autoPause.patience", "normal")) ?? .normal
        autoEndMinutes = Self.read("autoEnd.minutes", 20)
        treatMusicAsContent = Self.read("treatMusicAsContent", true)
        memoryEnabled = Self.read("memory.enabled", true)
        memoryRewatchSearch = Self.read("memory.rewatchSearch", true)
        islandPulse = Self.read("island.pulse", true)
        islandRing = Self.read("island.ring", true)
        showNextLine = Self.read("island.showNextLine", false)
        leadSeconds = Self.read("island.leadSeconds", 0.15)
        theaterTextSize = Self.read("theater.textSize", "large")
        theaterKeepAwake = Self.read("theater.keepAwake", true)
        theaterHaptics = Self.read("theater.haptics", true)
        theaterAllowLandscape = Self.read("theater.allowLandscape", true)
        debugShowEngine = Self.read("debug.showEngine", false)
        legendSeen = Self.read("legend.seen", false)
        sessionLast = d.data(forKey: "session.last")
        tuningUseTextExpectations = Self.read("tuning.useTextExpectations", false)
        tuningAdaptiveCap = Self.read("tuning.adaptiveCap", 300.0)
        forwardSettings()
        engine.onLock = { [weak self] lock in self?.apply(lock) }
        engine.onAction = { [weak self] action in self?.apply(action: action) }
    }

    /// Property observers do not fire inside `init`, so the persisted values are pushed once here.
    private func forwardSettings() {
        engine.speedWatching = speedWatching
        engine.lockedInEnabled = lockedInEnabled
        engine.checkInInterval = lockedInCheckIn
        engine.autoPauseEnabled = autoPauseEnabled
        engine.autoPausePatience = autoPausePatience
        engine.autoEndMinutes = autoEndMinutes
        engine.treatMusicAsContent = treatMusicAsContent
        engine.memoryEnabled = memoryEnabled
        engine.memoryRewatchSearch = memoryRewatchSearch
        engine.useTextExpectations = tuningUseTextExpectations
        engine.adaptiveCap = tuningAdaptiveCap
    }

    private static func read<T>(_ key: String, _ fallback: T) -> T {
        (UserDefaults.standard.object(forKey: key) as? T) ?? fallback
    }

    private func store(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    var phase: SyncPhase {
        if clock.isPaused { return pauseReason == .auto ? .autoPaused : .paused }
        if !autoSync { return .manual }
        return engine.phase
    }

    func mediaTime(at wall: Date = .now) -> Double { clock.mediaTime(at: wall) + trim }

    // MARK: Lifecycle

    func start(track: SubtitleTrack) {
        end()
        self.track = track
        clock = PlaybackClock(media: 0, paused: false)
        trim = 0
        currentIndex = nil
        isPlaced = !autoSync
        pauseReason = .none
        sessionStart = .now
        lastNudgeAt = nil
        pendingCorrection = nil
        endsAt = nil
        isActive = true
        if autoSync { restartEngine() }
        if liveActivityEnabled {
            activity.start(attributes: attributes(for: track), state: contentState())
        }
        startScheduler()
        log.info("Session started: \(track.title, privacy: .public)")
    }

    func end() {
        guard isActive else { return }
        scheduler?.cancel()
        scheduler = nil
        engine.stop()
        activity.end()
        isActive = false
        track = nil
        currentIndex = nil
        isPlaced = false
        pauseReason = .none
        pendingCorrection = nil
        endsAt = nil
        jumpUndoUntil = nil
    }

    private func restartEngine() {
        guard let track else { return }
        Task { await engine.start(cues: track.cues, language: track.language, audioLocale: audioLocale, useSpeech: useSpeech) }
    }

    // MARK: Commands

    func handle(_ command: SyncCommand) {
        switch command {
        case .nudge(let seconds): nudge(seconds)
        case .resync: resync()
        case .togglePause: togglePause()
        case .resume: resume()
        case .keepListening: keepListening()
        }
    }

    func nudge(_ seconds: Double) {
        setTrim(trim + seconds)
    }

    func setTrim(_ value: Double) {
        trim = (value * 100).rounded() / 100
        lastNudgeAt = .now
        refresh(force: true)
    }

    /// Theater trim drag: in-app clock only, no Island push, no scheduler restart.
    /// `setTrim` on drag end does the forced refresh.
    func previewTrim(_ value: Double) {
        trim = (value * 100).rounded() / 100
        lastNudgeAt = .now
        if let track { currentIndex = track.cueIndex(at: mediaTime()) }
    }

    /// Re-sync: a wide pass around the current position first; two taps within 10 s → full search.
    /// WP0: the engine runs V1's full search either way and, as in V1, the lines go blank until
    /// the new lock lands. WP7 keeps `isPlaced` sticky while the wide pass runs (critique C7).
    func resync() {
        let now = Date.now
        let doubleTap = lastResyncAt.map { now.timeIntervalSince($0) < 10 } ?? false
        lastResyncAt = now
        trim = 0
        if clock.isPaused { clock.resume() }
        pauseReason = .none
        pendingCorrection = nil
        isPlaced = false
        if !autoSync { autoSync = true }
        engine.resync(wide: !doubleTap)
        refresh(force: true)
    }

    /// Theater long-press (0.6 s): hinted search around the current position; lines stay.
    func relisten() {
        guard isActive, autoSync else { return }
        if clock.isPaused { clock.resume() }
        pauseReason = .none
        engine.relisten(center: clock.mediaTime())
        refresh(force: true)
    }

    /// Theater: tap the current line → it is right; confirm the lock.
    func confirmSync() {
        guard isActive else { return }
        engine.confirm()
        isPlaced = true
        refresh()
    }

    func togglePause() {
        if clock.isPaused {
            clock.resume()
            pauseReason = .none
        } else {
            clock.pause()
            pauseReason = .user
        }
        refresh(force: true)
    }

    /// Idempotent resume (Island Resume button). While auto-paused the user asserts the film
    /// resumed where it stopped; WP7 adds the hypothesis-P check-in.
    func resume() {
        guard clock.isPaused else { return }
        clock.resume()
        pauseReason = .none
        refresh(force: true)
    }

    /// Auto-end warning → keep the session alive (WP7 resets the quiet clock).
    func keepListening() {
        endsAt = nil
        engine.extendKill()
        refresh(force: true)
    }

    /// The user tapped the line they just heard: that cue starts now.
    func jump(toCue index: Int) {
        guard let track, track.cues.indices.contains(index) else { return }
        let now = Date.now
        previousClock = clock
        previousTrim = trim
        jumpUndoUntil = now.addingTimeInterval(3)
        trim = 0
        clock.set(media: track.cues[index].start, at: now)
        if clock.isPaused { clock.resume(at: now) }
        pauseReason = .none
        pendingCorrection = nil
        isPlaced = true
        engine.seed(mediaTime: track.cues[index].start)
        refresh(force: true)
    }

    /// Restores the clock from before the last `jump(toCue:)`, within 3 s.
    func undoJump() {
        guard let until = jumpUndoUntil, Date.now <= until, let previous = previousClock else { return }
        jumpUndoUntil = nil
        clock = previous
        trim = previousTrim
        if clock.isPaused { clock.resume() }
        engine.seed(mediaTime: clock.mediaTime())
        refresh(force: true)
    }

    /// Manual scrub of the absolute position, for when nothing has locked yet.
    func seek(to media: Double) {
        let now = Date.now
        clock.set(media: media, at: now)
        pendingCorrection = nil
        isPlaced = true
        engine.seed(mediaTime: media)
        refresh(force: true)
    }

    // MARK: Sync input

    /// A V1 tracker lock. Ignored while the clock is paused: under an auto-pause corrections
    /// arrive as `SessionAction`s (critique §2 gap 3), never through this path.
    private func apply(_ lock: SyncTracker.Lock) {
        guard isActive, autoSync else { return }
        isPlaced = true
        guard !clock.isPaused else { return }
        let now = Date.now
        let target = lock.mediaTime(at: now)
        let current = clock.mediaTime(at: now)
        if abs(target - current) < 0.12, lock.rate == clock.rate { return }
        clock.set(media: target, at: now, rate: lock.rate)
        log.info("Lock applied: \(target, privacy: .public)s rate \(lock.rate, privacy: .public)")
        refresh(force: true)
    }

    /// Scheduler actions (WP7 fills the status / warn / end paths). Clock actions are honoured
    /// while `pauseReason == .auto`, which is the only way a correction reaches a held clock.
    func apply(action: SessionAction) {
        guard isActive else { return }
        let now = Date.now
        switch action {
        case .setClock(let c):
            guard autoSync, !clock.isPaused || pauseReason == .auto else { return }
            if let deadline = c.deferUntil, deadline > now {
                pendingCorrection = c
                return
            }
            clock.set(media: c.media + now.timeIntervalSince(c.at) * c.rate, at: now, rate: c.rate)
            if clock.isPaused, pauseReason == .auto { clock.resume(at: now); pauseReason = .none }
            isPlaced = true
            refresh(force: true)
        case .holdClock(let at, let reason):
            guard pauseReason != .user else { return }
            clock.pause(at: at)
            pauseReason = reason
            isPlaced = true
            refresh(force: true)
        case .resumeClock(let at):
            guard pauseReason != .user, clock.isPaused else { return }
            clock.resume(at: at)
            pauseReason = .none
            refresh(force: true)
        case .warn(let at):
            endsAt = at
            refresh(force: true)
        case .clearWarning:
            endsAt = nil
            refresh(force: true)
        case .status, .endSession, .caughtUp:
            break
        }
    }

    // MARK: Scheduling

    private func startScheduler() {
        scheduler?.cancel()
        generation += 1
        let myGeneration = generation
        scheduler = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation == myGeneration, let track = self.track else { return }
                let media = self.mediaTime()
                self.currentIndex = track.cueIndex(at: media)
                self.pushState()
                var wait = 1.0
                if !self.clock.isPaused, let boundary = track.nextBoundary(after: media) {
                    wait = min(1.0, max(0.03, (boundary - media) / max(0.1, self.clock.rate) + 0.01))
                }
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    func refresh(force: Bool = false) {
        guard isActive, let track else { return }
        currentIndex = track.cueIndex(at: mediaTime())
        pushState()
        if force { startScheduler() }
    }

    /// Pushes the current `IslandState`. `staleDate` policy (critique C14) is WP7's; V1 passes nil.
    func pushState(staleDate: Date? = nil) {
        guard liveActivityEnabled, let track else { return }
        activity.update(state: contentState(), attributes: attributes(for: track), staleDate: staleDate)
    }

    private func attributes(for track: SubtitleTrack) -> SubtextActivityAttributes {
        SubtextActivityAttributes(title: track.title, language: track.language)
    }

    func snapshot() -> EngineSnapshot {
        // WP0 (reviewer): exactly V1's `showLines`. `isPlaced` alone would keep a dropped
        // unconfirmed candidate's line on the glass where V1 blanked it (tracker: one miss →
        // `lock = nil`, `.searching`). WP7 drops the engine terms so `isPlaced` is sticky
        // through lost / reacquiring (critique §4.2).
        EngineSnapshot(phase: phase, isPaused: clock.isPaused,
                       placed: (isPlaced && (engine.lock != nil || engine.phase == .locked)) || !autoSync || clock.isPaused,
                       beat: 0, trim: trim, rate: clock.rate, sessionStart: sessionStart,
                       checkInWindow: engine.checkInWindow, lastCheckInAt: engine.lastCheckInAt,
                       nextCheckInAt: engine.nextCheckInAt, pauseReason: pauseReason, endsAt: endsAt)
    }

    func contentState() -> SubtextActivityAttributes.ContentState {
        guard let track else {
            return IslandState(currentText: "", nextText: "", cueIndex: 0, cueCount: 0, trim: trim, phase: phase,
                               isPaused: clock.isPaused, rate: clock.rate, pauseReason: pauseReason)
        }
        // WP0: V1 always sent the next line, so the widget keeps showing it; WP7 switches this to
        // the `island.showNextLine` setting (`showNextLine`, default off) when WP5's widget lands.
        return IslandPresenter.state(track: track, media: mediaTime(), snapshot: snapshot(),
                                     options: PresenterOptions(showNextLine: true, showRing: islandRing),
                                     now: .now)
    }
}

extension SubtitleTrack: IslandCueSource {
    var cueCount: Int { cues.count }
    func cueText(_ index: Int) -> String { cues[index].text }
    func cueEnd(_ index: Int) -> Double { cues[index].end }
}
