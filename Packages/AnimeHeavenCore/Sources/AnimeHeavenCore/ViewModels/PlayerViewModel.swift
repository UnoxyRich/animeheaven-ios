import Foundation
import Observation

public struct PreparedNextEpisode: Sendable {
    public let episodeKey: String
    public let stream: EpisodeStream
    public let rankedMirrors: [String]
    public let cacheKey: String
    public let sessionId: String
    public let descriptor: StreamSessionDescriptor
    public let localURL: URL
    public let skipTimes: EpisodeSkipTimes
    public let durationMs: Int64

    public init(
        episodeKey: String,
        stream: EpisodeStream,
        rankedMirrors: [String],
        cacheKey: String,
        sessionId: String,
        descriptor: StreamSessionDescriptor,
        localURL: URL,
        skipTimes: EpisodeSkipTimes,
        durationMs: Int64
    ) {
        self.episodeKey = episodeKey
        self.stream = stream
        self.rankedMirrors = rankedMirrors
        self.cacheKey = cacheKey
        self.sessionId = sessionId
        self.descriptor = descriptor
        self.localURL = localURL
        self.skipTimes = skipTimes
        self.durationMs = durationMs
    }
}

@MainActor
@Observable
public final class PlayerViewModel {
    public private(set) var isLoading: Bool = true
    public private(set) var isDiskCacheWarm: Bool = false
    public private(set) var errorMessage: String?
    public private(set) var stream: EpisodeStream?
    public private(set) var mirrorState: MirrorQueueState = MirrorQueueState(sources: [])
    public private(set) var playbackURL: URL?
    public private(set) var usesProxyStream: Bool = false
    public private(set) var initialResumePositionMs: Int64 = 0
    public private(set) var initialDurationMs: Int64 = 0
    public private(set) var animeId: String
    public private(set) var animeTitle: String
    public private(set) var coverUrl: String
    public private(set) var skipTimes: EpisodeSkipTimes = EpisodeSkipTimes()
    public private(set) var skipTimesResolved: Bool = false
    public private(set) var preparedNextEpisode: PreparedNextEpisode? = nil

    @ObservationIgnored
    public let settingsStore: SettingsStore
    @ObservationIgnored
    private let repository: AnimeHeavenRepository
    @ObservationIgnored
    private let skipTimesClient: SkipTimesClient
    @ObservationIgnored
    private let chunkBooster: StreamingChunkBooster
    @ObservationIgnored
    private let proxyServer: LocalStreamProxyServer
    @ObservationIgnored
    private let networkPolicy: NetworkPolicy
    @ObservationIgnored
    private let preloader: AnimePreloader?

    @ObservationIgnored
    private var loadTask: Task<Void, Never>?
    @ObservationIgnored
    private var skipTask: Task<Void, Never>?
    @ObservationIgnored
    private var nextPreloadTask: Task<Void, Never>?
    @ObservationIgnored
    private var activeProxySessionId: String?
    @ObservationIgnored
    private var activeCacheKey: String?
    @ObservationIgnored
    private var attemptedFreshGate: Bool = false
    @ObservationIgnored
    private var hasRecordedStartForAttempt: Bool = false
    @ObservationIgnored
    private var mirrorAttemptStartedAtMs: Int64 = 0
    @ObservationIgnored
    private var hasPreloadedNextForEpisode: Bool = false
    @ObservationIgnored
    private var hasEscalatedNextEpisode: Bool = false
    @ObservationIgnored
    private var isUserPriorityActive: Bool = false

