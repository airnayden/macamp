// ListeningStatsViewModel — the ONE read model behind every listening-statistics
// surface (the Stats page, its window tabs, the recent-plays list and the right-panel
// Stats tab).
//
// Three properties define it, and every choice below serves one of them:
//
//  1. **One pass per profile.** ``load(profileId:)`` performs ALL of the I/O the whole
//     screen needs — the digest, one page of recent plays, one ranked scan of the
//     replay heatmaps, four bounded top-track reads and at most three batched track
//     resolutions — and nothing else in this type ever opens a repository. Changing
//     ``selectedWindow`` is therefore a pure re-read of already-loaded state: zero
//     queries, zero digest rebuilds, and the three published collections keep their
//     identity so SwiftUI has nothing to diff.
//  2. **Snapshot keying, not live tags.** A digest identifies a track by
//     ``ListeningTrackIdentity/identityKey`` derived from the text the history
//     *snapshotted at capture*. So does this model: ``topTrackResolution`` is built by
//     re-deriving that key from `playEvent`'s OWN denormalised columns (via
//     ``TopTrackId``), never from the library row's current tags. Retagging a file
//     moves its live title but not its history, and the row still resolves.
//  3. **Per-window resolution.** Each ``ListeningWindowKind`` gets its OWN
//     `identityKey → track` map, built from a `topTrackIds` read bounded by that
//     window's own `startedAt`. An all-time-only ranking would leave a track that is
//     hot this week but unremarkable over a lifetime unresolvable in the 7-day list.
//
// Resolution is best-effort by design: a track the user has since deleted resolves to
// `nil` and the row renders from its snapshot text alone. That is the whole point of a
// survivable history — see `ListeningDigest.swift`.
import Foundation
import Observation
import Persistence
import Services

/// One entry of the recent-plays list: the raw event plus the library row it still
/// points at, or `nil` when that row is gone.
public struct RecentPlay: Identifiable, Sendable, Equatable {
    /// The event's rowid. Stable within one profile's history.
    public let id: Int64
    /// The play as captured, carrying its own artist/title/album snapshot.
    public let event: PlayEventRecord
    /// The live library row, or `nil` when the track no longer exists.
    public let resolved: ProfileScopedTrack?

    public init(event: PlayEventRecord, resolved: ProfileScopedTrack?) {
        id = event.id ?? 0
        self.event = event
        self.resolved = resolved
    }
}

/// The shared, `@Observable` read model for one profile's listening statistics.
@MainActor
@Observable
public final class ListeningStatsViewModel {
    /// Recent plays fetched in one page. Fifty is a screenful and change, and it keeps
    /// the union that feeds ``TrackRepository/resolvedTracks(profileId:trackIds:)``
    /// inside three batches.
    public nonisolated static let recentPlaysLimit = 50

    /// Rows a top-tracks / top-artists / top-genres list shows before "see all". The
    /// digest itself keeps ``ListeningDigestBuilder/topEntityLimit``; this is the
    /// display slice over it.
    public nonisolated static let topListDisplayLimit = 10

    /// Rows the most-replayed list shows. ``replayedRows`` itself keeps
    /// ``ListeningDigestBuilder/replayEntityLimit`` so a "see all" needs no reload.
    public nonisolated static let replayedDisplayLimit = 10

    /// Ids per ``TrackRepository/resolvedTracks(profileId:trackIds:)`` call — the same
    /// ceiling that read applies internally, so no batch is ever silently truncated.
    nonisolated static let resolveBatchSize = 100

    /// The profile's digest, or `nil` before the first load (or after a failed one).
    public private(set) var digest: ListeningDigest?

    /// The window the UI is showing. Assigning it performs NO repository work.
    public var selectedWindow: ListeningWindowKind = .last30Days

    /// Newest-first, at most ``recentPlaysLimit`` entries.
    public private(set) var recentPlays: [RecentPlay] = []

    /// The lifetime most-replayed list, ranked exactly as ``ListeningDigest/mostReplayed``.
    public private(set) var replayedRows: [ReplayedRow] = []

    /// Per-window `identityKey → live track` maps. Read through
    /// ``resolvedTopTrack(_:in:)`` rather than directly.
    public private(set) var topTrackResolution: [ListeningWindowKind: [String: ProfileScopedTrack]] = [:]

    /// `true` while ``load(profileId:)`` is in flight.
    public private(set) var isLoading = false

    @ObservationIgnored private let digestBuilder: any ListeningDigestBuilding
    @ObservationIgnored private let events: any PlayEventRepositoryProviding
    @ObservationIgnored private let heat: any PlaySegmentHeatRepositoryProviding
    /// The CONCRETE repository on purpose: `resolvedTracks` is a ProfileState read,
    /// and those live on `TrackRepository`'s concrete extension by long-standing
    /// precedent rather than on `TrackRepositoryProviding`.
    @ObservationIgnored private let tracks: TrackRepository

