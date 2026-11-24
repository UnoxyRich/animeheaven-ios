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
    private var observerTask: Task<Void, Never>?

    public init(repository: AnimeHeavenRepository) {
        self.repository = repository
    }

    public func startObserving() {
        guard observerTask == nil else { return }
        observerTask = Task { [weak self] in
            guard let self else { return }
            await self.reload()
            let stream = await self.repository.database.observeChanges()
            for await event in stream {
                if Task.isCancelled { break }
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
