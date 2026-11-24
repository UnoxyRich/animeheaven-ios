import SwiftUI
import AnimeHeavenCore

struct CatalogView: View {
    @State var viewModel: CatalogViewModel
    let imageCache: ImageCacheManager
    let isRootTab: Bool
    let seasonLabel: String?
    let onOpenAnime: (String) -> Void
    let onOpenSeasonal: () -> Void
    let onOpenSearch: () -> Void
    let onOpenRandom: () -> Void
    let onOpenSettings: () -> Void

    @Environment(\.ahPalette) private var palette
    private let gridColumns = [GridItem(.adaptive(minimum: 112, maximum: 165), spacing: 12)]

    var body: some View {
        ZStack {
            AhScreenBackground()

            if viewModel.isLoading && viewModel.items.isEmpty {
                AhLoadingView()
            } else if let error = viewModel.errorMessage, viewModel.items.isEmpty {
                AhErrorView(message: error) {
                    viewModel.load(forceRefresh: true)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(viewModel.title)
                                .font(.title3.weight(.bold))
                                .foregroundStyle(palette.textPrimary)
                            Spacer()
                            if !viewModel.kind.isGridPage {
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
                        }
                        .padding(.horizontal, 16)

                        if viewModel.viewMode == .list && !viewModel.kind.isGridPage {
                            LazyVStack(spacing: 10) {
                                ForEach(viewModel.items) { card in
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
                                ForEach(viewModel.items) { card in
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
                    .padding(.vertical, 12)
                }
                .refreshable {
                    await viewModel.refreshAsync()
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(isRootTab ? "" : viewModel.title)
        .toolbar {
            if isRootTab {
                ToolbarItem(placement: .topBarLeading) {
                    AhBrandToolbarTitle(
                        seasonLabel: seasonLabel,
                        onTapSeason: onOpenSeasonal
                    )
                }
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
            if viewModel.items.isEmpty {
                viewModel.load()
            }
        }
    }
}
