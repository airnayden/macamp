// ListeningSessionizer — cuts a play-event stream into listening sessions.
//
// A session is one continuous run of listening: consecutive plays separated by less
// than ``ListeningSessionizer/defaultGapSeconds`` (30 minutes). The moment the
// silence between two plays reaches that gap, the run is over and the next play
// opens a new session. Sessions are the unit co-occurrence similarity is scored in —
// "these two tracks were heard in the same sitting" — so the split has to be a pure,
// reproducible function of the events, and nothing else.
//
// Three properties make it one:
//
//  1. **Epoch arithmetic only.** The gap is a subtraction of two `startedAt` doubles.
//     There is no `Calendar`, `TimeZone` or `DateComponents` anywhere in this file,
//     so a daylight-saving transition — which moves the wall clock by an hour without
//     moving the epoch at all — cannot merge or split a single session.
//  2. **Defensive total ordering.** The input is sorted by `(startedAt, id)` before
//     it is cut, because ``PlayEventRepository/playEvents(profileId:before:limit:)``
//     pages NEWEST first. The same set of events therefore produces the same sessions
//     whatever order — and whatever page size — they arrived in.
//  3. **No ambient inputs in the split.** The clock is injected and is used ONLY by
//     ``ListeningSessionizer/isOpen(_:)``, never by the cut itself.
import Foundation
import Persistence

/// One continuous run of listening.
///
/// ``events`` is ordered by `(startedAt, id)` ascending; ``trackIds`` is the DISTINCT
/// set of library tracks heard in the run, ascending. That ordering is not cosmetic:
/// co-occurrence tallies iterate ``trackIds``, so publishing it as a sorted array
/// (rather than a `Set`) is what keeps their floating-point accumulation free of
/// `Dictionary`/`Set` iteration order.
public struct ListeningSession: Sendable, Equatable {
    /// The plays that make up the run, oldest first.
    public let events: [PlayEventRecord]
    /// When the run's first play began, as seconds since the Unix epoch.
    public let startedAt: TimeInterval
    /// When the run's LAST play began, as seconds since the Unix epoch. Deliberately
    /// the start of the final play rather than its end: `secondsListened` describes
    /// how much was heard, not when it stopped, so a play's end instant is not a fact
    /// the history records.
    public let endedAt: TimeInterval
    /// The distinct library tracks heard in the run, ascending. Plays with no
    /// `trackId` (a file that was never in the library) contribute nothing.
    public let trackIds: [Int64]

    /// Builds a session from a non-empty, already-ordered run of plays.
    ///
    /// Returns `nil` for an empty run — a session with no plays has no bounds, and
    /// inventing zeroes for them would put a phantom 1970 session in every result.
    init?(events: [PlayEventRecord]) {
        guard let first = events.first, let last = events.last else { return nil }
        self.events = events
        startedAt = first.startedAt
        endedAt = last.startedAt
        trackIds = Set(events.compactMap(\.trackId)).sorted()
    }
}

/// Splits a profile's play history into listening sessions.
///
/// The type is a `Sendable` value: it holds the gap it cuts on and the clock
/// ``isOpen(_:)`` measures against, and no mutable state at all.
public struct ListeningSessionizer: Sendable {
    /// The silence that ends a session: 30 minutes, in seconds.
    public static let defaultGapSeconds: TimeInterval = 1800

    /// The gap this sessionizer cuts on.
    public let gapSeconds: TimeInterval

    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - gapSeconds: The silence that ends a session. Negative values clamp to `0`.
    ///   - now: The clock ``isOpen(_:)`` measures against. Injected so a test can
    ///     place "now" exactly on a boundary without waiting for real time. The
    ///     session CUT never reads it.
    public init(
        gapSeconds: TimeInterval = ListeningSessionizer.defaultGapSeconds,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.gapSeconds = max(0, gapSeconds)
        self.now = now
    }

    /// Cuts `events` into sessions, oldest session first.
    ///
    /// An empty stream yields no sessions.
    public func sessions(from events: [PlayEventRecord]) -> [ListeningSession] {
        Self.split(events, gapSeconds: gapSeconds).compactMap(ListeningSession.init(events:))
    }

    /// Whether `session` could still be running — its last play began less than
    /// ``gapSeconds`` ago, so the next play would join it rather than open a new one.
    ///
    /// This is the ONLY place the injected clock is read.
    public func isOpen(_ session: ListeningSession) -> Bool {
        now().timeIntervalSince1970 - session.endedAt < gapSeconds
    }

    /// The pure cut: `events` grouped into runs whose consecutive `startedAt` gaps
    /// are strictly less than `gapSeconds`.
    ///
    /// **The boundary is exclusive-below:** a gap of EXACTLY `gapSeconds` opens a new
    /// session, and only a strictly smaller gap continues the current one. Stated the
    /// other way round, "a 30-minute silence ends the session" is true at 30 minutes,
    /// not just past it.
    ///
    /// `events` need not be sorted; it is ordered by `(startedAt, id)` first. Plays
    /// with no `trackId` still delimit a run — the listener was listening, even if the
    /// file is not in the library.
    public static func split(
        _ events: [PlayEventRecord],
        gapSeconds: TimeInterval = ListeningSessionizer.defaultGapSeconds
    ) -> [[PlayEventRecord]] {
        let threshold = max(0, gapSeconds)
        var sessions: [[PlayEventRecord]] = []
        var current: [PlayEventRecord] = []
        var previousStart: TimeInterval?
        for event in events.sorted(by: isOrderedBefore) {
            if let previousStart, event.startedAt - previousStart >= threshold {
                sessions.append(current)
                current = []
            }
            current.append(event)
            previousStart = event.startedAt
        }
        if !current.isEmpty {
            sessions.append(current)
        }
        return sessions
    }

    /// Chronological order, with the rowid as the tie-break that makes it total, so
    /// two plays captured in the same instant cannot swap between runs.
    private static func isOrderedBefore(_ lhs: PlayEventRecord, _ rhs: PlayEventRecord) -> Bool {
        lhs.startedAt == rhs.startedAt ? (lhs.id ?? 0) < (rhs.id ?? 0) : lhs.startedAt < rhs.startedAt
    }
}
