import Foundation

public enum RankDirection: String, Codable, Sendable, Hashable {
    case up = "UP"
    case down = "DOWN"
    case same = "SAME"
}

public enum FeedViewMode: String, Codable, Sendable, Hashable, CaseIterable {
    case list = "LIST"
    case grid = "GRID"

    public var displayName: String {
        switch self {
        case .list: return "List"
        case .grid: return "Grid"
        }
    }
}

public enum PreloadMode: String, Codable, Sendable, Hashable, CaseIterable {
    case aggressive = "AGGRESSIVE"
    case balanced = "BALANCED"
    case dataSaver = "DATA_SAVER"

    public var displayName: String {
        switch self {
        case .aggressive: return "Aggressive (Wi-Fi)"
        case .balanced: return "Balanced"
        case .dataSaver: return "Data Saver"
        }
    }

    public var subtitle: String {
        switch self {
        case .aggressive:
            return "Preload Home feeds, Bookmarks & up to 8 MB Next Ep video on Wi-Fi (auto-pauses on cellular)"
        case .balanced:
            return "Preload Home banners, Continue Watching & metadata as you browse"
        case .dataSaver:
            return "Metadata & thumbnails only • zero background video preloading"
        }
    }
}

public enum AhThemeId: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case dark = "dark"
    case darkIndigo = "dark2"
    case darkGraphite = "dark3"
    case darkTealPlum = "dark4"
    case darkCrimsonVelvet = "dark5"
    case darkMagenta = "dark6"
    case darkTwilight = "dark7"
    case light = "light"

    public var id: String { rawValue }
    public var cssKey: String { rawValue }

    public var displayName: String {
        switch self {
        case .dark: return "Cinema Dark"
        case .darkIndigo: return "Midnight Indigo"
        case .darkGraphite: return "Graphite Slate"
        case .darkTealPlum: return "Teal Plum"
        case .darkCrimsonVelvet: return "Crimson Velvet"
        case .darkMagenta: return "Magenta Dusk"
        case .darkTwilight: return "Steel Twilight"
        case .light: return "Classic Light"
        }
    }

    public var subtitle: String {
        switch self {
        case .dark: return "Deep charcoal • Netflix Red"
        case .darkIndigo: return "Plum to midnight navy"
        case .darkGraphite: return "Charcoal metallic dark"
        case .darkTealPlum: return "Abyssal teal to plum"
        case .darkCrimsonVelvet: return "Deep maroon to plum"
        case .darkMagenta: return "Vibrant magenta to purple"
        case .darkTwilight: return "Slate blue to indigo"
        case .light: return "White canvas • Crisp cards"
        }
    }

    public static func fromCssKey(_ key: String?) -> AhThemeId {
        guard let key else { return .dark }
        return AhThemeId(rawValue: key) ?? .dark
    }
}

public enum ImageTargetSize: String, Sendable, Hashable, CaseIterable {
    case heroBanner
    case detailPoster
    case continueCard
    case popularCard
    case standardCard
    case searchThumb

    public var widthPx: Int {
        switch self {
        case .heroBanner: return 1080
        case .detailPoster: return 360
        case .continueCard: return 480
        case .popularCard: return 320
        case .standardCard: return 420
        case .searchThumb: return 256
        }
    }

    public var heightPx: Int {
        switch self {
        case .heroBanner: return 460
        case .detailPoster: return 540
        case .continueCard: return 270
        case .popularCard: return 320
        case .standardCard: return 236
        case .searchThumb: return 144
        }
    }

    public var maxPixelDimension: Int {
        max(widthPx, heightPx)
    }
}

public struct BannerItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String { "\(animeId)-\(bannerImageUrl)" }
    public let animeId: String
    public let title: String
    public let bannerImageUrl: String

    public init(animeId: String, title: String, bannerImageUrl: String) {
        self.animeId = animeId
        self.title = title
        self.bannerImageUrl = bannerImageUrl
    }
}

