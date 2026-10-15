import AppIntents
import Foundation
import os

private let intentLog = Logger(subsystem: "com.utkarsh.subtext", category: "Intent")

/// Commands the Live Activity buttons send into the running app.
enum SyncCommand: Equatable, Sendable {
    case nudge(Double)
    /// State-dependent: locked → wide pass then full search; twice within 10 s → full search.
    case resync
    case togglePause
    /// Idempotent resume (paused / autoPaused rows). While auto-paused this asserts "the film
    /// resumed where it stopped".
    case resume
    /// Auto-end warning: reset the quiet clock and keep the session alive.
    case keepListening
}

/// `LiveActivityIntent.perform` runs inside the app's process, so the app registers a
/// handler at launch and the intents call through to it. The widget target compiles the
/// same intents only so it can build the buttons; its handler stays nil.
enum SyncCommandRelay {
    nonisolated(unsafe) static var handler: (@MainActor (SyncCommand) async -> Void)?

    // Widget buttons occasionally double-fire. Identical commands inside this gap are one tap.
    nonisolated(unsafe) private static var last: (SyncCommand, Date)?

    @MainActor
    static func send(_ command: SyncCommand) async {
        intentLog.info("Intent received: \(String(describing: command), privacy: .public); handler \(handler == nil ? "missing" : "present", privacy: .public)")
        if let last, last.0 == command, Date.now.timeIntervalSince(last.1) < 0.12 { return }
        last = (command, .now)
        await handler?(command)
    }
}

struct NudgeSyncIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Nudge subtitle timing"
    static let description = IntentDescription("Shifts the subtitles earlier or later by a fraction of a second.")
    static let isDiscoverable = false

    @Parameter(title: "Seconds")
    var seconds: Double

    init() { seconds = 0.1 }
    init(seconds: Double) { self.seconds = seconds }

    @MainActor
    func perform() async throws -> some IntentResult {
        await SyncCommandRelay.send(.nudge(seconds))
        return .result()
    }
}

struct ResyncIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Re-sync subtitles"
    static let description = IntentDescription("Listens again and snaps the subtitles back onto what is playing.")
    static let isDiscoverable = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        await SyncCommandRelay.send(.resync)
        return .result()
    }
}

struct TogglePauseIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Pause or resume subtitles"
    static let description = IntentDescription("Freezes the subtitle clock while the film is paused.")
    static let isDiscoverable = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        await SyncCommandRelay.send(.togglePause)
        return .result()
    }
}

struct ResumeIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Resume subtitles"
    static let description = IntentDescription("Starts the subtitle clock again from where it stopped.")
    static let isDiscoverable = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        await SyncCommandRelay.send(.resume)
        return .result()
    }
}

struct KeepListeningIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Keep listening"
    static let description = IntentDescription("Keeps the session alive when nothing has been heard for a while.")
    static let isDiscoverable = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        await SyncCommandRelay.send(.keepListening)
        return .result()
    }
}
