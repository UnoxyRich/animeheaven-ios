import SwiftUI
import AnimeHeavenCore

/// 2025/2026 Netflix Mobile Top Bar Brand: Condensed bold red "A" monogram + contextual title.
struct AhBrandToolbarTitle: View {
    @Environment(\.ahPalette) private var palette
    let title: String
    let seasonLabel: String?
    let onTapSeason: (() -> Void)?

    init(
        title: String = "For You",
        seasonLabel: String? = nil,
        onTapSeason: (() -> Void)? = nil
    ) {
        self.title = title
        self.seasonLabel = seasonLabel
        self.onTapSeason = onTapSeason
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("A")
                .font(.system(size: 26, weight: .black))
                .foregroundStyle(palette.crimson)

            Text(title)
                .font(.system(size: 19, weight: .heavy))
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1)

            if let seasonLabel, !seasonLabel.isEmpty, let onTapSeason {
                Button(action: onTapSeason) {
                    Text(seasonLabel)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(palette.textPrimary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .liquidGlass(in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Liquid Glass grouped trailing toolbar capsule ([Search | Random | Settings]).
struct AhTopActionButtons: View {
    @Environment(\.ahPalette) private var palette
    let onSearch: () -> Void
    let onRandom: () -> Void
    let onSettings: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onSearch) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
            }
            .accessibilityLabel("Search")
            .accessibilityIdentifier("topbar.search")

            Button(action: onRandom) {
                Image(systemName: "shuffle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
            }
            .accessibilityLabel("Random Anime")
            .accessibilityIdentifier("topbar.random")

            Button(action: onSettings) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
            }
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("topbar.settings")
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 7)
        .liquidGlass(in: Capsule(), interactive: true)
    }
}

/// Netflix Mobile horizontal Liquid Glass category filter pills strip.
struct NetflixCategoryPillStrip: View {
    let seasonLabel: String?
    let onSeasonal: () -> Void
    let onPopular: () -> Void
    let onRandom: () -> Void

    @Environment(\.ahPalette) private var palette

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let seasonLabel, !seasonLabel.isEmpty {
                    pillButton(title: seasonLabel, systemImage: nil, action: onSeasonal)
                }
                pillButton(title: "Top 10", systemImage: "flame.fill", action: onPopular)
                pillButton(title: "Surprise Me", systemImage: "shuffle", action: onRandom)
            }
            .padding(.horizontal, 16)
        }
    }

    private func pillButton(title: String, systemImage: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.caption2.weight(.bold))
                }
                Text(title)
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(palette.textPrimary)
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .liquidGlass(in: Capsule(), interactive: true)
        }
        .buttonStyle(.plain)
    }
}

/// Iconic Netflix Mobile Tall Framed Hero Billboard Card with bounded image, ambient backdrop,
/// dual White Play + Frosted Details buttons, and dedicated non-overlapping bottom page dots.
struct HeroBannerPager: View {
    let banners: [BannerItem]
    let imageCache: ImageCacheManager
    let onSelect: (String) -> Void

    @Environment(\.ahPalette) private var palette
    @Environment(\.scenePhase) private var scenePhase
    @State private var currentIndex: Int = 0

