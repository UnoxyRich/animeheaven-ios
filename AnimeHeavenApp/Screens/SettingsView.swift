import SwiftUI
import AnimeHeavenCore

struct SettingsView: View {
    let container: AppContainer
    @Environment(\.ahPalette) private var palette

    @State private var cacheSummary: AppContainer.CacheStorageSummary?
    @State private var statusBanner: String?

    var body: some View {
        let settings = container.settingsStore
        ZStack {
            AhScreenBackground()

            Form {
                Section("Appearance") {
                    ForEach(AhThemeId.allCases) { theme in
                        Button {
                            settings.themeId = theme
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(theme.displayName)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(palette.textPrimary)
                                    Text(theme.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(palette.textMuted)
                                }
                                Spacer()
                                if settings.themeId == theme {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(palette.crimson)
                                }
                            }
                        }
                    }

                    Picker("Default Feed View", selection: Binding(
                        get: { settings.defaultViewMode },
                        set: { settings.defaultViewMode = $0 }
                    )) {
                        ForEach(FeedViewMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                }

                Section("Player & Gestures") {
                    Toggle("Auto-Landscape Fullscreen", isOn: Binding(
                        get: { settings.autoLandscapePlayer },
                        set: { settings.autoLandscapePlayer = $0 }
                    ))
                    Toggle("Auto-Play Next Episode", isOn: Binding(
                        get: { settings.autoPlayNext },
                        set: { settings.autoPlayNext = $0 }
                    ))
                    Toggle("Skip OP / ED Prompts", isOn: Binding(
                        get: { settings.skipPromptEnabled },
                        set: { settings.skipPromptEnabled = $0 }
                    ))
                    Picker("Double-Tap Seek Step", selection: Binding(
                        get: { settings.doubleTapSeekSeconds },
                        set: { settings.doubleTapSeekSeconds = $0 }
                    )) {
                        Text("5s").tag(5)
                        Text("10s").tag(10)
                        Text("15s").tag(15)
                    }
                    Picker("Fallback Skip OP Jump", selection: Binding(
                        get: { settings.skipOpSeconds },
                        set: { settings.skipOpSeconds = $0 }
                    )) {
                        Text("75s").tag(75)
                        Text("85s").tag(85)
                        Text("90s").tag(90)
                    }
                }

                Section("Preloading & Network") {
                    Picker("Preload Mode", selection: Binding(
                        get: { settings.preloadMode },
                        set: { settings.preloadMode = $0 }
                    )) {
                        ForEach(PreloadMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    Text(settings.preloadMode.subtitle)
                        .font(.caption)
                        .foregroundStyle(palette.textMuted)
                }

                Section("Storage & Cache") {
                    if let summary = cacheSummary {
                        LabeledContent("Web & Metadata", value: "\(summary.webPages) pages (\(formatBytes(summary.webBytes)))")
                        LabeledContent("Image Cache", value: formatBytes(summary.imageBytes))
                        LabeledContent("Video Chunk Cache", value: formatBytes(summary.videoBytes))
                        LabeledContent("Total", value: formatBytes(summary.totalBytes))
                    } else {
                        ProgressView()
                    }

                    Button("Clear Image Cache", role: .destructive) {
                        Task {
                            await container.imageCacheManager.clearDiskCache()
                            await reloadCacheStats("Cleared image cache")
                        }
                    }
                    Button("Clear Video Cache", role: .destructive) {
                        Task {
                            await container.chunkBooster.clearAll()
                            await reloadCacheStats("Cleared video chunk cache")
                        }
                    }
                    Button("Clear Web & Metadata Cache", role: .destructive) {
                        Task {
                            await container.repository.clearWebCache()
                            await container.preloader.resetSessionMarkers()
                            await reloadCacheStats("Cleared web cache")
                        }
                    }

                    if let statusBanner {
                        Text(statusBanner)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(palette.positiveGreen)
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            cacheSummary = await container.loadCacheSummary()
        }
    }

    private func reloadCacheStats(_ message: String) async {
        statusBanner = message
        cacheSummary = await container.loadCacheSummary()
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }
}
