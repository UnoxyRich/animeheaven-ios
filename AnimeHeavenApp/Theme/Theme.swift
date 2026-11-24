import SwiftUI
import AnimeHeavenCore

public struct AhThemePalette: Sendable, Equatable {
    public let themeId: AhThemeId
    public let background: Color
    public let gradientColors: [Color]?
    public let surface: Color
    public let surfaceElevated: Color
    public let surfacePressed: Color
    public let crimson: Color
    public let crimsonDark: Color
    public let textPrimary: Color
    public let textSecondary: Color
    public let textMuted: Color
    public let borderSubtle: Color
    public let positiveGreen: Color
    public let isLight: Bool

    private static let cachedPalettes: [AhThemeId: AhThemePalette] = {
        var dict: [AhThemeId: AhThemePalette] = [:]
        for id in AhThemeId.allCases {
            dict[id] = buildPalette(for: id)
        }
        return dict
    }()

    public static func palette(for themeId: AhThemeId) -> AhThemePalette {
        cachedPalettes[themeId] ?? buildPalette(for: .dark)
    }

    private static func buildPalette(for themeId: AhThemeId) -> AhThemePalette {
        let crimson = Color(hex: 0xE50914) // Signature Netflix Red
        let crimsonDark = Color(hex: 0xB20710)
        let green = Color(hex: 0x46D369) // Netflix Match Green

        switch themeId {
        case .dark:
            return AhThemePalette(
                themeId: themeId,
                background: Color(hex: 0x0B0B0B),
                gradientColors: [Color(hex: 0x1E0A0D), Color(hex: 0x0B0B0B), Color(hex: 0x0B0B0B)],
                surface: Color(hex: 0x141414),
                surfaceElevated: Color(hex: 0x1F1F1F),
                surfacePressed: Color(hex: 0x2B2B2B),
                crimson: crimson,
                crimsonDark: crimsonDark,
                textPrimary: .white,
                textSecondary: Color(hex: 0xD2D2D2),
                textMuted: Color(hex: 0x8C8C8C),
                borderSubtle: Color(hex: 0x2A2A2A),
                positiveGreen: green,
                isLight: false
            )
        case .darkIndigo:
            return gradientDark(themeId, Color(hex: 0x2C1231), Color(hex: 0x052031), crimson, crimsonDark, green)
        case .darkGraphite:
            return gradientDark(themeId, Color(hex: 0x232526), Color(hex: 0x414345), crimson, crimsonDark, green)
        case .darkTealPlum:
            return gradientDark(themeId, Color(hex: 0x01534E), Color(hex: 0x5A1C4C), crimson, crimsonDark, green)
        case .darkCrimsonVelvet:
            return gradientDark(themeId, Color(hex: 0x800000), Color(hex: 0x5A1C4C), crimson, crimsonDark, green)
        case .darkMagenta:
            return gradientDark(themeId, Color(hex: 0xAA076B), Color(hex: 0x61045F), crimson, crimsonDark, green)
        case .darkTwilight:
            return gradientDark(themeId, Color(hex: 0x536976), Color(hex: 0x292E49), crimson, crimsonDark, green)
        case .light:
            return AhThemePalette(
                themeId: themeId,
                background: Color(hex: 0xFFFFFF),
                gradientColors: nil,
                surface: Color(hex: 0xF4F4F8),
                surfaceElevated: Color(hex: 0xEAEAF0),
                surfacePressed: Color(hex: 0xDFDFE8),
                crimson: crimson,
                crimsonDark: crimsonDark,
                textPrimary: Color(hex: 0x141414),
                textSecondary: Color(hex: 0x4A4A52),
                textMuted: Color(hex: 0x767680),
                borderSubtle: Color(hex: 0xDCDCE4),
                positiveGreen: Color(hex: 0x1E9E56),
                isLight: true
            )
        }
    }

    private static func gradientDark(
        _ id: AhThemeId,
        _ start: Color,
        _ end: Color,
        _ crimson: Color,
        _ crimsonDark: Color,
        _ green: Color
    ) -> AhThemePalette {
        AhThemePalette(
            themeId: id,
            background: start,
            gradientColors: [start, end],
            surface: Color.black.opacity(0.42),
            surfaceElevated: Color.black.opacity(0.58),
            surfacePressed: Color.white.opacity(0.14),
            crimson: crimson,
            crimsonDark: crimsonDark,
            textPrimary: .white,
            textSecondary: Color.white.opacity(0.82),
            textMuted: Color.white.opacity(0.58),
            borderSubtle: Color.white.opacity(0.14),
            positiveGreen: green,
            isLight: false
        )
    }
}

public extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}

private struct AhPaletteEnvironmentKey: EnvironmentKey {
    static let defaultValue: AhThemePalette = .palette(for: .dark)
}

public extension EnvironmentValues {
    var ahPalette: AhThemePalette {
        get { self[AhPaletteEnvironmentKey.self] }
        set { self[AhPaletteEnvironmentKey.self] = newValue }
    }
}

public struct AhScreenBackground: View {
    @Environment(\.ahPalette) private var palette

    public init() {}

    public var body: some View {
        Group {
            if let colors = palette.gradientColors {
                LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
            } else {
                palette.background
            }
        }
        .ignoresSafeArea()
    }
}
