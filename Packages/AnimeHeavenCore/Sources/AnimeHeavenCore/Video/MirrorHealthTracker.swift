import Foundation

public struct VideoProbeMeta: Sendable, Hashable {
    public let url: String
    public let contentLength: Int64
    public let supportsRanges: Bool
    public let latencyMs: Int64

    public init(url: String, contentLength: Int64, supportsRanges: Bool, latencyMs: Int64) {
        self.url = url
        self.contentLength = contentLength
        self.supportsRanges = supportsRanges
        self.latencyMs = latencyMs
    }
}

public struct MirrorQueueState: Sendable, Equatable {
    public let sources: [String]
    public let activeIndex: Int
    public let exhausted: Bool

    public init(sources: [String], activeIndex: Int = 0, exhausted: Bool = false) {
        self.sources = sources
        self.activeIndex = activeIndex
        self.exhausted = exhausted
    }

    public var currentUrl: String? {
        guard !exhausted, activeIndex >= 0, activeIndex < sources.count else { return nil }
        return sources[activeIndex]
    }

    public var mirrorCount: Int { sources.count }

    public var displayLabel: String {
        guard !sources.isEmpty else { return "Mirror 0/0" }
        let idx = min(activeIndex + 1, sources.count)
        return "Mirror \(idx)/\(sources.count)"
    }

    public func advanceOnError() -> MirrorQueueState {
        guard !sources.isEmpty else {
            return MirrorQueueState(sources: [], activeIndex: 0, exhausted: true)
        }
        let next = activeIndex + 1
        if next >= sources.count {
            return MirrorQueueState(sources: sources, activeIndex: activeIndex, exhausted: true)
        }
        return MirrorQueueState(sources: sources, activeIndex: next, exhausted: false)
    }

    public func cycleManual() -> MirrorQueueState {
        guard sources.count > 1 else {
            return MirrorQueueState(sources: sources, activeIndex: 0, exhausted: sources.isEmpty)
        }
        let next = (activeIndex + 1) % sources.count
        return MirrorQueueState(sources: sources, activeIndex: next, exhausted: false)
    }

    public func reset() -> MirrorQueueState {
        MirrorQueueState(sources: sources, activeIndex: 0, exhausted: sources.isEmpty)
    }
}

/// Tracks CDN host RTT latency, failure cooldowns, EWMA throughput (`avgBytesPerSec`),
/// and `< 1 MB` stub-clip detection with strictly transitive mirror ranking.
public final class MirrorHealthTracker: @unchecked Sendable {
    public static let minValidVideoBytes: Int64 = 1 * 1024 * 1024
    public static let failureCooldownMs: Int64 = 60_000
    public static let persistThrottleMs: Int64 = 15_000
    private static let defaultsKeyPrefix = "ah_mirror_health_"

    private struct HostStats: Sendable {
        var lastLatencyMs: Int64 = Int64.max
        var failureCount: Int = 0
        var lastFailureAtMs: Int64 = 0
        var isStubVideo: Bool = false
        var avgBytesPerSec: Int64 = 0

        func encode() -> String {
            "\(lastLatencyMs)|\(failureCount)|\(lastFailureAtMs)|\(isStubVideo)|\(avgBytesPerSec)"
        }

        static func decode(_ raw: String) -> HostStats? {
            let parts = raw.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count == 4 || parts.count == 5,
                  let lat = Int64(parts[0]),
                  let fail = Int(parts[1]),
                  let failAt = Int64(parts[2]) else {
                return nil
            }
            let stub = (String(parts[3]).lowercased() == "true")
            let bps = parts.count == 5 ? (Int64(parts[4]) ?? 0) : 0
            return HostStats(
                lastLatencyMs: lat,
                failureCount: fail,
                lastFailureAtMs: failAt,
                isStubVideo: stub,
                avgBytesPerSec: bps
            )
        }
    }

    private let lock = NSLock()
    private let defaults: UserDefaults?
    private let persistenceQueue = DispatchQueue(label: "me.animeheaven.ios.mirror-health")
    private let clockMs: @Sendable () -> Int64
    private var statsByHost: [String: HostStats] = [:]
    private var lastPersistedAtMs: [String: Int64] = [:]

    public init(
        defaults: UserDefaults? = nil,
        clockMs: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.defaults = defaults
        self.clockMs = clockMs
        if let defaults {
            for (key, value) in defaults.dictionaryRepresentation() {
                guard key.hasPrefix(Self.defaultsKeyPrefix),
                      let raw = value as? String,
                      let stats = HostStats.decode(raw) else {
                    continue
                }
                let host = String(key.dropFirst(Self.defaultsKeyPrefix.count))
                statsByHost[host] = stats
            }
        }
    }

    public func recordSuccess(url: String, latencyMs: Int64 = 100) {
        guard let host = Self.extractHost(url) else { return }
        lock.lock()
        let prev = statsByHost[host]
        let updated = HostStats(
            lastLatencyMs: max(1, latencyMs),
            failureCount: 0,
            lastFailureAtMs: 0,
            isStubVideo: false,
            avgBytesPerSec: prev?.avgBytesPerSec ?? 0
        )
        saveLocked(host: host, stats: updated, forcePersist: true)
        lock.unlock()
    }

    public func recordThroughput(url: String, bytesTransferred: Int64, durationMs: Int64) {
        guard bytesTransferred >= 32 * 1024, durationMs > 0,
              let host = Self.extractHost(url) else {
            return
        }
        let sampleBps = (bytesTransferred * 1000) / max(1, durationMs)
        lock.lock()
        var prev = statsByHost[host] ?? HostStats()
        if prev.avgBytesPerSec <= 0 {
            prev.avgBytesPerSec = sampleBps
        } else {
            prev.avgBytesPerSec = Int64(Double(prev.avgBytesPerSec) * 0.65 + Double(sampleBps) * 0.35)
        }
        prev.failureCount = 0
        prev.lastFailureAtMs = 0
        prev.isStubVideo = false
        saveLocked(host: host, stats: prev, forcePersist: false)
        lock.unlock()
    }

