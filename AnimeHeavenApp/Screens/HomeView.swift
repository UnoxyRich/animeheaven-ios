import SwiftUI
import AnimeHeavenCore

struct HomeView: View {
    let viewModel: HomeViewModel
    let imageCache: ImageCacheManager
    let onOpenAnime: (String) -> Void
    let onPlayContinue: (ContinueWatchingItem) -> Void
    let onOpenPopular: () -> Void
    let onOpenSeasonal: (String, String) -> Void
    let onOpenSearch: () -> Void
    let onOpenRandom: () -> Void
    let onOpenSettings: () -> Void

    @Environment(\.ahPalette) private var palette
    private let gridColumns = [GridItem(.adaptive(minimum: 112, maximum: 165), spacing: 12)]

    var body: some View {
        ZStack {
            AhScreenBackground()

            if viewModel.isLoading && viewModel.feed == nil {
                AhLoadingView()
            } else if let error = viewModel.errorMessage, viewModel.feed == nil {
                AhErrorView(message: error) {
                    viewModel.loadHome(forceRefresh: true)
                }
            } else if let feed = viewModel.feed {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        NetflixCategoryPillStrip(
                            seasonLabel: feed.seasonLabel,
                            onSeasonal: {
                                guard let path = feed.seasonPath, !path.isEmpty else { return }
                                let label = feed.seasonLabel ?? "Season"
                                onOpenSeasonal(path, label)
                            },
                            onPopular: onOpenPopular,
                            onRandom: onOpenRandom
                        )

                        HeroBannerPager(
                            banners: feed.banners,
                            imageCache: imageCache,
                            onSelect: onOpenAnime
                        )

                        ContinueWatchingRow(
                            items: viewModel.continueWatching,
                            imageCache: imageCache,
                            onPlay: onPlayContinue
                        )

                        PopularHorizontalStrip(
                            items: feed.popularItems,
                            imageCache: imageCache,
                            onSelect: onOpenAnime,
                            onSeeAll: onOpenPopular
                        )

                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Subbed Schedule")
                                    .font(.title3.weight(.bold))
                                    .foregroundStyle(palette.textPrimary)
                                Spacer()
                                Button {
                                    viewModel.toggleViewMode()
                                } label: {
                                    Image(systemName: viewModel.viewMode == .list ? "square.grid.2x2" : "list.bullet")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(palette.textPrimary)
                                        .padding(8)
                                        .background(palette.surfaceElevated, in: Circle())
                                }
                            }
                            .padding(.horizontal, 16)

                            if viewModel.viewMode == .list {
                                LazyVStack(spacing: 10) {
                                    ForEach(feed.scheduleItems) { card in
                                        ScheduleListRow(
                                            card: card,
                                            isBookmarked: viewModel.bookmarkedIds.contains(card.id),
                                            imageCache: imageCache,
                                            onSelect: { onOpenAnime(card.id) }
                                        )
                                    }
                                }
                                .padding(.horizontal, 16)
                            } else {
                                LazyVGrid(columns: gridColumns, spacing: 12) {
                                    ForEach(feed.scheduleItems) { card in
                                        ScheduleGridCard(
                                            card: card,
                                            isBookmarked: viewModel.bookmarkedIds.contains(card.id),
                                            imageCache: imageCache,
                                            onSelect: { onOpenAnime(card.id) }
                                        )
                                    }
                                }
                                .padding(.horizontal, 16)
                            }
                        }
                    }
                    .padding(.top, 12)
                    .padding(.bottom, 92)
                }
                .refreshable {
                    await viewModel.refreshAsync()
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                AhBrandToolbarTitle(title: "For You")
            }
            ToolbarItem(placement: .topBarTrailing) {
                AhTopActionButtons(
                    onSearch: onOpenSearch,
                    onRandom: onOpenRandom,
                    onSettings: onOpenSettings
                )
            }
        }
        .onAppear {
            viewModel.startObservingLocalState()
            if viewModel.feed == nil {
                viewModel.loadHome()
            }
        }
        .onDisappear {
            viewModel.stopObservingLocalState()
        }
    }
}
