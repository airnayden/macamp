// RediscoveryService — the three "you have forgotten this" candidate lists.
//
// Rediscovery asks a different question from the listening digest: not "what did
// you play" but "what is worth playing again". Three lists, one profile:
//
//   1. FORGOTTEN FAVOURITES — tracks this profile favourited or played heavily,
//      with no play at all in the last ``silenceDays`` days.
//   2. NEVER PLAYED — tracks that have sat in the library long enough to have been
//      discovered (``settlingDays``) and still carry zero plays.
//   3. THROWBACKS — the tracks this profile played most in the SAME civil month of
//      an earlier year.
//
// Four rules are load-bearing:
//
//  1. **Only `present` tracks are ever surfaced.** A candidate list is a list of
//     things to play, so a `missing` or `externalOffline` row is filtered out at
//     every exit. The availability state machine keeps those rows in the library;
//     rediscovery simply never proposes them.
//  2. **Everything is profile-scoped.** History comes from `playEvent` filtered by
//     `profileId`, engagement from `profileTrackState`, and the library walk from
//     the visibility-scoped `tracksPage`. A rival profile's plays cannot reach this
//     profile's lists.
//  3. **Every read is bounded.** Events are keyset-paged newest-first and the walk
//     stops at the oldest instant a list can care about; the library walk stops at
//     `limit` results or ``maxScannedTracks``, whichever comes first. There is no
//     unbounded `fetchAll` anywhere.
//  4. **Month arithmetic goes through ``CivilMonth``.** Throwbacks name civil
//     months, so they use the SAME pure-integer helper the compactor and the digest
//     use — never `Calendar`, never `TimeZone`, never `strftime` in SQL.
//
// Frozen-column note: engagement is read from `profileTrackState` through
// ``ProfileScopedTrack``'s `resolved*` fields, never from the dead
// `track.playCount` / `track.isFavourite` columns.
//
// Horizon note: raw `playEvent` rows survive only ~24 months before
// ``PlayEventCompactor`` folds them into `playEventRollup`, which is keyed
// `(profileId, yearMonth, artistKey, genreKey)` and carries NO `trackId`. Per-track
// throwbacks therefore CANNOT come from the rollup and are computed from raw events
// alone — so they reach back at most as far as the raw horizon does.
import Foundation
import Persistence

/// Why a track surfaced as a rediscovery candidate.
public enum RediscoveryReason: Sendable, Equatable, Hashable {
    /// Historically engaged with, then silent for the whole silence window.
    case forgottenFavourite(isFavourite: Bool, playCount: Int, listenedCount: Int)
    /// In the library past the settling window with no play ever recorded.
    /// `dateAdded` is `nil` for rows imported before the column was populated.
    case neverPlayed(dateAdded: TimeInterval?)
    /// A top track of the same civil month in an earlier year. `yearMonth` is the
    /// `"YYYY-MM"` key of the single month that contributed the most plays.
    case throwback(yearMonth: String, plays: Int)
}

/// One playable rediscovery candidate, with the evidence that produced it.
public struct RediscoveryCandidate: Sendable, Equatable, Hashable {
    /// The library row's id. Always `present` at the moment it was produced.
    public let trackId: Int64
    /// The live title, as the player would show it.
    public let title: String?
    /// The live artist, as the player would show it.
    public let artistName: String?
    /// Why this track surfaced.
    public let reason: RediscoveryReason

    public init(trackId: Int64, title: String?, artistName: String?, reason: RediscoveryReason) {
        self.trackId = trackId
        self.title = title
        self.artistName = artistName
        self.reason = reason
    }
}

/// Produces one profile's rediscovery candidate lists.
public protocol RediscoveryProviding: Sendable {
    /// Engaged-with tracks with no play in the silence window, strongest engagement
    /// first. Empty — never an error — when the profile has no history.
    func forgottenFavourites(profileId: Int64, limit: Int) async throws -> [RediscoveryCandidate]

    /// Settled library tracks this profile has never played, in library order.
    func neverPlayed(profileId: Int64, limit: Int) async throws -> [RediscoveryCandidate]

