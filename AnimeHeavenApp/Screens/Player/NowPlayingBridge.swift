import Foundation
import MediaPlayer

@MainActor
final class NowPlayingBridge {
    private var commandTokens: [Any] = []

    func bindRemoteCommands(
        onPlay: @escaping @MainActor () -> Void,
        onPause: @escaping @MainActor () -> Void,
        onToggle: @escaping @MainActor () -> Void,
        onSeekDelta: @escaping @MainActor (Double) -> Void
    ) {
        clearRemoteCommands()
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        commandTokens.append(center.playCommand.addTarget { _ in
            Task { @MainActor in onPlay() }
            return .success
        })

        center.pauseCommand.isEnabled = true
        commandTokens.append(center.pauseCommand.addTarget { _ in
            Task { @MainActor in onPause() }
            return .success
        })

        center.togglePlayPauseCommand.isEnabled = true
        commandTokens.append(center.togglePlayPauseCommand.addTarget { _ in
            Task { @MainActor in onToggle() }
            return .success
        })

        center.skipForwardCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = [10]
        commandTokens.append(center.skipForwardCommand.addTarget { _ in
            Task { @MainActor in onSeekDelta(10) }
            return .success
        })

        center.skipBackwardCommand.isEnabled = true
        center.skipBackwardCommand.preferredIntervals = [10]
        commandTokens.append(center.skipBackwardCommand.addTarget { _ in
            Task { @MainActor in onSeekDelta(-10) }
            return .success
        })
    }

    func updateMetadata(
        title: String,
        episodeLabel: String,
        positionSec: Double,
        durationSec: Double,
        isPlaying: Bool
    ) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: episodeLabel.isEmpty ? title : "\(title) • \(episodeLabel)",
            MPMediaItemPropertyArtist: "AnimeHeaven",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, positionSec),
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if durationSec > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = durationSec
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func clearRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.skipForwardCommand.removeTarget(nil)
        center.skipBackwardCommand.removeTarget(nil)
        commandTokens.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}