    public init(
        animeId: String,
        animeTitle: String,
        coverUrl: String,
        repository: AnimeHeavenRepository,
        settingsStore: SettingsStore,
        skipTimesClient: SkipTimesClient,
        chunkBooster: StreamingChunkBooster,
        proxyServer: LocalStreamProxyServer,
        networkPolicy: NetworkPolicy,
        preloader: AnimePreloader? = nil
    ) {
        self.animeId = animeId
        self.animeTitle = animeTitle
        self.coverUrl = coverUrl
        self.repository = repository
        self.settingsStore = settingsStore
        self.skipTimesClient = skipTimesClient
        self.chunkBooster = chunkBooster
        self.proxyServer = proxyServer
        self.networkPolicy = networkPolicy
        self.preloader = preloader
    }

    public func loadEpisode(episodeKey: String, forceRefreshGate: Bool = false, resumeOverrideMs: Int64? = nil) {
        loadTask?.cancel()
        skipTask?.cancel()
        nextPreloadTask?.cancel()
        nextPreloadTask = nil
        isLoading = true
        isDiskCacheWarm = false
        errorMessage = nil
        playbackURL = nil
        initialDurationMs = 0
        skipTimes = EpisodeSkipTimes()
        skipTimesResolved = false
        attemptedFreshGate = forceRefreshGate
        hasRecordedStartForAttempt = false
        hasPreloadedNextForEpisode = false
        hasEscalatedNextEpisode = false

        loadTask = Task { [weak self] in
            guard let self else { return }
            await self.setUserPriority(true)
            await self.teardownActiveSession()
            await self.teardownPreparedNextSession()
            await self.chunkBooster.cancelPreloadsExcept(episodeKey)

            do {
                try Task.checkCancellation()
                async let savedProgressTask = self.repository.getSavedProgress(episodeKey: episodeKey)

                // Fast path: if stream + playable hot window are already warm on disk, bind localhost proxy immediately
                // with ZERO network blocking, then probe mirrors / refresh stale gate asynchronously.
                if !forceRefreshGate,
                   let cachedStream = await self.repository.peekCachedStream(episodeKey: episodeKey),
                   !cachedStream.videoSources.isEmpty {
                    let saved = await savedProgressTask
                    let savedResume = saved.map {
                        WatchProgressLogic.resolveResumePositionMs(positionMs: $0.positionMs, durationMs: $0.durationMs)
                    } ?? 0
                    let resumeMs = resumeOverrideMs ?? savedResume
                    let idxDur = await self.chunkBooster.videoIndex(for: episodeKey)?.durationMs ?? 0
                    let knownDur = idxDur > 0 ? idxDur : (saved?.durationMs ?? 0)
                    let ranked = self.chunkBooster.mirrorHealthTracker.rankMirrors(cachedStream.videoSources)
                    if let primary = ranked.first {
                        let totalLen = await self.chunkBooster.resolveTotalLength(urls: ranked, episodeKey: episodeKey)
                        let cacheKey = DiskChunkCache.buildEpisodeCacheKey(
                            episodeKey: episodeKey,
                            contentLength: totalLen,
                            fallbackUrl: primary
                        )
                        var warmOnDisk = false
                        if totalLen >= MirrorHealthTracker.minValidVideoBytes {
                            warmOnDisk = await self.chunkBooster.hasPlayableHotWindow(
                                episodeKey: episodeKey,
                                cacheKey: cacheKey,
                                resumePositionMs: resumeMs,
                                estimatedDurationMs: knownDur
                            )
                        }
                        if warmOnDisk {
                            try Task.checkCancellation()
                            self.stream = cachedStream
                            self.initialResumePositionMs = resumeMs
                            self.initialDurationMs = knownDur
                            self.isDiskCacheWarm = true
                            if let resolvedId = cachedStream.animeId, !resolvedId.isEmpty {
                                self.animeId = resolvedId
                            }
                            if !cachedStream.animeTitle.isEmpty {
                                self.animeTitle = cachedStream.animeTitle
                            }
                            self.fetchSkipTimesAsync(title: self.animeTitle, episodeLabel: cachedStream.episodeLabel)
                            self.mirrorState = MirrorQueueState(sources: ranked, activeIndex: 0, exhausted: false)
                            try await self.bindPlaybackURL(
                                for: ranked,
                                episodeKey: episodeKey,
                                resumeMs: resumeMs,
                                estimatedDurationMs: knownDur
                            )
                            try Task.checkCancellation()
                            self.isLoading = false
                            await self.chunkBooster.probeMirrorsInBackground(urls: cachedStream.videoSources)
                            if await self.repository.isCachedStreamStale(episodeKey: episodeKey) {
                                let aId = self.animeId.isEmpty ? nil : self.animeId
                                Task.detached(priority: .utility) { [repository = self.repository] in
                                    _ = try? await repository.resolveEpisodeStream(
                                        episodeKey: episodeKey,
                                        animeId: aId,
                                        forceRefresh: true
                                    )
                                }
                            }
                            return
                        }
                    }
                }

                let resolved = try await self.repository.resolveEpisodeStream(
                    episodeKey: episodeKey,
                    animeId: self.animeId.isEmpty ? nil : self.animeId,
                    forceRefresh: forceRefreshGate
                )
                if Task.isCancelled { return }

                let saved = await savedProgressTask
                let savedResumeMs = saved.map {
                    WatchProgressLogic.resolveResumePositionMs(positionMs: $0.positionMs, durationMs: $0.durationMs)
                } ?? 0
                let resumeMs = resumeOverrideMs ?? savedResumeMs
                let idxDur = await self.chunkBooster.videoIndex(for: episodeKey)?.durationMs ?? 0
                let knownDur = idxDur > 0 ? idxDur : (saved?.durationMs ?? 0)
                try Task.checkCancellation()
                self.stream = resolved
                self.initialResumePositionMs = resumeMs
                self.initialDurationMs = knownDur
                if let resolvedId = resolved.animeId, !resolvedId.isEmpty {
                    self.animeId = resolvedId
                }
                if !resolved.animeTitle.isEmpty {
                    self.animeTitle = resolved.animeTitle
                }

                guard !resolved.videoSources.isEmpty else {
                    self.isLoading = false
                    self.errorMessage = "No playable video mirrors found for this episode."
                    await self.setUserPriority(false)
                    return
                }

                // Launch AniSkip lookup concurrently without blocking video startup
                self.fetchSkipTimesAsync(title: self.animeTitle, episodeLabel: resolved.episodeLabel)

                let preRanked = self.chunkBooster.mirrorHealthTracker.rankMirrors(resolved.videoSources)
                var warmOnDisk = false
                if let primary = preRanked.first {
                    let knownLen = await self.chunkBooster.resolveTotalLength(urls: preRanked, episodeKey: episodeKey)
                    if knownLen >= MirrorHealthTracker.minValidVideoBytes {
                        let cacheKey = DiskChunkCache.buildEpisodeCacheKey(
                            episodeKey: episodeKey,
                            contentLength: knownLen,
                            fallbackUrl: primary
                        )
                        warmOnDisk = await self.chunkBooster.hasPlayableHotWindow(
                            episodeKey: episodeKey,
                            cacheKey: cacheKey,
                            resumePositionMs: resumeMs,
                            estimatedDurationMs: knownDur
                        )
                    }
                }
                self.isDiskCacheWarm = warmOnDisk

                if warmOnDisk {
                    await self.chunkBooster.probeMirrorsInBackground(urls: resolved.videoSources)
                } else {
                    // Race probes until the FIRST valid full-length mirror responds (~80–150 ms)
                    await self.chunkBooster.probeMirrorsForPlayback(urls: resolved.videoSources, maxWaitMs: 900)
                }
                if Task.isCancelled { return }

                let ranked = self.chunkBooster.mirrorHealthTracker.rankMirrors(resolved.videoSources)
                self.mirrorState = MirrorQueueState(sources: ranked, activeIndex: 0, exhausted: false)
                try await self.bindPlaybackURL(
                    for: ranked,
                    episodeKey: episodeKey,
                    resumeMs: resumeMs,
                    estimatedDurationMs: knownDur
                )
                try Task.checkCancellation()
                self.isLoading = false
            } catch {
                if !Task.isCancelled {
                    self.isLoading = false
                    self.errorMessage = error.localizedDescription
                    await self.setUserPriority(false)
                }
            }
        }
    }

