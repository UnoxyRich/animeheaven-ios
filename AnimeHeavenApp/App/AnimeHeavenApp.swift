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
    @State private var container: AppContainer?
    @State private var startupError: String?

    var body: some Scene {
        WindowGroup {
            if let container {
                let palette = AhThemePalette.palette(for: container.settingsStore.themeId)
                RootTabView(container: container)
                    .environment(\.ahPalette, palette)
                    .environment(\.artworkStore, container.artworkStore)
                    .preferredColorScheme(palette.isLight ? .light : .dark)
                    .tint(palette.crimson)
                    .onAppear { container.warmUpOnStartup() }
                    .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                        container.handleMemoryWarning()
                    }
            } else {
                let startupPalette = AhThemePalette.palette(
                    for: AhThemeId.fromCssKey(UserDefaults.standard.string(forKey: "ah_theme_css_key"))
                )
                ZStack {
                    AhScreenBackground()
                    if let startupError {
                        ContentUnavailableView {
                            Label("Couldn’t Open AnimeHeaven", systemImage: "exclamationmark.triangle")
                        } description: {
                            Text(startupError)
                        } actions: {
                            Button("Try Again") { self.startupError = nil }
                        }
                        .foregroundStyle(startupPalette.textSecondary)
                    } else {
                        ProgressView("Opening AnimeHeaven…")
                            .tint(startupPalette.crimson)
                            .foregroundStyle(startupPalette.textSecondary)
                            .task {
                                do { container = try await AppContainer.bootstrap() }
                                catch { startupError = "Local storage couldn’t be opened. Please try again." }
                            }
                    }
                }
                .environment(\.ahPalette, startupPalette)
                .preferredColorScheme(startupPalette.isLight ? .light : .dark)
                .tint(startupPalette.crimson)
            }
        }
    }
}
