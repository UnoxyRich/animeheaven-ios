import SwiftUI
import AnimeHeavenCore

struct CatalogView: View {
    @StateObject private var modelStorage: ViewModelStorage<CatalogViewModel>
    private var viewModel: CatalogViewModel { modelStorage.value }
    let imageCache: ImageCacheManager
    let isRootTab: Bool
    let seasonLabel: String?
    let onOpenAnime: (String) -> Void
    let onOpenSeasonal: () -> Void
    let onOpenSearch: () -> Void
    let onOpenRandom: () -> Void
    let onOpenSettings: () -> Void

    @Environment(\.ahPalette) private var palette
    @Environment(\.artworkStore) private var artworkStore
    private let gridColumns = [GridItem(.adaptive(minimum: 112, maximum: 165), spacing: 12)]

    init(
        viewModel: @autoclosure @escaping @MainActor () -> CatalogViewModel,
        imageCache: ImageCacheManager,
        isRootTab: Bool,
        seasonLabel: String?,
        onOpenAnime: @escaping (String) -> Void,
        onOpenSeasonal: @escaping () -> Void,
        onOpenSearch: @escaping () -> Void,
        onOpenRandom: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        _modelStorage = StateObject(wrappedValue: ViewModelStorage(viewModel()))
        self.imageCache = imageCache
        self.isRootTab = isRootTab
        self.seasonLabel = seasonLabel
        self.onOpenAnime = onOpenAnime
        self.onOpenSeasonal = onOpenSeasonal
        self.onOpenSearch = onOpenSearch
        self.onOpenRandom = onOpenRandom
        self.onOpenSettings = onOpenSettings
    }

    private var sectionSubtitle: String {
        switch viewModel.kind {
        case .popular: return "Ranked by Views"
        case .newReleases: return "Latest Releases"
        case .seasonal: return "Seasonal Releases"
        case .tag: return "Browse by Genre"
        }
    }

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
                            Text(sectionSubtitle)
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
                                        .frame(width: 44, height: 44)
                                        .contentShape(Circle())
                                        .liquidGlass(in: Circle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(viewModel.viewMode == .list ? "Switch to Grid View" : "Switch to List View")
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
                                        isPopularRank: viewModel.kind.isPopularRank,
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
                                        isPopularRank: viewModel.kind.isPopularRank,
                                        onSelect: { onOpenAnime(card.id) }
                                    )
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                    .padding(.top, 12)
                    .padding(.bottom, 20)
                }
                .refreshable {
                    await viewModel.refreshAsync()
                }
            }
        }
        .overlay(alignment: .topLeading) {
            if artworkStore?.tracksWalkthroughImages == true, isRootTab, !viewModel.items.isEmpty {
                let slot: ArtworkSlot = viewModel.viewMode == .list ? .landscape16x9 : .portrait2x3
                let required = viewModel.items.prefix(6).map { ArtworkStore.walkthroughImageKey($0.id, slot: slot) }
                ArtworkWalkthroughStatus(name: viewModel.kind.isPopularRank ? "popular" : "new", required: required)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(isRootTab ? "" : viewModel.title)
        .toolbar(isRootTab ? .hidden : .visible, for: .navigationBar)
        .safeAreaInset(edge: .top, spacing: 0) {
            if isRootTab {
                AhRootNavigationBar(title: viewModel.title, onSearch: onOpenSearch,
                    onRandom: onOpenRandom, onSettings: onOpenSettings)
            }
        }
        .toolbar {
            if !isRootTab {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button(action: onOpenSearch) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(palette.textPrimary)
                    }
                    .accessibilityLabel("Search")
                    .accessibilityIdentifier("topbar.search")

                    Button(action: onOpenRandom) {
                        Image(systemName: "shuffle")
                            .foregroundStyle(palette.textPrimary)
                    }
                    .accessibilityLabel("Random Anime")
                    .accessibilityIdentifier("topbar.random")

                    Button(action: onOpenSettings) {
                        Image(systemName: "gearshape.fill")
                            .foregroundStyle(palette.textPrimary)
                    }
                    .accessibilityLabel("Settings")
                    .accessibilityIdentifier("topbar.settings")
                }
            }
        }
        .onAppear {
            viewModel.startObservingLocalState()
            if viewModel.items.isEmpty {
                viewModel.load()
            }
        }
        .onDisappear {
            viewModel.stopObservingLocalState()
        }
    }
}
