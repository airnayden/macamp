import SwiftUI

/// One genre-filter chip as plain data: a stable identity, a rendered title, and
/// whether it is the current selection.
///
/// DesignSystem owns **no** user-facing strings — the app shells supply each
/// chip's title. A chrome label (e.g. "All Genres") arrives as ``Title/localized``
/// so it resolves through the shell's String Catalog; a genre NAME is
/// non-translatable and arrives as ``Title/verbatim`` so it renders exactly as
/// given (never re-interpreted as a localization key or format string).
public struct GenreFilterChip: Identifiable {
    /// A chip's title: a localized chrome label, or a verbatim (non-translatable)
    /// genre name.
    public enum Title {
        case localized(LocalizedStringResource)
        case verbatim(String)
    }

    public let id: String
    public let title: Title
    public let isSelected: Bool

    public init(id: String, title: Title, isSelected: Bool) {
        self.id = id
        self.title = title
        self.isSelected = isSelected
    }
}

/// A horizontal, scrollable row of genre-filter chips. Selecting a chip reports its
/// ``GenreFilterChip/id`` back through `onSelect`, and the caller maps that id onto
/// its own selection model. Every color, radius, gap and type role resolves through
/// the design tokens — no literal styling — so the bar renders identically on every
/// shell that composes it.
///
/// The shells differ only in three injected knobs, so a single component covers
/// both without an `#if os` in sight:
/// - `horizontalPadding` — the outer gutter, a ``SpacingScale`` key path.
/// - `accessibilityHint` — an optional per-chip VoiceOver hint (`nil` = none).
/// - `appliesContentShape` — whether each chip clips its hit area to a `Capsule`.
public struct GenreFilterBarView: View {
    private let chips: [GenreFilterChip]
    private let accessibilityLabel: LocalizedStringResource
    private let accessibilityHint: LocalizedStringResource?
    private let horizontalPadding: KeyPath<SpacingScale, CGFloat>
    private let appliesContentShape: Bool
    private let onSelect: (String) -> Void

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    public init(
        chips: [GenreFilterChip],
        accessibilityLabel: LocalizedStringResource,
        accessibilityHint: LocalizedStringResource? = nil,
        horizontalPadding: KeyPath<SpacingScale, CGFloat> = \.medium,
        appliesContentShape: Bool = false,
        onSelect: @escaping (String) -> Void
    ) {
        self.chips = chips
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityHint = accessibilityHint
        self.horizontalPadding = horizontalPadding
        self.appliesContentShape = appliesContentShape
        self.onSelect = onSelect
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: tokens.spacing.xSmall) {
                ForEach(chips) { chip in
                    chipButton(chip)
                }
            }
            .padding(.horizontal, tokens.spacing[keyPath: horizontalPadding])
            .padding(.vertical, tokens.spacing.xSmall)
        }
        .accessibilityLabel(Text(accessibilityLabel))
    }

    private func chipButton(_ chip: GenreFilterChip) -> some View {
        Button {
            onSelect(chip.id)
        } label: {
            chipLabel(chip)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chip.isSelected ? .isSelected : [])
        .genreFilterHint(accessibilityHint)
    }

    private func chipLabel(_ chip: GenreFilterChip) -> some View {
        titleText(chip.title)
            .font(tokens.typography.callout.font)
            .foregroundStyle(foreground(chip.isSelected))
            .padding(.horizontal, tokens.spacing.small)
            .padding(.vertical, tokens.spacing.xSmall)
            .background { Capsule().fill(fill(chip.isSelected)) }
            .overlay { Capsule().strokeBorder(border(chip.isSelected), lineWidth: 1) }
            .genreFilterContentShape(appliesContentShape)
    }

    private func titleText(_ title: GenreFilterChip.Title) -> Text {
        switch title {
        case let .localized(resource): Text(resource)
        case let .verbatim(name): Text(verbatim: name)
        }
    }

    private func fill(_ isSelected: Bool) -> Color {
        (isSelected ? tokens.colors.accent : tokens.colors.surfaceRaised).resolve(scheme)
    }

    private func foreground(_ isSelected: Bool) -> Color {
        (isSelected ? tokens.colors.onAccent : tokens.colors.textSecondary).resolve(scheme)
    }

    private func border(_ isSelected: Bool) -> Color {
        (isSelected ? tokens.colors.accent : tokens.colors.separator).resolve(scheme)
    }
}

private extension View {
    /// Adds a VoiceOver hint (iOS shell) — a no-op when `nil` (macOS shell), so the
    /// bar's rendered tree matches the prior per-shell components byte-for-byte.
    @ViewBuilder
    func genreFilterHint(_ hint: LocalizedStringResource?) -> some View {
        if let hint {
            accessibilityHint(Text(hint))
        } else {
            self
        }
    }

    /// Clips the chip's hit area to a `Capsule` (iOS shell) — a no-op when disabled
    /// (macOS shell).
    @ViewBuilder
    func genreFilterContentShape(_ isEnabled: Bool) -> some View {
        if isEnabled {
            contentShape(Capsule())
        } else {
            self
        }
    }
}

#Preview {
    GenreFilterBarView(
        chips: [
            GenreFilterChip(id: "all", title: .verbatim("All Genres"), isSelected: true),
            GenreFilterChip(id: "ambient", title: .verbatim("Ambient"), isSelected: false),
            GenreFilterChip(id: "jazz", title: .verbatim("Jazz"), isSelected: false),
            GenreFilterChip(id: "untagged", title: .verbatim("(no genre)"), isSelected: false),
        ],
        accessibilityLabel: "Filter by genre",
        onSelect: { _ in }
    )
    .designTokens(.standard)
    .frame(width: 420)
    .padding()
}
