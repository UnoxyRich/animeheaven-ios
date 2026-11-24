import Foundation
import Observation

public protocol SearchGateway: Sendable {
    func fastSearch(query: String) async throws -> [FastSearchItem]
    func fullSearch(query: String) async throws -> ChartFeedResult
    func getRecentSearches() async -> [String]
    func deleteRecentSearch(query: String) async
}

public struct RepositorySearchGateway: SearchGateway {
    private let repository: AnimeHeavenRepository

    public init(repository: AnimeHeavenRepository) {
        self.repository = repository
    }

    public func fastSearch(query: String) async throws -> [FastSearchItem] {
        try await repository.fastSearch(query: query)
    }

    public func fullSearch(query: String) async throws -> ChartFeedResult {
        try await repository.fullSearch(query: query)
    }

    public func getRecentSearches() async -> [String] {
        await repository.getRecentSearches()
    }

    public func deleteRecentSearch(query: String) async {
        await repository.deleteSearchHistory(query: query)
    }
}

@MainActor
@Observable
public final class SearchViewModel {
    public var query: String = ""
    public private(set) var fastResults: [FastSearchItem] = []
    public private(set) var fullResults: [AnimeCard] = []
    public private(set) var fullResultsTitle: String = ""
    public private(set) var isFullSearchMode: Bool = false
    public private(set) var isLoading: Bool = false
    public private(set) var errorMessage: String?
    public private(set) var recentSearches: [String] = []

    @ObservationIgnored
    private let gateway: SearchGateway
    @ObservationIgnored
    private let preloader: AnimePreloader?
    @ObservationIgnored
    private let debounceMs: UInt64
    @ObservationIgnored
    private var activeTask: Task<Void, Never>?

    public init(
        gateway: SearchGateway,
        preloader: AnimePreloader? = nil,
        debounceMs: UInt64 = 220
    ) {
        self.gateway = gateway
        self.preloader = preloader
        self.debounceMs = debounceMs
    }

    public func loadRecentSearches() async {
        recentSearches = await gateway.getRecentSearches()
    }

    /// Wait for the currently requested search, including its debounced work.
    func waitForCurrentSearch() async {
        await activeTask?.value
    }

    public func onQueryChanged(_ newValue: String) {
        query = newValue
        isFullSearchMode = false
        errorMessage = nil
        activeTask?.cancel()

        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            fastResults = []
            isLoading = false
            return
        }

        isLoading = true
        activeTask = Task { [weak self] in
            guard let self else { return }
            if self.debounceMs > 0 {
                try? await Task.sleep(for: .milliseconds(self.debounceMs))
            }
            if Task.isCancelled { return }
            do {
                let matches = try await self.gateway.fastSearch(query: trimmed)
                if Task.isCancelled { return }
                self.fastResults = matches
                self.isLoading = false
                await self.preloader?.preloadImages(
                    urls: matches.map(\.coverUrl),
                    maxCount: 10,
                    targetSize: .searchThumb
                )
            } catch {
                if !Task.isCancelled {
                    self.isLoading = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    public func submitFullSearch(_ overrideQuery: String? = nil) {
        let target = (overrideQuery ?? query).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }
        query = target
        isFullSearchMode = true
        isLoading = true
        errorMessage = nil
        activeTask?.cancel()

        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let res = try await self.gateway.fullSearch(query: target)
                if Task.isCancelled { return }
                self.fullResultsTitle = res.title.isEmpty ? "Results for \"\(target)\"" : res.title
                self.fullResults = res.items
                self.isLoading = false
                let recent = await self.gateway.getRecentSearches()
                guard !Task.isCancelled else { return }
                self.recentSearches = recent
                await self.preloader?.preloadImages(
                    urls: res.items.map(\.coverUrl),
                    maxCount: 12,
                    targetSize: .standardCard
                )
            } catch {
                if !Task.isCancelled {
                    self.isLoading = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    public func clearQuery() {
        activeTask?.cancel()
        query = ""
        fastResults = []
        fullResults = []
        isFullSearchMode = false
        isLoading = false
        errorMessage = nil
    }

    public func deleteRecent(_ term: String) {
        Task {
            await gateway.deleteRecentSearch(query: term)
            recentSearches = await gateway.getRecentSearches()
        }
    }
}
