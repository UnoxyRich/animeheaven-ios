import SwiftUI
import UIKit
import AnimeHeavenCore

public struct AhCoverImage: View {
    public let url: String
    public let targetSize: ImageTargetSize
    public let imageCache: ImageCacheManager
    public var contentMode: ContentMode = .fill

    @Environment(\.ahPalette) private var palette
    @State private var loadedImage: UIImage?

    public init(
        url: String,
        targetSize: ImageTargetSize,
        imageCache: ImageCacheManager,
        contentMode: ContentMode = .fill
    ) {
        self.url = url
        self.targetSize = targetSize
        self.imageCache = imageCache
        self.contentMode = contentMode
    }

    public var body: some View {
        // Render image inside `.overlay` on a flexible Color so `.fill` NEVER expands parent width/height.
        palette.surfaceElevated
            .overlay {
                if let img = loadedImage {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .transition(.opacity.animation(.easeOut(duration: 0.14)))
                }
            }
            .clipped()
            .task(id: "\(url)#\(targetSize.rawValue)") {
                guard !url.isEmpty else {
                    loadedImage = nil
                    return
                }
                loadedImage = await imageCache.image(for: url, targetSize: targetSize)
            }
    }
}