    /// This profile's top tracks of the same civil month in earlier years, most
    /// plays first.
    func throwbacks(profileId: Int64, limit: Int) async throws -> [RediscoveryCandidate]
}

/// The production ``RediscoveryProviding`` over the v15 statistics tables and the
/// profile-scoped library.
public struct RediscoveryService: RediscoveryProviding {
    /// Days without a single play before an engaged-with track counts as forgotten.
    public static let silenceDays: Double = 90
    /// Days a track must have been in the library before "never played" is a
    /// statement about the listener rather than about the import being recent.
    public static let settlingDays: Double = 14
    /// Plays (or listens) at or above which an un-favourited track still counts as
    /// historically engaged with.
    public static let engagementThreshold = 3
    /// How many earlier years a throwback reaches back for. Raw events survive ~24
    /// months, so years 3–5 are normally empty; they cost one `Set` membership test
    /// each and keep the list correct on an imported archive.
    public static let throwbackYearsBack = 5
    /// Ceiling on any single list.
    public static let maxLimit = 100
    /// Ceiling on the engagement candidate pool drawn from `profileTrackState`.
    static let candidatePoolLimit = 200
    /// Ceiling on the library rows the never-played walk will look at.
    static let maxScannedTracks = 5000

    private let events: any PlayEventRepositoryProviding
    private let tracks: TrackRepository
    private let now: @Sendable () -> Date
    private let pageSize: Int

    /// - Parameters:
    ///   - events: Windowed access to `playEvent`.
    ///   - tracks: The library. Held concretely for its `profileTrackState`
    ///     ProfileState reads, which are concrete-extension APIs by repo precedent.
    ///   - now: The reference clock every window is measured back from. Injected so
    ///     a test can place "now" on a boundary without waiting for real time.
    ///   - pageSize: Rows per keyset page. A free parameter precisely so a test can
    ///     prove the output does not depend on it.
    public init(
        events: any PlayEventRepositoryProviding,
        tracks: TrackRepository,
        now: @escaping @Sendable () -> Date = { Date() },
        pageSize: Int = InsightPaging.defaultPageSize
    ) {
        self.events = events
        self.tracks = tracks
        self.now = now
        self.pageSize = max(1, pageSize)
    }

    /// Convenience over the application database.
    public init(
        _ appDatabase: AppDatabase,
        now: @escaping @Sendable () -> Date = { Date() },
        pageSize: Int = InsightPaging.defaultPageSize
    ) {
        self.init(
            events: PlayEventRepository(appDatabase),
            tracks: TrackRepository(appDatabase),
            now: now,
            pageSize: pageSize
        )
    }
}

// MARK: - Forgotten favourites

public extension RediscoveryService {
    func forgottenFavourites(profileId: Int64, limit: Int) async throws -> [RediscoveryCandidate] {
        let engaged = try await engagedTracks(profileId: profileId)
        guard !engaged.isEmpty else { return [] }
        // Newest-first paging stops at the cutoff, so the scan costs only the plays
        // inside the silence window — not the whole surviving history.
        let silenceStart = now().timeIntervalSince1970 - Self.silenceDays * ListeningLocalTime.secondsPerDay
        let recent = try await events.playedTrackIds(
            profileId: profileId,
            since: silenceStart,
            pageSize: pageSize
        )
        return engaged
            .filter { !recent.contains($0.key) }
            .map(\.value)
            .sorted(by: Self.engagementOrder)
            .prefix(InsightPaging.cap(limit, ceiling: Self.maxLimit))
            .compactMap(Self.forgottenCandidate)
    }
}

private extension RediscoveryService {
    /// The pool of tracks this profile has historically engaged with, keyed by id.
    ///
    /// Both reads drive from the sparse `profileTrackState` rows (favourites via the
    /// covering index, top-played by descending count), so neither ever scans the
    /// `track` table. Non-`present` rows are dropped here rather than at the exit,
    /// so an unreachable file never occupies a slot in the pool.
    func engagedTracks(profileId: Int64) async throws -> [Int64: ProfileScopedTrack] {
        let tracks = tracks
        let favourites = try await Task.detached(priority: .utility) {
            try tracks.favouriteTracks(profileId: profileId, limit: Self.candidatePoolLimit)
        }.value
        let played = try await tracks.topPlayedTracks(profileId: profileId, limit: Self.candidatePoolLimit)
        var pool: [Int64: ProfileScopedTrack] = [:]
        for scoped in favourites + played {
            guard let trackId = scoped.track.id,
                  scoped.track.availability == .present,
                  Self.isEngaged(scoped)
            else { continue }
            pool[trackId] = scoped
        }
        return pool
    }

