import CoreGraphics
import Foundation
import SwiftUI

/// A preset profile avatar: a fixed SF Symbol paired with a fixed, token-sourced
/// accent gradient. Presets are stable *identities* (like the built-in avatars in
/// a streaming app), so — unlike the rest of the design system — their gradients
/// are intentionally fixed rather than following the injected `\.designTokens`
/// accent. The symbol tint and hairline rim still resolve from the injected theme
/// so the avatar sits correctly in light and dark, matching ``ArtworkView``.
///
/// The `rawValue` IS the stable id persisted as `profile.avatarId`
/// (`ProfileRecord.avatarId`). ``ProfileAvatarPreset/init(id:)`` resolves a stored
/// id back to a preset, falling back to ``ProfileAvatarPreset/default`` for any
/// unknown/renamed id so a forward-migrated database never renders a blank avatar.
///
/// The built-in Guest profile (id 1) stores the migration default
/// (`avatarId DEFAULT 'waveform-vice'`), so Guest resolves to
/// ``ProfileAvatarPreset/default`` (`.waveformVice`) like any never-customized
/// profile — every profile renders uniformly through `init(id:)`, no special case.
public enum ProfileAvatarPreset: String, CaseIterable, Identifiable, Sendable {
    case waveformVice = "waveform-vice"
    case boltSunset = "bolt-sunset"
    case starGold = "star-gold"
    case guitarsEmber = "guitars-ember"
    case headphonesOcean = "headphones-ocean"
    case micOrchid = "mic-orchid"
    case pianoNebula = "piano-nebula"
    case metronomeMint = "metronome-mint"
    case radioSunrise = "radio-sunrise"
    case quaverBerry = "quaver-berry"
    case speakerNeon = "speaker-neon"
    case hifiForest = "hifi-forest"

    public var id: String {
        rawValue
    }

    /// The preset applied for an unknown/renamed stored id and for Guest. Matches
    /// the v12 migration column default (`profile.avatarId DEFAULT 'waveform-vice'`).
    public static let `default`: ProfileAvatarPreset = .waveformVice

    /// Resolves a stored `avatarId` to a preset, falling back to ``default`` for
    /// any id this build does not recognise (forward compatibility).
    public init(id: String) {
        self = ProfileAvatarPreset(rawValue: id) ?? .default
    }
}

// MARK: - Preset rendering data

/// A two-stop gradient built from design-system color tokens.
struct AvatarGradient: Equatable {
    let start: AdaptiveColor
    let end: AdaptiveColor

