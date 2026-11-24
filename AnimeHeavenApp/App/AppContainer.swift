import Foundation
import SwiftUI
import AnimeHeavenCore

@MainActor
final class ViewModelStorage<Model>: ObservableObject {
    let value: Model

    init(_ value: Model) { self.value = value }
}

/// Lazy application dependency container mirroring Android's `AppContainer` architecture.
/// Heavy I/O subsystems initialize lazily off the main thread so cold start finishes in <5 ms.
@MainActor
public final class AppContainer {
    public let settingsStore: SettingsStore

    private let cachesDir: URL
    private let appSupportDir: URL

    public lazy var client: AnimeHeavenClient = {
        AnimeHeavenClient(session: AnimeHeavenClient.makeDefaultSession(cacheDirectory: cachesDir))
    }()

    public lazy var database: SQLiteDatabase = {
        let dbPath = appSupportDir.appendingPathComponent("animeheaven_ios.db").path
        do {
            return try SQLiteDatabase(path: dbPath)
        } catch {
            // Fallback to in-memory store if disk path is unavailable
            return try! SQLiteDatabase(path: ":memory:")
        }
    }()

    public lazy var networkPolicy: NetworkPolicy = {
        let store = self.settingsStore
        return NetworkPolicy(preloadModeProvider: { store.currentPreloadModeNonisolated() })
    }()

    public lazy var repository: AnimeHeavenRepository = {
        AnimeHeavenRepository(
            client: client,
            database: database,
            snapshotDirectory: appSupportDir
        )
    }()

    public lazy var skipTimesClient: SkipTimesClient = {
        SkipTimesClient(database: database)
    }()

    public lazy var mirrorHealthTracker: MirrorHealthTracker = {
        MirrorHealthTracker(defaults: .standard)
    }()

    public lazy var diskChunkCache: DiskChunkCache = {
        let videoDir = cachesDir.appendingPathComponent("video_cache", isDirectory: true)
        return DiskChunkCache(rootDirectory: videoDir)
    }()

    public lazy var chunkBooster: StreamingChunkBooster = {
        StreamingChunkBooster(
            diskCache: diskChunkCache,
            mirrorHealthTracker: mirrorHealthTracker
        )
    }()

    public lazy var proxyServer: LocalStreamProxyServer = {
        LocalStreamProxyServer(booster: chunkBooster)
    }()

    public lazy var imageCacheManager: ImageCacheManager = {
        let imgDir = cachesDir.appendingPathComponent("image_cache", isDirectory: true)
        return ImageCacheManager(diskDirectory: imgDir)
    }()
    lazy var homeViewModel = HomeViewModel(repository: repository, settingsStore: settingsStore, preloader: preloader)
    lazy var newViewModel = CatalogViewModel(kind: .newReleases, repository: repository,
        settingsStore: settingsStore, preloader: preloader)
    lazy var popularViewModel = CatalogViewModel(kind: .popular, repository: repository,
        settingsStore: settingsStore, preloader: preloader)
    lazy var bookmarksViewModel = BookmarksViewModel(repository: repository)
    private var hasStartedWarmup = false

    private var _preloader: AnimePreloader?
    public var preloader: AnimePreloader {
        if let existing = _preloader { return existing }
        let created = AnimePreloader(
            repository: repository,
            skipTimesClient: skipTimesClient,
            chunkBooster: chunkBooster,
            networkPolicy: networkPolicy,
            imagePreloadHandler: Self.makeImagePreloadHandler(cache: imageCacheManager)
        )
        _preloader = created
        return created
    }

    private nonisolated static func makeImagePreloadHandler(
        cache: ImageCacheManager
    ) -> AnimePreloader.ImagePreloadHandler {
        { urls, targetSize in
            await cache.preload(urls: urls, targetSize: targetSize)
        }
    }

    public init(settingsStore: SettingsStore? = nil) {
        self.settingsStore = settingsStore ?? SettingsStore()
        let fm = FileManager.default
        self.cachesDir = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        self.appSupportDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        try? fm.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
    }

    public func warmUpOnStartup() {
        guard !hasStartedWarmup else { return }
        hasStartedWarmup = true
        let client = self.client
        let repository = self.repository
        let preloader = self.preloader
        let tracker = self.mirrorHealthTracker
        let booster = self.chunkBooster

        Task.detached(priority: .utility) {
            let learnedHosts = tracker.topHealthyHosts(limit: 2).map { "https://\($0)" }
            client.preconnectHosts([AnimeHeavenClient.baseURL] + learnedHosts)

            if let fastFeed = await repository.hydrateHomeFast() {
                await preloader.preloadImages(
                    urls: fastFeed.banners.map(\.bannerImageUrl),
                    maxCount: 2,
                    targetSize: .heroBanner
                )
                await preloader.preloadImages(
                    urls: fastFeed.popularItems.map(\.coverUrl),
                    maxCount: 6,
                    targetSize: .popularCard
                )
            }

            let (feed, continueItems) = await repository.warmUpFromDisk()
            if let feed {
                await preloader.preloadHomeEcosystem(feed: feed, continueItems: continueItems)
            }

            // Warm video cache subsystem off main thread after Frame 1 settles
            try? await Task.sleep(for: .milliseconds(800))
            _ = await booster.diskCache.totalSizeBytes()

            try? await Task.sleep(for: .seconds(9))
            await repository.pruneExpiredCache()
        }
    }

    public func handleMemoryWarning() {
        let repo = self.repository
        let skip = self.skipTimesClient
        let img = self.imageCacheManager
        Task.detached(priority: .utility) {
            await img.clearMemoryCache()
            await repo.trimMemory(aggressive: true)
            await skip.trimMemory()
        }
    }

    public struct CacheStorageSummary: Sendable {
        public let webPages: Int
        public let webBytes: Int64
        public let imageBytes: Int64
        public let videoBytes: Int64

        public var totalBytes: Int64 { webBytes + imageBytes + videoBytes }
    }

    public func loadCacheSummary() async -> CacheStorageSummary {
        async let web = repository.webCacheStats()
        async let img = imageCacheManager.diskSizeBytes()
        async let vid = diskChunkCache.totalSizeBytes()
        let (w, i, v) = await (web, img, vid)
        return CacheStorageSummary(webPages: w.pages, webBytes: w.bytes, imageBytes: i, videoBytes: v)
    }
}
