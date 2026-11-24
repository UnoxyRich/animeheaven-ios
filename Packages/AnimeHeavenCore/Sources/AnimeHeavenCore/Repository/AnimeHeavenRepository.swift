import Foundation

public struct CachedEntry<T: Sendable>: Sendable {
    public let value: T
    public let fetchedAt: Int64

    public init(value: T, fetchedAt: Int64) {
        self.value = value
        self.fetchedAt = fetchedAt
    }

    public func isStale(softTTLMs: Int64, nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> Bool {
        nowMs - fetchedAt >= softTTLMs
    }
}

public enum WatchProgressLogic {
    public static let minResumeThresholdMs: Int64 = 10_000
    public static let maxResumeRatio: Float = 0.92
    public static let watchedRatio: Float = 0.85

    public static func isEpisodeWatched(positionMs: Int64, durationMs: Int64) -> Bool {
        guard durationMs > 0 else { return false }
        return Float(positionMs) / Float(durationMs) >= watchedRatio
    }

    public static func resolveResumePositionMs(positionMs: Int64, durationMs: Int64) -> Int64 {
        if positionMs <= minResumeThresholdMs { return 0 }
        if durationMs > 0 && Float(positionMs) / Float(durationMs) >= maxResumeRatio {
            return 0
        }
        return positionMs
    }

