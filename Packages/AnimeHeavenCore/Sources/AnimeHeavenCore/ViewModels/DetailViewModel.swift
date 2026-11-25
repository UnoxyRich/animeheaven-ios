import Foundation
import Observation

public struct DetailActionTarget: Sendable, Equatable {
    public let episodeKey: String
    public let episodeLabel: String
    public let buttonLabel: String

    public init(episodeKey: String, episodeLabel: String, buttonLabel: String) {
        self.episodeKey = episodeKey
        self.episodeLabel = episodeLabel
        self.buttonLabel = buttonLabel
    }
}

@MainActor
@Observable
public final class DetailViewModel {
    public let animeId: String
    public private(set) var detail: AnimeDetail?
    public private(set) var isLoading: Bool = false
    public private(set) var isRefreshing: Bool = false
    public private(set) var errorMessage: String?
    public private(set) var isBookmarked: Bool = false
    public private(set) var progressMap: [String: WatchProgressRecord] = [:]
    public private(set) var primaryAction: DetailActionTarget?
    public var sortOldestFirst: Bool = false

    @ObservationIgnored
    private let repository: AnimeHeavenRepository
    @ObservationIgnored
    private let preloader: AnimePreloader?
    @ObservationIgnored
    private var loadTask: Task<Void, Never>?
    @ObservationIgnored
    private var observerTask: Task<Void, Never>?
    @ObservationIgnored
    private var lastPreloadedKey: String?

    public init(
        animeId: String,
        repository: AnimeHeavenRepository,
        preloader: AnimePreloader? = nil
    ) {
        self.animeId = animeId
        self.repository = repository
        self.preloader = preloader
    }

    public var displayedEpisodes: [EpisodeItem] {
        guard let episodes = detail?.episodes else { return [] }
        return sortOldestFirst ? Array(episodes.reversed()) : episodes
    }
    deinit {
        observerTask?.cancel()
        loadTask?.cancel()
    }

    public func startObserving() {
        guard observerTask == nil else { return }
        let db = repository.database
        observerTask = Task { [weak self] in
            let stream = await db.observeChanges()
            await self?.refreshLocalState()
            for await event in stream {
                guard !Task.isCancelled, let self else { break }
                if event == .bookmarks || event == .watchProgress {
                    await self.refreshLocalState()
                }
            }
        }
    }

    public func stopObserving() {
        observerTask?.cancel()
        observerTask = nil
    }

    public func load(forceRefresh: Bool = false) {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            await self?.runLoad(forceRefresh: forceRefresh)
        }
    }

    public func refreshAsync() async {
        load(forceRefresh: true)
        await loadTask?.value
    }

    public func toggleBookmark() {
        guard let detail else { return }
        Task {
            self.isBookmarked = await repository.toggleBookmark(detail: detail)
        }
    }

    public func toggleSortOrder() {
        sortOldestFirst.toggle()
    }

    private func refreshLocalState() async {
        async let bm = repository.isBookmarked(animeId: animeId)
        async let prog = repository.getWatchProgressMap(animeId: animeId)
        self.isBookmarked = await bm
        self.progressMap = await prog
        recomputePrimaryAction()
    }

    private func runLoad(forceRefresh: Bool) async {
        if detail == nil { isLoading = true } else { isRefreshing = true }
        errorMessage = nil
        await refreshLocalState()

        do {
            let (loaded, isStale) = try await repository.getAnimeDetail(
                animeId: animeId,
                forceRefresh: forceRefresh
            )
            self.detail = loaded
            self.isLoading = false
            recomputePrimaryAction()
            warmPrimaryEpisodeIfNeeded()

            if isStale && !forceRefresh {
                isRefreshing = true
                if let fresh = try? await repository.refreshAnimeDetail(animeId: animeId) {
                    self.detail = fresh
                    recomputePrimaryAction()
                }
            }
            self.isRefreshing = false
        } catch {
            if !Task.isCancelled {
                self.isLoading = false
                self.isRefreshing = false
                if self.detail == nil {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func recomputePrimaryAction() {
        guard let detail, !detail.episodes.isEmpty else {
            primaryAction = nil
            return
        }
        // AnimeHeaven lists episodes newest-first; oldest is `.last`
        if let latestProg = progressMap.values.max(by: { $0.updatedAt < $1.updatedAt }) {
            if latestProg.isWatched {
                if let nextKey = latestProg.nextEpisodeKey, !nextKey.isEmpty {
                    let label = latestProg.nextEpisodeLabel ?? "Next Ep"
                    primaryAction = DetailActionTarget(
                        episodeKey: nextKey,
                        episodeLabel: label,
                        buttonLabel: "Watch \(label)"
                    )
                    return
                }
            } else if latestProg.positionMs > WatchProgressLogic.minResumeThresholdMs {
                primaryAction = DetailActionTarget(
                    episodeKey: latestProg.episodeKey,
                    episodeLabel: latestProg.episodeLabel,
                    buttonLabel: "Resume Ep \(latestProg.episodeLabel)"
                )
                return
            }
        }
        if let firstEp = detail.episodes.last {
            primaryAction = DetailActionTarget(
                episodeKey: firstEp.key,
                episodeLabel: firstEp.numberLabel,
                buttonLabel: "Watch Ep \(firstEp.numberLabel)"
            )
        }
    }

    private func warmPrimaryEpisodeIfNeeded() {
        guard let detail, let target = primaryAction, target.episodeKey != lastPreloadedKey else { return }
        lastPreloadedKey = target.episodeKey
        let saved = progressMap[target.episodeKey]
        let resumeMs = saved.map {
            WatchProgressLogic.resolveResumePositionMs(positionMs: $0.positionMs, durationMs: $0.durationMs)
        } ?? 0
        let durationMs = saved?.durationMs ?? 0
        Task.detached(priority: .utility) { [preloader] in
            await preloader?.preloadAnimeDetail(
                detail: detail,
                primaryEpisodeKey: target.episodeKey,
                primaryEpisodeLabel: target.episodeLabel,
                primaryResumeMs: resumeMs,
                primaryDurationMs: durationMs
            )
        }
    }
}
