// AssistantContextCacheTests — the memoisation contract, and the honesty rule
// underneath it.
//
// Two claims are worth proving separately. The CHEAPNESS claim is that a digest — a
// full scan of a profile's listening history — is built once per bucket rather than
// once per parse; a spy counting builds is the only way to see that, because a
// rebuilt digest and a cached one are indistinguishable from the returned value. The
// HONESTY claim is that every fact in the prompt came from measured rows: a missing
// digest, an empty window and an unnamed artist must all yield NOTHING rather than a
// plausible-looking placeholder.
import Foundation
import Services
import Testing

@Suite("AssistantContextCache")
struct AssistantContextCacheTests {
    @Test("Two lookups in the same bucket build the digest once")
    func repeatedLookupsShareOneDigest() async {
        let spy = SpyDigestBuilder(digest: Fixtures.digest())
        let cache = AssistantContextCache(genres: Fixtures.genres, digests: spy, now: TestClock().read)

        let first = await cache.context(profileId: 1)
        let second = await cache.context(profileId: 1)
        let builds = await spy.buildCount

        #expect(first == second)
        #expect(builds == 1)
    }

    @Test("Crossing a bucket boundary rebuilds")
    func aNewBucketRebuilds() async {
        let spy = SpyDigestBuilder(digest: Fixtures.digest())
        let clock = TestClock()
        let cache = AssistantContextCache(genres: Fixtures.genres, digests: spy, now: clock.read)
        _ = await cache.context(profileId: 1)

        clock.advance(by: AssistantContextCache.bucketSeconds)
        _ = await cache.context(profileId: 1)
        let builds = await spy.buildCount

        #expect(builds == 2)
    }

    @Test("A lookup later in the same bucket does not rebuild")
    func insideTheBucketDoesNotRebuild() async {
        // Anchored at 0 so "almost a whole bucket later" is still bucket 0. This is a
        // BUCKET, not a sliding TTL: what expires an entry is crossing a boundary, not
        // its own age, and starting anywhere else would conflate the two.
        let spy = SpyDigestBuilder(digest: Fixtures.digest())
        let clock = TestClock(seconds: 0)
        let cache = AssistantContextCache(genres: Fixtures.genres, digests: spy, now: clock.read)
        _ = await cache.context(profileId: 1)

        clock.advance(by: AssistantContextCache.bucketSeconds - 1)
        _ = await cache.context(profileId: 1)
        let builds = await spy.buildCount

        #expect(builds == 1)
    }

    @Test("invalidate() forces the next lookup to rebuild")
    func invalidationRebuilds() async {
        let spy = SpyDigestBuilder(digest: Fixtures.digest())
        let cache = AssistantContextCache(genres: Fixtures.genres, digests: spy, now: TestClock().read)
        _ = await cache.context(profileId: 1)

        await cache.invalidate()
        _ = await cache.context(profileId: 1)
        let builds = await spy.buildCount

        #expect(builds == 2)
    }

    @Test("Each profile gets its own entry, and one never serves another")
    func profilesNeverShareAnEntry() async {
        let spy = SpyDigestBuilder(perProfile: [
            1: Fixtures.digest(genres: ["Rock"], artists: ["Radiohead"]),
            2: Fixtures.digest(genres: ["Jazz"], artists: ["Coltrane"]),
        ])
        let cache = AssistantContextCache(
            genres: { profileId in profileId == 1 ? ["Rock"] : ["Jazz"] },
            digests: spy,
            now: TestClock().read
        )

        let one = await cache.context(profileId: 1)
        let two = await cache.context(profileId: 2)
        let oneAgain = await cache.context(profileId: 1)
        let builds = await spy.buildCount

        #expect(one.genres == ["Rock"])
        #expect(one.artists == ["Radiohead"])
        #expect(two.genres == ["Jazz"])
        #expect(two.artists == ["Coltrane"])
        #expect(oneAgain == one)
        // One build each: profile 2's miss must not have evicted profile 1's entry,
        // or a two-profile household would never cache at all.
        #expect(builds == 2)
    }

    @Test("With no digest source the context is genres-only")
    func noDigestSourceYieldsGenresOnly() async {
        let cache = AssistantContextCache(genres: Fixtures.genres)

        let context = await cache.context(profileId: 1)

        #expect(context.genres == Fixtures.libraryGenres)
        #expect(context.artists.isEmpty)
        #expect(context.summary.isEmpty)
    }

    @Test("A failing digest degrades to genres-only instead of failing the parse")
    func aFailingDigestDegrades() async {
        let cache = AssistantContextCache(
            genres: Fixtures.genres,
            digests: SpyDigestBuilder.failing,
            now: TestClock().read
        )

        let context = await cache.context(profileId: 1)

        #expect(context.genres == Fixtures.libraryGenres)
        #expect(context.artists.isEmpty)
        #expect(context.summary.isEmpty)
    }
}

// MARK: - Digest projection

@Suite("AssistantContextCacheProjection")
struct AssistantContextProjectionTests {
    @Test("The summary names the most recent window that actually has plays")
    func theSummaryNamesItsWindow() {
        let month = "In the last month this listener played mostly: Rock, Jazz, Ambient."
        let year = "In the last year this listener played mostly: Rock, Jazz, Ambient."

        #expect(AssistantContextCache.summary(for: Fixtures.digest()) == month)
        #expect(AssistantContextCache.summary(for: Fixtures.digest(window: .last12Months)) == year)
    }

