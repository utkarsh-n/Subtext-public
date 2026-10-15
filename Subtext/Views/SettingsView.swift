import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = OpenSubtitlesClient.apiKey ?? ""
    @State private var username = OpenSubtitlesClient.username ?? ""
    @State private var password = ""
    @State private var loggingIn = false
    @State private var message: String?

    /// The one privacy paragraph (docs/v2/critique.md §4.3); also the basis of the mic usage string.
    static let privacyParagraph = "Subtext listens through the microphone to tell when people are talking, recognises a few words on this phone while it is finding the scene, and keeps a small sketch of how each line sounded (loudness in 24 frequency bands) so it can find its place faster next time. Nothing can be played back and nothing leaves the phone. The orange microphone indicator stays on for the whole session, including while the film is paused and while Subtext is only checking the room every few minutes: iOS does not let an app re-open the microphone from the background, so Subtext keeps it open rather than losing your place."

    var body: some View {
        NavigationStack {
            Form {
                ListeningSettingsSection()
                AudioMemorySettingsSection()
                IslandSettingsSection()
                TheaterSettingsSection()
                Section {
                    TextField("API key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: apiKey) { _, new in Keychain.set(new.trimmingCharacters(in: .whitespaces), for: OpenSubtitlesClient.keyAccount) }
                } header: {
                    Text("OpenSubtitles")
                } footer: {
                    Text("Register a consumer at opensubtitles.com/consumers to get a key. Searching works with the key alone.")
                }
                Section {
                    TextField("Username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Password", text: $password)
                    Button {
                        login()
                    } label: {
                        if loggingIn { ProgressView() } else { Text(OpenSubtitlesClient.token == nil ? "Log in" : "Log in again") }
                    }
                    .disabled(username.isEmpty || password.isEmpty || loggingIn)
                    if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                } header: {
                    Text("Account")
                } footer: {
                    Text("Downloads need a login. Free accounts get a daily allowance; VIP gets more.")
                }
                AdvancedSettingsSection()
                Section("Privacy") {
                    Text(Self.privacyParagraph)
                        .font(.footnote)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func login() {
        loggingIn = true
        message = nil
        Task {
            do {
                try await OpenSubtitlesClient().login(username: username, password: password)
                message = "Logged in as \(username)."
                password = ""
            } catch {
                message = error.localizedDescription
            }
            loggingIn = false
        }
    }
}