    public func recordFailure(url: String) {
        guard let host = Self.extractHost(url) else { return }
        let now = clockMs()
        lock.lock()
        var prev = statsByHost[host] ?? HostStats()
        prev.failureCount += 1
        prev.lastFailureAtMs = now
        saveLocked(host: host, stats: prev, forcePersist: true)
        lock.unlock()
    }

    public func recordStubVideo(url: String) {
        guard let host = Self.extractHost(url) else { return }
        lock.lock()
        var prev = statsByHost[host] ?? HostStats()
        prev.isStubVideo = true
        saveLocked(host: host, stats: prev, forcePersist: true)
        lock.unlock()
    }

    public func hasFreshStats(url: String) -> Bool {
        guard let host = Self.extractHost(url) else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard let stats = statsByHost[host] else { return false }
        return stats.lastLatencyMs < Int64.max || stats.isStubVideo || stats.failureCount > 0
    }

    public func rankMirrors(_ urls: [String]) -> [String] {
        guard urls.count > 1 else { return urls }
        let now = clockMs()
        lock.lock()
        let snapshot = statsByHost
        lock.unlock()

        let indexed = urls.enumerated().map { (idx, url) -> (Int, String, (Int, Int64, Int)) in
            let host = Self.extractHost(url)
            let stats = host.flatMap { snapshot[$0] }
            let key = sortKey(stats: stats, nowMs: now, originalIndex: idx)
            return (idx, url, key)
        }

        return indexed.sorted { a, b in
            if a.2.0 != b.2.0 { return a.2.0 < b.2.0 }
            if a.2.1 != b.2.1 { return a.2.1 < b.2.1 }
            return a.2.2 < b.2.2
        }.map(\.1)
    }

    public func topHealthyHosts(limit: Int = 3) -> [String] {
        let now = clockMs()
        lock.lock()
        let entries = Array(statsByHost)
        lock.unlock()

        return entries.compactMap { (host, stats) -> (String, Int64)? in
            guard !stats.isStubVideo else { return nil }
            let inCooldown = stats.failureCount > 0 && (now - stats.lastFailureAtMs) < Self.failureCooldownMs
            guard !inCooldown, stats.lastLatencyMs < Int64.max else { return nil }
            let score = stats.avgBytesPerSec > 0
                ? -stats.avgBytesPerSec
                : stats.lastLatencyMs
            return (host, score)
        }
        .sorted { $0.1 < $1.1 }
        .prefix(limit)
        .map(\.0)
    }

    public func reset() {
        lock.lock()
        let keys = statsByHost.keys.map { "\(Self.defaultsKeyPrefix)\($0)" }
        statsByHost.removeAll()
        lastPersistedAtMs.removeAll()
        if !keys.isEmpty {
            persistenceQueue.async { [weak self] in
                guard let defaults = self?.defaults else { return }
                for key in keys { defaults.removeObject(forKey: key) }
            }
        }
        lock.unlock()
    }

    /// Strictly transitive tier sort key:
    /// Tier 0: Healthy with known throughput/latency (sorted by throughput-weighted latency score)
    /// Tier 1: Untried or cooled-down host (preserves original server order)
    /// Tier 2: Failed within active cooldown window
    /// Tier 3: Detected `< 1 MB` stub video host
    private func sortKey(stats: HostStats?, nowMs: Int64, originalIndex: Int) -> (Int, Int64, Int) {
        guard let stats else {
            return (1, Int64(originalIndex), originalIndex)
        }
        if stats.isStubVideo {
            return (3, Int64(originalIndex), originalIndex)
        }
        let inCooldown = stats.failureCount > 0 && (nowMs - stats.lastFailureAtMs) < Self.failureCooldownMs
        if inCooldown {
            return (2, Int64(stats.failureCount), originalIndex)
        }
        if stats.failureCount == 0 && (stats.lastLatencyMs < Int64.max || stats.avgBytesPerSec > 0) {
            let lat = stats.lastLatencyMs == Int64.max ? 250 : stats.lastLatencyMs
            let bpsBonus = min(stats.avgBytesPerSec / 4_096, 800)
            let score = lat - bpsBonus
            return (0, score, originalIndex)
        }
        return (1, Int64(originalIndex), originalIndex)
    }

    private func saveLocked(host: String, stats: HostStats, forcePersist: Bool) {
        statsByHost[host] = stats
        guard defaults != nil else { return }
        let now = clockMs()
        let prev = lastPersistedAtMs[host] ?? 0
        if forcePersist || (now - prev) >= Self.persistThrottleMs {
            lastPersistedAtMs[host] = now
            let encoded = stats.encode()
            persistenceQueue.async { [weak self] in
                self?.defaults?.set(encoded, forKey: "\(Self.defaultsKeyPrefix)\(host)")
            }
        }
    }

    public static func extractHost(_ rawUrl: String) -> String? {
        guard let schemeRange = rawUrl.range(of: "://") else { return nil }
        let afterScheme = rawUrl[schemeRange.upperBound...]
        let endIdx = afterScheme.firstIndex { $0 == "/" || $0 == ":" || $0 == "?" || $0 == "#" } ?? afterScheme.endIndex
        let host = afterScheme[..<endIdx].lowercased()
        return host.isEmpty ? nil : host
    }
}
