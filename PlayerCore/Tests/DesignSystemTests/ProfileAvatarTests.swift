// Locks the ``ProfileAvatarPreset`` contract that todos 14/15/16 render against:
// exactly 12 presets, stable unique ids, the migration default id present, and a
// forward-compatible fallback when a stored `avatarId` is unknown to this build.
//
// The default id (`"waveform-vice"`) is a hard contract with the v12 migration
// (`profile.avatarId TEXT NOT NULL DEFAULT 'waveform-vice'`) — it must never drift.
//
// It ALSO pins every preset's gradient to exact sRGB values. Preset avatars are
// stable identities a listener picked once, so their colors are frozen art, not
// theme-following tokens. Nine of them used to read the retired `red` / `orange` /
// `cyan` / `pink` accent palettes, deleted when MacAMP collapsed to a single
// skin; re-pointing any of them at a surviving palette would silently
// restyle existing profiles while passing every identity/count assertion above.
@testable import DesignSystem
import Testing

@Suite("ProfileAvatarTests")
struct ProfileAvatarTests {
    @Test("There are exactly 12 presets")
    func caseCountIsTwelve() {
        #expect(ProfileAvatarPreset.allCases.count == 12)
    }

    @Test("Preset ids are unique")
    func idsAreUnique() {
        let ids = ProfileAvatarPreset.allCases.map(\.id)
        #expect(Set(ids).count == ProfileAvatarPreset.allCases.count)
    }

    @Test("id equals rawValue and round-trips")
    func idRoundTrips() {
        for preset in ProfileAvatarPreset.allCases {
            #expect(preset.id == preset.rawValue)
            #expect(ProfileAvatarPreset(rawValue: preset.rawValue) == preset)
            #expect(ProfileAvatarPreset(id: preset.rawValue) == preset)
        }
    }

    @Test("The migration default id is present and stable")
    func defaultIdPresent() {
        #expect(ProfileAvatarPreset.default == .waveformVice)
        #expect(ProfileAvatarPreset.waveformVice.rawValue == "waveform-vice")
        #expect(ProfileAvatarPreset.allCases.contains(.default))
        #expect(ProfileAvatarPreset(rawValue: "waveform-vice") == .waveformVice)
    }

    @Test("Unknown ids fall back to the default preset")
    func unknownIdFallsBackToDefault() {
        #expect(ProfileAvatarPreset(id: "nonexistent") == .waveformVice)
        #expect(ProfileAvatarPreset(id: "nonexistent") == .default)
        #expect(ProfileAvatarPreset(id: "") == .default)
        #expect(ProfileAvatarPreset(rawValue: "nonexistent") == nil)
    }

    @Test("Every preset exposes a non-empty accessibility label")
    func everyPresetHasAccessibilityLabel() {
        for preset in ProfileAvatarPreset.allCases {
            let resolved = String(localized: preset.accessibilityLabel)
            #expect(!resolved.isEmpty)
        }
    }

    @Test("Every preset gradient renders the exact frozen colors", arguments: ProfileAvatarPreset.allCases)
    func gradientStopsAreFrozen(preset: ProfileAvatarPreset) throws {
        let expected = try #require(Self.frozenGradients[preset])
        #expect(preset.gradient.start == expected.start)
        #expect(preset.gradient.end == expected.end)
    }

    @Test("Every preset is covered by the frozen-gradient table")
    func gradientTableIsExhaustive() {
        #expect(Set(Self.frozenGradients.keys) == Set(ProfileAvatarPreset.allCases))
    }

    // MARK: Frozen appearance

    private static func hex(_ light: UInt32, _ dark: UInt32) -> AdaptiveColor {
        AdaptiveColor(light: ColorValue(hex: light), dark: ColorValue(hex: dark))
    }

    private static func rgb(_ red: Double, _ green: Double, _ blue: Double) -> AdaptiveColor {
        AdaptiveColor(ColorValue(red: red, green: green, blue: blue))
    }

    private static let neonCyan = rgb(0.39, 0.82, 1.0)
    private static let neonPurple = rgb(0.68, 0.35, 1.0)
    private static let skinAccent = hex(0xD70060, 0xFF2975)
    private static let baseAccent = hex(0x5B3FE0, 0x7C5CFF)
    private static let baseWarning = hex(0x9A6700, 0xFFD60A)
    private static let baseSuccess = hex(0x248A3D, 0x30D158)
    private static let avatarRed = hex(0xD70015, 0xFF453A)
    private static let avatarOrange = hex(0xC93400, 0xFF9F0A)
    private static let avatarCyan = hex(0x0091D9, 0x64D2FF)
    private static let avatarPink = hex(0xD63062, 0xFF375F)

    private static let frozenGradients: [ProfileAvatarPreset: AvatarGradient] = [
        .waveformVice: AvatarGradient(start: skinAccent, end: neonCyan),
        .boltSunset: AvatarGradient(start: avatarOrange, end: avatarRed),
        .starGold: AvatarGradient(start: baseWarning, end: avatarOrange),
        .guitarsEmber: AvatarGradient(start: avatarRed, end: baseWarning),
        .headphonesOcean: AvatarGradient(start: avatarCyan, end: baseAccent),
        .micOrchid: AvatarGradient(start: avatarPink, end: neonPurple),
        .pianoNebula: AvatarGradient(start: neonPurple, end: avatarPink),
        .metronomeMint: AvatarGradient(start: baseSuccess, end: avatarCyan),
        .radioSunrise: AvatarGradient(start: baseWarning, end: avatarPink),
        .quaverBerry: AvatarGradient(start: neonPurple, end: avatarCyan),
        .speakerNeon: AvatarGradient(start: rgb(1.0, 0.22, 0.56), end: neonCyan),
        .hifiForest: AvatarGradient(start: baseSuccess, end: baseAccent),
    ]
}
