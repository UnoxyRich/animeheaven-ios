# AnimeHeaven iOS & iPadOS (`me.animeheaven.ios`)

Native **Swift 6 + SwiftUI + AVFoundation** iPhone and iPad application for browsing and streaming anime from `animeheaven.me`, sharing the 6-pillar optimized engine architecture with `animeheaven-tv` and `animeheaven-android`.

> **Companion Repositories**: See `animeheaven-tv` (`me.animeheaven.tv`) for Android TV / Leanback and `animeheaven-android` (`me.animeheaven.android`) for Android phones & tablets.

---

## Key Capabilities

- **Two-Layer Swift Architecture**:
  - [`Packages/AnimeHeavenCore`](Packages/AnimeHeavenCore): Pure Swift 6 SPM package containing models, `URLSession` client, `SwiftSoup` HTML parser, native `SQLite3` WAL persistence, 3-tier caching, `MirrorHealthTracker`, `DiskChunkCache`, `StreamingChunkBooster`, `LocalStreamProxyServer` (`NWListener`), AniSkip/AniList client, `AnimePreloader`, and `@Observable` ViewModels — buildable and testable on macOS without Xcode via SwiftPM.
  - [`AnimeHeavenApp`](AnimeHeavenApp): Native iOS 17+ SwiftUI application for iPhone & iPad with `AnimeHeaven.xcodeproj` and XcodeGen [`project.yml`](project.yml).
- **Hardware `AVPlayer` + Multi-Mirror Booster**:
  - Localhost loopback HTTP/1.1 `206 Partial Content` proxy (`NWListener` on `127.0.0.1:0` with random 128-bit auth token) feeding native `AVPlayer`.
  - Shared `ep:<episodeKey>:<contentLength>` 512 KB chunk cache on disk for 0 ms mirror failover & manual mirror switching, parallel range boosting, `Referer` header injection, and non-faststart MP4 `moov` tail warming.
  - Native **Picture-in-Picture (`AVPictureInPictureController`)**, Lock Screen / Control Center (`MPNowPlayingInfoCenter`), auto-landscape fullscreen (`UIWindowScene.requestGeometryUpdate`), double-tap left/right seek (`5/10/15s`), vertical left/right brightness & volume drags, interactive `Canvas` scrubber, screen lock, speed control (`0.75x..2.0x`), resize mode (`Fit`/`Fill`/`Zoom`), and AniSkip OP/ED overlays.
- **Minimal External Dependencies**: Only **1** third-party package — `SwiftSoup` (`2.7.5+`). Everything else uses Apple first-party frameworks (`SQLite3`, `Network`, `ImageIO`, `AVFoundation`, `AVKit`, `MediaPlayer`, `SwiftUI`, SF Symbols).

---

## Quick Start

### 1. Run Core Build & Self-Test (Works with macOS Command Line Tools Only)

```bash
cd Packages/AnimeHeavenCore

# Build release binary of AnimeHeavenCore
swift build -c release

# Execute full self-test suite (Parser, SQLite3 WAL, Coalescer, MirrorHealth, Live NWListener HTTP 206 Proxy, ViewModels)
swift run AnimeHeavenCoreSelfTest
```

### 2. Run Swift Testing & iOS App (Requires Xcode 16+ / iOS 17+ SDK)

```bash
# Run Swift Testing suite via SwiftPM
cd Packages/AnimeHeavenCore && swift test

# Build iOS Simulator target from CLI
cd animeheaven-ios
xcodebuild build \
  -project AnimeHeaven.xcodeproj \
  -scheme AnimeHeaven \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO

# Or open in Xcode and press Cmd+R
open AnimeHeaven.xcodeproj
```

---

## Repository Structure

```text
animeheaven-ios/
├── AnimeHeaven.xcodeproj/                  # Checked-in Xcode project (iOS 17+, iPhone & iPad)
├── project.yml                             # XcodeGen specification
├── .github/workflows/ios-ci.yml            # macos-15 CI (Core tests + iOS Simulator build)
├── Packages/AnimeHeavenCore/               # Pure Swift 6 package (iOS 17 + macOS 14)
│   ├── Package.swift
│   ├── Sources/AnimeHeavenCore/
│   │   ├── Cache/                          # LruCache, AnimePreloader
│   │   ├── Models/                         # Sendable/Codable domain & UI models
│   │   ├── Network/                        # AnimeHeavenClient, NetworkPolicy (NWPathMonitor), SkipTimesClient
│   │   ├── Parser/                         # AnimeHeavenParser (SwiftSoup CSS selectors)
│   │   ├── Persistence/                    # SQLiteDatabase (SQLite3 WAL), SettingsStore
│   │   ├── Player/                         # SkipPromptLogic
│   │   ├── Repository/                     # RequestCoalescer, AnimeHeavenRepository (SWR + snapshot)
│   │   ├── Video/                          # MirrorHealthTracker, DiskChunkCache, StreamingChunkBooster, LocalStreamProxyServer
│   │   └── ViewModels/                     # @Observable Home, Catalog, Bookmarks, Search, Detail, Player VMs
│   ├── Sources/AnimeHeavenCoreSelfTest/    # Zero-dependency CLI test runner for macOS CLT
│   └── Tests/AnimeHeavenCoreTests/         # 9 Swift Testing suites (for Xcode 16+ / CI)
├── AnimeHeavenApp/                         # Native SwiftUI iOS 17+ target (18 Swift files)
│   ├── App/                                # AnimeHeavenApp, AppDelegate, AppContainer
│   ├── Components/                         # AhCoverImage, AnimeCards
│   ├── Images/                             # ImageCacheManager (ImageIO downsampling + 250 MB disk LRU)
│   ├── Navigation/                         # RootTabView (4-tab NavigationStack + fullScreenCover player)
│   ├── Resources/                          # Info.plist, PrivacyInfo.xcprivacy, Assets.xcassets
│   ├── Screens/                            # Home, Catalog, Bookmarks, Search, Detail, Settings, Player/
│   └── Theme/                              # 8 cached AhThemePalette themes
└── docs/
    ├── ARCHITECTURE.md
    ├── VIDEO_AND_CACHING.md
    └── PERFORMANCE_AND_BUILD.md
```