    /// Bumped by every ``load(profileId:)`` so a slow load for a profile the user has
    /// already switched away from cannot overwrite the newer one's result.
    @ObservationIgnored private var generation = 0

    public init(
        digestBuilder: any ListeningDigestBuilding,
        events: any PlayEventRepositoryProviding,
        heat: any PlaySegmentHeatRepositoryProviding,
        tracks: TrackRepository
    ) {
        self.digestBuilder = digestBuilder
        self.events = events
        self.heat = heat
        self.tracks = tracks
    }

    // MARK: - Derived state (no I/O)

    /// The selected window's facets, or `nil` before the first load.
    public var selectedWindowDigest: ListeningWindowDigest? {
        digest?.window(selectedWindow)
    }

    /// The selected window's busiest daypart, or `nil` when it has no plays at all.
    ///
    /// Ties resolve to the earlier ``ListeningDaypart`` in declaration order, so the
    /// answer does not depend on how the dayparts happened to be enumerated.
    public var mostActiveDaypart: ListeningDaypartDigest? {
        var best: ListeningDaypartDigest?
        for candidate in selectedWindowDigest?.dayparts ?? [] where candidate.plays > (best?.plays ?? 0) {
            best = candidate
        }
        return best
    }

    /// Completions over plays for one window.
    ///
    /// Deliberately NOT ``ListeningWindowDigest/meanCompletion``: that figure is RAW
    /// events only, because a rollup keeps counts rather than fractions, so it would
    /// silently step down the month a listener's history crosses the compaction
    /// horizon. `completions` and `totalPlays` are both raw ∪ rollups, so their ratio
    /// stays coherent over the full horizon — the honest "how often do you finish a
    /// track" number.
    public func completionRate(for window: ListeningWindowKind) -> Double {
        guard let facets = digest?.window(window) else { return 0 }
        return StatsRounding.ratio(Double(facets.completions), over: Double(facets.totalPlays))
    }

    /// The live library row behind one of a window's top tracks, or `nil` when the
    /// track was deleted (or ranked below this window's resolution horizon).
    public func resolvedTopTrack(
        _ stat: ListeningTrackStat,
        in window: ListeningWindowKind
    ) -> ProfileScopedTrack? {
        topTrackResolution[window]?[stat.track.identityKey]
    }

    // MARK: - Loading

    /// Reads everything this screen needs for one profile, in one pass.
    ///
    /// Generation-guarded: an overlapping call always wins, so switching profiles
    /// twice in quick succession cannot leave the first profile's rows on screen. A
    /// failed read degrades to empty state rather than surfacing an error — statistics
    /// are a read-only summary and a partial one would be worse than none.
    public func load(profileId: Int64) async {
        generation &+= 1
        let token = generation
        isLoading = true
        let snapshot: LoadedStats
        do {
            snapshot = try await makeSnapshot(profileId: profileId)
        } catch {
            snapshot = LoadedStats()
        }
        guard token == generation else { return }
        digest = snapshot.digest
        recentPlays = snapshot.recentPlays
        replayedRows = snapshot.replayedRows
        topTrackResolution = snapshot.topTrackResolution
        isLoading = false
    }

    /// Re-reads the profile. Identical to ``load(profileId:)`` — named separately so a
    /// pull-to-refresh / menu action reads as one.
    public func refresh(profileId: Int64) async {
        await load(profileId: profileId)
    }
}

// MARK: - The one I/O pass

/// Everything one ``ListeningStatsViewModel/load(profileId:)`` produces, assembled off
/// the published properties so a stale generation can be dropped whole.
struct LoadedStats {
    var digest: ListeningDigest?
    var recentPlays: [RecentPlay] = []
    var replayedRows: [ReplayedRow] = []
    var topTrackResolution: [ListeningWindowKind: [String: ProfileScopedTrack]] = [:]
}

private extension ListeningStatsViewModel {
    func makeSnapshot(profileId: Int64) async throws -> LoadedStats {
        // Hoisted so the concurrent children capture Sendable values rather than
        // reaching back into a main-actor-isolated instance.
        let builder = digestBuilder
        let eventsRepository = events
        async let digestResult = builder.buildDigest(profileId: profileId)
        async let recentResult = eventsRepository.playEvents(
            profileId: profileId,
            before: nil,
            limit: Self.recentPlaysLimit
        )
        let digest = try await digestResult
        let recentPage = try await recentResult
        let recentEvents = recentPage.items

        let replayCandidates = try await Self.rankedReplayCandidates(heat: heat, profileId: profileId)
        let perWindowTop = try await Self.topTracksPerWindow(
            events: eventsRepository,
            profileId: profileId,
            digest: digest
        )
        let resolved = try await Self.resolveTracks(
            tracks: tracks,
            profileId: profileId,
            ids: Self.unionedTrackIds(
                perWindowTop: perWindowTop,
                recentEvents: recentEvents,
                replayCandidates: replayCandidates
            )
        )
        return LoadedStats(
            digest: digest,
            recentPlays: recentEvents.map { RecentPlay(event: $0, resolved: $0.trackId.flatMap { resolved[$0] }) },
            replayedRows: Self.makeReplayedRows(replayCandidates, resolved: resolved),
            topTrackResolution: Self.makeWindowResolution(perWindowTop, resolved: resolved)
        )
    }

