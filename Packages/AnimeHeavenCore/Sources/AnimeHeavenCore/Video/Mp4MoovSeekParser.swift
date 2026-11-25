import Foundation

public struct Mp4SeekPoint: Codable, Sendable, Equatable {
    public let timeMs: Int64
    public let byteOffset: Int64

    public init(timeMs: Int64, byteOffset: Int64) {
        self.timeMs = timeMs
        self.byteOffset = byteOffset
    }
}

public struct EpisodeVideoIndex: Codable, Sendable, Equatable {
    public let episodeKey: String
    public let contentLength: Int64
    public let durationMs: Int64
    public let moovOffset: Int64
    public let moovSize: Int64
    public let seekPoints: [Mp4SeekPoint]
    public let updatedAtMs: Int64

    public init(
        episodeKey: String,
        contentLength: Int64,
        durationMs: Int64 = 0,
        moovOffset: Int64 = -1,
        moovSize: Int64 = 0,
        seekPoints: [Mp4SeekPoint] = [],
        updatedAtMs: Int64 = 0
    ) {
        self.episodeKey = episodeKey
        self.contentLength = contentLength
        self.durationMs = durationMs
        self.moovOffset = moovOffset
        self.moovSize = moovSize
        self.seekPoints = seekPoints
        self.updatedAtMs = updatedAtMs
    }

    public var isMoovAtTail: Bool {
        moovOffset > 0 && contentLength > 0 && moovOffset >= contentLength / 2
    }

