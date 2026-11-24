import Foundation

public enum SkipSegmentType: String, Codable, Sendable, Hashable {
    case op = "OP"
    case ed = "ED"
}

public struct SkipSegment: Codable, Sendable, Hashable {
    public let type: SkipSegmentType
    public let startMs: Int64
    public let endMs: Int64
    public let isExact: Bool

    public init(type: SkipSegmentType, startMs: Int64, endMs: Int64, isExact: Bool) {
        self.type = type
        self.startMs = startMs
        self.endMs = endMs
        self.isExact = isExact
    }
}

public struct EpisodeSkipTimes: Codable, Sendable, Hashable {
    public let op: SkipSegment?
    public let ed: SkipSegment?

    public init(op: SkipSegment? = nil, ed: SkipSegment? = nil) {
        self.op = op
        self.ed = ed
    }
}

public enum SkipTimesParser {
    private static let epIntRegex = try! NSRegularExpression(pattern: #"(\d+)"#)
    private static let idMalRegex = try! NSRegularExpression(pattern: #""idMal"\s*:\s*(\d+)"#)

    private struct AniSkipEnvelope: Decodable {
        let found: Bool?
        let results: [AniSkipItem]?
    }

    private struct AniSkipItem: Decodable {
        let interval: AniSkipInterval?
        let skipType: String?
    }

    private struct AniSkipInterval: Decodable {
        let startTime: Double?
        let endTime: Double?
    }

    public static func parseEpisodeNumber(_ episodeLabel: String) -> Int? {
        let range = NSRange(episodeLabel.startIndex..<episodeLabel.endIndex, in: episodeLabel)
        guard let match = epIntRegex.firstMatch(in: episodeLabel, range: range),
              match.numberOfRanges > 1,
              let r = Range(match.range(at: 1), in: episodeLabel) else {
            return nil
        }
        return Int(episodeLabel[r])
    }

    public static func parseMalIdFromAniList(_ json: String) -> Int? {
        let range = NSRange(json.startIndex..<json.endIndex, in: json)
        guard let match = idMalRegex.firstMatch(in: json, range: range),
              match.numberOfRanges > 1,
              let r = Range(match.range(at: 1), in: json) else {
            return nil
        }
        return Int(json[r])
    }

    public static func parseAniSkipResponse(_ json: String) -> EpisodeSkipTimes {
        guard let data = json.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(AniSkipEnvelope.self, from: data),
              envelope.found == true,
              let results = envelope.results else {
            return EpisodeSkipTimes()
        }

        var exactOp: SkipSegment?
        var mixedOp: SkipSegment?
        var exactEd: SkipSegment?
        var mixedEd: SkipSegment?

        for item in results {
            guard let startSec = item.interval?.startTime,
                  let endSec = item.interval?.endTime,
                  let skipType = item.skipType?.lowercased(),
                  endSec > startSec + 3.0 else {
                continue
            }
            guard let startMs = Int64(exactly: (startSec * 1000.0).rounded()),
                  let endMs = Int64(exactly: (endSec * 1000.0).rounded()) else { continue }

            switch skipType {
            case "op":
                if exactOp == nil {
                    exactOp = SkipSegment(type: .op, startMs: startMs, endMs: endMs, isExact: true)
                }
            case "mixed-op":
                if mixedOp == nil {
                    mixedOp = SkipSegment(type: .op, startMs: startMs, endMs: endMs, isExact: true)
                }
            case "ed":
                if exactEd == nil {
                    exactEd = SkipSegment(type: .ed, startMs: startMs, endMs: endMs, isExact: true)
                }
            case "mixed-ed":
                if mixedEd == nil {
                    mixedEd = SkipSegment(type: .ed, startMs: startMs, endMs: endMs, isExact: true)
                }
            default:
                break
            }
        }

        return EpisodeSkipTimes(op: exactOp ?? mixedOp, ed: exactEd ?? mixedEd)
    }
}

public actor SkipTimesClient {
    private static let anilistTTLMs: Int64 = 30 * 24 * 60 * 60 * 1000
    private static let aniskipTTLMs: Int64 = 7 * 24 * 60 * 60 * 1000

    private let session: URLSession
    private let database: SQLiteDatabase?
    private let artworkResolver: AnimeArtworkResolver?
    private let malIdCache = LruCache<String, Int>(maxEntries: 256)
    private let skipCache = LruCache<String, EpisodeSkipTimes>(maxEntries: 128)
    private var inFlightMalLookups: [String: Task<Int?, Never>] = [:]

    public init(session: URLSession? = nil, database: SQLiteDatabase? = nil, artworkResolver: AnimeArtworkResolver? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 4.5
            config.timeoutIntervalForResource = 6.0
            self.session = URLSession(configuration: config)
        }
        self.database = database
        self.artworkResolver = artworkResolver
    }

    public func fetchSkipTimes(animeTitle: String, episodeNumber: Int) async -> EpisodeSkipTimes {
        let trimmed = animeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, episodeNumber > 0 else { return EpisodeSkipTimes() }

        let normalized = normalizeTitle(trimmed)
        let cacheKey = "\(normalized)#\(episodeNumber)"
        if let cached = skipCache.get(cacheKey) {
            return cached
        }

        let dbKey = "aniskip:\(cacheKey)"
        let now = currentTimeMs()
        if let db = database,
           let record = await db.getWebCache(cacheKey: dbKey),
           now - record.fetchedAt < Self.aniskipTTLMs {
            let parsed = SkipTimesParser.parseAniSkipResponse(record.payload)
            skipCache.set(cacheKey, value: parsed)
            return parsed
        }

        guard let malId = await resolveMalId(rawTitle: trimmed, normalized: normalized) else {
            return EpisodeSkipTimes()
        }

        guard let url = URL(
            string: "https://api.aniskip.com/v2/skip-times/\(malId)/\(episodeNumber)?types=op&types=ed&episodeLength=0"
        ) else {
            return EpisodeSkipTimes()
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await session.data(for: request),
              !Task.isCancelled, let http = response as? HTTPURLResponse else { return EpisodeSkipTimes() }
        let payload: String
        if http.statusCode == 404 {
            payload = #"{"found":false,"results":[]}"#
        } else if http.statusCode == 200,
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  json["found"] is Bool, let body = String(data: data, encoding: .utf8) {
            payload = body
        } else {
            return EpisodeSkipTimes()
        }
        let parsed = SkipTimesParser.parseAniSkipResponse(payload)
        skipCache.set(cacheKey, value: parsed)
        if let db = database {
            await db.upsertWebCache(WebCacheRecord(cacheKey: dbKey, payload: payload, fetchedAt: now))
        }
        return parsed
    }

    public func trimMemory() {
        malIdCache.clear()
        skipCache.clear()
    }

    private func resolveMalId(rawTitle: String, normalized: String) async -> Int? {
        if let artworkResolver { return await artworkResolver.resolveMalId(title: rawTitle) }
        if let mem = malIdCache.get(normalized) {
            return mem > 0 ? mem : nil
        }
        if let existing = inFlightMalLookups[normalized] {
            let result = await existing.value
            return result.flatMap { $0 > 0 ? $0 : nil }
        }

        let task = Task<Int?, Never> {
            let dbKey = "anilist:\(normalized)"
            let now = currentTimeMs()
            if let db = database,
               let record = await db.getWebCache(cacheKey: dbKey),
               now - record.fetchedAt < Self.anilistTTLMs {
                if let id = Int(record.payload), id == -1 || id > 0 { return id }
            }

            guard let url = URL(string: "https://graphql.anilist.co") else { return nil }
            let bodyObj: [String: Any] = [
                "query": "query($s:String){Media(search:$s,type:ANIME){id idMal}}",
                "variables": ["s": rawTitle]
            ]
            guard let bodyData = try? JSONSerialization.data(withJSONObject: bodyObj) else {
                return nil
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = bodyData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            guard let (data, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse,
                  let storedVal = Self.cacheableMalId(status: http.statusCode, data: data) else { return nil }
            if let db = database {
                await db.upsertWebCache(
                    WebCacheRecord(cacheKey: dbKey, payload: "\(storedVal)", fetchedAt: now)
                )
            }
            return storedVal
        }

        inFlightMalLookups[normalized] = task
        let result = await task.value
        inFlightMalLookups.removeValue(forKey: normalized)
        if let result {
            malIdCache.set(normalized, value: result)
            return result > 0 ? result : nil
        }
        return nil
    }

    static func cacheableMalId(status: Int, data: Data) -> Int? {
        if status == 404 { return -1 }
        guard status == 200,
              let envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              envelope["errors"] == nil,
              let values = envelope["data"] as? [String: Any],
              let media = values["Media"] as? [String: Any] else { return nil }
        if let id = media["idMal"] as? Int, id > 0 { return id }
        return media["idMal"] is NSNull ? -1 : nil
    }

    private func normalizeTitle(_ raw: String) -> String {
        raw.lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func currentTimeMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
