// The pure update decisions, as tables: date-stamp version comparison, the 90-day
// staleness rule, the 24-hour auto-check throttle, and the `SHA2-256SUMS` parser.
//
// Every expectation is written out here rather than derived from the production
// constants, so a table that changed value would fail rather than agree with itself.
// The one exception is the staleness/throttle arithmetic, which is expressed in days
// and hours precisely so the reader can check it against the documented rule.
import Foundation
import Services
import Testing

// MARK: - Version comparison

struct ToolVersionPair: CustomStringConvertible {
    let candidate: String
    let installed: String
    let isNewer: Bool
    let note: String

    var description: String {
        "\(candidate) vs \(installed) — \(note)"
    }
}

@Suite("Tool update planner — version comparison")
struct ToolUpdatePlannerVersionTests {
    @Test("date-stamped versions compare numerically, never lexicographically", arguments: [
        ToolVersionPair(candidate: "2026.08.20", installed: "2026.08.19", isNewer: true, note: "next day"),
        ToolVersionPair(candidate: "2026.08.19", installed: "2026.08.19", isNewer: false, note: "identical"),
        ToolVersionPair(candidate: "2026.08.19", installed: "2026.08.20", isNewer: false, note: "previous day"),
        ToolVersionPair(candidate: "2027.01.01", installed: "2026.12.31", isNewer: true, note: "year rollover"),
        ToolVersionPair(candidate: "2026.08.19", installed: "2026.8.9", isNewer: true, note: "unpadded is OLDER"),
        ToolVersionPair(candidate: "2026.8.9", installed: "2026.08.19", isNewer: false, note: "the lexicographic trap"),
        ToolVersionPair(
            candidate: "2026.08.19.232305",
            installed: "2026.08.19",
            isNewer: true,
            note: "a nightly follows the stable it was cut from"
        ),
        ToolVersionPair(
            candidate: "2026.08.19",
            installed: "2026.08.19.232305",
            isNewer: false,
            note: "stable does not overwrite a newer nightly"
        ),
    ])
    func comparesNumerically(pair: ToolVersionPair) {
        #expect(ToolUpdatePlanner.isNewer(pair.candidate, than: pair.installed) == pair.isNewer)
    }

    @Test("an undecidable comparison never claims newer", arguments: [
        ToolVersionPair(candidate: "nightly", installed: "2026.08.19", isNewer: false, note: "non-numeric candidate"),
        ToolVersionPair(candidate: "2026.08.19", installed: "unknown", isNewer: false, note: "non-numeric installed"),
        ToolVersionPair(candidate: "2026..19", installed: "2026.08.19", isNewer: false, note: "empty component"),
        ToolVersionPair(
            candidate: "2026.08.19rc1",
            installed: "2026.08.19",
            isNewer: false,
            note: "suffixed component"
        ),
        ToolVersionPair(candidate: "", installed: "2026.08.19", isNewer: false, note: "empty string"),
        ToolVersionPair(candidate: "2026.08.19", installed: "", isNewer: false, note: "empty installed"),
    ])
    func undecidableIsNeverNewer(pair: ToolVersionPair) {
        #expect(ToolUpdatePlanner.isNewer(pair.candidate, than: pair.installed) == pair.isNewer)
    }

    @Test("the lexicographic trap is real — the strings sort the other way")
    func lexicographicTrapIsReal() {
        // Documents WHY `isNewer` cannot be `candidate > installed`.
        #expect("2026.8.9" > "2026.08.19")
        #expect(ToolUpdatePlanner.isNewer("2026.8.9", than: "2026.08.19") == false)
    }

    @Test("availability names the installed and published sides correctly")
    func availabilityMapsBothWays() {
        #expect(
            ToolUpdatePlanner.availability(installed: "2026.08.19", latest: "2026.09.01")
                == .updateAvailable(installed: "2026.08.19", latest: "2026.09.01")
        )
        #expect(
            ToolUpdatePlanner.availability(installed: "2026.08.19", latest: "2026.08.19")
                == .upToDate(version: "2026.08.19")
        )
        #expect(
            ToolUpdatePlanner.availability(installed: "2026.09.01", latest: "2026.08.19")
                == .upToDate(version: "2026.09.01")
        )
    }
}

// MARK: - Release date + staleness

struct ToolReleaseDateCase: CustomStringConvertible {
    let version: String
    let iso: String?
    let note: String

    var description: String {
        "\(version) — \(note)"
    }
}

/// One "how long ago / how long since" row, shared by the staleness and throttle tables.
struct ToolElapsedCase: CustomStringConvertible {
    /// Days for the staleness table, hours for the throttle table.
    let amount: Double
    let expected: Bool
    let note: String

    var description: String {
        "\(amount) — \(note)"
    }
}

@Suite("Tool update planner — release dates and staleness")
struct ToolUpdatePlannerStalenessTests {
    /// An independent oracle: Foundation's own ISO-8601 parser, fixed to UTC. The
    /// production code deliberately avoids `Calendar`, so this is genuine double entry
    /// rather than the same arithmetic restated.
    private static func instant(_ iso: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let parsed = formatter.date(from: iso)
        return try #require(parsed)
    }

