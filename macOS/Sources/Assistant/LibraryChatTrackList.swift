// LibraryChatTrackList — the tracks a lookup answered with, drawn as the library
// draws them everywhere else.
//
// ── THE IDS ARE RE-RESOLVED, NEVER TRUSTED ───────────────────────────────────
//
// `AssistantChatRow` carries a title and an artist, and drawing THOSE would be a
// one-liner. It is deliberately not what happens: the strings in an event are a
// snapshot taken when the tool answered, on the far side of a model round trip that
// may have taken a minute, and the row offers PLAY / ENQUEUE / EDIT TAGS on the id
// beside them. So the id is the only thing carried forward and everything drawn
// comes from a fresh read — which also means a track deleted between the answer and
// the render simply has no row, rather than a row that plays nothing.
//
// ── THE READ IS OFF-MAIN, ONCE PER MESSAGE, AND NEVER IN `body` ───────────────
//
// `ChatTrackResolver` runs `TrackRepository.resolvedTracks` (bounded to 100) from a
// `.task`, and `body` only ever reads the dictionary it left behind. The macOS
// UI-performance rules forbid database work in a view body outright, and a
// transcript re-evaluates its rows on every scroll tick.
//
// ── WHY NOT A `Table` ─────────────────────────────────────────────────────────
//
// `SearchResultsView` uses `Table` + `.contextMenu(forSelectionType:)` because it
// owns a selection. A transcript does not: these rows sit inside a scrolling
// conversation, there is no multi-select, and a nested `Table`'s own scroll view
// would fight the transcript's. So this is a `LazyVStack` of the shared
// ``TrackListRow`` with a per-row `.contextMenu`, which is the same row every other
// list surface renders.
import DesignSystem
import Persistence
import Services
import SwiftUI
import ViewModels

/// One chat row that still resolves to a live library track.
struct ChatTrackRow: Identifiable {
    let id: Int64
    let scoped: ProfileScopedTrack

    var track: TrackRecord {
        scoped.track
    }
}

/// The live library rows behind one message's lookups.
///
/// Owned as `@State` by the message row, so the read happens once per message and
/// survives every re-render of the transcript around it.
@MainActor
@Observable
final class ChatTrackResolver {
    private(set) var resolved: [Int64: ProfileScopedTrack] = [:]
    private var loadedKey: UUID?

    /// Resolves `trackIds` for `profileId`, at most once per `key`.
    ///
    /// A failed read leaves the map empty, which renders as "no rows" rather than as
    /// an error: the answer's prose is still above it and is still true.
    func load(key: UUID, repository: TrackRepository, profileId: Int64, trackIds: [Int64]) async {
        guard loadedKey != key else { return }
        loadedKey = key
        guard !trackIds.isEmpty else { return }
        resolved = await (try? repository.resolvedTracks(profileId: profileId, trackIds: trackIds)) ?? [:]
    }
}

extension ChatTrackResolver {
    /// Every library id this message's lookups answered with, de-duplicated in
    /// first-seen order and bounded by the repository's own batch cap.
    ///
    /// Ordered rather than a `Set` because `resolvedTracks` truncates to 100, and a
    /// `Set`'s iteration order would make WHICH hundred survive vary run to run.
    static func trackIds(in activities: [AssistantChatActivity]) -> [Int64] {
        var seen = Set<Int64>()
        var ids: [Int64] = []
        for activity in activities {
            for row in activity.rows {
                guard let trackId = row.trackId, seen.insert(trackId).inserted else { continue }
                ids.append(trackId)
                if ids.count == resolveLimit { return ids }
            }
        }
        return ids
    }

    /// `TrackRepository.resolvedTracks`' own bound, restated so the truncation is
    /// deterministic here rather than inside a `Set`.
    static let resolveLimit = 100
}

// MARK: - The list

struct LibraryChatTrackList: View {
    let rows: [AssistantChatRow]
    let resolved: [Int64: ProfileScopedTrack]
    /// Prefix for this list's accessibility identifiers, unique per activity row.
    let identifierPrefix: String

    @Environment(AppEnvironment.self) private var environment
    @Environment(AppSettings.self) private var settings
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    @State private var isExpanded = false
    @State private var favouriteOverrides: [Int64: Bool] = [:]
    @State private var tagEditRequest: TagEditorRequest?

    var body: some View {
        let displayed = Self.resolvedRows(rows, in: resolved)
        let visible = Array(Self.visibleRows(displayed, isExpanded: isExpanded).enumerated())
        if !displayed.isEmpty {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(visible, id: \.element.id) { position, row in
                    trackRow(row, position: position + 1)
                }
                if Self.showsExpander(displayed, isExpanded: isExpanded) {
                    expander(total: displayed.count)
                }
            }
            .padding(.leading, tokens.spacing.medium)
            .accessibilityIdentifier(identifierPrefix)
            .sheet(item: $tagEditRequest) { request in
                TagEditorSheet(records: request.records)
            }
        }
    }
}

// MARK: - Rows

