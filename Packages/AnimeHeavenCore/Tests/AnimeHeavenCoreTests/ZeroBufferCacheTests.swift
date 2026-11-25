import Foundation
import Testing
@testable import AnimeHeavenCore

@Suite("ZeroBufferCache")
struct ZeroBufferCacheTests {

    @Test func mp4MoovSeekParserLocatesAndParsesFaststartVbrKeyframes() throws {
        let sampleCount = 1440
        let sampleSizes = (0..<sampleCount).map { $0 < 720 ? 20_000 : 140_000 }
        let syncSamples = Array(stride(from: 1, through: sampleCount, by: 5))

        let ftyp = buildBox("ftyp", Data("isom\0\0\u{2}\0isommp41".utf8))
        let placeholderMoov = buildSyntheticMoov(
            timescale: 1000,
            durationUnits: 1_440_000,
            sampleSizes: sampleSizes,
            syncSamples: syncSamples,
            firstChunkOffset: Int64(ftyp.count) + 30_000
        )
        let exactMdatStart = Int64(ftyp.count + placeholderMoov.count + 8)
        let moov = buildSyntheticMoov(
            timescale: 1000,
            durationUnits: 1_440_000,
            sampleSizes: sampleSizes,
            syncSamples: syncSamples,
            firstChunkOffset: exactMdatStart
        )
        let mdatPayloadSize = sampleSizes.reduce(Int64(0)) { $0 + Int64($1) }
        let mdatHeader = buildBoxHeader("mdat", totalSize: 8 + mdatPayloadSize)
        let totalLength = Int64(ftyp.count + moov.count) + 8 + mdatPayloadSize
        var headData = Data()
        headData.append(ftyp)
        headData.append(moov)
        headData.append(mdatHeader)

        let loc = Mp4MoovSeekParser.inspectTopLevelBoxes(headData: headData, totalLength: totalLength)
        #expect(loc != nil)
        #expect(loc?.offset == Int64(ftyp.count))
        #expect(loc?.size == Int64(moov.count))
        #expect(loc?.isAtTail == false)

        let parsed = Mp4MoovSeekParser.parseMoovIndex(
            episodeKey: "ep_vbr_ios",
            contentLength: totalLength,
            moovFileOffset: loc!.offset,
            data: headData,
            dataBaseFileOffset: 0,
            sampleIntervalMs: 5_000,
            nowMs: 123_456
        )
        #expect(parsed != nil)
        #expect(parsed?.durationMs == 1_440_000)
        #expect(parsed?.isMoovAtTail == false)
        #expect((parsed?.seekPoints.count ?? 0) >= 200)

        let expectedAt10Min = exactMdatStart + 600 * 20_000
        #expect(parsed?.resolveByteOffset(targetMs: 600_000) == expectedAt10Min)
        #expect(parsed?.resolveByteOffset(targetMs: 85_000) == exactMdatStart + 85 * 20_000)

        // Codable round-trip
        let encoded = try JSONEncoder().encode(parsed!)
        let decoded = try JSONDecoder().decode(EpisodeVideoIndex.self, from: encoded)
        #expect(decoded == parsed)
    }

