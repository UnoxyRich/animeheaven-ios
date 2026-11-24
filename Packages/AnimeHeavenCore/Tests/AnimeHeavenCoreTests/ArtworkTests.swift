import Foundation
import Testing
import os
@testable import AnimeHeavenCore

@Suite("Artwork")
struct ArtworkTests {
    @Test func aliasedAniListBatchMatchesSeasonsAndPartialResults() throws {
        let requests = [
            ArtworkLookupRequest(animeId: "frieren", title: "Frieren: Beyond Journey's End", japaneseTitle: "Sousou no Frieren"),
            ArtworkLookupRequest(animeId: "black-clover", title: "Black Clover 2nd Season", year: 2026),
            ArtworkLookupRequest(animeId: "other", title: "Escaped \"title\"\n試験")
        ]
        let body = try #require(ArtworkProviders.object(ArtworkProviders.aniListBody(requests)))
        #expect((body["variables"] as? [String: String])?["s2"] == requests[2].title)
        #expect((body["query"] as? String)?.contains("a2:Page(perPage:5)") == true)
        let matches = ArtworkProviders.aniList(Data("""
        {"data":{"a0":{"media":[
          {"id":189513,"title":{"english":"Frieren: Beyond Journey’s End Mini Anime Part 2"},"format":"ONA","popularity":100000},
          {"id":154587,"idMal":52991,"title":{"english":"Frieren: Beyond Journey’s End","romaji":"Sousou no Frieren"},"format":"TV"}]},
          "a1":{"media":[{"id":97940,"title":{"english":"Black Clover"},"format":"TV","popularity":1000000},
          {"id":195604,"title":{"english":"Black Clover Season 2"},"seasonYear":2026,"format":"TV"}]},
          "a2":null},"errors":[{"path":["a2"]}]}
        """.utf8), requests: requests)
        #expect(matches.map { $0?.anilistId } == [154587, 195604, nil])
        #expect(ArtworkTitleMatcher.bestIndex(for: requests[1], candidates: [
            .init(titles: ["Black Lagoon"], year: 2026, format: "TV", popularity: 100_000)
        ]) == nil)
        #expect(ArtworkTitleMatcher.normalize("Pokémon") == "pokemon")
    }

    @Test func providersAndEpisodeSelection() throws {
        let request = ArtworkLookupRequest(animeId: "sample", title: "Example Title")
        var artwork = AnimeArtwork()
        #expect(ArtworkProviders.applyAniZip(Data("""
        {"images":[{"coverType":"Fanart","url":"https://example.test/fanart"},
            {"coverType":"Poster","url":"https://example.test/portrait"},{"coverType":"Banner","url":"https://example.test/banner"}],
          "episodes":{"1":{"image":"https://example.test/episode"},"1.5":{"image":"https://example.test/not-integer"}}}
        """.utf8), to: &artwork))
        #expect(ArtworkProviders.applyKitsu(Data("""
        {"data":[{"attributes":{"canonicalTitle":"Example Title","subtype":"TV","posterImage":{"large":"https://example.test/kitsu-poster"},
          "coverImage":{"large":"https://example.test/kitsu-banner"}}}]}
        """.utf8), request: request, to: &artwork))
        var jikan = AnimeArtwork()
        #expect(ArtworkProviders.applyJikan(Data("""
        {"data":{"mal_id":12,"images":{"webp":{"large_image_url":"https://example.test/mal"}},
            "trailer":{"images":{"maximum_image_url":"https://example.test/trailer"}}}}
        """.utf8), request: request, to: &jikan))
        #expect(artwork.bestUrl(for: .landscape16x9, episodeNumber: 1, fallbackUrl: "native") == "https://example.test/episode")
        #expect(artwork.bestUrl(for: .landscape16x9, episodeNumber: 2, fallbackUrl: "native") == "https://example.test/fanart")
        #expect(artwork.bestUrl(for: .portrait2x3, fallbackUrl: "native") == "https://example.test/portrait")
        #expect(artwork.bestUrl(for: .wideBanner, fallbackUrl: "native") == "https://example.test/kitsu-banner")
        #expect(jikan.bestUrl(for: .portrait2x3, fallbackUrl: "native") == "https://example.test/mal")
        #expect(jikan.bestUrl(for: .landscape16x9, fallbackUrl: "native") == "https://example.test/trailer")
        #expect(jikan.bestUrl(for: .landscape16x9, episodeNumber: 2, fallbackUrl: "native") == "native")
        #expect(try JSONDecoder().decode(AnimeArtwork.self, from: JSONEncoder().encode(artwork)) == artwork)
    }

    @Test func smartFitAndNativeHostIsolation() {
        #expect(!ArtworkSmartFit.needsAmbient(imageRatio: 1.55, frameRatio: 1))
        #expect(!ArtworkSmartFit.needsAmbient(imageRatio: 16.0 / 9, frameRatio: 16.0 / 10))
        #expect(ArtworkSmartFit.needsAmbient(imageRatio: 8, frameRatio: 16.0 / 10))
        #expect(ArtworkSmartFit.needsAmbient(imageRatio: 16.0 / 9, frameRatio: 2.0 / 3))
        #expect(ArtworkSmartFit.needsAmbient(imageRatio: 2.0 / 3, frameRatio: 16.0 / 9))
        #expect(ArtworkImageHeaders.referer(forHost: "cdn.animeheaven.me") == "https://animeheaven.me/")
        for host in ["fakeanimeheaven.me", "animeheaven.me.example.test", "s4.anilist.co", "artworks.thetvdb.com",
                     "media.kitsu.app", "cdn.myanimelist.net", "i.ytimg.com"] {
            #expect(ArtworkImageHeaders.referer(forHost: host) == nil)
        }
        let detail = AnimeHeavenParser.parseAnimeDetail(animeId: "sample", html: """
        <meta property="og:image" content="/image.php?cover">
        <div class="banner"><img class="bannerimg" src="/image.php?wide"></div>
        <div class="infoimg"><img class="posterimg" src="/image.php?portrait"></div>
        """)
        #expect(detail.landscapeCoverUrl == "https://animeheaven.me/image.php?cover")
    }

    @Test func rateLimitPausesAniListWithoutPersistingTransientMiss() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArtworkRateLimitProtocol.self]
        let database = try SQLiteDatabase(path: ":memory:")
        let resolver = AnimeArtworkResolver(database: database, session: URLSession(configuration: configuration))
        #expect(await resolver.resolveMalId(title: "First Test Show") == nil)
        #expect(await resolver.resolveMalId(title: "Second Test Show") == nil)
        #expect(ArtworkRateLimitProtocol.calls.withLock { $0 } == 1)
        #expect(await database.getWebCache(cacheKey: "artwork:title:first test show") == nil)
        #expect(await database.getWebCache(cacheKey: "artwork:title:second test show") == nil)
        #expect(AnimeArtworkResolver.retrySeconds("40") == 40)
    }
}

private final class ArtworkRateLimitProtocol: URLProtocol, @unchecked Sendable {
    static let calls = OSAllocatedUnfairLock(initialState: 0)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.calls.withLock { $0 += 1 }
        let response = HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "40"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
