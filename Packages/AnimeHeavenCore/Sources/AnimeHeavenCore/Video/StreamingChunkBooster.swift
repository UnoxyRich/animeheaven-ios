import Foundation

public struct StreamSessionDescriptor: Sendable {
    public let sessionId: String
    public let cacheKey: String
    public let episodeKey: String?
    public let mirrors: [String]
    public let totalLength: Int64
    public let preferExplicitOrder: Bool

    public init(
        sessionId: String,
        cacheKey: String,
        episodeKey: String?,
        mirrors: [String],
        totalLength: Int64,
        preferExplicitOrder: Bool = false
    ) {
        self.sessionId = sessionId
        self.cacheKey = cacheKey
        self.episodeKey = episodeKey
        self.mirrors = mirrors
        self.totalLength = totalLength
        self.preferExplicitOrder = preferExplicitOrder
    }
}

/// Multi-mirror parallel HTTP-Range chunk booster + MP4 `moov` seek indexer powering
/// `LocalStreamProxyServer`. Uses 4 parallel workers with a 32 MB sliding ahead buffer,
/// exact MP4 keyframe resume & post-OP targeting, and Tier-A hot-window protection.
public actor StreamingChunkBooster {
    public static let defaultPreloadBytes: Int64 = 4 * 1024 * 1024
    public static let minPlayableHotBytes: Int64 = 1536 * 1024
    private static let aheadWindowChunks: Int = 64 // 32 MB ahead
    private static let activePinAheadChunks: Int = 32 // 16 MB pinned ahead
    private static let fallbackTailMoovChunks: Int = 3
    private static let trailingDemoteBackBufferMs: Int64 = 180_000
    private static let trailingDemoteStepBytes: Int64 = 4 * 1024 * 1024

    public let diskCache: DiskChunkCache
    public let mirrorHealthTracker: MirrorHealthTracker
    private let videoSession: URLSession
    private let probeSession: URLSession
    private let probeMetaByUrl = LruCache<String, VideoProbeMeta>(maxEntries: 128)
    private let videoIndexByEpisode = LruCache<String, EpisodeVideoIndex>(maxEntries: 160)
    private var onVideoIndexReady: (@Sendable (EpisodeVideoIndex) async -> Void)?

    private var activeSession: StreamSessionDescriptor?
    private var boosterTask: Task<Void, Never>?
    private var inFlightChunks: [String: Task<Data?, Never>] = [:]
    private var preloadTasks: [String: Task<Void, Never>] = [:]

    private var currentPlayheadMs: Int64 = 0
    private var currentDurationMs: Int64 = 0
    private var currentOpEndMs: Int64 = 0
    private var lastDemotedTrailingByte: Int64 = 0
    private var seekRevision: UInt64 = 0
    private var retrySleep: Task<Void, Never>?

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

    public func setVideoIndexPersistence(_ handler: @escaping @Sendable (EpisodeVideoIndex) async -> Void) {
        onVideoIndexReady = handler
    }

    public func hydrateVideoIndices(_ indices: [EpisodeVideoIndex]) async {
        for idx in indices where !idx.episodeKey.isEmpty && idx.contentLength >= MirrorHealthTracker.minValidVideoBytes {
            videoIndexByEpisode.set(idx.episodeKey, value: idx)
            await diskCache.recordEpisodeLength(episodeKey: idx.episodeKey, contentLength: idx.contentLength)
            let key = DiskChunkCache.buildEpisodeCacheKey(episodeKey: idx.episodeKey, contentLength: idx.contentLength, fallbackUrl: "")
            var pinOffsets: [Int64] = [0]
            if idx.moovOffset >= 0 && idx.moovSize > 0 {
                var c = DiskChunkCache.alignChunkStart(idx.moovOffset)
                let end = min(idx.contentLength, idx.moovOffset + idx.moovSize)
                while c < end {
                    pinOffsets.append(c)
                    c += DiskChunkCache.chunkSizeBytes
                }
            }
            await diskCache.markHotWindow(cacheKey: key, offsets: pinOffsets)
        }
    }

    public func videoIndex(for episodeKey: String?) -> EpisodeVideoIndex? {
        guard let episodeKey, !episodeKey.isEmpty else { return nil }
        return videoIndexByEpisode.get(episodeKey)
    }

    public func cachedProbeMeta(for url: String) -> VideoProbeMeta? {
        probeMetaByUrl.get(url)
    }

    public func resolveKnownContentLength(episodeKey: String?, url: String? = nil) async -> Int64 {
        if let url, let meta = probeMetaByUrl.get(url), meta.contentLength >= MirrorHealthTracker.minValidVideoBytes {
            return meta.contentLength
        }
        if let episodeKey, !episodeKey.isEmpty {
            if let idx = videoIndexByEpisode.get(episodeKey), idx.contentLength >= MirrorHealthTracker.minValidVideoBytes {
                return idx.contentLength
            }
            let diskLen = await diskCache.knownContentLength(episodeKey: episodeKey)
            if diskLen >= MirrorHealthTracker.minValidVideoBytes {
                return diskLen
            }
        }
        return -1
    }

    public func resolveCacheKey(episodeKey: String?, url: String) async -> String {
        let len = await resolveKnownContentLength(episodeKey: episodeKey, url: url)
        return DiskChunkCache.buildEpisodeCacheKey(episodeKey: episodeKey, contentLength: len, fallbackUrl: url)
    }

    public func resolveTotalLength(urls: [String], episodeKey: String? = nil) async -> Int64 {
        for url in urls {
            if let meta = probeMetaByUrl.get(url), meta.contentLength >= MirrorHealthTracker.minValidVideoBytes {
                return meta.contentLength
            }
        }
        return await resolveKnownContentLength(episodeKey: episodeKey)
    }

    public func hasPlayableHotWindow(
        episodeKey: String?,
        cacheKey: String,
        resumePositionMs: Int64,
        estimatedDurationMs: Int64 = 0,
        minBytes: Int64 = minPlayableHotBytes
    ) async -> Bool {
        let totalLen = await resolveKnownContentLength(episodeKey: episodeKey)
        guard totalLen >= MirrorHealthTracker.minValidVideoBytes else { return false }
        guard await diskCache.hasChunk(cacheKey: cacheKey, chunkOffset: 0) else { return false }

        let idx = videoIndex(for: episodeKey)
        if let idx, idx.isMoovAtTail, idx.moovSize > 0 {
            let moovLen = min(idx.moovSize, totalLen - idx.moovOffset)
            let cachedMoov = await diskCache.cachedBytesInWindow(
                cacheKey: cacheKey,
                startOffset: idx.moovOffset,
                windowBytes: moovLen,
                totalLength: totalLen
            )
            if cachedMoov < moovLen { return false }
        }

        let effectiveDur = (idx?.durationMs ?? 0) > 0 ? (idx?.durationMs ?? 0) : estimatedDurationMs
        let targetStart: Int64
        if resumePositionMs > 10_000 && effectiveDur > 0 {
            targetStart = DiskChunkCache.alignChunkStart(
                DiskChunkCache.resolveByteOffset(
                    videoIndex: idx,
                    positionMs: resumePositionMs,
                    durationMs: effectiveDur,
                    totalLength: totalLen
                )
            )
        } else {
            targetStart = 0
        }

        let windowLen = min(minBytes, max(0, totalLen - targetStart))
        guard windowLen > 0 else { return false }
        let cached = await diskCache.cachedBytesInWindow(
            cacheKey: cacheKey,
            startOffset: targetStart,
            windowBytes: windowLen,
            totalLength: totalLen
        )
        return cached >= (windowLen * 3) / 4
    }

    public func probeMirrorsInBackground(urls: [String]) {
        let distinct = Array(NSOrderedSet(array: urls).compactMap { $0 as? String })
        let needsProbe = distinct.filter {
            probeMetaByUrl.get($0) == nil || !mirrorHealthTracker.hasFreshStats(url: $0)
        }
        guard !needsProbe.isEmpty else { return }
        for url in needsProbe {
            Task.detached(priority: .utility) { [weak self] in
                _ = await self?.probeSingleMirror(url)
            }
        }
    }

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
            probeMirrorsInBackground(urls: needsProbe)
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
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        let start = Date()
        do {
            let (bytes, response) = try await probeSession.bytes(for: request)
            defer { bytes.task.cancel() }
            let latencyMs = max(1, Int64(Date().timeIntervalSince(start) * 1000))
            guard let http = response as? HTTPURLResponse,
                  let totalLength = Self.validatedRangeLength(http, start: 0, end: 0) else {
                mirrorHealthTracker.recordFailure(url: urlString)
                return nil
            }
            let supportsRanges = http.statusCode == 206

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
            if !Task.isCancelled { mirrorHealthTracker.recordFailure(url: urlString) }
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
        currentPlayheadMs = max(0, resumePositionMs)
        let idxDur = videoIndex(for: session.episodeKey)?.durationMs ?? 0
        currentDurationMs = estimatedDurationMs > 0 ? estimatedDurationMs : idxDur
        currentOpEndMs = max(0, opEndMs)
        lastDemotedTrailingByte = 0

        boosterTask = Task.detached(priority: .utility) { [weak self] in
            await self?.runBoosterLoop(session: session)
        }
    }

    public func updatePlayhead(positionMs: Int64, durationMs: Int64, opEndMs: Int64) {
        let clamped = max(0, positionMs)
        let delta = abs(clamped - currentPlayheadMs)
        currentPlayheadMs = clamped
        if durationMs > 0 { currentDurationMs = durationMs }
        if opEndMs > 0 { currentOpEndMs = opEndMs }
        if delta > 4_000 {
            seekRevision &+= 1
            retrySleep?.cancel()
        }

        if let session = activeSession, clamped > Self.trailingDemoteBackBufferMs, currentDurationMs > 0 {
            let behindMs = clamped - Self.trailingDemoteBackBufferMs
            let idx = videoIndex(for: session.episodeKey)
            let behindByte = DiskChunkCache.resolveByteOffset(
                videoIndex: idx,
                positionMs: behindMs,
                durationMs: currentDurationMs,
                totalLength: session.totalLength
            )
            if behindByte > DiskChunkCache.chunkSizeBytes * 2,
               behindByte - lastDemotedTrailingByte >= Self.trailingDemoteStepBytes {
                lastDemotedTrailingByte = behindByte
                let aligned = DiskChunkCache.alignChunkStart(behindByte)
                let cacheKey = session.cacheKey
                Task.detached(priority: .background) { [diskCache] in
                    await diskCache.demoteTrailingChunks(cacheKey: cacheKey, behindOffset: aligned)
                }
            }
        }
    }

    public func stopBoosting() {
        boosterTask?.cancel()
        boosterTask = nil
        retrySleep?.cancel()
        retrySleep = nil
        activeSession = nil
    }

    public func stopBoosting(sessionId: String) {
        if activeSession?.sessionId == sessionId { stopBoosting() }
    }

    public func markEpisodeCompleted(episodeKey: String?, cacheKey: String?) async {
        if let cacheKey, !cacheKey.isEmpty {
            await diskCache.unpinKey(cacheKey: cacheKey)
        }
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

        let task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            _ = await self.runPreloadVideoHead(
                episodeKey: episodeKey,
                allSources: allSources,
                bytesToCache: bytesToCache,
                resumePositionMs: resumePositionMs,
                estimatedDurationMs: estimatedDurationMs,
                opEndMs: opEndMs
            )
            await self.clearPreloadHandle(episodeKey)
        }
        preloadTasks[episodeKey] = task
    }

    /// Runs parallel multi-mirror head + `moov` + resume/OP warming and returns the resolved
    /// `cacheKey` if playable bytes are now committed to `DiskChunkCache`.
    public func preloadVideoHeadAndAwait(
        episodeKey: String,
        allSources: [String],
        bytesToCache: Int64 = defaultPreloadBytes,
        resumePositionMs: Int64 = 0,
        estimatedDurationMs: Int64 = 24 * 60_000,
        opEndMs: Int64 = 85_000
    ) async -> String? {
        guard !episodeKey.isEmpty, !allSources.isEmpty, bytesToCache > 0 else { return nil }
        if let existing = preloadTasks[episodeKey] {
            await existing.value
        }
        let task = Task.detached(priority: .utility) { [weak self] () -> String? in
            guard let self else { return nil }
            let key = await self.runPreloadVideoHead(
                episodeKey: episodeKey,
                allSources: allSources,
                bytesToCache: bytesToCache,
                resumePositionMs: resumePositionMs,
                estimatedDurationMs: estimatedDurationMs,
                opEndMs: opEndMs
            )
            await self.clearPreloadHandle(episodeKey)
            return key
        }
        preloadTasks[episodeKey] = Task { _ = await task.value }
        return await task.value
    }

    private func runPreloadVideoHead(
        episodeKey: String,
        allSources: [String],
        bytesToCache: Int64,
        resumePositionMs: Int64,
        estimatedDurationMs: Int64,
        opEndMs: Int64
    ) async -> String? {
        var totalLength = await resolveTotalLength(urls: allSources, episodeKey: episodeKey)
        if totalLength < MirrorHealthTracker.minValidVideoBytes {
            await probeMirrorsForPlayback(urls: allSources, maxWaitMs: 900)
            totalLength = await resolveTotalLength(urls: allSources, episodeKey: episodeKey)
        }
        guard totalLength >= MirrorHealthTracker.minValidVideoBytes else { return nil }
        let ranked = mirrorHealthTracker.rankMirrors(allSources)
        guard let primaryUrl = ranked.first else { return nil }

        await diskCache.recordEpisodeLength(episodeKey: episodeKey, contentLength: totalLength)
        let cacheKey = DiskChunkCache.buildEpisodeCacheKey(
            episodeKey: episodeKey,
            contentLength: totalLength,
            fallbackUrl: primaryUrl
        )
        let session = StreamSessionDescriptor(
            sessionId: "preload-\(episodeKey)",
            cacheKey: cacheKey,
            episodeKey: episodeKey,
            mirrors: ranked,
            totalLength: totalLength
        )

        // Step 1: Fetch chunk 0 & locate MP4 moov atom (head or multi-chunk tail)
        let chunk0 = await getOrFetchChunk(session: session, chunkOffset: 0)
        await diskCache.markHotWindow(cacheKey: cacheKey, offsets: [0])
        if Task.isCancelled { return nil }

        var resolvedIndex = videoIndexByEpisode.get(episodeKey)
        let moovLoc = chunk0.flatMap { Mp4MoovSeekParser.inspectTopLevelBoxes(headData: $0, totalLength: totalLength) }

        var moovOffsets: [Int64] = []
        if let moovLoc, moovLoc.size >= 16 && moovLoc.size <= Mp4MoovSeekParser.maxMoovParseBytes {
            var c = DiskChunkCache.alignChunkStart(moovLoc.offset)
            let end = min(totalLength, moovLoc.offset + moovLoc.size)
            while c < end {
                moovOffsets.append(c)
                c += DiskChunkCache.chunkSizeBytes
            }
        } else if let chunk0, !DiskChunkCache.containsMoovBox(chunk0) {
            let tailStart = DiskChunkCache.alignChunkStart(max(0, totalLength - 1))
            for step in 0..<Self.fallbackTailMoovChunks {
                let c = tailStart - Int64(step) * DiskChunkCache.chunkSizeBytes
                if c > 0 { moovOffsets.append(c) }
            }
        }

        if !moovOffsets.isEmpty {
            await diskCache.markHotWindow(cacheKey: cacheKey, offsets: moovOffsets)
            await fetchOffsetsParallel(session: session, offsets: moovOffsets, maxConcurrency: 3)
        }

        if resolvedIndex == nil || resolvedIndex?.seekPoints.isEmpty == true {
            if let moovLoc, moovLoc.size >= 16 && moovLoc.size <= Mp4MoovSeekParser.maxMoovParseBytes,
               let moovData = await diskCache.readRange(cacheKey: cacheKey, startOffset: moovLoc.offset, length: Int(moovLoc.size)),
               let parsed = Mp4MoovSeekParser.parseMoovIndex(
                episodeKey: episodeKey,
                contentLength: totalLength,
                moovFileOffset: moovLoc.offset,
                data: moovData,
                dataBaseFileOffset: moovLoc.offset
               ) {
                resolvedIndex = parsed
                videoIndexByEpisode.set(episodeKey, value: parsed)
                if let persist = onVideoIndexReady { await persist(parsed) }
            } else if resolvedIndex == nil {
                let basic = EpisodeVideoIndex(
                    episodeKey: episodeKey,
                    contentLength: totalLength,
                    durationMs: max(0, estimatedDurationMs),
                    updatedAtMs: Int64(Date().timeIntervalSince1970 * 1000)
                )
                resolvedIndex = basic
                videoIndexByEpisode.set(episodeKey, value: basic)
                if let persist = onVideoIndexReady { await persist(basic) }
            }
        }

        let effectiveDur = (resolvedIndex?.durationMs ?? 0) > 0 ? (resolvedIndex?.durationMs ?? 0) : estimatedDurationMs
        let chunks = DiskChunkCache.buildInitialWindowChunks(
            totalLength: totalLength,
            targetBytes: bytesToCache,
            resumePositionMs: resumePositionMs,
            estimatedDurationMs: effectiveDur,
            opEndMs: opEndMs,
            videoIndex: resolvedIndex
        )
        await diskCache.markHotWindow(cacheKey: cacheKey, offsets: chunks)
        await fetchOffsetsParallel(session: session, offsets: chunks, maxConcurrency: 4)

        let ready = await hasPlayableHotWindow(
            episodeKey: episodeKey,
            cacheKey: cacheKey,
            resumePositionMs: resumePositionMs,
            estimatedDurationMs: effectiveDur
        )
        return ready ? cacheKey : nil
    }

    private func fetchOffsetsParallel(session: StreamSessionDescriptor, offsets: [Int64], maxConcurrency: Int) async {
        var missing: [Int64] = []
        var seen = Set<Int64>()
        for offset in offsets {
            guard seen.insert(offset).inserted else { continue }
            if !(await diskCache.hasChunk(cacheKey: session.cacheKey, chunkOffset: offset)) {
                missing.append(offset)
            }
        }
        guard !missing.isEmpty else { return }

        let workerCap = max(1, min(maxConcurrency, missing.count))
        await withTaskGroup(of: Void.self) { group in
            var idx = 0
            for _ in 0..<workerCap {
                let offset = missing[idx]
                idx += 1
                group.addTask {
                    _ = await self.getOrFetchChunk(session: session, chunkOffset: offset)
                }
            }
            while await group.next() != nil {
                if Task.isCancelled || idx >= missing.count { continue }
                let nextOffset = missing[idx]
                idx += 1
                group.addTask {
                    _ = await self.getOrFetchChunk(session: session, chunkOffset: nextOffset)
                }
            }
        }
    }

    public func cancelPreloadsExcept(_ keepEpisodeKey: String?) {
        let keepSet: Set<String> = keepEpisodeKey.map { [$0] } ?? []
        cancelPreloadsExcept(keepSet)
    }

    public func cancelPreloadsExcept(_ keepKeys: Set<String>) {
        for (key, task) in preloadTasks {
            if !keepKeys.contains(key) {
                task.cancel()
                preloadTasks.removeValue(forKey: key)
            }
        }
    }

    private func clearPreloadHandle(_ key: String) {
        preloadTasks.removeValue(forKey: key)
    }

    public func getOrFetchChunk(session: StreamSessionDescriptor, chunkOffset: Int64) async -> Data? {
        guard chunkOffset >= 0 && chunkOffset < session.totalLength else { return nil }
        if let cached = await diskCache.readChunk(cacheKey: session.cacheKey, chunkOffset: chunkOffset) {
            return cached
        }

        let inFlightKey = "\(session.cacheKey)#\(chunkOffset)"
        if let existing = inFlightChunks[inFlightKey] {
            return await existing.value
        }

        let compatible = session.mirrors.filter { url in
            probeMetaByUrl.get(url).map { $0.contentLength == session.totalLength } ?? true
        }
        let rankedMirrors = session.preferExplicitOrder ? compatible : mirrorHealthTracker.rankMirrors(compatible)
        let chunkEnd = min(session.totalLength - 1, chunkOffset + DiskChunkCache.chunkSizeBytes - 1)
        let task = Task.detached(priority: .userInitiated) { [videoSession, mirrorHealthTracker, diskCache] () -> Data? in
            for mirrorUrl in rankedMirrors {
                if Task.isCancelled { return nil }
                guard let url = URL(string: mirrorUrl) else { continue }
                var request = URLRequest(url: url)
                request.setValue(AnimeHeavenClient.userAgent, forHTTPHeaderField: "User-Agent")
                request.setValue("\(AnimeHeavenClient.baseURL)/", forHTTPHeaderField: "Referer")
                request.setValue("bytes=\(chunkOffset)-\(chunkEnd)", forHTTPHeaderField: "Range")
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

                let start = Date()
                do {
                    let (bytes, response) = try await videoSession.bytes(for: request)
                    defer { bytes.task.cancel() }
                    guard let http = response as? HTTPURLResponse,
                          Self.validatedRangeLength(http, start: chunkOffset, end: chunkEnd) == session.totalLength else {
                        mirrorHealthTracker.recordFailure(url: mirrorUrl)
                        continue
                    }
                    let expected = Int(chunkEnd - chunkOffset + 1)
                    var resultData = Data()
                    resultData.reserveCapacity(expected)
                    for try await byte in bytes {
                        resultData.append(byte)
                        if resultData.count == expected { break }
                    }
                    bytes.task.cancel()
                    try Task.checkCancellation()
                    guard resultData.count == expected else {
                        mirrorHealthTracker.recordFailure(url: mirrorUrl)
                        continue
                    }
                    let elapsedMs = max(1, Int64(Date().timeIntervalSince(start) * 1000))
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
        cancelPreloadsExcept(Set<String>())
        let active = Array(inFlightChunks.values)
        for task in active { task.cancel() }
        for task in active { _ = await task.value }
        probeMetaByUrl.clear()
        videoIndexByEpisode.clear()
        await diskCache.clearAll()
    }

    static func validatedRangeLength(_ response: HTTPURLResponse, start: Int64, end: Int64) -> Int64? {
        let type = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        let encoding = response.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
        guard !type.hasPrefix("text/"), !type.contains("html"), !type.contains("json"),
              encoding == nil || encoding == "identity" else { return nil }
        let range = response.value(forHTTPHeaderField: "Content-Range")
        if response.statusCode == 200, start == 0, range == nil,
           let rawLength = response.value(forHTTPHeaderField: "Content-Length"),
           let length = Int64(rawLength), length > end { return length }
        guard response.statusCode == 206,
              let range, range.lowercased().hasPrefix("bytes ") else { return nil }
        let fields = range.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
        guard fields.count == 2, let total = Int64(fields[1]), total > end else { return nil }
        let bounds = fields[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, Int64(bounds[0]) == start, Int64(bounds[1]) == end else { return nil }
        return total
    }

    private func runBoosterLoop(session: StreamSessionDescriptor) async {
        // Ensure chunk 0 + non-faststart MP4 tail moov are warmed immediately
        if let firstChunk = await getOrFetchChunk(session: session, chunkOffset: 0) {
            if let loc = Mp4MoovSeekParser.inspectTopLevelBoxes(headData: firstChunk, totalLength: session.totalLength),
               loc.size >= 16 && loc.size <= Mp4MoovSeekParser.maxMoovParseBytes {
                var moovOffsets: [Int64] = []
                var c = DiskChunkCache.alignChunkStart(loc.offset)
                let end = min(session.totalLength, loc.offset + loc.size)
                while c < end {
                    moovOffsets.append(c)
                    c += DiskChunkCache.chunkSizeBytes
                }
                await fetchOffsetsParallel(session: session, offsets: moovOffsets, maxConcurrency: 3)
            } else if !DiskChunkCache.containsMoovBox(firstChunk) {
                let tailStart = DiskChunkCache.alignChunkStart(max(0, session.totalLength - 1))
                var tailOffsets: [Int64] = []
                for step in 0..<Self.fallbackTailMoovChunks {
                    let c = tailStart - Int64(step) * DiskChunkCache.chunkSizeBytes
                    if c > 0 { tailOffsets.append(c) }
                }
                await fetchOffsetsParallel(session: session, offsets: tailOffsets, maxConcurrency: 3)
            }
        }

        var backoffMs = 450
        while !Task.isCancelled && activeSession?.sessionId == session.sessionId {
            let before = seekRevision
            let idx = videoIndex(for: session.episodeKey)
            let effectiveDur = currentDurationMs > 0 ? currentDurationMs : ((idx?.durationMs ?? 0) > 0 ? (idx?.durationMs ?? 0) : 24 * 60_000)

            var candidates: [Int64] = []
            // 1. Prioritize post-OP skip landing zone (1.5 MB) while playhead is before OP end
            if currentOpEndMs > currentPlayheadMs + 4_000 && effectiveDur > 0 {
                let opByte = DiskChunkCache.resolveByteOffset(
                    videoIndex: idx,
                    positionMs: currentOpEndMs,
                    durationMs: effectiveDur,
                    totalLength: session.totalLength
                )
                let opStart = DiskChunkCache.alignChunkStart(opByte)
                for step in 0..<3 {
                    let offset = opStart + Int64(step) * DiskChunkCache.chunkSizeBytes
                    if offset < session.totalLength,
                       !(await diskCache.hasChunk(cacheKey: session.cacheKey, chunkOffset: offset)) {
                        candidates.append(offset)
                    }
                }
            }

            // 2. 32 MB sliding ahead window right from the current playhead frontier
            let anchorOffset = computeAnchorChunkOffset(totalLength: session.totalLength, videoIndex: idx, durationMs: effectiveDur)
            var pinOffsets: [Int64] = []
            for step in 0..<Self.aheadWindowChunks {
                let offset = anchorOffset + Int64(step) * DiskChunkCache.chunkSizeBytes
                if offset < session.totalLength {
                    if step < Self.activePinAheadChunks { pinOffsets.append(offset) }
                    if !(await diskCache.hasChunk(cacheKey: session.cacheKey, chunkOffset: offset)) {
                        candidates.append(offset)
                    }
                }
            }
            if !pinOffsets.isEmpty {
                await diskCache.markHotWindow(cacheKey: session.cacheKey, offsets: pinOffsets)
            }

            if candidates.isEmpty {
                await waitForRetry(ms: 800, revision: before, sessionId: session.sessionId)
                continue
            }

            // Fetch up to 4 chunks concurrently across ranked mirrors
            let batch = Array(candidates.prefix(4))
            let fetched = await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
                for offset in batch {
                    group.addTask {
                        await self.getOrFetchChunk(session: session, chunkOffset: offset) != nil
                    }
                }
                var anySuccess = false
                for await success in group { anySuccess = anySuccess || success }
                return anySuccess
            }
            if fetched || before != seekRevision {
                backoffMs = 450
            } else {
                await waitForRetry(ms: backoffMs, revision: before, sessionId: session.sessionId)
                backoffMs = min(10_000, backoffMs * 2)
            }
        }
    }

    private func waitForRetry(ms: Int, revision: UInt64, sessionId: String) async {
        guard !Task.isCancelled, revision == seekRevision, activeSession?.sessionId == sessionId else { return }
        let sleep = Task { try? await Task.sleep(for: .milliseconds(ms)); return () }
        retrySleep = sleep
        await sleep.value
        if activeSession?.sessionId == sessionId { retrySleep = nil }
    }

    private func computeAnchorChunkOffset(totalLength: Int64, videoIndex: EpisodeVideoIndex?, durationMs: Int64) -> Int64 {
        let est = DiskChunkCache.resolveByteOffset(
            videoIndex: videoIndex,
            positionMs: currentPlayheadMs,
            durationMs: durationMs,
            totalLength: totalLength
        )
        return DiskChunkCache.alignChunkStart(est)
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
