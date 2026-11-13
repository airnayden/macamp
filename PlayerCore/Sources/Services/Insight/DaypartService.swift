// DaypartService — what this profile actually listens to at each time of day.
//
// "I play this in the morning" is a statement about the listener's OWN wall clock
// when they pressed play, which is why `playEvent` stamps `utcOffsetSeconds` at
// capture. Every local hour here is derived from that stored pair through
// ``ListeningLocalTime`` — the SAME helper the listening digest's hour facets use.
// There is deliberately no `Calendar`, no `TimeZone` arithmetic and no `strftime`
// in SQL: a second implementation would eventually disagree with the digest about
// which hour an event fell in, and a history re-bucketed by the machine's current
// zone would rewrite itself whenever the listener travelled.
//
// The one place a `TimeZone` appears is ``DaypartService/currentDaypart()``, which
// asks "what daypart is it *now*" — a question about the present moment that stored
// data cannot answer. It reads the injected zone's offset exactly the way
// ``PlayEventRecorder`` stamps one, then hands it to ``ListeningLocalTime``.
//
// Scans are bounded the same way the rest of the insight engine's are: keyset pages
// newest-first, stopping at ``DaypartService/historyDays`` back, and candidate ids
// resolved to playable rows in capped batches. Only `present` tracks are surfaced —
// a daypart list is a list of things to play.
import Foundation
import Persistence

/// A coarse time-of-day bucket over the listener's own local hours.
public enum Daypart: String, Sendable, CaseIterable, Codable {
    /// Local hours 5–11.
    case morning
    /// Local hours 12–16.
    case afternoon
    /// Local hours 17–21.
    case evening
    /// Local hours 22–4, the only bucket that wraps midnight.
    case night
}

public extension Daypart {
    /// The bucket a local hour falls in.
    ///
    /// `night` is the `default` arm rather than an explicit `22...23, 0...4` pair
    /// because the wrap makes those two ranges one bucket; any hour outside the
    /// three daylight ranges — including an out-of-domain one — is night.
    static func containing(localHour hour: Int) -> Daypart {
        switch hour {
        case 5 ... 11: .morning
        case 12 ... 16: .afternoon
        case 17 ... 21: .evening
        default: .night
        }
    }
}

/// One track's standing inside a single daypart.
public struct DaypartTrack: Sendable, Equatable, Hashable {
    /// The bucket this ranking belongs to.
    public let daypart: Daypart
    /// The library row's id. Always `present` at the moment it was produced.
    public let trackId: Int64
    /// The live title, as the player would show it.
    public let title: String?
    /// The live artist, as the player would show it.
    public let artistName: String?
    /// Plays recorded inside this daypart across the history window.
    public let plays: Int

    public init(daypart: Daypart, trackId: Int64, title: String?, artistName: String?, plays: Int) {
        self.daypart = daypart
        self.trackId = trackId
        self.title = title
        self.artistName = artistName
        self.plays = plays
    }
}

/// Produces one profile's per-daypart listening tops.
public protocol DaypartProviding: Sendable {
    /// The bucket the listener is in right now.
    func currentDaypart() -> Daypart

    /// This profile's most-played tracks inside one daypart, most plays first.
    /// Empty — never an error — when the profile has no history there.
    func topTracks(profileId: Int64, daypart: Daypart, limit: Int) async throws -> [DaypartTrack]

    /// Every daypart the profile actually listened in, each with its own ranking.
    /// A daypart with no playable history is absent rather than empty.
    func topTracksByDaypart(profileId: Int64, limit: Int) async throws -> [Daypart: [DaypartTrack]]
}

/// The production ``DaypartProviding`` over the v15 `playEvent` table.
public struct DaypartService: DaypartProviding {
    /// How far back a daypart ranking looks. A year covers seasonal habits while
    /// staying well inside the raw-event horizon the compactor preserves.
    public static let historyDays: Double = 365
    /// Ceiling on any single daypart list.
    public static let maxLimit = 100

    private let events: any PlayEventRepositoryProviding
    private let tracks: TrackRepository
    private let now: @Sendable () -> Date
    private let timeZone: TimeZone
    private let pageSize: Int

