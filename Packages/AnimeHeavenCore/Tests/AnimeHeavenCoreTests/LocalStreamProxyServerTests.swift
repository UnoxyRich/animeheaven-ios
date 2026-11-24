import Foundation
import Testing
@testable import AnimeHeavenCore

@Suite("LocalStreamProxyServer")
struct LocalStreamProxyServerTests {

    @Test func proxyServesHttp206PartialRangeFromDiskChunkCache() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ah-proxy-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cache = DiskChunkCache(rootDirectory: tempDir, maxCacheBytes: 16 * 1024 * 1024)
        let booster = StreamingChunkBooster(diskCache: cache)
        let proxy = LocalStreamProxyServer(booster: booster)
        defer { Task { await proxy.stop() } }

        let chunkSize = Int(DiskChunkCache.chunkSizeBytes)
        let chunk0 = Data((0..<chunkSize).map { UInt8($0 % 251) })
        let chunk1 = Data((0..<chunkSize).map { UInt8(($0 + 77) % 251) })
        let totalLength = Int64(chunk0.count + chunk1.count)
        let cacheKey = "ep:test123:\(totalLength)"

        await cache.writeChunk(cacheKey: cacheKey, chunkOffset: 0, data: chunk0)
        await cache.writeChunk(cacheKey: cacheKey, chunkOffset: DiskChunkCache.chunkSizeBytes, data: chunk1)

        let session = StreamSessionDescriptor(
            sessionId: "sess1",
            cacheKey: cacheKey,
            episodeKey: "test123",
            mirrors: ["https://unused.local/video.mp4"],
            totalLength: totalLength
        )
        let localURL = try await proxy.registerSession(session)

        // 1. Cross-chunk Range GET (spans end of chunk 0 into start of chunk 1)
        let rangeStart = chunkSize - 16
        let rangeEnd = chunkSize + 31
        var rangeReq = URLRequest(url: localURL)
        rangeReq.setValue("bytes=\(rangeStart)-\(rangeEnd)", forHTTPHeaderField: "Range")

        let (data, response) = try await URLSession.shared.data(for: rangeReq)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 206)
        #expect(http.value(forHTTPHeaderField: "Content-Range") == "bytes \(rangeStart)-\(rangeEnd)/\(totalLength)")
        #expect(data.count == 48)

        var expected = Data()
        expected.append(chunk0.subdata(in: (chunkSize - 16)..<chunkSize))
        expected.append(chunk1.subdata(in: 0..<32))
        #expect(data == expected)

        // 2. HEAD probe returns exact headers and 0 body bytes
        var headReq = URLRequest(url: localURL)
        headReq.httpMethod = "HEAD"
        let (headData, headResp) = try await URLSession.shared.data(for: headReq)
        let headHttp = try #require(headResp as? HTTPURLResponse)
        #expect(headHttp.statusCode == 200)
        #expect(headHttp.value(forHTTPHeaderField: "Accept-Ranges") == "bytes")
        #expect(headHttp.value(forHTTPHeaderField: "Content-Length") == "\(totalLength)")
        #expect(headData.isEmpty)

        // 3. Invalid token returns 403 Forbidden
        let badURL = URL(string: "http://127.0.0.1:\(localURL.port ?? 0)/stream/wrongtoken/sess1.mp4")!
        let (_, badResp) = try await URLSession.shared.data(from: badURL)
        let badHttp = try #require(badResp as? HTTPURLResponse)
        #expect(badHttp.statusCode == 403)
    }

    @Test func byteRangeResolverHandlesOpenEndedSuffixAndInvalidRanges() {
        let open = LocalStreamProxyServer.resolveByteRange(rangeHeader: "bytes=100-", totalLength: 1000)
        #expect(open?.start == 100)
        #expect(open?.end == 999)
        #expect(open?.isPartial == true)

        let suffix = LocalStreamProxyServer.resolveByteRange(rangeHeader: "bytes=-200", totalLength: 1000)
        #expect(suffix?.start == 800)
        #expect(suffix?.end == 999)

        let invalid = LocalStreamProxyServer.resolveByteRange(rangeHeader: "bytes=2000-3000", totalLength: 1000)
        #expect(invalid == nil)
    }
}