    @Test func mp4MoovSeekParserDetectsAndParsesTailMoov() {
        let sampleSizes = Array(repeating: 100_000, count: 600)
        let syncSamples = Array(stride(from: 1, through: 600, by: 5))
        let ftyp = buildBox("ftyp", Data("isom\0\0\u{2}\0isommp41".utf8))
        let mdatPayloadSize = sampleSizes.reduce(Int64(0)) { $0 + Int64($1) }
        let mdatStart = Int64(ftyp.count + 8)
        let moov = buildSyntheticMoov(
            timescale: 1000,
            durationUnits: 600_000,
            sampleSizes: sampleSizes,
            syncSamples: syncSamples,
            firstChunkOffset: mdatStart
        )
        let mdatHeader = buildBoxHeader("mdat", totalSize: 8 + mdatPayloadSize)
        let moovOffset = Int64(ftyp.count) + 8 + mdatPayloadSize
        let totalLength = moovOffset + Int64(moov.count)

        var headChunk = Data()
        headChunk.append(ftyp)
        headChunk.append(mdatHeader)
        headChunk.append(Data(repeating: 0, count: 1024))

        let loc = Mp4MoovSeekParser.inspectTopLevelBoxes(headData: headChunk, totalLength: totalLength)
        #expect(loc != nil)
        #expect(loc?.offset == moovOffset)
        #expect(loc?.size == Int64(moov.count))
        #expect(loc?.isAtTail == true)

        let parsed = Mp4MoovSeekParser.parseMoovIndex(
            episodeKey: "ep_tail_ios",
            contentLength: totalLength,
            moovFileOffset: loc!.offset,
            data: moov,
            dataBaseFileOffset: loc!.offset
        )
        #expect(parsed != nil)
        #expect(parsed?.isMoovAtTail == true)
        #expect(parsed?.durationMs == 600_000)
        #expect(parsed?.resolveByteOffset(targetMs: 300_000) == mdatStart + 300 * 100_000)
    }

    @Test func buildInitialWindowChunksTargetsExactVbrKeyframe() {
        let totalLen: Int64 = 120 * 1024 * 1024
        let exactResume: Int64 = 20 * 1024 * 1024
        let exactOp: Int64 = 6 * 1024 * 1024
        let index = EpisodeVideoIndex(
            episodeKey: "ep_vbr",
            contentLength: totalLen,
            durationMs: 1_200_000,
            seekPoints: [
                Mp4SeekPoint(timeMs: 0, byteOffset: 64),
                Mp4SeekPoint(timeMs: 85_000, byteOffset: exactOp),
                Mp4SeekPoint(timeMs: 600_000, byteOffset: exactResume)
            ]
        )
        let chunks = DiskChunkCache.buildInitialWindowChunks(
            totalLength: totalLen,
            targetBytes: 2 * 1024 * 1024,
            resumePositionMs: 600_000,
            estimatedDurationMs: 1_200_000,
            opEndMs: 85_000,
            videoIndex: index
        )
        #expect(chunks.first == 0)
        #expect(chunks.contains(DiskChunkCache.alignChunkStart(exactResume)))
        #expect(chunks.contains(DiskChunkCache.alignChunkStart(exactOp)))
        #expect(!chunks.contains(DiskChunkCache.alignChunkStart(60 * 1024 * 1024)))
    }

    @Test func diskChunkCacheTieredEvictionReadRangeAndLengthPersistence() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ah_zero_buf_test_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let chunkSize = Int(DiskChunkCache.chunkSizeBytes) // 512 KB
        // Max cache = 5 chunks (2.5 MB), protected ratio = 40% (~2 chunks = 1 MB)
        let cache = DiskChunkCache(rootDirectory: dir, maxCacheBytes: Int64(chunkSize) * 5)
        await cache.warmUp()

        // Mark 2 hot chunks (1 MB) in Tier A and write them first
        let hotKey = "ep:hot:100000000"
        await cache.markHotWindow(cacheKey: hotKey, offsets: [0, Int64(chunkSize)])
        let c0 = Data(repeating: 0xAA, count: chunkSize)
        let c1 = Data(repeating: 0xBB, count: chunkSize)
        await cache.writeChunk(cacheKey: hotKey, chunkOffset: 0, data: c0)
        await cache.writeChunk(cacheKey: hotKey, chunkOffset: Int64(chunkSize), data: c1)

        // Verify cross-chunk readRange
        let span = await cache.readRange(cacheKey: hotKey, startOffset: Int64(chunkSize - 4), length: 8)
        #expect(span == Data([0xAA, 0xAA, 0xAA, 0xAA, 0xBB, 0xBB, 0xBB, 0xBB]))
        let cachedWin = await cache.cachedBytesInWindow(
            cacheKey: hotKey,
            startOffset: 0,
            windowBytes: Int64(chunkSize * 2),
            totalLength: 100_000_000
        )
        #expect(cachedWin == Int64(chunkSize * 2))

