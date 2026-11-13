// ListeningSessionizerTests — the session cut, boundary first.
//
// Every instant below is raw UTC epoch seconds, hand-computed, and every gap is a
// literal number of seconds. Nothing here builds a `Date` from components or consults
// a `Calendar`, because that is exactly the property under test: the cut is epoch
// arithmetic, so a daylight-saving transition (which moves the wall clock by an hour
// while moving the epoch by nothing) cannot change a single session.
import Foundation
import Persistence
import PlayerCoreTestSupport
import Services
import Testing

@Suite("ListeningSessionizerTests")
struct ListeningSessionizerTests {
    /// 2026-03-08T09:00:00Z — a Sunday, and in US zones the spring-forward instant is
    /// two hours before it. Chosen so the DST case below straddles a real transition.
    static let base: Double = 1_772_960_400

    // MARK: - Degenerate inputs

    @Test("An empty stream produces no sessions and does not crash")
    func emptyStreamProducesNoSessions() {
        let sessionizer = ListeningSessionizer()
        #expect(sessionizer.sessions(from: []).isEmpty)
        #expect(ListeningSessionizer.split([]).isEmpty)
    }

    @Test("A single play is one session bounded by itself")
    func singleEventIsOneSession() throws {
        let sessionizer = ListeningSessionizer()
        let sessions = sessionizer.sessions(from: [Self.event(trackId: 7, at: Self.base)])
        let only = try #require(sessions.first)
        #expect(sessions.count == 1)
        #expect(only.startedAt == Self.base)
        #expect(only.endedAt == Self.base)
        #expect(only.trackIds == [7])
    }

    // MARK: - The 30-minute boundary

    @Test("A gap just under 30 minutes keeps both plays in one session")
    func gapJustBelowThresholdStaysInOneSession() {
        let sessions = Self.sessions(gaps: [1799.999])
        #expect(sessions.count == 1)
        #expect(sessions.first?.events.count == 2)
    }

    @Test("A gap of EXACTLY 30 minutes opens a new session")
    func gapExactlyAtThresholdSplits() {
        let sessions = Self.sessions(gaps: [1800])
        #expect(sessions.count == 2)
        #expect(sessions.map(\.events.count) == [1, 1])
    }

    @Test("A gap past 30 minutes opens a new session")
    func gapAboveThresholdSplits() {
        #expect(Self.sessions(gaps: [1800.001]).count == 2)
        #expect(Self.sessions(gaps: [7200]).count == 2)
    }

    @Test("The gap is measured play-to-play, so a long run never accumulates a split")
    func gapIsMeasuredBetweenConsecutivePlays() {
        // Four plays 20 minutes apart span an hour, but no single gap reaches 30.
        let sessions = Self.sessions(gaps: [1200, 1200, 1200])
        #expect(sessions.count == 1)
        #expect(sessions.first?.events.count == 4)
    }

    @Test("A custom gap is honoured on its own boundary")
    func customGapIsHonoured() {
        let sessionizer = ListeningSessionizer(gapSeconds: 600)
        let events = [
            Self.event(trackId: 1, at: Self.base),
            Self.event(trackId: 2, at: Self.base + 600),
        ]
        #expect(sessionizer.sessions(from: events).count == 2)
        #expect(ListeningSessionizer(gapSeconds: 601).sessions(from: events).count == 1)
    }

    // MARK: - Ordering and identity

    @Test("Unsorted input is ordered before it is cut")
    func unsortedInputIsOrderedFirst() throws {
        // Newest-first, exactly as `playEvents` pages arrive.
        let events = [
            Self.event(trackId: 3, at: Self.base + 3600, id: 3),
            Self.event(trackId: 2, at: Self.base + 60, id: 2),
            Self.event(trackId: 1, at: Self.base, id: 1),
        ]
        let sessions = ListeningSessionizer().sessions(from: events)
        #expect(sessions.count == 2)
        let first = try #require(sessions.first)
        #expect(first.trackIds == [1, 2])
        #expect(first.startedAt == Self.base)
        #expect(first.endedAt == Self.base + 60)
        #expect(sessions.last?.trackIds == [3])
    }

