import Foundation
import Testing
@testable import AnimeHeavenCore

@Suite("SkipPromptLogic")
struct SkipPromptLogicTests {

    @Test func exactOpSegmentActivatesAndSeeksToEnd() {
        let op = SkipSegment(type: .op, startMs: 80_000, endMs: 170_000, isExact: true)
        let times = EpisodeSkipTimes(op: op, ed: nil)

        let active = SkipPromptLogic.resolveActiveSegment(
            positionMs: 90_000,
            durationMs: 1_440_000,
            skipTimes: times,
            skipTimesResolved: true,
            skipPromptEnabled: true,
            fallbackSkipSeconds: 85,
            handledTypes: []
        )
        #expect(active == op)

        let action = SkipPromptLogic.resolveSkipAction(
            segment: op,
            currentPositionMs: 90_000,
            durationMs: 1_440_000,
            fallbackSkipSeconds: 85,
            hasNextEpisode: true
        )
        #expect(action.kind == .seekToTarget)
        #expect(action.targetPositionMs == 170_000)
    }

    @Test func endingNearEndAdvancesToNextEpisode() {
        let ed = SkipSegment(type: .ed, startMs: 1_340_000, endMs: 1_430_000, isExact: true)
        let action = SkipPromptLogic.resolveSkipAction(
            segment: ed,
            currentPositionMs: 1_350_000,
            durationMs: 1_440_000,
            fallbackSkipSeconds: 85,
            hasNextEpisode: true
        )
        #expect(action.kind == .nextEpisode)
        #expect(action.feedbackLabel == "Next Episode")
    }

    @Test func doesNotShowFallbackSkipWhenAniSkipReturnsEmpty() {
        let active = SkipPromptLogic.resolveActiveSegment(
            positionMs: 20_000,
            durationMs: 1_440_000,
            skipTimes: EpisodeSkipTimes(),
            skipTimesResolved: true,
            skipPromptEnabled: true,
            fallbackSkipSeconds: 85,
            handledTypes: []
        )
        #expect(active == nil)
        #expect(SkipPromptLogic.hudActiveSegment(
            positionMs: 20_000,
            skipTimes: EpisodeSkipTimes(),
            skipPromptEnabled: true
        ) == nil)
    }

    @Test func hudActiveSegmentOnlyMatchesInsideFetchedOpOrEdWindow() {
        let op = SkipSegment(type: .op, startMs: 80_000, endMs: 170_000, isExact: true)
        let times = EpisodeSkipTimes(op: op, ed: nil)
        #expect(SkipPromptLogic.hudActiveSegment(positionMs: 0, skipTimes: times, skipPromptEnabled: true) == nil)
        #expect(SkipPromptLogic.hudActiveSegment(positionMs: 90_000, skipTimes: times, skipPromptEnabled: true) == op)
        #expect(SkipPromptLogic.hudActiveSegment(positionMs: 175_000, skipTimes: times, skipPromptEnabled: true) == nil)
    }

    @Test func disabledOrAlreadyHandledSuppressesPrompt() {
        let op = SkipSegment(type: .op, startMs: 80_000, endMs: 170_000, isExact: true)
        let times = EpisodeSkipTimes(op: op, ed: nil)

        #expect(SkipPromptLogic.resolveActiveSegment(
            positionMs: 90_000,
            durationMs: 1_440_000,
            skipTimes: times,
            skipTimesResolved: true,
            skipPromptEnabled: false,
            fallbackSkipSeconds: 85,
            handledTypes: []
        ) == nil)
        #expect(SkipPromptLogic.resolveActiveSegment(
            positionMs: 90_000,
            durationMs: 1_440_000,
            skipTimes: times,
            skipTimesResolved: true,
            skipPromptEnabled: true,
            fallbackSkipSeconds: 85,
            handledTypes: [.op]
        ) == nil)
    }
}
