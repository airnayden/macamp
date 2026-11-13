import DesignSystem
import SwiftUI

/// The launch splash: the synthwave key art under a token-derived legibility
/// scrim, the product mark, a live loading status driven by ``SplashPhase``, a
/// glowing neon progress bar and a version line. `MacAMPApp` shows it while the
/// app warms up, then cross-fades it out.
struct SplashView: View {
    let phase: SplashPhase

    @Environment(\.designTokens) private var tokens
    @State private var revealed = false
    @State private var barProgress = 0.0

    var body: some View {
        ZStack {
            Image("Splash")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .clipped()
            scrim
            VStack(spacing: 0) {
                Spacer()
                loaderBlock
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(revealed ? 1 : 0)
                    .offset(y: revealed ? 0 : tokens.spacing.small)
            }
            .padding(.horizontal, tokens.spacing.xLarge)
            .padding(.bottom, tokens.spacing.xLarge)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onAppear(perform: start)
        .onChange(of: phase) { _, newPhase in
            withAnimation(.spring(response: 0.6, dampingFraction: 0.85)) {
                barProgress = newPhase.progress
            }
        }
    }

    private var scrim: some View {
        let base = tokens.colors.canvas.resolve(.dark)
        return LinearGradient(
            stops: [
                .init(color: base.opacity(0.22), location: 0.0),
                .init(color: base.opacity(0.05), location: 0.35),
                .init(color: base.opacity(0.48), location: 0.78),
                .init(color: base.opacity(0.88), location: 1.0),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var loaderBlock: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.small) {
            HStack(alignment: .lastTextBaseline) {
                Text(phase.label)
                    .font(tokens.typography.callout.font)
                    .foregroundStyle(secondaryColor)
                    .contentTransition(.opacity)
                Spacer()
                Text(verbatim: versionLabel)
                    .font(tokens.typography.caption.font.monospacedDigit())
                    .foregroundStyle(tertiaryColor)
            }
            NeonLoadingBar(progress: barProgress, tokens: tokens)
        }
        .accessibilityElement(children: .combine)
    }

    private var textColor: Color {
        tokens.colors.textPrimary.resolve(.dark)
    }

    private var secondaryColor: Color {
        tokens.colors.textSecondary.resolve(.dark)
    }

    private var tertiaryColor: Color {
        tokens.colors.textTertiary.resolve(.dark)
    }

    private var glow: Color {
        tokens.colors.accent.resolve(.dark).opacity(0.7)
    }

    private var versionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard let version, !version.isEmpty else { return "" }
        return "v\(version)"
    }

    private func start() {
        withAnimation(.easeOut(duration: 0.6)) { revealed = true }
        withAnimation(.spring(response: 0.7, dampingFraction: 0.85)) {
            barProgress = phase.progress
        }
    }
}

/// A launch phase whose localized label is shown beside the progress bar; the
/// `progress` fraction drives how full the neon bar reads for that phase.
enum SplashPhase: CaseIterable {
    case loadingLibrary
    case startingEngine

    var label: LocalizedStringResource {
        switch self {
        case .loadingLibrary: SplashStrings.loadingLibrary
        case .startingEngine: SplashStrings.startingEngine
        }
    }

    var progress: Double {
        switch self {
        case .loadingLibrary: 0.55
        case .startingEngine: 1.0
        }
    }
}

private struct NeonLoadingBar: View {
    let progress: Double
    let tokens: DesignTokens

    var body: some View {
        let pink = ColorValue(hex: 0xFF375F).color
        let cyan = ColorValue(hex: 0x64D2FF).color
        let purple = tokens.colors.accent.resolve(.dark)
        let track = tokens.colors.textPrimary.resolve(.dark).opacity(0.14)
        return GeometryReader { geometry in
            Capsule(style: .continuous)
                .fill(track)
                .overlay(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [pink, purple, cyan],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geometry.size.width * clamped)
                        .shadow(color: pink.opacity(0.7), radius: 8)
                        .shadow(color: cyan.opacity(0.5), radius: 14)
                }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }

    private var clamped: CGFloat {
        CGFloat(max(0, min(1, progress)))
    }
}

private enum SplashStrings {
    static let loadingLibrary = LocalizedStringResource(
        "app.splash.loadingLibrary",
        defaultValue: "Loading library…",
        comment: "Status shown on the launch splash while the music library loads"
    )
    static let startingEngine = LocalizedStringResource(
        "app.splash.startingEngine",
        defaultValue: "Starting audio engine…",
        comment: "Status shown on the launch splash while the audio engine starts"
    )
}
