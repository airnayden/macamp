import Foundation
import GRDB
import Persistence
import Testing

/// CRUD, keyset-window and batch-lookup coverage for ``DownloadHistoryRepository``.
@Suite("DownloadHistoryRepositoryTests")
struct DownloadHistoryRepositoryTests {
    // MARK: - CRUD

    @Test("insert then read back one entry")
    func insertRoundTrips() async throws {
        let repository = try await Self.repository()
        let entry = DownloadHistoryFixtures.entry(id: "a", videoID: "vid-a", downloadedAt: 10)
        try await repository.insert(entry)

        let page = try await repository.entries(before: nil, limit: 10)
        #expect(page.items == [entry])
        #expect(page.nextCursor == nil)
        #expect(page.hasMore == false)
    }

    @Test("delete removes exactly one row and answers whether it matched")
    func deleteRemovesOneRow() async throws {
        let repository = try await Self.repository()
        try await repository.insert(DownloadHistoryFixtures.entry(id: "a", videoID: "v1", downloadedAt: 10))
        try await repository.insert(DownloadHistoryFixtures.entry(id: "b", videoID: "v2", downloadedAt: 20))

        let removed = try await repository.delete(id: "a")
        let missing = try await repository.delete(id: "never-existed")

        #expect(removed)
        #expect(!missing)
        let page = try await repository.entries(before: nil, limit: 10)
        #expect(page.items.map(\.id) == ["b"])
    }

    @Test("deleteAll clears the log and reports how many rows went")
    func deleteAllClearsTheLog() async throws {
        let repository = try await Self.repository()
        for index in 0 ..< 4 {
            try await repository.insert(
                DownloadHistoryFixtures.entry(id: "e\(index)", videoID: "v\(index)", downloadedAt: Double(index))
            )
        }

        let removed = try await repository.deleteAll()

        #expect(removed == 4)
        let page = try await repository.entries(before: nil, limit: 10)
        #expect(page.items.isEmpty)
    }

    // MARK: - Keyset window

    @Test("pages walk the whole log newest first, without gaps or repeats")
    func keysetPagesNewestFirst() async throws {
        let repository = try await Self.repository()
        for index in 0 ..< 5 {
            try await repository.insert(
                DownloadHistoryFixtures.entry(
                    id: "e\(index)",
                    videoID: "v\(index)",
                    downloadedAt: Double(100 + index)
                )
            )
        }

        let walked = try await Self.walkEveryPage(repository, limit: 2)

        #expect(walked == ["e4", "e3", "e2", "e1", "e0"])
    }

    /// The assertion that binds the tie-breaker. Five entries share one `downloadedAt`,
    /// so the timestamp alone cannot order them: a window with no tie-breaker — or one
    /// binding an integer against the TEXT primary key, which SQLite orders BEFORE
    /// every text value — returns the first page and then nothing at all.
    @Test("pages survive a run of entries sharing one timestamp")
    func keysetPagesThroughATimestampTie() async throws {
        let repository = try await Self.repository()
        for index in 0 ..< 5 {
            try await repository.insert(
                DownloadHistoryFixtures.entry(id: "tie\(index)", videoID: "v\(index)", downloadedAt: 500)
            )
        }

        let walked = try await Self.walkEveryPage(repository, limit: 2)

        #expect(walked.count == 5)
        #expect(Set(walked) == ["tie0", "tie1", "tie2", "tie3", "tie4"])
        #expect(walked == ["tie4", "tie3", "tie2", "tie1", "tie0"])
    }

    @Test("a full page that exhausts the log reports no next cursor")
    func lastPageHasNoCursor() async throws {
        let repository = try await Self.repository()
        try await repository.insert(DownloadHistoryFixtures.entry(id: "a", videoID: "v1", downloadedAt: 1))
        try await repository.insert(DownloadHistoryFixtures.entry(id: "b", videoID: "v2", downloadedAt: 2))

        let page = try await repository.entries(before: nil, limit: 2)

        #expect(page.items.map(\.id) == ["b", "a"])
        #expect(page.nextCursor == nil)
    }

    @Test("the page limit is capped at fetchLimit")
    func pageLimitIsCapped() async throws {
        let repository = try await Self.repository()
        for index in 0 ..< 3 {
            try await repository.insert(
                DownloadHistoryFixtures.entry(id: "e\(index)", videoID: "v\(index)", downloadedAt: Double(index))
            )
        }

        let page = try await repository.entries(before: nil, limit: 10000)

        #expect(page.items.count == 3)
        #expect(DownloadHistoryRepository.fetchLimit == 500)
    }

    // MARK: - latestEntry

    @Test("latestEntry answers the newest row for a re-downloaded video")
    func latestEntryIsNewestWins() async throws {
        let repository = try await Self.repository()
        try await repository.insert(
            DownloadHistoryFixtures.entry(id: "old", videoID: "same", downloadedAt: 100, audioFormat: "mp3")
        )
        try await repository.insert(
            DownloadHistoryFixtures.entry(id: "new", videoID: "same", downloadedAt: 900, audioFormat: "flac")
        )
        try await repository.insert(
            DownloadHistoryFixtures.entry(id: "other", videoID: "different", downloadedAt: 5000)
        )

        let latest = try await repository.latestEntry(canonicalVideoID: "same")

        #expect(latest?.id == "new")
        #expect(latest?.audioFormat == "flac")
    }

