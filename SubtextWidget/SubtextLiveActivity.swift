import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

// The Live Activity (docs/v2/island.md §3 with critique C7 / C14 / C16 and §4.2).
//
// Rules: no phase words anywhere on the Island — the beacon carries the state, the only strings
// are cue text, the trim / rate label and button labels. The cue slot is an empty area of fixed
// height between lines, never a placeholder. Short captions may sit *under* the slot for states
// a dot alone cannot explain (stale, auto-paused, ending, ended, mic lost), never in it.

private let theaterURL = URL(string: "subtext://theater")!

struct SubtextLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SubtextActivityAttributes.self) { context in
            LockScreenView(title: context.attributes.title, state: context.state, stale: context.isStale)
                .activityBackgroundTint(Color.black.opacity(0.78))
                .activitySystemActionForegroundColor(Color.subtextTheme)
                .widgetURL(theaterURL)
        } dynamicIsland: { context in
            let s = context.state
            let stale = context.isStale
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        BeaconWithRing(state: s, size: CGFloat(IslandLayout.beaconExpanded))
                        Text(context.attributes.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TrailingLabel(state: s)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        CueBlock(state: s)
                        Caption(state: s, stale: stale)
                        ControlRow(state: s, stale: stale)
                    }
                    .padding(.top, 2)
                }
            } compactLeading: {
                Beacon(phase: s.phase, isPaused: s.isPaused, beat: s.beat, cueIndex: s.cueIndex, size: CGFloat(IslandLayout.beaconCompact))
                    .padding(.leading, 2)
                    .widgetURL(theaterURL)
            } compactTrailing: {
                CompactTrailing(state: s)
                    .widgetURL(theaterURL)
            } minimal: {
                Beacon(phase: s.phase, isPaused: s.isPaused, beat: s.beat, cueIndex: s.cueIndex, size: CGFloat(IslandLayout.beaconMinimal))
                    .widgetURL(theaterURL)
            }
            .keylineTint(Color.subtextTheme)
        }
        .supplementalActivityFamilies([.small])
    }
}

// MARK: - Compact

/// The current line on one row, or a clear spacer of `compactEmptyWidth` so the pill reads as
/// "just the dot". Dimmed while the clock is held.
private struct CompactTrailing: View {
    let state: IslandState

    var body: some View {
        // iOS 27 landscape: the pill cannot grow, show only the dot. The environment key lives in
        // WidgetKit (not SwiftUI), iOS 27+ — verified against the iPhoneSimulator27.0 SDK.
        if #available(iOS 27, *) { LimitedWidthAware(state: state) } else { body(limited: false) }
    }

    @ViewBuilder
    func body(limited: Bool) -> some View {
        if let text = IslandLayout.compactTrailing(state, limitedWidth: limited) {
            Text(text)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
                .frame(maxWidth: IslandLayout.compactMaxWidth)
                .opacity(IslandLayout.dimsText(state) ? 0.55 : 1)
                .contentTransition(.opacity)
        } else {
            Color.clear.frame(width: IslandLayout.compactEmptyWidth, height: 1)
        }
    }
}

@available(iOS 27, *)
private struct LimitedWidthAware: View {
    @Environment(\.isDynamicIslandLimitedInWidth) private var limited
    let state: IslandState
    var body: some View { CompactTrailing(state: state).body(limited: limited) }
}

// MARK: - Expanded pieces

/// Trim (amber: a human correction) or rate (secondary); under it the next-check-in countdown.
private struct TrailingLabel: View {
    let state: IslandState

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if let label = IslandLayout.trailingLabel(state) {
                Text(label)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(state.trim != 0 ? Color.subtextTheme : .secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            if let next = state.nextCheckInAt, next > .now {
                Text(timerInterval: Date.now...next, countsDown: true, showsHours: false)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44)
                    .multilineTextAlignment(.trailing)
            }
        }
    }
}

/// The cue slot: the current line, or an empty area of `cueMinHeight`. Never a placeholder.
private struct CueBlock: View {
    let state: IslandState

