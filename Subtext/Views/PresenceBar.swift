import SwiftUI

/// Two-segment presence bar (latch.md §9): room ⟷ film, with the live level as the thumb.
/// The thumb sits by the profile distances when the session has learned both profiles
/// (closer to "Film" when the sound looks like the TV did earlier), and by the plain mic
/// level until then. Pure display; nothing here decides anything.
struct PresenceBar: View {
    var features: PresenceFeatures?
    var state: PresenceState
    var micLevel: Double

    /// 0 = room-like, 1 = film-like.
    private var position: Double {
        if let f = features, let tv = f.tvDistance, let room = f.roomDistance, tv + room > 0 {
            return min(1, max(0, Double(room / (tv + room))))
        }
        if let f = features, f.level > 0 {
            // Level above floor: 0 dB → room, ≥ 20 dB → film-like.
            return min(1, max(0, Double(f.level) / 20))
        }
        return min(1, max(0, micLevel))
    }

    private var filmSide: Bool {
        switch state {
        case .playing, .resuming: true
        default: false
        }
    }

    private var evidenceLabel: String {
        guard let f = features else { return "" }
        switch f.evidence {
        case .present: return "film"
        case .absent: return "nothing playing"
        case .hold: return "voices in the room"
        case .none: return ""
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    HStack(spacing: 2) {
                        Capsule().fill(Color.secondary.opacity(0.18))
                        Capsule().fill(filmSide ? Color.subtextTheme.opacity(0.35) : Color.secondary.opacity(0.18))
                    }
                    .frame(height: 6)
                    Circle()
                        .fill(filmSide ? Color.subtextTheme : Color.secondary)
                        .frame(width: 12, height: 12)
                        .offset(x: max(0, min(w - 12, CGFloat(position) * (w - 12))))
                        .animation(.easeOut(duration: 0.25), value: position)
                }
                .frame(height: 12)
            }
            .frame(height: 12)
            HStack {
                Text("Room").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if !evidenceLabel.isEmpty {
                    Text(evidenceLabel).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text("Film").font(.caption2).foregroundStyle(filmSide ? Color.subtextTheme : .secondary)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Presence")
        .accessibilityValue(filmSide ? "Hearing the film" : "Not hearing the film")
    }
}
