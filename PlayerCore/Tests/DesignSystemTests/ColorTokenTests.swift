// Locks the three neon spectrum tokens (Task 8) to their EXACT stored sRGB
// components. Task 8 extracted them verbatim from the three hardcoded
// `Color(red:green:blue:)` literals in `macOS/Sources/InlineSpectrumView.swift`;
// any drift here is a visual regression in the spectrum bars.
//
// These assert the raw ``ColorValue`` components directly — NOT an
// environment-resolved `SwiftUI.Color` — so the check is free of colorspace /
// float-rounding drift. Exact `==` is correct: the token and the expected value
// are written as the SAME Double source literals, so they share one IEEE-754 bit
// pattern (this is a byte-identity assertion, not an approximate colour match).
import DesignSystem
import Testing

@Suite("ColorTokenTests")
struct ColorTokenTests {
    @Test("neonPink stored components are exactly (1.0, 0.22, 0.56)")
    func neonPinkExactComponents() {
        let token = SpectrumColors.neonPink
        #expect(token.red == 1.0)
        #expect(token.green == 0.22)
        #expect(token.blue == 0.56)
        #expect(token.opacity == 1.0)
    }

    @Test("neonCyan stored components are exactly (0.39, 0.82, 1.0)")
    func neonCyanExactComponents() {
        let token = SpectrumColors.neonCyan
        #expect(token.red == 0.39)
        #expect(token.green == 0.82)
        #expect(token.blue == 1.0)
        #expect(token.opacity == 1.0)
    }

    @Test("neonPurple stored components are exactly (0.68, 0.35, 1.0)")
    func neonPurpleExactComponents() {
        let token = SpectrumColors.neonPurple
        #expect(token.red == 0.68)
        #expect(token.green == 0.35)
        #expect(token.blue == 1.0)
        #expect(token.opacity == 1.0)
    }
}
