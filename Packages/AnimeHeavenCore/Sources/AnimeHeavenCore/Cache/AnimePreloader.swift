import Foundation

/// 2-band predictive preloader with Wi-Fi vs cellular awareness, foreground user-priority yielding,
/// canonical `ImageTargetSize` artwork hooks, and shared-key video warming.
public actor AnimePreloader {
    private static let band1StartupGraceMs: Int64 = 450
    private static let defaultEpDurationMs: Int64 = 24 * 60_000
    private static let defaultOpEndMs: Int64 = 85_000

    public typealias ImagePreloadHandler = @Sendable (_ urls: [String], _ targetSize: ImageTargetSize) async -> Void

    private let repository: AnimeHeavenRepository
    private let skipTimesClient: SkipTimesClient
    private let chunkBooster: StreamingChunkBooster
    private let networkPolicy: NetworkPolicy
    private let imagePreloadHandler: ImagePreloadHandler?

    private var warmedDetails = Set<String>()
    private var warmedCatalogs = Set<String>()
    private var warmedEpisodes = Set<String>()
    private var lastHomeSignature: String?
    private var lastTopContinueKey: String?
    private var foregroundUserWorkCount: Int = 0
    private var homeEcosystemTask: Task<Void, Never>?

    public init(
        repository: AnimeHeavenRepository,
        skipTimesClient: SkipTimesClient,
        chunkBooster: StreamingChunkBooster,
        networkPolicy: NetworkPolicy,
        imagePreloadHandler: ImagePreloadHandler? = nil
    ) {
        self.repository = repository
        self.skipTimesClient = skipTimesClient
        self.chunkBooster = chunkBooster
        self.networkPolicy = networkPolicy
        self.imagePreloadHandler = imagePreloadHandler
    }

    public func beginUserPriorityWork() {
        foregroundUserWorkCount += 1
    }

    public func endUserPriorityWork() {
        foregroundUserWorkCount = max(0, foregroundUserWorkCount - 1)
    }

    public func preloadImages(
        urls: [String],
        maxCount: Int = 12,
        targetSize: ImageTargetSize = .standardCard
    ) {
        guard let handler = imagePreloadHandler, !urls.isEmpty, maxCount > 0 else { return }
        var seen = Set<String>()
        let filtered = urls.filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(maxCount)
        let list = Array(filtered)
        guard !list.isEmpty else { return }
        Task.detached(priority: .utility) {
            await handler(list, targetSize)
        }
    }

    public func preloadHomeEcosystem(
        feed: HomeFeed,
        continueItems: [ContinueWatchingItem]
    ) {
        let sig = "\(feed.banners.first?.animeId ?? "")|\(feed.scheduleItems.count)|\(feed.popularItems.count)|" +
            continueItems.prefix(3).map(\.targetEpisodeKey).joined(separator: ",")
        guard sig != lastHomeSignature else { return }
        lastHomeSignature = sig

        preloadImages(urls: feed.banners.map(\.bannerImageUrl), maxCount: 3, targetSize: .heroBanner)
        preloadImages(urls: feed.popularItems.map(\.coverUrl), maxCount: 8, targetSize: .popularCard)
        preloadImages(urls: feed.scheduleItems.map(\.coverUrl), maxCount: 8, targetSize: .standardCard)
        preloadImages(urls: continueItems.map(\.coverUrl), maxCount: 6, targetSize: .continueCard)

        homeEcosystemTask?.cancel()
        homeEcosystemTask = Task {
            // Band 0: warm top Continue Watching episode stream + optional 2 MB video head on Wi-Fi
            if let top = continueItems.first, top.targetEpisodeKey != lastTopContinueKey {
                lastTopContinueKey = top.targetEpisodeKey
                let videoBytes = networkPolicy.continueWatchingVideoBytes
                await warmEpisode(
                    episodeKey: top.targetEpisodeKey,
                    animeId: top.animeId,
                    animeTitle: top.animeTitle,
                    episodeLabel: top.targetEpisodeLabel,
                    videoBytes: videoBytes,
                    resumePositionMs: top.resumePositionMs,
                    estimatedDurationMs: top.durationMs
                )
            }

            guard networkPolicy.allowBackgroundCatalogPreload else { return }
            try? await Task.sleep(for: .milliseconds(Self.band1StartupGraceMs))
            if Task.isCancelled { return }

            await yieldWhileUserBusy()
            await warmCatalogTab(cacheKey: "new", path: "new.php", isPopular: false)
            await yieldWhileUserBusy()
            await warmCatalogTab(cacheKey: "popular", path: "popular.php", isPopular: true)

            if let seasonPath = feed.seasonPath, !seasonPath.isEmpty {
                await yieldWhileUserBusy()
                await warmCatalogTab(cacheKey: "season:\(seasonPath)", path: seasonPath, isPopular: false)
            }
        }
    }

    public func warmAnimeDetail(animeId: String) {
        guard !animeId.isEmpty, warmedDetails.insert(animeId).inserted else { return }
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            if await self.repository.hasFreshDetailInMemory(animeId: animeId) { return }
            _ = try? await self.repository.getAnimeDetail(animeId: animeId)
        }
    }

    public func warmEpisode(
        episodeKey: String,
        animeId: String?,
        animeTitle: String,
        episodeLabel: String,
        videoBytes: Int64,
        resumePositionMs: Int64 = 0,
        estimatedDurationMs: Int64 = 0
    ) async {
        guard !episodeKey.isEmpty else { return }
        let first = warmedEpisodes.insert(episodeKey).inserted
        if !first && videoBytes <= 0 { return }

        do {
            let stream = try await repository.resolveEpisodeStream(episodeKey: episodeKey, animeId: animeId)
            let title = stream.animeTitle.isEmpty ? animeTitle : stream.animeTitle
            let label = stream.episodeLabel.isEmpty ? episodeLabel : stream.episodeLabel
            if let epNum = SkipTimesParser.parseEpisodeNumber(label), !title.isEmpty {
                Task.detached(priority: .utility) { [skipTimesClient] in
                    _ = await skipTimesClient.fetchSkipTimes(animeTitle: title, episodeNumber: epNum)
                }
            }
            if !stream.videoSources.isEmpty {
                await chunkBooster.probeMirrorsSpeed(urls: stream.videoSources)
                if videoBytes > 0 {
                    let dur = estimatedDurationMs > 0 ? estimatedDurationMs : Self.defaultEpDurationMs
                    await chunkBooster.preloadVideoHead(
                        episodeKey: episodeKey,
                        allSources: stream.videoSources,
                        bytesToCache: videoBytes,
                        resumePositionMs: resumePositionMs,
                        estimatedDurationMs: dur,
                        opEndMs: Self.defaultOpEndMs
                    )
                }
            }
        } catch {
            warmedEpisodes.remove(episodeKey)
        }
    }

    public func resetSessionMarkers() {
        warmedDetails.removeAll()
        warmedCatalogs.removeAll()
        warmedEpisodes.removeAll()
        lastHomeSignature = nil
        lastTopContinueKey = nil
    }

    private func warmCatalogTab(cacheKey: String, path: String, isPopular: Bool) async {
        guard warmedCatalogs.insert(cacheKey).inserted else { return }
        if await repository.hasFreshChartInMemory(cacheKey: cacheKey) { return }
        _ = try? await repository.getChartFeed(
            cacheKey: cacheKey,
            relativePath: path,
            isPopularRank: isPopular
        )
    }

    private func yieldWhileUserBusy() async {
        var waited = 0
        while foregroundUserWorkCount > 0 && waited < 20 && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
            waited += 1
        }
    }
}