    /// - Parameters:
    ///   - events: Windowed access to `playEvent`.
    ///   - tracks: The library, held concretely for its profile-resolved batch read.
    ///   - now: The reference clock the history window is measured back from, and
    ///     the instant ``currentDaypart()`` reports on.
    ///   - timeZone: The zone whose offset ``currentDaypart()`` uses. Stored events
    ///     carry their own offset and never consult this.
    ///   - pageSize: Rows per keyset page, free so a test can prove the output does
    ///     not depend on it.
    public init(
        events: any PlayEventRepositoryProviding,
        tracks: TrackRepository,
        now: @escaping @Sendable () -> Date = { Date() },
        timeZone: TimeZone = .current,
        pageSize: Int = InsightPaging.defaultPageSize
    ) {
        self.events = events
        self.tracks = tracks
        self.now = now
        self.timeZone = timeZone
        self.pageSize = max(1, pageSize)
    }

    /// Convenience over the application database.
    public init(_ appDatabase: AppDatabase, now: @escaping @Sendable () -> Date = { Date() }) {
        self.init(events: PlayEventRepository(appDatabase), tracks: TrackRepository(appDatabase), now: now)
    }

    public func currentDaypart() -> Daypart {
        let instant = now().timeIntervalSince1970
        let offset = timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: instant))
        return Daypart.containing(
            localHour: ListeningLocalTime.hourOfDay(startedAt: instant, utcOffsetSeconds: offset)
        )
    }

    public func topTracks(profileId: Int64, daypart: Daypart, limit: Int) async throws -> [DaypartTrack] {
        try await topTracksByDaypart(profileId: profileId, limit: limit)[daypart] ?? []
    }

    public func topTracksByDaypart(profileId: Int64, limit: Int) async throws -> [Daypart: [DaypartTrack]] {
        let capped = InsightPaging.cap(limit, ceiling: Self.maxLimit)
        let floor = max(0, now().timeIntervalSince1970 - Self.historyDays * ListeningLocalTime.secondsPerDay)
        let tally = try await events.reduceEvents(
            profileId: profileId,
            pageSize: pageSize,
            stoppingBefore: floor,
            into: DaypartTally()
        ) { tally, event in tally.ingest(event) }
        var ranked: [Daypart: [DaypartTrack]] = [:]
        for daypart in Daypart.allCases {
            let rows = try await playable(profileId: profileId, daypart: daypart, tally: tally, limit: capped)
            guard !rows.isEmpty else { continue }
            ranked[daypart] = rows
        }
        return ranked
    }
}

private extension DaypartService {
    /// Resolves one daypart's ranked ids to playable rows, preserving rank order and
    /// carrying each row's play count back out of the tally.
    func playable(
        profileId: Int64,
        daypart: Daypart,
        tally: DaypartTally,
        limit: Int
    ) async throws -> [DaypartTrack] {
        let counts = tally.ranked(daypart)
        guard !counts.isEmpty else { return [] }
        let present = try await tracks.presentTracks(
            profileId: profileId,
            orderedIds: counts.map(\.trackId),
            limit: limit
        )
        let plays = Dictionary(counts.map { ($0.trackId, $0.plays) }, uniquingKeysWith: { first, _ in first })
        return present.compactMap { scoped in
            guard let trackId = scoped.track.id, let count = plays[trackId] else { return nil }
            return DaypartTrack(
                daypart: daypart,
                trackId: trackId,
                title: scoped.track.title,
                artistName: scoped.track.artistName,
                plays: count
            )
        }
    }
}

// MARK: - Tally

/// Per-daypart play counts, keyed by track.
///
/// `Sendable` because it is the accumulator handed to
/// ``PlayEventRepositoryProviding/reduceEvents(profileId:pageSize:stoppingBefore:into:_:)``,
/// which is a `nonisolated async` scan.
private struct DaypartTally {
    /// One track's standing inside a daypart, before it is resolved to a library row.
    struct Count {
        let trackId: Int64
        let plays: Int
    }

    private var counts: [Daypart: [Int64: Int]] = [:]

    mutating func ingest(_ event: PlayEventRecord) {
        guard let trackId = event.trackId else { return }
        let hour = ListeningLocalTime.hourOfDay(
            startedAt: event.startedAt,
            utcOffsetSeconds: event.utcOffsetSeconds
        )
        counts[Daypart.containing(localHour: hour), default: [:]][trackId, default: 0] += 1
    }

