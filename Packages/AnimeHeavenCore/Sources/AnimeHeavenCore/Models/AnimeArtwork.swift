import Foundation

public enum ArtworkSlot: String, Codable, Sendable, Hashable {
    case portrait2x3, landscape16x9, wideBanner
}

public enum ArtworkPriority: Int, Sendable, Hashable {
    /// Use existing artwork only; native landscape thumbnails don't need speculative requests.
    case cachedOnly, normal, featured, high
}

public struct ArtworkLookupRequest: Sendable, Hashable {
    public let animeId: String
    public let title: String
    public let japaneseTitle: String
    public let year: Int?
    public let priority: ArtworkPriority

    public init(animeId: String, title: String, japaneseTitle: String = "", year: Int? = nil,
                priority: ArtworkPriority = .normal) {
        self.animeId = animeId
        self.title = title
        self.japaneseTitle = japaneseTitle
        self.year = year
        self.priority = priority
    }

    var titleKey: String {
        "artwork:title:\(ArtworkTitleMatcher.normalize(title))\(year.map { ":\($0)" } ?? "")"
    }
    var animeKey: String { animeId.isEmpty ? titleKey : "artwork:ah:\(animeId)" }
}

public struct AnimeArtwork: Codable, Sendable, Hashable {
    public var anilistId: Int?
    public var malId: Int?
    public var aniListPoster: String?
    public var aniListBanner: String?
    public var accentColorHex: String?
    public var trailerID: String?
    public var aniZipPoster: String?
    public var aniZipBanner: String?
    public var landscapeFanartUrl: String?
    public var episodeThumbs: [Int: String] = [:]
    public var kitsuPoster: String?
    public var kitsuBanner: String?
    public var jikanPoster: String?
    public var jikanTrailer: String?
    var aniZipChecked = false
    var kitsuChecked = false
    var jikanChecked = false

    public init() {}

    public func urls(for slot: ArtworkSlot, episodeNumber: Int? = nil, fallbackUrl: String = "",
                     nativeLandscapeFirst: Bool = false) -> [String] {
        let trailer = trailerID.map { "https://i.ytimg.com/vi/\($0)/maxresdefault.jpg" }
        let trailerMedium = trailerID.map { "https://i.ytimg.com/vi/\($0)/mqdefault.jpg" }
        let candidateURLs: [String?]
        switch slot {
        case .portrait2x3:
            candidateURLs = [aniZipPoster, aniListPoster, kitsuPoster, jikanPoster, fallbackUrl]
        case .wideBanner:
            candidateURLs = [aniListBanner, kitsuBanner, landscapeFanartUrl, aniZipBanner, fallbackUrl]
        case .landscape16x9 where episodeNumber != nil || nativeLandscapeFirst:
            candidateURLs = [episodeNumber.flatMap { episodeThumbs[$0] }, landscapeFanartUrl, fallbackUrl]
        case .landscape16x9:
            candidateURLs = [landscapeFanartUrl, trailer, jikanTrailer, trailerMedium, aniListBanner, kitsuBanner, fallbackUrl]
        }
        var seen: Set<String> = []
        return candidateURLs.compactMap { $0 }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    public func bestUrl(for slot: ArtworkSlot, episodeNumber: Int? = nil, fallbackUrl: String) -> String {
        urls(for: slot, episodeNumber: episodeNumber, fallbackUrl: fallbackUrl).first ?? fallbackUrl
    }
}

public enum ArtworkSmartFit {
    public static func needsAmbient(imageRatio: Double, frameRatio: Double) -> Bool {
        guard imageRatio.isFinite, frameRatio.isFinite, imageRatio > 0, frameRatio > 0 else { return false }
        return max(imageRatio, frameRatio) > min(imageRatio, frameRatio) * 1.55
    }
}

public enum ArtworkImageHeaders {
    public static func referer(forHost host: String?) -> String? {
        guard let host = host?.lowercased(),
              host == "animeheaven.me" || host.hasSuffix(".animeheaven.me") else { return nil }
        return "https://animeheaven.me/"
    }
}