    public func onPlaybackStarted(durationMs: Int64) {
        if !hasRecordedStartForAttempt, let currentUrl = mirrorState.currentUrl {
            hasRecordedStartForAttempt = true
            let elapsed = max(1, currentTimeMs() - mirrorAttemptStartedAtMs)
            chunkBooster.mirrorHealthTracker.recordSuccess(url: currentUrl, latencyMs: elapsed)
        }
        Task {
            await setUserPriority(false)
        }
        if !hasPreloadedNextForEpisode, let nextKey = stream?.nextEpisodeKey, !nextKey.isEmpty {
            hasPreloadedNextForEpisode = true
            let bytes = networkPolicy.nextEpisodeInitialBytes
            scheduleNextEpisodeWarmup(
                nextKey: nextKey,
                nextLabel: stream?.nextEpisodeLabel ?? "",
                videoBytes: bytes
            )
        }
    }

    /// Called once the active episode has built a comfortable forward buffer (>= 15s) to
    /// escalate Watch Next from 6 MB -> 20 MB on unmetered Wi-Fi.
    public func onPlaybackHealthyBufferAhead() {
        guard !hasEscalatedNextEpisode,
              let nextKey = stream?.nextEpisodeKey, !nextKey.isEmpty,
              networkPolicy.allowBackgroundVideoPreload else { return }
        let escalatedBytes = networkPolicy.nextEpisodeEscalatedBytes
        guard escalatedBytes > networkPolicy.nextEpisodeInitialBytes else { return }
        hasEscalatedNextEpisode = true
        scheduleNextEpisodeWarmup(
            nextKey: nextKey,
            nextLabel: stream?.nextEpisodeLabel ?? "",
            videoBytes: escalatedBytes
        )
    }

