// StatsTopListsView — what the selected period was actually spent on.
//
// One section, three rankings behind a segmented sub-filter: Tracks, Artists,
// Genres. They share a heading rather than stacking as three sections because they
// answer the same question at three grains, and stacked they would push everything
// below the fold.
//
// **Tracks and the other two are not the same kind of thing, and the section says
// so through interaction.** A track row names a file that may still exist, so it
// resolves through `ListeningStatsViewModel.resolvedTopTrack(_:in:)` and — only when
// that succeeds — becomes playable via `statsRowActions(for:)`. An artist or a genre
// row is an AGGREGATE over many files; there is no one thing to play, so those rows
// carry no cursor, no double-click and no menu at all. A row whose track has since
// been deleted keeps its place and its numbers, and simply stops being clickable.
//
// **The view computes no statistics.** Every figure arrives ranked and summed from
// `ListeningWindowDigest`; the only derivation is the display `.prefix`. Note that
// `topTracks` is RAW EVENTS ONLY while `topArtists`/`topGenres` are raw ∪ rollups —
// so an all-time period whose old plays survive only as monthly rollups can show
// artists and genres while the Tracks list is legitimately empty. That asymmetry is
// explained once by the raw-horizon caption at the Group 1 header, which is why
// there is deliberately no second caption here.
import DesignSystem
import Foundation
import Persistence
import Services
import SwiftUI
import ViewModels

/// The three rankings the Top section can show.
enum StatsTopCategory: String, CaseIterable, Identifiable {
    case tracks, artists, genres

    var id: String {
        rawValue
    }

    var label: LocalizedStringResource {
        switch self {
        case .tracks: StatsStrings.topTracks
        case .artists: StatsStrings.topArtists
        case .genres: StatsStrings.topGenres
        }
    }
}

/// The Top tracks / artists / genres section of the selected period.
struct StatsTopListsView: View {
    /// The read model, or `nil` before the first load. Held whole because a track
    /// row's playability is a per-row lookup into the SELECTED window's own
    /// resolution map — see ``ListeningStatsViewModel/resolvedTopTrack(_:in:)``.
    let model: ListeningStatsViewModel?

    @State private var category: StatsTopCategory = .tracks

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    /// Wide enough for a two-digit rank, narrow enough to keep names left-aligned
    /// with the section heading.
    private static let rankColumnWidth: CGFloat = 24

    /// Three short segments need far less room than the four-window period filter
    /// above them, and a full-width sub-filter would read as the primary control.
    private static let pickerMaxWidth: CGFloat = 320

    var body: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.small) {
            Text(StatsStrings.topSection)
                .font(tokens.typography.headline.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
            categoryPicker
            selectedList
        }
    }
}

// MARK: - Chrome

private extension StatsTopListsView {
    var categoryPicker: some View {
        Picker(selection: $category) {
            ForEach(StatsTopCategory.allCases) { item in
                Text(item.label).tag(item)
            }
        } label: {
            Text(StatsStrings.topCategoryLabel)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: Self.pickerMaxWidth)
        .pointingHandCursor()
        .help(Text(StatsStrings.topCategoryHelp))
        .accessibilityLabel(Text(StatsStrings.topCategoryLabel))
        .accessibilityIdentifier("stats.topCategory")
    }

    var emptyLine: some View {
        Text(StatsStrings.topEmpty)
            .font(tokens.typography.caption.font)
            .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Lists

private extension StatsTopListsView {
    @ViewBuilder
    var selectedList: some View {
        switch category {
        case .tracks: trackList
        case .artists: nameList(model?.selectedWindowDigest?.topArtists ?? [])
        case .genres: nameList(model?.selectedWindowDigest?.topGenres ?? [])
        }
    }

    @ViewBuilder
    var trackList: some View {
        let stats = displaySlice(model?.selectedWindowDigest?.topTracks ?? [])
        if stats.isEmpty {
            emptyLine
        } else {
            LazyVStack(spacing: 0) {
                ForEach(Array(stats.enumerated()), id: \.element.track.identityKey) { index, stat in
                    trackRow(rank: index + 1, stat: stat)
                }
            }
        }
    }

    @ViewBuilder
    func nameList(_ stats: [ListeningNameStat]) -> some View {
        let rows = displaySlice(stats)
        if rows.isEmpty {
            emptyLine
        } else {
            LazyVStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.name) { index, stat in
                    nameRow(rank: index + 1, stat: stat)
                }
            }
        }
    }

