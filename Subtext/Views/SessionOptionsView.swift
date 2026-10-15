import SwiftUI

// WP6 — session options (Now Playing card) and the Settings sections that share the same
// `SessionController` settings properties (docs/v2/critique.md §4.3). Every row writes a
// UserDefaults-backed property declared by WP0; nothing here talks to the engine directly.

// MARK: - Now Playing options card

/// The per-session options card on Now Playing: locked-in mode, check-in cadence, auto-pause,
/// auto-end, music and memory. The same rows appear in Settings via the sections below.
struct SessionOptionsView: View {
    @State private var session = SessionController.shared
    /// `SyncTracker.rateConfirmed` as far as the UI can tell; nil = unknown (the suffix is then
    /// hidden). Fixed check-in intervals are clamped to 30 s until the playback speed is
    /// confirmed (keepalive.md §2), and the picker says so while clamped.
    /// TODO(WP7): feed this from a published `engine.rateConfirmed`.
    var rateConfirmed: Bool? = false

    var body: some View {
        VStack(spacing: 0) {
            Toggle("Locked-in mode", isOn: $session.lockedInEnabled)
                .padding(.vertical, 8)
            Text(session.lockedInEnabled
                 ? "Once in sync, Subtext stops the constant searching: a light check every 10 s and a timed check-in. The microphone stays open the whole time (iOS cannot re-open it from the background)."
                 : "Off: Subtext keeps searching continuously, as in the first version.")
                .font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 8)
            Divider()
            CheckInPickerRow(rateConfirmed: rateConfirmed)
                .disabled(!session.lockedInEnabled)
            Divider()
            Toggle("Pause when the film pauses", isOn: $session.autoPauseEnabled)
                .padding(.vertical, 8)
            if session.autoPauseEnabled {
                AutoPausePatienceRow()
            }
            Divider()
            AutoEndPickerRow()
            Divider()
            Toggle("Treat music as content", isOn: $session.treatMusicAsContent)
                .padding(.vertical, 8)
            Divider()
            Toggle("Remember what each film sounds like", isOn: $session.memoryEnabled)
                .padding(.vertical, 8)
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}

// MARK: - Shared rows

/// "Check in" picker with the "(30 s until speed is confirmed)" suffix while a fixed interval
/// longer than 30 s is clamped (keepalive.md §2; critique §4.3).
struct CheckInPickerRow: View {
    @State private var session = SessionController.shared
    /// nil = unknown: no suffix (Settings has no view of the tracker).
    var rateConfirmed: Bool? = nil

    private var clamped: Bool {
        guard session.isActive, session.lockedInEnabled, rateConfirmed == false else { return false }
        return (session.lockedInCheckIn.fixedSeconds ?? 0) > 30
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Picker("Check in", selection: $session.lockedInCheckIn) {
                ForEach(CheckInInterval.allCases, id: \.self) { interval in
                    Text(interval.optionLabel).tag(interval)
                }
            }
            if clamped {
                Text("(30 s until speed is confirmed)")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if session.lockedInCheckIn == .manual {
                Text("Only Re-sync or the Island's Re-sync button checks in; the 10 s probe still runs.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if session.lockedInCheckIn == .adaptive {
                Text("30 s after a correction, stretching to 5 min while the lines stay right.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
    }
}

/// normal (6 s / 10 s) · patient (12 s / 20 s).
struct AutoPausePatienceRow: View {
    @State private var session = SessionController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Patience", selection: $session.autoPausePatience) {
                ForEach(AutoPausePatience.allCases, id: \.self) { patience in
                    Text(patience.optionLabel).tag(patience)
                }
            }
            .pickerStyle(.segmented)
            Text(session.autoPausePatience.footnote)
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.bottom, 8)
    }
}

/// 10 · 20 · 30 · 60 · Never (0).
struct AutoEndPickerRow: View {
    @State private var session = SessionController.shared

    var body: some View {
        Picker("End after nothing heard for", selection: $session.autoEndMinutes) {
            ForEach(AutoEndOption.all, id: \.minutes) { option in
                Text(option.label).tag(option.minutes)
            }
        }
        .padding(.vertical, 8)
    }
}

struct AutoEndOption {
    let minutes: Int
    var label: String { minutes == 0 ? "Never" : (minutes >= 60 ? "\(minutes / 60) h" : "\(minutes) min") }
    static let all: [AutoEndOption] = [10, 20, 30, 60, 0].map(AutoEndOption.init)
}

extension CheckInInterval {
    /// Picker labels (critique §4.3): Adaptive · 30 s · 1 min · 2 min · 5 min · Only when I tap.
    var optionLabel: String {
        switch self {
        case .adaptive: "Adaptive"
        case .s30: "30 s"
        case .m1: "1 min"
        case .m2: "2 min"
        case .m5: "5 min"
        case .manual: "Only when I tap"
        }
    }
}

extension AutoPausePatience {
    var optionLabel: String { self == .normal ? "Normal" : "Patient" }
    var footnote: String {
        let d = Int(confirmDialogueSeconds), a = Int(confirmAbsentSeconds)
        return "Pauses after \(d) s of missing dialogue, or \(a) s of nothing playing."
    }
}

// MARK: - Settings sections

/// Settings › Listening: the session rows again, for people who never open the card.
struct ListeningSettingsSection: View {
    @State private var session = SessionController.shared