private extension LibraryChatTrackList {
    func trackRow(_ row: ChatTrackRow, position: Int) -> some View {
        TrackListRow(
            number: position,
            title: row.track.displayTitle,
            artist: row.track.artistName,
            artistId: row.track.artistId,
            duration: row.track.duration,
            isPlaying: isCurrent(row),
            availability: row.track.availability,
            isFavourite: isFavourite(row),
            onToggleFavourite: { toggleFavourite(row) },
            karaokeState: environment.karaokeRowState(
                filePath: row.track.filePath,
                enabled: settings.karaokeEnabled
            )
        )
        .contentShape(Rectangle())
        .pointingHandCursor()
        .onTapGesture(count: 2) { play(startingAt: row) }
        .contextMenu { menu(for: row) }
        .accessibilityIdentifier("\(identifierPrefix).row.\(row.id)")
    }

    func expander(total: Int) -> some View {
        Button { isExpanded = true } label: {
            Label {
                Text(LibraryChatStrings.showAllTracks(count: total))
            } icon: {
                Image(systemName: "chevron.down")
            }
            .font(tokens.typography.caption.font)
        }
        .buttonStyle(.plain)
        .foregroundStyle(tokens.colors.accent.resolve(scheme))
        .padding(.vertical, tokens.spacing.xxSmall)
        .pointingHandCursor()
        .accessibilityIdentifier("\(identifierPrefix).expander")
    }

    func isCurrent(_ row: ChatTrackRow) -> Bool {
        row.id == environment.player.currentTrack?.trackID
    }

    func isFavourite(_ row: ChatTrackRow) -> Bool {
        favouriteOverrides[row.id] ?? row.scoped.isFavourite
    }
}

// MARK: - The menu, routed through the library's own action bodies

private extension LibraryChatTrackList {
    @ViewBuilder
    func menu(for row: ChatTrackRow) -> some View {
        Button { play(startingAt: row) } label: {
            Label { Text(MacAMPStrings.menuPlay) } icon: { Image(systemName: "play.fill") }
        }
        Button { actions.playNext([TrackRef(record: row.track)]) } label: {
            Label { Text(MacAMPStrings.menuPlayNext) } icon: { Image(systemName: "text.insert") }
        }
        Button { actions.enqueue([TrackRef(record: row.track)]) } label: {
            Label { Text(MacAMPStrings.menuAddToQueue) } icon: { Image(systemName: "text.append") }
        }
        KaraokeRenderMenuButton(filePaths: [row.track.filePath], enabled: settings.karaokeEnabled)
        if !environment.playlists.playlists.isEmpty {
            Divider()
            addToPlaylistMenu(row)
        }
        Divider()
        Button { tagEditRequest = TrackRowActions.tagEditRequest(for: [row.track]) } label: {
            Label { Text(MacAMPStrings.tagsMenuSingle) } icon: { Image(systemName: "tag") }
        }
    }

    func addToPlaylistMenu(_ row: ChatTrackRow) -> some View {
        Menu {
            ForEach(environment.playlists.playlists, id: \.playlist.id) { item in
                Button(item.playlist.name) {
                    actions.addTracks([row.id], toPlaylist: item.playlist)
                }
            }
        } label: {
            Label { Text(MacAMPStrings.menuAddToPlaylist) } icon: { Image(systemName: "music.note.list") }
        }
    }

    var actions: TrackRowActions {
        TrackRowActions(environment: environment)
    }

    /// Plays the whole answered list, starting at the row the listener acted on.
    ///
    /// The list rather than the one track — unlike ``StatsRowActions``, where the
    /// list is a ranking. Here it is a running order the assistant just proposed.
    func play(startingAt row: ChatTrackRow) {
        let refs = Self.resolvedRows(rows, in: resolved).map { TrackRef(record: $0.track) }
        actions.play(refs, startingAt: row.id, source: .search)
    }

    func toggleFavourite(_ row: ChatTrackRow) {
        let wasFavourite = isFavourite(row)
        favouriteOverrides[row.id] = !wasFavourite
        actions.toggleFavourite(row.track, wasFavourite: wasFavourite)
    }
}

// MARK: - Derivation (static so the composition suite can drive it)

extension LibraryChatTrackList {
    /// How many rows show before the expander.
    static let visibleLimit = 10

    /// The answered rows that still resolve, in the order the tool returned them.
    ///
    /// An id that no longer resolves is DROPPED rather than drawn greyed out: unlike
    /// the stats page, whose history rows are the point even when the file is gone,
    /// a lookup result exists only to be acted on.
    static func resolvedRows(
        _ rows: [AssistantChatRow],
        in resolved: [Int64: ProfileScopedTrack]
    ) -> [ChatTrackRow] {
        var seen = Set<Int64>()
        return rows.compactMap { row in
            guard
                let trackId = row.trackId,
                let scoped = resolved[trackId],
                seen.insert(trackId).inserted
            else {
                return nil
            }
            return ChatTrackRow(id: trackId, scoped: scoped)
        }
    }

    static func visibleRows(_ rows: [ChatTrackRow], isExpanded: Bool) -> [ChatTrackRow] {
        isExpanded ? rows : Array(rows.prefix(visibleLimit))
    }

    static func showsExpander(_ rows: [ChatTrackRow], isExpanded: Bool) -> Bool {
        !isExpanded && rows.count > visibleLimit
    }
}
