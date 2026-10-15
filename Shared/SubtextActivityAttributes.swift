import ActivityKit
import Foundation

/// The Live Activity. `SyncPhase` lives in `Shared/SyncPhase.swift` and the content state is
/// `Shared/IslandState.swift`, both Foundation-only so the macOS harness can compile them.
struct SubtextActivityAttributes: ActivityAttributes {
    typealias ContentState = IslandState

    /// Title of the film or episode.
    var title: String
    /// Subtitle language code, e.g. "en".
    var language: String
}
