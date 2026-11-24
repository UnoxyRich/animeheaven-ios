import Foundation
import MediaPlayer

@MainActor
final class NowPlayingBridge {
    private var commandTokens: [(MPRemoteCommand, Any)] = []
    private struct MetadataState: Equatable {
        let title: String
        let duration: Double
        let rate: Float
    }
    private var lastState: MetadataState?

    func bindRemoteCommands(
        skipSeconds: Int,
        onPlay: @escaping @MainActor () -> Void,
        onPause: @escaping @MainActor () -> Void,
        onToggle: @escaping @MainActor () -> Void,
        onSeekDelta: @escaping @MainActor (Double) -> Void
    ) {
        clearRemoteCommands()
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        commandTokens.append((center.playCommand, center.playCommand.addTarget { _ in
            Task { @MainActor in onPlay() }
            return .success
        }))

        center.pauseCommand.isEnabled = true
        commandTokens.append((center.pauseCommand, center.pauseCommand.addTarget { _ in
            Task { @MainActor in onPause() }
            return .success
        }))

        center.togglePlayPauseCommand.isEnabled = true
        commandTokens.append((center.togglePlayPauseCommand, center.togglePlayPauseCommand.addTarget { _ in
            Task { @MainActor in onToggle() }
            return .success
        }))

        center.skipForwardCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: skipSeconds)]
        commandTokens.append((center.skipForwardCommand, center.skipForwardCommand.addTarget { _ in
            Task { @MainActor in onSeekDelta(Double(skipSeconds)) }
            return .success
        }))

        center.skipBackwardCommand.isEnabled = true
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipSeconds)]
        commandTokens.append((center.skipBackwardCommand, center.skipBackwardCommand.addTarget { _ in
            Task { @MainActor in onSeekDelta(-Double(skipSeconds)) }
            return .success
        }))
    }

    func updateMetadata(
        title: String,
        episodeLabel: String,
        positionSec: Double,
        durationSec: Double,
        playbackRate: Float,
        force: Bool = false
    ) {
        let state = MetadataState(
            title: episodeLabel.isEmpty ? title : "\(title) • \(episodeLabel)",
            duration: durationSec,
            rate: playbackRate
        )
        guard force || state != lastState else { return }
        lastState = state
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: state.title,
            MPMediaItemPropertyArtist: "AnimeHeaven",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, positionSec),
            MPNowPlayingInfoPropertyPlaybackRate: playbackRate
        ]
        if durationSec > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = durationSec
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func clearRemoteCommands() {
        for (command, token) in commandTokens {
            command.removeTarget(token)
            command.isEnabled = false
        }
        commandTokens.removeAll()
        lastState = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}