        // Write 5 unpinned Tier-B watched chunks to force eviction (total attempted = 7 chunks > 5 cap)
        let watchedKey = "ep:watched:100000000"
        for i in 0..<5 {
            await cache.writeChunk(
                cacheKey: watchedKey,
                chunkOffset: Int64(i) * Int64(chunkSize),
                data: Data(repeating: UInt8(i), count: chunkSize)
            )
        }

        // Both Tier-A hot chunks must survive while older Tier-B watched chunks were evicted!
        #expect(await cache.hasChunk(cacheKey: hotKey, chunkOffset: 0))
        #expect(await cache.hasChunk(cacheKey: hotKey, chunkOffset: Int64(chunkSize)))
        #expect(await cache.protectedSizeBytes() == Int64(chunkSize * 2))

        // Demote trailing chunk 0 of hotKey -> Tier B
        await cache.demoteTrailingChunks(cacheKey: hotKey, behindOffset: Int64(chunkSize))
        #expect(await cache.protectedSizeBytes() == Int64(chunkSize))

        // Verify episode length persistence survives fresh DiskChunkCache restart
        await cache.recordEpisodeLength(episodeKey: "ep_persisted", contentLength: 142_000_000)
        let reloaded = DiskChunkCache(rootDirectory: dir, maxCacheBytes: Int64(chunkSize) * 5)
        #expect(await reloaded.knownContentLength(episodeKey: "ep_persisted") == 142_000_000)