    var body: some View {
        let block = IslandLayout.cueBlock(state)
        VStack(alignment: .leading, spacing: 4) {
            Text(block.primary ?? "")
                .font(.title3.weight(.medium))
                .lineLimit(3)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, minHeight: IslandLayout.cueMinHeight, alignment: .leading)
                .contentTransition(.opacity)
            if let secondary = block.secondary {
                Text(secondary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .opacity(IslandLayout.dimsText(state) ? 0.55 : 1)
    }
}

/// A caption under the slot (critique C16): stale, auto-paused, ending (with countdown),
/// ended, microphone lost. Nothing for the live states.
private struct Caption: View {
    let state: IslandState
    let stale: Bool

    var body: some View {
        if stale {
            Text(IslandLayout.staleCaption)
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else if let caption = IslandLayout.caption(state) {
            HStack(spacing: 6) {
                Text(caption)
                if state.phase == .ending, let endsAt = state.endsAt, endsAt > .now {
                    Text(timerInterval: Date.now...endsAt, countsDown: true, showsHours: false)
                        .monospacedDigit()
                        .frame(width: 44)
                        .multilineTextAlignment(.leading)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }
}

/// Controls per `IslandLayout.controls`. A stale activity (the process may be gone) shows the
/// Open link only, since intents could not run.
private struct ControlRow: View {
    let state: IslandState
    let stale: Bool

    var body: some View {
        let plan = stale ? ControlPlan(nudges: false, prominent: .openApp, pauseButton: false) : IslandLayout.controls(state)
        if plan.hasControls {
            HStack(spacing: 6) {
                if plan.nudges {
                    NudgeButton(seconds: -0.5, label: "−½")
                    NudgeButton(seconds: -0.1, label: "−.1")
                }
                prominent(plan.prominent)
                if plan.nudges {
                    NudgeButton(seconds: 0.1, label: "+.1")
                    NudgeButton(seconds: 0.5, label: "+½")
                }
                if plan.pauseButton {
                    Button(intent: TogglePauseIntent()) {
                        Image(systemName: "pause.fill")
                            .font(.caption.weight(.semibold))
                            .frame(width: 22)
                    }
                    .buttonStyle(IslandButtonStyle(prominent: false))
                }
            }
        }
    }

    @ViewBuilder
    private func prominent(_ action: ProminentAction) -> some View {
        switch action {
        case .resync:
            Button(intent: ResyncIntent()) { ProminentLabel(action) }.buttonStyle(IslandButtonStyle(prominent: true))
        case .listen:
            Button(intent: ResyncIntent()) { ProminentLabel(action) }.buttonStyle(IslandButtonStyle(prominent: true))
        case .resume:
            Button(intent: ResumeIntent()) { ProminentLabel(action) }.buttonStyle(IslandButtonStyle(prominent: true))
        case .pause:
            Button(intent: TogglePauseIntent()) { ProminentLabel(action) }.buttonStyle(IslandButtonStyle(prominent: true))
        case .keepListening:
            Button(intent: KeepListeningIntent()) { ProminentLabel(action) }.buttonStyle(IslandButtonStyle(prominent: true))
        case .openApp:
            Link(destination: theaterURL) { ProminentLabel(action) }.buttonStyle(IslandButtonStyle(prominent: true))
        case .none:
            EmptyView()
        }
    }
}

private struct ProminentLabel: View {
    let action: ProminentAction
    init(_ action: ProminentAction) { self.action = action }
    var body: some View {
        Label(action.label, systemImage: action.symbol)
            .font(.caption.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
    }
}

private struct NudgeButton: View {
    let seconds: Double
    let label: String
    var body: some View {
        Button(intent: NudgeSyncIntent(seconds: seconds)) {
            Text(label)
                .font(.caption.weight(.semibold).monospacedDigit())
                .frame(minWidth: 30)
        }
        .buttonStyle(IslandButtonStyle(prominent: false))
    }
}

private struct IslandButtonStyle: ButtonStyle {
    let prominent: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, 7)
            .padding(.horizontal, 6)
            .background(
                Capsule().fill(prominent ? Color.subtextTheme.opacity(0.9) : Color.white.opacity(0.14))
            )
            .foregroundStyle(prominent ? Color.black : Color.white)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

// MARK: - Lock Screen / StandBy / Watch

private struct LockScreenView: View {
    @Environment(\.activityFamily) private var family
    let title: String
    let state: IslandState
    let stale: Bool

    var body: some View {
        if family == .small {
            watch
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    BeaconWithRing(state: state, size: CGFloat(IslandLayout.beaconExpanded))
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    TrailingLabel(state: state)
                }
                CueBlock(state: state)
                Caption(state: state, stale: stale)
                ControlRow(state: state, stale: stale)
            }
            .padding(16)
        }
    }

    /// Apple Watch Smart Stack: the dot, the words, exactly one control (WWDC24). The hollow
    /// dot gets its accessibility label as a caption here, since nothing else on the wrist can
    /// explain it; that caption never goes in the cue slot.
    private var watch: some View {
        HStack(alignment: .top, spacing: 8) {
            Beacon(phase: state.phase, isPaused: state.isPaused, beat: state.beat, cueIndex: state.cueIndex, size: CGFloat(IslandLayout.beaconWatch))
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                if !state.currentText.isEmpty {
                    Text(state.currentText)
                        .font(.headline)
                        .lineLimit(3)
                        .minimumScaleFactor(0.8)
                        .opacity(IslandLayout.dimsText(state) ? 0.55 : 1)
                } else if stale {
                    Text(IslandLayout.staleCaption).font(.caption2).foregroundStyle(.secondary)
                } else if state.isPaused || state.phase == .autoPaused || state.phase == .micLost || state.phase == .ending || state.phase == .ended {
                    Text(BeaconStyle(phase: state.phase, isPaused: state.isPaused).accessibilityLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if !state.currentText.isEmpty, !state.nextText.isEmpty {
                    Text(state.nextText).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if !stale {
                switch state.phase {
                case .ending:
                    Button(intent: KeepListeningIntent()) { Image(systemName: "ear.badge.waveform") }
                        .buttonStyle(.plain).font(.caption)
                case .ended, .micLost:
                    EmptyView()
                default:
                    if state.isPaused {
                        Button(intent: ResumeIntent()) { Image(systemName: "play.fill") }
                            .buttonStyle(.plain).font(.caption)
                    } else {
                        Button(intent: ResyncIntent()) { Image(systemName: "arrow.triangle.2.circlepath") }
                            .buttonStyle(.plain).font(.caption)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Previews

private func previewState(_ phase: SyncPhase, paused: Bool = false, beat: Int = 0, text: String = "") -> IslandState {
    IslandState(currentText: text, nextText: "", cueIndex: 3, cueCount: 100, trim: 0, phase: phase, isPaused: paused, rate: 1, beat: beat,
                pauseReason: paused ? (phase == .autoPaused ? .auto : .user) : .none,
                endsAt: phase == .ending ? .now.addingTimeInterval(110) : nil)
}

#Preview("Compact", as: .dynamicIsland(.compact), using: SubtextActivityAttributes(title: "Film", language: "en")) {
    SubtextLiveActivity()
} contentStates: {
    previewState(.listening, beat: 1)
    previewState(.listening, beat: 2)
    previewState(.searching, beat: 3)
    previewState(.locked, text: "Still in the vault, where it's been since nineteen fifty-two.")
    previewState(.locked)
    previewState(.checkingIn, beat: 2, text: "Get down!")
    previewState(.paused, paused: true, text: "What was that?")
    previewState(.autoPaused, paused: true, text: "What was that?")
    previewState(.recovering, paused: true, beat: 2, text: "What was that?")
    previewState(.drifting, beat: 1, text: "Stay low.")
    previewState(.ending, paused: true)
    previewState(.ended, paused: true)
    previewState(.manual, text: "It's quiet now.")
    previewState(.micLost)
}

#Preview("Expanded", as: .dynamicIsland(.expanded), using: SubtextActivityAttributes(title: "Film", language: "en")) {
    SubtextLiveActivity()
} contentStates: {
    previewState(.searching, beat: 2)
    previewState(.locked, text: "Still in the vault, where it's been since nineteen fifty-two.")
    previewState(.locked)
    previewState(.autoPaused, paused: true, text: "What was that?")
    previewState(.ending, paused: true)
    previewState(.ended, paused: true)
    previewState(.micLost)
}

#Preview("Lock Screen", as: .content, using: SubtextActivityAttributes(title: "Film", language: "en")) {
    SubtextLiveActivity()
} contentStates: {
    previewState(.listening, beat: 2)
    previewState(.locked, text: "Still in the vault, where it's been since nineteen fifty-two.")
    previewState(.ending, paused: true)
}
