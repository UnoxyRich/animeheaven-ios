import Foundation

public enum SkipActionKind: String, Sendable, Hashable {
    case seekToTarget
    case nextEpisode
}

public struct SkipAction: Sendable, Hashable {
    public let kind: SkipActionKind
    public let targetPositionMs: Int64
    public let feedbackLabel: String

    public init(kind: SkipActionKind, targetPositionMs: Int64, feedbackLabel: String) {
        self.kind = kind
        self.targetPositionMs = targetPositionMs
        self.feedbackLabel = feedbackLabel
    }
}

public enum SkipPromptLogic {
    public static let fallbackOpMaxWindowMs: Int64 = 180_000
    public static let fallbackOpStartMs: Int64 = 3_000
    public static let fallbackMinEpisodeMs: Int64 = 600_000
    public static let nextEpisodeThresholdFromEndMs: Int64 = 30_000

    public static func resolveActiveSegment(
        positionMs: Int64,
        durationMs: Int64,
        skipTimes: EpisodeSkipTimes,
        skipTimesResolved: Bool,
        skipPromptEnabled: Bool,
        fallbackSkipSeconds: Int,
        handledTypes: Set<SkipSegmentType>
    ) -> SkipSegment? {
        guard skipPromptEnabled else { return nil }

        if let op = skipTimes.op, !handledTypes.contains(.op) {
            if positionMs >= op.startMs && positionMs < (op.endMs - 1_000) {
                return op
            }
        }

        if let ed = skipTimes.ed, !handledTypes.contains(.ed) {
            if positionMs >= ed.startMs && positionMs < (ed.endMs - 1_000) {
                return ed
            }
        }

        if skipTimesResolved && skipTimes.op == nil && !handledTypes.contains(.op) {
            let safeDur = durationMs
            let skipMs = Int64(max(30, fallbackSkipSeconds)) * 1000
            if safeDur >= fallbackMinEpisodeMs &&
                positionMs >= fallbackOpStartMs &&
                positionMs <= fallbackOpMaxWindowMs {
                let target = min(positionMs + skipMs, max(0, safeDur - 5_000))
                if target > positionMs + 5_000 {
                    return SkipSegment(
                        type: .op,
                        startMs: fallbackOpStartMs,
                        endMs: target,
                        isExact: false
                    )
                }
            }
        }

        return nil
    }

    public static func resolveSkipAction(
        segment: SkipSegment,
        currentPositionMs: Int64,
        durationMs: Int64,
        fallbackSkipSeconds: Int,
        hasNextEpisode: Bool
    ) -> SkipAction {
        let targetMs: Int64
        if segment.isExact {
            targetMs = segment.endMs
        } else {
            let deltaMs = Int64(max(30, fallbackSkipSeconds)) * 1000
            targetMs = currentPositionMs + deltaMs
        }

        let clampedTarget = durationMs > 0
            ? min(max(0, targetMs), max(0, durationMs - 500))
            : max(0, targetMs)

        if segment.type == .ed &&
            hasNextEpisode &&
            durationMs > 0 &&
            (durationMs - clampedTarget) <= nextEpisodeThresholdFromEndMs {
            return SkipAction(
                kind: .nextEpisode,
                targetPositionMs: clampedTarget,
                feedbackLabel: "Next Episode"
            )
        }

        let label = segment.type == .op ? "Skipped Opening" : "Skipped Ending"
        return SkipAction(
            kind: .seekToTarget,
            targetPositionMs: clampedTarget,
            feedbackLabel: label
        )
    }
}
