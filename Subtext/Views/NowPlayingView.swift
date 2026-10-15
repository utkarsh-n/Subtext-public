import SwiftUI

struct NowPlayingView: View {
    let track: SubtitleTrack
    @State private var session = SessionController.shared
    @State private var locales: [Locale] = []
    @State private var showingLines = false
    @State private var showingSeek = false
    /// "Caught up −38 s" for 2 s after a large correction (keepalive.md §1).
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?
    /// "Checking… 8 s" counts from the moment the phase became `.checkingIn`.
    @State private var checkingSince: Date?
    /// "Learn this room" runs for 5 s; the button shows the countdown meanwhile.
    @State private var learningUntil: Date?
    /// First moment of the current uninterrupted `.locked` stretch; proxy for `rateConfirmed`
    /// (A's rule: ≥ 120 s of tracking). TODO(WP7): read `engine.rateConfirmed` instead.
    @State private var lockedSince: Date?
    /// `session.last` decoded once per change (the status card re-renders at the mic meter's rate).
    @State private var lastRecord: LastSessionRecord?

    private var isThisSession: Bool { session.isActive && session.track?.id == track.id }
    private var engine: SyncEngine { session.engine }

    /// The auto-end warning (critique §4.2 `ending`). WP0's `session.phase` reports
    /// `.paused`/`.autoPaused` whenever the clock is held — and it is held while ending — so
    /// `session.endsAt` (set by `SessionAction.warn`) is the reliable signal until WP7 maps
    /// scheduler states to phases in `SessionController`.
    private var isEnding: Bool {
        if session.phase == .ending { return true }
        if let endsAt = session.endsAt, endsAt > .now { return true }
        return false
    }