    /// Most plays first, then the lowest id — total, so the ranking cannot depend on
    /// the unordered dictionary it is derived from.
    func ranked(_ daypart: Daypart) -> [Count] {
        (counts[daypart] ?? [:])
            .map { Count(trackId: $0.key, plays: $0.value) }
            .sorted { lhs, rhs in
                lhs.plays == rhs.plays ? lhs.trackId < rhs.trackId : lhs.plays > rhs.plays
            }
    }
}

// MARK: - Shared insight primitives

/// Bounds shared by every insight scan.
///
/// One home for the paging constants so ``RediscoveryService`` and
/// ``DaypartService`` cannot drift on how far back they read or how many candidate
/// ids they will resolve.
public enum InsightPaging {
    /// Rows per keyset page, matching the statistics repository's own ceiling.
    public static let defaultPageSize = PlayEventRepository.fetchLimit
    /// Ids per profile-resolved batch. `resolvedTracks` caps the list it is handed,
    /// so an unbounded chunk would be silently truncated in a nondeterministic order.
    /// Held at 100 independently of that cap: these scans rank candidates, and a
    /// wider page only makes each round trip heavier.
    static let resolveChunkSize = 100
    /// Ceiling on the ranked ids any one list will try to resolve.
    static let maxResolvedIds = 500
    /// Ceiling on the event pages any one scan will walk.
    static let maxScannedPages = 200

    /// Clamps a caller's requested list length into `1 ... ceiling`.
    static func cap(_ limit: Int, ceiling: Int) -> Int {
        min(max(1, limit), ceiling)
    }
}

extension PlayEventRepositoryProviding {
    /// Folds a profile's events, newest first, stopping at `floor`.
    ///
    /// `playEvents` orders by `startedAt` descending, so the first event older than
    /// `floor` proves every remaining one is older too and the walk returns
    /// immediately — which is what keeps a 90-day question from paging years of
    /// history. Pass `0` to walk everything that survives the raw horizon.
    func reduceEvents<Accumulator: Sendable>(
        profileId: Int64,
        pageSize: Int,
        stoppingBefore floor: TimeInterval,
        into initial: Accumulator,
        _ accumulate: (inout Accumulator, PlayEventRecord) -> Void
    ) async throws -> Accumulator {
        var result = initial
        var cursor: PageCursor<Double>?
        var pages = 0
        repeat {
            let page = try await playEvents(profileId: profileId, before: cursor, limit: pageSize)
            for event in page.items {
                guard event.startedAt >= floor else { return result }
                accumulate(&result, event)
            }
            cursor = page.nextCursor
            pages += 1
        } while cursor != nil && pages < InsightPaging.maxScannedPages
        return result
    }

    /// The distinct library ids this profile played at or after `since`.
    func playedTrackIds(profileId: Int64, since: TimeInterval, pageSize: Int) async throws -> Set<Int64> {
        try await reduceEvents(
            profileId: profileId,
            pageSize: pageSize,
            stoppingBefore: since,
            into: Set<Int64>()
        ) { ids, event in
            guard let trackId = event.trackId else { return }
            ids.insert(trackId)
        }
    }
}

extension TrackRepository {
    /// Resolves ranked ids to `present` library rows, in rank order, up to `limit`.
    ///
    /// Ids are resolved in batches of ``InsightPaging/resolveChunkSize`` and the walk
    /// stops as soon as `limit` playable rows exist — so a ranking whose head is all
    /// unreachable files costs one extra batch, not a full resolve. An id that no
    /// longer exists, or whose file is `missing`/`externalOffline`, is skipped.
    func presentTracks(profileId: Int64, orderedIds: [Int64], limit: Int) async throws -> [ProfileScopedTrack] {
        guard limit > 0 else { return [] }
        let ids = Array(orderedIds.prefix(InsightPaging.maxResolvedIds))
        var found: [ProfileScopedTrack] = []
        var index = ids.startIndex
        while index < ids.endIndex, found.count < limit {
            let end = min(index + InsightPaging.resolveChunkSize, ids.endIndex)
            let chunk = Array(ids[index ..< end])
            let resolved = try await resolvedTracks(profileId: profileId, trackIds: chunk)
            for trackId in chunk where found.count < limit {
                guard let scoped = resolved[trackId], scoped.track.availability == .present else { continue }
                found.append(scoped)
            }
            index = end
        }
        return found
    }
}
