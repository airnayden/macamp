import SwiftUI

/// A Dynamic-Type-aware font specification stored as `Sendable` data.
///
/// Built on `Font.system(_:design:)` so every role scales automatically with the
/// user's preferred content size. The design language is SF Pro throughout — the
/// system optical variants (Display at large sizes, Text at body sizes) selected
/// automatically by point size — with monospaced digits for transport/time
/// labels. Zero bundled font resources; fully Dynamic-Type accessible.
public struct FontToken: Sendable, Equatable {
    public var style: Font.TextStyle
    public var design: Font.Design
    public var weight: Font.Weight
    public var monospacedDigit: Bool

    public init(
        style: Font.TextStyle,
        design: Font.Design = .default,
        weight: Font.Weight = .regular,
        monospacedDigit: Bool = false
    ) {
        self.style = style
        self.design = design
        self.weight = weight
        self.monospacedDigit = monospacedDigit
    }

    public var font: Font {
        let base = Font.system(style, design: design).weight(weight)
        return monospacedDigit ? base.monospacedDigit() : base
    }
}

/// Semantic typographic roles. Components pick a role; they never call
/// `Font.system(size:)` with a raw point size.
public struct TypographyScale: Sendable, Equatable {
    public var displayLarge: FontToken
    public var displayMedium: FontToken
    public var titleLarge: FontToken
    public var titleMedium: FontToken
    public var headline: FontToken
    public var body: FontToken
    public var callout: FontToken
    public var caption: FontToken
    public var timecode: FontToken

    public init(
        displayLarge: FontToken,
        displayMedium: FontToken,
        titleLarge: FontToken,
        titleMedium: FontToken,
        headline: FontToken,
        body: FontToken,
        callout: FontToken,
        caption: FontToken,
        timecode: FontToken
    ) {
        self.displayLarge = displayLarge
        self.displayMedium = displayMedium
        self.titleLarge = titleLarge
        self.titleMedium = titleMedium
        self.headline = headline
        self.body = body
        self.callout = callout
        self.caption = caption
        self.timecode = timecode
    }
}

public extension TypographyScale {
    static let standard = TypographyScale(
        displayLarge: FontToken(style: .largeTitle, design: .default, weight: .bold),
        displayMedium: FontToken(style: .title, design: .default, weight: .bold),
        titleLarge: FontToken(style: .title2, design: .default, weight: .semibold),
        titleMedium: FontToken(style: .title3, design: .default, weight: .semibold),
        headline: FontToken(style: .headline, design: .default, weight: .semibold),
        body: FontToken(style: .body, design: .default, weight: .regular),
        callout: FontToken(style: .callout, design: .default, weight: .regular),
        caption: FontToken(style: .caption, design: .default, weight: .medium),
        timecode: FontToken(style: .footnote, design: .default, weight: .medium, monospacedDigit: true)
    )
}
