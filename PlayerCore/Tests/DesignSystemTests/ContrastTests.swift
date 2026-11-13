// Protect text contrast on the MacAMP palette while retaining its synthwave hues.
import DesignSystem
import SwiftUI
import Testing

private let palette = ColorPalette.macAMP

/// WCAG 2.1 contrast ratio — `(L_lighter + 0.05) / (L_darker + 0.05)`.
///
/// Ordering the operands by luminance (rather than assuming foreground is darker)
/// is what keeps the result ≥ 1 for any pair, including light-on-dark.
private func contrastRatio(_ foreground: ColorValue, on background: ColorValue) -> Double {
    let lhs = foreground.luminance
    let rhs = background.luminance
    return (max(lhs, rhs) + 0.05) / (min(lhs, rhs) + 0.05)
}

struct TextRoleCase: CustomStringConvertible {
    let name: String
    let token: AdaptiveColor
    let minimumRatio: Double

    var description: String {
        name
    }
}

struct ColorPinCase: CustomStringConvertible {
    let name: String
    let actual: ColorValue
    let expected: ColorValue

    var description: String {
        name
    }
}

/// WCAG AA: 4.5:1 for body text, 3.0:1 for the disabled role (which is
/// deliberately de-emphasised and only needs to stay perceivable).
private let lightTextRoles: [TextRoleCase] = [
    TextRoleCase(name: "textPrimary", token: palette.textPrimary, minimumRatio: 4.5),
    TextRoleCase(name: "textSecondary", token: palette.textSecondary, minimumRatio: 4.5),
    TextRoleCase(name: "textTertiary", token: palette.textTertiary, minimumRatio: 4.5),
    TextRoleCase(name: "textDisabled", token: palette.textDisabled, minimumRatio: 3.0),
]

private let darkPins: [ColorPinCase] = [
    ColorPinCase(name: "canvas", actual: palette.canvas.dark, expected: ColorValue(hex: 0x0D0221)),
    ColorPinCase(name: "surface", actual: palette.surface.dark, expected: ColorValue(hex: 0x1A0533)),
    ColorPinCase(name: "surfaceRaised", actual: palette.surfaceRaised.dark, expected: ColorValue(hex: 0x2A0A45)),
    ColorPinCase(name: "textPrimary", actual: palette.textPrimary.dark, expected: ColorValue(hex: 0xF8F0FF)),
    ColorPinCase(name: "textSecondary", actual: palette.textSecondary.dark, expected: ColorValue(hex: 0x4DE2F0)),
    ColorPinCase(name: "textTertiary", actual: palette.textTertiary.dark, expected: ColorValue(hex: 0xB388D9)),
    ColorPinCase(name: "textDisabled", actual: palette.textDisabled.dark, expected: ColorValue(hex: 0x6A4A8A)),
    ColorPinCase(
        name: "separator",
        actual: palette.separator.dark,
        expected: ColorValue(hex: 0xFF2975, opacity: 0.18)
    ),
    ColorPinCase(name: "accent", actual: palette.accent.dark, expected: ColorValue(hex: 0xFF2975)),
    ColorPinCase(
        name: "accentMuted",
        actual: palette.accentMuted.dark,
        expected: ColorValue(hex: 0xFF2975, opacity: 0.24)
    ),
    ColorPinCase(name: "success", actual: palette.success.dark, expected: ColorValue(hex: 0x2DE2C0)),
    ColorPinCase(name: "warning", actual: palette.warning.dark, expected: ColorValue(hex: 0xFFD60A)),
    ColorPinCase(name: "danger", actual: palette.danger.dark, expected: ColorValue(hex: 0xFF3864)),
]

@Suite("ContrastTests")
struct ContrastTests {
    @Test("filled accent controls have readable text in both schemes", arguments: [ColorScheme.light, .dark])
    func filledAccentText(scheme: ColorScheme) {
        #expect(contrastRatio(palette.onAccent.value(for: scheme), on: palette.accent.value(for: scheme)) >= 4.5)
    }

    @Test("light semantic labels remain readable on every content surface")
    func lightSemanticLabels() {
        for foreground in [palette.accent, palette.success, palette.warning] {
            for background in [palette.canvas, palette.surface, palette.surfaceRaised] {
                #expect(contrastRatio(foreground.light, on: background.light) >= 4.5)
            }
        }
    }

    @Test("light text roles clear their WCAG floor on the canvas", arguments: lightTextRoles)
    func lightTextOnCanvas(role: TextRoleCase) {
        let ratio = contrastRatio(role.token.value(for: .light), on: palette.canvas.value(for: .light))
        #expect(ratio >= role.minimumRatio, "\(role.name) on canvas = \(ratio):1, floor \(role.minimumRatio):1")
    }

    @Test("light text roles clear their WCAG floor on the surface", arguments: lightTextRoles)
    func lightTextOnSurface(role: TextRoleCase) {
        let ratio = contrastRatio(role.token.value(for: .light), on: palette.surface.value(for: .light))
        #expect(ratio >= role.minimumRatio, "\(role.name) on surface = \(ratio):1, floor \(role.minimumRatio):1")
    }

    @Test("dark scheme values are byte-identical to the shipped constants", arguments: darkPins)
    func darkValuesUnchanged(pin: ColorPinCase) {
        #expect(pin.actual == pin.expected)
    }

    /// The two light surface-treatment opacities carry no text, so no ratio test
    /// covers them — they are pinned directly or the raise would be unguarded.
    @Test("light surface treatments keep their raised opacities")
    func lightSurfaceTreatmentOpacities() {
        #expect(palette.separator.light == ColorValue(hex: 0xFF2975, opacity: 0.16))
        #expect(palette.accentMuted.light == ColorValue(hex: 0xD70060, opacity: 0.20))
    }
}
