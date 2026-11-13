import SwiftUI

/// A library / playlist list row: leading artwork, a title and optional subtitle,
/// and an optional trailing duration. A playing row is marked with an accent rail
/// and accent-tinted title.
///
/// `title`/`subtitle` are track *data*, not UI copy, so they render verbatim; the
/// row composes them into one accessibility element. Spacing, type and color all
/// come from tokens.
public struct TrackRow: View {
    private let title: String
    private let subtitle: String?
    private let artwork: CGImage?
    private let duration: Duration?
    private let isPlaying: Bool

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    public init(
        title: String,
        subtitle: String? = nil,
        artwork: CGImage? = nil,
        duration: Duration? = nil,
        isPlaying: Bool = false
    ) {
        self.title = title
        self.subtitle = subtitle
        self.artwork = artwork
        self.duration = duration
        self.isPlaying = isPlaying
    }

    public var body: some View {
        HStack(spacing: tokens.spacing.medium) {
            ArtworkView(image: artwork, cornerRadius: tokens.radii.small, shadow: tokens.elevation.low)
                .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: tokens.spacing.xxSmall) {
                Text(verbatim: title)
                    .font(tokens.typography.headline.font)
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
                if let subtitle {
                    Text(verbatim: subtitle)
                        .font(tokens.typography.caption.font)
                        .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: tokens.spacing.small)

            if isPlaying {
                Image(systemName: "waveform")
                    .font(tokens.typography.callout.font)
                    .foregroundStyle(tokens.colors.accent.resolve(scheme))
                    .symbolEffectPlaying()
            }

            if let duration {
                Text(verbatim: durationText(duration))
                    .font(tokens.typography.timecode.font)
                    .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
            }
        }
        .padding(.vertical, tokens.spacing.small)
        .padding(.horizontal, tokens.spacing.medium)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: tokens.radii.medium, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var titleColor: Color {
        isPlaying
            ? tokens.colors.accent.resolve(scheme)
            : tokens.colors.textPrimary.resolve(scheme)
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isPlaying {
            HStack(spacing: 0) {
                Rectangle()
                    .fill(tokens.colors.accent.resolve(scheme))
                    .frame(width: 3)
                tokens.colors.accentMuted.resolve(scheme)
            }
        } else {
            Color.clear
        }
    }

    private func durationText(_ duration: Duration) -> String {
        duration.formatted(.time(pattern: .minuteSecond))
    }
}

private extension View {
    @ViewBuilder
    func symbolEffectPlaying() -> some View {
        if #available(macOS 14.0, iOS 17.0, *) {
            symbolEffect(.variableColor.iterative, options: .repeating)
        } else {
            self
        }
    }
}
