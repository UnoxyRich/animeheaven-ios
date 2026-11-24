import Foundation
import Observation

public struct AppSettings: Sendable, Equatable {
    public var themeId: AhThemeId
    public var defaultViewMode: FeedViewMode
    public var autoPlayNext: Bool
    public var skipOpSeconds: Int
    public var skipPromptEnabled: Bool
    public var doubleTapSeekSeconds: Int
    public var autoLandscapePlayer: Bool
    public var preloadMode: PreloadMode

    public init(
        themeId: AhThemeId = .dark,
        defaultViewMode: FeedViewMode = .list,
        autoPlayNext: Bool = true,
        skipOpSeconds: Int = 85,
        skipPromptEnabled: Bool = true,
        doubleTapSeekSeconds: Int = 10,
        autoLandscapePlayer: Bool = true,
        preloadMode: PreloadMode = .aggressive
    ) {
        self.themeId = themeId
        self.defaultViewMode = defaultViewMode
        self.autoPlayNext = autoPlayNext
        self.skipOpSeconds = skipOpSeconds
        self.skipPromptEnabled = skipPromptEnabled
        self.doubleTapSeekSeconds = doubleTapSeekSeconds
        self.autoLandscapePlayer = autoLandscapePlayer
        self.preloadMode = preloadMode
    }
}

private final class LockedPreloadModeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: PreloadMode

    init(_ initial: PreloadMode) {
        self.value = initial
    }

    func get() -> PreloadMode {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: PreloadMode) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}

@MainActor
@Observable
public final class SettingsStore {
    private enum Keys {
        static let theme = "ah_theme_css_key"
        static let viewMode = "ah_default_view_mode"
        static let autoPlayNext = "ah_auto_play_next"
        static let skipOpSeconds = "ah_skip_op_seconds"
        static let skipPromptEnabled = "ah_skip_prompt_enabled"
        static let doubleTapSeekSeconds = "ah_double_tap_seek_seconds"
        static let autoLandscapePlayer = "ah_auto_landscape_player"
        static let preloadMode = "ah_preload_mode"
    }

    @ObservationIgnored
    private let defaults: UserDefaults
    @ObservationIgnored
    private nonisolated let preloadModeBox: LockedPreloadModeBox

    public var themeId: AhThemeId {
        didSet {
            guard themeId != oldValue else { return }
            defaults.set(themeId.cssKey, forKey: Keys.theme)
        }
    }

    public var defaultViewMode: FeedViewMode {
        didSet {
            guard defaultViewMode != oldValue else { return }
            defaults.set(defaultViewMode.rawValue, forKey: Keys.viewMode)
        }
    }

    public var autoPlayNext: Bool {
        didSet {
            guard autoPlayNext != oldValue else { return }
            defaults.set(autoPlayNext, forKey: Keys.autoPlayNext)
        }
    }

    public var skipOpSeconds: Int {
        didSet {
            guard skipOpSeconds != oldValue else { return }
            defaults.set(skipOpSeconds, forKey: Keys.skipOpSeconds)
        }
    }

    public var skipPromptEnabled: Bool {
        didSet {
            guard skipPromptEnabled != oldValue else { return }
            defaults.set(skipPromptEnabled, forKey: Keys.skipPromptEnabled)
        }
    }

    public var doubleTapSeekSeconds: Int {
        didSet {
            guard doubleTapSeekSeconds != oldValue else { return }
            defaults.set(doubleTapSeekSeconds, forKey: Keys.doubleTapSeekSeconds)
        }
    }

    public var autoLandscapePlayer: Bool {
        didSet {
            guard autoLandscapePlayer != oldValue else { return }
            defaults.set(autoLandscapePlayer, forKey: Keys.autoLandscapePlayer)
        }
    }

    public var preloadMode: PreloadMode {
        didSet {
            guard preloadMode != oldValue else { return }
            defaults.set(preloadMode.rawValue, forKey: Keys.preloadMode)
            preloadModeBox.set(preloadMode)
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let loadedTheme = AhThemeId.fromCssKey(defaults.string(forKey: Keys.theme))
        let loadedViewMode = defaults.string(forKey: Keys.viewMode)
            .flatMap(FeedViewMode.init(rawValue:)) ?? .list
        let loadedAutoPlay = defaults.object(forKey: Keys.autoPlayNext) as? Bool ?? true
        let loadedSkipOp = defaults.object(forKey: Keys.skipOpSeconds) as? Int ?? 85
        let loadedSkipPrompt = defaults.object(forKey: Keys.skipPromptEnabled) as? Bool ?? true
        let loadedDoubleTap = defaults.object(forKey: Keys.doubleTapSeekSeconds) as? Int ?? 10
        let loadedAutoLandscape = defaults.object(forKey: Keys.autoLandscapePlayer) as? Bool ?? true
        let loadedPreload = defaults.string(forKey: Keys.preloadMode)
            .flatMap(PreloadMode.init(rawValue:)) ?? .aggressive

        self.themeId = loadedTheme
        self.defaultViewMode = loadedViewMode
        self.autoPlayNext = loadedAutoPlay
        self.skipOpSeconds = loadedSkipOp
        self.skipPromptEnabled = loadedSkipPrompt
        self.doubleTapSeekSeconds = loadedDoubleTap
        self.autoLandscapePlayer = loadedAutoLandscape
        self.preloadMode = loadedPreload
        self.preloadModeBox = LockedPreloadModeBox(loadedPreload)
    }

    public var snapshot: AppSettings {
        AppSettings(
            themeId: themeId,
            defaultViewMode: defaultViewMode,
            autoPlayNext: autoPlayNext,
            skipOpSeconds: skipOpSeconds,
            skipPromptEnabled: skipPromptEnabled,
            doubleTapSeekSeconds: doubleTapSeekSeconds,
            autoLandscapePlayer: autoLandscapePlayer,
            preloadMode: preloadMode
        )
    }

    public nonisolated func currentPreloadModeNonisolated() -> PreloadMode {
        preloadModeBox.get()
    }
}