    /// `session.phase`, with the ending warning winning over the held clock it rides on.
    private var displayPhase: SyncPhase { isEnding ? .ending : session.phase }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                statusCard
                if !session.legendSeen {
                    LegendCard { withAnimation { session.legendSeen = true } }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                cueCard
                trimCard
                theaterButton
                controls
                SessionOptionsView(rateConfirmed: rateConfirmedProxy)
                options
            }
            .padding()
        }
        .overlay(alignment: .top) { toastView }
        .navigationTitle(track.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isThisSession {
                    Button("End", role: .destructive) { session.end() }
                } else {
                    Button("Start") { session.start(track: track) }.buttonStyle(.borderedProminent)
                }
            }
        }
        .sheet(isPresented: $showingLines) { CueListView(track: track) }
        .sheet(isPresented: $showingSeek) { SeekSheet(track: track) }
        .task { locales = await LiveTranscriber.supportedLocales() }
        .onAppear { if !session.isActive { session.start(track: track) } }
        .onChange(of: engine.lastCatchUp) { _, value in
            guard let value, abs(value) >= 0.5 else { return }
            showToast(Self.catchUpLabel(value))
        }
        .onChange(of: session.sessionLast, initial: true) { _, data in
            lastRecord = LastSessionRecord.load(from: data)
        }
        .onChange(of: session.phase, initial: true) { _, phase in
            checkingSince = phase == .checkingIn ? .now : nil
            switch phase {
            case .locked, .checkingIn: if lockedSince == nil { lockedSince = .now }
            case .paused, .autoPaused, .recovering, .ending: break   // a held clock keeps the stretch
            default: lockedSince = nil
            }
        }
    }

    // MARK: Status

    private var statusCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                // island.md §5.9: the in-app beacon at 12 pt, on a dark puck so the Island's white
                // states stay visible on a light card.
                BeaconPuck(phase: displayPhase, isPaused: session.clock.isPaused, level: engine.micLevel)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline).font(.headline)
                    statusDetail.font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    if let secondary = secondaryDetail {
                        Text(secondary).font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
                    }
                }
                Spacer()
                MicMeter(level: engine.micLevel)
            }
            if isThisSession, session.autoSync, session.phase != .micLost, session.phase != .ended {
                PresenceBar(features: engine.presenceFeatures, state: engine.presenceState, micLevel: engine.micLevel)
            }
            statusActions
        }
        .padding()
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .contentShape(Rectangle())
        .onTapGesture {
            // A §8: tapping the card while the mic is lost runs a check-in.
            if session.phase == .micLost { engine.requestCheckIn(force: false) }
        }
    }

    private var headline: String {
        if isEnding { return SyncPhase.ending.label }
        if session.phase == .locked, engine.mode == .lockedIn { return "Locked in" }
        return session.phase.label
    }

    /// Status copy: keepalive.md §8 (minus `.released`), latch.md §9, critique §4.2.
    @ViewBuilder
    private var statusDetail: some View {
        if let error = engine.error {
            Text(error)
        } else if !session.autoSync {
            Text("Auto-sync is off. Use the wheel or tap the line you hear.")
        } else {
            switch displayPhase {
            case .listening:
                if neverLockedAndQuiet {
                    Text("Nothing heard — is the TV's sound reaching the phone?")
                } else {
                    Text("Play the film and keep the phone within earshot.")
                }
            case .searching:
                if neverLockedAndQuiet {
                    Text("Nothing heard — is the TV's sound reaching the phone?")
                } else {
                    Text(engine.lastHeard.isEmpty ? "Matching speech rhythm against the track…" : "Heard “\(engine.lastHeard)”")
                }
            case .locked:
                lockedDetail
            case .checkingIn:
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let s = max(0, Int(ctx.date.timeIntervalSince(checkingSince ?? ctx.date).rounded()))
                    Text("Checking… \(s) s")
                }
            case .paused:
                Text("Clock frozen. Resume when the film does.")
            case .autoPaused:
                autoPausedDetail
            case .recovering:
                Text("Hearing something — finding your place")
            case .drifting:
                Text("Lost the thread, listening…")
            case .ending:
                // `now` is read once: a `ClosedRange` whose lower bound is re-read after the
                // guard could invert in the last microseconds and trap.
                let now = Date.now
                if let endsAt = session.endsAt ?? schedulerEndsAt, endsAt > now {
                    HStack(spacing: 0) {
                        Text("Ending in ")
                        Text(timerInterval: now...endsAt, countsDown: true).monospacedDigit()
                        Text(" · tap Keep listening")
                    }
                } else {
                    Text("Ending soon · tap Keep listening")
                }
            case .ended:
                Text(endedCopy)
            case .manual:
                Text("Timing is yours.")
            case .micLost:
                Text(micLostCopy)
            }
        }
    }

    /// keepalive.md §8 (D7): the mic words come from `engine.micState`, never from the mode.
    /// `.openIdle` → "Locked in · mic open, idle"; any other capture state while locked-in
    /// says only what is certain — the mic is open.
    private var lockedInMicCopy: String {
        engine.micState == .openIdle ? MicState.openIdle.copy : "Locked in · mic open"
    }

    @ViewBuilder
    private var lockedDetail: some View {
        if engine.mode == .lockedIn {
            let now = Date.now
            if session.lockedInCheckIn == .manual {
                Text(lockedInMicCopy + " · check-ins only when you tap Re-sync")
            } else if let next = engine.nextCheckInAt, next > now {
                // keepalive.md §8 `.openIdle`: "Locked in · mic open, idle · next check-in 0:48".
                // The mic-open statement stays on this line (critique §2: said plainly, not buried).
                HStack(spacing: 0) {
                    Text(lockedInMicCopy + " · next check-in ")
                    Text(timerInterval: now...next, countsDown: true).monospacedDigit()
                }
            } else {
                Text(lockedInMicCopy)
            }
        } else {
            let rate = session.clock.rate
            Text(rate == 1 ? "In step with the room." : String(format: "In step, playing at %.3f× speed.", rate))
        }
    }

    @ViewBuilder
    private var autoPausedDetail: some View {
        if engine.presenceFeatures?.evidence == .hold {
            Text("Hearing voices, not the film")
        } else if let since = heldSince {
            HStack(spacing: 0) {
                Text("Paused ")
                Text(timerInterval: since...since.addingTimeInterval(8 * 3600), countsDown: false).monospacedDigit()
                Text(" ago · nothing playing")
            }
        } else {
            Text("Paused · catches up when the film does")
        }
    }

    /// A second, quieter line: presence hints and audio-memory progress.
    private var secondaryDetail: String? {
        guard isThisSession, session.autoSync, engine.error == nil else { return nil }
        switch displayPhase {
        case .locked, .checkingIn:
            if case .suspect = engine.presenceState { return "Sounds like it stopped…" }
            if engine.presenceFeatures?.evidence == .hold { return "Hearing voices, not the film" }
            if engine.memoryConfirmed { return "Confirmed by audio memory" }
            if session.memoryEnabled, engine.memoryCoverage > 0 {
                return String(format: "Learning this film · %.0f %%", engine.memoryCoverage * 100)
            }
            if engine.mode == .lockedIn { return "A light check every 10 s; the mic stays open." }
            if engine.presenceFeatures?.evidence == .present { return "Hearing the film." }   // latch.md §9 `playing`
            return nil
        case .searching:
            if session.memoryEnabled, engine.memoryCoverage >= 0.25 { return "Listening for lines it remembers" }
            return nil
        case .autoPaused, .recovering:
            if engine.roomQuiet { return "Room is quiet" }
            return nil
        default:
            return nil
        }
    }

    private var heldSince: Date? {
        if case .paused(_, let since) = engine.presenceState { return since }
        if case .held(_, let since) = engine.schedulerState { return since }
        return nil
    }

    private var schedulerEndsAt: Date? {
        if case .ending(let endsAt) = engine.schedulerState { return endsAt }
        if case .ending(_, let endsAt) = engine.presenceState { return endsAt }
        return nil
    }

    private var neverLockedAndQuiet: Bool {
        guard session.isActive, !session.isPlaced else { return false }
        if case .paused = engine.presenceState { return true }
        return engine.presenceFeatures?.evidence == .absent && engine.tickCount > 30
    }

    private var endedCopy: String {
        if case .ended(let reason) = engine.schedulerState { return Self.endedCopy(reason) }
        if case .ended(let reason) = engine.presenceState { return Self.endedCopy(reason) }
        return "Ended — nothing heard for \(session.autoEndMinutes == 0 ? 20 : session.autoEndMinutes) min"
    }

    static func endedCopy(_ reason: EndReason) -> String {
        switch reason {
        case .silence(let minutes): "Ended — nothing heard for \(minutes) min"
        case .neverHeard: "Ended — the TV's sound never reached the phone"
        case .timeLimit: "Ended after 8 hours"
        }
    }

    private var micLostCopy: String {
        switch engine.micState {
        case .interrupted, .unavailable: engine.micState.copy
        default: "Microphone lost. Open Subtext to re-sync."
        }
    }

    // MARK: Status actions

    @ViewBuilder
    private var statusActions: some View {
        let showLearn = isThisSession && session.autoSync && ![.ended, .micLost, .ending].contains(displayPhase)
        let showResume = resumableRecord != nil
        if isEnding || showLearn || showResume {
            HStack(spacing: 8) {
                if isEnding {
                    Button { session.keepListening() } label: {
                        Label("Keep listening", systemImage: "ear.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(Color.subtextTheme)
                }
                if showResume, let record = resumableRecord {
                    Button { resumeLastSession(record) } label: {
                        Label("Resume last session", systemImage: "memories").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                if showLearn {
                    learnRoomButton
                }
            }
            .controlSize(.small)
            .buttonBorderShape(.capsule)
        }
    }

    private var learnRoomButton: some View {
        Button {
            guard learningUntil == nil else { return }
            engine.learnRoom()
            learningUntil = .now.addingTimeInterval(5)
            Task {
                try? await Task.sleep(for: .seconds(5))
                learningUntil = nil
            }
        } label: {
            let now = Date.now
            if let until = learningUntil, until > now {
                HStack(spacing: 4) {
                    Text("Learning the room… ")
                    Text(timerInterval: now...until, countsDown: true, showsHours: false).monospacedDigit()
                }
                .frame(maxWidth: .infinity)
            } else {
                Label("Learn this room", systemImage: "waveform.and.magnifyingglass").frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.bordered)
        .disabled(learningUntil != nil)
        .accessibilityHint("Pause the film and let Subtext hear 5 s of the empty room.")
    }

    /// `session.last` for this track, if it is less than 12 h old and the lines are not
    /// already placed (critique §4.3; latch.md §7 step 3).
    private var resumableRecord: LastSessionRecord? {
        guard let record = lastRecord, record.trackID == track.id,
              Date.now.timeIntervalSince(record.wall) < 12 * 3600 else { return nil }
        if isThisSession, session.isPlaced, session.phase != .ended { return nil }
        return record
    }

    private func resumeLastSession(_ record: LastSessionRecord) {
        let starting = !isThisSession
        if starting { session.start(track: track) }
        // Places the clock and lines at the remembered spot and seeds the tracker there; the
        // tracker's ±3 s / ±15 s radii pick up the real position from the room.
        // TODO(WP7): prefer `engine.seedHint(mediaTime:)` + lockedIn with a check-in at +15 s
        // (critique C3 "seed/jump/seek" row) once the scheduler exists.
        session.seek(to: record.media)
        guard starting else { return }
        // `session.start` brings the engine up asynchronously (mic permission, new tracker), so
        // the seed above reached no tracker. Re-seed at the clock's current position once the
        // engine runs (≤ 10 s); the clock and lines are already placed either way.
        Task {
            for _ in 0..<100 where !engine.isRunning {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard engine.isRunning, session.isActive, session.track?.id == track.id else { return }
            engine.seed(mediaTime: session.clock.mediaTime())
        }
    }

    /// A's rule for `rateConfirmed` (≥ 120 s of tracking) from the UI's own observation.
    private var rateConfirmedProxy: Bool {
        guard let since = lockedSince else { return false }
        return Date.now.timeIntervalSince(since) >= 120
    }

    // MARK: Toast

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            Text(toast)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .padding(.horizontal, 16).padding(.vertical, 10)
                .glassEffect(.regular, in: .capsule)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func showToast(_ text: String) {
        toastTask?.cancel()
        withAnimation(.snappy) { toast = text }
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut) { toast = nil }
        }
    }

    /// `lastCatchUp` is the signed correction (measured − predicted): a pause the film took
    /// puts the real position behind the clock, so it reads "Caught up −38 s".
    static func catchUpLabel(_ seconds: Double) -> String {
        let n = Int(abs(seconds).rounded())
        return "Caught up \(seconds < 0 ? "−" : "+")\(n) s"
    }

    // MARK: Cue

    private var cueCard: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            let media = session.mediaTime(at: context.date)
            let placed = isThisSession && session.snapshot().placed
            let current = placed ? track.cueIndex(at: media) : nil
            let next = current.map { i in track.nextCueIndex(after: track.cues[i].end - 0.001).flatMap { $0 > i ? $0 : nil } } ?? (placed ? track.nextCueIndex(after: media) : nil)
            let dimmed = session.clock.isPaused || session.phase == .drifting || (placed && session.phase == .searching)
            VStack(alignment: .leading, spacing: 10) {
                // No placeholder text: an empty slot of fixed height (island.md §5.9).
                Text(current.map { track.cues[$0].text } ?? "")
                    .font(.title2.weight(.medium))
                    .foregroundStyle(.primary)
                    .opacity(dimmed ? 0.55 : 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: 70, alignment: .topLeading)
                    .contentTransition(.opacity)
                    .animation(.easeOut(duration: 0.15), value: current)
                if placed, let next {
                    Text(track.cues[next].text)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .opacity(dimmed ? 0.55 : 1)
                        .lineLimit(2)
                }
                HStack {
                    Text(timeLabel(media)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    Button { showingSeek = true } label: {
                        Label("Set position", systemImage: "scope").font(.caption)
                    }
                }
            }
            .padding()
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
            .contentShape(Rectangle())
            .onTapGesture { openTheater() }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Opens Theater")
        }
    }

    // MARK: Trim

    private var trimCard: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Timing").font(.subheadline.weight(.semibold))
                Spacer()
                Text(session.trim.trimLabel)
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Color.subtextTheme)
            }
            ScrubWheel(value: Binding(get: { session.trim }, set: { session.setTrim($0) }))
                .frame(height: 64)
            HStack(spacing: 8) {
                stepper(-1, "−1s"); stepper(-0.5, "−½"); stepper(-0.1, "−.1")
                Spacer(minLength: 0)
                stepper(0.1, "+.1"); stepper(0.5, "+½"); stepper(1, "+1s")
            }
            Text("Drag the wheel to shift lines earlier or later. Negative shows them sooner.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding()
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private func stepper(_ seconds: Double, _ label: String) -> some View {
        Button(label) { session.nudge(seconds) }
            .font(.subheadline.weight(.semibold).monospacedDigit())
            .fixedSize()
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
    }

    // MARK: Controls

    /// WP5 presents `TheaterView` as a full-screen cover over the root (`SubtextApp`), so the
    /// button, the cue card and the `subtext://theater` deep link all go through
    /// `TheaterNavigation`; a second cover here would present the stage twice.
    private func openTheater() {
        if !isThisSession { session.start(track: track) }
        TheaterNavigation.shared.present()
    }

    private var theaterButton: some View {
        Button { openTheater() } label: {
            Label("Theater", systemImage: "captions.bubble.fill").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(Color.subtextTheme)
        .controlSize(.large)
        .buttonBorderShape(.capsule)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button { session.resync() } label: {
                Label("Re-sync", systemImage: "arrow.triangle.2.circlepath").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            Button { showingLines = true } label: {
                Label("Tap the line", systemImage: "text.line.first.and.arrowtriangle.forward").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            Button { session.togglePause() } label: {
                Image(systemName: session.clock.isPaused ? "play.fill" : "pause.fill").frame(width: 24)
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.large)
        .buttonBorderShape(.capsule)
    }

    // MARK: Options (V1 toggles + engine row)

    private var options: some View {
        VStack(spacing: 0) {
            Toggle("Auto-sync by listening", isOn: $session.autoSync)
                .padding(.vertical, 8)
            Divider()
            Toggle("Use speech to find the scene", isOn: $session.useSpeech)
                .padding(.vertical, 8)
                .disabled(!LiveTranscriber.isAvailable)
            Divider()
            Toggle("Live Activity & Dynamic Island", isOn: $session.liveActivityEnabled)
                .padding(.vertical, 8)
            Divider()
            Toggle("Speed-watching (1.25×–2×)", isOn: $session.speedWatching)
                .padding(.vertical, 8)
            Divider()
            Picker("Audio language", selection: $session.audioLocale) {
                ForEach(locales, id: \.identifier) { locale in
                    Text(locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier).tag(locale)
                }
                if !locales.contains(where: { $0.identifier == session.audioLocale.identifier }) {
                    Text(session.audioLocale.identifier).tag(session.audioLocale)
                }
            }
            .padding(.vertical, 8)
            if session.debugShowEngine {
                Divider()
                engineRow
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    /// Settings › Advanced "Show the engine row": tracker note (incl. `sig r/thr`), presence
    /// features `L D M V Fx Δtv Δroom E` + latch state, mic and scheduler states.
    private var engineRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Engine").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(engine.note.isEmpty ? "—" : engine.note).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(presenceLine).font(.caption2.monospacedDigit()).foregroundStyle(.secondary).lineLimit(2)
            Text(stateLine).font(.caption2.monospacedDigit()).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(.vertical, 8)
    }

    private var presenceLine: String {
        guard let f = engine.presenceFeatures else { return "presence: no features yet" }
        func opt(_ v: Float?) -> String { v.map { String(format: "%.1f", $0) } ?? "–" }
        let e = f.expectedDialogue.map { String(format: "%.2f", $0) } ?? "–"
        return String(format: "L %.1f D %.1f M %.2f V %.2f Fx %.1f Δtv %@ Δroom %@ E %@ · %@",
                      f.level, f.depth, f.modRatio, f.speechFraction, f.fluxSpread,
                      opt(f.tvDistance), opt(f.roomDistance), e, "\(f.evidence)")
    }

    private var stateLine: String {
        let residual = engine.lastResidual.map { String(format: " r %+.2f", $0) } ?? ""
        let coverage = session.memoryEnabled ? String(format: " mem %.0f%%", engine.memoryCoverage * 100) : ""
        return "\(engine.schedulerState) · \(engine.presenceState) · mic \(engine.micState) · tick \(engine.tickCount)\(residual)\(coverage)"
    }

    private func timeLabel(_ seconds: Double) -> String {
        let t = max(0, Int(seconds))
        return String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
    }
}

// MARK: - session.last

/// The `session.last` record (critique §4.3: `{trackID, media, wall, rate, reason}`), JSON in
/// UserDefaults. WP7 writes it ≤ every 5 s while locked and on every hold/end; the app reads
/// it for "Resume last session" (< 12 h old) and the hinted relaunch.
struct LastSessionRecord: Codable, Equatable {
    var trackID: UUID
    /// Media time at `wall` (the frozen position when the session was held or ended).
    var media: Double
    var wall: Date
    var rate: Double
    /// "running", "paused", "autoPaused", "ended", … — free text for the UI and logs.
    var reason: String

    static func load(from data: Data?) -> LastSessionRecord? {
        guard let data else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let record = try? decoder.decode(LastSessionRecord.self, from: data) { return record }
        return try? JSONDecoder().decode(LastSessionRecord.self, from: data)
    }

    func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(self)
    }
}

// MARK: - Mic meter

private struct MicMeter: View {
    let level: Double
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(level * 5 > Double(i) ? Color.subtextTheme : Color.secondary.opacity(0.25))
                    .frame(width: 4, height: CGFloat(6 + i * 4))
            }
        }
        .animation(.linear(duration: 0.1), value: level)
        .accessibilityLabel("Microphone level")
    }
}

// MARK: - Scrub wheel

/// A horizontal ruler the user drags; 0.1 s per tick, with a haptic click on each tick.
struct ScrubWheel: View {
    @Binding var value: Double
    @State private var dragStart: Double?
    @State private var lastTick: Int = 0

    private let pointsPerSecond: CGFloat = 120
    private let generator = UISelectionFeedbackGenerator()

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let centre = width / 2
            let offset = CGFloat(value) * pointsPerSecond
            ZStack {
                Canvas { context, size in
                    let visibleSeconds = Double(size.width / pointsPerSecond) + 1
                    let first = Int(((value - visibleSeconds / 2) * 10).rounded(.down))
                    let last = Int(((value + visibleSeconds / 2) * 10).rounded(.up))
                    for tick in first...last {
                        let seconds = Double(tick) / 10
                        let x = centre + CGFloat(seconds) * pointsPerSecond - offset
                        let major = tick % 10 == 0
                        let half = tick % 5 == 0
                        let height: CGFloat = major ? 26 : (half ? 16 : 9)
                        var path = Path()
                        path.move(to: CGPoint(x: x, y: size.height / 2 - height / 2))
                        path.addLine(to: CGPoint(x: x, y: size.height / 2 + height / 2))
                        context.stroke(path, with: .color(major ? .primary : .secondary.opacity(0.6)), lineWidth: major ? 2 : 1)
                        if major {
                            let label = Text(seconds.trimLabel).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            context.draw(label, at: CGPoint(x: x, y: size.height - 6))
                        }
                    }
                }
                Rectangle()
                    .fill(Color.subtextTheme)
                    .frame(width: 2, height: 40)
                    .offset(y: -6)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { drag in
                        if dragStart == nil {
                            dragStart = value
                            lastTick = Int((value * 10).rounded())
                            generator.prepare()
                        }
                        let raw = (dragStart ?? 0) - Double(drag.translation.width / pointsPerSecond)
                        let snapped = (raw * 10).rounded() / 10
                        let tick = Int((snapped * 10).rounded())
                        if tick != lastTick {
                            generator.selectionChanged()
                            lastTick = tick
                        }
                        if snapped != value { value = max(-30, min(30, snapped)) }
                    }
                    .onEnded { _ in dragStart = nil }
            )
        }
        .accessibilityElement()
        .accessibilityLabel("Timing offset")
        .accessibilityValue(value.trimLabel)
        .accessibilityAdjustableAction { direction in
            value += direction == .increment ? 0.1 : -0.1
        }
    }
}

