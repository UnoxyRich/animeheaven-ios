import Foundation
import Testing
@testable import AnimeHeavenCore

@Suite("SQLiteDatabase")
struct SQLiteDatabaseTests {

    @Test func bookmarksCrudAndOrdering() async throws {
        let db = try SQLiteDatabase(path: ":memory:")
        await db.upsertBookmark(BookmarkRecord(animeId: "a1", title: "Show 1", coverUrl: "u1", lastEpisodeLabel: "12", addedAt: 100))
        await db.upsertBookmark(BookmarkRecord(animeId: "a2", title: "Show 2", coverUrl: "u2", lastEpisodeLabel: "24", addedAt: 200))

        let all = await db.getAllBookmarks()
        #expect(all.map(\.animeId) == ["a2", "a1"])
        #expect(await db.isBookmarked(animeId: "a1"))

        await db.deleteBookmark(animeId: "a1")
        #expect(!(await db.isBookmarked(animeId: "a1")))
    }

    @Test func latestWatchProgressPerAnimeReturnsOnlyMostRecentEpisode() async throws {
        let db = try SQLiteDatabase(path: ":memory:")
        await db.upsertWatchProgress(WatchProgressRecord(
            episodeKey: "ep1", animeId: "showA", animeTitle: "Show A", coverUrl: "cA",
            episodeLabel: "1", positionMs: 1_200_000, durationMs: 1_400_000, isWatched: true,
            nextEpisodeKey: "ep2", nextEpisodeLabel: "Episode 2", updatedAt: 100
        ))
        await db.upsertWatchProgress(WatchProgressRecord(
            episodeKey: "ep2", animeId: "showA", animeTitle: "Show A", coverUrl: "cA",
            episodeLabel: "2", positionMs: 300_000, durationMs: 1_400_000, isWatched: false,
            nextEpisodeKey: "ep3", nextEpisodeLabel: "Episode 3", updatedAt: 300
        ))
        await db.upsertWatchProgress(WatchProgressRecord(
            episodeKey: "b1", animeId: "showB", animeTitle: "Show B", coverUrl: "cB",
            episodeLabel: "1", positionMs: 200_000, durationMs: 1_400_000, isWatched: false,
            updatedAt: 200
        ))

        let latest = await db.getLatestWatchProgressPerAnime(limit: 10)
        #expect(latest.count == 2)
        #expect(latest[0].episodeKey == "ep2")
        #expect(latest[1].episodeKey == "b1")
    }

    @Test func searchHistoryAndWebCachePruning() async throws {
        let db = try SQLiteDatabase(path: ":memory:")
        await db.upsertSearchHistory(query: "bleach", searchedAt: 10)
        await db.upsertSearchHistory(query: "frieren", searchedAt: 20)
        let recent = await db.getRecentSearches(limit: 5)
        #expect(recent == ["frieren", "bleach"])

        await db.upsertWebCache(WebCacheRecord(cacheKey: "old", payload: "12345", fetchedAt: 100, parsedJson: "{}"))
        await db.upsertWebCache(WebCacheRecord(cacheKey: "new", payload: "67890", fetchedAt: 500, parsedJson: "{}"))
        await db.pruneWebCacheOlderThan(cutoffMs: 250)

        #expect(await db.getWebCache(cacheKey: "old") == nil)
        #expect(await db.getWebCache(cacheKey: "new") != nil)
    }

    @Test @MainActor func settingsStorePersistsAcrossInstances() {
        let suiteName = "test.animeheaven.settings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store1 = SettingsStore(defaults: defaults)
        store1.themeId = .darkTealPlum
        store1.doubleTapSeekSeconds = 15
        store1.autoLandscapePlayer = false
        store1.preloadMode = .dataSaver

        let store2 = SettingsStore(defaults: defaults)
        #expect(store2.themeId == .darkTealPlum)
        #expect(store2.doubleTapSeekSeconds == 15)
        #expect(store2.autoLandscapePlayer == false)
        #expect(store2.preloadMode == .dataSaver)
    }
}