public struct AnimeCard: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let japaneseTitle: String
    public let coverUrl: String
    public let episodeLabel: String
    public let timerOrStatus: String
    public let rankDelta: String?
    public let rankDirection: RankDirection?
    public let isPopularRank: Bool

    public init(
        id: String,
        title: String,
        japaneseTitle: String = "",
        coverUrl: String = "",
        episodeLabel: String = "",
        timerOrStatus: String = "",
        rankDelta: String? = nil,
        rankDirection: RankDirection? = nil,
        isPopularRank: Bool = false
    ) {
        self.id = id
        self.title = title
        self.japaneseTitle = japaneseTitle
        self.coverUrl = coverUrl
        self.episodeLabel = episodeLabel
        self.timerOrStatus = timerOrStatus
        self.rankDelta = rankDelta
        self.rankDirection = rankDirection
        self.isPopularRank = isPopularRank
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case japaneseTitle
        case coverUrl
        case episodeLabel
        case timerOrStatus
        case rankDelta
        case rankDirection
        case isPopularRank
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.title = try container.decode(String.self, forKey: .title)
        self.japaneseTitle = try container.decodeIfPresent(String.self, forKey: .japaneseTitle) ?? ""
        self.coverUrl = try container.decodeIfPresent(String.self, forKey: .coverUrl) ?? ""
        self.episodeLabel = try container.decodeIfPresent(String.self, forKey: .episodeLabel) ?? ""
        self.timerOrStatus = try container.decodeIfPresent(String.self, forKey: .timerOrStatus) ?? ""
        self.rankDelta = try container.decodeIfPresent(String.self, forKey: .rankDelta)
        self.rankDirection = try container.decodeIfPresent(RankDirection.self, forKey: .rankDirection)
        self.isPopularRank = try container.decodeIfPresent(Bool.self, forKey: .isPopularRank) ?? (self.rankDirection != nil)
    }
}

public struct HomeFeed: Codable, Sendable, Hashable {
    public let banners: [BannerItem]
    public let scheduleItems: [AnimeCard]
    public let popularItems: [AnimeCard]
    public let seasonPath: String?
    public let seasonLabel: String?

    public init(
        banners: [BannerItem],
        scheduleItems: [AnimeCard],
        popularItems: [AnimeCard],
        seasonPath: String?,
        seasonLabel: String?
    ) {
        self.banners = banners
        self.scheduleItems = scheduleItems
        self.popularItems = popularItems
        self.seasonPath = seasonPath
        self.seasonLabel = seasonLabel
    }
}

public struct FastSearchItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String { animeId }
    public let animeId: String
    public let title: String
    public let coverUrl: String

    public init(animeId: String, title: String, coverUrl: String) {
        self.animeId = animeId
        self.title = title
        self.coverUrl = coverUrl
    }
}

public struct EpisodeItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String { key }
    public let key: String
    public let numberLabel: String
    public let releaseAge: String

    public init(key: String, numberLabel: String, releaseAge: String) {
        self.key = key
        self.numberLabel = numberLabel
        self.releaseAge = releaseAge
    }
}

public struct AnimeDetail: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let japaneseTitle: String
    public let bannerUrl: String?
    public let posterUrl: String
    public let synopsis: String
    public let tags: [String]
    public let episodesLabel: String
    public let year: String
    public let score: String
    public let countdownLabel: String?
    public let episodes: [EpisodeItem]
    public let relatedShows: [AnimeCard]
    public let similarShows: [AnimeCard]

    public init(
        id: String,
        title: String,
        japaneseTitle: String,
        bannerUrl: String?,
        posterUrl: String,
        synopsis: String,
        tags: [String],
        episodesLabel: String,
        year: String,
        score: String,
        countdownLabel: String?,
        episodes: [EpisodeItem],
        relatedShows: [AnimeCard],
        similarShows: [AnimeCard]
    ) {
        self.id = id
        self.title = title
        self.japaneseTitle = japaneseTitle
        self.bannerUrl = bannerUrl
        self.posterUrl = posterUrl
        self.synopsis = synopsis
        self.tags = tags
        self.episodesLabel = episodesLabel
        self.year = year
        self.score = score
        self.countdownLabel = countdownLabel
        self.episodes = episodes
        self.relatedShows = relatedShows
        self.similarShows = similarShows
    }
}

public struct EpisodeStream: Codable, Sendable, Hashable {
    public let episodeKey: String
    public let animeId: String?
    public let animeTitle: String
    public let episodeLabel: String
    public let videoSources: [String]
    public let prevEpisodeKey: String?
    public let prevEpisodeLabel: String?
    public let nextEpisodeKey: String?
    public let nextEpisodeLabel: String?

    public init(
        episodeKey: String,
        animeId: String?,
        animeTitle: String,
        episodeLabel: String,
        videoSources: [String],
        prevEpisodeKey: String?,
        prevEpisodeLabel: String?,
        nextEpisodeKey: String?,
        nextEpisodeLabel: String?
    ) {
        self.episodeKey = episodeKey
        self.animeId = animeId
        self.animeTitle = animeTitle
        self.episodeLabel = episodeLabel
        self.videoSources = videoSources
        self.prevEpisodeKey = prevEpisodeKey
        self.prevEpisodeLabel = prevEpisodeLabel
        self.nextEpisodeKey = nextEpisodeKey
        self.nextEpisodeLabel = nextEpisodeLabel
    }
}