    @Test("A session's track ids are distinct and ascending")
    func trackIdsAreDistinctAndAscending() {
        let events = [
            Self.event(trackId: 9, at: Self.base, id: 1),
            Self.event(trackId: 4, at: Self.base + 60, id: 2),
            Self.event(trackId: 9, at: Self.base + 120, id: 3),
            Self.event(trackId: nil, at: Self.base + 180, id: 4),
        ]
        let sessions = ListeningSessionizer().sessions(from: events)
        #expect(sessions.count == 1)
        // The library-less play still belongs to the run, but contributes no id.
        #expect(sessions.first?.events.count == 4)
        #expect(sessions.first?.trackIds == [4, 9])
    }

    @Test("The pure split returns the same runs as the session view")
    func splitAndSessionsAgree() {
        let events = [
            Self.event(trackId: 1, at: Self.base, id: 1),
            Self.event(trackId: 2, at: Self.base + 1800, id: 2),
            Self.event(trackId: 3, at: Self.base + 1900, id: 3),
        ]
        let runs = ListeningSessionizer.split(events)
        let sessions = ListeningSessionizer().sessions(from: events)
        #expect(runs.map { $0.map(\.trackId) } == [[1], [2, 3]])
        #expect(sessions.map(\.events) == runs)
    }

    // MARK: - DST agnosticism

    @Test("A play pair straddling a DST transition is judged by epoch seconds alone")
    func daylightSavingDoesNotMoveTheBoundary() {
        // 2026-03-08T09:00:00Z sits just after the US spring-forward instant. These two
        // plays are 15 minutes apart on the clock that matters (the epoch) even though
        // the local wall clock between them jumped by a whole hour.
        let straddling = [
            Self.event(trackId: 1, at: Self.base - 900, id: 1),
            Self.event(trackId: 2, at: Self.base, id: 2),
        ]
        #expect(ListeningSessionizer().sessions(from: straddling).count == 1)

        // And the reverse: a 45-minute epoch gap splits, however the wall clock read.
        let separated = [
            Self.event(trackId: 1, at: Self.base - 2700, id: 1),
            Self.event(trackId: 2, at: Self.base, id: 2),
        ]
        #expect(ListeningSessionizer().sessions(from: separated).count == 2)
    }

    // MARK: - The injected clock

    @Test("isOpen reads only the injected clock")
    func isOpenUsesTheInjectedClock() throws {
        let clock = FakeClock(epochSeconds: Self.base + 60)
        let sessionizer = ListeningSessionizer(now: clock.nowProvider)
        let session = try #require(sessionizer.sessions(from: [Self.event(trackId: 1, at: Self.base)]).first)
        #expect(sessionizer.isOpen(session))

        // Exactly one gap later the run can no longer be joined — the same
        // exclusive-below boundary the cut uses.
        clock.set(Date(timeIntervalSince1970: Self.base + ListeningSessionizer.defaultGapSeconds))
        #expect(!sessionizer.isOpen(session))
    }
}

// MARK: - Fixture helpers

private extension ListeningSessionizerTests {
    static func event(trackId: Int64?, at startedAt: Double, id: Int64? = nil) -> PlayEventRecord {
        PlayEventRecord(
            id: id,
            profileId: ProfileRecord.guestID,
            trackId: trackId,
            startedAt: startedAt,
            utcOffsetSeconds: 0
        )
    }

    /// A run of plays laid out by the gaps between them, cut with the default gap.
    static func sessions(gaps: [Double]) -> [ListeningSession] {
        var events = [event(trackId: 1, at: base, id: 1)]
        var startedAt = base
        for (offset, gap) in gaps.enumerated() {
            startedAt += gap
            events.append(event(trackId: Int64(offset + 2), at: startedAt, id: Int64(offset + 2)))
        }
        return ListeningSessionizer().sessions(from: events)
    }
}