    @Test("A window with no plays is skipped in favour of one that has them")
    func anEmptyWindowIsSkipped() {
        let digest = ListeningDigest(windows: [
            ListeningWindowDigest(window: .last30Days, totalPlays: 0, topGenres: [Fixtures.stat("Rock")]),
            ListeningWindowDigest(window: .allTime, totalPlays: 9, topGenres: [Fixtures.stat("Jazz")]),
        ])
        let expected = "Across their whole history this listener played mostly: Jazz."

        #expect(AssistantContextCache.summary(for: digest) == expected)
    }

    @Test("Nothing measured means nothing claimed")
    func nothingMeasuredMeansNoSummary() {
        // Plays but no NAMED genres: the sentence would otherwise end in a colon.
        let unnamed = ListeningDigest(windows: [
            ListeningWindowDigest(window: .allTime, totalPlays: 4, topGenres: [Fixtures.stat("")]),
        ])

        #expect(AssistantContextCache.summary(for: nil).isEmpty)
        #expect(AssistantContextCache.summary(for: ListeningDigest()).isEmpty)
        #expect(AssistantContextCache.summary(for: unnamed).isEmpty)
        #expect(AssistantContextCache.topArtists(in: nil).isEmpty)
    }

    @Test("Unnamed artists are dropped rather than offered to the model")
    func unnamedArtistsAreDropped() {
        let digest = ListeningDigest(windows: [
            ListeningWindowDigest(
                window: .allTime,
                totalPlays: 3,
                topArtists: [Fixtures.stat("Radiohead"), Fixtures.stat(""), Fixtures.stat("Portishead")]
            ),
        ])

        #expect(AssistantContextCache.topArtists(in: digest) == ["Radiohead", "Portishead"])
    }

    @Test("The summary names at most three genres")
    func theSummaryIsBounded() {
        let digest = ListeningDigest(windows: [
            ListeningWindowDigest(
                window: .allTime,
                totalPlays: 5,
                topGenres: ["A", "B", "C", "D", "E"].map(Fixtures.stat)
            ),
        ])
        let expected = "Across their whole history this listener played mostly: A, B, C."

        #expect(AssistantContextCache.summary(for: digest) == expected)
    }

    @Test("Bucketing is integer division of epoch seconds, with no calendar anywhere")
    func bucketingIsPureArithmetic() {
        let width = AssistantContextCache.bucketSeconds

        #expect(AssistantContextCache.bucket(forEpochSeconds: 0) == 0)
        #expect(AssistantContextCache.bucket(forEpochSeconds: width - 1) == 0)
        #expect(AssistantContextCache.bucket(forEpochSeconds: width) == 1)
        // A clock set before the epoch clamps rather than producing a negative bucket
        // that could collide with a real one.
        #expect(AssistantContextCache.bucket(forEpochSeconds: -width) == 0)
    }
}

// MARK: - Doubles

private struct DigestUnavailable: Error {}

/// Counts builds, so "the digest was not rebuilt" is a fact rather than an inference.
private actor SpyDigestBuilder: ListeningDigestBuilding {
    private(set) var buildCount = 0
    private let perProfile: [Int64: ListeningDigest]
    private let fallback: ListeningDigest?

    /// A builder with nothing to return, so every call throws.
    static var failing: SpyDigestBuilder {
        SpyDigestBuilder(perProfile: [:])
    }

    init(digest: ListeningDigest) {
        perProfile = [:]
        fallback = digest
    }

    init(perProfile: [Int64: ListeningDigest]) {
        self.perProfile = perProfile
        fallback = nil
    }

    func buildDigest(profileId: Int64) async throws -> ListeningDigest {
        buildCount += 1
        guard let digest = perProfile[profileId] ?? fallback else { throw DigestUnavailable() }
        return digest
    }
}

/// A hand-wound clock, so a bucket boundary is crossed in a microsecond.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: Double

    init(seconds: Double = 1000) {
        self.seconds = seconds
    }

    var read: @Sendable () -> Date {
        { [self] in
            lock.lock()
            defer { lock.unlock() }
            return Date(timeIntervalSince1970: seconds)
        }
    }

    func advance(by interval: Double) {
        lock.lock()
        defer { lock.unlock() }
        seconds += interval
    }
}

private enum Fixtures {
    static let libraryGenres = ["Rock", "Jazz", "Ambient", "Dub"]

    static let genres: @Sendable (Int64) async -> [String] = { _ in libraryGenres }

    static func stat(_ name: String) -> ListeningNameStat {
        ListeningNameStat(name: name, plays: 1)
    }

    static func digest(
        window: ListeningWindowKind = .last30Days,
        genres: [String] = ["Rock", "Jazz", "Ambient"],
        artists: [String] = ["Radiohead", "Portishead"]
    ) -> ListeningDigest {
        ListeningDigest(windows: [
            ListeningWindowDigest(
                window: window,
                totalPlays: 42,
                topArtists: artists.map(stat),
                topGenres: genres.map(stat)
            ),
        ])
    }
}
