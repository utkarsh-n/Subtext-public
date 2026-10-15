import SwiftUI

/// The "Lines…" sheet (docs/v2/island.md §5.7): a dark list of the cues around the current one,
/// 44 pt rows with a clock, tap = that line starts now. No search field (the library's
/// `CueListView` remains for "I'm lost").
struct TheaterReel: View {
    let track: SubtitleTrack
    @State private var session = SessionController.shared
    @Environment(\.dismiss) private var dismiss

    private var range: Range<Int> {
        let media = session.mediaTime()
        let centre = track.cueIndex(at: media) ?? track.nextCueIndex(after: media) ?? max(0, track.cues.count - 1)
        return max(0, centre - 8)..<min(track.cues.count, centre + 13)
    }

    var body: some View {
        let media = session.mediaTime()
        let current = track.cueIndex(at: media)
        ScrollViewReader { proxy in
            List {
                ForEach(range, id: \.self) { i in
                    let cue = track.cues[i]
                    Button {
                        session.jump(toCue: i)
                        dismiss()
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(TheaterLogic.clockLabel(cue.start))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(i == current ? Color.subtextTheme : .secondary)
                                .frame(width: 52, alignment: .trailing)
                            Text(cue.text)
                                .font(.body)
                                .foregroundStyle(i == current ? Color.subtextTheme : .white)
                                .lineLimit(2)
                            Spacer(minLength: 0)
                        }
                        .frame(minHeight: 44)
                    }
                    .listRowBackground(Color.black)
                    .id(i)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .onAppear { if let current { proxy.scrollTo(current, anchor: .center) } }
        }
        .presentationDetents([.medium])
        .presentationBackground(.black)
        .preferredColorScheme(.dark)
    }
}
