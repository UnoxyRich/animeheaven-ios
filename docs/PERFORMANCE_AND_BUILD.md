# Performance, Build & Contributor Guide

This guide covers Swift 6 concurrency hygiene, SwiftUI performance rules, local vs. Xcode testing workflows, and invariants to preserve in `animeheaven-ios`.

---

## 1. SwiftUI & Swift 6 Concurrency Hygiene

- **Granular `@Observable` Tracking**: All ViewModels and `SettingsStore` use Swift's `@Observable` macro (iOS 17+), so mutating a single preference (e.g., `doubleTapSeekSeconds`) never invalidates views reading only `themeId`.
- **Isolated 2 Hz Player Progress**: `PlayerProgressModel` is read only inside `InteractiveSeekBar` (`Canvas`) and time labels, preventing 2 Hz full-screen `PlayerView` body re-evaluation during video playback.
- **Zero `DateFormatter` in Hot Paths**: Use `DurationFormatter.format(ms:)` instead of `DateComponentsFormatter` inside the 500 ms playback observer.
- **Lifecycle-Gated Timers**: `HeroBannerPager` suspends auto-advance whenever `scenePhase != .active`.
- **Strict Swift 6 Concurrency**: `Packages/AnimeHeavenCore` compiles cleanly under `swift-tools-version: 6.0` with zero concurrency warnings. Actors isolate mutable state (`SQLiteDatabase`, `AnimeHeavenRepository`, `DiskChunkCache`, `StreamingChunkBooster`, `LocalStreamProxyServer`, `AnimePreloader`, `SkipTimesClient`, `ImageCacheManager`).

---

## 2. Testing & Verification Workflows

### On macOS Command Line Tools (No Xcode Required)
```bash
cd Packages/AnimeHeavenCore
swift build -c release
swift run AnimeHeavenCoreSelfTest
```
`AnimeHeavenCoreSelfTest` executes 11 end-to-end test suites covering:
- `AnimeHeavenParser` (Home, Popular ranks/arrows, FastSearch, SimilarGrid, AnimeDetail, GatePage)
- `MirrorHealthTracker` (cooldown, EWMA throughput, stub demotion)
- `DiskChunkCache` (shared episode key, headers, MP4 `moov` detection, initial window)
- `LruCache` eviction
- `SQLiteDatabase` (`:memory:` WAL tables, `latestPerAnime`, web cache pruning)
- `RequestCoalescer` deduplication & caller-cancellation isolation
- `WatchProgressLogic`, `SkipPromptLogic`, `MirrorQueueState`
- **Live `LocalStreamProxyServer`** (`NWListener` HTTP `206 Partial Content` cross-chunk reads, `HEAD`, `403` token validation)
- `@MainActor` `SearchViewModel` & `SettingsStore` persistence

### With Xcode 16+ / GitHub Actions (`macos-15`)
- Run `swift test` in `Packages/AnimeHeavenCore` (executes all 9 Swift Testing suites under `Tests/AnimeHeavenCoreTests/`).
- Build the iOS app target:
  ```bash
  xcodebuild build \
    -project AnimeHeaven.xcodeproj \
    -scheme AnimeHeaven \
    -destination 'generic/platform=iOS Simulator' \
    CODE_SIGNING_ALLOWED=NO
  ```
- [`.github/workflows/ios-ci.yml`](../.github/workflows/ios-ci.yml) automates both jobs on `macos-15`.

---

## 3. Build & App Store / Sideload Notes

- **ATS & Loopback Proxy**: `Info.plist` sets `NSAllowsArbitraryLoads = false` and `NSAllowsLocalNetworking = true` so `AVPlayer` can connect to `http://127.0.0.1:<ephemeralPort>` while all remote URLs stay strictly HTTPS.
- **PiP Requirement**: `UIBackgroundModes` includes `audio`, and `AnimeHeavenAppDelegate` activates `AVAudioSession` with `.playback` / `.moviePlayback`. Removing either disables iOS Picture-in-Picture.
- **Privacy Manifest**: [`PrivacyInfo.xcprivacy`](../AnimeHeavenApp/Resources/PrivacyInfo.xcprivacy) declares `UserDefaults` (`CA92.1`) and disk space (`E174.1`) usage.
- **Regenerating `.xcodeproj`**: If you add new Swift files under `AnimeHeavenApp/`, either add them in Xcode or run `xcodegen generate` using [`project.yml`](../project.yml).

---

## 4. Invariants Not to Break

- **Keep `AnimeHeavenCore` UIKit-free** — never `import UIKit` or `import SwiftUI` inside `Packages/AnimeHeavenCore` so `swift test` / `swift run AnimeHeavenCoreSelfTest` keeps running on macOS CLI and Linux/CI runners.
- **Never bind `LocalStreamProxyServer` to `0.0.0.0`** — keep it strictly bound to `NWEndpoint.Host.ipv4(.loopback)` (`127.0.0.1`) with its random per-launch auth token.
- **Keep `ImageCacheManager`'s `URLSession` `urlCache = nil`** — prevents double-writing artwork to both `URLCache` and `Caches/image_cache`.
- **Keep `ImageTargetSize` aligned** between `AnimePreloader` and `AhCoverImage`.
- **Always restore `OrientationManager.shared.unlockAll()` and `isIdleTimerDisabled = false`** when exiting `PlayerView`.
