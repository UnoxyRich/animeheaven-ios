# Video Playback, Caching & Preloading Engine

This document covers the networking, `SwiftSoup` parsing, SQLite3 WAL persistence, `ImageIO` downsampling cache, and `NWListener` multi-mirror `AVPlayer` streaming architecture in `animeheaven-ios`.

---

## 1. Networking & HTML Parsing

- **[`AnimeHeavenClient.swift`](../Packages/AnimeHeavenCore/Sources/AnimeHeavenCore/Network/AnimeHeavenClient.swift)**:
  - Configures `URLSession` (`httpMaximumConnectionsPerHost = 12`, `URLCache` 4 MB RAM / 24 MB disk under `Caches/http_cache`), plus an ephemeral non-redirect `URLSession` (`NoRedirectDelegate`) for extracting `Location` headers from `random.php`.
  - Episode gate requests (`gate.php`) inject `Cookie: key=<episodeKey>` and `Referer: https://animeheaven.me/anime.php?<animeId>` with `.reloadIgnoringLocalCacheData`.
  - Cooperative Swift `Task` cancellation aborts in-flight requests immediately during rapid Search typing or view dismissal.
- **[`NetworkPolicy.swift`](../Packages/AnimeHeavenCore/Sources/AnimeHeavenCore/Network/NetworkPolicy.swift)**:
  - Uses `Network.NWPathMonitor` to track `path.isExpensive` (cellular/hotspot) and `path.isConstrained` (Low Data Mode) reactively, strictly forcing `.dataSaver` (`0 B` background video preloading) on metered connections and exposing `observeUnmeteredTransitions() -> AsyncStream<Bool>` so `AppContainer` automatically resumes 4-wave preloading when Wi-Fi returns.
- **[`AnimeHeavenParser.swift`](../Packages/AnimeHeavenCore/Sources/AnimeHeavenCore/Parser/AnimeHeavenParser.swift)**:
  - 1:1 port of the Android Jsoup selectors using `SwiftSoup` across Home, Chart/Popular, FastSearch, SimilarGrid, AnimeDetail, and GatePage.

---

## 2. Three-Tier Persistence & Caching

1. **In-Memory Bounded LRU ([`LruCache.swift`](../Packages/AnimeHeavenCore/Sources/AnimeHeavenCore/Cache/LruCache.swift))**:
   - Charts (`24`), Grids (`24`), Details (`128`), Streams (`128`), FastSearch (`100`), ProbeMeta (`128`), VideoIndices (`160`), AniList MAL IDs (`256`), AniSkip entries (`128`), plus in-memory watch-progress maps hydrated on launch alongside persisted `gate:*` streams (`48`), `detail:*` records (`24`), and `vmeta:*` MP4 seek indices (`128`).
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

## 4. 4-Wave Preloading, MP4 Seek Index & `AVQueuePlayer` Loopback Proxy

Because `AVAssetResourceLoaderDelegate` breaks or stalls with `AVPictureInPictureController` and custom schemes, `animeheaven-ios` streams through a lightweight TCP loopback proxy bound strictly to `127.0.0.1:0` (warmed eagerly at app launch with a random per-launch 128-bit path token and concurrent multi-session support for gapless Watch Next):

```text
AVQueuePlayer (current + pre-buffered Watch Next item, actionAtItemEnd = .pause)
   │
   ▼
http://127.0.0.1:<port>/stream/<token>/<sessionId>.mp4 (HTTP/1.1 206 Partial Content)
   │
   ▼
LocalStreamProxyServer (NWListener — concurrent active + Watch Next sessions)
   ├── Hit  ──▶ DiskChunkCache (512 KB chunks, 2 GB cap, Tier-A hot window / Tier-B eviction)
   └── Miss ──▶ StreamingChunkBooster (4 parallel workers, 32 MB ahead window, MP4 moov seek index)
```

