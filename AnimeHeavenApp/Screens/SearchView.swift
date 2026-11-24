import SwiftUI
import AnimeHeavenCore

struct SearchView: View {
    @State private var viewModel: SearchViewModel
    private let imageCache: ImageCacheManager
    private let onOpenAnime: (String) -> Void

    @Environment(\.ahPalette) private var palette
    @FocusState private var searchFocused: Bool
    private let gridColumns = [GridItem(.adaptive(minimum: 112, maximum: 165), spacing: 12)]

    init(container: AppContainer, onOpenAnime: @escaping (String) -> Void) {
        _viewModel = State(initialValue: SearchViewModel(
            gateway: RepositorySearchGateway(repository: container.repository),
            preloader: container.preloader
        ))
        self.imageCache = container.imageCacheManager
        self.onOpenAnime = onOpenAnime
    }

    var body: some View {
        ZStack {
            AhScreenBackground()

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(palette.textMuted)
                    TextField("Search anime titles...", text: Binding(
                        get: { viewModel.query },
                        set: { viewModel.onQueryChanged($0) }
                    ))
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .foregroundStyle(palette.textPrimary)
                    .onSubmit {
                        viewModel.submitFullSearch()
                    }

                    if !viewModel.query.isEmpty {
                        Button {
                            viewModel.clearQuery()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(palette.textMuted)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(palette.surfaceElevated, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.borderSubtle, lineWidth: 1))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                contentBody
            }
        }
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.loadRecentSearches()
            searchFocused = true
        }
    }

    @ViewBuilder
    private var contentBody: some View {
        if viewModel.isLoading {
            AhLoadingView()
        } else if let err = viewModel.errorMessage {
            AhErrorView(message: err) {
                viewModel.submitFullSearch()
            }
        } else if viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !viewModel.recentSearches.isEmpty {
                        Text("Recent Searches")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(palette.textSecondary)
                            .padding(.horizontal, 16)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(viewModel.recentSearches, id: \.self) { term in
                                    HStack(spacing: 6) {
                                        Button(term) {
                                            viewModel.submitFullSearch(term)
                                        }
                                        .font(.subheadline)
                                        .foregroundStyle(palette.textPrimary)

                                        Button {
                                            viewModel.deleteRecent(term)
                                        } label: {
                                            Image(systemName: "xmark")
                                                .font(.caption2)
                                                .foregroundStyle(palette.textMuted)
                                        }
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(palette.surfaceElevated, in: Capsule())
                                    .overlay(Capsule().stroke(palette.borderSubtle, lineWidth: 1))
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    } else {
                        ContentUnavailableView(
                            "Search AnimeHeaven",
                            systemImage: "magnifyingglass",
                            description: Text("Type at least 2 characters for live matches or tap Search for full results.")
                        )
                        .foregroundStyle(palette.textSecondary)
                        .padding(.top, 48)
                    }
                }
                .padding(.top, 8)
            }
        } else if viewModel.isFullSearchMode {
            if viewModel.fullResults.isEmpty {
                ContentUnavailableView.search(text: viewModel.query)
                    .foregroundStyle(palette.textSecondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(viewModel.fullResultsTitle)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(palette.textSecondary)
                            .padding(.horizontal, 16)

                        LazyVGrid(columns: gridColumns, spacing: 12) {
                            ForEach(viewModel.fullResults) { card in
                                ScheduleGridCard(
                                    card: card,
                                    isBookmarked: false,
                                    imageCache: imageCache,
                                    onSelect: { onOpenAnime(card.id) }
                                )
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.vertical, 8)
                }
            }
        } else {
            if viewModel.fastResults.isEmpty {
                ContentUnavailableView(
                    "No Instant Matches",
                    systemImage: "magnifyingglass",
                    description: Text("Press Search on the keyboard to run a full catalog query.")
                )
                .foregroundStyle(palette.textSecondary)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(viewModel.fastResults) { item in
                            Button {
                                onOpenAnime(item.animeId)
                            } label: {
                                HStack(spacing: 12) {
                                    AhCoverImage(
                                        url: item.coverUrl,
                                        targetSize: .searchThumb,
                                        imageCache: imageCache
                                    )
                                    .frame(width: 56, height: 76)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))

                                    Text(item.title)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(palette.textPrimary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)

                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(palette.textMuted)
                                }
                                .padding(10)
                                .background(palette.surface, in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.borderSubtle, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
        }
    }
}
