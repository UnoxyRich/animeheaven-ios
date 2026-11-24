import SwiftUI
import UIKit
import AnimeHeavenCore

final class AnimeHeavenAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        OrientationManager.shared.allowedOrientations
    }
}

@main
struct AnimeHeavenApp: App {
    @UIApplicationDelegateAdaptor(AnimeHeavenAppDelegate.self) private var appDelegate
    @State private var container = AppContainer()

    var body: some Scene {
        WindowGroup {
            let palette = AhThemePalette.palette(for: container.settingsStore.themeId)
            RootTabView(container: container)
                .environment(\.ahPalette, palette)
                .preferredColorScheme(palette.isLight ? .light : .dark)
                .tint(palette.crimson)
                .onAppear {
                    container.warmUpOnStartup()
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: UIApplication.didReceiveMemoryWarningNotification
                    )
                ) { _ in
                    container.handleMemoryWarning()
                }
        }
    }
}