    static func isEngaged(_ scoped: ProfileScopedTrack) -> Bool {
        scoped.isFavourite
            || scoped.playCount >= engagementThreshold
            || scoped.listenedCount >= engagementThreshold
    }

    /// Favourites first, then the heaviest counts, then the lowest id. Total, so the
    /// output cannot depend on the unordered pool dictionary it is sorted from.
    static func engagementOrder(_ lhs: ProfileScopedTrack, _ rhs: ProfileScopedTrack) -> Bool {
        if lhs.isFavourite != rhs.isFavourite { return lhs.isFavourite }
        if lhs.playCount != rhs.playCount { return lhs.playCount > rhs.playCount }
        if lhs.listenedCount != rhs.listenedCount { return lhs.listenedCount > rhs.listenedCount }
        return (lhs.track.id ?? 0) < (rhs.track.id ?? 0)
    }

    static func forgottenCandidate(_ scoped: ProfileScopedTrack) -> RediscoveryCandidate? {
        guard let trackId = scoped.track.id else { return nil }
        return RediscoveryCandidate(
            trackId: trackId,
            title: scoped.track.title,
            artistName: scoped.track.artistName,
            reason: .forgottenFavourite(
                isFavourite: scoped.isFavourite,
                playCount: scoped.playCount,
                listenedCount: scoped.listenedCount
            )
        )
    }
}

// MARK: - Never played

public extension RediscoveryService {
    func neverPlayed(profileId: Int64, limit: Int) async throws -> [RediscoveryCandidate] {
        let capped = InsightPaging.cap(limit, ceiling: Self.maxLimit)
        let addedBefore = now().timeIntervalSince1970 - Self.settlingDays * ListeningLocalTime.secondsPerDay
        // Two independent records of "played": every surviving raw event (which
        // includes skips), and the profile's own counters (which outlive the raw
        // horizon). A track is a candidate only when BOTH are silent about it.
        let everPlayed = try await events.playedTrackIds(profileId: profileId, since: 0, pageSize: pageSize)
        var found: [RediscoveryCandidate] = []
        var scanned = 0
        var cursor: PageCursor<String>?
        repeat {
            let page = try await tracks.tracksPage(
                profileId: profileId,
                after: cursor,
                limit: min(pageSize, InsightPaging.resolveChunkSize)
            )
            scanned += page.items.count
            let settled = page.items.filter { Self.isSettled($0, addedBefore: addedBefore, playedIds: everPlayed) }
            try await found.append(contentsOf: unplayedCandidates(profileId: profileId, settled: settled))
            cursor = page.nextCursor
        } while cursor != nil && found.count < capped && scanned < Self.maxScannedTracks
        return Array(found.prefix(capped))
    }
}

private extension RediscoveryService {
    /// The cheap, page-local filters: reachable, old enough, and unseen by the raw
    /// event log. `dateAdded == nil` predates the column being populated, so the
    /// track has been in the library at least as long as the window requires.
    static func isSettled(_ track: TrackRecord, addedBefore: TimeInterval, playedIds: Set<Int64>) -> Bool {
        guard let trackId = track.id, track.availability == .present else { return false }
        guard !playedIds.contains(trackId) else { return false }
        guard let dateAdded = track.dateAdded else { return true }
        return dateAdded <= addedBefore
    }

