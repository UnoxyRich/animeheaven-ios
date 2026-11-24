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
}
