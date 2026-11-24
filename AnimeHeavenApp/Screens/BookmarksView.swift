import SwiftUI
import AnimeHeavenCore

struct BookmarksView: View {
    let viewModel: BookmarksViewModel
    let imageCache: ImageCacheManager
    let seasonLabel: String?
    let onOpenAnime: (String) -> Void
    let onPlayContinue: (ContinueWatchingItem) -> Void
    let onOpenSeasonal: () -> Void
    let onOpenSearch: () -> Void
    let onOpenRandom: () -> Void
    let onOpenSettings: () -> Void

    @Environment(\.ahPalette) private var palette
    @State private var confirmClearHistory = false
    private let gridColumns = [GridItem(.adaptive(minimum: 112, maximum: 165), spacing: 12)]

    var body: some View {
        ZStack {
            AhScreenBackground()

            if viewModel.bookmarks.isEmpty && viewModel.continueWatching.isEmpty {
                ContentUnavailableView(
                    "No Bookmarks Yet",
                    systemImage: "bookmark",
                    description: Text("Bookmark anime from any detail screen or start watching episodes to track your progress.")
                )
                .foregroundStyle(palette.textSecondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if !viewModel.continueWatching.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Continue Watching")
                                        .font(.title3.weight(.bold))
                                        .foregroundStyle(palette.textPrimary)
                                    Spacer()
                                    Button("Clear History") {
                                        confirmClearHistory = true
                                    }
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(palette.crimson)
                                }
                                .padding(.horizontal, 16)

                                ContinueWatchingRow(
                                    items: viewModel.continueWatching,
                                    imageCache: imageCache,
                                    onPlay: onPlayContinue
                                )
                            }
                        }

                        if !viewModel.bookmarks.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Bookmarked Anime (\(viewModel.bookmarks.count))")
                                    .font(.title3.weight(.bold))
                                    .foregroundStyle(palette.textPrimary)
                                    .padding(.horizontal, 16)

                                LazyVGrid(columns: gridColumns, spacing: 12) {
                                    ForEach(viewModel.bookmarks) { item in
                                        ZStack(alignment: .topTrailing) {
                                            Button {
                                                onOpenAnime(item.animeId)
                                            } label: {
                                                VStack(alignment: .leading, spacing: 6) {
                                                    AhCoverImage(
                                                        url: item.coverUrl,
                                                        targetSize: .standardCard,
                                                        imageCache: imageCache
                                                    )
                                                    .aspectRatio(0.70, contentMode: .fill)
                                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                                    .overlay(
                                                        RoundedRectangle(cornerRadius: 10)
                                                            .stroke(palette.borderSubtle, lineWidth: 1)
                                                    )

                                                    Text(item.title)
                                                        .font(.caption.weight(.semibold))
                                                        .foregroundStyle(palette.textPrimary)
                                                        .lineLimit(2)
                                                        .multilineTextAlignment(.leading)

                                                    if !item.lastEpisodeLabel.isEmpty {
                                                        Text("Ep \(item.lastEpisodeLabel)")
                                                            .font(.caption2)
                                                            .foregroundStyle(palette.textMuted)
                                                    }
                                                }
                                            }
                                            .buttonStyle(.plain)

                                            Button {
                                                viewModel.removeBookmark(animeId: item.animeId)
                                            } label: {
                                                Image(systemName: "xmark.circle.fill")
                                                    .font(.body)
                                                    .symbolRenderingMode(.palette)
                                                    .foregroundStyle(.white, Color.black.opacity(0.65))
                                                    .padding(6)
                                            }
                                        }
                                    }
                                }
                                .padding(.horizontal, 16)
                            }
                        }
                    }
                    .padding(.top, 12)
                    .padding(.bottom, 92)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                AhBrandToolbarTitle(title: "My Bookmarks")
            }
            ToolbarItem(placement: .topBarTrailing) {
                AhTopActionButtons(
                    onSearch: onOpenSearch,
                    onRandom: onOpenRandom,
                    onSettings: onOpenSettings
                )
            }
        }
        .alert("Clear Watch History?", isPresented: $confirmClearHistory) {
            Button("Clear", role: .destructive) { viewModel.clearWatchHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all saved episode resume positions and Continue Watching items.")
        }
        .onAppear { viewModel.startObserving() }
        .onDisappear { viewModel.stopObserving() }
    }
}