public struct ContinueWatchingItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String { "\(animeId)-\(targetEpisodeKey)" }
    public let animeId: String
    public let animeTitle: String
    public let coverUrl: String
    public let targetEpisodeKey: String
    public let targetEpisodeLabel: String
    public let isNextEpisode: Bool
    public let resumePositionMs: Int64
    public let durationMs: Int64
    public let lastWatchedLabel: String

    public init(
        animeId: String,
        animeTitle: String,
        coverUrl: String,
        targetEpisodeKey: String,
        targetEpisodeLabel: String,
        isNextEpisode: Bool,
        resumePositionMs: Int64,
        durationMs: Int64,
        lastWatchedLabel: String
    ) {
        self.animeId = animeId
        self.animeTitle = animeTitle
        self.coverUrl = coverUrl
        self.targetEpisodeKey = targetEpisodeKey
        self.targetEpisodeLabel = targetEpisodeLabel
        self.isNextEpisode = isNextEpisode
        self.resumePositionMs = resumePositionMs
        self.durationMs = durationMs
        self.lastWatchedLabel = lastWatchedLabel
    }

    public var progressFraction: Double {
        guard !isNextEpisode, durationMs > 0 else { return 0 }
        return min(1.0, max(0.0, Double(resumePositionMs) / Double(durationMs)))
    }
}

public struct BookmarkRecord: Codable, Sendable, Hashable, Identifiable {
    public var id: String { animeId }
    public let animeId: String
    public let title: String
    public let coverUrl: String
    public let lastEpisodeLabel: String
    public let addedAt: Int64

    public init(
        animeId: String,
        title: String,
        coverUrl: String,
        lastEpisodeLabel: String,
        addedAt: Int64
    ) {
        self.animeId = animeId
        self.title = title
        self.coverUrl = coverUrl
        self.lastEpisodeLabel = lastEpisodeLabel
        self.addedAt = addedAt
    }
}

public struct WatchProgressRecord: Codable, Sendable, Hashable, Identifiable {
    public var id: String { episodeKey }
    public let episodeKey: String
    public let animeId: String
    public let animeTitle: String
    public let coverUrl: String
    public let episodeLabel: String
    public let positionMs: Int64
    public let durationMs: Int64
    public let isWatched: Bool
    public let nextEpisodeKey: String?
    public let nextEpisodeLabel: String?
    public let updatedAt: Int64

    public init(
        episodeKey: String,
        animeId: String,
        animeTitle: String,
        coverUrl: String,
        episodeLabel: String,
        positionMs: Int64,
        durationMs: Int64,
        isWatched: Bool,
        nextEpisodeKey: String? = nil,
        nextEpisodeLabel: String? = nil,
        updatedAt: Int64
    ) {
        self.episodeKey = episodeKey
        self.animeId = animeId
        self.animeTitle = animeTitle
        self.coverUrl = coverUrl
        self.episodeLabel = episodeLabel
        self.positionMs = positionMs
        self.durationMs = durationMs
        self.isWatched = isWatched
        self.nextEpisodeKey = nextEpisodeKey
        self.nextEpisodeLabel = nextEpisodeLabel
        self.updatedAt = updatedAt
    }
}

public struct WebCacheRecord: Codable, Sendable, Hashable {
    public let cacheKey: String
    public let payload: String
    public let fetchedAt: Int64
    public let parsedJson: String?

    public init(cacheKey: String, payload: String, fetchedAt: Int64, parsedJson: String? = nil) {
        self.cacheKey = cacheKey
        self.payload = payload
        self.fetchedAt = fetchedAt
        self.parsedJson = parsedJson
    }
}

public struct ChartFeedResult: Codable, Sendable, Hashable {
    public let title: String
    public let items: [AnimeCard]

    public init(title: String, items: [AnimeCard]) {
        self.title = title
        self.items = items
    }
}

public enum DurationFormatter {
    /// Zero-DateFormatter allocation-minimal duration formatting (`MM:SS` or `H:MM:SS`).
    public static func format(ms: Int64) -> String {
        let clamped = max(0, ms) / 1000
        let hours = clamped / 3600
        let minutes = (clamped % 3600) / 60
        let seconds = clamped % 60
        if hours > 0 {
            return "\(hours):\(twoDigits(minutes)):\(twoDigits(seconds))"
        }
        return "\(twoDigits(minutes)):\(twoDigits(seconds))"
    }

    private static func twoDigits(_ value: Int64) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}
