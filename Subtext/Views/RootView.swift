import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @State private var library = Library.shared
    @State private var session = SessionController.shared
    @State private var showingImporter = false
    @State private var showingSearch = false
    @State private var showingSettings = false
    @State private var importError: String?
    @State private var path: [SubtitleTrack] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if library.tracks.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("Subtext")
            .navigationDestination(for: SubtitleTrack.self) { track in
                NowPlayingView(track: track)
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showingSearch = true } label: { Image(systemName: "magnifyingglass") }
                    Button { showingImporter = true } label: { Image(systemName: "doc.badge.plus") }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if session.isActive, let track = session.track, path.last?.id != track.id {
                    nowShowingBar(track)
                }
            }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.plainText, .text, .data, .item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                for url in urls {
                    do { _ = try library.importFile(at: url) } catch { importError = error.localizedDescription }
                }
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
        .sheet(isPresented: $showingSearch) { OpenSubtitlesSearchView() }
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .alert("Could not import", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK") { importError = nil }
        } message: { Text(importError ?? "") }
    }

    private var list: some View {
        List {
            ForEach(library.tracks) { track in
                NavigationLink(value: track) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title).font(.headline)
                        Text("\(track.language.uppercased()) · \(track.cues.count) lines · \(durationLabel(track.duration))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { offsets in
                offsets.map { library.tracks[$0] }.forEach { library.remove($0) }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No subtitles yet", systemImage: "captions.bubble")
        } description: {
            Text("Import an .srt, .vtt or .ass file, or search OpenSubtitles. Then press play on the TV and Subtext listens to the room to follow along.")
        } actions: {
            Button("Search OpenSubtitles") { showingSearch = true }.buttonStyle(.borderedProminent)
            Button("Import a file") { showingImporter = true }
        }
    }

    private func nowShowingBar(_ track: SubtitleTrack) -> some View {
        Button { path = [track] } label: {
            HStack {
                Image(systemName: session.phase.symbol)
                    .foregroundStyle(Color.subtextTheme)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(session.phase.label).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
            .padding(.horizontal)
        }
        .buttonStyle(.plain)
    }

    private func durationLabel(_ seconds: Double) -> String {
        let total = Int(seconds)
        return total >= 3600 ? "\(total / 3600)h \((total % 3600) / 60)m" : "\(total / 60)m"
    }
}
