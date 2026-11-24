import Foundation

public struct StreamSessionDescriptor: Sendable {
    public let sessionId: String
    public let cacheKey: String
    public let episodeKey: String?
    public let mirrors: [String]
    public let totalLength: Int64

    public init(
        sessionId: String,
        cacheKey: String,
        episodeKey: String?,
        mirrors: [String],
        totalLength: Int64
    ) {
        self.sessionId = sessionId
        self.cacheKey = cacheKey
        self.episodeKey = episodeKey
        self.mirrors = mirrors
        self.totalLength = totalLength
    }
}

/// Multi-mirror parallel HTTP-Range chunk booster + mirror prober powering `LocalStreamProxyServer`.
/// Fetches 512 KB spans concurrently across throughput-ranked healthy mirrors with `Referer` injection,
/// commits chunks into `DiskChunkCache`, and detects non-faststart MP4 `moov` boxes for tail warming.
public actor StreamingChunkBooster {
    public static let defaultPreloadBytes: Int64 = 2 * 1024 * 1024
    private static let aheadWindowChunks: Int = 10

    public let diskCache: DiskChunkCache
    public let mirrorHealthTracker: MirrorHealthTracker
    private let videoSession: URLSession
    private let probeSession: URLSession
    private let probeMetaByUrl = LruCache<String, VideoProbeMeta>(maxEntries: 64)

    private var activeSession: StreamSessionDescriptor?
    private var boosterTask: Task<Void, Never>?
    private var inFlightChunks: [String: Task<Data?, Never>] = [:]
    private var preloadTasks: [String: Task<Void, Never>] = [:]

    private var currentPlayheadMs: Int64 = 0
    private var currentDurationMs: Int64 = 0
    private var currentOpEndMs: Int64 = 0
    private var lastSeekAtMs: Int64 = 0
    private var wakeupContinuation: AsyncStream<Void>.Continuation?

    public init(
        diskCache: DiskChunkCache,
        mirrorHealthTracker: MirrorHealthTracker = MirrorHealthTracker()
    ) {
        self.diskCache = diskCache
        self.mirrorHealthTracker = mirrorHealthTracker

        let videoConfig = URLSessionConfiguration.ephemeral
        videoConfig.timeoutIntervalForRequest = 10
        videoConfig.timeoutIntervalForResource = 30
        videoConfig.httpMaximumConnectionsPerHost = 12
        videoConfig.urlCache = nil
        self.videoSession = URLSession(configuration: videoConfig)

        let probeConfig = URLSessionConfiguration.ephemeral
        probeConfig.timeoutIntervalForRequest = 2.0
        probeConfig.timeoutIntervalForResource = 2.5
        probeConfig.httpMaximumConnectionsPerHost = 12
        probeConfig.urlCache = nil
        self.probeSession = URLSession(configuration: probeConfig)
    }

    public func cachedProbeMeta(for url: String) -> VideoProbeMeta? {
        probeMetaByUrl.get(url)
    }

    public func resolveCacheKey(episodeKey: String?, url: String) -> String {
        let len = probeMetaByUrl.get(url)?.contentLength ?? -1
        return DiskChunkCache.buildEpisodeCacheKey(episodeKey: episodeKey, contentLength: len, fallbackUrl: url)
    }

    public func resolveTotalLength(urls: [String]) -> Int64 {
        for url in urls {
            if let meta = probeMetaByUrl.get(url), meta.contentLength >= MirrorHealthTracker.minValidVideoBytes {
                return meta.contentLength
            }
        }
        return -1
    }

    /// Races mirror probes concurrently and returns as soon as the FIRST valid full-length
    /// (`>= 1 MB`) mirror responds (~80–150 ms), letting remaining mirrors finish in background.
    public func probeMirrorsForPlayback(urls: [String], maxWaitMs: Int64 = 900) async {
        let distinct = Array(NSOrderedSet(array: urls).compactMap { $0 as? String })
        guard !distinct.isEmpty else { return }

        let alreadyHaveValid = distinct.contains { url in
            guard let meta = probeMetaByUrl.get(url) else { return false }
            return meta.contentLength >= MirrorHealthTracker.minValidVideoBytes
        }

        let needsProbe = distinct.filter { url in
            probeMetaByUrl.get(url) == nil || !mirrorHealthTracker.hasFreshStats(url: url)
        }
        guard !needsProbe.isEmpty else { return }

        if alreadyHaveValid {
            for url in needsProbe {
                Task.detached(priority: .utility) { [weak self] in
                    _ = await self?.probeSingleMirror(url)
                }
            }
            return
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let state = ProbeRaceState(remaining: needsProbe.count, continuation: continuation)

            for url in needsProbe {
                Task.detached(priority: .userInitiated) { [weak self] in
                    let meta = await self?.probeSingleMirror(url)
                    if let meta, meta.contentLength >= MirrorHealthTracker.minValidVideoBytes {
                        state.finishNow()
                    } else {
                        state.decrementAndFinishIfZero()
                    }
                }
            }

            Task.detached(priority: .userInitiated) {
                try? await Task.sleep(for: .milliseconds(maxWaitMs))
                state.finishNow()
            }
        }
    }

    public func probeMirrorsSpeed(urls: [String]) async {
        let distinct = Array(NSOrderedSet(array: urls).compactMap { $0 as? String })
        let needsProbe = distinct.filter {
            probeMetaByUrl.get($0) == nil || !mirrorHealthTracker.hasFreshStats(url: $0)
        }
        guard !needsProbe.isEmpty else { return }

        await withTaskGroup(of: Void.self) { group in
            for url in needsProbe {
                group.addTask {
                    _ = await self.probeSingleMirror(url)
                }
            }
        }
    }

    @discardableResult
    public func probeSingleMirror(_ urlString: String) async -> VideoProbeMeta? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(AnimeHeavenClient.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("\(AnimeHeavenClient.baseURL)/", forHTTPHeaderField: "Referer")
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")

        let start = Date()
        do {
            let (_, response) = try await probeSession.data(for: request)
            let latencyMs = max(1, Int64(Date().timeIntervalSince(start) * 1000))
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 206 || http.statusCode == 200 else {
                mirrorHealthTracker.recordFailure(url: urlString)
                return nil
            }
            let totalLength = DiskChunkCache.parseTotalLengthFromHeaders(
                contentRange: http.value(forHTTPHeaderField: "Content-Range"),
                contentLength: http.value(forHTTPHeaderField: "Content-Length"),
                statusCode: http.statusCode
            )
            let supportsRanges = http.statusCode == 206 ||
                (http.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased().contains("bytes") == true)

            if totalLength > 0 && totalLength < MirrorHealthTracker.minValidVideoBytes {
                mirrorHealthTracker.recordStubVideo(url: urlString)
            } else {
                mirrorHealthTracker.recordSuccess(url: urlString, latencyMs: latencyMs)
            }

            let meta = VideoProbeMeta(
                url: urlString,
                contentLength: totalLength,
                supportsRanges: supportsRanges,
                latencyMs: latencyMs
            )
            probeMetaByUrl.set(urlString, value: meta)
            return meta
        } catch {
            mirrorHealthTracker.recordFailure(url: urlString)
            return nil
        }
    }

    // MARK: - Background Playback Booster

    public func startBoosting(
        session: StreamSessionDescriptor,
        resumePositionMs: Int64 = 0,
        estimatedDurationMs: Int64 = 0,
        opEndMs: Int64 = 0
    ) {
        stopBoosting()
        activeSession = session
        currentPlayheadMs = resumePositionMs
        currentDurationMs = estimatedDurationMs
        currentOpEndMs = opEndMs

        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        wakeupContinuation = continuation

        boosterTask = Task.detached(priority: .utility) { [weak self] in
            await self?.runBoosterLoop(session: session, wakeupStream: stream)
        }
        continuation.yield(())
    }

    public func updatePlayhead(positionMs: Int64, durationMs: Int64, opEndMs: Int64) {
        let delta = abs(positionMs - currentPlayheadMs)
        currentPlayheadMs = positionMs
        if durationMs > 0 { currentDurationMs = durationMs }
        if opEndMs > 0 { currentOpEndMs = opEndMs }
        if delta > 8_000 {
            lastSeekAtMs = Int64(Date().timeIntervalSince1970 * 1000)
            wakeupContinuation?.yield(())
        }
    }

    public func stopBoosting() {
        boosterTask?.cancel()
        boosterTask = nil
        wakeupContinuation?.finish()
        wakeupContinuation = nil
        activeSession = nil
    }

    public func preloadVideoHead(
        episodeKey: String,
        allSources: [String],
        bytesToCache: Int64 = defaultPreloadBytes,
        resumePositionMs: Int64 = 0,
        estimatedDurationMs: Int64 = 24 * 60_000,
        opEndMs: Int64 = 85_000
    ) {
        guard !episodeKey.isEmpty, !allSources.isEmpty, bytesToCache > 0 else { return }
        if preloadTasks[episodeKey] != nil { return }

        let task = Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            await self.probeMirrorsForPlayback(urls: allSources, maxWaitMs: 900)
            let ranked = self.mirrorHealthTracker.rankMirrors(allSources)
            let totalLength = await self.resolveTotalLength(urls: ranked)
            guard totalLength >= MirrorHealthTracker.minValidVideoBytes else {
                await self.clearPreloadHandle(episodeKey)
                return
            }
            let cacheKey = DiskChunkCache.buildEpisodeCacheKey(
                episodeKey: episodeKey,
                contentLength: totalLength,
                fallbackUrl: ranked[0]
            )
            let session = StreamSessionDescriptor(
                sessionId: "preload-\(episodeKey)",
                cacheKey: cacheKey,
                episodeKey: episodeKey,
                mirrors: ranked,
                totalLength: totalLength
            )
            let chunks = DiskChunkCache.buildInitialWindowChunks(
                totalLength: totalLength,
                targetBytes: bytesToCache,
                resumePositionMs: resumePositionMs,
                estimatedDurationMs: estimatedDurationMs,
                opEndMs: opEndMs
            )
            for offset in chunks {
                if Task.isCancelled { break }
                let data = await self.getOrFetchChunk(session: session, chunkOffset: offset)
                if offset == 0, let data, !DiskChunkCache.containsMoovBox(data) {
                    let tailStart = DiskChunkCache.alignChunkStart(max(0, totalLength - DiskChunkCache.chunkSizeBytes * 2))
                    _ = await self.getOrFetchChunk(session: session, chunkOffset: tailStart)
                }
            }
            await self.clearPreloadHandle(episodeKey)
        }
        preloadTasks[episodeKey] = task
    }

    public func cancelPreloadsExcept(_ keepEpisodeKey: String?) {
        for (key, task) in preloadTasks {
            if key != keepEpisodeKey {
                task.cancel()
                preloadTasks.removeValue(forKey: key)
            }
        }
    }

    private func clearPreloadHandle(_ key: String) {
        preloadTasks.removeValue(forKey: key)
    }

    /// Serves a 512 KB chunk from `DiskChunkCache` or fetches it across ranked healthy mirrors
    /// (coalescing concurrent requests for the exact same `(cacheKey, chunkOffset)`).
    public func getOrFetchChunk(session: StreamSessionDescriptor, chunkOffset: Int64) async -> Data? {
        guard chunkOffset >= 0 && chunkOffset < session.totalLength else { return nil }
        if let cached = await diskCache.readChunk(cacheKey: session.cacheKey, chunkOffset: chunkOffset) {
            return cached
        }

        let inFlightKey = "\(session.cacheKey)#\(chunkOffset)"
        if let existing = inFlightChunks[inFlightKey] {
            return await existing.value
        }

        let rankedMirrors = mirrorHealthTracker.rankMirrors(session.mirrors)
        let chunkEnd = min(session.totalLength - 1, chunkOffset + DiskChunkCache.chunkSizeBytes - 1)
        let task = Task.detached(priority: .userInitiated) { [videoSession, mirrorHealthTracker, diskCache] () -> Data? in
            for mirrorUrl in rankedMirrors {
                if Task.isCancelled { return nil }
                guard let url = URL(string: mirrorUrl) else { continue }
                var request = URLRequest(url: url)
                request.setValue(AnimeHeavenClient.userAgent, forHTTPHeaderField: "User-Agent")
                request.setValue("\(AnimeHeavenClient.baseURL)/", forHTTPHeaderField: "Referer")
                request.setValue("bytes=\(chunkOffset)-\(chunkEnd)", forHTTPHeaderField: "Range")

                let start = Date()
                do {
                    let (data, response) = try await videoSession.data(for: request)
                    guard let http = response as? HTTPURLResponse,
                          http.statusCode == 206 || (http.statusCode == 200 && chunkOffset == 0),
                          !data.isEmpty else {
                        mirrorHealthTracker.recordFailure(url: mirrorUrl)
                        continue
                    }
                    let elapsedMs = max(1, Int64(Date().timeIntervalSince(start) * 1000))
                    let slice = data.count > Int(chunkEnd - chunkOffset + 1)
                        ? data.prefix(Int(chunkEnd - chunkOffset + 1))
                        : data
                    let resultData = Data(slice)
                    mirrorHealthTracker.recordThroughput(
                        url: mirrorUrl,
                        bytesTransferred: Int64(resultData.count),
                        durationMs: elapsedMs
                    )
                    await diskCache.writeChunk(
                        cacheKey: session.cacheKey,
                        chunkOffset: chunkOffset,
                        data: resultData
                    )
                    return resultData
                } catch {
                    if !Task.isCancelled {
                        mirrorHealthTracker.recordFailure(url: mirrorUrl)
                    }
                }
            }
            return nil
        }

        inFlightChunks[inFlightKey] = task
        let result = await task.value
        inFlightChunks.removeValue(forKey: inFlightKey)
        return result
    }

    public func clearAll() async {
        stopBoosting()
        cancelPreloadsExcept(nil)
        probeMetaByUrl.clear()
        await diskCache.clearAll()
    }

    private func runBoosterLoop(
        session: StreamSessionDescriptor,
        wakeupStream: AsyncStream<Void>
    ) async {
        // Ensure chunk 0 + non-faststart MP4 tail moov are warmed immediately
        if let firstChunk = await getOrFetchChunk(session: session, chunkOffset: 0),
           !DiskChunkCache.containsMoovBox(firstChunk) {
            let tailOffset = DiskChunkCache.alignChunkStart(max(0, session.totalLength - DiskChunkCache.chunkSizeBytes * 2))
            _ = await getOrFetchChunk(session: session, chunkOffset: tailOffset)
        }

        while !Task.isCancelled {
            let anchorOffset = computeAnchorChunkOffset(totalLength: session.totalLength)
            var candidates: [Int64] = []
            for step in 0..<Self.aheadWindowChunks {
                let offset = anchorOffset + Int64(step) * DiskChunkCache.chunkSizeBytes
                if offset < session.totalLength {
                    if !(await diskCache.hasChunk(cacheKey: session.cacheKey, chunkOffset: offset)) {
                        candidates.append(offset)
                    }
                }
            }

            if candidates.isEmpty {
                try? await Task.sleep(for: .milliseconds(900))
                continue
            }

            // Fetch up to 2 chunks concurrently across mirrors
            let batch = Array(candidates.prefix(2))
            await withTaskGroup(of: Void.self) { group in
                for offset in batch {
                    group.addTask {
                        _ = await self.getOrFetchChunk(session: session, chunkOffset: offset)
                    }
                }
            }
        }
    }

    private func computeAnchorChunkOffset(totalLength: Int64) -> Int64 {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let recentlySeeked = (nowMs - lastSeekAtMs) < 3_500
        let est = DiskChunkCache.estimateByteOffset(
            positionMs: currentPlayheadMs,
            durationMs: currentDurationMs > 0 ? currentDurationMs : 24 * 60_000,
            totalLength: totalLength
        )
        let aligned = DiskChunkCache.alignChunkStart(est)
        return recentlySeeked ? aligned : max(0, aligned)
    }
}

private final class ProbeRaceState: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private var completed = false
    private let continuation: CheckedContinuation<Void, Never>

    init(remaining: Int, continuation: CheckedContinuation<Void, Never>) {
        self.remaining = remaining
        self.continuation = continuation
    }

    func finishNow() {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        lock.unlock()
        continuation.resume()
    }

    func decrementAndFinishIfZero() {
        lock.lock()
        remaining -= 1
        let shouldFinish = remaining <= 0 && !completed
        if shouldFinish { completed = true }
        lock.unlock()
        if shouldFinish {
            continuation.resume()
        }
    }
}
