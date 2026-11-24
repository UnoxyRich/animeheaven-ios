import CoreGraphics
import Foundation
import ImageIO
import UIKit
import AnimeHeavenCore

private final class ArtworkImageRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        var request = request
        guard request.url?.scheme?.lowercased() == "https" else { return nil }
        request.setValue(ArtworkImageHeaders.referer(forHost: request.url?.host), forHTTPHeaderField: "Referer")
        return request
    }
}

/// Hardware-downsampled image cache backed by `NSCache<NSString, UIImage>` + 250 MB LRU disk cache.
/// Uses a dedicated `URLSession` with `urlCache = nil` (eliminating double disk caching) and
/// `CGImageSourceCreateThumbnailAtIndex` so full-resolution bitmaps never enter RAM.
public actor ImageCacheManager {
    private static let maxDiskBytes: Int64 = 250 * 1024 * 1024

    private let diskDirectory: URL
    private let session: URLSession
    private let memoryCache = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private typealias DiskEntries = [String: (url: URL, size: Int64, touchedAt: TimeInterval)]
    private var diskIndex: DiskEntries = [:]
    private var totalDiskBytes: Int64 = 0
    private var warmupTask: Task<(entries: DiskEntries, total: Int64), Never>?
    private var didWarmUp = false
    private var clearing = false

    public init(diskDirectory: URL) {
        self.diskDirectory = diskDirectory
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
        config.httpAdditionalHeaders = ["User-Agent": AnimeHeavenClient.userAgent]
        self.session = URLSession(configuration: config, delegate: ArtworkImageRedirects(), delegateQueue: nil)

    }

    public func warmUp() async {
        if didWarmUp { return }
        let task: Task<(entries: DiskEntries, total: Int64), Never>
        if let existing = warmupTask {
            task = existing
        } else {
            task = Task.detached(priority: .utility) { [diskDirectory] in
                try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
                return Self.scanDisk(in: diskDirectory)
            }
            warmupTask = task
        }
        let scanned = await task.value
        if didWarmUp { return }
        diskIndex = scanned.entries
        totalDiskBytes = scanned.total
        didWarmUp = true
        warmupTask = nil
    }

    public func image(for urlString: String, targetSize: ImageTargetSize) async -> UIImage? {
        guard !clearing, !Task.isCancelled, !urlString.isEmpty,
              let url = URL(string: urlString), url.scheme?.lowercased() == "https" else { return nil }
        let memKey = "\(urlString)#\(targetSize.widthPx)x\(targetSize.heightPx)"
        if let cached = memoryCache.object(forKey: memKey as NSString) {
            return cached
        }
        if let existing = inFlight[memKey] {
            return await existing.value
        }

        let diskKey = Self.fnv1a64Hex(urlString)
        let maxPixels = targetSize.maxPixelDimension
        let task = Task<UIImage?, Never> {
            await warmUp()
            guard !Task.isCancelled else { return nil }
            // 1. Check disk cache
            if let entry = diskIndex[diskKey] {
                let img = await Self.runIO {
                    guard !Task.isCancelled, let data = try? Data(contentsOf: entry.url) else { return nil as UIImage? }
                    return Self.downsample(data: data, maxPixelSize: maxPixels)
                }
                guard !Task.isCancelled else { return nil }
                if let img {
                    diskIndex[diskKey]?.touchedAt = Date().timeIntervalSince1970
                    storeInMemory(img, key: memKey)
                    return img
                }
            }
            // 2. Fetch over network
            do {
                var request = URLRequest(url: url)
                request.setValue(ArtworkImageHeaders.referer(forHost: url.host), forHTTPHeaderField: "Referer")
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      !data.isEmpty, !Task.isCancelled else {
                    return nil
                }
                let fileURL = diskDirectory.appendingPathComponent("\(diskKey).img")
                let (img, wrote) = await Self.runIO {
                    guard !Task.isCancelled,
                          let image = Self.downsample(data: data, maxPixelSize: maxPixels) else {
                        return (nil as UIImage?, false)
                    }
                    let wrote = !Task.isCancelled && ((try? data.write(to: fileURL, options: .atomic)) != nil)
                    return (image, wrote)
                }
                if wrote {
                    if let old = diskIndex[diskKey] { totalDiskBytes -= old.size }
                    let size = Int64(data.count)
                    diskIndex[diskKey] = (fileURL, size, Date().timeIntervalSince1970)
                    totalDiskBytes += size
                    evictDiskIfNeeded()
                }
                guard !Task.isCancelled, let img else { return nil }
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

    public func clearDiskCache() async {
        if clearing { return }
        clearing = true
        defer { clearing = false }
        await warmUp()
        let pending = Array(inFlight.values)
        for task in pending { task.cancel() }
        for task in pending { _ = await task.value }

        memoryCache.removeAllObjects()
        for entry in diskIndex.values {
            try? FileManager.default.removeItem(at: entry.url)
        }
        diskIndex.removeAll()
        totalDiskBytes = 0
    }

    public func diskSizeBytes() async -> Int64 {
        await warmUp()
        return totalDiskBytes
    }

    private func storeInMemory(_ image: UIImage, key: String) {
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        memoryCache.setObject(image, forKey: key as NSString, cost: max(1, cost))
    }

    private nonisolated static func runIO<Value: Sendable>(_ work: @escaping @Sendable () -> Value) async -> Value {
        let task = Task.detached(priority: .utility, operation: work)
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
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
