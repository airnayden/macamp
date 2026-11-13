// ListeningDigestDeterminismTests — the hardest guarantee this feature makes.
//
// The digest must be a pure function of `(rows, injected clock)`. Everything else —
// the order rows were inserted in, the page size they are read back through, the
// process time zone, the process locale, the per-launch hash seed behind `Dictionary`
// iteration — must be invisible in the output bytes. An archive that round-trips
// between two machines is only comparable if that holds.
//
// Each test below removes exactly one of those hidden inputs and asserts the bytes did
// not move, and the golden test pins the actual values so a silent reshaping of the
// payload cannot pass as "still deterministic".
import Foundation
import GRDB
import Persistence
import PlayerCoreTestSupport
@testable import Services
import Testing

/// Where the digest's own sources live, relative to this file.
private var statsSourceDirectory: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/Services/Stats")
}

/// Everything on a line before its first `//`, so a doc comment naming a banned API
/// does not read as a use of it.
private func codeOnly(_ source: String) -> String {
    source
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { line -> Substring in
            guard let comment = line.range(of: "//") else { return line }
            return line[line.startIndex ..< comment.lowerBound]
        }
        .joined(separator: "\n")
}

@Suite(.serialized)
struct ListeningDigestDeterminismTests {
    // MARK: - The golden bytes

    @Test("the seeded fixture encodes to the golden bytes, exactly")
    func goldenSnapshot() async throws {
        let database = try makeDigestDatabase()
        try seedDigestFixture(database)
        let encoded = try await buildDigestJSON(database)
        let json = try #require(String(data: encoded, encoding: .utf8))
        if let dump = ProcessInfo.processInfo.environment["MACAMP_DIGEST_GOLDEN_DUMP"] {
            try json.write(toFile: dump, atomically: true, encoding: .utf8)
        }
        #expect(json == ListeningDigestGolden.json)
    }

    @Test("decoding and re-encoding the golden bytes reproduces them")
    func encodingRoundtrips() throws {
        let original = try #require(ListeningDigestGolden.json.data(using: .utf8))
        let digest = try ListeningDigest.decoded(from: original)
        #expect(digest.digestVersion == ListeningDigest.currentVersion)
        #expect(try digest.encodedJSON() == original)
    }

    // MARK: - Invariance

    @Test("inserting the SAME events in REVERSED order moves not one byte")
    func reversedInsertionOrder() async throws {
        let forward = try makeDigestDatabase()
        try seedDigestFixture(forward)
        let backward = try makeDigestDatabase()
        try seedDigestFixture(backward, reversed: true)
        // Different rowids for the same history: the digest must key on identity, and
        // every reduction must be order-independent.
        #expect(try await buildDigestJSON(backward) == buildDigestJSON(forward))
    }

    @Test("reading through DIFFERENT page sizes moves not one byte", arguments: [1, 2, 3, 7, 500])
    func pageSizeInvariance(pageSize: Int) async throws {
        let database = try makeDigestDatabase()
        try seedDigestFixture(database)
        let baseline = try await buildDigestJSON(database, pageSize: PlayEventRepository.fetchLimit)
        #expect(try await buildDigestJSON(database, pageSize: pageSize) == baseline)
    }

    @Test("a different process time zone and locale move not one byte")
    func processEnvironmentInvariance() async throws {
        let database = try makeDigestDatabase()
        try seedDigestFixture(database)
        let baseline = try await buildDigestJSON(database)

        let savedZone = NSTimeZone.default
        let savedLocale = setlocale(LC_ALL, nil).map { String(cString: $0) } ?? "C"
        defer {
            NSTimeZone.default = savedZone
            setlocale(LC_ALL, savedLocale)
        }
        // Chatham is UTC+12:45 with its own DST; Turkish is the locale whose case
        // mapping would fold "I" to a dotless "ı" if the identity key were ever built
        // with the locale-sensitive `lowercased(with:)`.
        NSTimeZone.default = try #require(TimeZone(identifier: "Pacific/Chatham"))
        setlocale(LC_ALL, "tr_TR.UTF-8")

        #expect(try await buildDigestJSON(database) == baseline)
    }

    @Test("the identity key uses Unicode DEFAULT case mapping, not the process locale")
    func identityKeyIsLocaleIndependent() {
        let savedLocale = setlocale(LC_ALL, nil).map { String(cString: $0) } ?? "C"
        defer { setlocale(LC_ALL, savedLocale) }
        setlocale(LC_ALL, "tr_TR.UTF-8")
        let key = ListeningTrackIdentity.identityKey(artistName: "INXS", title: "İstanbul", albumTitle: nil)
        // Turkish would give "ınxs"; the default mapping gives "inxs".
        #expect(key == "inxs|i̇stanbul|")
    }

    @Test("rebuilding the same database twice is byte-stable across dictionary seeds")
    func repeatedBuildsAgree() async throws {
        let database = try makeDigestDatabase()
        try seedDigestFixture(database)
        let first = try await buildDigestJSON(database)
        let second = try await buildDigestJSON(database)
        #expect(first == second)
    }

    // MARK: - Structural guards

    @Test("no digest source names Calendar, TimeZone, Locale or DateFormatter")
    func sourcesHaveNoAmbientTimeAPIs() throws {
        let banned = ["Calendar", "TimeZone", "DateFormatter", "Locale", "lowercased(with:"]
        let sources = [
            "CivilMonth.swift",
            "ListeningDigest.swift",
            "ListeningDigestAccumulator+Emit.swift",
            "ListeningDigestAccumulator.swift",
            "ListeningDigestBuilder.swift",
            "ListeningDigestEntities.swift",
            "ListeningLocalTime.swift",
            "ListeningWindowDigest.swift",
            "ReplayHeatAnalysis.swift",
            "StatsQuantization.swift",
        ]
        for name in sources {
            let url = statsSourceDirectory.appendingPathComponent(name)
            let code = try codeOnly(String(contentsOf: url, encoding: .utf8))
            for token in banned {
                #expect(code.contains(token) == false, "\(name) uses \(token)")
            }
        }
    }

    @Test("no digest source joins a library table")
    func sourcesNeverJoinTheLibrary() throws {
        let banned = ["TrackRecord", "PlaylistRecord", "filePath", "JOIN", "join("]
        let sources = ["ListeningDigestBuilder.swift", "ListeningDigestAccumulator.swift"]
        for name in sources {
            let url = statsSourceDirectory.appendingPathComponent(name)
            let code = try codeOnly(String(contentsOf: url, encoding: .utf8))
            for token in banned {
                #expect(code.contains(token) == false, "\(name) references \(token)")
            }
        }
    }
}
