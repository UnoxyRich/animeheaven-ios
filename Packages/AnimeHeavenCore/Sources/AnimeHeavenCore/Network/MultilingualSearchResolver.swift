import Foundation

/// Resolves multi-language queries (Japanese, Chinese, Korean, Russian, Spanish, French, Arabic,
/// Thai, Vietnamese, Romaji pronunciation variants, etc.) into canonical English & Romaji titles
/// searchable on AnimeHeaven. Uses public keyless endpoints without AnimeHeaven cookies/headers.
public actor MultilingualSearchResolver {
    private static let cachePrefix = "mlsearch:"
    private static let maxCandidates = 5
    private static let ttlMs: Int64 = 7 * 86_400_000
    private static let publicUA = "AnimeHeaveniOS/1.0 (MultilingualSearch)"
    private static let aniListFields = "title{romaji english} format popularity"
    private static let aniListSingleQuery =
        "query($s:String!){Page(perPage:6){media(search:$s,type:ANIME,sort:[SEARCH_MATCH,POPULARITY_DESC]){\(aniListFields)}}}"
    private static let wikidataKeywords = [
        "anime", "manga", "animated", "animation", "television series",
        "tv series", "japanese film", "animated film", "light novel", "ova", "ona"
    ]

    private let database: SQLiteDatabase
    private let session: URLSession
    private let cache = LruCache<String, WebCacheRecord>(maxEntries: 256)
    private let coalescer = RequestCoalescer<[String]>()
    private var generation: UInt64 = 0
    private var clearing = false

    public init(database: SQLiteDatabase, session: URLSession? = nil) {
        self.database = database
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.urlCache = nil
            config.httpShouldSetCookies = false
            config.httpCookieAcceptPolicy = .never
            config.timeoutIntervalForRequest = 4
            config.timeoutIntervalForResource = 5
            self.session = URLSession(configuration: config)
        }
    }

    private var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    public func trimMemory() {
        cache.clear()
    }

    public func onCacheCleared() {
        generation &+= 1
        clearing = true
        cache.clear()
        clearing = false
    }

    public func resolveCandidates(for analyzed: AnalyzedQuery) async -> [String] {
        let rawKey = analyzed.original.lowercased()
        guard !rawKey.isEmpty else { return [] }
        let cacheKey = "\(Self.cachePrefix)\(rawKey)"

        if !clearing {
            if let mem = cache.get(cacheKey), nowMs - mem.fetchedAt < Self.ttlMs,
               let decoded = Self.decodeCandidates(mem.payload) {
                return decoded
            }
            if let row = await database.getWebCache(cacheKey: cacheKey),
               nowMs - row.fetchedAt < Self.ttlMs,
               let decoded = Self.decodeCandidates(row.payload) {
                cache.set(cacheKey, value: row)
                return decoded
            }
        }

        let epoch = generation
        let resolved = (try? await coalescer.getOrFetch(key: "\(epoch):\(cacheKey)") {
            await self.fetchAndRank(analyzed: analyzed)
        }) ?? []

        if !resolved.isEmpty, !clearing, epoch == generation, let encoded = Self.encodeCandidates(resolved) {
            let record = WebCacheRecord(cacheKey: cacheKey, payload: encoded, fetchedAt: nowMs)
            cache.set(cacheKey, value: record)
            await database.upsertWebCache(record)
        }
        return resolved
    }

    private func fetchAndRank(analyzed: AnalyzedQuery) async -> [String] {
        let raw = analyzed.original
        var collected: [String] = []

        switch analyzed.script {
        case .hanCJK:
            async let aniListDirect = queryAniListSingle(raw)
            async let bangumiNative = queryBangumi(raw)
            async let wikidataHits = queryWikidata(raw, langHint: analyzed.wikidataLangHint)

            let (al, bgm, wd) = await (aniListDirect, bangumiNative, wikidataHits)
            collected.append(contentsOf: al)
            if !bgm.isEmpty {
                let bgmAniList = await queryAniListBatch(Array(bgm.prefix(2)))
                collected.append(contentsOf: bgmAniList)
                collected.append(contentsOf: bgm.filter(MultilingualQueryNormalizer.isSearchableOnSite))
            }
            collected.append(contentsOf: wd)

        case .kanaOnly:
            let romaji = analyzed.kanaRomajiCandidates.first ?? ""
            async let aniListKana = queryAniListSingle(raw)
            async let aniListRomaji: [String] = romaji.isEmpty ? [] : queryAniListSingle(romaji)
            async let kitsuHits: [String] = romaji.isEmpty ? [] : queryKitsu(romaji)
            async let wikidataHits = queryWikidata(raw, langHint: "ja")

            let (alRom, alKana, kHits, wd) = await (aniListRomaji, aniListKana, kitsuHits, wikidataHits)
            collected.append(contentsOf: alRom)
            collected.append(contentsOf: alKana)
            collected.append(contentsOf: kHits)
            collected.append(contentsOf: wd)

        case .otherNonLatin:
            async let aniListHits = queryAniListSingle(raw)
            async let wikidataHits = queryWikidata(raw, langHint: analyzed.wikidataLangHint)
            let (al, wd) = await (aniListHits, wikidataHits)
            collected.append(contentsOf: al)
            collected.append(contentsOf: wd)

        case .latin:
            let q = analyzed.normalizedLatin
            async let kitsuHits = queryKitsu(q)
            async let aniListHits = queryAniListSingle(q)
            async let wikidataHits = queryWikidata(q, langHint: "en")
            let (kHits, al, wd) = await (kitsuHits, aniListHits, wikidataHits)
            collected.append(contentsOf: kHits)
            collected.append(contentsOf: al)
            collected.append(contentsOf: wd)
        }

        var ranked = MultilingualQueryNormalizer.rankAndDedupe(collected, excludeQuery: analyzed.normalizedLatin)

        if ranked.isEmpty {
            let jikanQuery = analyzed.kanaRomajiCandidates.first ?? analyzed.normalizedLatin
            let jikanHits = await queryJikan(jikanQuery)
            ranked = MultilingualQueryNormalizer.rankAndDedupe(jikanHits, excludeQuery: analyzed.normalizedLatin)
        }

        if !analyzed.romajiVariants.isEmpty {
            ranked = MultilingualQueryNormalizer.rankAndDedupe(
                ranked + analyzed.romajiVariants,
                excludeQuery: analyzed.normalizedLatin
            )
        }

        return Array(ranked.prefix(Self.maxCandidates))
    }

    private func queryAniListSingle(_ query: String) async -> [String] {
        let payload: [String: Any] = [
            "query": Self.aniListSingleQuery,
            "variables": ["s": query]
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload),
              let data = await postJson("https://graphql.anilist.co", body: body) else { return [] }
        return Self.parseAniListSingle(data)
    }

    private func queryAniListBatch(_ queries: [String]) async -> [String] {
        var seen = Set<String>()
        let distinct = queries
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .prefix(3)
        let list = Array(distinct)
        guard !list.isEmpty else { return [] }
        if list.count == 1 { return await queryAniListSingle(list[0]) }

        let args = list.indices.map { "$s\($0):String!" }.joined(separator: ",")
        let aliases = list.indices.map {
            "a\($0):Page(perPage:4){media(search:$s\($0),type:ANIME,sort:[SEARCH_MATCH,POPULARITY_DESC]){\(Self.aniListFields)}}"
        }.joined()
        let variables = Dictionary(uniqueKeysWithValues: list.enumerated().map { ("s\($0.offset)", $0.element) })
        let payload: [String: Any] = ["query": "query(\(args)){\(aliases)}", "variables": variables]
        guard let body = try? JSONSerialization.data(withJSONObject: payload),
              let data = await postJson("https://graphql.anilist.co", body: body) else { return [] }
        return Self.parseAniListBatch(data, count: list.count)
    }

    private func queryBangumi(_ query: String) async -> [String] {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#&+=")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
        guard let url = URL(string: "https://api.bgm.tv/search/subject/\(encoded)?type=2&responseGroup=small&max_results=6"),
              let data = await getJson(url) else { return [] }
        return Self.parseBangumiNativeNames(data)
    }

    private func queryWikidata(_ query: String, langHint: String) async -> [String] {
        var components = URLComponents(string: "https://www.wikidata.org/w/api.php")
        components?.queryItems = [
            URLQueryItem(name: "action", value: "wbsearchentities"),
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "language", value: langHint),
            URLQueryItem(name: "uselang", value: "en"),
            URLQueryItem(name: "type", value: "item"),
            URLQueryItem(name: "limit", value: "6"),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let url = components?.url, let data = await getJson(url) else { return [] }
        return Self.parseWikidataLabels(data)
    }

    private func queryKitsu(_ query: String) async -> [String] {
        var components = URLComponents(string: "https://kitsu.app/api/edge/anime")
        components?.queryItems = [
            URLQueryItem(name: "filter[text]", value: query),
            URLQueryItem(name: "page[limit]", value: "6")
        ]
        guard let url = components?.url, let data = await getJson(url) else { return [] }
        return Self.parseKitsuTitles(data)
    }

    private func queryJikan(_ query: String) async -> [String] {
        var components = URLComponents(string: "https://api.jikan.moe/v4/anime")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: "6")
        ]
        guard let url = components?.url, let data = await getJson(url) else { return [] }
        return Self.parseJikanTitles(data)
    }

    private func getJson(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.publicUA, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { return nil }
        return data
    }

    private func postJson(_ endpoint: String, body: Data) async -> Data? {
        guard let url = URL(string: endpoint) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.publicUA, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { return nil }
        return data
    }

    // MARK: - Pure Parsers (testable without network)

    static func parseAniListSingle(_ data: Data) -> [String] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let dataObj = root["data"] as? [String: Any],
              let page = dataObj["Page"] as? [String: Any],
              let media = page["media"] as? [[String: Any]] else { return [] }
        return extractAniListMediaTitles(media)
    }

    static func parseAniListBatch(_ data: Data, count: Int) -> [String] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let dataObj = root["data"] as? [String: Any] else { return [] }
        var out: [String] = []
        for i in 0..<count {
            if let page = dataObj["a\(i)"] as? [String: Any],
               let media = page["media"] as? [[String: Any]] {
                out.append(contentsOf: extractAniListMediaTitles(media))
            }
        }
        return out
    }

    private static func extractAniListMediaTitles(_ media: [[String: Any]]) -> [String] {
        var out: [String] = []
        for item in media {
            guard let title = item["title"] as? [String: Any] else { continue }
            if let romaji = nonEmpty(title["romaji"]) { out.append(romaji) }
            if let english = nonEmpty(title["english"]) { out.append(english) }
        }
        return out
    }

    static func parseBangumiNativeNames(_ data: Data) -> [String] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = root["list"] as? [[String: Any]] else { return [] }
        return rows.compactMap { nonEmpty($0["name"]) }
    }

    static func parseWikidataLabels(_ data: Data) -> [String] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = root["search"] as? [[String: Any]] else { return [] }
        var preferred: [String] = []
        var secondary: [String] = []
        for row in rows {
            let display = row["display"] as? [String: Any]
            let label = nonEmpty((display?["label"] as? [String: Any])?["value"]) ?? nonEmpty(row["label"])
            guard let label else { continue }
            let desc = (nonEmpty((display?["description"] as? [String: Any])?["value"])
                ?? nonEmpty(row["description"]) ?? "").lowercased()
            if wikidataKeywords.contains(where: { desc.contains($0) }) {
                preferred.append(label)
            } else if !desc.isEmpty && (desc.contains("series") || desc.contains("film") || desc.contains("novel")) {
                secondary.append(label)
            }
        }
        return preferred + secondary
    }

    static func parseKitsuTitles(_ data: Data) -> [String] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = root["data"] as? [[String: Any]] else { return [] }
        var out: [String] = []
        for row in rows {
            guard let attrs = row["attributes"] as? [String: Any] else { continue }
            let titles = attrs["titles"] as? [String: Any]
            if let enJp = nonEmpty(titles?["en_jp"]) { out.append(enJp) }
            if let en = nonEmpty(titles?["en"]) { out.append(en) }
            if let canonical = nonEmpty(attrs["canonicalTitle"]) { out.append(canonical) }
        }
        return out
    }

    static func parseJikanTitles(_ data: Data) -> [String] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = root["data"] as? [[String: Any]] else { return [] }
        var out: [String] = []
        for row in rows {
            if let t = nonEmpty(row["title"]) { out.append(t) }
            if let en = nonEmpty(row["title_english"]) { out.append(en) }
        }
        return out
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let str = value as? String else { return nil }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func encodeCandidates(_ candidates: [String]) -> String? {
        guard let data = try? JSONEncoder().encode(candidates) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decodeCandidates(_ payload: String) -> [String]? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
    }
}
