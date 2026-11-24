# Video Playback, Caching & Preloading Engine

This document covers the networking, `SwiftSoup` parsing, SQLite3 WAL persistence, `ImageIO` downsampling cache, and `NWListener` multi-mirror `AVPlayer` streaming architecture in `animeheaven-ios`.

---

## 1. Networking & HTML Parsing

- **[`AnimeHeavenClient.swift`](../Packages/AnimeHeavenCore/Sources/AnimeHeavenCore/Network/AnimeHeavenClient.swift)**:
  - Configures `URLSession` (`httpMaximumConnectionsPerHost = 12`, `URLCache` 4 MB RAM / 24 MB disk under `Caches/http_cache`), plus an ephemeral non-redirect `URLSession` (`NoRedirectDelegate`) for extracting `Location` headers from `random.php`.
  - Episode gate requests (`gate.php`) inject `Cookie: key=<episodeKey>` and `Referer: https://animeheaven.me/anime.php?<animeId>` with `.reloadIgnoringLocalCacheData`.
  - Cooperative Swift `Task` cancellation aborts in-flight requests immediately during rapid Search typing or view dismissal.
- **[`NetworkPolicy.swift`](../Packages/AnimeHeavenCore/Sources/AnimeHeavenCore/Network/NetworkPolicy.swift)**:
  - Uses `Network.NWPathMonitor` to track `path.isExpensive` (cellular/hotspot) and `path.isConstrained` (Low Data Mode) reactively, automatically disabling `8 MB` next-episode video preloading on metered networks.
- **[`AnimeHeavenParser.swift`](../Packages/AnimeHeavenCore/Sources/AnimeHeavenCore/Parser/AnimeHeavenParser.swift)**:
  - 1:1 port of the Android Jsoup selectors using `SwiftSoup` across Home, Chart/Popular, FastSearch, SimilarGrid, AnimeDetail, and GatePage.

---

## 2. Three-Tier Persistence & Caching

1. **In-Memory Bounded LRU ([`LruCache.swift`](../Packages/AnimeHeavenCore/Sources/AnimeHeavenCore/Cache/LruCache.swift))**:
   - Charts (`24`), Grids (`24`), Details (`64`), Streams (`48`), FastSearch (`100`), ProbeMeta (`64`), AniList MAL IDs (`256`), AniSkip entries (`128`).
   - Soft TTLs: Home/Chart `5m`, Detail/Gate `15m`, Seasonal/Search `30m`.
   - [`RequestCoalescer`](../Packages/AnimeHeavenCore/Sources/AnimeHeavenCore/Repository/RequestCoalescer.swift) executes shared fetches inside a detached `Task` so cancelling a preloader caller never cancels a foreground screen awaiting the same key.
2. **Fast Cold-Start Snapshot**:
   - `AnimeHeavenRepository` persists `home_snapshot.v1.json` atomically in Application Support so Home renders before SQLite finishes opening.
3. **Native `SQLite3` WAL Database ([`SQLiteDatabase.swift`](../Packages/AnimeHeavenCore/Sources/AnimeHeavenCore/Persistence/SQLiteDatabase.swift))**:
   - Zero third-party ORM dependency; opens `animeheaven_ios.db` with `PRAGMA journal_mode = WAL`, `synchronous = NORMAL`, `temp_store = MEMORY`, `cache_size = -4000`.
   - Tables: `bookmarks`, `watch_progress` (indexed `(animeId, updatedAt)` & `(updatedAt)` with `getLatestWatchProgressPerAnime(limit: 30)`), `search_history`, and `web_cache` (14-day retention).
   - Watch thresholds (`WatchProgressLogic`): `MIN_RESUME_THRESHOLD_MS = 10_000`, `WATCHED_RATIO = 0.85`, `MAX_RESUME_RATIO = 0.92`.

---

## 3. Hardware-Downsampled Image Cache ([`ImageCacheManager.swift`](../AnimeHeavenApp/Images/ImageCacheManager.swift))