    @Test("latestEntry is nil for a video that was never downloaded")
    func latestEntryIsNilWhenUnknown() async throws {
        let repository = try await Self.repository()
        try await repository.insert(DownloadHistoryFixtures.entry(id: "a", videoID: "known", downloadedAt: 1))

        let latest = try await repository.latestEntry(canonicalVideoID: "unknown")

        #expect(latest == nil)
    }

    // MARK: - knownVideoIDs

    @Test("knownVideoIDs returns only the ids the log has seen")
    func knownVideoIDsFiltersToWhatWasDownloaded() async throws {
        let repository = try await Self.repository()
        try await repository.insert(DownloadHistoryFixtures.entry(id: "a", videoID: "seen-1", downloadedAt: 1))
        try await repository.insert(DownloadHistoryFixtures.entry(id: "b", videoID: "seen-2", downloadedAt: 2))
        try await repository.insert(DownloadHistoryFixtures.entry(id: "c", videoID: "seen-1", downloadedAt: 3))

        let known = try await repository.knownVideoIDs(in: ["seen-1", "fresh", "seen-2", "also-fresh"])

        #expect(known == ["seen-1", "seen-2"])
    }

    @Test("knownVideoIDs on an empty list costs no statement at all")
    func knownVideoIDsShortCircuitsOnEmptyInput() async throws {
        let (queue, trace) = try DownloadHistoryFixtures.tracedQueue()
        let repository = DownloadHistoryRepository(queue)
        trace.reset()

        let known = try await repository.knownVideoIDs(in: [])

        #expect(known.isEmpty)
        #expect(trace.all.isEmpty)
    }

    /// Fifty candidate ids must cost exactly ONE statement against the table — the
    /// property todo 15's paste-time hint is built on. Measured through GRDB's own
    /// trace rather than read off the implementation, and the `trace.all` assertion
    /// proves the probe fired at all, so "one statement" cannot be satisfied by a
    /// trace that recorded nothing.
    @Test("knownVideoIDs resolves fifty ids in exactly one statement")
    func knownVideoIDsIsOneStatementForFiftyIDs() async throws {
        let (queue, trace) = try DownloadHistoryFixtures.tracedQueue()
        let repository = DownloadHistoryRepository(queue)
        for index in 0 ..< 10 {
            try await repository.insert(
                DownloadHistoryFixtures.entry(id: "e\(index)", videoID: "vid-\(index)", downloadedAt: Double(index))
            )
        }
        let candidates = (0 ..< 50).map { "vid-\($0)" }
        trace.reset()

        let known = try await repository.knownVideoIDs(in: candidates)

        #expect(known == Set((0 ..< 10).map { "vid-\($0)" }))
        #expect(!trace.all.isEmpty, "the trace recorded nothing — the probe is dead")
        let touching = trace.mentioning("downloadHistory")
        #expect(touching.count == 1, "expected one statement, traced \(touching.count): \(touching)")
    }

    @Test("knownVideoIDs deduplicates before binding, still in one statement")
    func knownVideoIDsDeduplicatesCandidates() async throws {
        let (queue, trace) = try DownloadHistoryFixtures.tracedQueue()
        let repository = DownloadHistoryRepository(queue)
        try await repository.insert(DownloadHistoryFixtures.entry(id: "a", videoID: "dupe", downloadedAt: 1))
        trace.reset()

        let known = try await repository.knownVideoIDs(in: Array(repeating: "dupe", count: 40))

        #expect(known == ["dupe"])
        #expect(trace.mentioning("downloadHistory").count == 1)
    }

    @Test("knownVideoIDs stays one statement at its own ceiling")
    func knownVideoIDsHonoursItsCeiling() async throws {
        let (queue, trace) = try DownloadHistoryFixtures.tracedQueue()
        let repository = DownloadHistoryRepository(queue)
        try await repository.insert(DownloadHistoryFixtures.entry(id: "a", videoID: "vid-7", downloadedAt: 1))
        let candidates = (0 ..< (DownloadHistoryRepository.videoIDLookupLimit * 2)).map { "vid-\($0)" }
        trace.reset()

        let known = try await repository.knownVideoIDs(in: candidates)

        #expect(known == ["vid-7"])
        #expect(trace.mentioning("downloadHistory").count == 1)
    }
}

// MARK: - Helpers

private extension DownloadHistoryRepositoryTests {
    static func repository() async throws -> DownloadHistoryRepository {
        try DownloadHistoryRepository(AppDatabase.makeEmpty())
    }

    /// Walks every page and returns the ids in the order they were served.
    static func walkEveryPage(
        _ repository: DownloadHistoryRepository,
        limit: Int
    ) async throws -> [String] {
        var walked: [String] = []
        var cursor: PageCursor<Double>?
        var guardRail = 0
        repeat {
            let page = try await repository.entries(before: cursor, limit: limit)
            walked.append(contentsOf: page.items.map(\.id))
            cursor = page.nextCursor
            guardRail += 1
            if guardRail > 20 { break }
        } while cursor != nil
        return walked
    }
}
