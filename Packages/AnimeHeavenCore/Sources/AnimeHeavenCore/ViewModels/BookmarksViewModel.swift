import Foundation
import Observation

@MainActor
@Observable
public final class BookmarksViewModel {
    public private(set) var bookmarks: [BookmarkRecord] = []
    public private(set) var continueWatching: [ContinueWatchingItem] = []

    @ObservationIgnored
    private let repository: AnimeHeavenRepository
    @ObservationIgnored
    private let preloader: AnimePreloader?
    @ObservationIgnored
    private var observerTask: Task<Void, Never>?

    public init(repository: AnimeHeavenRepository, preloader: AnimePreloader? = nil) {
        self.repository = repository
        self.preloader = preloader
    }
    deinit { observerTask?.cancel() }

    public func startObserving() {
        guard observerTask == nil else { return }
        let db = repository.database
        observerTask = Task { [weak self] in
            let stream = await db.observeChanges()
            await self?.reload()
            for await event in stream {
                guard !Task.isCancelled, let self else { break }
                if event == .bookmarks || event == .watchProgress {
                    await self.reload()
                }
            }
        }
    }

    public func stopObserving() {
        observerTask?.cancel()
        observerTask = nil
    }

    public func reload() async {
        async let bm = repository.getBookmarks()
        async let cw = repository.getContinueWatching()
        self.bookmarks = await bm
        self.continueWatching = await cw
        await preloader?.preloadBookmarksEcosystem(bookmarks: self.bookmarks, continueItems: self.continueWatching)
    }

    public func removeBookmark(animeId: String) {
        Task {
            await repository.removeBookmark(animeId: animeId)
        }
    }

    public func clearWatchHistory() {
        Task {
            await repository.clearWatchHistory()
        }
    }
}