    /// Atomically promotes a pre-buffered `preparedNextEpisode` into the active playback slot
    /// for 0 ms instant switching via `AVQueuePlayer.advanceToNextItem()`.
    public func promotePreparedNextEpisode() -> PreparedNextEpisode? {
        guard let next = preparedNextEpisode else { return nil }
        let oldSessionId = activeProxySessionId
        let oldEpisodeKey = stream?.episodeKey
        let oldCacheKey = activeCacheKey

        nextPreloadTask?.cancel()
        nextPreloadTask = nil
        skipTask?.cancel()
        skipTask = nil

        preparedNextEpisode = nil
        stream = next.stream
        mirrorState = MirrorQueueState(sources: next.rankedMirrors, activeIndex: 0, exhausted: false)
        activeProxySessionId = next.sessionId
        activeCacheKey = next.cacheKey
        usesProxyStream = true
        isLoading = false
        isDiskCacheWarm = true
        errorMessage = nil
        initialResumePositionMs = 0
        initialDurationMs = next.durationMs
        if let resolvedId = next.stream.animeId, !resolvedId.isEmpty {
            animeId = resolvedId
        }
        if !next.stream.animeTitle.isEmpty {
            animeTitle = next.stream.animeTitle
        }
        skipTimes = next.skipTimes
        skipTimesResolved = next.skipTimes.op != nil || next.skipTimes.ed != nil
        attemptedFreshGate = false
        hasRecordedStartForAttempt = false
        hasPreloadedNextForEpisode = false
        hasEscalatedNextEpisode = false
        mirrorAttemptStartedAtMs = currentTimeMs()
        playbackURL = next.localURL

        if !skipTimesResolved {
            fetchSkipTimesAsync(title: animeTitle, episodeLabel: next.stream.episodeLabel)
        }

        let opEndMs = next.skipTimes.op?.endMs ?? Int64(settingsStore.skipOpSeconds) * 1000
        let keepKeys = Set([next.episodeKey, next.stream.nextEpisodeKey].compactMap { $0 })
        let durMs = next.durationMs > 0 ? next.durationMs : 24 * 60_000
        Task { [chunkBooster, proxyServer] in
            if let oldSessionId {
                await chunkBooster.stopBoosting(sessionId: oldSessionId)
                await proxyServer.unregisterSession(sessionId: oldSessionId)
            }
            await chunkBooster.markEpisodeCompleted(episodeKey: oldEpisodeKey, cacheKey: oldCacheKey)
            await chunkBooster.cancelPreloadsExcept(keepKeys)
            await chunkBooster.startBoosting(
                session: next.descriptor,
                resumePositionMs: 0,
                estimatedDurationMs: durMs,
                opEndMs: opEndMs
            )
        }
        return next
    }