- **[`Mp4MoovSeekParser.swift`](../Packages/AnimeHeavenCore/Sources/AnimeHeavenCore/Video/Mp4MoovSeekParser.swift)**: Pure-Swift ISO-BMFF parser locates faststart and multi-chunk trailing `moov` atoms and parses `mvhd`/`mdhd`/`hdlr`/`stts`/`stss`/`stsc`/`stsz`/`stco`/`co64` into `EpisodeVideoIndex` keyframe tables persisted in SQLite `web_cache` (`"vmeta:<episodeKey>"`).
- **[`DiskChunkCache.swift`](../Packages/AnimeHeavenCore/Sources/AnimeHeavenCore/Video/DiskChunkCache.swift)**: Shared `ep:<episodeKey>:<contentLength>` key across mirrors, scaling up to `2 GB` (`512 MB` `< 4 GB`, `1 GB` `< 12 GB`, `2 GB` `>= 12 GB` free, capped at `<= 25%` of usable storage), with Tier-A hot-window protection (`40%` budget), automatic trailing chunk demotion (`> 3 min` behind playhead), `readRange`, and `episode_lengths.json` cold-start length lookup.
- **[`StreamingChunkBooster.swift`](../Packages/AnimeHeavenCore/Sources/AnimeHeavenCore/Video/StreamingChunkBooster.swift)**: Parallel `withTaskGroup` preloading (`4` workers), `32 MB` (`64` chunks) sliding ahead buffer from exact playhead frontier, `4s` seek wakeups, post-OP skip priority, and warm-disk zero-probe playback start (`hasPlayableHotWindow`).
- **[`AnimePreloader.swift`](../Packages/AnimeHeavenCore/Sources/AnimeHeavenCore/Cache/AnimePreloader.swift)**: 4-wave startup engine on unmetered Wi-Fi (Wave 0: top 3 Continue Watching `8/6/6 MB` + Hero #1 `6 MB`; Wave 1 `+350 ms`: CW #4–#15 `5 MB`, Banners #2–#5 `5 MB`, Bookmarks #1–#15 `4.5 MB`; Wave 2 paced `150 ms`: Home Popular `12` + Schedule `24` shows `4 MB` each + catalog tabs; Wave 3 interactive: Detail `8 MB` + follow-up `4 MB`, Catalog/Bookmarks, Watch Next `6 -> 20 MB` with `originHtmlGate(2)` and `429`/`503` backoff).
- **Gapless `AVQueuePlayer` Watch Next ([`PlayerViewModel.swift`](../Packages/AnimeHeavenCore/Sources/AnimeHeavenCore/ViewModels/PlayerViewModel.swift), [`PlayerView.swift`](../AnimeHeavenApp/Screens/Player/PlayerView.swift))**: Once Watch Next warms, `PlayerViewModel` registers a second concurrent localhost proxy session and `PlayerView` inserts a pre-buffered `AVPlayerItem` into `AVQueuePlayer` (`actionAtItemEnd = .pause`). Advancing via Up Next, Play Now, Skip ED, or Next Ep calls `promotePreparedNextEpisode()` + `player.advanceToNextItem()` for a **0 ms instant cut**, paired with a `220 ms` anti-flicker spinner debounce when warm on disk.
- **[`MirrorHealthTracker.swift`](../Packages/AnimeHeavenCore/Sources/AnimeHeavenCore/Video/MirrorHealthTracker.swift)**: Tracks RTT latency, `60s` failure cooldown, EWMA `avgBytesPerSec`, and `< 1 MB` stub-clip penalties with throttled `UserDefaults` persistence.
- **Fallback**: Mirrors without a verified range length stream directly through the same loopback proxy with upstream headers, bypassing the shared chunk cache.

---

## 5. Skip OP / ED Pipeline

[`SkipTimesClient.swift`](../Packages/AnimeHeavenCore/Sources/AnimeHeavenCore/Network/SkipTimesClient.swift) resolves episode titles via AniList GraphQL (`30-day` `web_cache` TTL) and fetches OP/ED intervals from AniSkip v2 (`7-day` TTL). [`SkipPromptLogic.swift`](../Packages/AnimeHeavenCore/Sources/AnimeHeavenCore/Player/SkipPromptLogic.swift) evaluates exact OP/ED intervals, configurable fallback OP jump (`skipOpSeconds`), and end-of-episode Next Episode advancement inside the 500 ms player observer.
