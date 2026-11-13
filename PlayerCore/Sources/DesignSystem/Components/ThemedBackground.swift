import SwiftUI

/// The app-wide backdrop. Renders the art-derived ``AlbumTheme/background`` when
/// a theme is present (with a soft accent bloom for depth), otherwise the neutral
/// canvas token. The bloom is suppressed under reduce-transparency.
public struct ThemedBackground: View {
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme
    @Environment(\.albumTheme) private var albumTheme
    @Environment(\.themePresentation) private var presentation

    public init() {}

    public var body: some View {
        ZStack {
            if let theme = albumTheme {
                theme.background.shapeStyleView(for: scheme)
                if !presentation.reduceTransparency {
                    RadialGradient(
                        colors: [theme.accent.opacity(0.30).color, .clear],
                        center: .top,
                        startRadius: 0,
                        endRadius: 520
                    )
                    .blendMode(.plusLighter)
                }
            } else {
                tokens.colors.canvas.resolve(scheme)
            }
        }
        .ignoresSafeArea()
    }
}