    public func onPlayheadTick(positionMs: Int64, durationMs: Int64) {
        let opEndMs = skipTimes.op?.endMs ?? Int64(settingsStore.skipOpSeconds) * 1000
        Task {
            await chunkBooster.updatePlayhead(
                positionMs: positionMs,
                durationMs: durationMs,
                opEndMs: opEndMs
            )
        }
    }

    public func onPlaybackError(resumeFromMs: Int64) {
        guard !isLoading, !mirrorState.exhausted else { return }
        if let failing = mirrorState.currentUrl {
            chunkBooster.mirrorHealthTracker.recordFailure(url: failing)
        }
        let nextState = mirrorState.advanceOnError()
        mirrorState = nextState
        hasRecordedStartForAttempt = false

        if !nextState.exhausted, let nextUrl = nextState.currentUrl {
            initialResumePositionMs = resumeFromMs
            let reordered = [nextUrl] + nextState.sources.filter { $0 != nextUrl }
            let epKey = stream?.episodeKey ?? ""
            switchPlayback(to: reordered, episodeKey: epKey, resumeMs: resumeFromMs)
            return
        }

        if !attemptedFreshGate, let epKey = stream?.episodeKey {
            attemptedFreshGate = true
            initialResumePositionMs = resumeFromMs
            loadEpisode(episodeKey: epKey, forceRefreshGate: true, resumeOverrideMs: resumeFromMs)
            return
        }

        errorMessage = "All video mirrors failed to play. Tap Retry to refresh mirrors."
    }

    public func cycleMirrorManually(currentPositionMs: Int64) {
        guard !isLoading, mirrorState.mirrorCount > 1 else { return }
        let nextState = mirrorState.cycleManual()
        mirrorState = nextState
        hasRecordedStartForAttempt = false
        initialResumePositionMs = currentPositionMs
        guard let selected = nextState.currentUrl, let epKey = stream?.episodeKey else { return }
        let reordered = [selected] + nextState.sources.filter { $0 != selected }
        switchPlayback(to: reordered, episodeKey: epKey, resumeMs: currentPositionMs)
    }

