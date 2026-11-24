import SwiftUI

/// Adaptive iOS Liquid Glass material modifier:
/// - Uses Apple's native `.glassEffect(.regular.interactive(), in:)` when compiled with Xcode 26 / iOS 26 SDK.
/// - Renders a refractive `.ultraThinMaterial` + diagonal specular white rim highlight + floating depth shadow on Xcode 16 / iOS 17-18.
struct LiquidGlassModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let interactive: Bool
    @Environment(\.ahPalette) private var palette

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            fallbackGlass(content)
        }
        #else
        fallbackGlass(content)
        #endif
    }

    private func fallbackGlass(_ content: Content) -> some View {
        content
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(
                        LinearGradient(
                            stops: [
                                .init(
                                    color: palette.isLight
                                        ? Color.white.opacity(0.42)
                                        : Color.white.opacity(0.14),
                                    location: 0.0
                                ),
                                .init(
                                    color: palette.isLight
                                        ? Color.white.opacity(0.14)
                                        : Color.black.opacity(0.28),
                                    location: 0.55
                                ),
                                .init(
                                    color: palette.isLight
                                        ? Color.white.opacity(0.24)
                                        : Color.black.opacity(0.38),
                                    location: 1.0
                                )
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                }
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: Color.white.opacity(palette.isLight ? 0.85 : 0.46), location: 0.0),
                            .init(color: Color.white.opacity(palette.isLight ? 0.30 : 0.10), location: 0.48),
                            .init(color: Color.white.opacity(palette.isLight ? 0.55 : 0.24), location: 1.0)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.0
                )
            }
            .shadow(color: Color.black.opacity(palette.isLight ? 0.14 : 0.45), radius: 16, x: 0, y: 8)
    }
}

extension View {
    func liquidGlass<S: InsettableShape>(in shape: S, interactive: Bool = true) -> some View {
        modifier(LiquidGlassModifier(shape: shape, interactive: interactive))
    }
}

/// Floating iOS 26-style Liquid Glass capsule bottom navigation dock.
struct FloatingLiquidGlassTabBar: View {
    @Binding var selectedTab: AppTab
    @Environment(\.ahPalette) private var palette
    @Namespace private var activeLensNamespace

    private struct TabItemMeta {
        let tab: AppTab
        let title: String
        let icon: String
        let accessibilityId: String
    }

    private let items: [TabItemMeta] = [
        TabItemMeta(tab: .home, title: "Schedule", icon: "calendar", accessibilityId: "tab.schedule"),
        TabItemMeta(tab: .newReleases, title: "New", icon: "sparkles", accessibilityId: "tab.new"),
        TabItemMeta(tab: .popular, title: "Popular", icon: "flame.fill", accessibilityId: "tab.popular"),
        TabItemMeta(tab: .bookmarks, title: "Bookmarks", icon: "bookmark.fill", accessibilityId: "tab.bookmarks")
    ]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items, id: \.tab) { item in
                let isSelected = selectedTab == item.tab
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                        selectedTab = item.tab
                    }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.icon)
                            .font(.system(size: 18, weight: isSelected ? .bold : .medium))
                        Text(item.title)
                            .font(.system(size: 10, weight: isSelected ? .bold : .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(
                        isSelected
                            ? (palette.isLight ? palette.crimson : Color.white)
                            : palette.textSecondary.opacity(0.75)
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background {
                        if isSelected {
                            Capsule()
                                .fill(
                                    palette.isLight
                                        ? palette.crimson.opacity(0.14)
                                        : Color.white.opacity(0.18)
                                )
                                .overlay(
                                    Capsule()
                                        .strokeBorder(
                                            LinearGradient(
                                                colors: [
                                                    Color.white.opacity(palette.isLight ? 0.75 : 0.42),
                                                    Color.white.opacity(0.06)
                                                ],
                                                startPoint: .top,
                                                endPoint: .bottom
                                            ),
                                            lineWidth: 0.8
                                        )
                                )
                                .matchedGeometryEffect(id: "liquidGlassActiveTabLens", in: activeLensNamespace)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title)
                .accessibilityIdentifier(item.accessibilityId)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .liquidGlass(in: Capsule(), interactive: true)
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .background(alignment: .bottom) {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: palette.bottomBackdropColor.opacity(0.78), location: 0.35),
                    .init(color: palette.bottomBackdropColor, location: 0.62),
                    .init(color: palette.bottomBackdropColor, location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)
        }
    }
}
