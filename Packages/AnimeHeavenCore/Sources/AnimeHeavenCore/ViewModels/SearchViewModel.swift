import Foundation
import Observation

public protocol SearchGateway: Sendable {
    func fastSearch(query: String) async throws -> [FastSearchItem]
    func fullSearch(query: String) async throws -> ChartFeedResult
    func fastSearchMultilingual(query: String, forcedCandidate: String?) async throws -> MultilingualFastSearchResult
    func fullSearchMultilingual(query: String, forcedCandidate: String?) async throws -> MultilingualFullSearchResult
    func getRecentSearches() async -> [String]
    func deleteRecentSearch(query: String) async
}

public extension SearchGateway {
    func fastSearchMultilingual(
        query: String,
        forcedCandidate: String? = nil
    ) async throws -> MultilingualFastSearchResult {
        let items = try await fastSearch(query: forcedCandidate ?? query)
        return MultilingualFastSearchResult(items: items)
    }

    func fullSearchMultilingual(
        query: String,
        forcedCandidate: String? = nil
    ) async throws -> MultilingualFullSearchResult {
        let res = try await fullSearch(query: forcedCandidate ?? query)
        return MultilingualFullSearchResult(title: res.title, items: res.items)
    }
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

    public func fastSearchMultilingual(
        query: String,
        forcedCandidate: String? = nil
    ) async throws -> MultilingualFastSearchResult {
        try await repository.fastSearchMultilingual(query: query, forcedCandidate: forcedCandidate)
    }

    public func fullSearchMultilingual(
        query: String,
        forcedCandidate: String? = nil
    ) async throws -> MultilingualFullSearchResult {
        try await repository.fullSearchMultilingual(query: query, forcedCandidate: forcedCandidate)
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
    public private(set) var matchedQuery: String?
    public private(set) var candidateQueries: [String] = []
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
        matchedQuery = nil
        candidateQueries = []
        errorMessage = nil
        activeTask?.cancel()

        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            fastResults = []
            isLoading = false
            return
        }

        let isLatin = MultilingualQueryNormalizer.analyze(trimmed).script == .latin
        let effectiveDebounceMs = isLatin ? debounceMs : debounceMs * 2
        isLoading = true
        activeTask = Task { [weak self] in
            guard let self else { return }
            if effectiveDebounceMs > 0 {
                try? await Task.sleep(for: .milliseconds(effectiveDebounceMs))
            }
            if Task.isCancelled { return }
            do {
                let res = try await self.gateway.fastSearchMultilingual(query: trimmed, forcedCandidate: nil)
                if Task.isCancelled { return }
                self.fastResults = res.items
                self.matchedQuery = res.matchedQuery
                self.candidateQueries = res.candidateQueries
                self.isLoading = false
                await self.preloader?.preloadImages(
                    urls: res.items.map(\.coverUrl),
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
        matchedQuery = nil
        candidateQueries = []
        isLoading = true
        errorMessage = nil
        activeTask?.cancel()

        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let res = try await self.gateway.fullSearchMultilingual(query: target, forcedCandidate: nil)
                if Task.isCancelled { return }
                self.fullResultsTitle = res.title.isEmpty ? "Results for \"\(target)\"" : res.title
                self.fullResults = res.items
                self.matchedQuery = res.matchedQuery
                self.candidateQueries = res.candidateQueries
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

    public func selectCandidateQuery(_ candidate: String) {
        let target = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, !chosen.isEmpty else { return }
        let fullMode = isFullSearchMode
        let existingCandidates = candidateQueries
        matchedQuery = chosen
        isLoading = true
        errorMessage = nil
        activeTask?.cancel()

        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                if fullMode {
                    let res = try await self.gateway.fullSearchMultilingual(query: target, forcedCandidate: chosen)
                    if Task.isCancelled { return }
                    self.fullResultsTitle = res.title.isEmpty ? "Results for \"\(chosen)\"" : res.title
                    self.fullResults = res.items
                    self.matchedQuery = chosen
                    self.candidateQueries = existingCandidates.isEmpty ? res.candidateQueries : existingCandidates
                    self.isLoading = false
                    await self.preloader?.preloadImages(
                        urls: res.items.map(\.coverUrl),
                        maxCount: 12,
                        targetSize: .standardCard
                    )
                } else {
                    let res = try await self.gateway.fastSearchMultilingual(query: target, forcedCandidate: chosen)
                    if Task.isCancelled { return }
                    self.fastResults = res.items
                    self.matchedQuery = chosen
                    self.candidateQueries = existingCandidates.isEmpty ? res.candidateQueries : existingCandidates
                    self.isLoading = false
                    await self.preloader?.preloadImages(
                        urls: res.items.map(\.coverUrl),
                        maxCount: 10,
                        targetSize: .searchThumb
                    )
                }
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
        matchedQuery = nil
        candidateQueries = []
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
