import UIKit

@MainActor
public final class OrientationManager {
    public static let shared = OrientationManager()

    public private(set) var allowedOrientations: UIInterfaceOrientationMask = .allButUpsideDown

    private init() {}

    public func lockLandscape() {
        allowedOrientations = .landscape
        applyGeometryUpdate(.landscape)
    }

    public func unlockAll() {
        allowedOrientations = .allButUpsideDown
        applyGeometryUpdate(.allButUpsideDown)
    }

    public func requestPortrait() {
        allowedOrientations = .allButUpsideDown
        applyGeometryUpdate(.portrait)
    }

    private func applyGeometryUpdate(_ mask: UIInterfaceOrientationMask) {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            let prefs = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: mask)
            windowScene.requestGeometryUpdate(prefs) { _ in }
            for window in windowScene.windows {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
        }
    }
}
