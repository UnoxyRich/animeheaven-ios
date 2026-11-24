import CoreGraphics
import Foundation
import ImageIO
import UIKit
import AnimeHeavenCore

/// Hardware-downsampled image cache backed by `NSCache<NSString, UIImage>` + 250 MB LRU disk cache.
/// Uses a dedicated `URLSession` with `urlCache = nil` (eliminating double disk caching) and
/// `CGImageSourceCreateThumbnailAtIndex` so full-resolution bitmaps never enter RAM.
public actor ImageCacheManager {
    private static let maxDiskBytes: Int64 = 250 * 1024 * 1024

    private let diskDirectory: URL
    private let session: URLSession
    private let memoryCache = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private var diskIndex: [String: (url: URL, size: Int64, touchedAt: TimeInterval)] = [:]
    private var totalDiskBytes: Int64 = 0

    public init(diskDirectory: URL) {
        self.diskDirectory = diskDirectory
        try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)

        let physMem = ProcessInfo.processInfo.physicalMemory
        let isLowRam = physMem <= 3 * 1024 * 1024 * 1024
        let fraction = isLowRam ? 0.14 : 0.20
        let budget = Int(min(Double(physMem) * fraction, 160 * 1024 * 1024))
        self.memoryCache.totalCostLimit = max(32 * 1024 * 1024, budget)
        self.memoryCache.countLimit = 220

        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil // Dedicated disk cache below avoids writing image bytes twice
        config.httpMaximumConnectionsPerHost = 10
        config.timeoutIntervalForRequest = 12
        config.httpAdditionalHeaders = [
            "User-Agent": AnimeHeavenClient.userAgent,
            "Referer": "\(AnimeHeavenClient.baseURL)/"
        ]
        self.session = URLSession(configuration: config)

        let scanned = Self.scanDisk(in: diskDirectory)
        self.diskIndex = scanned.entries
        self.totalDiskBytes = scanned.total
    }

    public func image(for urlString: String, targetSize: ImageTargetSize) async -> UIImage? {
        guard !urlString.isEmpty, let url = URL(string: urlString) else { return nil }
        let memKey = "\(urlString)#\(targetSize.widthPx)x\(targetSize.heightPx)"
        if let cached = memoryCache.object(forKey: memKey as NSString) {
            return cached
        }
        if let existing = inFlight[memKey] {
            return await existing.value
        }

        let diskKey = Self.fnv1a64Hex(urlString)
        let task = Task<UIImage?, Never> {
            // 1. Check disk cache
            if let diskData = readDisk(key: diskKey),
               let img = Self.downsample(data: diskData, maxPixelSize: targetSize.maxPixelDimension) {
                storeInMemory(img, key: memKey)
                return img
            }
            // 2. Fetch over network
            do {
                let (data, response) = try await session.data(from: url)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      !data.isEmpty,
                      let img = Self.downsample(data: data, maxPixelSize: targetSize.maxPixelDimension) else {
                    return nil
                }
                writeDisk(key: diskKey, data: data)
                storeInMemory(img, key: memKey)
                return img
            } catch {
                return nil
            }
        }

        inFlight[memKey] = task
        let img = await task.value
        inFlight.removeValue(forKey: memKey)
        return img
    }

    public func preload(urls: [String], targetSize: ImageTargetSize) async {
        await withTaskGroup(of: Void.self) { group in
            for url in urls.prefix(8) {
                group.addTask {
                    _ = await self.image(for: url, targetSize: targetSize)
                }
            }
        }
    }

    public func clearMemoryCache() {
        memoryCache.removeAllObjects()
    }

    public func clearDiskCache() {
        memoryCache.removeAllObjects()
        for entry in diskIndex.values {
            try? FileManager.default.removeItem(at: entry.url)
        }
        diskIndex.removeAll()
        totalDiskBytes = 0
    }

    public func diskSizeBytes() -> Int64 {
        totalDiskBytes
    }

    private func storeInMemory(_ image: UIImage, key: String) {
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        memoryCache.setObject(image, forKey: key as NSString, cost: max(1, cost))
    }

    private func readDisk(key: String) -> Data? {
        guard var entry = diskIndex[key] else { return nil }
        guard let data = try? Data(contentsOf: entry.url) else {
            diskIndex.removeValue(forKey: key)
            totalDiskBytes = max(0, totalDiskBytes - entry.size)
            return nil
        }
        entry.touchedAt = Date().timeIntervalSince1970
        diskIndex[key] = entry
        return data
    }

    private func writeDisk(key: String, data: Data) {
        let fileURL = diskDirectory.appendingPathComponent("\(key).img")
        do {
            try data.write(to: fileURL, options: .atomic)
            let size = Int64(data.count)
            if let old = diskIndex[key] {
                totalDiskBytes = max(0, totalDiskBytes - old.size)
            }
            diskIndex[key] = (url: fileURL, size: size, touchedAt: Date().timeIntervalSince1970)
            totalDiskBytes += size
            evictDiskIfNeeded()
        } catch {
            // Non-fatal
        }
    }

    private func evictDiskIfNeeded() {
        guard totalDiskBytes > Self.maxDiskBytes else { return }
        let target = Int64(Double(Self.maxDiskBytes) * 0.85)
        let sorted = diskIndex.sorted { $0.value.touchedAt < $1.value.touchedAt }
        for (key, entry) in sorted {
            guard totalDiskBytes > target else { break }
            try? FileManager.default.removeItem(at: entry.url)
            diskIndex.removeValue(forKey: key)
            totalDiskBytes = max(0, totalDiskBytes - entry.size)
        }
    }

    private static func downsample(data: Data, maxPixelSize: Int) -> UIImage? {
        let sourceOpts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOpts as CFDictionary) else {
            return UIImage(data: data)
        }
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(64, maxPixelSize)
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOpts as CFDictionary) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cgImage)
    }

    private static func fnv1a64Hex(_ input: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for b in input.utf8 {
            hash ^= UInt64(b)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    private static func scanDisk(
        in dir: URL
    ) -> (entries: [String: (url: URL, size: Int64, touchedAt: TimeInterval)], total: Int64) {
        var entries: [String: (url: URL, size: Int64, touchedAt: TimeInterval)] = [:]
        var total: Int64 = 0
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return (entries, 0)
        }
        for url in files where url.pathExtension == "img" {
            let key = url.deletingPathExtension().lastPathComponent
            let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = Int64(vals?.fileSize ?? 0)
            let touched = vals?.contentModificationDate?.timeIntervalSince1970 ?? 0
            entries[key] = (url: url, size: size, touchedAt: touched)
            total += size
        }
        return (entries, total)
    }
}
