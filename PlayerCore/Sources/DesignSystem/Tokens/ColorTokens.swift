import SwiftUI

/// An sRGB color stored as pure `Sendable` component data.
///
/// Colors are kept as raw components (not a stored `SwiftUI.Color`) so token
/// values are trivially `Sendable`/`Hashable` and can cross actor boundaries
/// (e.g. out of ``ThemeExtractor``) without relying on framework conformances.
public struct ColorValue: Sendable, Equatable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var opacity: Double

    public init(red: Double, green: Double, blue: Double, opacity: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.opacity = opacity
    }

    public init(hex: UInt32, opacity: Double = 1) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }

    public var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
    }

    public func opacity(_ value: Double) -> ColorValue {
        ColorValue(red: red, green: green, blue: blue, opacity: value)
    }

    /// Relative luminance (WCAG-style), used to choose contrasting foregrounds.
    public var luminance: Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    public var isDark: Bool {
        luminance < 0.5
    }
}

/// A color with distinct light- and dark-scheme variants.
///
/// Resolved against the SwiftUI `\.colorScheme` environment at the point of use,
/// giving cross-platform adaptive color without AppKit/UIKit dynamic providers.
public struct AdaptiveColor: Sendable, Equatable, Hashable {
    public var light: ColorValue
    public var dark: ColorValue

    public init(light: ColorValue, dark: ColorValue) {
        self.light = light
        self.dark = dark
    }

    public init(_ both: ColorValue) {
        light = both
        dark = both
    }

    public func value(for scheme: ColorScheme) -> ColorValue {
        scheme == .dark ? dark : light
    }

    public func resolve(_ scheme: ColorScheme) -> Color {
        value(for: scheme).color
    }
}

/// Semantic color tokens. Every surface, label and accent in the design system
/// resolves through one of these — components never embed a literal color.
public struct ColorPalette: Sendable, Equatable {
    public var canvas: AdaptiveColor
    public var surface: AdaptiveColor
    public var surfaceRaised: AdaptiveColor
    public var textPrimary: AdaptiveColor
    public var textSecondary: AdaptiveColor
    public var textTertiary: AdaptiveColor
    public var textDisabled: AdaptiveColor
    public var separator: AdaptiveColor
    public var accent: AdaptiveColor
    public var accentMuted: AdaptiveColor
    public var onAccent: AdaptiveColor
    public var success: AdaptiveColor
    public var warning: AdaptiveColor
    public var danger: AdaptiveColor

    public init(
        canvas: AdaptiveColor,
        surface: AdaptiveColor,
        surfaceRaised: AdaptiveColor,
        textPrimary: AdaptiveColor,
        textSecondary: AdaptiveColor,
        textTertiary: AdaptiveColor,
        textDisabled: AdaptiveColor = AdaptiveColor(
            light: ColorValue(hex: 0xA0A0A8),
            dark: ColorValue(hex: 0x5A5A63)
        ),
        separator: AdaptiveColor,
        accent: AdaptiveColor,
        accentMuted: AdaptiveColor,
        onAccent: AdaptiveColor,
        success: AdaptiveColor,
        warning: AdaptiveColor,
        danger: AdaptiveColor
    ) {
        self.canvas = canvas
        self.surface = surface
        self.surfaceRaised = surfaceRaised
        self.textPrimary = textPrimary
        self.textSecondary = textSecondary
        self.textTertiary = textTertiary
        self.textDisabled = textDisabled
        self.separator = separator
        self.accent = accent
        self.accentMuted = accentMuted
        self.onAccent = onAccent
        self.success = success
        self.warning = warning
        self.danger = danger
    }
}

/// Spectrum visualizer neon accent colors.
public struct SpectrumColors: Sendable, Equatable {
    public static let neonPink = ColorValue(red: 1.0, green: 0.22, blue: 0.56)
    public static let neonCyan = ColorValue(red: 0.39, green: 0.82, blue: 1.0)
    public static let neonPurple = ColorValue(red: 0.68, green: 0.35, blue: 1.0)
}

public extension ColorPalette {
    static func withAccent(dark accent: ColorValue, light accentLight: ColorValue) -> ColorPalette {
        let base = ColorPalette.standard
        let muted = AdaptiveColor(
            light: ColorValue(red: accentLight.red, green: accentLight.green, blue: accentLight.blue, opacity: 0.14),
            dark: ColorValue(red: accent.red, green: accent.green, blue: accent.blue, opacity: 0.22)
        )
        return ColorPalette(
            canvas: base.canvas,
            surface: base.surface,
            surfaceRaised: base.surfaceRaised,
            textPrimary: base.textPrimary,
            textSecondary: base.textSecondary,
            textTertiary: base.textTertiary,
            separator: base.separator,
            accent: AdaptiveColor(light: accentLight, dark: accent),
            accentMuted: muted,
            onAccent: base.onAccent,
            success: base.success,
            warning: base.warning,
            danger: base.danger
        )
    }

