import SwiftUI
import AnimeHeavenCore

public enum AppTab: Hashable {
    case home
    case newReleases
    case popular
    case bookmarks
}

public enum AppDestination: Hashable {
    case detail(animeId: String)
    case seasonal(path: String, label: String)
    case tag(String)
    case search
    case settings
}

public struct PlayerPresentation: Identifiable, Hashable {
    public let id = UUID()
    public let episodeKey: String
    public let animeId: String
    public let animeTitle: String
    public let coverUrl: String

    public init(episodeKey: String, animeId: String, animeTitle: String, coverUrl: String) {
        self.episodeKey = episodeKey
        self.animeId = animeId
        self.animeTitle = animeTitle
        self.coverUrl = coverUrl
    }
}

struct RootTabView: View {
    let container: AppContainer
    @Environment(\.ahPalette) private var palette

    @State private var selectedTab: AppTab = .home
    @State private var homePath = NavigationPath()
    @State private var newPath = NavigationPath()
    @State private var popularPath = NavigationPath()
    @State private var bookmarksPath = NavigationPath()
    @State private var activePlayer: PlayerPresentation?
    @State private var isResolvingRandom = false

    @State private var homeVM: HomeViewModel
    @State private var newVM: CatalogViewModel
    @State private var popularVM: CatalogViewModel
    @State private var bookmarksVM: BookmarksViewModel

    init(container: AppContainer) {
        self.container = container
        _homeVM = State(initialValue: HomeViewModel(
            repository: container.repository,
            settingsStore: container.settingsStore,
            preloader: container.preloader
        ))
        _newVM = State(initialValue: CatalogViewModel(
            kind: .newReleases,
            repository: container.repository,
            settingsStore: container.settingsStore,
            preloader: container.preloader
        ))
        _popularVM = State(initialValue: CatalogViewModel(
            kind: .popular,
            repository: container.repository,
            settingsStore: container.settingsStore,
            preloader: container.preloader
        ))
        _bookmarksVM = State(initialValue: BookmarksViewModel(repository: container.repository))
    }

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                NavigationStack(path: $homePath) {
                    HomeView(
                        viewModel: homeVM,
                        imageCache: container.imageCacheManager,
                        onOpenAnime: { push(.detail(animeId: $0)) },
                        onPlayContinue: { openContinue($0) },
                        onOpenPopular: { selectedTab = .popular },
                        onOpenSeasonal: { path, label in push(.seasonal(path: path, label: label)) },
                        onOpenSearch: { push(.search) },
                        onOpenRandom: { openRandom() },
                        onOpenSettings: { push(.settings) }
                    )
                    .navigationDestination(for: AppDestination.self) { destinationView($0) }
                }
                .tabItem { Label("Schedule", systemImage: "calendar") }
                .tag(AppTab.home)

                NavigationStack(path: $newPath) {
                    CatalogView(
                        viewModel: newVM,
                        imageCache: container.imageCacheManager,
                        isRootTab: true,
                        seasonLabel: homeVM.feed?.seasonLabel,
                        onOpenAnime: { push(.detail(animeId: $0)) },
                        onOpenSeasonal: { openCurrentSeason() },
                        onOpenSearch: { push(.search) },
                        onOpenRandom: { openRandom() },
                        onOpenSettings: { push(.settings) }
                    )
                    .navigationDestination(for: AppDestination.self) { destinationView($0) }
                }
                .tabItem { Label("New", systemImage: "sparkles") }
                .tag(AppTab.newReleases)

                NavigationStack(path: $popularPath) {
                    CatalogView(
                        viewModel: popularVM,
                        imageCache: container.imageCacheManager,
                        isRootTab: true,
                        seasonLabel: homeVM.feed?.seasonLabel,
                        onOpenAnime: { push(.detail(animeId: $0)) },
                        onOpenSeasonal: { openCurrentSeason() },
                        onOpenSearch: { push(.search) },
                        onOpenRandom: { openRandom() },
                        onOpenSettings: { push(.settings) }
                    )
                    .navigationDestination(for: AppDestination.self) { destinationView($0) }
                }
                .tabItem { Label("Popular", systemImage: "flame.fill") }
                .tag(AppTab.popular)

