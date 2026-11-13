// KaraokeButton — the karaoke (vocal-removal) control for the player bar AND the
// now-playing overlay (Task 16 / karaoke-refinements todo 13).
//
// Two pieces, split so every state is previewable:
//   • `KaraokeButton` — the CONTAINER. Reads the coarse ``KaraokeButtonState`` and
//     the press seams from the live `PlayerViewModel`, then defers to the pure
//     `KaraokeButtonContent`. Absent from the view tree (and the accessibility
//     hierarchy) entirely while ``KaraokeButtonState/hidden``.
//   • `KaraokeButtonContent` — the PURE, state-driven visual: the ONLY exhaustive
//     switch over ``KaraokeButtonState`` in the app. Split out so all five visible
//     states render in `#Preview` (the live model reaches only three hermetically).
//
// It MIRRORS ``TransportButton``'s standard-prominence circular styling but is a
// SEPARATE control (`TransportButton` is a fixed-`Kind` glyph button with no
// six-state / progress-ring / render-vs-toggle support), so this wraps the same
// visual conventions (design tokens, hover fill, reduce-motion press scale) around
// the karaoke state machine instead of modifying that shared component.
//
// Isolation (macOS UI-performance rule 3): `PlayerBarTransport` never reads any
// karaoke state — it just mounts `KaraokeButton()`, so the whole transport cluster
// is insulated from karaoke updates. The preparation ring is a LEAF
// (`KaraokeProgressRing`) that reads ONLY `PlayerViewModel.karaokePreparationProgress`,
// so a progress update re-renders the arc alone — never the surrounding bar.
import DesignSystem
import Separation
import SwiftUI
import ViewModels

/// The player-bar / overlay karaoke toggle. Reads the derived state + press seams
/// from the live model and defers to ``KaraokeButtonContent``. Self-hides (renders
/// nothing) while ``KaraokeButtonState/hidden``, so a host `HStack` is unchanged
/// when karaoke is off in Settings.
struct KaraokeButton: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        KaraokeButtonContent(
            state: environment.player.karaokeButtonState,
            onToggle: { environment.player.toggleKaraoke() },
            onRender: { environment.player.requestKaraokeRender() }
        )
    }
}

/// The pure, state-driven karaoke button visual — the single exhaustive switch over
/// ``KaraokeButtonState``. Fed the derived state + the two press actions by
/// ``KaraokeButton`` (or an explicit state by `#Preview`). The `.renderable` state
/// creates an instrumental on demand (`mic.badge.plus` glyph → `onRender`); `.ready`
/// engages the cached instrumental instantly (`microphone` + accent dot → `onToggle`).
struct KaraokeButtonContent: View {
    let state: KaraokeButtonState
    let onToggle: () -> Void
    let onRender: () -> Void

    /// Matches ``TransportButton/Size/small`` (the other transport glyphs).
    static let diameter: CGFloat = 36
    private static let glyphScale: CGFloat = 0.40
    private static let readyIcon = "microphone"
    private static let activeIcon = "microphone.slash"
    private static let renderableIcon = "mic.badge.plus"

    var body: some View {
        switch state {
        case .hidden:
            EmptyView()
        case let .disabled(reason):
            button(disabledSpec(reason))
                .disabled(true)
        case .preparing:
            button(preparingSpec)
                .overlay { KaraokeProgressRing(diameter: Self.diameter) }
                .pointingHandCursor()
        case .renderable:
            button(renderableSpec)
                .pointingHandCursor()
        case .ready:
            button(readySpec)
                .accessibilityValue(Text(MacAMPStrings.karaokeReadyIndicatorAccessibilityLabel))
                .overlay(alignment: .topTrailing) { KaraokeReadyIndicator() }
                .pointingHandCursor()
        case .active:
            button(activeSpec)
                .pointingHandCursor()
        }
    }
}

// MARK: - Presentation specs

private extension KaraokeButtonContent {
    /// One state's full button presentation — bundled so ``body`` stays a compact
    /// switch and each state's icon / help / hint / a11y id / press action lives in
    /// exactly one place.
    struct Spec {
        let icon: String
        var isActive = false
        let help: LocalizedStringResource
        let hint: LocalizedStringResource
        let identifier: String
        let action: () -> Void
    }

    func button(_ spec: Spec) -> some View {
        Button(action: spec.action) {
            Image(systemName: spec.icon)
                .font(.system(size: Self.diameter * Self.glyphScale, weight: .semibold))
        }
        .buttonStyle(KaraokeButtonStyle(diameter: Self.diameter, isActive: spec.isActive))
        .help(Text(spec.help))
        .accessibilityLabel(Text(MacAMPStrings.karaokeAccessibilityLabel))
        .accessibilityHint(Text(spec.hint))
        .accessibilityIdentifier(spec.identifier)
    }

    func disabledSpec(_ reason: SeparationUnavailableReason) -> Spec {
        Spec(
            icon: Self.readyIcon,
            help: reason.message,
            hint: reason.message,
            identifier: "player.karaokeButton.disabled",
            action: onToggle
        )
    }

    var preparingSpec: Spec {
        Spec(
            icon: Self.readyIcon,
            help: MacAMPStrings.karaokeHelp,
            hint: MacAMPStrings.karaokePreparingAccessibilityHint,
            identifier: "player.karaokeButton.preparing",
            action: onToggle
        )
    }

