import Foundation
import Observation

@MainActor
@Observable
public final class PlayerViewModel {
    public private(set) var isLoading: Bool = true
    public private(set) var errorMessage: String?
    public private(set) var stream: EpisodeStream?
    public private(set) var mirrorState: MirrorQueueState = MirrorQueueState(sources: [])
    public private(set) var playbackURL: URL?
    public private(set) var usesProxyStream: Bool = false
    public private(set) var initialResumePositionMs: Int64 = 0
    public private(set) var animeId: String
    public private(set) var animeTitle: String
    public private(set) var coverUrl: String
    public private(set) var skipTimes: EpisodeSkipTimes = EpisodeSkipTimes()
    public private(set) var skipTimesResolved: Bool = false

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
    private var activeProxySessionId: String?
    @ObservationIgnored
    private var attemptedFreshGate: Bool = false
    @ObservationIgnored
    private var hasRecordedStartForAttempt: Bool = false
    @ObservationIgnored
    private var mirrorAttemptStartedAtMs: Int64 = 0
    @ObservationIgnored
    private var hasPreloadedNextForEpisode: Bool = false
    @ObservationIgnored
    private var isUserPriorityActive: Bool = false

    public init(
        episodeKey: String,
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

        loadEpisode(episodeKey: episodeKey)
    }

    public func loadEpisode(episodeKey: String, forceRefreshGate: Bool = false) {
        loadTask?.cancel()
        skipTask?.cancel()
        isLoading = true
        errorMessage = nil
        playbackURL = nil
        skipTimes = EpisodeSkipTimes()
        skipTimesResolved = false
        attemptedFreshGate = forceRefreshGate
        hasRecordedStartForAttempt = false
        hasPreloadedNextForEpisode = false

        loadTask = Task { [weak self] in
            guard let self else { return }
            await self.setUserPriority(true)
            await self.teardownActiveSession()
            await self.chunkBooster.cancelPreloadsExcept(episodeKey)

            do {
                async let resumeTask = self.repository.getResumePositionMs(episodeKey: episodeKey)
                let resolved = try await self.repository.resolveEpisodeStream(
                    episodeKey: episodeKey,
                    animeId: self.animeId.isEmpty ? nil : self.animeId,
                    forceRefresh: forceRefreshGate
                )
                if Task.isCancelled { return }

                let resumeMs = await resumeTask
                self.stream = resolved
                self.initialResumePositionMs = resumeMs
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

                // Race probes until the FIRST valid full-length mirror responds (~80–150 ms)
                await self.chunkBooster.probeMirrorsForPlayback(urls: resolved.videoSources, maxWaitMs: 900)
                if Task.isCancelled { return }

                let ranked = self.chunkBooster.mirrorHealthTracker.rankMirrors(resolved.videoSources)
                self.mirrorState = MirrorQueueState(sources: ranked, activeIndex: 0, exhausted: false)
                try await self.bindPlaybackURL(for: ranked, episodeKey: episodeKey, resumeMs: resumeMs)
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
            let bytes = networkPolicy.nextEpisodeVideoBytes
            let title = animeTitle
            let nextLabel = stream?.nextEpisodeLabel ?? ""
            let aId = animeId
            Task.detached(priority: .utility) { [preloader] in
                await preloader?.warmEpisode(
                    episodeKey: nextKey,
                    animeId: aId,
                    animeTitle: title,
                    episodeLabel: nextLabel,
                    videoBytes: bytes
                )
            }
        }
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
            Task { [weak self] in
                guard let self else { return }
                try? await self.bindPlaybackURL(for: reordered, episodeKey: epKey, resumeMs: resumeFromMs)
            }
            return
        }

        if !attemptedFreshGate, let epKey = stream?.episodeKey {
            attemptedFreshGate = true
            initialResumePositionMs = resumeFromMs
            loadEpisode(episodeKey: epKey, forceRefreshGate: true)
            return
        }

        errorMessage = "All video mirrors failed to play. Tap Retry to refresh mirrors."
    }

    public func cycleMirrorManually(currentPositionMs: Int64) {
        guard mirrorState.mirrorCount > 1 else { return }
        let nextState = mirrorState.cycleManual()
        mirrorState = nextState
        hasRecordedStartForAttempt = false
        initialResumePositionMs = currentPositionMs
        guard let selected = nextState.currentUrl, let epKey = stream?.episodeKey else { return }
        let reordered = [selected] + nextState.sources.filter { $0 != selected }
        Task { [weak self] in
            guard let self else { return }
            try? await self.bindPlaybackURL(for: reordered, episodeKey: epKey, resumeMs: currentPositionMs)
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
        skipTask?.cancel()
        Task { [weak self] in
            guard let self else { return }
            await self.teardownActiveSession()
            await self.setUserPriority(false)
        }
    }

    private func bindPlaybackURL(
        for orderedMirrors: [String],
        episodeKey: String,
        resumeMs: Int64
    ) async throws {
        await teardownActiveSession()
        mirrorAttemptStartedAtMs = currentTimeMs()
        guard let primaryUrl = orderedMirrors.first else { return }

        let totalLength = await chunkBooster.resolveTotalLength(urls: orderedMirrors)
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
                totalLength: totalLength
            )
            let localURL = try await proxyServer.registerSession(descriptor)
            activeProxySessionId = sessionId
            usesProxyStream = true
            playbackURL = localURL

            await chunkBooster.startBoosting(
                session: descriptor,
                resumePositionMs: resumeMs,
                estimatedDurationMs: 24 * 60_000,
                opEndMs: skipTimes.op?.endMs ?? Int64(settingsStore.skipOpSeconds) * 1000
            )
        } else if let direct = URL(string: primaryUrl) {
            usesProxyStream = false
            playbackURL = direct
        }
    }

    private func teardownActiveSession() async {
        await chunkBooster.stopBoosting()
        if let sid = activeProxySessionId {
            await proxyServer.unregisterSession(sessionId: sid)
            activeProxySessionId = nil
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