                NavigationStack(path: $bookmarksPath) {
                    BookmarksView(
                        viewModel: bookmarksVM,
                        imageCache: container.imageCacheManager,
                        seasonLabel: homeVM.feed?.seasonLabel,
                        onOpenAnime: { push(.detail(animeId: $0)) },
                        onPlayContinue: { openContinue($0) },
                        onOpenSeasonal: { openCurrentSeason() },
                        onOpenSearch: { push(.search) },
                        onOpenRandom: { openRandom() },
                        onOpenSettings: { push(.settings) }
                    )
                    .navigationDestination(for: AppDestination.self) { destinationView($0) }
                }
                .tabItem { Label("Bookmarks", systemImage: "bookmark.fill") }
                .tag(AppTab.bookmarks)
            }
            .tint(palette.crimson)

            if isResolvingRandom {
                Color.black.opacity(0.45).ignoresSafeArea()
                ProgressView("Finding random anime...")
                    .padding(20)
                    .background(palette.surfaceElevated, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(palette.textPrimary)
            }
        }
        .fullScreenCover(item: $activePlayer) { presentation in
            PlayerView(
                presentation: presentation,
                container: container,
                onDismiss: { activePlayer = nil }
            )
            .environment(\.ahPalette, palette)
        }
    }

    @ViewBuilder
    private func destinationView(_ destination: AppDestination) -> some View {
        switch destination {
        case .detail(let animeId):
            AnimeDetailView(
                animeId: animeId,
                container: container,
                onPlayEpisode: { key, aId, title, cover in
                    activePlayer = PlayerPresentation(
                        episodeKey: key,
                        animeId: aId,
                        animeTitle: title,
                        coverUrl: cover
                    )
                },
                onOpenTag: { push(.tag($0)) },
                onOpenAnime: { push(.detail(animeId: $0)) }
            )
        case .seasonal(let path, let label):
            CatalogView(
                viewModel: CatalogViewModel(
                    kind: .seasonal(path: path, label: label),
                    repository: container.repository,
                    settingsStore: container.settingsStore,
                    preloader: container.preloader
                ),
                imageCache: container.imageCacheManager,
                isRootTab: false,
                seasonLabel: nil,
                onOpenAnime: { push(.detail(animeId: $0)) },
                onOpenSeasonal: {},
                onOpenSearch: { push(.search) },
                onOpenRandom: { openRandom() },
                onOpenSettings: { push(.settings) }
            )
        case .tag(let tag):
            CatalogView(
                viewModel: CatalogViewModel(
                    kind: .tag(tag),
                    repository: container.repository,
                    settingsStore: container.settingsStore,
                    preloader: container.preloader
                ),
                imageCache: container.imageCacheManager,
                isRootTab: false,
                seasonLabel: nil,
                onOpenAnime: { push(.detail(animeId: $0)) },
                onOpenSeasonal: {},
                onOpenSearch: { push(.search) },
                onOpenRandom: { openRandom() },
                onOpenSettings: { push(.settings) }
            )
        case .search:
            SearchView(
                container: container,
                onOpenAnime: { push(.detail(animeId: $0)) }
            )
        case .settings:
            SettingsView(container: container)
        }
    }

    private func push(_ destination: AppDestination) {
        switch selectedTab {
        case .home: homePath.append(destination)
        case .newReleases: newPath.append(destination)
        case .popular: popularPath.append(destination)
        case .bookmarks: bookmarksPath.append(destination)
        }
    }

    private func openContinue(_ item: ContinueWatchingItem) {
        activePlayer = PlayerPresentation(
            episodeKey: item.targetEpisodeKey,
            animeId: item.animeId,
            animeTitle: item.animeTitle,
            coverUrl: item.coverUrl
        )
    }

    private func openCurrentSeason() {
        let path = homeVM.feed?.seasonPath ?? "2025fall.php"
        let label = homeVM.feed?.seasonLabel ?? "Season"
        push(.seasonal(path: path, label: label))
    }

    private func openRandom() {
        guard !isResolvingRandom else { return }
        isResolvingRandom = true
        Task {
            defer { isResolvingRandom = false }
            if let randomId = try? await container.repository.getRandomAnimeId() {
                push(.detail(animeId: randomId))
            }
        }
    }
}
