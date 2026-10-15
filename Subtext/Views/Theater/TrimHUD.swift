import SwiftUI

/// The capsule under the lines (docs/v2/island.md §5.6): the trim value during a drag,
/// "Jumped · Undo" for 3 s after a tap-to-jump, or a short caption ("Listening again").
struct TrimHUD: View {
    enum Model: Hashable {
        case trim(Double, until: Date)
        case jumped(undoUntil: Date)
        case text(String, until: Date)

        var until: Date {
            switch self {
            case .trim(_, let u), .jumped(let u), .text(_, let u): u
            }
        }
    }

    let model: Model
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            switch model {
            case .trim(let value, _):
                Text(value.trimLabel)
                    .font(.title2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Color.subtextTheme)
            case .jumped:
                Text("Jumped")
                    .font(.headline)
                    .foregroundStyle(.white)
                Button("Undo", action: onUndo)
                    .font(.headline)
                    .foregroundStyle(Color.subtextTheme)
                    .buttonStyle(.plain)
            case .text(let caption, _):
                Text(caption)
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }
}
