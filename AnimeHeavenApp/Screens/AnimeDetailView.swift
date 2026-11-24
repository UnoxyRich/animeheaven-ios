import SwiftUI
import AnimeHeavenCore

struct AnimeDetailView: View {
    @StateObject private var modelStorage: ViewModelStorage<DetailViewModel>
    private var viewModel: DetailViewModel { modelStorage.value }
    private let imageCache: ImageCacheManager
    private let onPlayEpisode: (String, String, String, String) -> Void
    private let onOpenTag: (String) -> Void
    private let onOpenAnime: (String) -> Void

    @Environment(\.ahPalette) private var palette
    @State private var expandSynopsis = false
    private let episodeColumns = [GridItem(.adaptive(minimum: 78, maximum: 114), spacing: 10)]

    init(
        animeId: String,
        container: AppContainer,
        onPlayEpisode: @escaping (String, String, String, String) -> Void,
        onOpenTag: @escaping (String) -> Void,
        onOpenAnime: @escaping (String) -> Void
    ) {
        _modelStorage = StateObject(wrappedValue: ViewModelStorage(DetailViewModel(
            animeId: animeId,
            repository: container.repository,
            preloader: container.preloader
        )))
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
                                .font(.caption.weight(.bold))
                                .foregroundStyle(palette.textPrimary)
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
                                                .foregroundStyle(palette.textSecondary)
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
                                .font(.caption.weight(.bold))
                                .foregroundStyle(palette.positiveGreen)
                                .padding(.horizontal, 16)
                        }

                        episodesSection(detail: detail)

                        if !detail.relatedShows.isEmpty {
                            showStrip(title: "Related Shows", shows: detail.relatedShows)
                        }
                        if !detail.similarShows.isEmpty {
                            showStrip(title: "More Like This", shows: detail.similarShows)
                        }
                    }
                    .padding(.bottom, 28)
                }
                .refreshable {
                    await viewModel.refreshAsync()
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
        // Full-bleed Netflix hero backdrop
        ZStack(alignment: .bottomLeading) {
            AhCoverImage(
                url: detail.landscapeCoverUrl ?? detail.bannerUrl ?? detail.posterUrl,
                targetSize: .detailHero,
                imageCache: imageCache,
                artwork: .init(animeId: detail.id, title: detail.title, japaneseTitle: detail.japaneseTitle,
                               year: Int(detail.year.prefix(4)), priority: .high)
            )
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .frame(maxHeight: 260)
            .frame(maxWidth: .infinity)
            .clipped()
            .overlay(
                LinearGradient(
                    stops: [
                        .init(color: Color.black.opacity(palette.isLight ? 0.08 : 0.22), location: 0.0),
                        .init(color: .clear, location: 0.45),
                        .init(color: Color.black.opacity(palette.isLight ? 0.12 : 0.35), location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0.0),
                        .init(color: .black, location: 0.58),
                        .init(color: .black.opacity(0.55), location: 0.80),
                        .init(color: .clear, location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }

        // Netflix editorial title & metadata block
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("A")
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(palette.crimson)
                Text("S E R I E S")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(2.2)
                    .foregroundStyle(palette.textSecondary)
            }

            Text(detail.title)
                .font(.title2.weight(.heavy))
                .foregroundStyle(palette.textPrimary)
                .lineLimit(3)

            if !detail.japaneseTitle.isEmpty {
                Text(detail.japaneseTitle)
                    .font(.caption)
                    .foregroundStyle(palette.textMuted)
                    .lineLimit(2)
            }

            HStack(spacing: 10) {
                let normalizedScore = detail.score.trimmingCharacters(in: .whitespacesAndNewlines)
                if !normalizedScore.isEmpty && normalizedScore != "?" && normalizedScore.caseInsensitiveCompare("N/A") != .orderedSame {
                    Text("Score \(normalizedScore)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(palette.positiveGreen)
                        .lineLimit(1)
                }
                if !detail.year.isEmpty {
                    Text(detail.year)
                        .font(.caption)
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(1)
                }
                if !detail.episodesLabel.isEmpty {
                    Text("\(detail.episodesLabel) Episodes")
                        .font(.caption)
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(1)
                }
                Text("HD")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(palette.textSecondary.opacity(0.6), lineWidth: 1))
            }

            // Stacked Full-Width Netflix Mobile CTAs
            VStack(spacing: 9) {
                if let target = viewModel.primaryAction {
                    Button {
                        onPlayEpisode(target.episodeKey, detail.id, detail.title, detail.landscapeCoverUrl ?? "")
                    } label: {
                        Label(target.buttonLabel, systemImage: "play.fill")
                            .font(.subheadline.weight(.heavy))
                            .foregroundStyle(palette.isLight ? Color.white : Color.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(palette.isLight ? palette.crimson : Color.white, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    viewModel.toggleBookmark()
                } label: {
                    Label(
                        viewModel.isBookmarked ? "In My List" : "Add to My List",
                        systemImage: viewModel.isBookmarked ? "checkmark" : "plus"
                    )
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(viewModel.isBookmarked ? Color.white : palette.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(
                        viewModel.isBookmarked ? palette.crimson : palette.surfaceElevated,
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(viewModel.isBookmarked ? palette.crimson : palette.borderSubtle, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func episodesSection(detail: AnimeDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Capsule()
                        .fill(palette.crimson)
                        .frame(width: 44, height: 3)
                    Text("Episodes (\(detail.episodes.count))")
                        .font(.title3.weight(.heavy))
                        .foregroundStyle(palette.textPrimary)
                }
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
                    .overlay(Capsule().stroke(palette.borderSubtle, lineWidth: 1))
                }
                .buttonStyle(.plain)
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
                        onPlayEpisode(ep.key, detail.id, detail.title, detail.landscapeCoverUrl ?? "")
                    } label: {
                        VStack(spacing: 4) {
                            Text(isWatched ? "WATCHED" : "EP")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(isWatched ? palette.positiveGreen : palette.textMuted)
                            Text(ep.numberLabel)
                                .font(.headline.weight(.heavy))
                                .foregroundStyle(palette.textPrimary)
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
                                        Capsule().fill(palette.textPrimary.opacity(0.14))
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
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .background(isWatched ? palette.surface : palette.surfaceElevated, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(isWatched ? palette.positiveGreen.opacity(0.45) : palette.borderSubtle, lineWidth: 1)
                        )
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
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
                .font(.title3.weight(.heavy))
                .foregroundStyle(palette.textPrimary)
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 10) {
                    ForEach(shows) { show in
                        Button {
                            onOpenAnime(show.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                AhCoverImage(
                                    url: show.coverUrl,
                                    targetSize: .popularCard,
                                    imageCache: imageCache,
                                    artwork: .init(animeId: show.id, title: show.title, japaneseTitle: show.japaneseTitle),
                                    slot: .portrait2x3
                                )
                                .frame(width: 112, height: 168)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(palette.borderSubtle, lineWidth: 1)
                                )

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
