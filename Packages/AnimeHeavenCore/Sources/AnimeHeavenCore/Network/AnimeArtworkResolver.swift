import Foundation

/// Public metadata only. This session never shares cookies, HTTP cache or AnimeHeaven headers.
public actor AnimeArtworkResolver {
    private static let ttl: Int64 = 14 * 86_400_000
    private let database: SQLiteDatabase
    private let session: URLSession
    private let dataSaver: @Sendable () -> Bool
    private let cache = LruCache<String, WebCacheRecord>(maxEntries: 512)
    private var observers: [String: [UUID: AsyncStream<AnimeArtwork>.Continuation]] = [:]
    private let base = RequestCoalescer<AnimeArtwork?>()
    private let zip = RequestCoalescer<Data?>()
    private let kitsu = RequestCoalescer<Data?>()
    private let jikan = RequestCoalescer<Data?>()
    private let clock = ContinuousClock()
    private var nextRequest: [Provider: ContinuousClock.Instant] = [:]
    private var pausedUntil: [Provider: ContinuousClock.Instant] = [:]
    private var pending: [(ArtworkLookupRequest, CheckedContinuation<AnimeArtwork?, Never>)] = []
    private var batchTask: Task<Void, Never>?
    private var zipInFlight = 0
    private var zipWaiters: [CheckedContinuation<Void, Never>] = []
    private var generation: UInt64 = 0
    private var clearing = false

    private enum Provider: Hashable {
        case aniList, aniZip, kitsu, jikan

        var spacing: Duration {
            switch self {
            case .aniList: .milliseconds(2050)
            case .aniZip: .zero
            case .kitsu, .jikan: .milliseconds(1100)
            }
        }
    }

    public init(database: SQLiteDatabase, session: URLSession? = nil, dataSaver: @escaping @Sendable () -> Bool = { false }) {
        self.database = database
        self.dataSaver = dataSaver
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 9
        self.session = session ?? URLSession(configuration: config)
    }

    private var now: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    public func hydrateRecentFromDisk() async {
        let epoch = generation
        let rows = await database.getRecentArtwork(since: now - Self.ttl)
        guard generation == epoch, !clearing else { return }
        for row in rows.reversed() where cache.get(row.cacheKey) == nil { cache.set(row.cacheKey, value: row) }
    }

    public func trimMemory() { cache.clear() }

    public func updates(for request: ArtworkLookupRequest) -> AsyncStream<AnimeArtwork> {
        let key = request.animeKey
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: AnimeArtwork.self, bufferingPolicy: .bufferingNewest(1))
        observers[key, default: [:]][id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(key: key, id: id) }
        }
        return stream
    }

    private func removeObserver(key: String, id: UUID) {
        observers[key]?[id] = nil
        if observers[key]?.isEmpty == true { observers[key] = nil }
    }

    /// Prevent a provider response started before the Settings action from restoring cleared records.
    public func withCacheCleared(_ clear: @Sendable () async -> Void) async {
        generation &+= 1
        clearing = true
        cache.clear()
        await clear()
        clearing = false
    }

    public func cached(_ request: ArtworkLookupRequest) async -> AnimeArtwork? {
        for key in [request.animeKey, request.titleKey] {
            let epoch = generation
            let row: WebCacheRecord?
            if let inMemory = cache.get(key), now - inMemory.fetchedAt < Self.ttl {
                row = inMemory
            } else {
                row = await database.getWebCache(cacheKey: key)
            }
            guard generation == epoch, !clearing else { return nil }
            if let row, now - row.fetchedAt < Self.ttl,
               let value = try? JSONDecoder().decode(AnimeArtwork.self, from: Data(row.payload.utf8)) {
                cache.set(key, value: row)
                return value
            }
        }
        return nil
    }

    public func resolveMalId(title: String) async -> Int? {
        let request = ArtworkLookupRequest(animeId: "", title: title)
        if let id = await cached(request)?.malId { return id }
        let epoch = generation
        guard !clearing, let result = await aniList(request), epoch == generation else { return nil }
        await persist(result, for: request, epoch: epoch)
        return result.malId
    }

    public func resolve(_ request: ArtworkLookupRequest, slot: ArtworkSlot) async -> AnimeArtwork? {
        guard !clearing, !ArtworkTitleMatcher.normalize(request.title).isEmpty else { return nil }
        let epoch = generation
        let previous = await cached(request)
        guard !clearing, epoch == generation, !Task.isCancelled,
              request.priority != .cachedOnly, !dataSaver() || request.priority.rawValue >= ArtworkPriority.featured.rawValue else {
            return previous
        }
        var artwork = previous ?? AnimeArtwork()
        if artwork.anilistId == nil, let match = await aniList(request) {
            artwork.anilistId = match.anilistId
            artwork.malId = match.malId ?? artwork.malId
            artwork.aniListBanner = match.aniListBanner
            artwork.aniListPoster = match.aniListPoster
            artwork.accentColorHex = match.accentColorHex
            artwork.trailerID = match.trailerID
        }
        guard generation == epoch, !Task.isCancelled else { return previous }
        if request.priority == .high, !artwork.aniZipChecked, let id = artwork.anilistId,
           slot != .wideBanner || artwork.aniListBanner == nil {
            let payload = try? await zip.getOrFetch(key: "\(epoch):\(id)") {
                await self.get(.aniZip, "https://api.ani.zip/mappings", query: [.init(name: "anilist_id", value: "\(id)")])
            }
            if let payload { artwork.aniZipChecked = ArtworkProviders.applyAniZip(payload, to: &artwork) }
        }
        guard generation == epoch, !Task.isCancelled else { return previous }
        let missingPortrait = slot == .portrait2x3 && artwork.aniZipPoster == nil && artwork.aniListPoster == nil
        let missingWide = slot == .wideBanner && artwork.aniListBanner == nil
        let missingLandscape = slot == .landscape16x9 && artwork.landscapeFanartUrl == nil && artwork.trailerID == nil
        if !artwork.kitsuChecked && (missingPortrait || missingWide || (missingLandscape && artwork.aniListBanner == nil)) {
            let payload = try? await kitsu.getOrFetch(key: "\(epoch):\(request.titleKey)") {
                await self.get(.kitsu, "https://kitsu.app/api/edge/anime", query: [
                    .init(name: "filter[text]", value: request.title), .init(name: "page[limit]", value: "5")
                ])
            }
            if let payload { artwork.kitsuChecked = ArtworkProviders.applyKitsu(payload, request: request, to: &artwork) }
        }
        guard generation == epoch, !Task.isCancelled else { return previous }
        if !artwork.jikanChecked && ((missingPortrait && artwork.kitsuPoster == nil) || missingLandscape) {
            let malId = artwork.malId
            let payload = try? await jikan.getOrFetch(key: "\(epoch):\(malId.map(String.init) ?? request.titleKey)") {
                if let malId { return await self.get(.jikan, "https://api.jikan.moe/v4/anime/\(malId)") }
                return await self.get(.jikan, "https://api.jikan.moe/v4/anime", query: [
                    .init(name: "q", value: request.title), .init(name: "limit", value: "5")
                ])
            }
            if let payload { artwork.jikanChecked = ArtworkProviders.applyJikan(payload, request: request, to: &artwork) }
        }
        guard generation == epoch, !Task.isCancelled else { return previous }
        // An all-provider miss is never stored on disk, particularly after a transient HTTP error.
        guard artwork.anilistId != nil || artwork.malId != nil ||
                ArtworkSlot.allURLsContainArtwork(artwork) else { return previous }
        if artwork != previous { await persist(artwork, for: request, epoch: epoch) }
        return artwork
    }

    private func persist(_ value: AnimeArtwork, for request: ArtworkLookupRequest, epoch: UInt64) async {
        let stored = await cached(request)
        guard generation == epoch, !clearing else { return }
        var merged = value
        if let stored {
            if merged.anilistId == nil { merged.anilistId = stored.anilistId }
            if merged.malId == nil { merged.malId = stored.malId }
            if merged.aniListPoster == nil { merged.aniListPoster = stored.aniListPoster }
            if merged.aniListBanner == nil { merged.aniListBanner = stored.aniListBanner }
            if merged.accentColorHex == nil { merged.accentColorHex = stored.accentColorHex }
            if merged.trailerID == nil { merged.trailerID = stored.trailerID }
            if !merged.aniZipChecked, stored.aniZipChecked {
                merged.aniZipChecked = true
                merged.aniZipPoster = stored.aniZipPoster
                merged.aniZipBanner = stored.aniZipBanner
                merged.landscapeFanartUrl = stored.landscapeFanartUrl
                merged.episodeThumbs = stored.episodeThumbs
            }
            if !merged.kitsuChecked, stored.kitsuChecked {
                merged.kitsuChecked = true
                merged.kitsuPoster = stored.kitsuPoster
                merged.kitsuBanner = stored.kitsuBanner
            }
            if !merged.jikanChecked, stored.jikanChecked {
                merged.jikanChecked = true
                merged.jikanPoster = stored.jikanPoster
                merged.jikanTrailer = stored.jikanTrailer
            }
        }
        guard let encoded = try? JSONEncoder().encode(merged), let payload = String(data: encoded, encoding: .utf8) else { return }
        for key in Set([request.titleKey, request.animeKey]) {
            guard generation == epoch, !clearing else { return }
            let record = WebCacheRecord(cacheKey: key, payload: payload, fetchedAt: now)
            cache.set(key, value: record)
            await database.upsertWebCache(record)
            guard generation == epoch, !clearing else { return }
            if let subscribers = observers[key] {
                for continuation in subscribers.values { continuation.yield(merged) }
            }
        }
    }

    private func aniList(_ request: ArtworkLookupRequest) async -> AnimeArtwork? {
        guard !clearing else { return nil }
        let epoch = generation
        return try? await base.getOrFetch(key: "\(epoch):\(request.titleKey):\(ArtworkTitleMatcher.normalize(request.japaneseTitle))") {
            await self.enqueue(request, epoch: epoch)
        }
    }

    private func enqueue(_ request: ArtworkLookupRequest, epoch: UInt64) async -> AnimeArtwork? {
        guard epoch == generation, !clearing, pending.count < 128 else { return nil }
        return await withCheckedContinuation { continuation in
            pending.append((request, continuation))
            if batchTask == nil {
                batchTask = Task {
                    try? await Task.sleep(for: .milliseconds(120))
                    await flushBatches()
                }
            }
        }
    }

    private func flushBatches() async {
        defer { batchTask = nil }
        while !pending.isEmpty {
            let group = Array(pending.prefix(8))
            pending.removeFirst(group.count)
            let lookups = group.map(\.0)
            let payload = try? ArtworkProviders.aniListBody(lookups)
            let response = await get(.aniList, "https://graphql.anilist.co", body: payload)
            let hits = response.map { ArtworkProviders.aniList($0, requests: lookups) }
            for (index, entry) in group.enumerated() { entry.1.resume(returning: hits?[index]) }
        }
    }

    private func get(_ provider: Provider, _ endpoint: String, query: [URLQueryItem] = [], body: Data? = nil) async -> Data? {
        guard !clearing, (pausedUntil[provider] ?? clock.now) <= clock.now,
              var components = URLComponents(string: endpoint) else { return nil }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { return nil }
        if provider == .aniZip {
            if zipInFlight < 3 { zipInFlight += 1 }
            else { await withCheckedContinuation { zipWaiters.append($0) } }
        }
        defer {
            if provider == .aniZip {
                if zipWaiters.isEmpty { zipInFlight -= 1 }
                else { zipWaiters.removeFirst().resume() }
            }
        }
        let start = max(nextRequest[provider] ?? clock.now, clock.now)
        if provider.spacing > .zero { nextRequest[provider] = start + provider.spacing }
        if start > clock.now { try? await clock.sleep(until: start) }
        guard !clearing, !Task.isCancelled, (pausedUntil[provider] ?? clock.now) <= clock.now else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        guard let (data, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 429 || (provider == .aniList && http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0") {
            let retry = http.value(forHTTPHeaderField: "Retry-After")
            pausedUntil[provider] = clock.now + .seconds(Self.retrySeconds(retry))
        }
        if http.statusCode == 404 && provider == .aniZip { return Data(#"{"images":[]}"#.utf8) }
        return (200..<300).contains(http.statusCode) ? data : nil
    }

    static func retrySeconds(_ header: String?, now: Date = Date()) -> Double {
        if let header, let seconds = Double(header), seconds.isFinite { return max(1, seconds) }
        if let header {
            let parser = DateFormatter()
            parser.locale = Locale(identifier: "en_US_POSIX")
            parser.timeZone = TimeZone(secondsFromGMT: 0)
            parser.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
            if let date = parser.date(from: header) { return max(1, date.timeIntervalSince(now)) }
        }
        return 60
    }
}

private extension ArtworkSlot {
    static func allURLsContainArtwork(_ artwork: AnimeArtwork) -> Bool {
        [Self.portrait2x3, .landscape16x9, .wideBanner].contains { !artwork.urls(for: $0).isEmpty }
    }
}
