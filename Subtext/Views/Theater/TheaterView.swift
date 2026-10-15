import SwiftUI
import UIKit

/// How the Theater gets opened: the Theater button (WP6's NowPlayingView calls `present()`),
/// the `subtext://theater` deep link from the Island, or the Live Activity's default tap.
/// `SubtextApp` presents it as a full-screen cover over the root.
@MainActor
@Observable
final class TheaterNavigation {
    static let shared = TheaterNavigation()

    /// The `NSUserActivity.activityType` the system hands the app for a Live Activity tap with no
    /// deep link (ActivityKit documents the constant `NSUserActivityTypeLiveActivity`; the Xcode 27
    /// beta SDK does not export the symbol, so its string value is spelled out).
    static let liveActivityUserActivityType = "NSUserActivityTypeLiveActivity"

    var isPresented = false

    func present() {
        guard SessionController.shared.isActive else { return }
        isPresented = true
    }

    /// `subtext://theater` → present. Returns true when the URL is ours (any `subtext://` URL).
    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "subtext" else { return false }
        let target = (url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
        if target == "theater" { present() }
        return true
    }
}

/// The in-app stage (docs/v2/island.md §5): black, large lines, the beacon breathing top-left,
/// one-gesture re-sync. Tap the line you hear; drag sideways to trim; hold to listen again.
struct TheaterView: View {
    let track: SubtitleTrack
    @State private var session = SessionController.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var vSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct TrimDrag {
        let startTrim: Double
        var value: Double
        var detent: Int
    }
    private enum Axis { case horizontal, vertical }

    @State private var chromeVisible = true
    @State private var chromeHideTask: Task<Void, Never>?
    @State private var showReel = false
    @State private var drag: TrimDrag?
    @State private var axis: Axis?
    @State private var reelOffset = 0
    @State private var reelDecayTask: Task<Void, Never>?
    @State private var hud: TrimHUD.Model?
    @State private var holdStage = 0
    // Haptic triggers (incremented only when `theater.haptics` is on).
    @State private var detentTick = 0
    @State private var zeroCross = 0
    @State private var relistenPulse = 0
    @State private var resyncPulse = 0
    @State private var jumpPulse = 0
    @State private var lockedPulse = 0
    @State private var reelTick = 0
    @State private var confirmFlash = 0
    @State private var rippleScale: CGFloat = 1
    @State private var rippleOpacity: Double = 0

