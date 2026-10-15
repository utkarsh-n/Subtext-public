import SwiftUI

/// The Theater's bars (docs/v2/island.md §5.5 item 5): top — title, "Aa" menu, ×; bottom —
/// pause/play, trim steppers, "Lines…". Fades after 3 s; a tap on the stage brings it back.
/// Swipe down on the top bar (> 80 pt) closes the Theater; the × always works.
struct TheaterChrome: View {
    let visible: Bool
    let title: String
    @Bindable var session: SessionController
    let onReel: () -> Void
    let onClose: () -> Void
    let onLandscape: () -> Void
    let onPauseToggle: () -> Void
    let onStep: (Double) -> Void

    var body: some View {
        VStack {
            topBar
            Spacer()
            bottomBar
        }
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .animation(.easeInOut(duration: 0.25), value: visible)
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            // Room for the beacon, which sits at the top-left of the stage.
            Color.clear.frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer()
            Menu {
                Picker("Text size", selection: $session.theaterTextSize_) {
                    ForEach(TheaterLogic.TextSize.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("Keep screen awake", isOn: $session.theaterKeepAwake)
                Toggle("Show next line on the Island", isOn: $session.showNextLine)
                if session.theaterAllowLandscape {
                    Button { onLandscape() } label: { Label("Open in landscape", systemImage: "rectangle.landscape.rotate") }
                }
            } label: {
                Text("Aa")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .background(LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 20).onEnded { g in if g.translation.height > 80 { onClose() } })
    }

    /// In-app, words are fine: the phase label plus the engine note behind the debug switch.
    private var caption: String {
        if session.debugShowEngine, !session.engine.note.isEmpty { return "\(session.phase.label) · \(session.engine.note)" }
        return session.phase.label
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Button(action: onPauseToggle) {
                Image(systemName: session.clock.isPaused ? "play.fill" : "pause.fill")
                    .font(.title3.weight(.semibold))
                    .frame(width: 48, height: 44)
            }
            .accessibilityLabel(session.clock.isPaused ? "Resume" : "Pause")
            Spacer()
            Button { onStep(-0.5) } label: { Text("−½").font(.headline.monospacedDigit()).frame(width: 52, height: 44) }
            Text(session.trim.trimLabel)
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(session.trim == 0 ? .white.opacity(0.6) : Color.subtextTheme)
                .frame(minWidth: 54)
            Button { onStep(0.5) } label: { Text("+½").font(.headline.monospacedDigit()).frame(width: 52, height: 44) }
            Spacer()
            Button(action: onReel) {
                Label("Lines…", systemImage: "list.bullet")
                    .font(.subheadline.weight(.semibold))
                    .frame(height: 44)
            }
        }
        .foregroundStyle(.white)
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
    }
}