        // Verify 2 GB tiered storage scaling
        let gb: Int64 = 1024 * 1024 * 1024
        #expect(DiskChunkCache.calculateVideoCacheMaxBytes(usableSpaceBytes: 2 * gb) == 512 * 1024 * 1024)
        #expect(DiskChunkCache.calculateVideoCacheMaxBytes(usableSpaceBytes: 6 * gb) == 1 * gb)
        #expect(DiskChunkCache.calculateVideoCacheMaxBytes(usableSpaceBytes: 16 * gb) == 2 * gb)
        #expect(DiskChunkCache.calculateVideoCacheMaxBytes(usableSpaceBytes: 1 * gb) == 256 * 1024 * 1024)
    }

    @Test func networkPolicyEnforcesStrictWifiOnlyOnMeteredNetworks() {
        #expect(NetworkPolicy.resolveEffectiveMode(configured: .aggressive, metered: true) == .dataSaver)
        #expect(NetworkPolicy.resolveEffectiveMode(configured: .balanced, metered: true) == .dataSaver)
        #expect(NetworkPolicy.resolveEffectiveMode(configured: .dataSaver, metered: true) == .dataSaver)
        #expect(NetworkPolicy.resolveEffectiveMode(configured: .aggressive, metered: false) == .aggressive)
        #expect(NetworkPolicy.resolveEffectiveMode(configured: .balanced, metered: false) == .balanced)
    }

    // MARK: - Synthetic ISO-BMFF Builders

    private func buildSyntheticMoov(
        timescale: UInt32,
        durationUnits: UInt32,
        sampleSizes: [Int],
        syncSamples: [Int],
        firstChunkOffset: Int64
    ) -> Data {
        let mvhd = buildMvhd(timescale: timescale, durationUnits: durationUnits)
        let audioTrak = buildTrak(handler: "soun", timescale: timescale, durationUnits: durationUnits, stbl: buildBox("stbl", Data()))

        var sttsPayload = Data()
        appendUInt32(&sttsPayload, 1)
        appendUInt32(&sttsPayload, UInt32(sampleSizes.count))
        appendUInt32(&sttsPayload, 1000)
        let stts = buildFullBox("stts", sttsPayload)

        var stssPayload = Data()
        appendUInt32(&stssPayload, UInt32(syncSamples.count))
        for s in syncSamples { appendUInt32(&stssPayload, UInt32(s)) }
        let stss = buildFullBox("stss", stssPayload)

        var stscPayload = Data()
        appendUInt32(&stscPayload, 1)
        appendUInt32(&stscPayload, 1)
        appendUInt32(&stscPayload, 1)
        appendUInt32(&stscPayload, 1)
        let stsc = buildFullBox("stsc", stscPayload)

        var stszPayload = Data()
        appendUInt32(&stszPayload, 0)
        appendUInt32(&stszPayload, UInt32(sampleSizes.count))
        for sz in sampleSizes { appendUInt32(&stszPayload, UInt32(sz)) }
        let stsz = buildFullBox("stsz", stszPayload)

        var stcoPayload = Data()
        appendUInt32(&stcoPayload, UInt32(sampleSizes.count))
        var offset = firstChunkOffset
        for sz in sampleSizes {
            appendUInt32(&stcoPayload, UInt32(offset))
            offset += Int64(sz)
        }
        let stco = buildFullBox("stco", stcoPayload)

        var stblBody = Data()
        stblBody.append(stts)
        stblBody.append(stss)
        stblBody.append(stsc)
        stblBody.append(stsz)
        stblBody.append(stco)
        let stbl = buildBox("stbl", stblBody)
        let videoTrak = buildTrak(handler: "vide", timescale: timescale, durationUnits: durationUnits, stbl: stbl)

        var moovBody = Data()
        moovBody.append(mvhd)
        moovBody.append(audioTrak)
        moovBody.append(videoTrak)
        return buildBox("moov", moovBody)
    }

    private func buildTrak(handler: String, timescale: UInt32, durationUnits: UInt32, stbl: Data) -> Data {
        var mdhdPayload = Data()
        appendUInt32(&mdhdPayload, 0)
        appendUInt32(&mdhdPayload, 0)
        appendUInt32(&mdhdPayload, timescale)
        appendUInt32(&mdhdPayload, durationUnits)
        appendUInt32(&mdhdPayload, 0)
        let mdhd = buildFullBox("mdhd", mdhdPayload)

        var hdlrPayload = Data()
        appendUInt32(&hdlrPayload, 0)
        hdlrPayload.append(Data(handler.utf8))
        hdlrPayload.append(Data(repeating: 0, count: 12))
        let hdlr = buildFullBox("hdlr", hdlrPayload)

        let minf = buildBox("minf", stbl)
        var mdiaBody = Data()
        mdiaBody.append(mdhd)
        mdiaBody.append(hdlr)
        mdiaBody.append(minf)
        return buildBox("trak", buildBox("mdia", mdiaBody))
    }

    private func buildMvhd(timescale: UInt32, durationUnits: UInt32) -> Data {
        var payload = Data()
        appendUInt32(&payload, 0)
        appendUInt32(&payload, 0)
        appendUInt32(&payload, timescale)
        appendUInt32(&payload, durationUnits)
        payload.append(Data(repeating: 0, count: 80))
        return buildFullBox("mvhd", payload)
    }

    private func buildFullBox(_ type: String, _ payload: Data) -> Data {
        var body = Data()
        appendUInt32(&body, 0)
        body.append(payload)
        return buildBox(type, body)
    }

    private func buildBox(_ type: String, _ payload: Data) -> Data {
        var out = buildBoxHeader(type, totalSize: Int64(8 + payload.count))
        out.append(payload)
        return out
    }

    private func buildBoxHeader(_ type: String, totalSize: Int64) -> Data {
        var out = Data()
        if totalSize <= Int64(UInt32.max) {
            appendUInt32(&out, UInt32(totalSize))
            out.append(Data(type.utf8))
        } else {
            appendUInt32(&out, 1)
            out.append(Data(type.utf8))
            appendInt64(&out, totalSize)
        }
        return out
    }

    private func appendUInt32(_ data: inout Data, _ value: UInt32) {
        var be = value.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }

    private func appendInt64(_ data: inout Data, _ value: Int64) {
        var be = value.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }
}
