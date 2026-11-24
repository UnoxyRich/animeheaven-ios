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
        try await Task.sleep(for: .milliseconds(80))
        #expect(!vm.isFullSearchMode)
        #expect(vm.fastResults.count == 1)
        #expect(vm.fastResults[0].title == "Match: bleach")

        vm.submitFullSearch()
        try await Task.sleep(for: .milliseconds(80))
        #expect(vm.isFullSearchMode)
        #expect(vm.fullResults.count == 1)
        #expect(vm.fullResults[0].title == "Full: bleach")
        #expect(vm.recentSearches.first == "bleach")
    }
}
