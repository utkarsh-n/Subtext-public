import ActivityKit
import SwiftUI

@main
struct SubtextApp: App {
    /// Orientation plumbing and the scene delegate (docs/v2/island.md §5.2).
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var theater = TheaterNavigation.shared
    @State private var session = SessionController.shared

    init() {
        // Live Activity buttons run their intents in this process; route them to the session.
        SyncCommandRelay.handler = { command in
            SessionController.shared.handle(command)
        }
        // The beacon's beat follows the phase from now on (WP5).
        SessionController.shared.startBeatObservation()
        #if DEBUG
        // `-importSubtitles /path/to/file.srt` loads a track at launch, for simulator testing.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "-importSubtitles"), i + 1 < args.count {
            _ = try? Library.shared.importFile(at: URL(fileURLWithPath: args[i + 1]))
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .fullScreenCover(isPresented: $theater.isPresented) {
                    if let track = session.track {
                        TheaterView(track: track)
                    }
                }
                // `end()` clears `track` and `isActive` in one step, which removes `TheaterView`
                // before its own dismiss-on-end can run; drop the cover from here (reviewer fix).
                .onChange(of: session.isActive) { _, active in
                    if !active { theater.isPresented = false }
                }
                .onOpenURL { url in
                    // `subtext://theater` from the Island opens the stage; anything else is a file.
                    // Same route as the scene delegate, deduplicated there.
                    SceneDelegate.route(url)
                }
                .onContinueUserActivity(TheaterNavigation.liveActivityUserActivityType) { _ in
                    // The Live Activity's default tap (no deep link): same destination.
                    theater.present()
                }
        }
    }
}
