// VisualizerHostView — the macOS visualizer host.
//
// A cinematic, edge-to-edge stage for the Metal spectrum surface (Task 19 backend
// via ``MetalVisualizerView``). The bespoke chrome is a floating, auto-hiding
// thick-glass HUD deck holding a sliding-pill mode switcher (bars / oscilloscope
// / particles / aurora), a renderer/backend seam (Metal now; projectM slots in
// behind `#if MACAMP_PROJECTM`), a windowed/fill-window toggle, and a native
// full-screen toggle. The whole stage recolors around the now-playing artwork via
// ``AlbumTheme`` and pulls frames on the render cadence — nothing is pushed from
// the audio thread, and the GPU is paused whenever the surface is hidden.
//
// Everything here is chrome. The renderer (`MetalVisualizerView`) and the
// pull-don't-push spectrum bridge are untouched: it receives an accent/background
// through its existing parameters (the ``AlbumTheme`` extension point) and nothing
// else changes.
import AppKit
import DesignSystem
import SwiftUI
import ViewModels
import Visualizer

/// How the visualizer surface fills its container.
private enum VisualizerPresentation {
    case windowed
    case fillWindow
}

/// Fixed chrome control metrics (no spacing token maps to a comfortable hit area).
enum VisualizerMetric {
    static let segmentWidth: CGFloat = 44
    static let segmentHeight: CGFloat = 32
    static let control: CGFloat = 36
    static let bloomRadius: CGFloat = 480
}

/// The visualizer surface plus its auto-hiding overlay controls.
struct VisualizerHostView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @State private var backendKind: VisualizerBackendKind = .metal
    @State private var presentation: VisualizerPresentation = .windowed
    @State private var controlsVisible = true
    @State private var isFullScreen = false
    @State private var albumTheme: AlbumTheme?
    @State private var hideControlsTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .bottom) {
            stageBackground
            if showsBloom { accentBloom }
            surface
            if isIdle { idleOverlay }
            if controlsVisible {
                controlDeck
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .designTokens(tokens)
        .albumTheme(albumTheme)
        .themePresentation(themeOptions)
        .contentShape(Rectangle())
        .onContinuousHover { handleHover($0) }
        .onAppear { flashControls() }
        .onDisappear { hideControlsTask?.cancel() }
        .task(id: themeKey) { albumTheme = await loadTheme() }
        .onReceive(fullScreenEnter) { _ in isFullScreen = true }
        .onReceive(fullScreenExit) { _ in isFullScreen = false }
    }

    /// The shared visualizer view model.
    var model: VisualizerViewModel {
        environment.visualizer
    }

    /// Base tokens recolored by the now-playing artwork (no-art ⇒ standard).
    var tokens: DesignTokens {
        albumTheme?.applied(to: .standard) ?? .standard
    }

    /// Accessibility presentation flags forwarded into the design system.
    var themeOptions: ThemePresentationOptions {
        ThemePresentationOptions(
            reduceTransparency: reduceTransparency,
            reduceMotion: reduceMotion,
            increaseContrast: contrast == .increased
        )
    }
}

// MARK: - Stage + surface

private extension VisualizerHostView {
    var stageBackground: some View {
        tokens.colors.canvas.value(for: .dark).color.ignoresSafeArea()
    }

