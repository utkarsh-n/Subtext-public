import UIKit

/// The app stays portrait everywhere except the Theater, even though Info.plist now lists
/// landscape (docs/v2/island.md §5.2). The Theater calls `allow(.allButUpsideDown)` on appear
/// and `allow(.portrait)` on disappear; both delegate hooks return `mask`.
@MainActor
enum OrientationLock {
    private(set) static var mask: UIInterfaceOrientationMask = .portrait

    static func allow(_ m: UIInterfaceOrientationMask) {
        guard mask != m else { return }
        mask = m
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
            if m == .portrait, !scene.effectiveGeometry.interfaceOrientation.isPortrait {
                // Leaving the Theater while sideways: ask to go back to portrait (denial is fine).
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in }
            }
        }
    }

    /// "Open in landscape" from the Theater menu. Never forced on entry; denial is ignored.
    static func requestLandscape() {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape)) { _ in /* denied: stay as we are */ }
    }
}