    var renderableSpec: Spec {
        Spec(
            icon: Self.renderableIcon,
            help: MacAMPStrings.karaokeRenderableHelp,
            hint: MacAMPStrings.karaokeRenderableAccessibilityHint,
            identifier: "player.karaokeButton.renderable",
            action: onRender
        )
    }

    var readySpec: Spec {
        Spec(
            icon: Self.readyIcon,
            help: MacAMPStrings.karaokeHelp,
            hint: MacAMPStrings.karaokeAccessibilityHint,
            identifier: "player.karaokeButton.ready",
            action: onToggle
        )
    }

    var activeSpec: Spec {
        Spec(
            icon: Self.activeIcon,
            isActive: true,
            help: MacAMPStrings.karaokeHelp,
            hint: MacAMPStrings.karaokeAccessibilityHint,
            identifier: "player.karaokeButton.active",
            action: onToggle
        )
    }
}

/// The karaoke preparation progress ring — a value-driven arc around the mic glyph.
///
/// A LEAF that reads ONLY `PlayerViewModel.karaokePreparationProgress`, so a progress
/// update re-renders this arc alone and nothing else (UI-performance rule 3). The
/// `trim` is plain / value-driven — no implicit animation, no ticker — so
/// reduce-motion needs no special handling: nothing here animates.
private struct KaraokeProgressRing: View {
    let diameter: CGFloat

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    private static let lineWidth: CGFloat = 2
    private static let inset: CGFloat = 5

    var body: some View {
        Circle()
            .trim(from: 0, to: environment.player.karaokePreparationProgress ?? 0)
            .stroke(
                tokens.colors.accent.resolve(scheme),
                style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round)
            )
            .rotationEffect(.degrees(-90))
            .frame(width: diameter - Self.inset * 2, height: diameter - Self.inset * 2)
            .allowsHitTesting(false)
    }
}

/// A small accent dot marking ``KaraokeButtonState/ready`` — the current track has a
/// cached instrumental, so a press engages karaoke instantly (vs. the distinct
/// `mic.badge.plus` glyph of ``KaraokeButtonState/renderable``, whose press renders
/// on demand). Decorative + non-interactive: it never blocks the tap, and the ready
/// state is announced to VoiceOver via the button's accessibility value.
private struct KaraokeReadyIndicator: View {
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    private static let dotSize: CGFloat = 8

    var body: some View {
        Circle()
            .fill(tokens.colors.accent.resolve(scheme))
            .frame(width: Self.dotSize, height: Self.dotSize)
            .padding(tokens.spacing.xxSmall)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Standard-prominence circular button styling, mirroring the private
/// `TransportButtonStyle` (glyph + subtle hover fill, accent when active, press
/// scale suppressed under reduce-motion). Reads `\.isEnabled` so the disabled state
/// renders greyed while the `Button`'s own `.disabled(true)` keeps the press inert.
private struct KaraokeButtonStyle: ButtonStyle {
    let diameter: CGFloat
    let isActive: Bool

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme
    @Environment(\.themePresentation) private var presentation
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .foregroundStyle(foreground)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(fill(pressed: pressed)))
            .contentShape(Circle())
            .scaleEffect(presentation.reduceMotion ? 1 : (pressed ? 0.9 : 1))
            .animation(
                presentation.reduceMotion ? nil : .spring(duration: tokens.motion.quick),
                value: pressed
            )
            .onHover { isHovered = $0 }
    }

    private var foreground: Color {
        guard isEnabled else { return tokens.colors.textDisabled.resolve(scheme) }
        return isActive
            ? tokens.colors.accent.resolve(scheme)
            : tokens.colors.textPrimary.resolve(scheme)
    }

    private func fill(pressed: Bool) -> Color {
        guard isEnabled else { return tokens.colors.surface.resolve(scheme).opacity(0.001) }
        if isActive { return tokens.colors.accentMuted.resolve(scheme) }
        if pressed { return tokens.colors.surfaceRaised.resolve(scheme) }
        if isHovered { return tokens.colors.surfaceRaised.resolve(scheme).opacity(0.6) }
        return tokens.colors.surface.resolve(scheme).opacity(0.001)
    }
}

#Preview("Karaoke · Renderable") {
    KaraokeButtonContent(state: .renderable, onToggle: {}, onRender: {})
        .environment(AppEnvironment.preview())
        .padding()
}

#Preview("Karaoke · Preparing") {
    KaraokeButtonContent(state: .preparing(0.6), onToggle: {}, onRender: {})
        .environment(AppEnvironment.preview())
        .padding()
}

#Preview("Karaoke · Ready") {
    KaraokeButtonContent(state: .ready, onToggle: {}, onRender: {})
        .environment(AppEnvironment.preview())
        .padding()
}

#Preview("Karaoke · Active") {
    KaraokeButtonContent(state: .active, onToggle: {}, onRender: {})
        .environment(AppEnvironment.preview())
        .padding()
}

#Preview("Karaoke · Disabled") {
    KaraokeButtonContent(state: .disabled(reason: .modelNotBundled), onToggle: {}, onRender: {})
        .environment(AppEnvironment.preview())
        .padding()
}
