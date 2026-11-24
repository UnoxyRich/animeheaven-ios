import SwiftUI
import AnimeHeavenCore

/// Stable environment dependency. Each visible artwork view owns its own observable image state.
@MainActor @Observable
final class ArtworkStore {
    let resolver: AnimeArtworkResolver
    private(set) var revision = 0

    init(resolver: AnimeArtworkResolver) { self.resolver = resolver }

    func didClearCache() { revision &+= 1 }
}

extension EnvironmentValues {
    @Entry var artworkStore: ArtworkStore? = nil
}
