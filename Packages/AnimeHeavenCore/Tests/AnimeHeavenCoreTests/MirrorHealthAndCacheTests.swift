import Foundation
import Testing
@testable import AnimeHeavenCore

@Suite("MirrorHealthAndCache")
struct MirrorHealthAndCacheTests {

    @Test func rankMirrorsPreservesOrderWhenNoStats() {
        let tracker = MirrorHealthTracker(clockMs: { 1_000 })
        let mirrors = ["https://s1.example.com/v1.mp4", "https://s2.example.com/v1.mp4", "https://s3.example.com/v1.mp4"]
        #expect(tracker.rankMirrors(mirrors) == mirrors)
    }

    @Test func rankMirrorsDemotesFailedHostDuringCooldownAndRestoresAfterExpiry() {
        final class Clock: @unchecked Sendable { var now: Int64 = 10_000 }
        let clock = Clock()
        let tracker = MirrorHealthTracker(clockMs: { clock.now })
        let dead = "https://ct.animeheaven.me/video.mp4?t=1"
        let healthy = "https://v1.animeheaven.me/video.mp4?t=1"
        let untried = "https://v2.animeheaven.me/video.mp4?t=1"

        tracker.recordFailure(url: dead)
        tracker.recordSuccess(url: healthy, latencyMs: 120)

        #expect(tracker.rankMirrors([dead, untried, healthy]) == [healthy, untried, dead])

        clock.now += MirrorHealthTracker.failureCooldownMs + 1
        #expect(tracker.rankMirrors([dead, untried, healthy]) == [healthy, dead, untried])
    }

    @Test func rankMirrorsPrefersHigherThroughputAndDemotesStubs() {
        let tracker = MirrorHealthTracker(clockMs: { 5_000 })
        let slow = "https://slow.cdn/video.mp4"
        let fast = "https://fast.cdn/video.mp4"
        let stub = "https://stub.cdn/video.mp4"

        tracker.recordSuccess(url: slow, latencyMs: 80)
        tracker.recordThroughput(url: slow, bytesTransferred: 256 * 1024, durationMs: 2_000)
        tracker.recordSuccess(url: fast, latencyMs: 120)
        tracker.recordThroughput(url: fast, bytesTransferred: 1024 * 1024, durationMs: 500)
        tracker.recordStubVideo(url: stub)

        #expect(tracker.rankMirrors([stub, slow, fast]) == [fast, slow, stub])
    }

    @Test func buildEpisodeCacheKeySharesKeyAcrossMirrors() {
        let len: Int64 = 140 * 1024 * 1024
        let k1 = DiskChunkCache.buildEpisodeCacheKey(episodeKey: "ep99", contentLength: len, fallbackUrl: "https://m1/a.mp4")
        let k2 = DiskChunkCache.buildEpisodeCacheKey(episodeKey: "ep99", contentLength: len, fallbackUrl: "https://m2/b.mp4")
        #expect(k1 == "ep:ep99:\(len)")
        #expect(k1 == k2)

        let stubKey = DiskChunkCache.buildEpisodeCacheKey(episodeKey: "ep99", contentLength: 10_000, fallbackUrl: "https://m1/stub.mp4")
        #expect(stubKey == "https://m1/stub.mp4")
    }

    @Test func parseTotalLengthFromHeaders() {
        #expect(
            DiskChunkCache.parseTotalLengthFromHeaders(contentRange: "bytes 0-0/123456789", contentLength: "1", statusCode: 206) == 123_456_789
        )
        #expect(
            DiskChunkCache.parseTotalLengthFromHeaders(contentRange: nil, contentLength: "98765432", statusCode: 200) == 98_765_432
        )
        #expect(
            DiskChunkCache.parseTotalLengthFromHeaders(contentRange: nil, contentLength: "1", statusCode: 206) == -1
        )
    }

    @Test func containsMoovBoxDetection() {
        let fastStart = Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x6D, 0x6F, 0x6F, 0x76, 0x00, 0x00])
        #expect(DiskChunkCache.containsMoovBox(fastStart))

        let tailMoov = Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x6D, 0x64, 0x61, 0x74, 0x01, 0x02])
        #expect(!DiskChunkCache.containsMoovBox(tailMoov))
    }

    @Test func buildInitialWindowChunksIncludesChunk0ResumeAndOpEnd() {
        let total: Int64 = 100 * 1024 * 1024
        let chunks = DiskChunkCache.buildInitialWindowChunks(
            totalLength: total,
            targetBytes: 2 * 1024 * 1024,
            resumePositionMs: 600_000,
            estimatedDurationMs: 1_200_000,
            opEndMs: 90_000
        )
        #expect(chunks.first == 0)
        #expect(chunks.count >= 5)
        #expect(Set(chunks).count == chunks.count)
    }

    @Test func lruCacheEvictsLeastRecentlyUsed() {
        let cache = LruCache<String, Int>(maxEntries: 2)
        cache.set("a", value: 1)
        cache.set("b", value: 2)
        #expect(cache.get("a") == 1)
        cache.set("c", value: 3)

        #expect(cache.count == 2)
        #expect(cache.get("a") == 1)
        #expect(cache.get("b") == nil)
        #expect(cache.get("c") == 3)
    }

    @Test func cachedEntrySoftTTLBoundary() {
        let entry = CachedEntry(value: "html", fetchedAt: 100_000)
        #expect(!entry.isStale(softTTLMs: 60_000, nowMs: 159_999))
        #expect(entry.isStale(softTTLMs: 60_000, nowMs: 160_000))
    }

    @Test func skipTimesParserExtractsIdsAndSegments() {
        #expect(SkipTimesParser.parseEpisodeNumber("Episode 12") == 12)
        #expect(
            SkipTimesParser.parseMalIdFromAniList(#"{"data":{"Media":{"idMal":21,"episodes":1000}}}"#) == 21
        )

        let json = """
        {
          "found": true,
          "results": [
            {"interval": {"startTime": 85.5, "endTime": 175.0}, "skipType": "op"},
            {"interval": {"startTime": 1310.0, "endTime": 1400.0}, "skipType": "ed"}
          ]
        }
        """
        let parsed = SkipTimesParser.parseAniSkipResponse(json)
        #expect(parsed.op?.startMs == 85_500)
        #expect(parsed.op?.endMs == 175_000)
        #expect(parsed.ed?.startMs == 1_310_000)
        #expect(parsed.ed?.endMs == 1_400_000)
    }

    @Test func durationFormatterFormatsMinutesAndHours() {
        #expect(DurationFormatter.format(ms: 0) == "00:00")
        #expect(DurationFormatter.format(ms: 65_000) == "01:05")
        #expect(DurationFormatter.format(ms: 3_661_000) == "1:01:01")
    }
}