    /// The neutral base every other palette derives from. **Load-bearing** — it is
    /// the base of ``withAccent(dark:light:)`` and of `DesignTokens.standard`, and
    /// several fixed component gradients read its `warning` / `success` / `accent`
    /// roles directly. Never delete it.
    static let standard = ColorPalette(
        canvas: AdaptiveColor(light: ColorValue(hex: 0xF2F2F6), dark: ColorValue(hex: 0x08080C)),
        surface: AdaptiveColor(light: ColorValue(hex: 0xFBFBFD), dark: ColorValue(hex: 0x131319)),
        surfaceRaised: AdaptiveColor(light: ColorValue(hex: 0xFFFFFF), dark: ColorValue(hex: 0x1E1E28)),
        textPrimary: AdaptiveColor(light: ColorValue(hex: 0x0E0E14), dark: ColorValue(hex: 0xF5F5F7)),
        textSecondary: AdaptiveColor(light: ColorValue(hex: 0x55555F), dark: ColorValue(hex: 0xA8A8B3)),
        textTertiary: AdaptiveColor(light: ColorValue(hex: 0x6A6A74), dark: ColorValue(hex: 0x8A8A96)),
        textDisabled: AdaptiveColor(light: ColorValue(hex: 0xA0A0A8), dark: ColorValue(hex: 0x5A5A63)),
        separator: AdaptiveColor(
            light: ColorValue(hex: 0x14141A, opacity: 0.10),
            dark: ColorValue(hex: 0xFFFFFF, opacity: 0.10)
        ),
        accent: AdaptiveColor(light: ColorValue(hex: 0x5B3FE0), dark: ColorValue(hex: 0x7C5CFF)),
        accentMuted: AdaptiveColor(
            light: ColorValue(hex: 0x5B3FE0, opacity: 0.14),
            dark: ColorValue(hex: 0x7C5CFF, opacity: 0.22)
        ),
        onAccent: AdaptiveColor(light: ColorValue(hex: 0xFFFFFF), dark: ColorValue(hex: 0xFFFFFF)),
        success: AdaptiveColor(light: ColorValue(hex: 0x248A3D), dark: ColorValue(hex: 0x30D158)),
        warning: AdaptiveColor(light: ColorValue(hex: 0x9A6700), dark: ColorValue(hex: 0xFFD60A)),
        danger: AdaptiveColor(light: ColorValue(hex: 0xD70015), dark: ColorValue(hex: 0xFF453A))
    )

    /// MacAMP's one shipped skin: neon-lit synthwave over deep purple.
    static let macAMP = ColorPalette(
        canvas: AdaptiveColor(light: ColorValue(hex: 0xFFF0F5), dark: ColorValue(hex: 0x0D0221)),
        surface: AdaptiveColor(light: ColorValue(hex: 0xFFE8F0), dark: ColorValue(hex: 0x1A0533)),
        surfaceRaised: AdaptiveColor(light: ColorValue(hex: 0xFFFFFF), dark: ColorValue(hex: 0x2A0A45)),
        textPrimary: AdaptiveColor(light: ColorValue(hex: 0x1A0533), dark: ColorValue(hex: 0xF8F0FF)),
        textSecondary: AdaptiveColor(light: ColorValue(hex: 0x006286), dark: ColorValue(hex: 0x4DE2F0)),
        textTertiary: AdaptiveColor(light: ColorValue(hex: 0x6E4193), dark: ColorValue(hex: 0xB388D9)),
        textDisabled: AdaptiveColor(light: ColorValue(hex: 0x8A63AC), dark: ColorValue(hex: 0x6A4A8A)),
        separator: AdaptiveColor(
            light: ColorValue(hex: 0xFF2975, opacity: 0.16),
            dark: ColorValue(hex: 0xFF2975, opacity: 0.18)
        ),
        accent: AdaptiveColor(light: ColorValue(hex: 0xC90059), dark: ColorValue(hex: 0xFF2975)),
        accentMuted: AdaptiveColor(
            light: ColorValue(hex: 0xD70060, opacity: 0.20),
            dark: ColorValue(hex: 0xFF2975, opacity: 0.24)
        ),
        onAccent: AdaptiveColor(light: ColorValue(hex: 0xFFFFFF), dark: ColorValue(hex: 0x1A0533)),
        success: AdaptiveColor(light: ColorValue(hex: 0x006B56), dark: ColorValue(hex: 0x2DE2C0)),
        warning: AdaptiveColor(light: ColorValue(hex: 0x806600), dark: ColorValue(hex: 0xFFD60A)),
        danger: AdaptiveColor(light: ColorValue(hex: 0xD70030), dark: ColorValue(hex: 0xFF3864))
    )
}
