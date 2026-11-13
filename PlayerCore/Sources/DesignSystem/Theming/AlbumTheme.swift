import SwiftUI

/// A theme derived from a piece of album artwork: a dominant accent, a
/// contrasting foreground, and a complementary background.
///
/// Produced off the main thread by ``ThemeExtractor`` and cached by
/// ``contentHash``. Apply it onto base ``DesignTokens`` with ``applied(to:)`` to
/// recolor a whole UI subtree around the currently-playing art.
public struct AlbumTheme: Sendable, Equatable, Hashable {
    public var accent: ColorValue
    public var onAccent: ColorValue
    public var background: ThemeBackground
    public var isDark: Bool
    public var contentHash: String

    public init(
        accent: ColorValue,
        onAccent: ColorValue,
        background: ThemeBackground,
        isDark: Bool,
        contentHash: String
    ) {
        self.accent = accent
        self.onAccent = onAccent
        self.background = background
        self.isDark = isDark
        self.contentHash = contentHash
    }

    /// Returns a copy of `tokens` with its accent replaced by this theme's
    /// art-derived accent (and matching `onAccent`/muted variants).
    public func applied(to tokens: DesignTokens) -> DesignTokens {
        var result = tokens
        result.colors.accent = AdaptiveColor(accent)
        result.colors.accentMuted = AdaptiveColor(accent.opacity(0.18))
        result.colors.onAccent = AdaptiveColor(onAccent)
        return result
    }
}

public extension EnvironmentValues {
    @Entry var albumTheme: AlbumTheme?
}

public extension View {
    /// Injects the current album theme (or `nil` to clear it).
    func albumTheme(_ theme: AlbumTheme?) -> some View {
        environment(\.albumTheme, theme)
    }
}
