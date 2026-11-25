import Foundation

public struct PreparedEpisodeWarmup: Sendable {
    public let episodeKey: String
    public let stream: EpisodeStream
    public let rankedMirrors: [String]
    public let cacheKey: String
    public let totalLength: Int64
    public let skipTimes: EpisodeSkipTimes
    public let durationMs: Int64

    public init(
        episodeKey: String,
        stream: EpisodeStream,
        rankedMirrors: [String],
        cacheKey: String,
        totalLength: Int64,
        skipTimes: EpisodeSkipTimes,
        durationMs: Int64
    ) {
        self.episodeKey = episodeKey
        self.stream = stream
        self.rankedMirrors = rankedMirrors
        self.cacheKey = cacheKey
        self.totalLength = totalLength
        self.skipTimes = skipTimes
        self.durationMs = durationMs
    }
}

private actor AsyncPermitGate {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(permits: Int) {
        self.permits = max(1, permits)
    }

    func acquire() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.resume()
        } else {
            permits += 1
        }
    }
}

/// 4-Wave predictive preloader (strictly unmetered Wi-Fi only for video preloading) with
/// origin rate-limit protection, user-priority yielding, resume-aware episode targeting,
/// and Watch Next escalation up to 20 MB.
public actor AnimePreloader {
    private static let wave1StartupGraceMs: Int64 = 350
    private static let wave2OriginPacingMs: Int64 = 150
    private static let maxOriginBackoffMs: Int64 = 15_000
    private static let defaultEpDurationMs: Int64 = 24 * 60_000
    private static let defaultOpEndMs: Int64 = 85_000

    public typealias ImagePreloadHandler = @Sendable (_ urls: [String], _ targetSize: ImageTargetSize) async -> Void

    private let repository: AnimeHeavenRepository
    private let skipTimesClient: SkipTimesClient
    private let chunkBooster: StreamingChunkBooster
    private let networkPolicy: NetworkPolicy
    private let imagePreloadHandler: ImagePreloadHandler?

    private let originHtmlGate = AsyncPermitGate(permits: 2)
    private let videoWarmupGate = AsyncPermitGate(permits: 2)

    private var warmedDetails = Set<String>()
    private var warmedCatalogs = Set<String>()
    private var warmedEpisodes = Set<String>()
    private var warmedVideoBytesByEpisode: [String: Int64] = [:]
    private var lastHomeSignature: String?
    private var lastHomeFeed: HomeFeed?
    private var lastContinueItems: [ContinueWatchingItem] = []
    private var lastTopContinueKey: String?
    private var foregroundUserWorkCount: Int = 0
    private var homeEcosystemTask: Task<Void, Never>?
    private var detailPreloadTask: Task<Void, Never>?
    private var originBackoffUntilMs: Int64 = 0
    private var originBackoffDurationMs: Int64 = 0

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

    public func onUnmeteredNetworkAvailable() {
        guard let feed = lastHomeFeed else { return }
        lastHomeSignature = nil
        preloadHomeEcosystem(feed: feed, continueItems: lastContinueItems)
    }

    public func preloadImages(
        urls: [String],
        maxCount: Int = 12,
        targetSize: ImageTargetSize = .standardCard
    ) {
        guard networkPolicy.allowBackgroundCatalogPreload,
              let handler = imagePreloadHandler, !urls.isEmpty, maxCount > 0 else { return }
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
        lastHomeFeed = feed
        lastContinueItems = continueItems
        guard networkPolicy.allowBackgroundCatalogPreload else { return }

        let sig = "\(feed.banners.first?.animeId ?? "")|\(feed.scheduleItems.count)|\(feed.popularItems.count)|\(networkPolicy.effectiveMode.rawValue)|" +
            continueItems.prefix(5).map(\.targetEpisodeKey).joined(separator: ",")
        guard sig != lastHomeSignature else { return }
        lastHomeSignature = sig

        preloadImages(urls: feed.banners.map(\.bannerImageUrl), maxCount: 5, targetSize: .heroBanner)
        preloadImages(urls: continueItems.map(\.coverUrl), maxCount: 8, targetSize: .continueCard)
        preloadImages(urls: feed.popularItems.map(\.coverUrl), maxCount: 12, targetSize: .popularCard)
        preloadImages(urls: feed.scheduleItems.map(\.coverUrl), maxCount: 16, targetSize: .standardCard)

        homeEcosystemTask?.cancel()
        homeEcosystemTask = Task {
            var warmedAnimeVideoIds = Set<String>()

            // Wave 0: Top 3 Continue Watching + Hero Banner #1
            let cwCap = networkPolicy.maxContinueWatchingCount
            let wave0Cw = Array(continueItems.prefix(min(3, cwCap)))
            for (idx, cw) in wave0Cw.enumerated() {
                if Task.isCancelled { return }
                warmedAnimeVideoIds.insert(cw.animeId)
                let bytes = networkPolicy.continueVideoBytes(index: idx)
                if idx == 0 { lastTopContinueKey = cw.targetEpisodeKey }
                _ = await warmEpisode(
                    episodeKey: cw.targetEpisodeKey,
                    animeId: cw.animeId,
                    animeTitle: cw.animeTitle,
                    episodeLabel: cw.targetEpisodeLabel,
                    videoBytes: bytes,
                    resumePositionMs: cw.resumePositionMs,
                    estimatedDurationMs: cw.durationMs,
                    highPriority: true
                )
            }

            if let firstBanner = feed.banners.first, warmedAnimeVideoIds.insert(firstBanner.animeId).inserted {
                let bytes = networkPolicy.bannerVideoBytes(index: 0)
                await warmAnimeWithPrimaryVideo(animeId: firstBanner.animeId, videoBytes: bytes, highPriority: true)
            }

            try? await Task.sleep(for: .milliseconds(Self.wave1StartupGraceMs))
            if Task.isCancelled { return }

            // Wave 1: Remaining Continue Watching (#4-#15)
            if cwCap > 3 && continueItems.count > 3 {
                for (offsetIdx, cw) in continueItems.dropFirst(3).prefix(cwCap - 3).enumerated() {
                    if Task.isCancelled { return }
                    await yieldWhileUserBusy()
                    warmedAnimeVideoIds.insert(cw.animeId)
                    let bytes = networkPolicy.continueVideoBytes(index: offsetIdx + 3)
                    _ = await warmEpisode(
                        episodeKey: cw.targetEpisodeKey,
                        animeId: cw.animeId,
                        animeTitle: cw.animeTitle,
                        episodeLabel: cw.targetEpisodeLabel,
                        videoBytes: bytes,
                        resumePositionMs: cw.resumePositionMs,
                        estimatedDurationMs: cw.durationMs,
                        highPriority: false
                    )
                }
            }

            // Wave 1: Remaining Hero Banners (#2-#5)
            let bannerCap = networkPolicy.bannerVideoCount
            if bannerCap > 1 && feed.banners.count > 1 {
                for (offsetIdx, banner) in feed.banners.dropFirst(1).prefix(bannerCap - 1).enumerated() {
                    if Task.isCancelled { return }
                    await yieldWhileUserBusy()
                    if warmedAnimeVideoIds.insert(banner.animeId).inserted {
                        let bytes = networkPolicy.bannerVideoBytes(index: offsetIdx + 1)
                        await warmAnimeWithPrimaryVideo(animeId: banner.animeId, videoBytes: bytes, highPriority: false)
                    }
                }
            }

            // Wave 1: Bookmarks (up to 15)
            let bmDetailCap = networkPolicy.bookmarkDetailCount
            if bmDetailCap > 0 {
                let bmIds = await repository.getOrderedBookmarkIds(limit: bmDetailCap)
                let bmVideoCap = networkPolicy.bookmarkVideoCount
                let bmBytes = networkPolicy.bookmarkVideoBytes
                for (idx, animeId) in bmIds.enumerated() {
                    if Task.isCancelled { return }
                    await yieldWhileUserBusy()
                    let vBytes: Int64 = (idx < bmVideoCap && warmedAnimeVideoIds.insert(animeId).inserted) ? bmBytes : 0
                    await warmAnimeWithPrimaryVideo(animeId: animeId, videoBytes: vBytes, highPriority: false, paced: true)
                }
            }

            // Wave 2: Home Popular Strip + Home Schedule (every show's start/resume seconds, paced)
            let showVideoBytes = networkPolicy.homeShowVideoBytes
            for card in feed.popularItems.prefix(networkPolicy.homePopularDetailCount) {
                if Task.isCancelled { return }
                await yieldWhileUserBusy()
                let vBytes: Int64 = warmedAnimeVideoIds.insert(card.id).inserted ? showVideoBytes : 0
                await warmAnimeWithPrimaryVideo(animeId: card.id, videoBytes: vBytes, highPriority: false, paced: true)
            }
            for card in feed.scheduleItems.prefix(networkPolicy.homeScheduleDetailCount) {
                if Task.isCancelled { return }
                await yieldWhileUserBusy()
                let vBytes: Int64 = warmedAnimeVideoIds.insert(card.id).inserted ? showVideoBytes : 0
                await warmAnimeWithPrimaryVideo(animeId: card.id, videoBytes: vBytes, highPriority: false, paced: true)
            }

            // Wave 2b: Background catalog tabs
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

    public func preloadAnimeDetail(
        detail: AnimeDetail,
        primaryEpisodeKey: String?,
        primaryEpisodeLabel: String?,
        primaryResumeMs: Int64 = -1,
        primaryDurationMs: Int64 = 0
    ) {
        guard networkPolicy.allowBackgroundCatalogPreload else { return }
        if let banner = detail.bannerUrl {
            preloadImages(urls: [banner], maxCount: 1, targetSize: .heroBanner)
        }
        preloadImages(urls: [detail.posterUrl], maxCount: 1, targetSize: .detailPoster)
        preloadImages(urls: (detail.relatedShows + detail.similarShows).map(\.coverUrl), maxCount: 12, targetSize: .standardCard)

        detailPreloadTask?.cancel()
        detailPreloadTask = Task {
            if let primaryEpisodeKey, !primaryEpisodeKey.isEmpty {
                let primaryBytes = networkPolicy.detailPrimaryVideoBytes
                var resolvedResumeMs = primaryResumeMs
                var resolvedDurMs = primaryDurationMs
                if resolvedResumeMs < 0 || resolvedDurMs <= 0 {
                    if let saved = await repository.getSavedProgress(episodeKey: primaryEpisodeKey) {
                        if resolvedResumeMs < 0 {
                            resolvedResumeMs = WatchProgressLogic.resolveResumePositionMs(
                                positionMs: saved.positionMs,
                                durationMs: saved.durationMs
                            )
                        }
                        if resolvedDurMs <= 0 { resolvedDurMs = saved.durationMs }
                    } else if resolvedResumeMs < 0 {
                        resolvedResumeMs = 0
                    }
                }
                _ = await warmEpisode(
                    episodeKey: primaryEpisodeKey,
                    animeId: detail.id,
                    animeTitle: detail.title,
                    episodeLabel: primaryEpisodeLabel ?? "",
                    videoBytes: primaryBytes,
                    resumePositionMs: max(0, resolvedResumeMs),
                    estimatedDurationMs: max(0, resolvedDurMs),
                    highPriority: true
                )

                if let epIdx = detail.episodes.firstIndex(where: { $0.key == primaryEpisodeKey }), epIdx > 0 {
                    let followEp = detail.episodes[epIdx - 1]
                    await yieldWhileUserBusy()
                    _ = await warmEpisode(
                        episodeKey: followEp.key,
                        animeId: detail.id,
                        animeTitle: detail.title,
                        episodeLabel: followEp.numberLabel,
                        videoBytes: networkPolicy.detailFollowupVideoBytes,
                        highPriority: false
                    )
                }
            }
        }
    }

    public func preloadCatalogPage(items: [AnimeCard]) {
        guard networkPolicy.allowBackgroundCatalogPreload else { return }
        preloadImages(urls: items.map(\.coverUrl), maxCount: 20, targetSize: .standardCard)
        let detailCap = networkPolicy.catalogDetailCount
        let videoCap = networkPolicy.catalogVideoCount
        let videoBytes = networkPolicy.homeShowVideoBytes
        guard detailCap > 0 else { return }
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            for (idx, card) in items.prefix(detailCap).enumerated() {
                if Task.isCancelled { return }
                await self.yieldWhileUserBusy()
                let vBytes: Int64 = idx < videoCap ? videoBytes : 0
                await self.warmAnimeWithPrimaryVideo(animeId: card.id, videoBytes: vBytes, highPriority: false, paced: true)
            }
        }
    }

    public func preloadBookmarksEcosystem(bookmarks: [BookmarkRecord], continueItems: [ContinueWatchingItem]) {
        guard networkPolicy.allowBackgroundCatalogPreload else { return }
        preloadImages(urls: bookmarks.map(\.coverUrl), maxCount: 16, targetSize: .standardCard)
        preloadImages(urls: continueItems.map(\.coverUrl), maxCount: 8, targetSize: .continueCard)
        let bmVideoCap = networkPolicy.bookmarkVideoCount
        let bmBytes = networkPolicy.bookmarkVideoBytes
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            for (idx, bm) in bookmarks.prefix(15).enumerated() {
                if Task.isCancelled { return }
                await self.yieldWhileUserBusy()
                let vBytes: Int64 = idx < bmVideoCap ? bmBytes : 0
                await self.warmAnimeWithPrimaryVideo(animeId: bm.animeId, videoBytes: vBytes, highPriority: false, paced: true)
            }
        }
    }

    public func warmAnimeDetail(animeId: String) {
        guard networkPolicy.allowBackgroundCatalogPreload,
              !animeId.isEmpty, warmedDetails.insert(animeId).inserted else { return }
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            _ = await self.fetchDetailWithPacing(animeId: animeId, highPriority: false, paced: false)
        }
    }

    @discardableResult
    public func warmEpisode(
        episodeKey: String,
        animeId: String?,
        animeTitle: String,
        episodeLabel: String,
        videoBytes: Int64,
        resumePositionMs: Int64 = 0,
        estimatedDurationMs: Int64 = 0,
        highPriority: Bool = true,
        paced: Bool = false
    ) async -> PreparedEpisodeWarmup? {
        guard !episodeKey.isEmpty, networkPolicy.allowBackgroundCatalogPreload else { return nil }
        let effectiveBytes: Int64 = networkPolicy.allowBackgroundVideoPreload ? videoBytes : 0
        let prevWarmedBytes = warmedVideoBytesByEpisode[episodeKey] ?? 0
        let first = warmedEpisodes.insert(episodeKey).inserted
        let needsMoreVideo = effectiveBytes > prevWarmedBytes
        if !first && !needsMoreVideo {
            return await buildPreparedSnapshotIfWarm(
                episodeKey: episodeKey,
                resumePositionMs: resumePositionMs,
                estimatedDurationMs: estimatedDurationMs
            )
        }

        let stream: EpisodeStream
        if let cached = await repository.peekCachedStream(episodeKey: episodeKey),
           !(await repository.isCachedStreamStale(episodeKey: episodeKey)),
           !cached.videoSources.isEmpty {
            stream = cached
        } else {
            if !highPriority { await awaitOriginBackoffIfNeeded() }
            do {
                stream = try await withGate(originHtmlGate) {
                    if paced { try? await Task.sleep(for: .milliseconds(Self.wave2OriginPacingMs)) }
                    return try await self.repository.resolveEpisodeStream(episodeKey: episodeKey, animeId: animeId)
                }
                recordOriginOutcome(error: nil)
            } catch {
                recordOriginOutcome(error: error)
                warmedEpisodes.remove(episodeKey)
                return nil
            }
        }

        let title = stream.animeTitle.isEmpty ? animeTitle : stream.animeTitle
        let label = stream.episodeLabel.isEmpty ? episodeLabel : stream.episodeLabel
        let epNum = SkipTimesParser.parseEpisodeNumber(label)
        if highPriority, let epNum, !title.isEmpty {
            Task.detached(priority: .utility) { [skipTimesClient] in
                _ = await skipTimesClient.fetchSkipTimes(animeTitle: title, episodeNumber: epNum)
            }
        }

        guard !stream.videoSources.isEmpty else { return nil }

        return await withGate(videoWarmupGate) {
            if effectiveBytes > 0 {
                let existingIdx = await self.chunkBooster.videoIndex(for: episodeKey)
                let durMs = estimatedDurationMs > 0
                    ? estimatedDurationMs
                    : ((existingIdx?.durationMs ?? 0) > 0 ? (existingIdx?.durationMs ?? 0) : Self.defaultEpDurationMs)
                if let readyCacheKey = await self.chunkBooster.preloadVideoHeadAndAwait(
                    episodeKey: episodeKey,
                    allSources: stream.videoSources,
                    bytesToCache: effectiveBytes,
                    resumePositionMs: resumePositionMs,
                    estimatedDurationMs: durMs,
                    opEndMs: Self.defaultOpEndMs
                ) {
                    self.recordWarmedBytes(episodeKey: episodeKey, bytes: effectiveBytes)
                    let ranked = self.chunkBooster.mirrorHealthTracker.rankMirrors(stream.videoSources)
                    let totalLen = await self.chunkBooster.resolveTotalLength(urls: ranked, episodeKey: episodeKey)
                    let refreshedDur = (await self.chunkBooster.videoIndex(for: episodeKey)?.durationMs) ?? estimatedDurationMs
                    var skipTimes = EpisodeSkipTimes()
                    if highPriority, let epNum, !title.isEmpty {
                        skipTimes = await self.skipTimesClient.fetchSkipTimes(animeTitle: title, episodeNumber: epNum)
                    }
                    return PreparedEpisodeWarmup(
                        episodeKey: episodeKey,
                        stream: stream,
                        rankedMirrors: ranked,
                        cacheKey: readyCacheKey,
                        totalLength: totalLen,
                        skipTimes: skipTimes,
                        durationMs: refreshedDur
                    )
                }
            } else {
                await self.chunkBooster.probeMirrorsSpeed(urls: stream.videoSources)
            }
            return nil
        }
    }

    public func resetSessionMarkers() {
        homeEcosystemTask?.cancel()
        detailPreloadTask?.cancel()
        warmedDetails.removeAll()
        warmedCatalogs.removeAll()
        warmedEpisodes.removeAll()
        warmedVideoBytesByEpisode.removeAll()
        lastHomeSignature = nil
        lastTopContinueKey = nil
        originBackoffUntilMs = 0
        originBackoffDurationMs = 0
    }

    // MARK: - Private Helpers

    private func recordWarmedBytes(episodeKey: String, bytes: Int64) {
        warmedVideoBytesByEpisode[episodeKey] = max(warmedVideoBytesByEpisode[episodeKey] ?? 0, bytes)
    }

    private func buildPreparedSnapshotIfWarm(
        episodeKey: String,
        resumePositionMs: Int64,
        estimatedDurationMs: Int64
    ) async -> PreparedEpisodeWarmup? {
        guard let stream = await repository.peekCachedStream(episodeKey: episodeKey),
              !stream.videoSources.isEmpty else { return nil }
        let ranked = chunkBooster.mirrorHealthTracker.rankMirrors(stream.videoSources)
        guard let primary = ranked.first else { return nil }
        let cacheKey = await chunkBooster.resolveCacheKey(episodeKey: episodeKey, url: primary)
        let totalLen = await chunkBooster.resolveTotalLength(urls: ranked, episodeKey: episodeKey)
        guard totalLen >= MirrorHealthTracker.minValidVideoBytes else { return nil }
        let ready = await chunkBooster.hasPlayableHotWindow(
            episodeKey: episodeKey,
            cacheKey: cacheKey,
            resumePositionMs: resumePositionMs,
            estimatedDurationMs: estimatedDurationMs
        )
        guard ready else { return nil }
        let dur = (await chunkBooster.videoIndex(for: episodeKey)?.durationMs) ?? estimatedDurationMs
        return PreparedEpisodeWarmup(
            episodeKey: episodeKey,
            stream: stream,
            rankedMirrors: ranked,
            cacheKey: cacheKey,
            totalLength: totalLen,
            skipTimes: EpisodeSkipTimes(),
            durationMs: dur
        )
    }

    private func warmAnimeWithPrimaryVideo(
        animeId: String,
        videoBytes: Int64,
        highPriority: Bool,
        paced: Bool = false
    ) async {
        guard networkPolicy.allowBackgroundCatalogPreload, !animeId.isEmpty else { return }
        let detail: AnimeDetail?
        if let cached = await repository.peekCachedDetail(animeId: animeId) {
            detail = cached
        } else {
            detail = await fetchDetailWithPacing(animeId: animeId, highPriority: highPriority, paced: paced)
        }
        guard let detail, videoBytes > 0, networkPolicy.allowBackgroundVideoPreload, !detail.episodes.isEmpty else { return }

        let target = await resolveTargetEpisode(detail: detail)
        guard let target else { return }
        _ = await warmEpisode(
            episodeKey: target.episodeKey,
            animeId: detail.id,
            animeTitle: detail.title,
            episodeLabel: target.episodeLabel,
            videoBytes: videoBytes,
            resumePositionMs: target.resumePositionMs,
            estimatedDurationMs: target.durationMs,
            highPriority: highPriority,
            paced: paced
        )
    }

    private func resolveTargetEpisode(detail: AnimeDetail) async -> (episodeKey: String, episodeLabel: String, resumePositionMs: Int64, durationMs: Int64)? {
        if let latest = await repository.peekLatestProgressForAnime(animeId: detail.id) {
            if !latest.isWatched && latest.positionMs > WatchProgressLogic.minResumeThresholdMs {
                let resumeMs = WatchProgressLogic.resolveResumePositionMs(
                    positionMs: latest.positionMs,
                    durationMs: latest.durationMs
                )
                return (latest.episodeKey, latest.episodeLabel, resumeMs, latest.durationMs)
            }
            if latest.isWatched {
                if let idx = detail.episodes.firstIndex(where: { $0.key == latest.episodeKey }), idx > 0 {
                    let nextEp = detail.episodes[idx - 1]
                    return (nextEp.key, nextEp.numberLabel, 0, 0)
                }
                if let nextKey = latest.nextEpisodeKey, !nextKey.isEmpty {
                    return (nextKey, latest.nextEpisodeLabel ?? "", 0, 0)
                }
            }
        }
        guard let firstEp = detail.episodes.last else { return nil }
        return (firstEp.key, firstEp.numberLabel, 0, 0)
    }

    private func fetchDetailWithPacing(animeId: String, highPriority: Bool, paced: Bool) async -> AnimeDetail? {
        if await repository.hasFreshDetailInMemory(animeId: animeId) {
            return await repository.peekCachedDetail(animeId: animeId)
        }
        if !highPriority { await awaitOriginBackoffIfNeeded() }
        do {
            let (detail, _) = try await withGate(originHtmlGate) {
                if paced { try? await Task.sleep(for: .milliseconds(Self.wave2OriginPacingMs)) }
                return try await self.repository.getAnimeDetail(animeId: animeId)
            }
            recordOriginOutcome(error: nil)
            if let banner = detail.bannerUrl {
                preloadImages(urls: [banner], maxCount: 1, targetSize: .heroBanner)
            }
            preloadImages(urls: [detail.posterUrl], maxCount: 1, targetSize: .detailPoster)
            return detail
        } catch {
            recordOriginOutcome(error: error)
            warmedDetails.remove(animeId)
            return nil
        }
    }

    private func warmCatalogTab(cacheKey: String, path: String, isPopular: Bool) async {
        guard warmedCatalogs.insert(cacheKey).inserted else { return }
        if await repository.hasFreshChartInMemory(cacheKey: cacheKey) { return }
        await awaitOriginBackoffIfNeeded()
        do {
            let (result, _) = try await withGate(originHtmlGate) {
                try await self.repository.getChartFeed(
                    cacheKey: cacheKey,
                    relativePath: path,
                    isPopularRank: isPopular
                )
            }
            recordOriginOutcome(error: nil)
            preloadImages(urls: result.items.map(\.coverUrl), maxCount: 16, targetSize: .standardCard)
        } catch {
            recordOriginOutcome(error: error)
        }
    }

    private func awaitOriginBackoffIfNeeded() async {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let waitMs = originBackoffUntilMs - nowMs
        if waitMs > 0 {
            try? await Task.sleep(for: .milliseconds(min(waitMs, Self.maxOriginBackoffMs)))
        }
    }

    private func recordOriginOutcome(error: Error?) {
        guard let error else {
            originBackoffDurationMs = 0
            return
        }
        let desc = error.localizedDescription
        if desc.contains("429") || desc.contains("503") {
            let next: Int64
            if originBackoffDurationMs <= 0 {
                next = 2_000
            } else if originBackoffDurationMs < 5_000 {
                next = 5_000
            } else {
                next = Self.maxOriginBackoffMs
            }
            originBackoffDurationMs = next
            originBackoffUntilMs = Int64(Date().timeIntervalSince1970 * 1000) + next
        }
    }

    private func withGate<T>(_ gate: AsyncPermitGate, _ operation: () async throws -> T) async rethrows -> T {
        await gate.acquire()
        do {
            let value = try await operation()
            await gate.release()
            return value
        } catch {
            await gate.release()
            throw error
        }
    }

    private func yieldWhileUserBusy() async {
        var waited = 0
        while foregroundUserWorkCount > 0 && waited < 20 && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
            waited += 1
        }
    }
}
