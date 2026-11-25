import Foundation
import OSLog
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

    public let database: SQLiteDatabase
    private nonisolated static let logger = Logger(subsystem: "me.animeheaven.ios", category: "Storage")

    public lazy var networkPolicy: NetworkPolicy = {
        let store = self.settingsStore
        return NetworkPolicy(preloadModeProvider: { store.currentPreloadModeNonisolated() })
    }()

    lazy var multilingualSearchResolver: MultilingualSearchResolver = {
        MultilingualSearchResolver(database: database)
    }()

    public lazy var repository: AnimeHeavenRepository = {
        let store = self.settingsStore
        return AnimeHeavenRepository(
            client: client,
            database: database,
            snapshotDirectory: appSupportDir,
            multilingualResolver: multilingualSearchResolver,
            multilingualSearchEnabled: { store.currentMultilingualSearchEnabledNonisolated() }
        )
    }()

    lazy var artworkResolver: AnimeArtworkResolver = {
        let policy = networkPolicy
        return AnimeArtworkResolver(database: database, dataSaver: { policy.effectiveMode == .dataSaver })
    }()
    lazy var artworkStore = ArtworkStore(resolver: artworkResolver)

    public lazy var skipTimesClient: SkipTimesClient = {
        SkipTimesClient(database: database, artworkResolver: artworkResolver)
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
    lazy var bookmarksViewModel = BookmarksViewModel(repository: repository, preloader: preloader)
    private var hasStartedWarmup = false
    private var networkObserverTask: Task<Void, Never>?

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

    private init(database: SQLiteDatabase, cachesDirectory: URL, supportDirectory: URL) {
        self.settingsStore = SettingsStore()
        self.database = database
        self.cachesDir = cachesDirectory
        self.appSupportDir = supportDirectory
    }

    public static func bootstrap() async throws -> AppContainer {
        let (db, caches, support) = try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
            let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
            let db: SQLiteDatabase
            do {
                db = try SQLiteDatabase(path: support.appending(path: "animeheaven_ios.db").path)
            } catch {
                logger.error("Local storage unavailable; using temporary session storage: \(error.localizedDescription)")
                db = try SQLiteDatabase(path: ":memory:")
            }
            return (db, caches, support)
        }.value
        return AppContainer(database: db, cachesDirectory: caches, supportDirectory: support)
    }

    public func warmUpOnStartup() {
        guard !hasStartedWarmup else { return }
        hasStartedWarmup = true
        let client = self.client
        let repository = self.repository
        let preloader = self.preloader
        let tracker = self.mirrorHealthTracker
        let booster = self.chunkBooster
        let proxy = self.proxyServer
        let policy = self.networkPolicy
        let images = imageCacheManager
        let artwork = artworkResolver

        networkObserverTask?.cancel()
        networkObserverTask = Task.detached(priority: .utility) {
            for await isUnmetered in policy.observeUnmeteredTransitions() {
                if Task.isCancelled { break }
                if isUnmetered {
                    await preloader.onUnmeteredNetworkAvailable()
                }
            }
        }

        Task.detached(priority: .utility) {
            await booster.setVideoIndexPersistence { index in
                await repository.saveEpisodeVideoIndex(index)
            }

            async let imageWarmup: Void = images.warmUp()
            async let artworkWarmup: Void = artwork.hydrateRecentFromDisk()
            async let videoDiskWarmup: Void = booster.diskCache.warmUp()
            async let proxyWarmup: UInt16? = try? await proxy.ensureStarted()

            let learnedHosts = tracker.topHealthyHosts(limit: 3).map { "https://\($0)" }
            client.preconnectHosts([AnimeHeavenClient.baseURL] + learnedHosts)

            if let fastFeed = await repository.hydrateHomeFast() {
                await preloader.preloadImages(
                    urls: fastFeed.banners.map(\.bannerImageUrl),
                    maxCount: 3,
                    targetSize: .heroBanner
                )
                await preloader.preloadImages(
                    urls: fastFeed.popularItems.map(\.coverUrl),
                    maxCount: 8,
                    targetSize: .popularCard
                )
            }

            await videoDiskWarmup
            let recentIndices = await repository.loadRecentVideoIndices(limit: 128)
            await booster.hydrateVideoIndices(recentIndices)

            let (diskFeed, continueItems) = await repository.warmUpFromDisk()
            let effectiveFeed: HomeFeed?
            if let diskFeed {
                effectiveFeed = diskFeed
            } else {
                effectiveFeed = try? await repository.getHomeFeed(forceRefresh: false).feed
            }
            if let effectiveFeed {
                await preloader.preloadHomeEcosystem(feed: effectiveFeed, continueItems: continueItems)
            }

            _ = await proxyWarmup
            await imageWarmup
            await artworkWarmup

            try? await Task.sleep(for: .seconds(9))
            await repository.pruneExpiredCache()
        }
    }

    public func handleMemoryWarning() {
        let repo = self.repository
        let skip = self.skipTimesClient
        let img = self.imageCacheManager
        let artwork = artworkResolver
        let multilingual = multilingualSearchResolver
        Task.detached(priority: .utility) {
            await img.clearMemoryCache()
            await artwork.trimMemory()
            await multilingual.trimMemory()
            await repo.trimMemory(aggressive: true)
            await skip.trimMemory()
        }
    }

    func clearWebAndArtworkCache() async {
        let repository = self.repository
        await artworkResolver.withCacheCleared { await repository.clearWebCache() }
        artworkStore.didClearCache()
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