// MARK: - Tap the line

struct CueListView: View {
    let track: SubtitleTrack
    @State private var session = SessionController.shared
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var rows: [Cue] {
        if query.isEmpty { return track.cues }
        return track.cues.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(rows) { cue in
                    Button {
                        session.jump(toCue: cue.id)
                        dismiss()
                    } label: {
                        HStack(alignment: .top) {
                            Text(timeLabel(cue.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                            Text(cue.text).foregroundStyle(cue.id == session.currentIndex ? Color.subtextTheme : .primary)
                        }
                    }
                    .id(cue.id)
                }
                .searchable(text: $query, prompt: "Find a line")
                .onAppear {
                    if let current = session.currentIndex { proxy.scrollTo(current, anchor: .center) }
                }
            }
            .navigationTitle("Tap the line you hear")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func timeLabel(_ seconds: Double) -> String {
        let t = Int(seconds)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}

// MARK: - Seek

struct SeekSheet: View {
    let track: SubtitleTrack
    @State private var session = SessionController.shared
    @Environment(\.dismiss) private var dismiss
    @State private var position: Double = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text(timeLabel(position)).font(.system(size: 44, weight: .light).monospacedDigit())
                Slider(value: $position, in: 0...max(1, track.duration))
                Text(track.cueIndex(at: position).map { track.cues[$0].text } ?? track.nextCueIndex(after: position).map { "Next: " + track.cues[$0].text } ?? "")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(minHeight: 50)
                Text("Match this to the player's time display. Auto-sync then fine-tunes from here.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Spacer()
            }
            .padding()
            .navigationTitle("Set position")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Set") { session.seek(to: position); dismiss() } }
            }
            .onAppear { position = max(0, session.mediaTime()) }
        }
        .presentationDetents([.medium])
    }

    private func timeLabel(_ seconds: Double) -> String {
        let t = Int(seconds)
        return String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
    }
}