    /// A soft accent bloom behind the framed card; dropped under reduce-transparency.
    var accentBloom: some View {
        RadialGradient(
            colors: [tokens.colors.accent.resolve(scheme).opacity(0.22), .clear],
            center: .bottom,
            startRadius: 0,
            endRadius: VisualizerMetric.bloomRadius
        )
        .blendMode(.plusLighter)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    @ViewBuilder
    var renderer: some View {
        switch backendKind {
        case .metal:
            MetalVisualizerView(
                model: model,
                mode: model.mode,
                accent: accentSIMD,
                background: backgroundSIMD,
                appActive: scenePhase == .active,
                reduceMotion: reduceMotion
            )
        #if MACAMP_PROJECTM
            case .projectM:
                ProjectMVisualizerView(
                    model: model,
                    appActive: scenePhase == .active,
                    reduceMotion: reduceMotion
                )
        #endif
        }
    }

    var surface: some View {
        renderer
            .clipShape(RoundedRectangle(cornerRadius: surfaceRadius, style: .continuous))
            .overlay {
                if presentation == .windowed {
                    RoundedRectangle(cornerRadius: surfaceRadius, style: .continuous)
                        .strokeBorder(tokens.colors.separator.resolve(scheme), lineWidth: tokens.spacing.hairline)
                }
            }
            .shadowToken(presentation == .windowed ? tokens.elevation.high : tokens.elevation.none)
            .padding(surfaceInset)
            .accessibilityElement()
            .accessibilityLabel(Text(VisualizerStrings.title))
            .accessibilityHint(Text(VisualizerStrings.idleMessage))
    }

    /// Elegant centered hint shown when no track is loaded.
    var idleOverlay: some View {
        VStack(spacing: tokens.spacing.small) {
            Image(systemName: "waveform")
                .font(tokens.typography.displayMedium.font)
                .foregroundStyle(tokens.colors.accent.resolve(scheme))
            Text(VisualizerStrings.title)
                .font(tokens.typography.titleMedium.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
            Text(VisualizerStrings.idleMessage)
                .font(tokens.typography.callout.font)
                .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
        }
        .multilineTextAlignment(.center)
        .padding(tokens.spacing.xLarge)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Control deck

private extension VisualizerHostView {
    var controlDeck: some View {
        HStack(spacing: tokens.spacing.medium) {
            VisualizerModeRail(selection: model.mode, onSelect: selectMode)
            deckDivider
            HStack(spacing: tokens.spacing.xxSmall) {
                if showsRendererMenu { rendererMenu }
                presentationButton
                fullScreenButton
            }
        }
        .padding(.horizontal, tokens.spacing.large)
        .padding(.vertical, tokens.spacing.xSmall)
        .background(deckBackground)
        .padding(.bottom, tokens.spacing.xLarge)
        .accessibilityElement(children: .contain)
    }

    /// Thick-glass HUD (``MaterialTokens/hud``) that collapses to a solid raised
    /// surface under reduce-transparency, with a hairline rim and a floating shadow.
    var deckBackground: some View {
        Capsule(style: .continuous)
            .fill(deckFillStyle)
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(tokens.colors.separator.resolve(scheme), lineWidth: tokens.spacing.hairline)
            )
            .shadowToken(tokens.elevation.high)
    }

    var deckFillStyle: AnyShapeStyle {
        themeOptions.reduceTransparency
            ? AnyShapeStyle(tokens.colors.surfaceRaised.resolve(scheme))
            : AnyShapeStyle(MaterialTokens.standard.hud.material)
    }

    var rendererMenu: some View {
        Menu {
            Picker(selection: $backendKind) {
                ForEach(VisualizerBackendKind.available) { kind in
                    Text(verbatim: kind.verbatimName).tag(kind)
                }
            } label: {
                Text(VisualizerStrings.rendererLabel)
            }
            .pickerStyle(.inline)
        } label: {
            controlIcon("cpu")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text(VisualizerStrings.rendererLabel))
        .accessibilityLabel(Text(VisualizerStrings.rendererLabel))
    }

    var presentationButton: some View {
        Button {
            withAnimation(motion(tokens.motion.standard)) {
                presentation = presentation == .windowed ? .fillWindow : .windowed
            }
            flashControls()
        } label: {
            controlIcon(presentation == .windowed ? "rectangle.fill" : "rectangle.inset.filled")
        }
        .buttonStyle(.plain)
        .help(Text(presentationLabel))
        .accessibilityLabel(Text(presentationLabel))
    }

    var fullScreenButton: some View {
        Button {
            toggleFullScreen()
            flashControls()
        } label: {
            controlIcon(isFullScreen
                ? "arrow.down.right.and.arrow.up.left"
                : "arrow.up.left.and.arrow.down.right")
        }
        .buttonStyle(.plain)
        .help(Text(fullScreenLabel))
        .accessibilityLabel(Text(fullScreenLabel))
    }

    var deckDivider: some View {
        Capsule()
            .fill(tokens.colors.separator.resolve(scheme))
            .frame(width: tokens.spacing.hairline, height: tokens.spacing.large)
    }

    func controlIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(tokens.typography.headline.font)
            .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
            .frame(width: VisualizerMetric.control, height: VisualizerMetric.control)
            .contentShape(Capsule())
    }
}

// MARK: - Derived values

private extension VisualizerHostView {
    var isIdle: Bool {
        environment.player.currentTrack == nil
    }

    var showsBloom: Bool {
        presentation == .windowed && !themeOptions.reduceTransparency
    }

    var showsRendererMenu: Bool {
        VisualizerBackendKind.available.count > 1
    }

    var accentSIMD: SIMD4<Float> {
        tokens.colors.accent.value(for: scheme).simd4
    }

    var backgroundSIMD: SIMD4<Float> {
        tokens.colors.canvas.dark.simd4
    }

    var surfaceRadius: CGFloat {
        presentation == .windowed ? tokens.radii.xLarge : 0
    }

    var surfaceInset: CGFloat {
        presentation == .windowed ? tokens.spacing.large : 0
    }

    var presentationLabel: LocalizedStringResource {
        presentation == .windowed ? VisualizerStrings.fillWindow : VisualizerStrings.windowed
    }

    var fullScreenLabel: LocalizedStringResource {
        isFullScreen ? VisualizerStrings.exitFullScreen : VisualizerStrings.enterFullScreen
    }

    var fullScreenEnter: NotificationCenter.Publisher {
        NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)
    }

    var fullScreenExit: NotificationCenter.Publisher {
        NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)
    }

    var themeKey: AlbumThemeKey {
        AlbumThemeKey(contentHash: environment.player.artwork?.contentHash, options: themeOptions)
    }
}

// MARK: - Behavior

private extension VisualizerHostView {
    /// Animation honoring reduce-motion (nil ⇒ instant).
    func motion(_ duration: Double) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: duration)
    }

    func selectMode(_ mode: VisualizerMode) {
        model.setMode(mode)
        flashControls()
    }

    func handleHover(_ phase: HoverPhase) {
        switch phase {
        case .active: flashControls()
        case .ended: scheduleHide(after: 0.6)
        }
    }

    func flashControls() {
        withAnimation(motion(tokens.motion.quick)) { controlsVisible = true }
        scheduleHide(after: 2.5)
    }

    func scheduleHide(after seconds: Double) {
        hideControlsTask?.cancel()
        hideControlsTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            withAnimation(motion(tokens.motion.standard)) { controlsVisible = false }
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    func toggleFullScreen() {
        let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first
        window?.toggleFullScreen(nil)
    }

    func loadTheme() async -> AlbumTheme? {
        await AlbumArtTheming.theme(forArtwork: environment.player.artwork?.data, options: themeOptions)
    }
}

#Preview {
    VisualizerHostView()
        .environment(AppEnvironment.preview())
        .designTokens(.standard)
        .frame(width: 640, height: 400)
}
