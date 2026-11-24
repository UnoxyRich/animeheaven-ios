import SwiftUI
import AnimeHeavenCore

/// Stable environment dependency. Each visible artwork view owns its own observable image state.
@MainActor @Observable
final class ArtworkStore {
    let resolver: AnimeArtworkResolver
    private(set) var revision = 0
    private(set) var walkthroughImages: Set<String> = []
    let tracksWalkthroughImages = ProcessInfo.processInfo.arguments.contains("-UITestTrackArtwork")

    init(resolver: AnimeArtworkResolver) { self.resolver = resolver }

    func didClearCache() { revision &+= 1 }

    func recordWalkthroughImage(_ animeId: String, slot: ArtworkSlot) {
        guard tracksWalkthroughImages else { return }
        walkthroughImages.insert(Self.walkthroughImageKey(animeId, slot: slot))
    }

    static func walkthroughImageKey(_ animeId: String, slot: ArtworkSlot) -> String {
        "\(slot.rawValue):\(animeId)"
    }
}

extension EnvironmentValues {
    @Entry var artworkStore: ArtworkStore? = nil
}
