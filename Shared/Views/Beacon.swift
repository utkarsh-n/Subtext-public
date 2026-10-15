import SwiftUI

// Compiled into the app and the widget (not the harness). The dot that replaces every phase
// word (docs/v2/island.md §2). Geometry: core 9 pt compact, 8 minimal, 12 expanded / Lock
// Screen, 7 Watch, 14 Theater. Gradients only: `.blur` in archived widget views is untested.

extension BeaconColor {
    var swiftUI: Color {
        switch self {
        case .white(let o): .white.opacity(o)
        case .amber(let o): Color.subtextTheme.opacity(o)
        case .red: Color("SubtextTrouble")
        }
    }
}

/// The beacon as the Island, Lock Screen and Watch draw it: animated only through the
/// mechanisms WidgetKit documents (insert/remove transitions, `animation(value:)`, `id`).
struct Beacon: View {
    let phase: SyncPhase
    let isPaused: Bool
    let beat: Int
    var cueIndex: Int = 0
    var size: CGFloat = 9
    @Environment(\.isLuminanceReduced) private var dim

    private var style: BeaconStyle { BeaconStyle(phase: phase, isPaused: isPaused) }
    private var color: Color { style.color.swiftUI }
    /// Bloom inserted on even beats, removed on odd ones. `beat` is 0 when the style does
    /// not pulse, so a non-pulsing state never carries a bloom.
    private var swell: Bool { style.pulses && beat != 0 && beat.isMultiple(of: 2) }

    var body: some View {
        ZStack {
            // 1. Bloom: insert/remove fades are the one animation Apple documents
            //    unconditionally; scale + opacity transitions are allowed.
            if !dim, swell {
                Circle()
                    .fill(RadialGradient(colors: [color.opacity(0.55), color.opacity(0)],
                                         center: .center, startRadius: 0, endRadius: size * 1.1))
                    .frame(width: size * 2.2, height: size * 2.2)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            // 2. Steady halo for glowing states.
            if !dim, style.glows {
                Circle()
                    .fill(RadialGradient(colors: [color.opacity(0.35), .clear], center: .center, startRadius: 0, endRadius: size))
                    .frame(width: size * 1.8, height: size * 1.8)
            }
            // 3. Core. Hollow when the clock is held, or under reduced luminance.
            Group {
                if style.hollow || dim {
                    Circle().strokeBorder(color, lineWidth: dim ? 1.5 : max(1.5, size * 0.18))
                } else {
                    Circle().fill(color)
                }
            }
            .frame(width: size, height: size)
            // Secondary layer: value-driven scale, documented as supported in Live Activities.
            .scaleEffect(swell ? 1.18 : 1.0)
            .animation(dim ? nil : .easeInOut(duration: 0.9), value: beat)
            // Locked "blink": a new identity per cue boundary → one transition per line change
            // with zero extra updates.
            .id(style.blinksOnCue ? cueIndex : -1)
            .transition(.scale(scale: 1.35).combined(with: .opacity))
        }
        .frame(width: size * 2.2, height: size * 2.2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(style.accessibilityLabel)
    }
}

/// Expanded leading and Lock Screen only (never compact / minimal / Watch): the beacon inside a
/// date-relative ring. `.listening` fills the first 45 s, `.schedule` fills from the last
/// check-in to the next, `.checkIn` drains over the analysis window. System-interpolated,
/// zero updates; built-in `.circular` only (date-relative progress has no custom styles).
struct BeaconWithRing: View {
    let state: IslandState
    var size: CGFloat = 12
    @Environment(\.isLuminanceReduced) private var dim

    var body: some View {
        if !dim, let ring = state.ring, state.ringKind != .none, ring.upperBound > .now {
            ProgressView(timerInterval: ring, countsDown: state.ringKind == .checkIn,
                         label: { EmptyView() },
                         currentValueLabel: {
                             Beacon(phase: state.phase, isPaused: state.isPaused, beat: state.beat, cueIndex: state.cueIndex, size: size * 0.75)
                         })
                .progressViewStyle(.circular)
                .tint(ringTint)
                .frame(width: size * 2.4, height: size * 2.4)
        } else {
            Beacon(phase: state.phase, isPaused: state.isPaused, beat: state.beat, cueIndex: state.cueIndex, size: size)
        }
    }

    private var ringTint: Color {
        switch state.ringKind {
        case .checkIn: .white.opacity(0.9)
        case .schedule: Color.subtextTheme.opacity(0.55)
        default: .white.opacity(0.35)
        }
    }
}
