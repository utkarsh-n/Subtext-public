import SwiftUI

/// One-time legend under the status card (island.md §5.9): the Island shows only a dot and a
/// line now, so the four dot states are explained once. Dismissing sets `legend.seen`.
struct LegendCard: View {
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("What the dot means").font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                }
                .accessibilityLabel("Dismiss legend")
            }
            row(.listening, false, "White, pulsing", "Listening for the film")
            row(.locked, false, "Amber", "In sync — the line you see is the line you hear")
            row(.autoPaused, true, "Hollow", "Paused — catches up when the film does")
            row(.micLost, false, "Red", "Microphone lost — open Subtext")
        }
        .padding()
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private func row(_ phase: SyncPhase, _ paused: Bool, _ name: String, _ meaning: String) -> some View {
        HStack(spacing: 12) {
            BeaconPuck(phase: phase, isPaused: paused, size: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.footnote.weight(.medium))
                Text(meaning).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// WP5's `BeaconLive` on a small dark puck. The beacon's white states are drawn for the
/// Island's black glass; the puck keeps them visible on a light Now Playing card and reads as
/// a miniature of the Island, which is what the legend explains.
struct BeaconPuck: View {
    let phase: SyncPhase
    var isPaused = false
    var level: Double = 0
    var size: CGFloat = 12

    var body: some View {
        BeaconLive(phase: phase, isPaused: isPaused, level: level, size: size)
            .frame(width: size * 2.8, height: size * 2.8)
            .background(Circle().fill(Color.black.opacity(0.85)))
            .frame(width: size * 2.8, height: size * 2.8)
    }
}
