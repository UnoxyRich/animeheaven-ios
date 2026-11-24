import AVFoundation
import SwiftUI
import UIKit
import AnimeHeavenCore

final class AnimeHeavenAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Required for audio playback through hardware mute switch & native Picture-in-Picture
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [.allowAirPlay])
        try? session.setActive(true)
        return true
    }

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