    /// The digest already caps every ranking at its own limit; this is the display
    /// slice over it.
    func displaySlice<Element>(_ stats: [Element]) -> [Element] {
        Array(stats.prefix(ListeningStatsViewModel.topListDisplayLimit))
    }
}

// MARK: - Rows

private extension StatsTopListsView {
    /// Playable only while the snapshot still resolves to a live library row —
    /// `statsRowActions(for:)` adds nothing at all for `nil`.
    func trackRow(rank: Int, stat: ListeningTrackStat) -> some View {
        HStack(spacing: tokens.spacing.small) {
            rankLabel(rank)
            VStack(alignment: .leading, spacing: 0) {
                primaryText(displayName(stat.track.title))
                secondaryText(displayName(stat.track.artistName))
            }
            Spacer(minLength: tokens.spacing.small)
            metrics(plays: stat.plays, listenedSeconds: stat.listenedSeconds)
        }
        .padding(.vertical, tokens.spacing.xxSmall)
        .accessibilityElement(children: .combine)
        .statsRowActions(for: model.flatMap { $0.resolvedTopTrack(stat, in: $0.selectedWindow) })
    }

    /// An aggregate over many files: displayed, never played. Deliberately carries
    /// no cursor, tap gesture or context menu.
    func nameRow(rank: Int, stat: ListeningNameStat) -> some View {
        HStack(spacing: tokens.spacing.small) {
            rankLabel(rank)
            primaryText(displayName(stat.name))
            Spacer(minLength: tokens.spacing.small)
            metrics(plays: stat.plays, listenedSeconds: stat.listenedSeconds)
        }
        .padding(.vertical, tokens.spacing.xxSmall)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Row parts

private extension StatsTopListsView {
    func rankLabel(_ rank: Int) -> some View {
        Text(verbatim: "\(rank)")
            .font(tokens.typography.caption.font.monospacedDigit())
            .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
            .frame(width: Self.rankColumnWidth, alignment: .trailing)
    }

    func primaryText(_ value: String) -> some View {
        Text(verbatim: value)
            .font(tokens.typography.body.font)
            .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
            .lineLimit(1)
    }

    func secondaryText(_ value: String) -> some View {
        Text(verbatim: value)
            .font(tokens.typography.caption.font)
            .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
            .lineLimit(1)
    }

    func metrics(plays: Int, listenedSeconds: Double) -> some View {
        HStack(spacing: tokens.spacing.small) {
            Text(verbatim: "\(plays)×")
                .font(tokens.typography.caption.font.monospacedDigit().bold())
                .foregroundStyle(tokens.colors.accent.resolve(scheme))
            Text(verbatim: StatsValueFormat.abbreviatedDuration(listenedSeconds))
                .font(tokens.typography.caption.font.monospacedDigit())
                .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
        }
    }

    /// The one fallback for a name the history never captured: `nil` for a track's
    /// snapshot text, and `PlayEventRollupRecord.unknownKey` — the empty string —
    /// for an artist or genre, which is the sentinel the rollups group unknowns under.
    func displayName(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return String(localized: StatsStrings.unknown) }
        return value
    }
}

#Preview {
    StatsTopListsView(model: nil)
        .environment(AppEnvironment.preview())
        .designTokens(.standard)
        .padding()
        .frame(width: 720)
}