    @Test("a date-stamped version resolves to midnight UTC on that civil day", arguments: [
        ToolReleaseDateCase(version: "2026.08.19", iso: "2026-08-19T00:00:00Z", note: "the shipped pin"),
        ToolReleaseDateCase(version: "2026.1.1", iso: "2026-01-01T00:00:00Z", note: "unpadded components"),
        ToolReleaseDateCase(version: "2024.02.29", iso: "2024-02-29T00:00:00Z", note: "leap day in a leap year"),
        ToolReleaseDateCase(version: "2026.12.31", iso: "2026-12-31T00:00:00Z", note: "year end"),
        ToolReleaseDateCase(
            version: "2026.08.19.232305",
            iso: "2026-08-19T00:00:00Z",
            note: "a nightly's time suffix is ignored"
        ),
        ToolReleaseDateCase(version: "2026.02.29", iso: nil, note: "29 February in a NON-leap year"),
        ToolReleaseDateCase(version: "2026.02.30", iso: nil, note: "day beyond the month never slides into March"),
        ToolReleaseDateCase(version: "2026.13.01", iso: nil, note: "month out of range"),
        ToolReleaseDateCase(version: "2026.08.00", iso: nil, note: "day zero"),
        ToolReleaseDateCase(version: "2026.08", iso: nil, note: "too few components"),
        ToolReleaseDateCase(version: "1969.12.31", iso: nil, note: "before the epoch guard"),
        ToolReleaseDateCase(version: "nightly", iso: nil, note: "not a date stamp at all"),
    ])
    func resolvesReleaseDate(dateCase: ToolReleaseDateCase) throws {
        let resolved = ToolUpdatePlanner.releaseDate(from: dateCase.version)
        guard let iso = dateCase.iso else {
            #expect(resolved == nil)
            return
        }
        let expected = try Self.instant(iso)
        #expect(resolved == expected)
    }

    @Test("staleness is strictly beyond 90 days", arguments: [
        ToolElapsedCase(amount: 0, expected: false, note: "released today"),
        ToolElapsedCase(amount: 89, expected: false, note: "one day inside the window"),
        ToolElapsedCase(amount: 90, expected: false, note: "exactly at the threshold"),
        ToolElapsedCase(amount: 90.5, expected: true, note: "half a day past it"),
        ToolElapsedCase(amount: 91, expected: true, note: "one day past it"),
        ToolElapsedCase(amount: 400, expected: true, note: "long abandoned"),
    ])
    func stalenessThreshold(elapsed: ToolElapsedCase) throws {
        let released = try Self.instant("2026-08-19T00:00:00Z")
        let now = released.addingTimeInterval(elapsed.amount * 24 * 60 * 60)
        #expect(ToolUpdatePlanner.isStale(version: "2026.08.19", now: now) == elapsed.expected)
    }

    @Test("an unreadable version is never reported as stale")
    func unreadableVersionIsNotStale() {
        #expect(ToolUpdatePlanner.isStale(version: "nightly", now: Date(timeIntervalSince1970: 4_000_000_000)) == false)
    }

    @Test("the threshold constant is the documented 90 days")
    func thresholdConstantIsNinetyDays() {
        #expect(ToolUpdatePlanner.stalenessThresholdDays == 90)
    }
}

// MARK: - Auto-check throttle

@Suite("Tool update planner — auto-check throttle")
struct ToolUpdatePlannerThrottleTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("a feed that has never been consulted always checks")
    func neverCheckedAlwaysChecks() {
        #expect(ToolUpdatePlanner.shouldAutoCheck(lastCheck: nil, now: Self.now))
    }

    @Test("the throttle opens at 24 hours", arguments: [
        ToolElapsedCase(amount: 0, expected: false, note: "checked just now"),
        ToolElapsedCase(amount: 1, expected: false, note: "an hour ago"),
        ToolElapsedCase(amount: 23.9, expected: false, note: "six minutes short of a day"),
        ToolElapsedCase(amount: 24, expected: true, note: "exactly one day"),
        ToolElapsedCase(amount: 48, expected: true, note: "two days"),
    ])
    func throttleOpensAtOneDay(elapsed: ToolElapsedCase) {
        let lastCheck = Self.now.addingTimeInterval(-elapsed.amount * 60 * 60)
        #expect(ToolUpdatePlanner.shouldAutoCheck(lastCheck: lastCheck, now: Self.now) == elapsed.expected)
    }

    @Test("a last-check in the FUTURE checks rather than latching shut forever")
    func clockSkewDoesNotLatch() {
        let future = Self.now.addingTimeInterval(60 * 60)
        #expect(ToolUpdatePlanner.shouldAutoCheck(lastCheck: future, now: Self.now))
    }

    @Test("the interval constant is the documented one day")
    func intervalConstantIsOneDay() {
        #expect(ToolUpdatePlanner.autoCheckInterval == 86400)
    }
}