    private func switchPlayback(to mirrors: [String], episodeKey: String, resumeMs: Int64) {
        loadTask?.cancel()
        playbackURL = nil
        errorMessage = nil
        isLoading = true
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.bindPlaybackURL(
                    for: mirrors,
                    episodeKey: episodeKey,
                    resumeMs: resumeMs,
                    estimatedDurationMs: self.initialDurationMs,
                    preferExplicitOrder: true
                )
                try Task.checkCancellation()
                self.isLoading = false
            } catch {
                guard !Task.isCancelled else { return }
                self.isLoading = false
                self.errorMessage = error.localizedDescription
                await self.setUserPriority(false)
            }
        }
    }

    public func persistProgress(positionMs: Int64, durationMs: Int64, forceWatched: Bool = false) {
        guard let stream, !stream.episodeKey.isEmpty else { return }
        let aId = animeId
        let aTitle = animeTitle
        let cUrl = coverUrl
        Task { [repository] in
            await repository.saveWatchProgress(
                episodeKey: stream.episodeKey,
                animeId: aId,
                animeTitle: aTitle,
                coverUrl: cUrl,
                episodeLabel: stream.episodeLabel,
                positionMs: positionMs,
                durationMs: durationMs,
                nextEpisodeKey: stream.nextEpisodeKey,
                nextEpisodeLabel: stream.nextEpisodeLabel,
                forceWatched: forceWatched
            )
        }
    }

    public func shutdown() {
        loadTask?.cancel()
        loadTask = nil
        skipTask?.cancel()
        skipTask = nil
        nextPreloadTask?.cancel()
        nextPreloadTask = nil
        let sessionId = activeProxySessionId
        activeProxySessionId = nil
        activeCacheKey = nil
        let preparedSessionId = preparedNextEpisode?.sessionId
        preparedNextEpisode = nil
        let endPriority = isUserPriorityActive
        isUserPriorityActive = false
        Task { [chunkBooster, proxyServer, preloader] in
            if let sessionId {
                await chunkBooster.stopBoosting(sessionId: sessionId)
                await proxyServer.unregisterSession(sessionId: sessionId)
            }
            if let preparedSessionId {
                await proxyServer.unregisterSession(sessionId: preparedSessionId)
            }
            if endPriority { await preloader?.endUserPriorityWork() }
        }
    }

    private func scheduleNextEpisodeWarmup(nextKey: String, nextLabel: String, videoBytes: Int64) {
        let title = animeTitle
        let aId = animeId
        nextPreloadTask?.cancel()
        nextPreloadTask = Task { [weak self] in
            guard let self else { return }
            guard let warmup = await self.preloader?.warmEpisode(
                episodeKey: nextKey,
                animeId: aId,
                animeTitle: title,
                episodeLabel: nextLabel,
                videoBytes: videoBytes,
                highPriority: true
            ) else { return }

            guard !Task.isCancelled,
                  self.stream?.nextEpisodeKey == nextKey,
                  warmup.totalLength >= MirrorHealthTracker.minValidVideoBytes else { return }

            // If a proxy session for this exact next episode is already registered, keep its stable URL
            // so AVQueuePlayer does not churn its pre-buffered next item while escalation adds more chunks.
            if let existing = self.preparedNextEpisode, existing.episodeKey == nextKey {
                return
            }

            let sessionId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let descriptor = StreamSessionDescriptor(
                sessionId: sessionId,
                cacheKey: warmup.cacheKey,
                episodeKey: nextKey,
                mirrors: warmup.rankedMirrors,
                totalLength: warmup.totalLength,
                preferExplicitOrder: false
            )
            guard let localURL = try? await self.proxyServer.registerSession(descriptor) else { return }
            if Task.isCancelled || self.stream?.nextEpisodeKey != nextKey {
                await self.proxyServer.unregisterSession(sessionId: sessionId)
                return
            }
            await self.teardownPreparedNextSession()
            self.preparedNextEpisode = PreparedNextEpisode(
                episodeKey: nextKey,
                stream: warmup.stream,
                rankedMirrors: warmup.rankedMirrors,
                cacheKey: warmup.cacheKey,
                sessionId: sessionId,
                descriptor: descriptor,
                localURL: localURL,
                skipTimes: warmup.skipTimes,
                durationMs: warmup.durationMs
            )
        }
    }

    private func bindPlaybackURL(
        for orderedMirrors: [String],
        episodeKey: String,
        resumeMs: Int64,
        estimatedDurationMs: Int64 = 0,
        preferExplicitOrder: Bool = false
    ) async throws {
        await teardownActiveSession()
        try Task.checkCancellation()
        mirrorAttemptStartedAtMs = currentTimeMs()
        guard let primaryUrl = orderedMirrors.first else { return }

        let primaryMeta = await chunkBooster.cachedProbeMeta(for: primaryUrl)
        let probedLen = primaryMeta?.supportsRanges == true ? (primaryMeta?.contentLength ?? -1) : -1
        let totalLength = probedLen >= MirrorHealthTracker.minValidVideoBytes
            ? probedLen
            : await chunkBooster.resolveTotalLength(urls: orderedMirrors, episodeKey: episodeKey)
        try Task.checkCancellation()
        if totalLength >= MirrorHealthTracker.minValidVideoBytes {
            let cacheKey = DiskChunkCache.buildEpisodeCacheKey(
                episodeKey: episodeKey,
                contentLength: totalLength,
                fallbackUrl: primaryUrl
            )
            let sessionId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let descriptor = StreamSessionDescriptor(
                sessionId: sessionId,
                cacheKey: cacheKey,
                episodeKey: episodeKey,
                mirrors: orderedMirrors,
                totalLength: totalLength,
                preferExplicitOrder: preferExplicitOrder
            )
            let localURL = try await proxyServer.registerSession(descriptor)
            if Task.isCancelled {
                await proxyServer.unregisterSession(sessionId: sessionId)
                throw CancellationError()
            }
            activeProxySessionId = sessionId
            activeCacheKey = cacheKey
            usesProxyStream = true

            await chunkBooster.startBoosting(
                session: descriptor,
                resumePositionMs: resumeMs,
                estimatedDurationMs: estimatedDurationMs > 0 ? estimatedDurationMs : 24 * 60_000,
                opEndMs: skipTimes.op?.endMs ?? Int64(settingsStore.skipOpSeconds) * 1000
            )
            try Task.checkCancellation()
            playbackURL = localURL
        } else {
            let sessionId = UUID().uuidString
            let descriptor = StreamSessionDescriptor(
                sessionId: sessionId, cacheKey: primaryUrl, episodeKey: episodeKey,
                mirrors: [primaryUrl], totalLength: -1, preferExplicitOrder: true
            )
            let localURL = try await proxyServer.registerSession(descriptor)
            if Task.isCancelled {
                await proxyServer.unregisterSession(sessionId: sessionId)
                throw CancellationError()
            }
            activeProxySessionId = sessionId
            activeCacheKey = primaryUrl
            usesProxyStream = true
            playbackURL = localURL
        }
    }

    private func teardownActiveSession() async {
        if let sid = activeProxySessionId {
            activeProxySessionId = nil
            activeCacheKey = nil
            await chunkBooster.stopBoosting(sessionId: sid)
            await proxyServer.unregisterSession(sessionId: sid)
        }
    }

    private func teardownPreparedNextSession() async {
        if let prepared = preparedNextEpisode {
            preparedNextEpisode = nil
            await proxyServer.unregisterSession(sessionId: prepared.sessionId)
        }
    }

    private func fetchSkipTimesAsync(title: String, episodeLabel: String) {
        skipTask?.cancel()
        guard let epNum = SkipTimesParser.parseEpisodeNumber(episodeLabel), !title.isEmpty else {
            skipTimesResolved = true
            return
        }
        skipTask = Task { [weak self] in
            guard let self else { return }
            let times = await self.skipTimesClient.fetchSkipTimes(animeTitle: title, episodeNumber: epNum)
            if !Task.isCancelled {
                self.skipTimes = times
                self.skipTimesResolved = true
            }
        }
    }

    private func setUserPriority(_ active: Bool) async {
        if active && !isUserPriorityActive {
            isUserPriorityActive = true
            await preloader?.beginUserPriorityWork()
        } else if !active && isUserPriorityActive {
            isUserPriorityActive = false
            await preloader?.endUserPriorityWork()
        }
    }

    private func currentTimeMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
