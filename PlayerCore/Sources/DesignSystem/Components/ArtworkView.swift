import SwiftUI

/// Album-artwork view with a token-styled placeholder.
///
/// Takes a cross-platform `CGImage?` (never `NSImage`/`UIImage`) so it is safe in
/// shared PlayerCore. When the image is `nil` it renders a gradient placeholder
/// with a music-note glyph. Corners, border and shadow all come from tokens.
public struct ArtworkView: View {
    private let image: CGImage?
    private let cornerRadius: CGFloat?
    private let shadow: ShadowToken?

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    public init(
        image: CGImage?,
        cornerRadius: CGFloat? = nil,
        shadow: ShadowToken? = nil
    ) {
        self.image = image
        self.cornerRadius = cornerRadius
        self.shadow = shadow
    }

    private var radius: CGFloat {
        cornerRadius ?? tokens.radii.large
    }

    public var body: some View {
        content
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(tokens.colors.separator.resolve(scheme), lineWidth: tokens.spacing.hairline)
            )
            .shadow(for: shadow ?? tokens.elevation.medium)
    }

    /// `.fill` deliberately *reports* a size that overflows the proposal for a
    /// non-square source — a 16∶9 cover proposed 56×56 reports 99.6×56 — and the outer
    /// `.aspectRatio(1, .fit)` passes that overflow through instead of re-clamping it,
    /// so the artwork paints over whatever sits beside it. Reading the resolved box and
    /// pinning the image to a *definite* square is what actually bounds it; a flexible
    /// `maxWidth`/`maxHeight` cap does not, because `.infinity` never clamps anything.
    ///
    /// `idealWidth`/`idealHeight` restore the source's own ideal size, which the
    /// `GeometryReader` would otherwise collapse to 10×10 — that ideal is what sizes the
    /// callers that pass only a `maxWidth` and let the artwork size itself.
    @ViewBuilder
    private var content: some View {
        if let image {
            GeometryReader { proxy in
                let side = min(proxy.size.width, proxy.size.height)
                Image(image, scale: 1, label: Text(DesignSystemStrings.artworkLabel))
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: side, height: side)
                    .clipped()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(idealWidth: CGFloat(image.width), idealHeight: CGFloat(image.height))
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: [
                    tokens.colors.surfaceRaised.resolve(scheme),
                    tokens.colors.accentMuted.resolve(scheme),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "music.note")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
        }
        .accessibilityLabel(Text(DesignSystemStrings.artworkPlaceholder))
    }
}

extension View {
    /// Applies a ``ShadowToken`` as a black drop shadow.
    func shadow(for token: ShadowToken) -> some View {
        shadow(
            color: Color.black.opacity(token.colorOpacity),
            radius: token.radius,
            x: token.offsetX,
            y: token.offsetY
        )
    }
}