// MARK: - SHA2-256SUMS parsing

@Suite("Tool update planner — SHA2-256SUMS parsing")
struct ToolUpdatePlannerChecksumTests {
    /// Shaped exactly like the real yt-dlp manifest: two spaces between fields, one
    /// record per line, several assets sharing a prefix.
    private static let manifest = """
    5f2c0a4b8d1e6f3a9c7b2d4e8f0a1c3b5d7e9f0a2c4b6d8e0f1a3c5b7d9e1f00  yt-dlp
    0f192b7ec147ab6288885d6351d9ab67367640029b4377576ef46dd79cf7b202  yt-dlp_macos
    aa11bb22cc33dd44ee55ff6600112233445566778899aabbccddeeff001122ab  yt-dlp_macos.zip
    """

    @Test("the exact asset's digest is returned")
    func returnsExactAssetDigest() {
        #expect(
            ToolUpdatePlanner.checksum(forAsset: "yt-dlp_macos", in: Self.manifest)
                == "0f192b7ec147ab6288885d6351d9ab67367640029b4377576ef46dd79cf7b202"
        )
    }

    @Test("a name that merely shares a prefix is not matched")
    func prefixesDoNotCrossMatch() {
        #expect(
            ToolUpdatePlanner.checksum(forAsset: "yt-dlp", in: Self.manifest)
                == "5f2c0a4b8d1e6f3a9c7b2d4e8f0a1c3b5d7e9f0a2c4b6d8e0f1a3c5b7d9e1f00"
        )
        #expect(
            ToolUpdatePlanner.checksum(forAsset: "yt-dlp_macos.zip", in: Self.manifest)
                == "aa11bb22cc33dd44ee55ff6600112233445566778899aabbccddeeff001122ab"
        )
    }

    @Test("an asset the manifest does not cover has no digest")
    func absentAssetHasNoDigest() {
        #expect(ToolUpdatePlanner.checksum(forAsset: "ffmpeg", in: Self.manifest) == nil)
    }

    @Test("a tab separator and a coreutils binary marker both parse")
    func toleratesSeparatorAndBinaryMarker() {
        let tabbed = "0f192b7ec147ab6288885d6351d9ab67367640029b4377576ef46dd79cf7b202\tyt-dlp_macos"
        let binaryMode = "0f192b7ec147ab6288885d6351d9ab67367640029b4377576ef46dd79cf7b202 *yt-dlp_macos"
        #expect(ToolUpdatePlanner.checksum(forAsset: "yt-dlp_macos", in: tabbed)?.hasPrefix("0f192b") == true)
        #expect(ToolUpdatePlanner.checksum(forAsset: "yt-dlp_macos", in: binaryMode)?.hasPrefix("0f192b") == true)
    }

    @Test("an uppercase digest is normalized to lowercase")
    func normalizesDigestCase() {
        let shouty = "0F192B7EC147AB6288885D6351D9AB67367640029B4377576EF46DD79CF7B202  yt-dlp_macos"
        #expect(
            ToolUpdatePlanner.checksum(forAsset: "yt-dlp_macos", in: shouty)
                == "0f192b7ec147ab6288885d6351d9ab67367640029b4377576ef46dd79cf7b202"
        )
    }

    @Test("blank lines, comments, and malformed digests are skipped rather than trusted")
    func skipsNoiseLines() {
        let noisy = """

        # SHA2-256SUMS for the 2026.08.19 release
        deadbeef  yt-dlp_macos
        notahexdigestnotahexdigestnotahexdigestnotahexdigestnotahexdiges  yt-dlp_macos
        0f192b7ec147ab6288885d6351d9ab67367640029b4377576ef46dd79cf7b202  yt-dlp_macos

        """
        #expect(
            ToolUpdatePlanner.checksum(forAsset: "yt-dlp_macos", in: noisy)
                == "0f192b7ec147ab6288885d6351d9ab67367640029b4377576ef46dd79cf7b202"
        )
    }

    @Test("a file name containing spaces survives")
    func nameWithSpacesSurvives() {
        let spaced = "0f192b7ec147ab6288885d6351d9ab67367640029b4377576ef46dd79cf7b202  yt dlp macos"
        #expect(ToolUpdatePlanner.checksum(forAsset: "yt dlp macos", in: spaced)?.hasPrefix("0f192b") == true)
    }

    @Test("an empty manifest yields nothing")
    func emptyManifestYieldsNothing() {
        #expect(ToolUpdatePlanner.checksum(forAsset: "yt-dlp_macos", in: "") == nil)
    }

    @Test("digest validation accepts exactly 64 hex characters")
    func validatesDigestShape() {
        #expect(ToolUpdatePlanner.isValidChecksum(String(repeating: "a", count: 64)))
        #expect(!ToolUpdatePlanner.isValidChecksum(String(repeating: "a", count: 63)))
        #expect(!ToolUpdatePlanner.isValidChecksum(String(repeating: "a", count: 65)))
        #expect(!ToolUpdatePlanner.isValidChecksum(String(repeating: "z", count: 64)))
    }
}