    public static func buildContinueWatchingItem(from progress: WatchProgressRecord) -> ContinueWatchingItem? {
        if progress.isWatched {
            guard let nextKey = progress.nextEpisodeKey, !nextKey.isEmpty else { return nil }
            return ContinueWatchingItem(
                animeId: progress.animeId,
                animeTitle: progress.animeTitle,
                coverUrl: progress.coverUrl,
                targetEpisodeKey: nextKey,
                targetEpisodeLabel: progress.nextEpisodeLabel ?? "Next Episode",
                isNextEpisode: true,
                resumePositionMs: 0,
                durationMs: 0,
                lastWatchedLabel: progress.episodeLabel
            )
        } else if progress.positionMs > minResumeThresholdMs {
            return ContinueWatchingItem(
                animeId: progress.animeId,
                animeTitle: progress.animeTitle,
                coverUrl: progress.coverUrl,
                targetEpisodeKey: progress.episodeKey,
                targetEpisodeLabel: progress.episodeLabel,
                isNextEpisode: false,
                resumePositionMs: progress.positionMs,
                durationMs: progress.durationMs,
                lastWatchedLabel: progress.episodeLabel
            )
        }
        return nil
    }
}

public actor AnimeHeavenRepository {
    public static let ttlHomeMs: Int64 = 5 * 60 * 1000
    public static let ttlChartMs: Int64 = 5 * 60 * 1000
    public static let ttlSeasonalMs: Int64 = 30 * 60 * 1000
    public static let ttlSearchMs: Int64 = 30 * 60 * 1000
    public static let ttlDetailMs: Int64 = 15 * 60 * 1000
    public static let ttlGateMs: Int64 = 15 * 60 * 1000
    private static let maxDiskRetentionMs: Int64 = 14 * 24 * 60 * 60 * 1000
    private static let homeSnapshotFilename = "home_snapshot.v1.json"
    private static let keyHome = "home"

    private let client: AnimeHeavenClient
    public let database: SQLiteDatabase
    private let snapshotDirectory: URL?
    private let coalescer = RequestCoalescer<String>()

    private var cachedHome: CachedEntry<HomeFeed>?
    private let cachedCharts = LruCache<String, CachedEntry<ChartFeedResult>>(maxEntries: 24)
    private let cachedGrids = LruCache<String, CachedEntry<ChartFeedResult>>(maxEntries: 24)
    private let cachedDetails = LruCache<String, CachedEntry<AnimeDetail>>(maxEntries: 64)
    private let cachedStreams = LruCache<String, CachedEntry<EpisodeStream>>(maxEntries: 48)
    private let cachedFastSearch = LruCache<String, CachedEntry<[FastSearchItem]>>(maxEntries: 100)

    private var _seasonHeader: (path: String?, label: String?) = (nil, nil)

    private var cacheGeneration: UInt64 = 0
    private var cacheClearsInProgress = 0
    private let decoder = JSONDecoder()

    public init(
        client: AnimeHeavenClient,
        database: SQLiteDatabase,
        snapshotDirectory: URL? = nil
    ) {
        self.client = client
        self.database = database
        self.snapshotDirectory = snapshotDirectory
    }

    public func seasonHeader() -> (path: String?, label: String?) {
        _seasonHeader
    }

    public func peekCachedHomeFeed() -> HomeFeed? {
        cachedHome?.value
    }

    public func hasFreshDetailInMemory(animeId: String) -> Bool {
        guard let entry = cachedDetails.get(animeId) else { return false }
        return !entry.isStale(softTTLMs: Self.ttlDetailMs)
    }

    public func hasFreshChartInMemory(cacheKey: String, ttlMs: Int64 = ttlChartMs) -> Bool {
        guard let entry = cachedCharts.get(cacheKey) else { return false }
        return !entry.isStale(softTTLMs: ttlMs)
    }

    /// Reads `home_snapshot.v1.json` directly before SQLite opens for near-instant cold start.
    public func hydrateHomeFast() -> HomeFeed? {
        if let existing = cachedHome?.value { return existing }
        guard let snapshotURL = snapshotFileURL(),
              let data = try? Data(contentsOf: snapshotURL),
              let envelope = try? decoder.decode(HomeSnapshotEnvelope.self, from: data) else {
            return nil
        }
        cachedHome = CachedEntry(value: envelope.feed, fetchedAt: envelope.fetchedAt)
        updateSeasonHeader(from: envelope.feed)
        return envelope.feed
    }

    /// Hydrates cached Home + recent details + Continue Watching from SQLite off main thread.
    public func warmUpFromDisk() async -> (feed: HomeFeed?, continueItems: [ContinueWatchingItem]) {
        if cachedHome == nil, let dbRow = await database.getWebCache(cacheKey: Self.keyHome) {
            if let feed = decodeHome(from: dbRow) {
                cachedHome = CachedEntry(value: feed, fetchedAt: dbRow.fetchedAt)
                updateSeasonHeader(from: feed)
            }
        }
        let recentDetails = await database.getRecentCachedDetails(limit: 12)
        for row in recentDetails {
            let animeId = String(row.cacheKey.dropFirst("detail:".count))
            if let json = row.parsedJson?.data(using: .utf8),
               let detail = try? decoder.decode(AnimeDetail.self, from: json) {
                cachedDetails.set(animeId, value: CachedEntry(value: detail, fetchedAt: row.fetchedAt))
            }
        }
        let continueItems = await getContinueWatching()
        return (cachedHome?.value, continueItems)
    }

    // MARK: - Home & Catalogs (Offline-First SWR)

    public func getHomeFeed(forceRefresh: Bool = false) async throws -> (feed: HomeFeed, isStale: Bool) {
        if !forceRefresh {
            if let mem = cachedHome {
                return (mem.value, mem.isStale(softTTLMs: Self.ttlHomeMs))
            }
            if let snap = hydrateHomeFast(), let mem = cachedHome {
                return (snap, mem.isStale(softTTLMs: Self.ttlHomeMs))
            }
            if let row = await database.getWebCache(cacheKey: Self.keyHome),
               let feed = decodeHome(from: row) {
                let entry = CachedEntry(value: feed, fetchedAt: row.fetchedAt)
                cachedHome = entry
                updateSeasonHeader(from: feed)
                return (feed, entry.isStale(softTTLMs: Self.ttlHomeMs))
            }
        }
        let fresh = try await refreshHomeFeed()
        return (fresh, false)
    }

    @discardableResult
    public func refreshHomeFeed() async throws -> HomeFeed {
        let generation = cacheGeneration
        let html = try await coalescer.getOrFetch(key: "\(generation):\(Self.keyHome)") { [client] in
            try await client.fetchHtml(relativePath: "index.php")
        }
        let feed = AnimeHeavenParser.parseHome(html: html)
        guard canPersist(generation) else { return feed }
        let now = currentTimeMs()
        cachedHome = CachedEntry(value: feed, fetchedAt: now)
        updateSeasonHeader(from: feed)
        persistHomeAsync(feed: feed, fetchedAt: now)
        return feed
    }

    public func getChartFeed(
        cacheKey: String,
        relativePath: String,
        isPopularRank: Bool,
        softTTLMs: Int64 = ttlChartMs,
        forceRefresh: Bool = false
    ) async throws -> (result: ChartFeedResult, isStale: Bool) {
        if !forceRefresh {
            if let mem = cachedCharts.get(cacheKey) {
                return (mem.value, mem.isStale(softTTLMs: softTTLMs))
            }
            if let row = await database.getWebCache(cacheKey: cacheKey),
               let parsed = decodeChart(from: row, isPopularRank: isPopularRank) {
                let entry = CachedEntry(value: parsed, fetchedAt: row.fetchedAt)
                cachedCharts.set(cacheKey, value: entry)
                return (parsed, entry.isStale(softTTLMs: softTTLMs))
            }
        }
        let fresh = try await refreshChartFeed(
            cacheKey: cacheKey,
            relativePath: relativePath,
            isPopularRank: isPopularRank
        )
        return (fresh, false)
    }

    @discardableResult
    public func refreshChartFeed(
        cacheKey: String,
        relativePath: String,
        isPopularRank: Bool
    ) async throws -> ChartFeedResult {
        let generation = cacheGeneration
        let html = try await coalescer.getOrFetch(key: "\(generation):\(cacheKey)") { [client] in
            try await client.fetchHtml(relativePath: relativePath)
        }
        let result = AnimeHeavenParser.parseChartPage(html: html, isPopularRank: isPopularRank)
        guard canPersist(generation) else { return result }
        let now = currentTimeMs()
        cachedCharts.set(cacheKey, value: CachedEntry(value: result, fetchedAt: now))
        persistCodableAsync(cacheKey: cacheKey, value: result, fetchedAt: now)
        return result
    }

    public func getGridFeed(
        cacheKey: String,
        relativePath: String,
        softTTLMs: Int64 = ttlSearchMs,
        forceRefresh: Bool = false
    ) async throws -> (result: ChartFeedResult, isStale: Bool) {
        if !forceRefresh {
            if let mem = cachedGrids.get(cacheKey) {
                return (mem.value, mem.isStale(softTTLMs: softTTLMs))
            }
            if let row = await database.getWebCache(cacheKey: cacheKey),
               let parsed = decodeGrid(from: row) {
                let entry = CachedEntry(value: parsed, fetchedAt: row.fetchedAt)
                cachedGrids.set(cacheKey, value: entry)
                return (parsed, entry.isStale(softTTLMs: softTTLMs))
            }
        }
        let fresh = try await refreshGridFeed(cacheKey: cacheKey, relativePath: relativePath)
        return (fresh, false)
    }

    @discardableResult
    public func refreshGridFeed(cacheKey: String, relativePath: String) async throws -> ChartFeedResult {
        let generation = cacheGeneration
        let html = try await coalescer.getOrFetch(key: "\(generation):\(cacheKey)") { [client] in
            try await client.fetchHtml(relativePath: relativePath)
        }
        let result = AnimeHeavenParser.parseSimilarGrid(html: html)
        guard canPersist(generation) else { return result }
        let now = currentTimeMs()
        cachedGrids.set(cacheKey, value: CachedEntry(value: result, fetchedAt: now))
        persistCodableAsync(cacheKey: cacheKey, value: result, fetchedAt: now)
        return result
    }

    // MARK: - Detail & Episode Gate

    public func getAnimeDetail(
        animeId: String,
        forceRefresh: Bool = false
    ) async throws -> (detail: AnimeDetail, isStale: Bool) {
        let dbKey = "detail:\(animeId)"
        if !forceRefresh {
            if let mem = cachedDetails.get(animeId) {
                return (mem.value, mem.isStale(softTTLMs: Self.ttlDetailMs))
            }
            if let row = await database.getWebCache(cacheKey: dbKey),
               let parsed = decodeDetail(animeId: animeId, from: row) {
                let entry = CachedEntry(value: parsed, fetchedAt: row.fetchedAt)
                cachedDetails.set(animeId, value: entry)
                return (parsed, entry.isStale(softTTLMs: Self.ttlDetailMs))
            }
        }
        let fresh = try await refreshAnimeDetail(animeId: animeId)
        return (fresh, false)
    }

    @discardableResult
    public func refreshAnimeDetail(animeId: String) async throws -> AnimeDetail {
        let generation = cacheGeneration
        let dbKey = "detail:\(animeId)"
        let html = try await coalescer.getOrFetch(key: "\(generation):\(dbKey)") { [client] in
            try await client.fetchHtml(relativePath: "anime.php?\(animeId)")
        }
        let detail = AnimeHeavenParser.parseAnimeDetail(animeId: animeId, html: html)
        guard canPersist(generation) else { return detail }
        let now = currentTimeMs()
        cachedDetails.set(animeId, value: CachedEntry(value: detail, fetchedAt: now))
        persistCodableAsync(cacheKey: dbKey, value: detail, fetchedAt: now)
        return detail
    }

    public func resolveEpisodeStream(
        episodeKey: String,
        animeId: String?,
        forceRefresh: Bool = false
    ) async throws -> EpisodeStream {
        if !forceRefresh,
           let mem = cachedStreams.get(episodeKey),
           !mem.isStale(softTTLMs: Self.ttlGateMs),
           !mem.value.videoSources.isEmpty {
            return mem.value
        }
        let coalesceKey = "gate:\(episodeKey)"
        let html = try await coalescer.getOrFetch(key: coalesceKey) { [client] in
            try await client.fetchGateHtml(episodeKey: episodeKey, animeId: animeId)
        }
        let stream = AnimeHeavenParser.parseGatePage(episodeKey: episodeKey, html: html)
        let now = currentTimeMs()
        if !stream.videoSources.isEmpty {
            cachedStreams.set(episodeKey, value: CachedEntry(value: stream, fetchedAt: now))
        }
        return stream
    }

    // MARK: - Search & Random

    public func fastSearch(query: String) async throws -> [FastSearchItem] {
        let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count >= 2 else { return [] }
        let key = cleaned.lowercased()
        if let mem = cachedFastSearch.get(key), !mem.isStale(softTTLMs: Self.ttlSearchMs) {
            return mem.value
        }
        let html = try await coalescer.getOrFetch(key: "fast:\(key)") { [client] in
            try await client.fetchFastSearch(query: cleaned)
        }
        let items = AnimeHeavenParser.parseFastSearch(html: html)
        cachedFastSearch.set(key, value: CachedEntry(value: items, fetchedAt: currentTimeMs()))
        return items
    }

    public func fullSearch(query: String) async throws -> ChartFeedResult {
        let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return ChartFeedResult(title: "Search", items: []) }
        await database.upsertSearchHistory(query: cleaned, searchedAt: currentTimeMs())
        let encoded = AnimeHeavenClient.urlQueryEncode(cleaned)
        let result = try await getGridFeed(
            cacheKey: "search:\(cleaned.lowercased())",
            relativePath: "search.php?s=\(encoded)",
            softTTLMs: Self.ttlSearchMs
        )
        return result.result
    }

