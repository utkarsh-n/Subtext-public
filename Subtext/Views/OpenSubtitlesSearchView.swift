import SwiftUI

struct OpenSubtitlesSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var library = Library.shared
    @State private var query = ""
    @State private var language = "en"
    @State private var season = ""
    @State private var episode = ""
    @State private var results: [OpenSubtitlesClient.Result] = []
    @State private var searching = false
    @State private var downloading: Int?
    @State private var error: String?
    @State private var showingSettings = false

    private let client = OpenSubtitlesClient()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Film or show", text: $query)
                        .submitLabel(.search)
                        .onSubmit { search() }
                    HStack {
                        TextField("Season", text: $season).keyboardType(.numberPad)
                        TextField("Episode", text: $episode).keyboardType(.numberPad)
                        TextField("Lang", text: $language).frame(width: 60).textInputAutocapitalization(.never)
                    }
                    Button { search() } label: {
                        if searching { ProgressView().frame(maxWidth: .infinity) } else { Text("Search").frame(maxWidth: .infinity) }
                    }
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || searching)
                }
                if OpenSubtitlesClient.apiKey == nil {
                    Section {
                        Button("Add OpenSubtitles API key…") { showingSettings = true }
                    } footer: {
                        Text("Searching needs a free API key from opensubtitles.com; downloading needs a login.")
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
                if !results.isEmpty {
                    Section("Results") {
                        ForEach(results) { r in
                            Button { download(r) } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(titleLine(r)).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                        Text(r.release).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        HStack(spacing: 8) {
                                            Text(r.language.uppercased())
                                            if let fps = r.fps, fps > 0 { Text(String(format: "%.3g fps", fps)) }
                                            Text("\(r.downloads) downloads")
                                            if r.hearingImpaired { Text("HI") }
                                        }
                                        .font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if downloading == r.fileId { ProgressView() } else { Image(systemName: "arrow.down.circle") }
                                }
                            }
                            .disabled(downloading != nil)
                        }
                    }
                }
            }
            .navigationTitle("OpenSubtitles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .sheet(isPresented: $showingSettings) { SettingsView() }
        }
    }

    private func titleLine(_ r: OpenSubtitlesClient.Result) -> String {
        var s = r.title
        if let y = r.year { s += " (\(y))" }
        if let se = r.season, let ep = r.episode { s += String(format: " S%02dE%02d", se, ep) }
        return s
    }

    private func search() {
        error = nil
        searching = true
        Task {
            do {
                results = try await client.search(query: query, languages: language, season: Int(season), episode: Int(episode))
                if results.isEmpty { error = "Nothing found." }
            } catch {
                self.error = error.localizedDescription
            }
            searching = false
        }
    }

    private func download(_ r: OpenSubtitlesClient.Result) {
        error = nil
        downloading = r.fileId
        Task {
            do {
                let (data, name) = try await client.download(fileId: r.fileId)
                _ = try library.importData(data, filename: name, titleOverride: titleLine(r), language: r.language, source: "OpenSubtitles · \(r.release)")
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            downloading = nil
        }
    }
}
