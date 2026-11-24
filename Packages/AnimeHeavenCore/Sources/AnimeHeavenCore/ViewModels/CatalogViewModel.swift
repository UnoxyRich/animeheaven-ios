import Foundation
import Observation

public enum CatalogKind: Sendable, Hashable {
    case newReleases
    case popular
    case seasonal(path: String, label: String)
    case tag(String)

    public var defaultTitle: String {
        switch self {
        case .newReleases: return "New Releases"
        case .popular: return "Popular Anime"
        case .seasonal(_, let label): return label
        case .tag(let tag): return "Tag: \(tag)"
        }
    }

    public var isPopularRank: Bool {
        if case .popular = self { return true }
        return false
    }

    public var isGridPage: Bool {
        if case .tag = self { return true }
        return false
    }

    public var cacheKey: String {
        switch self {
        case .newReleases: return "new"
        case .popular: return "popular"
        case .seasonal(let path, _): return "season:\(path)"
        case .tag(let tag): return "tag:\(tag.lowercased())"
        }
    }

    public var relativePath: String {
        switch self {
        case .newReleases: return "new.php"
        case .popular: return "popular.php"
        case .seasonal(let path, _): return path
        case .tag(let tag): return "tags.php?tag=\(AnimeHeavenClient.urlQueryEncode(tag))"
        }
    }

    public var softTTLMs: Int64 {
        switch self {
        case .newReleases, .popular: return AnimeHeavenRepository.ttlChartMs
        case .seasonal: return AnimeHeavenRepository.ttlSeasonalMs
        case .tag: return AnimeHeavenRepository.ttlSearchMs
        }
    }
}

@MainActor
@Observable
public final class CatalogViewModel {
    public let kind: CatalogKind
    public private(set) var title: String
    public private(set) var items: [AnimeCard] = []
    public private(set) var isLoading: Bool = false
    public private(set) var isRefreshing: Bool = false
    public private(set) var errorMessage: String?
    public private(set) var bookmarkedIds: Set<String> = []
    public var viewMode: FeedViewMode {
        get { kind.isGridPage ? .grid : settingsStore.defaultViewMode }
        set {
            guard !kind.isGridPage else { return }
            settingsStore.defaultViewMode = newValue
        }
    }

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
        kind: CatalogKind,
        repository: AnimeHeavenRepository,
        settingsStore: SettingsStore,
        preloader: AnimePreloader? = nil
    ) {
        self.kind = kind
        self.title = kind.defaultTitle
        self.repository = repository
        self.settingsStore = settingsStore
        self.preloader = preloader
    }

    public func startObservingLocalState() {
        guard dbObserverTask == nil else { return }
        let db = repository.database
        dbObserverTask = Task { [weak self] in
            let stream = await db.observeChanges()
            await self?.refreshBookmarks()
            for await event in stream {
                guard !Task.isCancelled, let self else { break }
                if event == .bookmarks {
                    await self.refreshBookmarks()
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

    private func refreshBookmarks() async {
        self.bookmarkedIds = await repository.getBookmarkedIds()
    }

    public func load(forceRefresh: Bool = false) {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            await self?.runLoad(forceRefresh: forceRefresh)
        }
    }

    public func refreshAsync() async {
        await runLoad(forceRefresh: true)
    }

    public func toggleViewMode() {
        guard !kind.isGridPage else { return }
        viewMode = viewMode == .list ? .grid : .list
    }

    private func runLoad(forceRefresh: Bool) async {
        if items.isEmpty { isLoading = true } else { isRefreshing = true }
        errorMessage = nil
        bookmarkedIds = await repository.getBookmarkedIds()

        do {
            let result: ChartFeedResult
            let isStale: Bool
            if kind.isGridPage {
                let res = try await repository.getGridFeed(
                    cacheKey: kind.cacheKey,
                    relativePath: kind.relativePath,
                    softTTLMs: kind.softTTLMs,
                    forceRefresh: forceRefresh
                )
                result = res.result
                isStale = res.isStale
            } else {
                let res = try await repository.getChartFeed(
                    cacheKey: kind.cacheKey,
                    relativePath: kind.relativePath,
                    isPopularRank: kind.isPopularRank,
                    softTTLMs: kind.softTTLMs,
                    forceRefresh: forceRefresh
                )
                result = res.result
                isStale = res.isStale
            }

            if !result.title.isEmpty { self.title = result.title }
            self.items = result.items
            self.isLoading = false
            await preloader?.preloadImages(
                urls: result.items.map(\.coverUrl),
                maxCount: 12,
                targetSize: .standardCard
            )

            if isStale && !forceRefresh {
                isRefreshing = true
                let fresh: ChartFeedResult?
                if kind.isGridPage {
                    fresh = try? await repository.refreshGridFeed(
                        cacheKey: kind.cacheKey,
                        relativePath: kind.relativePath
                    )
                } else {
                    fresh = try? await repository.refreshChartFeed(
                        cacheKey: kind.cacheKey,
                        relativePath: kind.relativePath,
                        isPopularRank: kind.isPopularRank
                    )
                }
                if let fresh {
                    if !fresh.title.isEmpty { self.title = fresh.title }
                    self.items = fresh.items
                }
            }
            self.isRefreshing = false
        } catch {
            if !Task.isCancelled {
                self.isLoading = false
                self.isRefreshing = false
                if self.items.isEmpty {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }
}