    public func getRandomAnimeId() async throws -> String {
        try await client.fetchRandomAnimeId()
    }

    // MARK: - Bookmarks, History & Watch Progress

    public func getBookmarks() async -> [BookmarkRecord] {
        await database.getAllBookmarks()
    }

    public func getBookmarkedIds() async -> Set<String> {
        await database.getBookmarkedIds()
    }

    public func isBookmarked(animeId: String) async -> Bool {
        await database.isBookmarked(animeId: animeId)
    }

    public func toggleBookmark(detail: AnimeDetail) async -> Bool {
        let exists = await database.isBookmarked(animeId: detail.id)
        if exists {
            await database.deleteBookmark(animeId: detail.id)
            return false
        } else {
            let latestEp = detail.episodes.first?.numberLabel ?? detail.episodesLabel
            await database.upsertBookmark(BookmarkRecord(
                animeId: detail.id,
                title: detail.title,
                coverUrl: detail.posterUrl,
                lastEpisodeLabel: latestEp,
                addedAt: currentTimeMs()
            ))
            return true
        }
    }

    public func removeBookmark(animeId: String) async {
        await database.deleteBookmark(animeId: animeId)
    }

    public func getContinueWatching() async -> [ContinueWatchingItem] {
        let latest = await database.getLatestWatchProgressPerAnime(limit: 30)
        return latest.compactMap(WatchProgressLogic.buildContinueWatchingItem(from:))
    }

