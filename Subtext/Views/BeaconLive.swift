import SwiftUI

/// The in-app beacon (docs/v2/island.md §5.8): same geometry as `Beacon`, driven by
/// `TimelineView(.animation)` instead of beats. Pulsing states breathe with a 1.6 s period,
/// locked breathes slowly (4 s), held states are static and hollow; the halo brightens with the
/// microphone level; `flash` plays one 0.4 s amber bloom (tap-to-confirm). Reduce Motion → static.
struct BeaconLive: View {
    let phase: SyncPhase
    let isPaused: Bool
    /// `SyncEngine.micLevel`, 0…1.
    var level: Double = 0
    /// Increment to play one amber flash.
    var flash: Int = 0
    var size: CGFloat = 14
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flashAt: Date?

    private var style: BeaconStyle { BeaconStyle(phase: phase, isPaused: isPaused) }

    private var period: Double {
        if style.pulses { return 1.6 }
        if style.glows { return 4 }
        return 0
    }

    var body: some View {
        let animates = !reduceMotion && (period > 0 || flashAt != nil || level > 0)
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animates)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let breathe = (period > 0 && !reduceMotion) ? 0.5 + 0.5 * sin(2 * .pi * t / period) : 0
            let flashAge = flashAt.map { ctx.date.timeIntervalSince($0) } ?? 1
            let flashStrength = max(0, 1 - flashAge / 0.4)
            let color = style.color.swiftUI
            ZStack {
                // Bloom, breathing.
                if style.pulses, !reduceMotion {
                    Circle()
                        .fill(RadialGradient(colors: [color.opacity(0.5 * (0.4 + 0.6 * breathe)), color.opacity(0)],
                                             center: .center, startRadius: 0, endRadius: size * 1.1))
                        .frame(width: size * 2.2, height: size * 2.2)
                        .scaleEffect(1 + 0.35 * breathe)
                }
                // Halo: steady for glowing states, plus a real level meter.
                let haloOpacity = (style.glows ? 0.35 * (0.7 + 0.3 * breathe) : 0) + 0.35 * min(1, max(0, level))
                if haloOpacity > 0.01 {
                    Circle()
                        .fill(RadialGradient(colors: [color.opacity(haloOpacity), .clear], center: .center, startRadius: 0, endRadius: size))
                        .frame(width: size * 1.8, height: size * 1.8)
                        .scaleEffect(1 + 0.4 * min(1, max(0, level)))
                }
                // Confirm flash.
                if flashStrength > 0 {
                    Circle()
                        .fill(RadialGradient(colors: [Color.subtextTheme.opacity(0.7 * flashStrength), .clear], center: .center, startRadius: 0, endRadius: size * 1.4))
                        .frame(width: size * 2.8, height: size * 2.8)
                        .scaleEffect(1 + 0.6 * (1 - flashStrength))
                }
                // Core.
                Group {
                    if style.hollow {
                        Circle().strokeBorder(color, lineWidth: max(1.5, size * 0.18))
                    } else {
                        Circle().fill(color)
                    }
                }
                .frame(width: size, height: size)
                .scaleEffect(style.pulses && !reduceMotion ? 1 + 0.18 * breathe : 1)
            }
            .frame(width: size * 2.8, height: size * 2.8)
        }
        .onChange(of: flash) { _, _ in flashAt = .now }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(style.accessibilityLabel)
    }
}
