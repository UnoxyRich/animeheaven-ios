import Foundation
import Testing
@testable import AnimeHeavenCore

@Suite("WatchProgressLogic")
struct WatchProgressLogicTests {

    @Test func isEpisodeWatchedAt85Percent() {
        #expect(!WatchProgressLogic.isEpisodeWatched(positionMs: 840_000, durationMs: 1_000_000))
        #expect(WatchProgressLogic.isEpisodeWatched(positionMs: 850_000, durationMs: 1_000_000))
        #expect(!WatchProgressLogic.isEpisodeWatched(positionMs: 500_000, durationMs: 0))
    }

    @Test func resolveResumePositionRespectsBounds() {
        #expect(WatchProgressLogic.resolveResumePositionMs(positionMs: 9_000, durationMs: 1_000_000) == 0)
        #expect(WatchProgressLogic.resolveResumePositionMs(positionMs: 250_000, durationMs: 1_000_000) == 250_000)
        #expect(WatchProgressLogic.resolveResumePositionMs(positionMs: 930_000, durationMs: 1_000_000) == 0)
    }

    @Test func buildContinueWatchingMidEpisode() {
        let rec = WatchProgressRecord(
            episodeKey: "ep1", animeId: "a1", animeTitle: "Bleach", coverUrl: "c1",
            episodeLabel: "1", positionMs: 120_000, durationMs: 1_400_000, isWatched: false,
            nextEpisodeKey: "ep2", nextEpisodeLabel: "Episode 2", updatedAt: 100
        )
        let cw = WatchProgressLogic.buildContinueWatchingItem(from: rec)
        #expect(cw != nil)
        #expect(cw?.targetEpisodeKey == "ep1")
        #expect(cw?.isNextEpisode == false)
        #expect(cw?.resumePositionMs == 120_000)
    }

    @Test func buildContinueWatchingPromotesNextEpisodeWhenWatched() {
        let rec = WatchProgressRecord(
            episodeKey: "ep1", animeId: "a1", animeTitle: "Bleach", coverUrl: "c1",
            episodeLabel: "1", positionMs: 1_350_000, durationMs: 1_400_000, isWatched: true,
            nextEpisodeKey: "ep2", nextEpisodeLabel: "Episode 2", updatedAt: 100
        )
        let cw = WatchProgressLogic.buildContinueWatchingItem(from: rec)
        #expect(cw != nil)
        #expect(cw?.targetEpisodeKey == "ep2")
        #expect(cw?.isNextEpisode == true)
        #expect(cw?.resumePositionMs == 0)
    }

    @Test func buildContinueWatchingReturnsNilWhenWatchedAndNoNext() {
        let rec = WatchProgressRecord(
            episodeKey: "ep12", animeId: "a1", animeTitle: "Bleach", coverUrl: "c1",
            episodeLabel: "12", positionMs: 1_400_000, durationMs: 1_400_000, isWatched: true,
            nextEpisodeKey: nil, nextEpisodeLabel: nil, updatedAt: 100
        )
        #expect(WatchProgressLogic.buildContinueWatchingItem(from: rec) == nil)
    }
}