    public func getWatchProgressMap(animeId: String) async -> [String: WatchProgressRecord] {
        let rows = await database.getWatchProgressByAnime(animeId: animeId)
        var map: [String: WatchProgressRecord] = [:]
        for row in rows {
            map[row.episodeKey] = row
        }
        return map
    }

    public func getResumePositionMs(episodeKey: String) async -> Int64 {
        guard let existing = await database.getWatchProgress(episodeKey: episodeKey) else { return 0 }
        return WatchProgressLogic.resolveResumePositionMs(
            positionMs: existing.positionMs,
            durationMs: existing.durationMs
        )
    }

    public func saveWatchProgress(
        episodeKey: String,
        animeId: String,
        animeTitle: String,
        coverUrl: String,
        episodeLabel: String,
        positionMs: Int64,
        durationMs: Int64,
        nextEpisodeKey: String?,
        nextEpisodeLabel: String?,
        forceWatched: Bool = false
    ) async {
        let existing = await database.getWatchProgress(episodeKey: episodeKey)
        let watched = forceWatched
            || (existing?.isWatched == true)
            || WatchProgressLogic.isEpisodeWatched(positionMs: positionMs, durationMs: durationMs)

        await database.upsertWatchProgress(WatchProgressRecord(
            episodeKey: episodeKey,
            animeId: animeId,
            animeTitle: animeTitle,
            coverUrl: coverUrl,
            episodeLabel: episodeLabel,
            positionMs: max(0, positionMs),
            durationMs: max(0, durationMs),
            isWatched: watched,
            nextEpisodeKey: nextEpisodeKey ?? existing?.nextEpisodeKey,
            nextEpisodeLabel: nextEpisodeLabel ?? existing?.nextEpisodeLabel,
            updatedAt: currentTimeMs()
        ))
    }

