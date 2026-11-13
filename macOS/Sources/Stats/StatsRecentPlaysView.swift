// StatsRecentPlaysView — the last fifty things you actually played.
//
// Every other section on this page is an aggregate. This one is the raw log, and
// it is the only place where a single play is visible as itself: what it was, how
// long ago, how much of it you heard, and whether you cut it short.
//
// It renders from `playEvent` snapshots, which do not join the library — so a row
// exists for a track you deleted last month exactly as it does for one still on
// disk. The snapshot supplies every word on screen; `resolved` supplies only the
// ability to act on it. That split is why a missing track degrades to an inert,
// de-emphasised row rather than to a blank one or to no row at all.
//
// `sourceSurface` is captured on every event but deliberately NOT rendered in v1:
// the raw value is an untranslated internal token, and surfacing it would need its
// own name mapping and a column the row has no width for. The data is kept so a
// later version can add it without a migration.
//
// The view computes no statistics. Ordering (newest first) and the fifty-row cap
// (`ListeningStatsViewModel.recentPlaysLimit`) both happen in the view model.
import DesignSystem
import Foundation
import Persistence
import SwiftUI
import ViewModels

/// The Recent Plays section: newest history entries first, playable while they last.
struct StatsRecentPlaysView: View {
    /// Events ordered newest-first and already capped at
    /// ``ListeningStatsViewModel/recentPlaysLimit`` by the view model. An empty
    /// array hides the section, matching every other list on the page.
    let rows: [RecentPlay]

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    /// Fixed so every title starts on the same vertical line no matter how long the
    /// relative phrase is — a log reads as a log only when its gutter is a column.
    private static let timestampWidth: CGFloat = 96

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: tokens.spacing.small) {
                header
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        recentRow(row)
                    }
                }
            }
            .accessibilityIdentifier("stats.recentPlays")
        }
    }
}

// MARK: - Chrome

private extension StatsRecentPlaysView {
    var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(StatsStrings.recentPlays)
                .font(tokens.typography.headline.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
            // "Latest 50 plays" IS `ListeningStatsViewModel.recentPlaysLimit`; the
            // cap is applied when the events are read, never re-applied here.
            Text(StatsStrings.recentCaption)
                .font(tokens.typography.caption.font)
                .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Rows

private extension StatsRecentPlaysView {
    /// Playable only while the snapshot still resolves to a live library row.
    /// `statsRowActions(for:)` adds nothing at all for `nil`, so a play whose track
    /// is gone keeps its text and simply stops being clickable — and says so by
    /// dropping to the tertiary text role.
    func recentRow(_ row: RecentPlay) -> some View {
        let isResolved = row.resolved != nil
        return HStack(spacing: tokens.spacing.small) {
            timestamp(row.event.startedAt, isResolved: isResolved)
            VStack(alignment: .leading, spacing: 0) {
                titleText(displayName(row.event.title), isResolved: isResolved)
                artistText(displayName(row.event.artistName), isResolved: isResolved)
            }
            Spacer(minLength: tokens.spacing.small)
            if row.event.skipped {
                skippedBadge
            }
            listenedText(row.event.secondsListened, isResolved: isResolved)
        }
        .padding(.vertical, tokens.spacing.xxSmall)
        .accessibilityElement(children: .combine)
        .statsRowActions(for: row.resolved)
    }

    /// `RelativeDateTimeFormatter`'s `.named` style, reached through its
    /// `FormatStyle` spelling — the same call `StatsPanelView` makes for its "last
    /// played" line, so the two surfaces phrase an age identically and no cached
    /// formatter instance has to be made concurrency-safe. Already locale-resolved,
    /// hence `Text(verbatim:)`.
    func timestamp(_ startedAt: TimeInterval, isResolved: Bool) -> some View {
        let relative = Date(timeIntervalSince1970: startedAt)
            .formatted(.relative(presentation: .named))
        return Text(verbatim: relative)
            .font(tokens.typography.caption.font)
            .foregroundStyle(secondaryColor(isResolved: isResolved))
            .lineLimit(1)
            .frame(width: Self.timestampWidth, alignment: .leading)
    }
}

// MARK: - Row parts

private extension StatsRecentPlaysView {
    func titleText(_ value: String, isResolved: Bool) -> some View {
        Text(verbatim: value)
            .font(tokens.typography.body.font)
            .foregroundStyle(primaryColor(isResolved: isResolved))
            .lineLimit(1)
    }

    func artistText(_ value: String, isResolved: Bool) -> some View {
        Text(verbatim: value)
            .font(tokens.typography.caption.font)
            .foregroundStyle(secondaryColor(isResolved: isResolved))
            .lineLimit(1)
    }

    func listenedText(_ seconds: Double, isResolved: Bool) -> some View {
        Text(verbatim: StatsValueFormat.abbreviatedDuration(seconds))
            .font(tokens.typography.caption.font.monospacedDigit())
            .foregroundStyle(secondaryColor(isResolved: isResolved))
            .lineLimit(1)
    }

    /// A bare glyph with no visible text, so it names itself twice: as a hover
    /// tooltip, and as a spoken label the row's `.combine` folds into its sentence.
    var skippedBadge: some View {
        Image(systemName: "forward.end")
            .font(tokens.typography.caption.font)
            .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
            .help(Text(StatsStrings.skippedBadge))
            .accessibilityLabel(Text(StatsStrings.skippedBadge))
    }
}

// MARK: - Row styling

private extension StatsRecentPlaysView {
    /// An unresolved row flattens to the tertiary role across the whole line. The
    /// point is not decoration: the hand cursor and the context menu are absent
    /// there, and the colour is what tells the reader that before they try.
    /// Size and weight still separate title from artist.
    func primaryColor(isResolved: Bool) -> Color {
        isResolved
            ? tokens.colors.textPrimary.resolve(scheme)
            : tokens.colors.textTertiary.resolve(scheme)
    }

    func secondaryColor(isResolved: Bool) -> Color {
        isResolved
            ? tokens.colors.textSecondary.resolve(scheme)
            : tokens.colors.textTertiary.resolve(scheme)
    }

    /// The one fallback for a name the history never captured — `nil` snapshot
    /// text, or the empty-string sentinel unknowns are grouped under.
    func displayName(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return String(localized: StatsStrings.unknown) }
        return value
    }
}

#Preview {
    // Sample names are bound to locals because `title:` is one of the argument
    // labels the hardcoded-text guard scans; preview fixtures are not translatable
    // copy. Both fixtures are deliberately unresolved, so the preview shows the
    // de-emphasised inert state a deleted track produces.
    let heardTitle = "Everything In Its Right Place"
    let cutShortTitle = "Pyramid Song"
    let artist = "Radiohead"
    let now = Date().timeIntervalSince1970

    StatsRecentPlaysView(rows: [
        RecentPlay(
            event: PlayEventRecord(
                id: 1,
                profileId: ProfileRecord.guestID,
                trackId: 10,
                artistName: artist,
                title: heardTitle,
                startedAt: now - 900,
                utcOffsetSeconds: 0,
                secondsListened: 251,
                completionFraction: 1
            ),
            resolved: nil
        ),
        RecentPlay(
            event: PlayEventRecord(
                id: 2,
                profileId: ProfileRecord.guestID,
                artistName: artist,
                title: cutShortTitle,
                startedAt: now - 7200,
                utcOffsetSeconds: 0,
                secondsListened: 34,
                completionFraction: 0.12,
                skipped: true
            ),
            resolved: nil
        ),
    ])
    .environment(AppEnvironment.preview())
    .designTokens(.standard)
    .padding()
    .frame(width: 720)
}
