import SwiftUI
import UIKit
import AnimeHeavenCore

public struct AhCoverImage: View {
    public let url: String
    public let targetSize: ImageTargetSize
    public let imageCache: ImageCacheManager
    private let artwork: ArtworkLookupRequest?
    private let slot: ArtworkSlot
    private let episodeNumber: Int?
    private let nativeLandscapeFirst: Bool
    private let contentMode: ContentMode

    @Environment(\.ahPalette) private var palette
    @Environment(\.artworkStore) private var store
    @State private var loaded: Loaded?

    private struct Loaded {
        let key: String
        let url: String
        let image: UIImage
        let accent: Color?
    }

    public init(url: String, targetSize: ImageTargetSize, imageCache: ImageCacheManager,
                contentMode: ContentMode = .fill, artwork: ArtworkLookupRequest? = nil,
                slot: ArtworkSlot = .landscape16x9, episodeNumber: Int? = nil, nativeLandscapeFirst: Bool = false) {
        self.url = url
        self.targetSize = targetSize
        self.imageCache = imageCache
        self.contentMode = contentMode
        self.artwork = artwork
        self.slot = slot
        self.episodeNumber = episodeNumber
        self.nativeLandscapeFirst = nativeLandscapeFirst
    }

    private var sourceKey: String { "\(artwork?.animeId ?? "")|\(url)|\(slot)|\(targetSize)|\(episodeNumber ?? 0)|\(store?.revision ?? 0)" }

    public var body: some View {
        palette.surfaceElevated.overlay {
            if let loaded, loaded.key == sourceKey {
                GeometryReader { proxy in
                    let size = proxy.size
                    let image = Image(uiImage: loaded.image).resizable()
                    let ambient = ArtworkSmartFit.needsAmbient(
                        imageRatio: Double(loaded.image.size.width / loaded.image.size.height),
                        frameRatio: Double(size.width / size.height)
                    )
                    if ambient {
                        ZStack {
                            image.scaledToFill()
                                .frame(width: size.width, height: size.height)
                                .clipped()
                                .blur(radius: 18)
                            (loaded.accent ?? .black).opacity(0.45)
                            image.scaledToFit().frame(width: size.width, height: size.height)
                        }
                    } else {
                        let alignment = Alignment(horizontal: .center, vertical: .center)
                        image.aspectRatio(contentMode: contentMode)
                            .alignmentGuide(VerticalAlignment.center) { dimensions in
                                let excess = max(0, dimensions.height - size.height)
                                return dimensions.height / 2 - (slot == .portrait2x3 && contentMode == .fill ? excess * 0.1 : 0)
                            }
                            .frame(width: size.width, height: size.height, alignment: alignment)
                    }
                }
                .id(loaded.url)
                .transition(.opacity)
            }
        }
        .accessibilityHidden(true)
        .clipped()
        .task(id: "\(sourceKey):\(artwork?.priority.rawValue ?? 0)") {
            guard let resolver = store?.resolver, let artwork else {
                await display(nil)
                return
            }
            let updates = await resolver.updates(for: artwork)
            async let enriched = resolver.resolve(artwork, slot: slot)
            let initial = Task { @MainActor in
                await display(await resolver.cached(artwork), initialOnly: true)
            }
            defer { initial.cancel() }
            for await value in updates { await display(value) }
            _ = await enriched
        }
    }

    @MainActor
    private func display(_ artwork: AnimeArtwork?, initialOnly: Bool = false) async {
        let urls = (artwork ?? AnimeArtwork()).urls(for: slot, episodeNumber: episodeNumber,
            fallbackUrl: url, nativeLandscapeFirst: nativeLandscapeFirst)
        for candidate in urls {
            if Task.isCancelled || initialOnly && loaded?.key == sourceKey { return }
            if loaded?.key == sourceKey && loaded?.url == candidate { return }
            if let image = await imageCache.image(for: candidate, targetSize: targetSize) {
                guard !Task.isCancelled else { return }
                if initialOnly && loaded?.key == sourceKey { return }
                let color = artwork?.accentColorHex.flatMap { UInt32($0.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) }
                withAnimation(.easeOut(duration: 0.18)) {
                    loaded = Loaded(key: sourceKey, url: candidate, image: image, accent: color.map { Color(hex: $0) })
                }
                let ratio = image.size.width / image.size.height
                let ratioMatchesSlot = slot == .portrait2x3 ? (0.45...0.9).contains(ratio) : (1.15...2.48).contains(ratio)
                if let lookup = self.artwork, ratioMatchesSlot {
                    store?.recordWalkthroughImage(lookup.animeId, slot: slot)
                }
                return
            }
        }
    }
}
