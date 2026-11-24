# Architecture & iOS UI Guide

This document describes startup wiring, dependency management, navigation, themes, and iOS/iPadOS player controls in `animeheaven-ios`.

---

## 1. Two-Layer Modular Architecture

- **`Packages/AnimeHeavenCore`** (`iOS 17` + `macOS 14`): Owns all business logic, networking, `SwiftSoup` HTML parsing, `SQLite3` WAL persistence, multi-mirror video caching/proxy, and `@MainActor @Observable` ViewModels. Keeping it pure Foundation/Network/SQLite3 lets developers iterate and test locally with SwiftPM (`swift run AnimeHeavenCoreSelfTest` / `swift test`) without spinning up an iOS Simulator.
- **`AnimeHeavenApp`** (`iOS 17+`, iPhone & iPad): Owns SwiftUI views, `ImageCacheManager` (`ImageIO` + `UIImage`), `AVPlayer` + `AVPictureInPictureController`, `OrientationManager`, and `MPNowPlayingInfoCenter`.

---

## 2. Startup, Lazy DI & Memory Handling

- [`AnimeHeavenApp.swift`](../AnimeHeavenApp/App/AnimeHeavenApp.swift) configures `AVAudioSession` (`category = .playback`, `mode = .moviePlayback`, `[.allowAirPlay]`) in `AnimeHeavenAppDelegate.application(_:didFinishLaunchingWithOptions:)` so video audio plays through the hardware mute switch and native Picture-in-Picture works.
- [`AppContainer.swift`](../AnimeHeavenApp/App/AppContainer.swift) opens SQLite off the main actor at startup, initializes other dependencies on demand, and warms image and video caches asynchronously.
- `warmUpOnStartup()` executes detached off the main thread:
  1. Preconnects `animeheaven.me` + learned top healthy CDN hosts (`mirrorHealthTracker.topHealthyHosts(limit: 2)`).
  2. Hydrates `home_snapshot.v1.json` (`repository.hydrateHomeFast()`) and preloads the top 2 Hero banners + 6 Popular cards at exact `ImageTargetSize` dimensions.
  3. Opens `SQLiteDatabase` (`repository.warmUpFromDisk()`) and triggers `preloadHomeEcosystem(...)`.
  4. Delays `800 ms` to warm `DiskChunkCache` off-main-thread, then delays `9 s` to prune expired `web_cache` rows (> 14 days).
- `UIApplication.didReceiveMemoryWarningNotification` invokes `AppContainer.handleMemoryWarning()`, clearing `ImageCacheManager` RAM cache, `AnimeHeavenRepository` LRU maps, and `SkipTimesClient` caches.

---

## 3. Navigation & Adaptive iPhone/iPad Layout

[`RootTabView.swift`](../AnimeHeavenApp/Navigation/RootTabView.swift) hosts 4 top-level tabs inside independent `NavigationStack`s:
1. **Schedule** (`HomeView`)
2. **New** (`CatalogView` `.newReleases`)
3. **Popular** (`CatalogView` `.popular`)
4. **Bookmarks** (`BookmarksView`)

Push destinations (`AppDestination`): `.detail(animeId:)`, `.seasonal(path:label:)`, `.tag(String)`, `.search`, `.settings`.
Video playback opens via `.fullScreenCover(item: $activePlayer)` so orientation locking, status bar hiding, and system-overlay dimming stay cleanly isolated from the tab hierarchy.

All card grids use `GridItem(.adaptive(minimum: 112, maximum: 165))`, automatically adapting column counts across portrait iPhones, landscape iPhones, and iPad split views.

---

## 4. Native Player, PiP & Touch Gestures (`AnimeHeavenApp/Screens/Player/`)

- **[`AVPlayerLayerView.swift`](../AnimeHeavenApp/Screens/Player/AVPlayerLayerView.swift)**:
  - Wraps `AVPlayerLayer` (`videoGravity` cycling `.resizeAspect` Fit / `.resizeAspectFill` Zoom / `.resize` Fill).
  - Attaches `AVPictureInPictureController(playerLayer:)` with `canStartPictureInPictureAutomaticallyFromInline = true` so swiping Home while playing enters iOS Picture-in-Picture automatically (requires `UIBackgroundModes: ["audio"]` in `Info.plist`).
  - Bridges vertical-drag volume adjustments via a hidden `MPVolumeView` slider (`SystemVolumeBridge`).
- **[`OrientationManager.swift`](../AnimeHeavenApp/Screens/Player/OrientationManager.swift)**:
  - Coordinates `AppDelegate.supportedInterfaceOrientationsFor` with `UIWindowScene.requestGeometryUpdate(.iOS(interfaceOrientations:))`.
  - Automatically enters `.landscape` when `settingsStore.autoLandscapePlayer == true`, supports manual portrait/landscape toggling, and restores `.allButUpsideDown` + `isIdleTimerDisabled = false` on exit.
- **[`PlayerView.swift`](../AnimeHeavenApp/Screens/Player/PlayerView.swift)** & **[`InteractiveSeekBar.swift`](../AnimeHeavenApp/Screens/Player/InteractiveSeekBar.swift)**:
  - **Double-tap**: `< 38%` width seeks `-doubleTapSeekSeconds`, `> 62%` seeks `+doubleTapSeekSeconds`, center toggles play/pause.
  - **Single-tap**: toggles HUD (or flashes Unlock button when locked).
  - **Vertical drag**: left half adjusts `UIScreen.main.brightness`, right half adjusts system volume.
  - **Scrubber**: isolated `@Observable PlayerProgressModel` updated at 2 Hz (`addPeriodicTimeObserver(0.5s)`) inside a leaf `Canvas` track supporting tap and drag seeking.
  - **Overlays**: Skip OP/ED button (driven by `SkipPromptLogic`), 5-second Up Next countdown, mirror switcher pill, speed selector (`0.75x..2.0x`), and Lock Screen metadata via [`NowPlayingBridge.swift`](../AnimeHeavenApp/Screens/Player/NowPlayingBridge.swift).

---

## 5. User Settings (`SettingsStore.swift`)

Persisted in `UserDefaults`:

| Setting | Default | Purpose |
| :--- | :--- | :--- |
| `themeId` | `.dark` | Active theme (`dark`, `dark2`..`dark7`, `light`) |
| `defaultViewMode` | `.list` | Default Schedule/Catalog layout (`.list` / `.grid`) |
| `autoPlayNext` | `true` | Enables 5-second Up Next auto-play countdown |
| `skipOpSeconds` | `85` | Fallback OP skip duration when AniSkip has no timestamps |
| `skipPromptEnabled` | `true` | Enables contextual Skip OP/ED prompts |
| `doubleTapSeekSeconds` | `10` | Double-tap left/right seek step (`5` / `10` / `15`s) |
| `autoLandscapePlayer` | `true` | Automatically switches player to landscape on open |
| `preloadMode` | `.aggressive` | Scales background prefetching (`.aggressive` Wi-Fi / `.balanced` / `.dataSaver`) |