    public func clearWatchHistory() async {
        await database.clearWatchHistory()
    }

    public func getRecentSearches() async -> [String] {
        await database.getRecentSearches(limit: 10)
    }

    public func deleteSearchHistory(query: String) async {
        await database.deleteSearchHistory(query: query)
    }

    public func clearSearchHistory() async {
        await database.clearSearchHistory()
    }

    // MARK: - Maintenance & Memory Trim

    public func pruneExpiredCache() async {
        let cutoff = currentTimeMs() - Self.maxDiskRetentionMs
        await database.pruneWebCacheOlderThan(cutoffMs: cutoff)
    }

    public func clearWebCache() async {
        cacheGeneration &+= 1
        cacheClearsInProgress += 1
        defer {
            cacheClearsInProgress -= 1
            cacheGeneration &+= 1
        }
        cachedHome = nil
        cachedCharts.clear()
        cachedGrids.clear()
        cachedDetails.clear()
        cachedStreams.clear()
        cachedFastSearch.clear()
        await database.clearWebCache()
        if let url = snapshotFileURL() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    public func trimMemory(aggressive: Bool) {
        cachedFastSearch.clear()
        cachedCharts.clear()
        cachedGrids.clear()
        if aggressive {
            cachedDetails.clear()
            cachedStreams.clear()
        }
    }

    public func webCacheStats() async -> (pages: Int, bytes: Int64) {
        await database.webCacheStats()
    }

    // MARK: - Private Encoding / Persistence

    private struct HomeSnapshotEnvelope: Codable {
        let fetchedAt: Int64
        let feed: HomeFeed
    }

    private func snapshotFileURL() -> URL? {
        snapshotDirectory?.appendingPathComponent(Self.homeSnapshotFilename)
    }

    private func updateSeasonHeader(from feed: HomeFeed) {
        if feed.seasonPath != nil || feed.seasonLabel != nil {
            _seasonHeader = (feed.seasonPath, feed.seasonLabel)
        }
    }

    private func persistHomeAsync(feed: HomeFeed, fetchedAt: Int64) {
        let generation = cacheGeneration
        Task.detached(priority: .utility) { [weak self] in
            let enc = JSONEncoder()
            guard let data = try? enc.encode(feed), let json = String(data: data, encoding: .utf8) else { return }
            let envelope = HomeSnapshotEnvelope(fetchedAt: fetchedAt, feed: feed)
            await self?.commitPersist(
                WebCacheRecord(cacheKey: Self.keyHome, payload: "", fetchedAt: fetchedAt, parsedJson: json),
                generation: generation, snapshotData: try? enc.encode(envelope)
            )
        }
    }

    private func persistCodableAsync<T: Codable & Sendable>(
        cacheKey: String,
        value: T,
        fetchedAt: Int64
    ) {
        let generation = cacheGeneration
        Task.detached(priority: .utility) { [weak self] in
            let enc = JSONEncoder()
            guard let data = try? enc.encode(value),
                  let jsonString = String(data: data, encoding: .utf8) else {
                return
            }
            let record = WebCacheRecord(
                cacheKey: cacheKey,
                payload: "",
                fetchedAt: fetchedAt,
                parsedJson: jsonString
            )
            await self?.commitPersist(record, generation: generation)
        }
    }

    private func canPersist(_ generation: UInt64) -> Bool {
        cacheClearsInProgress == 0 && generation == cacheGeneration
    }

    private func commitPersist(_ record: WebCacheRecord, generation: UInt64, snapshotData: Data? = nil) async {
        guard canPersist(generation) else { return }
        await database.upsertWebCache(record)
        if canPersist(generation), let snapshotData, let url = snapshotFileURL() {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? snapshotData.write(to: url, options: .atomic)
        }
    }

    private func decodeHome(from row: WebCacheRecord) -> HomeFeed? {
        if let json = row.parsedJson?.data(using: .utf8),
           let decoded = try? decoder.decode(HomeFeed.self, from: json) {
            return decoded
        }
        guard !row.payload.isEmpty else { return nil }
        return AnimeHeavenParser.parseHome(html: row.payload)
    }

    private func decodeChart(from row: WebCacheRecord, isPopularRank: Bool) -> ChartFeedResult? {
        if let json = row.parsedJson?.data(using: .utf8),
           let decoded = try? decoder.decode(ChartFeedResult.self, from: json) {
            return decoded
        }
        guard !row.payload.isEmpty else { return nil }
        return AnimeHeavenParser.parseChartPage(html: row.payload, isPopularRank: isPopularRank)
    }

    private func decodeGrid(from row: WebCacheRecord) -> ChartFeedResult? {
        if let json = row.parsedJson?.data(using: .utf8),
           let decoded = try? decoder.decode(ChartFeedResult.self, from: json) {
            return decoded
        }
        guard !row.payload.isEmpty else { return nil }
        return AnimeHeavenParser.parseSimilarGrid(html: row.payload)
    }

    private func decodeDetail(animeId: String, from row: WebCacheRecord) -> AnimeDetail? {
        if let json = row.parsedJson?.data(using: .utf8),
           let decoded = try? decoder.decode(AnimeDetail.self, from: json) {
            return decoded
        }
        guard !row.payload.isEmpty else { return nil }
        return AnimeHeavenParser.parseAnimeDetail(animeId: animeId, html: row.payload)
    }

    private func currentTimeMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
