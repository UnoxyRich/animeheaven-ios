import Foundation
import Observation

@MainActor
@Observable
public final class HomeViewModel {
    public private(set) var isLoading: Bool = false
    public private(set) var isRefreshing: Bool = false
    public private(set) var errorMessage: String?
    public private(set) var feed: HomeFeed?
    public private(set) var continueWatching: [ContinueWatchingItem] = []
    public private(set) var bookmarkedIds: Set<String> = []
    public var viewMode: FeedViewMode

    @ObservationIgnored
    private let repository: AnimeHeavenRepository
    @ObservationIgnored
    private let settingsStore: SettingsStore
    @ObservationIgnored
    private let preloader: AnimePreloader?
    @ObservationIgnored
    private var loadTask: Task<Void, Never>?
    @ObservationIgnored
    private var dbObserverTask: Task<Void, Never>?

    public init(
        repository: AnimeHeavenRepository,
        settingsStore: SettingsStore,
        preloader: AnimePreloader? = nil
    ) {
        self.repository = repository
        self.settingsStore = settingsStore
        self.preloader = preloader
        self.viewMode = settingsStore.defaultViewMode
    }

    public func startObservingLocalState() {
        guard dbObserverTask == nil else { return }
        let db = repository.database
        dbObserverTask = Task { [weak self] in
            let stream = await db.observeChanges()
            await self?.refreshLocalRows()
            for await event in stream {
                guard !Task.isCancelled, let self else { break }
                if event == .bookmarks || event == .watchProgress {
                    await self.refreshLocalRows()
                }
            }
        }
    }

    public func stopObservingLocalState() {
        dbObserverTask?.cancel()
        dbObserverTask = nil
    }
    deinit {
        dbObserverTask?.cancel()
        loadTask?.cancel()
    }

    public func loadHome(forceRefresh: Bool = false) {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            await self.runLoadHome(forceRefresh: forceRefresh)
        }
    }

    public func refreshAsync() async {
        await runLoadHome(forceRefresh: true)
    }

    public func toggleViewMode() {
        let next: FeedViewMode = viewMode == .list ? .grid : .list
        viewMode = next
        settingsStore.defaultViewMode = next
    }

    private func refreshLocalRows() async {
        async let cw = repository.getContinueWatching()
        async let bm = repository.getBookmarkedIds()
        self.continueWatching = await cw
        self.bookmarkedIds = await bm
        if let feed = self.feed {
            await preloader?.preloadHomeEcosystem(feed: feed, continueItems: self.continueWatching)
        }
    }

    private func runLoadHome(forceRefresh: Bool) async {
        if feed == nil {
            isLoading = true
        } else {
            isRefreshing = true
        }
        errorMessage = nil

        await refreshLocalRows()

        do {
            let (loaded, isStale) = try await repository.getHomeFeed(forceRefresh: forceRefresh)
            self.feed = loaded
            self.isLoading = false
            await preloader?.preloadHomeEcosystem(feed: loaded, continueItems: continueWatching)

            if isStale && !forceRefresh {
                isRefreshing = true
                if let fresh = try? await repository.refreshHomeFeed() {
                    self.feed = fresh
                    await preloader?.preloadHomeEcosystem(feed: fresh, continueItems: continueWatching)
                }
            }
            self.isRefreshing = false
        } catch {
            if !Task.isCancelled {
                self.isLoading = false
                self.isRefreshing = false
                if self.feed == nil {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }
}