    var body: some View {
        if !banners.isEmpty {
            VStack(spacing: 10) {
                TabView(selection: $currentIndex) {
                    ForEach(Array(banners.enumerated()), id: \.element.id) { idx, banner in
                        ZStack(alignment: .bottom) {
                            LinearGradient(
                                colors: [Color(hex: 0x2B090E), Color(hex: 0x141414)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )

                            AhCoverImage(
                                url: banner.bannerImageUrl,
                                targetSize: .heroBanner,
                                imageCache: imageCache
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0.0),
                                    .init(color: Color.black.opacity(0.18), location: 0.40),
                                    .init(color: Color(hex: 0x0B0B0B).opacity(0.86), location: 0.72),
                                    .init(color: Color(hex: 0x0B0B0B).opacity(0.97), location: 1.0)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )

                            // Top-left featured badge
                            VStack {
                                HStack {
                                    Text("#\(idx + 1) FEATURED")
                                        .font(.system(size: 10, weight: .black))
                                        .tracking(0.6)
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(palette.crimson, in: RoundedRectangle(cornerRadius: 4))
                                    Spacer()
                                }
                                .padding(14)
                                Spacer()
                            }

                            // Centered Netflix editorial metadata & side-by-side CTAs
                            VStack(spacing: 8) {
                                HStack(spacing: 6) {
                                    Text("A")
                                        .font(.system(size: 15, weight: .black))
                                        .foregroundStyle(palette.crimson)
                                    Text("S E R I E S")
                                        .font(.system(size: 10, weight: .bold))
                                        .tracking(2.2)
                                        .foregroundStyle(Color.white.opacity(0.88))
                                }

                                Text(banner.title)
                                    .font(.title2.weight(.heavy))
                                    .foregroundStyle(.white)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)

                                Text("Trending Now  •  Subbed Anime  •  HD")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Color.white.opacity(0.84))

                                HStack(spacing: 10) {
                                    Button {
                                        onSelect(banner.animeId)
                                    } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: "play.fill")
                                                .font(.subheadline)
                                            Text("Play")
                                                .font(.subheadline.weight(.heavy))
                                        }
                                        .foregroundStyle(.black)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 11)
                                        .background(Color.white, in: RoundedRectangle(cornerRadius: 6))
                                    }
                                    .buttonStyle(.plain)

                                    Button {
                                        onSelect(banner.animeId)
                                    } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: "info.circle")
                                                .font(.subheadline.weight(.semibold))
                                            Text("Details")
                                                .font(.subheadline.weight(.bold))
                                        }
                                        .foregroundStyle(.white)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 11)
                                        .background(Color(hex: 0x303030).opacity(0.84), in: RoundedRectangle(cornerRadius: 6))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(Color.white.opacity(0.24), lineWidth: 1)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.top, 4)
                            }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 16)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.white.opacity(0.22), lineWidth: 1)
                        )
                        .padding(.horizontal, 16)
                        .tag(idx)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: 364)

                // Dedicated non-overlapping Netflix capsule page indicator
                if banners.count > 1 {
                    HStack(spacing: 6) {
                        ForEach(0..<banners.count, id: \.self) { idx in
                            Capsule()
                                .fill(idx == currentIndex ? palette.crimson : palette.textMuted.opacity(0.45))
                                .frame(width: idx == currentIndex ? 18 : 6, height: 4)
                                .animation(.easeInOut(duration: 0.2), value: currentIndex)
                        }
                    }
                }
            }
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
                    .font(.title3.weight(.heavy))
                    .foregroundStyle(palette.textPrimary)
                    .padding(.horizontal, 16)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(items) { item in
                            Button {
                                onPlay(item)
                            } label: {
                                VStack(alignment: .leading, spacing: 0) {
                                    ZStack {
                                        AhCoverImage(
                                            url: item.coverUrl,
                                            targetSize: .continueCard,
                                            imageCache: imageCache
                                        )
                                        .frame(width: 204, height: 115)

                                        LinearGradient(
                                            colors: [.clear, Color.black.opacity(0.75)],
                                            startPoint: .center,
                                            endPoint: .bottom
                                        )

                                        // Netflix centered frosted play circle
                                        ZStack {
                                            Circle()
                                                .fill(Color.black.opacity(0.62))
                                                .frame(width: 40, height: 40)
                                            Circle()
                                                .stroke(Color.white, lineWidth: 1.5)
                                                .frame(width: 40, height: 40)
                                            Image(systemName: "play.fill")
                                                .font(.subheadline)
                                                .foregroundStyle(.white)
                                                .offset(x: 1)
                                        }

                                        VStack {
                                            HStack {
                                                Text(item.isNextEpisode ? "UP NEXT • \(item.targetEpisodeLabel)" : "EP \(item.targetEpisodeLabel)")
                                                    .font(.system(size: 10, weight: .heavy))
                                                    .foregroundStyle(.white)
                                                    .padding(.horizontal, 7)
                                                    .padding(.vertical, 3)
                                                    .background(
                                                        item.isNextEpisode ? palette.crimson : Color.black.opacity(0.72),
                                                        in: RoundedRectangle(cornerRadius: 4)
                                                    )
                                                Spacer()
                                            }
                                            .padding(7)
                                            Spacer()
                                            if !item.isNextEpisode && item.progressFraction > 0 {
                                                GeometryReader { geo in
                                                    ZStack(alignment: .leading) {
                                                        Rectangle().fill(Color.white.opacity(0.3))
                                                        Rectangle()
                                                            .fill(palette.crimson)
                                                            .frame(width: geo.size.width * item.progressFraction)
                                                    }
                                                }
                                                .frame(height: 3.5)
                                            }
                                        }
                                    }
                                    .frame(width: 204, height: 115)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.animeTitle)
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(palette.textPrimary)
                                            .lineLimit(1)
                                        Text(item.isNextEpisode ? "Ready to play" : "Resume Episode \(item.targetEpisodeLabel)")
                                            .font(.caption2)
                                            .foregroundStyle(palette.textMuted)
                                            .lineLimit(1)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .frame(width: 204, alignment: .leading)
                                    .background(palette.surface)
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                                )
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

/// Iconic Netflix "Top 10 Popular Today" horizontal swimlane with giant rank numerals & red TOP 10 badge.
struct PopularHorizontalStrip: View {
    let items: [AnimeCard]
    let imageCache: ImageCacheManager
    let onSelect: (String) -> Void
    let onSeeAll: () -> Void

    @Environment(\.ahPalette) private var palette

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("TOP 10")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(palette.crimson, in: RoundedRectangle(cornerRadius: 4))

                    Text("Popular Today")
                        .font(.title3.weight(.heavy))
                        .foregroundStyle(palette.textPrimary)

                    Spacer()

                    Button(action: onSeeAll) {
                        HStack(spacing: 2) {
                            Text("See All")
                            Image(systemName: "chevron.right")
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.textSecondary)
                    }
                }
                .padding(.horizontal, 16)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 10) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { idx, card in
                            let rank = idx + 1
                            Button {
                                onSelect(card.id)
                            } label: {
                                HStack(alignment: .bottom, spacing: 0) {
                                    if rank <= 10 {
                                        Text("\(rank)")
                                            .font(.system(size: rank == 10 ? 54 : 68, weight: .black))
                                            .tracking(-3)
                                            .foregroundStyle(
                                                palette.isLight ? Color.black.opacity(0.22) : Color.white.opacity(0.36)
                                            )
                                            .offset(x: 6, y: 4)
                                    }

                                    ZStack(alignment: .bottomLeading) {
                                        AhCoverImage(
                                            url: card.coverUrl,
                                            targetSize: .popularCard,
                                            imageCache: imageCache
                                        )
                                        .frame(width: 114, height: 164)

                                        LinearGradient(
                                            stops: [
                                                .init(color: .clear, location: 0.0),
                                                .init(color: Color.black.opacity(0.32), location: 0.42),
                                                .init(color: Color.black.opacity(0.84), location: 0.78),
                                                .init(color: Color.black.opacity(0.95), location: 1.0)
                                            ],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )

                                        if rank <= 10 {
                                            VStack {
                                                HStack {
                                                    Spacer()
                                                    VStack(spacing: -1) {
                                                        Text("TOP")
                                                            .font(.system(size: 7, weight: .black))
                                                        Text("10")
                                                            .font(.system(size: 10, weight: .black))
                                                    }
                                                    .foregroundStyle(.white)
                                                    .padding(.horizontal, 4)
                                                    .padding(.vertical, 3)
                                                    .background(palette.crimson)
                                                }
                                                Spacer()
                                            }
                                        }

                                        Text(card.title)
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(.white)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.leading)
                                            .padding(.horizontal, 7)
                                            .padding(.bottom, 7)
                                    }
                                    .frame(width: 114, height: 164)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color.white.opacity(0.14), lineWidth: 1)
                                    )
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
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
                ZStack(alignment: .bottomLeading) {
                    AhCoverImage(
                        url: card.coverUrl,
                        targetSize: .standardCard,
                        imageCache: imageCache
                    )
                    .frame(width: 116, height: 68)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    if !card.episodeLabel.isEmpty {
                        let badgeText = card.rankDirection != nil
                            ? "#\(card.episodeLabel)"
                            : "EP \(card.episodeLabel)"
                        Text(badgeText)
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(palette.crimson, in: RoundedRectangle(cornerRadius: 3))
                            .padding(5)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(card.title)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    if !card.japaneseTitle.isEmpty {
                        Text(card.japaneseTitle)
                            .font(.caption2)
                            .foregroundStyle(palette.textMuted)
                            .lineLimit(1)
                    }

                    HStack(spacing: 8) {
                        RankOrTimerBadge(card: card)
                        if isBookmarked {
                            Image(systemName: "bookmark.fill")
                                .font(.caption2)
                                .foregroundStyle(palette.crimson)
                        }
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.textMuted)
            }
            .padding(8)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.09), lineWidth: 1))
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
                ZStack(alignment: .bottomLeading) {
                    AhCoverImage(
                        url: card.coverUrl,
                        targetSize: .standardCard,
                        imageCache: imageCache
                    )
                    .aspectRatio(0.70, contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )

                    LinearGradient(
                        colors: [.clear, Color.black.opacity(0.76)],
                        startPoint: .center,
                        endPoint: .bottom
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    if !card.episodeLabel.isEmpty {
                        let badgeText = card.rankDirection != nil
                            ? "#\(card.episodeLabel)"
                            : "EP \(card.episodeLabel)"
                        Text(badgeText)
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(palette.crimson, in: RoundedRectangle(cornerRadius: 4))
                            .padding(6)
                    }
                }

                Text(card.title)
                    .font(.caption.weight(.bold))
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
                .font(.caption2.weight(.semibold))
                .foregroundStyle(palette.positiveGreen)
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
                Label("Try Again", systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.heavy))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