- Memory cache: `NSCache<NSString, UIImage>` keyed by `"\(url)#\(targetSize.widthPx)x\(targetSize.heightPx)"` (14% physical RAM on <= 3 GB devices, 20% otherwise, capped at 160 MB).
- Disk cache: `250 MB` LRU under `Caches/image_cache`.
- Dedicated `URLSession` with `urlCache = nil` eliminates double disk writes.
- Uses `CGImageSourceCreateThumbnailAtIndex` (`kCGImageSourceCreateThumbnailFromImageAlways: true`, `kCGImageSourceShouldCacheImmediately: true`) so images decode directly at canonical `ImageTargetSize` dimensions (`1080x460` Hero, `360x540` Detail poster, `480x270` Continue card, `320x320` Popular, `420x236` Standard, `256x144` Search thumb).

---

## 4. Localhost Loopback HTTP 206 Proxy & Multi-Mirror Booster

Because `AVAssetResourceLoaderDelegate` breaks or stalls with `AVPictureInPictureController` and custom schemes, `animeheaven-ios` streams through a lightweight TCP loopback proxy bound strictly to `127.0.0.1:0` with a random per-launch 128-bit path token:

```text
AVPlayer ──▶ http://127.0.0.1:<port>/stream/<token>/<sessionId>.mp4 (HTTP/1.1 206 Partial Content)
                │
                ▼
         LocalStreamProxyServer (NWListener)
                │
                ├── Hit  ──▶ DiskChunkCache (512 KB chunks keyed by ep:<episodeKey>:<contentLength>)
                └── Miss ──▶ StreamingChunkBooster (parallel ranked mirrors + Referer + MOOV tail warmup)
```

- **[`MirrorHealthTracker.swift`](../Packages/AnimeHeavenCore/Sources/AnimeHeavenCore/Video/MirrorHealthTracker.swift)**: Tracks RTT latency, `60s` failure cooldown, EWMA `avgBytesPerSec`, and `< 1 MB` stub-clip penalties with strictly transitive ranking and throttled `UserDefaults` persistence.
- **[`DiskChunkCache.swift`](../Packages/AnimeHeavenCore/Sources/AnimeHeavenCore/Video/DiskChunkCache.swift)**: Shared `ep:<episodeKey>:<contentLength>` key across mirrors (`512 MB` cap, `1 GB` when free space >= `4 GB`), plus `containsMoovBox(_:)` to warm trailing chunks of non-faststart MP4s.
- **[`StreamingChunkBooster.swift`](../Packages/AnimeHeavenCore/Sources/AnimeHeavenCore/Video/StreamingChunkBooster.swift)**: Races `Range: bytes=0-0` probes (`probeMirrorsForPlayback`) to unblock playback on the **first** valid full-length mirror (~80–150 ms), fetches `512 KB` chunks in parallel, and handles seek wakeups + background next-episode warming (`AnimePreloader`).
- **Fallback**: If a mirror omits `Content-Length` or fails probe sizing, `PlayerViewModel` falls back cleanly to direct `AVURLAsset(url:options: ["AVURLAssetHTTPHeaderFieldsKey": ...])`.

---

## 5. Skip OP / ED Pipeline

[`SkipTimesClient.swift`](../Packages/AnimeHeavenCore/Sources/AnimeHeavenCore/Network/SkipTimesClient.swift) resolves episode titles via AniList GraphQL (`30-day` `web_cache` TTL) and fetches OP/ED intervals from AniSkip v2 (`7-day` TTL). [`SkipPromptLogic.swift`](../Packages/AnimeHeavenCore/Sources/AnimeHeavenCore/Player/SkipPromptLogic.swift) evaluates exact OP/ED intervals, configurable fallback OP jump (`skipOpSeconds`), and end-of-episode Next Episode advancement inside the 500 ms player observer.