    func linear(_ scheme: ColorScheme) -> LinearGradient {
        LinearGradient(
            colors: [start.resolve(scheme), end.resolve(scheme)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

/// The fixed rendering data for one ``ProfileAvatarPreset``.
struct AvatarPresetSpec {
    let symbolName: String
    let gradient: AvatarGradient
    let accessibilityLabel: LocalizedStringResource

    /// Also the fallback for any unknown preset (see ``ProfileAvatarPreset/init(id:)``).
    static let fallback = AvatarPresetSpec(
        symbolName: "waveform",
        gradient: AvatarGradient(start: .avatarViceAccent, end: .neonCyan),
        accessibilityLabel: LocalizedStringResource(
            "profiles.avatar.waveformVice",
            defaultValue: "Waveform Vice",
            comment: "Accessibility label for the waveform profile avatar preset"
        )
    )
}

private extension AdaptiveColor {
    static let neonPink = AdaptiveColor(SpectrumColors.neonPink)
    static let neonCyan = AdaptiveColor(SpectrumColors.neonCyan)
    static let neonPurple = AdaptiveColor(SpectrumColors.neonPurple)

    // Frozen avatar-gradient stops. These carry the exact accents of the four
    // retired `red` / `orange` / `cyan` / `pink` theme palettes, deleted when
    // MacAMP collapsed to a single skin. Preset gradients are stable identities, so
    // the values are pinned here rather than re-pointed at a surviving palette —
    // re-pointing would silently restyle every existing profile's avatar.
    static let avatarViceAccent = AdaptiveColor(light: ColorValue(hex: 0xD70060), dark: ColorValue(hex: 0xFF2975))
    static let avatarRed = AdaptiveColor(light: ColorValue(hex: 0xD70015), dark: ColorValue(hex: 0xFF453A))
    static let avatarOrange = AdaptiveColor(light: ColorValue(hex: 0xC93400), dark: ColorValue(hex: 0xFF9F0A))
    static let avatarCyan = AdaptiveColor(light: ColorValue(hex: 0x0091D9), dark: ColorValue(hex: 0x64D2FF))
    static let avatarPink = AdaptiveColor(light: ColorValue(hex: 0xD63062), dark: ColorValue(hex: 0xFF375F))
}

extension ProfileAvatarPreset {
    /// SF Symbol drawn at the center of the avatar.
    var symbolName: String {
        resolvedSpec.symbolName
    }

    /// Fixed accent gradient filling the avatar circle.
    var gradient: AvatarGradient {
        resolvedSpec.gradient
    }

    /// Localized VoiceOver label describing the preset.
    public var accessibilityLabel: LocalizedStringResource {
        resolvedSpec.accessibilityLabel
    }

    private var resolvedSpec: AvatarPresetSpec {
        Self.specs[self] ?? .fallback
    }

    private static let specs: [ProfileAvatarPreset: AvatarPresetSpec] = [
        .waveformVice: .fallback,
        .boltSunset: AvatarPresetSpec(
            symbolName: "bolt.fill",
            gradient: AvatarGradient(start: .avatarOrange, end: .avatarRed),
            accessibilityLabel: LocalizedStringResource(
                "profiles.avatar.boltSunset",
                defaultValue: "Lightning Bolt",
                comment: "Accessibility label for the lightning-bolt profile avatar preset"
            )
        ),
        .starGold: AvatarPresetSpec(
            symbolName: "star.fill",
            gradient: AvatarGradient(start: ColorPalette.standard.warning, end: .avatarOrange),
            accessibilityLabel: LocalizedStringResource(
                "profiles.avatar.starGold",
                defaultValue: "Gold Star",
                comment: "Accessibility label for the gold-star profile avatar preset"
            )
        ),
        .guitarsEmber: AvatarPresetSpec(
            symbolName: "guitars.fill",
            gradient: AvatarGradient(start: .avatarRed, end: ColorPalette.standard.warning),
            accessibilityLabel: LocalizedStringResource(
                "profiles.avatar.guitarsEmber",
                defaultValue: "Ember Guitars",
                comment: "Accessibility label for the guitars profile avatar preset"
            )
        ),
        .headphonesOcean: AvatarPresetSpec(
            symbolName: "headphones",
            gradient: AvatarGradient(start: .avatarCyan, end: ColorPalette.standard.accent),
            accessibilityLabel: LocalizedStringResource(
                "profiles.avatar.headphonesOcean",
                defaultValue: "Ocean Headphones",
                comment: "Accessibility label for the headphones profile avatar preset"
            )
        ),
        .micOrchid: AvatarPresetSpec(
            symbolName: "music.mic",
            gradient: AvatarGradient(start: .avatarPink, end: .neonPurple),
            accessibilityLabel: LocalizedStringResource(
                "profiles.avatar.micOrchid",
                defaultValue: "Orchid Microphone",
                comment: "Accessibility label for the microphone profile avatar preset"
            )
        ),
        .pianoNebula: AvatarPresetSpec(
            symbolName: "pianokeys",
            gradient: AvatarGradient(start: .neonPurple, end: .avatarPink),
            accessibilityLabel: LocalizedStringResource(
                "profiles.avatar.pianoNebula",
                defaultValue: "Nebula Piano",
                comment: "Accessibility label for the piano-keys profile avatar preset"
            )
        ),
        .metronomeMint: AvatarPresetSpec(
            symbolName: "metronome.fill",
            gradient: AvatarGradient(start: ColorPalette.standard.success, end: .avatarCyan),
            accessibilityLabel: LocalizedStringResource(
                "profiles.avatar.metronomeMint",
                defaultValue: "Mint Metronome",
                comment: "Accessibility label for the metronome profile avatar preset"
            )
        ),
        .radioSunrise: AvatarPresetSpec(
            symbolName: "dot.radiowaves.left.and.right",
            gradient: AvatarGradient(start: ColorPalette.standard.warning, end: .avatarPink),
            accessibilityLabel: LocalizedStringResource(
                "profiles.avatar.radioSunrise",
                defaultValue: "Sunrise Radio",
                comment: "Accessibility label for the radio-waves profile avatar preset"
            )
        ),
        .quaverBerry: AvatarPresetSpec(
            symbolName: "music.quarternote.3",
            gradient: AvatarGradient(start: .neonPurple, end: .avatarCyan),
            accessibilityLabel: LocalizedStringResource(
                "profiles.avatar.quaverBerry",
                defaultValue: "Berry Notes",
                comment: "Accessibility label for the musical-notes profile avatar preset"
            )
        ),
        .speakerNeon: AvatarPresetSpec(
            symbolName: "speaker.wave.3.fill",
            gradient: AvatarGradient(start: .neonPink, end: .neonCyan),
            accessibilityLabel: LocalizedStringResource(
                "profiles.avatar.speakerNeon",
                defaultValue: "Neon Speaker",
                comment: "Accessibility label for the speaker profile avatar preset"
            )
        ),
        .hifiForest: AvatarPresetSpec(
            symbolName: "hifispeaker.fill",
            gradient: AvatarGradient(start: ColorPalette.standard.success, end: ColorPalette.standard.accent),
            accessibilityLabel: LocalizedStringResource(
                "profiles.avatar.hifiForest",
                defaultValue: "Forest Hi-Fi",
                comment: "Accessibility label for the hi-fi speaker profile avatar preset"
            )
        ),
    ]
}

// MARK: - View

/// Renders a ``ProfileAvatarPreset`` as a gradient-filled circle with its symbol,
/// or a custom `imagePath` photo clipped to the same circle when one is supplied.
///
/// Cross-platform (SwiftUI + ImageIO/CoreGraphics — no AppKit/UIKit). A nil,
/// missing, or still-loading `imagePath` falls back to the preset, so a deleted
/// custom avatar never renders blank.
public struct ProfileAvatarView: View {
    private let preset: ProfileAvatarPreset
    private let imagePath: String?
    private let size: CGFloat

    @State private var loadedImage: CGImage?

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    public init(preset: ProfileAvatarPreset, imagePath: String? = nil, size: CGFloat = 44) {
        self.preset = preset
        self.imagePath = imagePath
        self.size = size
    }

    public var body: some View {
        avatarContent
            .frame(width: size, height: size)
            .overlay(
                Circle()
                    .strokeBorder(tokens.colors.separator.resolve(scheme), lineWidth: tokens.spacing.hairline)
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(resolvedAccessibilityLabel))
            .task(id: imagePath) {
                loadedImage = imagePath.flatMap { ProfileAvatarImage.load(path: $0) }
            }
    }

    @ViewBuilder
    private var avatarContent: some View {
        if imagePath != nil, let image = loadedImage {
            Image(decorative: image, scale: 1, orientation: .up)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else {
            presetContent
        }
    }

    private var presetContent: some View {
        ZStack {
            Circle()
                .fill(preset.gradient.linear(scheme))
            Image(systemName: preset.symbolName)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(tokens.colors.onAccent.resolve(scheme))
        }
    }

    private var resolvedAccessibilityLabel: LocalizedStringResource {
        if imagePath != nil, loadedImage != nil {
            return Self.customPhotoLabel
        }
        return preset.accessibilityLabel
    }

    private static let customPhotoLabel = LocalizedStringResource(
        "profiles.avatar.customPhoto",
        defaultValue: "Profile photo",
        comment: "Accessibility label for a profile rendered with a custom photo instead of a preset avatar"
    )
}

#Preview("Profile avatar presets") {
    ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 20)], spacing: 20) {
            ForEach(ProfileAvatarPreset.allCases) { preset in
                VStack(spacing: 8) {
                    ProfileAvatarView(preset: preset, size: 72)
                    Text(verbatim: preset.rawValue)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(24)
    }
    .frame(width: 440, height: 520)
}
