import Foundation
import Testing
@testable import AnimeHeavenCore

private actor FakeSearchGateway: SearchGateway {
    var recent: [String] = ["frieren"]

    func fastSearch(query: String) async throws -> [FastSearchItem] {
        [FastSearchItem(animeId: "id1", title: "Match: \(query)", coverUrl: "https://example.com/1.jpg")]
    }

    func fullSearch(query: String) async throws -> ChartFeedResult {
        recent.insert(query, at: 0)
        return ChartFeedResult(
            title: "Search: \(query)",
            items: [AnimeCard(id: "id1", title: "Full: \(query)")]
        )
    }

    func fastSearchMultilingual(
        query: String,
        forcedCandidate: String?
    ) async throws -> MultilingualFastSearchResult {
        if query == "葬送的芙莉莲" && forcedCandidate == nil {
            return MultilingualFastSearchResult(
                items: [FastSearchItem(animeId: "ak2gr", title: "Sousou no Frieren", coverUrl: "https://example.com/f.jpg")],
                matchedQuery: "Sousou no Frieren",
                candidateQueries: ["Sousou no Frieren", "Frieren: Beyond Journey's End"]
            )
        }
        return MultilingualFastSearchResult(
            items: try await fastSearch(query: forcedCandidate ?? query),
            matchedQuery: forcedCandidate,
            candidateQueries: forcedCandidate.map { [$0] } ?? []
        )
    }

    func fullSearchMultilingual(
        query: String,
        forcedCandidate: String?
    ) async throws -> MultilingualFullSearchResult {
        if forcedCandidate == nil {
            recent.insert(query, at: 0)
        }
        if query == "葬送的芙莉莲" {
            let effective = forcedCandidate ?? "Sousou no Frieren"
            return MultilingualFullSearchResult(
                title: "Results for \"\(effective)\"",
                items: [AnimeCard(id: "ak2gr", title: "Full: \(effective)")],
                matchedQuery: effective,
                candidateQueries: ["Sousou no Frieren", "Frieren: Beyond Journey's End"]
            )
        }
        let effective = forcedCandidate ?? query
        return MultilingualFullSearchResult(
            title: "Search: \(effective)",
            items: [AnimeCard(id: "id1", title: "Full: \(effective)")],
            matchedQuery: forcedCandidate
        )
    }

    func getRecentSearches() async -> [String] { recent }

    func deleteRecentSearch(query: String) async {
        recent.removeAll { $0 == query }
    }
}

@Suite("SearchViewModel")
struct SearchViewModelTests {

    @Test @MainActor func fastAndFullSearchTransitionsCleanly() async throws {
        let gateway = FakeSearchGateway()
        let vm = SearchViewModel(gateway: gateway, debounceMs: 10)
        await vm.loadRecentSearches()
        #expect(vm.recentSearches == ["frieren"])

        vm.onQueryChanged("bleach")
        await vm.waitForCurrentSearch()
        #expect(!vm.isFullSearchMode)
        #expect(vm.fastResults.map(\.title) == ["Match: bleach"])

        vm.submitFullSearch()
        await vm.waitForCurrentSearch()
        #expect(vm.isFullSearchMode)
        #expect(vm.fullResults.map(\.title) == ["Full: bleach"])
        #expect(vm.recentSearches.first == "bleach")
    }

    @Test @MainActor func fullSearchCancelsPendingSuggestions() async {
        let vm = SearchViewModel(gateway: FakeSearchGateway(), debounceMs: 500)
        vm.onQueryChanged("bleach")
        vm.submitFullSearch("frieren")
        await vm.waitForCurrentSearch()
        #expect(vm.query == "frieren")
        #expect(vm.isFullSearchMode)
        #expect(vm.fastResults.isEmpty)
        #expect(vm.fullResults.map(\.title) == ["Full: frieren"])
    }

    @Test @MainActor func multilingualSearchPreservesQueryAndSwitchesCandidate() async {
        let vm = SearchViewModel(gateway: FakeSearchGateway(), debounceMs: 10)
        vm.onQueryChanged("葬送的芙莉莲")
        await vm.waitForCurrentSearch()
        #expect(vm.matchedQuery == "Sousou no Frieren")
        #expect(vm.candidateQueries == ["Sousou no Frieren", "Frieren: Beyond Journey's End"])

        vm.submitFullSearch()
        await vm.waitForCurrentSearch()
        #expect(vm.recentSearches.first == "葬送的芙莉莲")

        vm.selectCandidateQuery("Frieren: Beyond Journey's End")
        await vm.waitForCurrentSearch()
        #expect(vm.query == "葬送的芙莉莲")
        #expect(vm.matchedQuery == "Frieren: Beyond Journey's End")
        #expect(vm.fullResults.map(\.title) == ["Full: Frieren: Beyond Journey's End"])
    }
}
