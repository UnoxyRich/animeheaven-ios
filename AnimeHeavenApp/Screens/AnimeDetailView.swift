import SwiftUI
import AnimeHeavenCore

struct AnimeDetailView: View {
    @State private var viewModel: DetailViewModel
    private let imageCache: ImageCacheManager
    private let onPlayEpisode: (String, String, String, String) -> Void
    private let onOpenTag: (String) -> Void
    private let onOpenAnime: (String) -> Void

    @Environment(\.ahPalette) private var palette
    @State private var expandSynopsis = false
    private let episodeColumns = [GridItem(.adaptive(minimum: 74, maximum: 110), spacing: 10)]

    init(
        animeId: String,
        container: AppContainer,
        onPlayEpisode: @escaping (String, String, String, String) -> Void,
        onOpenTag: @escaping (String) -> Void,
        onOpenAnime: @escaping (String) -> Void
    ) {
        _viewModel = State(initialValue: DetailViewModel(
            animeId: animeId,
            repository: container.repository,
            preloader: container.preloader
        ))
        self.imageCache = container.imageCacheManager
        self.onPlayEpisode = onPlayEpisode
        self.onOpenTag = onOpenTag
        self.onOpenAnime = onOpenAnime
    }

    var body: some View {
        ZStack {
            AhScreenBackground()

            if viewModel.isLoading && viewModel.detail == nil {
                AhLoadingView()
            } else if let error = viewModel.errorMessage, viewModel.detail == nil {
                AhErrorView(message: error) {
                    viewModel.load(forceRefresh: true)
                }
            } else if let detail = viewModel.detail {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        headerSection(detail: detail)

                        if !detail.synopsis.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(detail.synopsis)
                                    .font(.subheadline)
                                    .foregroundStyle(palette.textSecondary)
                                    .lineLimit(expandSynopsis ? nil : 4)
                                Button(expandSynopsis ? "Show Less" : "Read More") {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        expandSynopsis.toggle()
                                    }
                                }
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(palette.crimson)
                            }
                            .padding(.horizontal, 16)
                        }

