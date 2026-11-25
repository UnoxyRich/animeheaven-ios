import Foundation

/// Sparse 512 KB chunk cache on disk keyed by shared episode key (`ep:<episodeKey>:<contentLength>`).
/// Supports two-tier eviction protection (Tier A hot-start/resume/Watch-Next windows up to 40%
/// budget vs Tier B watched streaming history), up to 2 GB storage scaling, and persisted episode
/// byte lengths for 0 ms cold-start cache key lookup.
public actor DiskChunkCache {
    public static let chunkSizeBytes: Int64 = 512 * 1024
    private static let baseMaxBytes: Int64 = 512 * 1024 * 1024
    private static let largeMaxBytes: Int64 = 1024 * 1024 * 1024
    private static let xlargeMaxBytes: Int64 = 2 * 1024 * 1024 * 1024
    private static let largeDiskThresholdBytes: Int64 = 4 * 1024 * 1024 * 1024
    private static let xlargeDiskThresholdBytes: Int64 = 12 * 1024 * 1024 * 1024
    private static let protectedBudgetRatio: Double = 0.40
    private static let lengthsFilename = "episode_lengths.json"

    public let rootDirectory: URL
    public private(set) var maxCacheBytes: Int64
    private let explicitBudget: Int64?
    private var isWarm = false
    private var totalCachedBytes: Int64 = 0
    private var chunkFiles: [String: (url: URL, size: Int64, touchedAt: TimeInterval, cacheKeyHash: String, offset: Int64)] = [:]
    private var protectedChunkIds = Set<String>()
    private var protectedBytes: Int64 = 0
    private var episodeLengths: [String: Int64] = [:]

    public init(rootDirectory: URL, maxCacheBytes: Int64? = nil) {
        self.rootDirectory = rootDirectory
        self.explicitBudget = maxCacheBytes
        self.maxCacheBytes = maxCacheBytes ?? Self.baseMaxBytes
    }

    public func warmUp() {
        guard !isWarm else { return }
        var directory = rootDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
        if explicitBudget == nil {
            maxCacheBytes = Self.calculateVideoCacheMaxBytes(usableSpaceBytes: Self.availableDiskBytes(at: directory))
        }
        let scanned = Self.scanExistingChunks(in: directory)
        self.chunkFiles = scanned.entries
        self.totalCachedBytes = scanned.totalBytes
        self.episodeLengths = Self.loadEpisodeLengths(in: directory)
        isWarm = true
    }

    public static func buildEpisodeCacheKey(
        episodeKey: String?,
        contentLength: Int64,
        fallbackUrl: String
    ) -> String {
        if let episodeKey, !episodeKey.isEmpty, contentLength >= MirrorHealthTracker.minValidVideoBytes {
            return "ep:\(episodeKey):\(contentLength)"
        }
        return fallbackUrl
    }

    public static func calculateVideoCacheMaxBytes(usableSpaceBytes: Int64) -> Int64 {
        let clamped = max(0, usableSpaceBytes)
        let target: Int64
        if clamped >= xlargeDiskThresholdBytes {
            target = xlargeMaxBytes
        } else if clamped >= largeDiskThresholdBytes {
            target = largeMaxBytes
        } else {
            target = baseMaxBytes
        }
        return min(target, clamped / 4)
    }

    public static func parseTotalLengthFromHeaders(
        contentRange: String?,
        contentLength: String?,
        statusCode: Int
    ) -> Int64 {
        if let range = contentRange, !range.isEmpty,
           let slash = range.lastIndex(of: "/") {
            let tail = range[range.index(after: slash)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if let total = Int64(tail), total > 0 {
                return total
            }
        }
        if statusCode == 200, let len = contentLength?.trimmingCharacters(in: .whitespacesAndNewlines),
           let parsed = Int64(len), parsed > 0 {
            return parsed
        }
        return -1
    }

    public static func containsMoovBox(_ data: Data) -> Bool {
        guard data.count >= 8 else { return false }
        let bytes = [UInt8](data)
        let limit = bytes.count - 4
        var i = 0
        while i <= limit {
            if bytes[i] == 0x6D &&
               bytes[i + 1] == 0x6F &&
               bytes[i + 2] == 0x6F &&
               bytes[i + 3] == 0x76 {
                return true
            }
            i += 1
        }
        return false
    }

    public static func alignChunkStart(_ offset: Int64) -> Int64 {
        max(0, (offset / chunkSizeBytes) * chunkSizeBytes)
    }

    public static func estimateByteOffset(
        positionMs: Int64,
        durationMs: Int64,
        totalLength: Int64
    ) -> Int64 {
        guard positionMs > 0, durationMs > 0, totalLength > 0 else { return 0 }
        let ratio = min(0.99, max(0.0, Double(positionMs) / Double(durationMs)))
        return Int64(Double(totalLength) * ratio)
    }

    public static func resolveByteOffset(
        videoIndex: EpisodeVideoIndex?,
        positionMs: Int64,
        durationMs: Int64,
        totalLength: Int64
    ) -> Int64 {
        guard positionMs > 0, totalLength > 0 else { return 0 }
        if let exact = videoIndex?.resolveByteOffset(targetMs: positionMs) {
            return min(max(0, totalLength - 1), max(0, exact))
        }
        return estimateByteOffset(positionMs: positionMs, durationMs: durationMs, totalLength: totalLength)
    }

    public static func buildInitialWindowChunks(
        totalLength: Int64,
        targetBytes: Int64,
        resumePositionMs: Int64,
        estimatedDurationMs: Int64,
        opEndMs: Int64,
        videoIndex: EpisodeVideoIndex? = nil
    ) -> [Int64] {
        guard totalLength > 0, targetBytes > 0 else { return [] }
        var ordered: [Int64] = []
        var seen = Set<Int64>()

        func appendUnique(_ offset: Int64) {
            if offset >= 0 && offset < totalLength && seen.insert(offset).inserted {
                ordered.append(offset)
            }
        }

        appendUnique(0)

        let chunkCount = max(1, Int((targetBytes + chunkSizeBytes - 1) / chunkSizeBytes))
        let effectiveDur = (videoIndex?.durationMs ?? 0) > 0 ? (videoIndex?.durationMs ?? 0) : estimatedDurationMs

        let exactResume = resumePositionMs > 10_000 ? videoIndex?.resolveByteOffset(targetMs: resumePositionMs) : nil
        let startByte: Int64
        let windowChunks: Int
        if let exactResume {
            let aligned = alignChunkStart(exactResume)
            startByte = (exactResume - aligned < 64 * 1024 && aligned >= chunkSizeBytes) ? (aligned - chunkSizeBytes) : aligned
            windowChunks = chunkCount
        } else if resumePositionMs > 10_000 && effectiveDur > 0 {
            let est = estimateByteOffset(positionMs: resumePositionMs, durationMs: effectiveDur, totalLength: totalLength)
            startByte = alignChunkStart(max(0, est - 2 * chunkSizeBytes))
            windowChunks = chunkCount + 2
        } else {
            startByte = 0
            windowChunks = chunkCount
        }

        for i in 0..<windowChunks {
            appendUnique(startByte + Int64(i) * chunkSizeBytes)
        }

        if opEndMs > 5_000 && effectiveDur > 0 {
            let opByte = resolveByteOffset(videoIndex: videoIndex, positionMs: opEndMs, durationMs: effectiveDur, totalLength: totalLength)
            let opStart = alignChunkStart(opByte)
            for step in 0..<3 {
                appendUnique(opStart + Int64(step) * chunkSizeBytes)
            }
        }

        return ordered
    }

    // MARK: - Persistent Episode Length Index

    public func recordEpisodeLength(episodeKey: String, contentLength: Int64) {
        guard !episodeKey.isEmpty, contentLength >= MirrorHealthTracker.minValidVideoBytes else { return }
        warmUp()
        if episodeLengths[episodeKey] == contentLength { return }
        episodeLengths[episodeKey] = contentLength
        if episodeLengths.count > 256 {
            let excess = episodeLengths.count - 200
            for key in Array(episodeLengths.keys.prefix(excess)) where key != episodeKey {
                episodeLengths.removeValue(forKey: key)
            }
        }
        Self.saveEpisodeLengths(episodeLengths, in: rootDirectory)
    }

    public func knownContentLength(episodeKey: String) -> Int64 {
        warmUp()
        return episodeLengths[episodeKey] ?? -1
    }

    // MARK: - Tier A / Tier B Eviction Protection

    public func markHotWindow(cacheKey: String, offsets: [Int64]) {
        warmUp()
        for offset in offsets {
            let id = chunkId(cacheKey: cacheKey, chunkOffset: offset)
            if protectedChunkIds.insert(id).inserted, let entry = chunkFiles[id] {
                protectedBytes += entry.size
            }
        }
    }

    public func demoteTrailingChunks(cacheKey: String, behindOffset: Int64) {
        guard behindOffset > 0 else { return }
        warmUp()
        let hash = Self.fnv1a64Hex(cacheKey)
        var toRemove: [String] = []
        for id in protectedChunkIds {
            if let entry = chunkFiles[id], entry.cacheKeyHash == hash, entry.offset + entry.size <= behindOffset {
                toRemove.append(id)
                protectedBytes = max(0, protectedBytes - entry.size)
            }
        }
        for id in toRemove { protectedChunkIds.remove(id) }
    }

    public func unpinKey(cacheKey: String) {
        warmUp()
        let hash = Self.fnv1a64Hex(cacheKey)
        let prefix = "\(hash)_"
        var toRemove: [String] = []
        for id in protectedChunkIds where id.hasPrefix(prefix) {
            toRemove.append(id)
            if let entry = chunkFiles[id] {
                protectedBytes = max(0, protectedBytes - entry.size)
            }
        }
        for id in toRemove { protectedChunkIds.remove(id) }
    }

    public func protectedSizeBytes() -> Int64 {
        warmUp()
        return protectedBytes
    }

    // MARK: - Chunk Read / Write

    public func hasChunk(cacheKey: String, chunkOffset: Int64) -> Bool {
        warmUp()
        let id = chunkId(cacheKey: cacheKey, chunkOffset: chunkOffset)
        return chunkFiles[id] != nil
    }

    public func readChunk(cacheKey: String, chunkOffset: Int64) -> Data? {
        warmUp()
        let id = chunkId(cacheKey: cacheKey, chunkOffset: chunkOffset)
        guard var entry = chunkFiles[id] else { return nil }
        guard let data = try? Data(contentsOf: entry.url) else {
            chunkFiles.removeValue(forKey: id)
            totalCachedBytes = max(0, totalCachedBytes - entry.size)
            if protectedChunkIds.remove(id) != nil {
                protectedBytes = max(0, protectedBytes - entry.size)
            }
            return nil
        }
        entry.touchedAt = Date().timeIntervalSince1970
        chunkFiles[id] = entry
        return data
    }

    /// Reads an arbitrary byte slice `[startOffset, startOffset + length)` spanning one or more
    /// cached 512 KB chunks without performing any network I/O.
    public func readRange(cacheKey: String, startOffset: Int64, length: Int) -> Data? {
        guard startOffset >= 0, length > 0 else { return nil }
        warmUp()
        var out = Data()
        out.reserveCapacity(length)
        var cursor = startOffset
        let end = startOffset + Int64(length)
        while cursor < end {
            let cStart = Self.alignChunkStart(cursor)
            guard let chunk = readChunk(cacheKey: cacheKey, chunkOffset: cStart) else { return nil }
            let rel = Int(cursor - cStart)
            guard rel < chunk.count else { return nil }
            let take = min(Int(end - cursor), chunk.count - rel)
            out.append(chunk[rel..<(rel + take)])
            cursor += Int64(take)
        }
        return out.count == length ? out : nil
    }

    public func cachedBytesInWindow(cacheKey: String, startOffset: Int64, windowBytes: Int64, totalLength: Int64) -> Int64 {
        guard startOffset >= 0, windowBytes > 0, totalLength > 0 else { return 0 }
        warmUp()
        let end = min(totalLength, startOffset + windowBytes)
        var cursor = Self.alignChunkStart(startOffset)
        var sum: Int64 = 0
        while cursor < end {
            let id = chunkId(cacheKey: cacheKey, chunkOffset: cursor)
            if let entry = chunkFiles[id] {
                let overlapStart = max(startOffset, cursor)
                let overlapEnd = min(end, cursor + entry.size)
                if overlapEnd > overlapStart {
                    sum += (overlapEnd - overlapStart)
                }
            }
            cursor += Self.chunkSizeBytes
        }
        return sum
    }

    public func writeChunk(cacheKey: String, chunkOffset: Int64, data: Data) {
        guard !data.isEmpty else { return }
        warmUp()
        let hash = Self.fnv1a64Hex(cacheKey)
        let id = "\(hash)_\(chunkOffset)"
        let fileURL = rootDirectory.appendingPathComponent("\(id).chk")
        do {
            try data.write(to: fileURL, options: .atomic)
            let newSize = Int64(data.count)
            let isPinned = protectedChunkIds.contains(id)
            if let existing = chunkFiles[id] {
                totalCachedBytes = max(0, totalCachedBytes - existing.size)
                if isPinned { protectedBytes = max(0, protectedBytes - existing.size) }
            }
            chunkFiles[id] = (url: fileURL, size: newSize, touchedAt: Date().timeIntervalSince1970, cacheKeyHash: hash, offset: chunkOffset)
            totalCachedBytes += newSize
            if isPinned { protectedBytes += newSize }
            evictIfNeeded()
        } catch {
            // Ignore transient disk write failures
        }
    }

    public func totalSizeBytes() -> Int64 {
        warmUp()
        return totalCachedBytes
    }

    public func clearAll() {
        warmUp()
        for entry in chunkFiles.values {
            try? FileManager.default.removeItem(at: entry.url)
        }
        chunkFiles.removeAll()
        protectedChunkIds.removeAll()
        episodeLengths.removeAll()
        try? FileManager.default.removeItem(at: rootDirectory.appendingPathComponent(Self.lengthsFilename))
        totalCachedBytes = 0
        protectedBytes = 0
    }

    private func evictIfNeeded() {
        guard totalCachedBytes > maxCacheBytes else { return }
        let target = Int64(Double(maxCacheBytes) * 0.85)
        let protectedCap = Int64(Double(maxCacheBytes) * Self.protectedBudgetRatio)

        // Phase 1: Evict oldest Tier B (unpinned watched chunks) first!
        let unpinned = chunkFiles
            .filter { !protectedChunkIds.contains($0.key) }
            .sorted { $0.value.touchedAt < $1.value.touchedAt }
        for (id, entry) in unpinned {
            guard totalCachedBytes > target else { break }
            try? FileManager.default.removeItem(at: entry.url)
            chunkFiles.removeValue(forKey: id)
            totalCachedBytes = max(0, totalCachedBytes - entry.size)
        }

        // Phase 2: Only evict oldest Tier A pinned chunks if over total target or protected cap
        if totalCachedBytes > target || protectedBytes > protectedCap {
            let pinned = chunkFiles
                .filter { protectedChunkIds.contains($0.key) }
                .sorted { $0.value.touchedAt < $1.value.touchedAt }
            for (id, entry) in pinned {
                guard totalCachedBytes > target || protectedBytes > protectedCap else { break }
                try? FileManager.default.removeItem(at: entry.url)
                chunkFiles.removeValue(forKey: id)
                protectedChunkIds.remove(id)
                totalCachedBytes = max(0, totalCachedBytes - entry.size)
                protectedBytes = max(0, protectedBytes - entry.size)
            }
        }
    }

    private func chunkId(cacheKey: String, chunkOffset: Int64) -> String {
        "\(Self.fnv1a64Hex(cacheKey))_\(chunkOffset)"
    }

    private static func fnv1a64Hex(_ input: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for b in input.utf8 {
            hash ^= UInt64(b)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    private static func availableDiskBytes(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 {
            return important
        }
        if let cap = values?.volumeAvailableCapacity, cap > 0 {
            return Int64(cap)
        }
        return 2 * 1024 * 1024 * 1024
    }

    private static func loadEpisodeLengths(in dir: URL) -> [String: Int64] {
        let file = dir.appendingPathComponent(lengthsFilename)
        guard let data = try? Data(contentsOf: file),
              let map = try? JSONDecoder().decode([String: Int64].self, from: data) else {
            return [:]
        }
        return map
    }

    private static func saveEpisodeLengths(_ map: [String: Int64], in dir: URL) {
        let file = dir.appendingPathComponent(lengthsFilename)
        if let data = try? JSONEncoder().encode(map) {
            try? data.write(to: file, options: .atomic)
        }
    }

    private static func scanExistingChunks(
        in dir: URL
    ) -> (entries: [String: (url: URL, size: Int64, touchedAt: TimeInterval, cacheKeyHash: String, offset: Int64)], totalBytes: Int64) {
        var entries: [String: (url: URL, size: Int64, touchedAt: TimeInterval, cacheKeyHash: String, offset: Int64)] = [:]
        var total: Int64 = 0
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return (entries, 0)
        }
        for url in urls where url.pathExtension == "chk" {
            let id = url.deletingPathExtension().lastPathComponent
            let parts = id.split(separator: "_", maxSplits: 1)
            let hash = parts.first.map(String.init) ?? ""
            let offset = parts.count > 1 ? (Int64(parts[1]) ?? 0) : 0
            let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = Int64(vals?.fileSize ?? 0)
            let touched = vals?.contentModificationDate?.timeIntervalSince1970 ?? 0
            entries[id] = (url: url, size: size, touchedAt: touched, cacheKeyHash: hash, offset: offset)
            total += size
        }
        return (entries, total)
    }
}
