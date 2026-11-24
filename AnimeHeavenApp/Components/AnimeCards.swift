import SwiftUI
import AnimeHeavenCore

struct AhBrandToolbarTitle: View {
    @Environment(\.ahPalette) private var palette
    let seasonLabel: String?
    let onTapSeason: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                Text("A")
                    .foregroundStyle(.white)
                Text("H")
                    .foregroundStyle(palette.crimson)
            }
            .font(.system(size: 16, weight: .heavy))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.black, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(palette.crimson, lineWidth: 1.5)
            )

            if let seasonLabel, !seasonLabel.isEmpty {
                Button(action: onTapSeason) {
                    Text(seasonLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(palette.surfaceElevated, in: Capsule())
                        .overlay(Capsule().stroke(palette.borderSubtle, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct AhTopActionButtons: View {
    @Environment(\.ahPalette) private var palette
    let onSearch: () -> Void
    let onRandom: () -> Void
    let onSettings: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onSearch) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(palette.textPrimary)
            }
            .accessibilityLabel("Search")
            .accessibilityIdentifier("topbar.search")

            Button(action: onRandom) {
                Image(systemName: "shuffle")
                    .foregroundStyle(palette.textPrimary)
            }
            .accessibilityLabel("Random Anime")
            .accessibilityIdentifier("topbar.random")

            Button(action: onSettings) {
                Image(systemName: "gearshape.fill")
                    .foregroundStyle(palette.textPrimary)
            }
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("topbar.settings")
        }
    }
}

struct HeroBannerPager: View {
    let banners: [BannerItem]
    let imageCache: ImageCacheManager
    let onSelect: (String) -> Void

    @Environment(\.ahPalette) private var palette
    @Environment(\.scenePhase) private var scenePhase
    @State private var currentIndex: Int = 0

    var body: some View {
        if !banners.isEmpty {
            TabView(selection: $currentIndex) {
                ForEach(Array(banners.enumerated()), id: \.element.id) { idx, banner in
                    Button {
                        onSelect(banner.animeId)
                    } label: {
                        ZStack(alignment: .bottomLeading) {
                            AhCoverImage(
                                url: banner.bannerImageUrl,
                                targetSize: .heroBanner,
                                imageCache: imageCache
                            )
                            LinearGradient(
                                colors: [.clear, Color.black.opacity(0.85)],
                                startPoint: .center,
                                endPoint: .bottom
                            )
                            VStack(alignment: .leading, spacing: 4) {
                                Text("FEATURED")
                                    .font(.caption2.weight(.heavy))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(palette.crimson, in: Capsule())
                                Text(banner.title)
                                    .font(.headline.weight(.bold))
                                    .foregroundStyle(.white)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                            .padding(14)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .padding(.horizontal, 16)
                    }
                    .buttonStyle(.plain)
                    .tag(idx)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
            .frame(height: 195)
            .task(id: scenePhase) {
                guard scenePhase == .active, banners.count > 1 else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(6))
                    if Task.isCancelled { break }
                    withAnimation(.easeInOut(duration: 0.35)) {
                        currentIndex = (currentIndex + 1) % banners.count
                    }
                }
            }
        }
    }
}

struct ContinueWatchingRow: View {
    let items: [ContinueWatchingItem]
    let imageCache: ImageCacheManager
    let onPlay: (ContinueWatchingItem) -> Void

    @Environment(\.ahPalette) private var palette

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Continue Watching")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(palette.textPrimary)
                    .padding(.horizontal, 16)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(items) { item in
                            Button {
                                onPlay(item)
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    ZStack(alignment: .bottomLeading) {
                                        AhCoverImage(
                                            url: item.coverUrl,
                                            targetSize: .continueCard,
                                            imageCache: imageCache
                                        )
                                        .frame(width: 210, height: 118)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))

                                        LinearGradient(
                                            colors: [.clear, Color.black.opacity(0.75)],
                                            startPoint: .center,
                                            endPoint: .bottom
                                        )
                                        .clipShape(RoundedRectangle(cornerRadius: 10))

                                        HStack {
                                            Image(systemName: "play.fill")
                                                .font(.caption2)
                                            Text(item.isNextEpisode ? "Up Next • \(item.targetEpisodeLabel)" : "Ep \(item.targetEpisodeLabel)")
                                                .font(.caption2.weight(.bold))
                                        }
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(palette.crimson, in: Capsule())
                                        .padding(8)

                                        if !item.isNextEpisode && item.progressFraction > 0 {
                                            GeometryReader { geo in
                                                ZStack(alignment: .leading) {
                                                    Rectangle().fill(Color.white.opacity(0.25))
                                                    Rectangle()
                                                        .fill(palette.crimson)
                                                        .frame(width: geo.size.width * item.progressFraction)
                                                }
                                            }
                                            .frame(height: 3)
                                            .clipShape(Capsule())
                                            .padding(.horizontal, 6)
                                            .padding(.bottom, 2)
                                        }
                                    }

                                    Text(item.animeTitle)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(palette.textPrimary)
                                        .lineLimit(1)
                                        .frame(width: 210, alignment: .leading)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }
}

struct PopularHorizontalStrip: View {
    let items: [AnimeCard]
    let imageCache: ImageCacheManager
    let onSelect: (String) -> Void
    let onSeeAll: () -> Void

    @Environment(\.ahPalette) private var palette

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Popular")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(palette.textPrimary)
                    Spacer()
                    Button(action: onSeeAll) {
                        HStack(spacing: 2) {
                            Text("See All")
                            Image(systemName: "chevron.right")
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.crimson)
                    }
                }
                .padding(.horizontal, 16)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(items) { card in
                            Button {
                                onSelect(card.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    AhCoverImage(
                                        url: card.coverUrl,
                                        targetSize: .popularCard,
                                        imageCache: imageCache
                                    )
                                    .frame(width: 118, height: 158)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(palette.borderSubtle, lineWidth: 1)
                                    )

                                    Text(card.title)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(palette.textPrimary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                        .frame(width: 118, alignment: .leading)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }
}

struct ScheduleListRow: View {
    let card: AnimeCard
    let isBookmarked: Bool
    let imageCache: ImageCacheManager
    let onSelect: () -> Void

    @Environment(\.ahPalette) private var palette

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                AhCoverImage(
                    url: card.coverUrl,
                    targetSize: .standardCard,
                    imageCache: imageCache
                )
                .frame(width: 72, height: 100)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 5) {
                    Text(card.title)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    if !card.japaneseTitle.isEmpty {
                        Text(card.japaneseTitle)
                            .font(.caption)
                            .foregroundStyle(palette.textMuted)
                            .lineLimit(1)
                    }

                    HStack(spacing: 8) {
                        if !card.episodeLabel.isEmpty {
                            Text("Ep \(card.episodeLabel)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(palette.crimson, in: Capsule())
                        }
                        RankOrTimerBadge(card: card)
                        if isBookmarked {
                            Image(systemName: "bookmark.fill")
                                .font(.caption)
                                .foregroundStyle(palette.crimson)
                        }
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.textMuted)
            }
            .padding(10)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.borderSubtle, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

struct ScheduleGridCard: View {
    let card: AnimeCard
    let isBookmarked: Bool
    let imageCache: ImageCacheManager
    let onSelect: () -> Void

    @Environment(\.ahPalette) private var palette

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    AhCoverImage(
                        url: card.coverUrl,
                        targetSize: .standardCard,
                        imageCache: imageCache
                    )
                    .aspectRatio(0.70, contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(palette.borderSubtle, lineWidth: 1)
                    )

                    if !card.episodeLabel.isEmpty {
                        Text(card.episodeLabel)
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(palette.crimson, in: RoundedRectangle(cornerRadius: 6))
                            .padding(6)
                    }
                }

                Text(card.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 4) {
                    RankOrTimerBadge(card: card)
                    if isBookmarked {
                        Spacer()
                        Image(systemName: "bookmark.fill")
                            .font(.caption2)
                            .foregroundStyle(palette.crimson)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }
}

struct RankOrTimerBadge: View {
    let card: AnimeCard
    @Environment(\.ahPalette) private var palette

    var body: some View {
        if let dir = card.rankDirection, let delta = card.rankDelta {
            HStack(spacing: 2) {
                Image(systemName: dir == .up ? "arrow.up" : (dir == .down ? "arrow.down" : "minus"))
                    .font(.caption2.weight(.bold))
                Text(delta)
                    .font(.caption2.weight(.bold))
            }
            .foregroundStyle(dir == .up ? palette.positiveGreen : (dir == .down ? palette.crimson : palette.textSecondary))
        } else if !card.timerOrStatus.isEmpty {
            Text(card.timerOrStatus)
                .font(.caption2)
                .foregroundStyle(palette.textSecondary)
                .lineLimit(1)
        }
    }
}

struct AhLoadingView: View {
    @Environment(\.ahPalette) private var palette

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(palette.crimson)
                .scaleEffect(1.2)
            Text("Loading...")
                .font(.subheadline)
                .foregroundStyle(palette.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AhErrorView: View {
    let message: String
    let onRetry: () -> Void
    @Environment(\.ahPalette) private var palette

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 36))
                .foregroundStyle(palette.crimson)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button(action: onRetry) {
                Label("Retry", systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(palette.crimson, in: Capsule())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