    /// One bounded `topTrackIds` read per window, each anchored at that window's own
    /// lower bound so a track that is hot only inside a short span still resolves
    /// there. The limit is DOUBLED because `topTrackIds` groups strictly finer than
    /// the digest's case-folded identity (case-sensitive, and split per `trackId`), so
    /// the surplus absorbs the splits a displayed top-10 identity would otherwise fall
    /// out of range behind.
    static func topTracksPerWindow(
        events: any PlayEventRepositoryProviding,
        profileId: Int64,
        digest: ListeningDigest
    ) async throws -> [ListeningWindowKind: [TopTrackId]] {
        var perWindow: [ListeningWindowKind: [TopTrackId]] = [:]
        for window in ListeningWindowKind.allCases {
            let since = TimeInterval(digest.window(window)?.startedAt ?? 0)
            perWindow[window] = try await events.topTrackIds(
                profileId: profileId,
                since: since,
                limit: ListeningDigestBuilder.topEntityLimit * 2
            )
        }
        return perWindow
    }

    /// Every track id the screen might render, deduplicated and sorted so the batching
    /// below is deterministic. Bounded by construction: at most 4 × 50 window rows,
    /// ``recentPlaysLimit`` events and ``ListeningDigestBuilder/replayEntityLimit``
    /// heatmaps — three ``resolveBatchSize`` batches at worst.
    static func unionedTrackIds(
        perWindowTop: [ListeningWindowKind: [TopTrackId]],
        recentEvents: [PlayEventRecord],
        replayCandidates: [RankedReplayCandidate]
    ) -> [Int64] {
        var ids = Set<Int64>()
        for rows in perWindowTop.values {
            ids.formUnion(rows.map(\.trackId))
        }
        ids.formUnion(recentEvents.compactMap(\.trackId))
        ids.formUnion(replayCandidates.map(\.trackId))
        return ids.sorted()
    }

    /// Resolves every id in ``resolveBatchSize``-sized batches. Batched rather than
    /// truncated: `resolvedTracks` keeps an arbitrary prefix of whatever it is handed
    /// once past its own bound, so a single unbounded call would drop ids no caller
    /// could predict. The batch stays at 100 regardless of where that bound sits —
    /// this surface reads history, and a wider page buys it nothing.
    static func resolveTracks(
        tracks: TrackRepository,
        profileId: Int64,
        ids: [Int64]
    ) async throws -> [Int64: ProfileScopedTrack] {
        var resolved: [Int64: ProfileScopedTrack] = [:]
        for start in stride(from: 0, to: ids.count, by: resolveBatchSize) {
            let batch = Array(ids[start ..< min(start + resolveBatchSize, ids.count)])
            let page = try await tracks.resolvedTracks(profileId: profileId, trackIds: batch)
            resolved.merge(page) { current, _ in current }
        }
        return resolved
    }

    /// Keys each window's rows by the identity the DIGEST would derive — rebuilt from
    /// the event snapshot's own columns, never from the resolved row's live tags.
    ///
    /// `topTrackIds` returns `plays DESC, trackId ASC`, a total order, so when two
    /// finer-grained rows fold onto one identity key (a case variant, a duplicate
    /// import) the busier one wins and the choice is reproducible.
    static func makeWindowResolution(
        _ perWindowTop: [ListeningWindowKind: [TopTrackId]],
        resolved: [Int64: ProfileScopedTrack]
    ) -> [ListeningWindowKind: [String: ProfileScopedTrack]] {
        var resolution: [ListeningWindowKind: [String: ProfileScopedTrack]] = [:]
        for (window, rows) in perWindowTop {
            var map: [String: ProfileScopedTrack] = [:]
            for row in rows {
                let key = ListeningTrackIdentity(
                    artistName: row.artistName,
                    title: row.title,
                    albumTitle: row.albumTitle
                ).identityKey
                guard map[key] == nil, let track = resolved[row.trackId] else { continue }
                map[key] = track
            }
            resolution[window] = map
        }
        return resolution
    }
}
