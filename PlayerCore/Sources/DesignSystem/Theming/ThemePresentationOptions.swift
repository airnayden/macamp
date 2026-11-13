import SwiftUI

/// Accessibility / presentation flags the app shell injects into the design
/// system.
///
/// PlayerCore cannot read AppKit/UIKit accessibility settings (it must not import
/// them), so the macOS / iOS / Widget shell reads
/// `accessibilityReduceTransparency`, `accessibilityReduceMotion` and
/// `colorSchemeContrast` and passes them down. Components and ``ThemeExtractor``
/// honor these instead of querying the platform directly.
public struct ThemePresentationOptions: Sendable, Equatable {
    public var reduceTransparency: Bool
    public var reduceMotion: Bool
    public var increaseContrast: Bool

    public init(
        reduceTransparency: Bool = false,
        reduceMotion: Bool = false,
        increaseContrast: Bool = false
    ) {
        self.reduceTransparency = reduceTransparency
        self.reduceMotion = reduceMotion
        self.increaseContrast = increaseContrast
    }

    public static let `default` = ThemePresentationOptions()
}

public extension EnvironmentValues {
    @Entry var themePresentation: ThemePresentationOptions = .default
}

public extension View {
    /// Injects accessibility presentation flags read by the app shell.
    func themePresentation(_ options: ThemePresentationOptions) -> some View {
        environment(\.themePresentation, options)
    }
}
