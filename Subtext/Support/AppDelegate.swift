import ActivityKit
import UIKit

/// Orientation plumbing under the SwiftUI life cycle (docs/v2/island.md §5.2): the deprecated
/// app-delegate hook is the only one iOS 26 consults; iOS 27 adds the scene-delegate method.
/// Both return `OrientationLock.mask`.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        if connectingSceneSession.role == .windowApplication {
            configuration.delegateClass = SceneDelegate.self
        }
        return configuration
    }

    // iOS 26 path (deprecated from iOS 27, where the scene delegate's method takes over).
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        MainActor.assumeIsolated { OrientationLock.mask }
    }
}

final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    /// iOS 27+: replaces Info.plist's orientations for this scene.
    @available(iOS 27, *)
    func supportedInterfaceOrientations(for windowScene: UIWindowScene) -> UIInterfaceOrientationMask {
        MainActor.assumeIsolated { OrientationLock.mask }
    }

    // With a custom scene delegate installed, URL opens may arrive here rather than through
    // SwiftUI's `onOpenURL`; both paths go through `route`, which ignores a repeat of the same
    // URL within `routeDedupSeconds` (`Library.add` keys on a fresh UUID, so a file URL handled
    // twice would otherwise import twice).
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        for context in connectionOptions.urlContexts { Self.route(context.url) }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        for context in URLContexts { Self.route(context.url) }
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        if userActivity.activityType == TheaterNavigation.liveActivityUserActivityType {
            MainActor.assumeIsolated { TheaterNavigation.shared.present() }
        }
    }

    private static let routeDedupSeconds: TimeInterval = 2
    @MainActor private static var lastRouted: (url: URL, at: Date)?

    /// `subtext://…` → `TheaterNavigation`; anything else is a subtitle file. The one entry point
    /// for the scene delegate and `SubtextApp.onOpenURL`.
    @MainActor
    static func route(_ url: URL) {
        let now = Date.now
        if let last = lastRouted, last.url == url, now.timeIntervalSince(last.at) < routeDedupSeconds { return }
        lastRouted = (url, now)
        if TheaterNavigation.shared.handle(url) { return }
        _ = try? Library.shared.importFile(at: url)
    }
}
