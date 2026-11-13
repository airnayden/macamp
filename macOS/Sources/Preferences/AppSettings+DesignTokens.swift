// AppSettings+DesignTokens — the theme-preset → design-token mapping.
//
// Split out of `AppSettings.swift` purely for size: that file sits against
// SwiftLint's 400-line `file_length` ceiling (enforced as an error by the `lint`
// CI job's `--strict`), and this 50-line switch is the one self-contained block in
// it that owns no stored state.
//
// Observation is unaffected by the move. `@Observable` instruments STORED
// properties; a computed property reads `themePreset` through that instrumented
// accessor whether it lives in the main body or an extension, so SwiftUI still
// invalidates on a preset change.
import DesignSystem

public extension AppSettings {
    /// The token set the whole shell renders from, derived from ``themePreset``.
    var designTokens: DesignTokens {
        switch themePreset {
        case .macAMP:
            DesignTokens(
                colors: .macAMP,
                spacing: .standard, typography: .standard, radii: .standard, elevation: .standard, motion: .standard
            )
        }
    }
}