                        if !detail.tags.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(detail.tags, id: \.self) { tag in
                                        Button {
                                            onOpenTag(tag)
                                        } label: {
                                            Text(tag)
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(palette.textPrimary)
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 6)
                                                .background(palette.surfaceElevated, in: Capsule())
                                                .overlay(Capsule().stroke(palette.borderSubtle, lineWidth: 1))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal, 16)
                            }
                        }

                        if let countdown = detail.countdownLabel {
                            Label(countdown, systemImage: "clock.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(palette.crimson)
                                .padding(.horizontal, 16)
                        }

                        episodesSection(detail: detail)

                        if !detail.relatedShows.isEmpty {
                            showStrip(title: "Related Shows", shows: detail.relatedShows)
                        }
                        if !detail.similarShows.isEmpty {
                            showStrip(title: "Similar Shows", shows: detail.similarShows)
                        }
                    }
                    .padding(.bottom, 28)
                }
                .refreshable {
                    viewModel.load(forceRefresh: true)
                }
            }
        }
        .navigationTitle(viewModel.detail?.title ?? "Details")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            viewModel.startObserving()
            if viewModel.detail == nil {
                viewModel.load()
            }
        }
        .onDisappear {
            viewModel.stopObserving()
        }
    }

    @ViewBuilder
    private func headerSection(detail: AnimeDetail) -> some View {
        ZStack(alignment: .bottomLeading) {
            if let banner = detail.bannerUrl {
                AhCoverImage(url: banner, targetSize: .heroBanner, imageCache: imageCache)
                    .frame(height: 180)
                    .overlay(
                        LinearGradient(
                            colors: [Color.black.opacity(0.25), palette.background],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            } else {
                Rectangle()
                    .fill(palette.surfaceElevated)
                    .frame(height: 110)
            }

            HStack(alignment: .bottom, spacing: 14) {
                AhCoverImage(url: detail.posterUrl, targetSize: .detailPoster, imageCache: imageCache)
                    .frame(width: 108, height: 156)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.borderSubtle, lineWidth: 1))

                VStack(alignment: .leading, spacing: 6) {
                    Text(detail.title)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(3)

                    if !detail.japaneseTitle.isEmpty {
                        Text(detail.japaneseTitle)
                            .font(.caption)
                            .foregroundStyle(palette.textMuted)
                            .lineLimit(2)
                    }

                    HStack(spacing: 12) {
                        metaBadge(label: "EP", value: detail.episodesLabel)
                        metaBadge(label: "YEAR", value: detail.year)
                        metaBadge(label: "SCORE", value: detail.score)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 48)
        }

        HStack(spacing: 10) {
            if let target = viewModel.primaryAction {
                Button {
                    onPlayEpisode(target.episodeKey, detail.id, detail.title, detail.posterUrl)
                } label: {
                    Label(target.buttonLabel, systemImage: "play.fill")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(palette.crimson, in: RoundedRectangle(cornerRadius: 12))
                }
            }

            Button {
                viewModel.toggleBookmark()
            } label: {
                Image(systemName: viewModel.isBookmarked ? "bookmark.fill" : "bookmark")
                    .font(.headline)
                    .foregroundStyle(viewModel.isBookmarked ? palette.crimson : palette.textPrimary)
                    .padding(12)
                    .background(palette.surfaceElevated, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.borderSubtle, lineWidth: 1))
            }
        }
        .padding(.horizontal, 16)
    }

    private func metaBadge(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(palette.textMuted)
            Text(value)
                .font(.caption.weight(.bold))
                .foregroundStyle(palette.textPrimary)
        }
    }

    @ViewBuilder
    private func episodesSection(detail: AnimeDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Episodes (\(detail.episodes.count))")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(palette.textPrimary)
                Spacer()
                Button {
                    viewModel.toggleSortOrder()
                } label: {
                    Label(
                        viewModel.sortOldestFirst ? "Oldest First" : "Newest First",
                        systemImage: "arrow.up.arrow.down"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(palette.surfaceElevated, in: Capsule())
                }
            }
            .padding(.horizontal, 16)

            LazyVGrid(columns: episodeColumns, spacing: 10) {
                ForEach(viewModel.displayedEpisodes) { ep in
                    let progress = viewModel.progressMap[ep.key]
                    let isWatched = progress?.isWatched == true
                    let frac: Double = {
                        guard let p = progress, p.durationMs > 0 else { return 0 }
                        return min(1.0, max(0.0, Double(p.positionMs) / Double(p.durationMs)))
                    }()

                    Button {
                        onPlayEpisode(ep.key, detail.id, detail.title, detail.posterUrl)
                    } label: {
                        VStack(spacing: 4) {
                            Text("Ep \(ep.numberLabel)")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(isWatched ? palette.textMuted : palette.textPrimary)
                                .lineLimit(1)
                            if !ep.releaseAge.isEmpty {
                                Text(ep.releaseAge)
                                    .font(.caption2)
                                    .foregroundStyle(palette.textMuted)
                                    .lineLimit(1)
                            }
                            if frac > 0.02 {
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(palette.borderSubtle)
                                        Capsule()
                                            .fill(isWatched ? palette.positiveGreen : palette.crimson)
                                            .frame(width: geo.size.width * frac)
                                    }
                                }
                                .frame(height: 3)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                        .background(palette.surface, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(isWatched ? palette.positiveGreen.opacity(0.45) : palette.borderSubtle, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private func showStrip(title: String, shows: [AnimeCard]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(palette.textPrimary)
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(shows) { show in
                        Button {
                            onOpenAnime(show.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                AhCoverImage(
                                    url: show.coverUrl,
                                    targetSize: .popularCard,
                                    imageCache: imageCache
                                )
                                .frame(width: 112, height: 152)
                                .clipShape(RoundedRectangle(cornerRadius: 10))

                                Text(show.title)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(palette.textPrimary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .frame(width: 112, alignment: .leading)
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