    public func resolveByteOffset(targetMs: Int64) -> Int64? {
        guard !seekPoints.isEmpty else { return nil }
        if targetMs <= 0 { return seekPoints[0].byteOffset }
        var lo = 0
        var hi = seekPoints.count - 1
        var best = 0
        while lo <= hi {
            let mid = (lo + hi) >> 1
            if seekPoints[mid].timeMs <= targetMs {
                best = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return seekPoints[best].byteOffset
    }
}

public struct Mp4MoovLocation: Sendable, Equatable {
    public let offset: Int64
    public let size: Int64
    public let isAtTail: Bool

    public init(offset: Int64, size: Int64, isAtTail: Bool) {
        self.offset = offset
        self.size = size
        self.isAtTail = isAtTail
    }
}

/// Pure-Swift ISO-BMFF (MP4) `moov` locator and keyframe seek-table parser.
/// Walks `mvhd`/`mdhd`/`hdlr`/`stts`/`stss`/`stsc`/`stsz`/`stco`/`co64` so Continue Watching
/// resumes and Skip OP jumps pre-warm the exact keyframe byte offsets instead of CBR estimates.
public enum Mp4MoovSeekParser {
    private static let boxMoov: UInt32 = 0x6D6F6F76 // "moov"
    private static let boxMdat: UInt32 = 0x6D646174 // "mdat"
    private static let boxMvhd: UInt32 = 0x6D766864 // "mvhd"
    private static let boxTrak: UInt32 = 0x7472616B // "trak"
    private static let boxMdia: UInt32 = 0x6D646961 // "mdia"
    private static let boxMdhd: UInt32 = 0x6D646864 // "mdhd"
    private static let boxHdlr: UInt32 = 0x68646C72 // "hdlr"
    private static let boxMinf: UInt32 = 0x6D696E66 // "minf"
    private static let boxStbl: UInt32 = 0x7374626C // "stbl"
    private static let boxStts: UInt32 = 0x73747473 // "stts"
    private static let boxStss: UInt32 = 0x73747373 // "stss"
    private static let boxStsc: UInt32 = 0x73747363 // "stsc"
    private static let boxStsz: UInt32 = 0x7374737A // "stsz"
    private static let boxStco: UInt32 = 0x7374636F // "stco"
    private static let boxCo64: UInt32 = 0x636F3634 // "co64"
    private static let handlerVide: UInt32 = 0x76696465 // "vide"

    public static let maxMoovParseBytes: Int64 = 4 * 1024 * 1024
    public static let defaultSeekIntervalMs: Int64 = 5_000
    public static let maxSeekPoints: Int = 512

    public static func inspectTopLevelBoxes(headData: Data, totalLength: Int64) -> Mp4MoovLocation? {
        let bytes = [UInt8](headData)
        let limit = bytes.count
        guard limit >= 8, totalLength > 0 else { return nil }

        var offset: Int64 = 0
        var visited = 0
        while offset + 8 <= Int64(limit) && visited < 64 {
            let pos = Int(offset)
            let rawSize = Int64(readUInt32(bytes, pos))
            let boxType = readUInt32(bytes, pos + 4)
            var headerLen: Int64 = 8
            let boxSize: Int64
            if rawSize == 0 {
                boxSize = totalLength - offset
            } else if rawSize == 1 {
                guard pos + 16 <= limit else { return nil }
                headerLen = 16
                boxSize = readInt64(bytes, pos + 8)
            } else {
                boxSize = rawSize
            }
            guard boxSize >= headerLen, offset + boxSize <= totalLength + 1024 else { return nil }

            if boxType == boxMoov {
                let clamped = min(boxSize, totalLength - offset)
                return Mp4MoovLocation(offset: offset, size: clamped, isAtTail: offset >= totalLength / 2)
            }
            if boxType == boxMdat {
                let afterMdat = offset + boxSize
                let tailRemaining = totalLength - afterMdat
                if afterMdat > 0 && afterMdat < totalLength && tailRemaining >= 16 && tailRemaining <= maxMoovParseBytes {
                    return Mp4MoovLocation(offset: afterMdat, size: tailRemaining, isAtTail: true)
                }
                return nil
            }
            offset += boxSize
            visited += 1
        }
        return nil
    }

    public static func parseMoovIndex(
        episodeKey: String,
        contentLength: Int64,
        moovFileOffset: Int64,
        data: Data,
        dataBaseFileOffset: Int64? = nil,
        sampleIntervalMs: Int64 = defaultSeekIntervalMs,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) -> EpisodeVideoIndex? {
        let bytes = [UInt8](data)
        let limit = bytes.count
        let baseOffset = dataBaseFileOffset ?? moovFileOffset
        guard limit >= 16, contentLength > 0 else { return nil }
        let relStart64 = moovFileOffset - baseOffset
        guard relStart64 >= 0, relStart64 + 8 <= Int64(limit) else { return nil }
        let relStart = Int(relStart64)
        guard let moovHeader = readBoxHeader(bytes, pos: relStart, limit: limit),
              moovHeader.type == boxMoov,
              moovHeader.end > moovHeader.contentStart else { return nil }

        var movieDurationMs: Int64 = 0
        var bestTrackDurationMs: Int64 = 0
        var bestSeekPoints: [Mp4SeekPoint] = []

        forEachChildBox(bytes, start: moovHeader.contentStart, end: moovHeader.end) { box in
            if box.type == boxMvhd {
                let dur = parseMvhdDurationMs(bytes, start: box.contentStart, end: box.end)
                if dur > 0 { movieDurationMs = dur }
            } else if box.type == boxTrak {
                if let parsed = parseVideoTrack(bytes, start: box.contentStart, end: box.end, sampleIntervalMs: sampleIntervalMs),
                   parsed.1.count > bestSeekPoints.count {
                    bestTrackDurationMs = parsed.0
                    bestSeekPoints = parsed.1
                }
            }
        }

        let resolvedDuration = movieDurationMs > 0 ? movieDurationMs : bestTrackDurationMs
        guard resolvedDuration > 0 || !bestSeekPoints.isEmpty else { return nil }

        return EpisodeVideoIndex(
            episodeKey: episodeKey,
            contentLength: contentLength,
            durationMs: resolvedDuration,
            moovOffset: moovFileOffset,
            moovSize: moovHeader.size,
            seekPoints: bestSeekPoints,
            updatedAtMs: nowMs
        )
    }

    private struct BoxSpan {
        let type: UInt32
        let start: Int
        let contentStart: Int
        let end: Int
        let size: Int64
    }

    private static func parseVideoTrack(
        _ buf: [UInt8],
        start: Int,
        end: Int,
        sampleIntervalMs: Int64
    ) -> (Int64, [Mp4SeekPoint])? {
        var mdiaBox: BoxSpan?
        forEachChildBox(buf, start: start, end: end) { box in
            if box.type == boxMdia { mdiaBox = box }
        }
        guard let mdia = mdiaBox else { return nil }

        var timescale: Int64 = 0
        var durationUnits: Int64 = 0
        var isVideo = false
        var minfBox: BoxSpan?

        forEachChildBox(buf, start: mdia.contentStart, end: mdia.end) { box in
            if box.type == boxMdhd, let parsed = parseMdhd(buf, start: box.contentStart, end: box.end) {
                timescale = parsed.0
                durationUnits = parsed.1
            } else if box.type == boxHdlr, box.contentStart + 12 <= box.end {
                isVideo = readUInt32(buf, box.contentStart + 8) == handlerVide
            } else if box.type == boxMinf {
                minfBox = box
            }
        }
        guard isVideo, timescale > 0, let minf = minfBox else { return nil }

        var stblBox: BoxSpan?
        forEachChildBox(buf, start: minf.contentStart, end: minf.end) { box in
            if box.type == boxStbl { stblBox = box }
        }
        guard let stbl = stblBox else { return nil }

        var sttsBox: BoxSpan?
        var stssBox: BoxSpan?
        var stscBox: BoxSpan?
        var stszBox: BoxSpan?
        var stcoBox: BoxSpan?
        var co64Box: BoxSpan?

        forEachChildBox(buf, start: stbl.contentStart, end: stbl.end) { box in
            switch box.type {
            case boxStts: sttsBox = box
            case boxStss: stssBox = box
            case boxStsc: stscBox = box
            case boxStsz: stszBox = box
            case boxStco: stcoBox = box
            case boxCo64: co64Box = box
            default: break
            }
        }

        guard let sttsBox, let stts = parseStts(buf, sttsBox),
              let stscBox, let stsc = parseStsc(buf, stscBox),
              let stszBox, let stsz = parseStsz(buf, stszBox) else { return nil }
        let chunkOffsets: [Int64]
        if let co64Box, let c64 = parseCo64(buf, co64Box) {
            chunkOffsets = c64
        } else if let stcoBox, let c32 = parseStco(buf, stcoBox) {
            chunkOffsets = c32
        } else {
            return nil
        }
        guard !chunkOffsets.isEmpty else { return nil }

        let syncSamples = stssBox.flatMap { parseStss(buf, $0) }
        let durationMs = durationUnits > 0 ? (durationUnits * 1000) / timescale : 0
        let points = buildSeekPoints(
            timescale: timescale,
            sttsCounts: stts.0,
            sttsDeltas: stts.1,
            syncSamples: syncSamples,
            stscFirstChunk: stsc.0,
            stscSamplesPerChunk: stsc.1,
            stszConstantSize: stsz.0,
            stszSizes: stsz.1,
            chunkOffsets: chunkOffsets,
            sampleIntervalMs: sampleIntervalMs
        )
        return (durationMs, points)
    }

    private static func buildSeekPoints(
        timescale: Int64,
        sttsCounts: [Int],
        sttsDeltas: [Int64],
        syncSamples: [Int]?,
        stscFirstChunk: [Int],
        stscSamplesPerChunk: [Int],
        stszConstantSize: Int,
        stszSizes: [Int]?,
        chunkOffsets: [Int64],
        sampleIntervalMs: Int64
    ) -> [Mp4SeekPoint] {
        let totalSamples = stszSizes?.count ?? sttsCounts.reduce(0, +)
        guard totalSamples > 0 else { return [] }

        var result: [Mp4SeekPoint] = []
        result.reserveCapacity(min(maxSeekPoints, 256))

        var sttsIdx = 0
        var sttsRemaining = sttsCounts.first ?? 0
        var sttsDelta = sttsDeltas.first ?? 0

        var syncCursor = 0
        var stscIdx = 0
        var sampleIndex1Based = 1
        var currentTimeUnits: Int64 = 0
        var lastEmittedTimeMs: Int64 = Int64.min

        for (chunkIdx, chunkStart) in chunkOffsets.enumerated() {
            let chunkNum1Based = chunkIdx + 1
            while stscIdx + 1 < stscFirstChunk.count && stscFirstChunk[stscIdx + 1] <= chunkNum1Based {
                stscIdx += 1
            }
            let samplesInChunk = stscIdx < stscSamplesPerChunk.count ? stscSamplesPerChunk[stscIdx] : 0
            if samplesInChunk <= 0 { continue }

            var byteOffset = chunkStart
            for _ in 0..<samplesInChunk {
                if sampleIndex1Based > totalSamples { break }
                let isSync: Bool
                if let syncSamples {
                    while syncCursor < syncSamples.count && syncSamples[syncCursor] < sampleIndex1Based {
                        syncCursor += 1
                    }
                    isSync = syncCursor < syncSamples.count && syncSamples[syncCursor] == sampleIndex1Based
                } else {
                    isSync = true
                }

                if isSync {
                    let timeMs = (currentTimeUnits * 1000) / timescale
                    if result.isEmpty || (timeMs - lastEmittedTimeMs >= sampleIntervalMs && result.count < maxSeekPoints) {
                        result.append(Mp4SeekPoint(timeMs: timeMs, byteOffset: max(0, byteOffset)))
                        lastEmittedTimeMs = timeMs
                    }
                }

                let sampleBytes: Int
                if stszConstantSize > 0 {
                    sampleBytes = stszConstantSize
                } else if let stszSizes, sampleIndex1Based - 1 < stszSizes.count {
                    sampleBytes = stszSizes[sampleIndex1Based - 1]
                } else {
                    sampleBytes = 0
                }
                byteOffset += Int64(sampleBytes)

                while sttsRemaining <= 0 && sttsIdx + 1 < sttsCounts.count {
                    sttsIdx += 1
                    sttsRemaining = sttsCounts[sttsIdx]
                    sttsDelta = sttsDeltas[sttsIdx]
                }
                if sttsRemaining > 0 {
                    currentTimeUnits += sttsDelta
                    sttsRemaining -= 1
                }
                sampleIndex1Based += 1
            }
            if sampleIndex1Based > totalSamples { break }
        }
        return result
    }

    private static func parseMvhdDurationMs(_ buf: [UInt8], start: Int, end: Int) -> Int64 {
        guard start + 4 <= end else { return 0 }
        let version = buf[start]
        if version == 0 {
            guard start + 20 <= end else { return 0 }
            let timescale = Int64(readUInt32(buf, start + 12))
            let duration = Int64(readUInt32(buf, start + 16))
            return timescale > 0 ? (duration * 1000) / timescale : 0
        } else if version == 1 {
            guard start + 32 <= end else { return 0 }
            let timescale = Int64(readUInt32(buf, start + 20))
            let duration = readInt64(buf, start + 24)
            return timescale > 0 && duration > 0 ? (duration * 1000) / timescale : 0
        }
        return 0
    }

    private static func parseMdhd(_ buf: [UInt8], start: Int, end: Int) -> (Int64, Int64)? {
        guard start + 4 <= end else { return nil }
        let version = buf[start]
        if version == 0 {
            guard start + 20 <= end else { return nil }
            return (Int64(readUInt32(buf, start + 12)), Int64(readUInt32(buf, start + 16)))
        } else if version == 1 {
            guard start + 32 <= end else { return nil }
            return (Int64(readUInt32(buf, start + 20)), readInt64(buf, start + 24))
        }
        return nil
    }

    private static func parseStts(_ buf: [UInt8], _ box: BoxSpan) -> ([Int], [Int64])? {
        let start = box.contentStart
        guard start + 8 <= box.end else { return nil }
        let count = Int(readUInt32(buf, start + 4))
        guard count > 0, count <= 500_000, Int64(start) + 8 + Int64(count) * 8 <= Int64(box.end) else { return nil }
        var counts = [Int](repeating: 0, count: count)
        var deltas = [Int64](repeating: 0, count: count)
        var pos = start + 8
        for i in 0..<count {
            counts[i] = Int(readUInt32(buf, pos))
            deltas[i] = Int64(readUInt32(buf, pos + 4))
            pos += 8
        }
        return (counts, deltas)
    }

    private static func parseStss(_ buf: [UInt8], _ box: BoxSpan) -> [Int]? {
        let start = box.contentStart
        guard start + 8 <= box.end else { return nil }
        let count = Int(readUInt32(buf, start + 4))
        guard count > 0, count <= 500_000, Int64(start) + 8 + Int64(count) * 4 <= Int64(box.end) else { return nil }
        var out = [Int](repeating: 0, count: count)
        var pos = start + 8
        for i in 0..<count {
            out[i] = Int(readUInt32(buf, pos))
            pos += 4
        }
        return out
    }

    private static func parseStsc(_ buf: [UInt8], _ box: BoxSpan) -> ([Int], [Int])? {
        let start = box.contentStart
        guard start + 8 <= box.end else { return nil }
        let count = Int(readUInt32(buf, start + 4))
        guard count > 0, count <= 500_000, Int64(start) + 8 + Int64(count) * 12 <= Int64(box.end) else { return nil }
        var firstChunks = [Int](repeating: 0, count: count)
        var spc = [Int](repeating: 0, count: count)
        var pos = start + 8
        for i in 0..<count {
            firstChunks[i] = Int(readUInt32(buf, pos))
            spc[i] = Int(readUInt32(buf, pos + 4))
            pos += 12
        }
        return (firstChunks, spc)
    }

    private static func parseStsz(_ buf: [UInt8], _ box: BoxSpan) -> (Int, [Int]?)? {
        let start = box.contentStart
        guard start + 12 <= box.end else { return nil }
        let constantSize = Int(readUInt32(buf, start + 4))
        let sampleCount = Int(readUInt32(buf, start + 8))
        guard sampleCount >= 0, sampleCount <= 2_000_000 else { return nil }
        if constantSize > 0 { return (constantSize, nil) }
        guard Int64(start) + 12 + Int64(sampleCount) * 4 <= Int64(box.end) else { return nil }
        var sizes = [Int](repeating: 0, count: sampleCount)
        var pos = start + 12
        for i in 0..<sampleCount {
            sizes[i] = Int(readUInt32(buf, pos))
            pos += 4
        }
        return (0, sizes)
    }

    private static func parseStco(_ buf: [UInt8], _ box: BoxSpan) -> [Int64]? {
        let start = box.contentStart
        guard start + 8 <= box.end else { return nil }
        let count = Int(readUInt32(buf, start + 4))
        guard count > 0, count <= 500_000, Int64(start) + 8 + Int64(count) * 4 <= Int64(box.end) else { return nil }
        var offsets = [Int64](repeating: 0, count: count)
        var pos = start + 8
        for i in 0..<count {
            offsets[i] = Int64(readUInt32(buf, pos))
            pos += 4
        }
        return offsets
    }

    private static func parseCo64(_ buf: [UInt8], _ box: BoxSpan) -> [Int64]? {
        let start = box.contentStart
        guard start + 8 <= box.end else { return nil }
        let count = Int(readUInt32(buf, start + 4))
        guard count > 0, count <= 500_000, Int64(start) + 8 + Int64(count) * 8 <= Int64(box.end) else { return nil }
        var offsets = [Int64](repeating: 0, count: count)
        var pos = start + 8
        for i in 0..<count {
            offsets[i] = readInt64(buf, pos)
            pos += 8
        }
        return offsets
    }

    private static func readBoxHeader(_ buf: [UInt8], pos: Int, limit: Int) -> BoxSpan? {
        guard pos + 8 <= limit else { return nil }
        let rawSize = Int64(readUInt32(buf, pos))
        let type = readUInt32(buf, pos + 4)
        var headerLen = 8
        let size: Int64
        if rawSize == 0 {
            size = Int64(limit - pos)
        } else if rawSize == 1 {
            guard pos + 16 <= limit else { return nil }
            headerLen = 16
            size = readInt64(buf, pos + 8)
        } else {
            size = rawSize
        }
        guard size >= Int64(headerLen) else { return nil }
        let end = Int(min(Int64(limit), Int64(pos) + size))
        return BoxSpan(type: type, start: pos, contentStart: pos + headerLen, end: end, size: size)
    }

    private static func forEachChildBox(_ buf: [UInt8], start: Int, end: Int, visitor: (BoxSpan) -> Void) {
        var pos = start
        var guardCount = 0
        while pos + 8 <= end && guardCount < 2048 {
            guard let box = readBoxHeader(buf, pos: pos, limit: end) else { break }
            visitor(box)
            if box.end <= pos { break }
            pos = box.end
            guardCount += 1
        }
    }

    private static func readUInt32(_ buf: [UInt8], _ pos: Int) -> UInt32 {
        (UInt32(buf[pos]) << 24) |
            (UInt32(buf[pos + 1]) << 16) |
            (UInt32(buf[pos + 2]) << 8) |
            UInt32(buf[pos + 3])
    }

    private static func readInt64(_ buf: [UInt8], _ pos: Int) -> Int64 {
        (Int64(readUInt32(buf, pos)) << 32) | Int64(readUInt32(buf, pos + 4))
    }
}