    private var landscape: Bool { vSize == .compact }
    private var textSize: TheaterLogic.TextSize { session.theaterTextSize_ }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
                let media = session.mediaTime(at: ctx.date)
                let reel = TheaterLogic.reel(track: track, media: media, placed: session.theaterPlaced, offset: reelOffset)
                TheaterLines(track: track, reel: reel, size: textSize, landscape: landscape,
                             dimmed: BeaconStyle.dimsLines(phase: session.phase, isPaused: session.clock.isPaused),
                             dragging: reelOffset != 0,
                             onTapCurrent: { confirm() },
                             onTapRow: { jump(to: $0) })
            }

            TheaterChrome(visible: chromeVisible, title: track.title, session: session,
                          onReel: { showReel = true; showChrome() },
                          onClose: { dismiss() },
                          onLandscape: { OrientationLock.requestLandscape() },
                          onPauseToggle: { session.togglePause(); session.syncBeat(); showChrome() },
                          onStep: { session.nudge($0); hud = .trim(session.trim, until: .now + TheaterLogic.hudSeconds); showChrome() })

            // Beacon, top-left. Tap = pause / resume.
            VStack {
                HStack {
                    ZStack {
                        Circle()
                            .stroke(Color.subtextTheme, lineWidth: 2)
                            .frame(width: 28, height: 28)
                            .scaleEffect(rippleScale)
                            .opacity(rippleOpacity)
                        BeaconLive(phase: session.phase, isPaused: session.clock.isPaused,
                                   level: session.engine.micLevel, flash: confirmFlash, size: CGFloat(IslandLayout.beaconTheater))
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .onTapGesture { session.togglePause(); session.syncBeat() }
                    .padding(.leading, 16)
                    .padding(.top, 8)
                    Spacer()
                }
                Spacer()
            }

            // HUD under the lines.
            if let hud {
                VStack {
                    Spacer()
                    TrimHUD(model: hud, onUndo: { session.undoJump(); self.hud = nil })
                        .padding(.bottom, landscape ? 70 : 120)
                }
                .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .gesture(stageDrag)
        .simultaneousGesture(relistenHold)
        .simultaneousGesture(resyncHold)
        .onTapGesture { toggleChrome() }
        .sensoryFeedback(.selection, trigger: detentTick)
        .sensoryFeedback(.alignment, trigger: zeroCross)
        .sensoryFeedback(.selection, trigger: reelTick)
        .sensoryFeedback(.start, trigger: relistenPulse)
        .sensoryFeedback(.impact(weight: .heavy), trigger: resyncPulse)
        .sensoryFeedback(.success, trigger: jumpPulse)
        .sensoryFeedback(.success, trigger: lockedPulse)
        .onChange(of: session.phase) { _, p in
            if p == .locked { if session.theaterHaptics { lockedPulse += 1 }; if case .text = hud { hud = nil } }
        }
        .sheet(isPresented: $showReel) { TheaterReel(track: track) }
        .animation(.easeInOut(duration: 0.2), value: hud)
        .task(id: hud) {
            guard let hud else { return }
            let wait = hud.until.timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            if !Task.isCancelled, self.hud == hud { self.hud = nil }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = session.theaterKeepAwake
            if session.theaterAllowLandscape { OrientationLock.allow(.allButUpsideDown) }
            scheduleChromeHide()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            OrientationLock.allow(.portrait)
            chromeHideTask?.cancel()
            reelDecayTask?.cancel()
        }
        .onChange(of: scenePhase) { _, p in UIApplication.shared.isIdleTimerDisabled = session.theaterKeepAwake && p == .active }
        .onChange(of: session.theaterKeepAwake) { _, on in UIApplication.shared.isIdleTimerDisabled = on && scenePhase == .active }
        .onChange(of: session.isActive) { _, active in if !active { dismiss() } }
    }

    // MARK: Gestures

    /// One drag for both axes: decided on the first callback. Horizontal = trim (anywhere),
    /// vertical = the reel (one row per 56 pt; drag down = earlier line).
    private var stageDrag: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .onChanged { g in
                if axis == nil {
                    axis = abs(g.translation.height) > abs(g.translation.width) ? .vertical : .horizontal
                    hideChrome()
                }
                switch axis {
                case .horizontal:
                    if drag == nil { drag = TrimDrag(startTrim: session.trim, value: session.trim, detent: Int((session.trim * 10).rounded())) }
                    guard var d = drag else { return }
                    let (v, detent) = TheaterLogic.trim(startTrim: d.startTrim, translationX: g.translation.width)
                    if v != d.value {
                        if session.theaterHaptics {
                            if TheaterLogic.crossedZero(from: d.value, to: v) { zeroCross += 1 } else { detentTick += 1 }
                        }
                        d.value = v
                        d.detent = detent
                        drag = d
                        session.previewTrim(v)   // in-app clock only; no Island push
                        hud = .trim(v, until: .now + TheaterLogic.hudSeconds)
                    }
                case .vertical:
                    let offset = TheaterLogic.reelOffset(translationY: g.translation.height)
                    if offset != reelOffset {
                        if session.theaterHaptics { reelTick += 1 }
                        reelOffset = offset
                    }
                case nil:
                    break
                }
            }
            .onEnded { _ in
                switch axis {
                case .horizontal:
                    if let d = drag { session.setTrim(d.value) }
                    drag = nil
                case .vertical:
                    if reelOffset != 0 {
                        let reel = TheaterLogic.reel(track: track, media: session.mediaTime(), placed: session.theaterPlaced, offset: reelOffset)
                        if let centre = reel.centre { jump(to: centre) }
                        reelOffset = 0
                    }
                case nil:
                    break
                }
                axis = nil
            }
    }

    /// Hold 0.6 s → listen again around here (lines stay; clock keeps running).
    private var relistenHold: some Gesture {
        LongPressGesture(minimumDuration: TheaterLogic.relistenHoldSeconds, maximumDistance: 10)
            .onEnded { _ in
                guard drag == nil, axis == nil else { return }
                holdStage = 1
                if session.theaterHaptics { relistenPulse += 1 }
                session.relisten()
                session.syncBeat()
                hud = .text("Listening again", until: .now + 4)
                ripple()
            }
    }

    /// Keep holding to 1.5 s → full search of the whole film.
    private var resyncHold: some Gesture {
        LongPressGesture(minimumDuration: TheaterLogic.resyncHoldSeconds, maximumDistance: 10)
            .onEnded { _ in
                guard drag == nil, axis == nil else { return }
                holdStage = 2
                if session.theaterHaptics { resyncPulse += 1 }
                session.resync()
                session.syncBeat()
                hud = .text("Searching the whole film", until: .now + 6)
                ripple()
            }
    }

    // MARK: Actions

    private func confirm() {
        session.confirmSync()
        confirmFlash += 1
        if session.theaterHaptics { lockedPulse += 1 }
    }

    private func jump(to index: Int) {
        session.jump(toCue: index)
        session.syncBeat()
        if session.theaterHaptics { jumpPulse += 1 }
        hud = .jumped(undoUntil: .now + TheaterLogic.undoWindowSeconds)
    }

    private func ripple() {
        guard !reduceMotion else { return }
        rippleScale = 1
        rippleOpacity = 0.6
        withAnimation(.easeOut(duration: 0.5)) {
            rippleScale = 3
            rippleOpacity = 0
        }
    }

    // MARK: Chrome

    private func toggleChrome() {
        if chromeVisible { hideChrome() } else { showChrome() }
    }

    private func showChrome() {
        chromeVisible = true
        scheduleChromeHide()
    }

    private func hideChrome() {
        chromeHideTask?.cancel()
        chromeVisible = false
    }

    private func scheduleChromeHide() {
        chromeHideTask?.cancel()
        chromeHideTask = Task {
            try? await Task.sleep(for: .seconds(TheaterLogic.chromeHideSeconds))
            if !Task.isCancelled { chromeVisible = false }
        }
    }
}
