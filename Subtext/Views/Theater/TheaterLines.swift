import SwiftUI

/// The three slots of the stage (docs/v2/island.md §5.4): past (one dim row), current (large,
/// a fixed-height slot that never collapses between lines), next (dim, two rows). While unplaced
/// every slot is empty: the stage is black and only the beacon moves. No waiting copy anywhere.
struct TheaterLines: View {
    let track: SubtitleTrack
    let reel: TheaterLogic.Reel
    let size: TheaterLogic.TextSize
    let landscape: Bool
    /// Lines drawn at 0.55: the clock is held or the lock is doubtful.
    let dimmed: Bool
    /// The reel is being dragged (the centre row is drawn as "current" even between lines).
    let dragging: Bool
    let onTapCurrent: () -> Void
    let onTapRow: (Int) -> Void

    private var points: CGFloat { CGFloat(size.points) * (landscape ? 1.1 : 1) }
    private var side: CGFloat { landscape ? 64 : 32 }

    var body: some View {
        VStack(spacing: 18) {
            row(reel.row(.past), scale: 0.55, opacity: 0.22, lines: 1)
            currentRow
            row(reel.row(.next), scale: 0.55, opacity: 0.38, lines: 2)
        }
        .padding(.horizontal, side)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(dimmed ? 0.55 : 1)
        .contentTransition(.opacity)
        .animation(.easeOut(duration: 0.12), value: reel.row(.current))
    }

    private var currentRow: some View {
        let index = reel.row(.current)
        return Text(index.map { track.cues[$0].text } ?? "")
            .font(.system(size: points, weight: .semibold, design: .rounded))
            .foregroundStyle(dragging && index != reel.current ? Color.subtextTheme : .white)
            .multilineTextAlignment(.center)
            .lineLimit(4)
            .minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity, minHeight: points * 2.4)
            .contentShape(Rectangle())
            .onTapGesture {
                if let index, index == reel.current { onTapCurrent() } else if let index { onTapRow(index) }
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Tap if this is the line you hear")
    }

    private func row(_ index: Int?, scale: CGFloat, opacity: Double, lines: Int) -> some View {
        Text(index.map { track.cues[$0].text } ?? "")
            .font(.system(size: points * scale, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(opacity))
            .multilineTextAlignment(.center)
            .lineLimit(lines)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
            .onTapGesture { if let index { onTapRow(index) } }
            .accessibilityAddTraits(index == nil ? [] : .isButton)
            .accessibilityHint(index == nil ? "" : "Tap if this is the line you hear")
    }
}