    var body: some View {
        Section {
            Toggle("Locked-in mode", isOn: $session.lockedInEnabled)
            CheckInPickerRow().disabled(!session.lockedInEnabled)
            Toggle("Pause when the film pauses", isOn: $session.autoPauseEnabled)
            if session.autoPauseEnabled { AutoPausePatienceRow() }
            AutoEndPickerRow()
            Toggle("Treat music as content", isOn: $session.treatMusicAsContent)
        } header: {
            Text("Listening")
        } footer: {
            Text("Locked-in mode stops the work, not the microphone. Between check-ins Subtext only runs a light check every 10 s and listens for the film pausing. Pause detection uses the rhythm of the sound in the room (how it swells and dips at a syllable's pace), its depth and its colour against what the TV sounded like earlier in the session. The orange indicator shows whenever the microphone hardware is open. Subtext never hides it.")
        }
    }
}

/// Settings › Audio memory: the toggle, the size, and "Forget all audio memory".
struct AudioMemorySettingsSection: View {
    @State private var session = SessionController.shared
    @State private var bytes = 0
    @State private var confirmForget = false

    var body: some View {
        Section {
            Toggle("Remember what each film sounds like", isOn: $session.memoryEnabled)
            Button(role: .destructive) {
                confirmForget = true
            } label: {
                HStack {
                    Text("Forget all audio memory")
                    Spacer()
                    Text(AudioMemoryFiles.sizeLabel(bytes)).foregroundStyle(.secondary)
                }
            }
            .disabled(bytes == 0)
            .confirmationDialog("Forget what every film sounds like?", isPresented: $confirmForget, titleVisibility: .visible) {
                Button("Forget all audio memory", role: .destructive) {
                    AudioMemoryFiles.forgetAll()
                    bytes = 0   // the store deletes on its own queue; re-read once it has
                    Task {
                        try? await Task.sleep(for: .milliseconds(500))
                        bytes = AudioMemoryFiles.totalBytes()
                    }
                }
            } message: {
                Text("Subtext will find its place from scratch next time. Your subtitle files are untouched.")
            }
        } header: {
            Text("Audio memory")
        } footer: {
            Text("Subtext keeps a small sketch of how each line sounded (loudness in 24 frequency bands, 50 times a second) so it can find its place faster next time. It cannot be played back and never leaves this phone.")
        }
        .task { bytes = AudioMemoryFiles.totalBytes() }
    }
}

/// Settings › Island.
struct IslandSettingsSection: View {
    @State private var session = SessionController.shared

    var body: some View {
        Section {
            Toggle("Pulse while listening", isOn: $session.islandPulse)
            Toggle("Show check-in ring", isOn: $session.islandRing)
            Toggle("Show the next line", isOn: $session.showNextLine)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Show lines slightly early")
                    Spacer()
                    Text(String(format: "%.2f s", session.leadSeconds))
                        .font(.body.monospacedDigit()).foregroundStyle(.secondary)
                }
                Slider(value: $session.leadSeconds, in: 0...0.4, step: 0.05) {
                    Text("Show lines slightly early")
                } minimumValueLabel: {
                    Text("0").font(.caption2)
                } maximumValueLabel: {
                    Text("0.4 s").font(.caption2)
                }
            }
        } header: {
            Text("Island")
        } footer: {
            Text("With the pulse off the dot sits still while searching and the Island gets no extra updates. Lines are pushed a little early to absorb the delay between the app and the glass.")
        }
    }
}

/// Settings › Theater. `theater.textSize` is a String key (medium / large / xl); the Theater's
/// own `Aa` menu (WP5) writes the same key.
struct TheaterSettingsSection: View {
    @State private var session = SessionController.shared

    private static let sizes: [(key: String, label: String)] = [("medium", "Medium"), ("large", "Large"), ("xl", "Extra large")]

    var body: some View {
        Section {
            Picker("Text size", selection: $session.theaterTextSize) {
                ForEach(Self.sizes, id: \.key) { size in Text(size.label).tag(size.key) }
            }
            Toggle("Keep the screen awake", isOn: $session.theaterKeepAwake)
            Toggle("Haptics", isOn: $session.theaterHaptics)
            Toggle("Allow landscape", isOn: $session.theaterAllowLandscape)
        } header: {
            Text("Theater")
        } footer: {
            Text("Theater is the full-screen view of the lines. Tap the line you hear to re-sync, drag sideways to trim, hold to listen again.")
        }
    }
}

/// Settings › Advanced.
struct AdvancedSettingsSection: View {
    @State private var session = SessionController.shared

    var body: some View {
        Section {
            Toggle("Search audio memory on a rewatch", isOn: $session.memoryRewatchSearch)
                .disabled(!session.memoryEnabled)
            Toggle("Show the engine row", isOn: $session.debugShowEngine)
            #if DEBUG
            Toggle("Text expectations (experiment)", isOn: $session.tuningUseTextExpectations)
            #endif
        } header: {
            Text("Advanced")
        } footer: {
            Text("The engine row on Now Playing shows the tracker's note, the presence features (level, depth, modulation, speech, flux, TV and room distances, expected dialogue) and the audio-memory score against its threshold.")
        }
    }
}

// MARK: - Audio memory files

/// Settings' view of WP4's `MemoryStore` (signature.md: `forgetAll()`, `totalSize()`), so that
/// "Forget all audio memory" also drops the store's bookkeeping, not just the files.
/// TODO(WP7): after `forgetAll()`, also drop an open session's in-memory `SignatureIndex`.
enum AudioMemoryFiles {
    static func totalBytes() -> Int { MemoryStore.shared.totalSize() }

    static func forgetAll() { MemoryStore.shared.forgetAll() }

    static func sizeLabel(_ bytes: Int) -> String {
        if bytes == 0 { return "Nothing stored" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
