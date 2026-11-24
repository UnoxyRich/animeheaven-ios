import Foundation

/// Sparse 512 KB chunk cache on disk keyed by shared episode key (`ep:<episodeKey>:<contentLength>`).
/// Enables 0 ms cache hits across mirror failovers, manual mirror switching, and CDN token rotations.
public actor DiskChunkCache {
    public static let chunkSizeBytes: Int64 = 512 * 1024
    private static let baseMaxBytes: Int64 = 512 * 1024 * 1024
    private static let largeMaxBytes: Int64 = 1024 * 1024 * 1024
    private static let largeDiskThresholdBytes: Int64 = 4 * 1024 * 1024 * 1024

    public let rootDirectory: URL
    public let maxCacheBytes: Int64
    private var totalCachedBytes: Int64 = 0
    private var chunkFiles: [String: (url: URL, size: Int64, touchedAt: TimeInterval)] = [:]

    public init(rootDirectory: URL, maxCacheBytes: Int64? = nil) {
        self.rootDirectory = rootDirectory
        try? FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        if let explicit = maxCacheBytes {
            self.maxCacheBytes = explicit
        } else {
            let freeSpace = Self.availableDiskBytes(at: rootDirectory)
            self.maxCacheBytes = Self.calculateVideoCacheMaxBytes(usableSpaceBytes: freeSpace)
        }
        let scanned = Self.scanExistingChunks(in: rootDirectory)
        self.chunkFiles = scanned.entries
        self.totalCachedBytes = scanned.totalBytes
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
        usableSpaceBytes >= largeDiskThresholdBytes ? largeMaxBytes : baseMaxBytes
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

    /// Detects whether an MP4 prefix buffer contains the `moov` box (faststart MP4).
    public static func containsMoovBox(_ data: Data) -> Bool {
        guard data.count >= 8 else { return false }
        let bytes = [UInt8](data)
        let limit = bytes.count - 4
        var i = 0
        while i <= limit {
            if bytes[i] == 0x6D &&     // 'm'
               bytes[i + 1] == 0x6F && // 'o'
               bytes[i + 2] == 0x6F && // 'o'
               bytes[i + 3] == 0x76 {  // 'v'
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
        guard durationMs > 0, totalLength > 0 else { return 0 }
        let ratio = min(1.0, max(0.0, Double(positionMs) / Double(durationMs)))
        return Int64(Double(totalLength) * ratio)
    }

    public static func buildInitialWindowChunks(
        totalLength: Int64,
        targetBytes: Int64,
        resumePositionMs: Int64,
        estimatedDurationMs: Int64,
        opEndMs: Int64
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
        let startByte: Int64
        if resumePositionMs > 10_000 && estimatedDurationMs > 0 {
            let est = estimateByteOffset(
                positionMs: resumePositionMs,
                durationMs: estimatedDurationMs,
                totalLength: totalLength
            )
            startByte = alignChunkStart(max(0, est - chunkSizeBytes))
        } else {
            startByte = 0
        }

        for i in 0..<chunkCount {
            appendUnique(startByte + Int64(i) * chunkSizeBytes)
        }

        if opEndMs > 5_000 && estimatedDurationMs > 0 {
            let opStart = alignChunkStart(
                estimateByteOffset(positionMs: opEndMs, durationMs: estimatedDurationMs, totalLength: totalLength)
            )
            for step in 0..<3 {
                appendUnique(opStart + Int64(step) * chunkSizeBytes)
            }
        }

        return ordered
    }

    // MARK: - Chunk Read / Write

    public func hasChunk(cacheKey: String, chunkOffset: Int64) -> Bool {
        let id = chunkId(cacheKey: cacheKey, chunkOffset: chunkOffset)
        return chunkFiles[id] != nil
    }

    public func readChunk(cacheKey: String, chunkOffset: Int64) -> Data? {
        let id = chunkId(cacheKey: cacheKey, chunkOffset: chunkOffset)
        guard var entry = chunkFiles[id] else { return nil }
        guard let data = try? Data(contentsOf: entry.url) else {
            chunkFiles.removeValue(forKey: id)
            totalCachedBytes = max(0, totalCachedBytes - entry.size)
            return nil
        }
        entry.touchedAt = Date().timeIntervalSince1970
        chunkFiles[id] = entry
        return data
    }

    public func writeChunk(cacheKey: String, chunkOffset: Int64, data: Data) {
        guard !data.isEmpty else { return }
        let id = chunkId(cacheKey: cacheKey, chunkOffset: chunkOffset)
        let fileURL = rootDirectory.appendingPathComponent("\(id).chk")
        do {
            try data.write(to: fileURL, options: .atomic)
            let newSize = Int64(data.count)
            if let existing = chunkFiles[id] {
                totalCachedBytes = max(0, totalCachedBytes - existing.size)
            }
            chunkFiles[id] = (url: fileURL, size: newSize, touchedAt: Date().timeIntervalSince1970)
            totalCachedBytes += newSize
            evictIfNeeded()
        } catch {
            // Ignore transient disk write failures; upstream fetch can still serve the caller.
        }
    }

    public func totalSizeBytes() -> Int64 {
        totalCachedBytes
    }

    public func clearAll() {
        for entry in chunkFiles.values {
            try? FileManager.default.removeItem(at: entry.url)
        }
        chunkFiles.removeAll()
        totalCachedBytes = 0
    }

    private func evictIfNeeded() {
        guard totalCachedBytes > maxCacheBytes else { return }
        let target = Int64(Double(maxCacheBytes) * 0.85)
        let sorted = chunkFiles.sorted { $0.value.touchedAt < $1.value.touchedAt }
        for (id, entry) in sorted {
            guard totalCachedBytes > target else { break }
            try? FileManager.default.removeItem(at: entry.url)
            chunkFiles.removeValue(forKey: id)
            totalCachedBytes = max(0, totalCachedBytes - entry.size)
        }
    }

    private func chunkId(cacheKey: String, chunkOffset: Int64) -> String {
        let hash = Self.fnv1a64Hex(cacheKey)
        return "\(hash)_\(chunkOffset)"
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

    private static func scanExistingChunks(
        in dir: URL
    ) -> (entries: [String: (url: URL, size: Int64, touchedAt: TimeInterval)], totalBytes: Int64) {
        var entries: [String: (url: URL, size: Int64, touchedAt: TimeInterval)] = [:]
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
            let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = Int64(vals?.fileSize ?? 0)
            let touched = vals?.contentModificationDate?.timeIntervalSince1970 ?? 0
            entries[id] = (url: url, size: size, touchedAt: touched)
            total += size
        }
        return (entries, total)
    }
}