    /// Resolves one page's survivors against `profileTrackState` in a single batch
    /// and keeps only those the profile has neither played nor listened through.
    func unplayedCandidates(profileId: Int64, settled: [TrackRecord]) async throws -> [RediscoveryCandidate] {
        let ids = settled.compactMap(\.id)
        guard !ids.isEmpty else { return [] }
        let resolved = try await tracks.resolvedTracks(profileId: profileId, trackIds: ids)
        return ids.compactMap { trackId in
            guard let scoped = resolved[trackId], scoped.playCount == 0, scoped.listenedCount == 0 else {
                return nil
            }
            return RediscoveryCandidate(
                trackId: trackId,
                title: scoped.track.title,
                artistName: scoped.track.artistName,
                reason: .neverPlayed(dateAdded: scoped.track.dateAdded)
            )
        }
    }
}

// MARK: - Throwbacks

/// One track's showing across the throwback months, collapsed for ranking.
///
/// A struct rather than a tuple: three members would trip the `large_tuple` budget,
/// and the peak month has to travel with the total to build the reason.
private struct ThrowbackTally {
    let trackId: Int64
    let yearMonth: String
    let plays: Int
}

public extension RediscoveryService {
    func throwbacks(profileId: Int64, limit: Int) async throws -> [RediscoveryCandidate] {
        let reference = CivilMonth.monthIndex(fromEpochSeconds: now().timeIntervalSince1970)
        let targets = Self.throwbackMonthIndices(reference: reference)
        guard let oldest = targets.min() else { return [] }
        let counts = try await events.reduceEvents(
            profileId: profileId,
            pageSize: pageSize,
            stoppingBefore: CivilMonth.startOfMonthEpochSeconds(atIndex: oldest),
            into: [Int64: [Int: Int]]()
        ) { counts, event in
            guard let trackId = event.trackId else { return }
            let month = CivilMonth.monthIndex(fromEpochSeconds: event.startedAt)
            guard targets.contains(month) else { return }
            counts[trackId, default: [:]][month, default: 0] += 1
        }
        let ranked = counts.map(Self.tally).sorted(by: Self.throwbackOrder)
        let capped = InsightPaging.cap(limit, ceiling: Self.maxLimit)
        let present = try await tracks.presentTracks(
            profileId: profileId,
            orderedIds: ranked.map(\.trackId),
            limit: capped
        )
        let plays = Dictionary(ranked.map { ($0.trackId, $0) }, uniquingKeysWith: { first, _ in first })
        return present.compactMap { scoped in Self.throwbackCandidate(scoped, tally: plays) }
    }
}

private extension RediscoveryService {
    /// The same civil month, one to ``throwbackYearsBack`` years earlier. A month
    /// index is `year * 12 + (month - 1)`, so subtracting whole years is exact.
    static func throwbackMonthIndices(reference: Int) -> Set<Int> {
        Set((1 ... throwbackYearsBack).map { reference - $0 * CivilMonth.monthsPerYear })
    }

    /// Collapses one track's per-month counts to a total plus its peak month. Ties on
    /// the peak resolve to the EARLIER month, so the reason is deterministic.
    static func tally(_ entry: (key: Int64, value: [Int: Int])) -> ThrowbackTally {
        let peak = entry.value.max { lhs, rhs in
            lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
        }
        return ThrowbackTally(
            trackId: entry.key,
            yearMonth: CivilMonth.yearMonthKey(atIndex: peak?.key ?? 0),
            plays: entry.value.values.reduce(0, +)
        )
    }

    /// Most plays first, then the lowest id — total, so the ranking cannot depend on
    /// the unordered tally dictionary.
    static func throwbackOrder(_ lhs: ThrowbackTally, _ rhs: ThrowbackTally) -> Bool {
        lhs.plays == rhs.plays ? lhs.trackId < rhs.trackId : lhs.plays > rhs.plays
    }

    static func throwbackCandidate(
        _ scoped: ProfileScopedTrack,
        tally: [Int64: ThrowbackTally]
    ) -> RediscoveryCandidate? {
        guard let trackId = scoped.track.id, let entry = tally[trackId] else { return nil }
        return RediscoveryCandidate(
            trackId: trackId,
            title: scoped.track.title,
            artistName: scoped.track.artistName,
            reason: .throwback(yearMonth: entry.yearMonth, plays: entry.plays)
        )
    }
}
