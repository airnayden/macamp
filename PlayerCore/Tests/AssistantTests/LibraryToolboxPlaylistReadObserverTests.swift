import Foundation
import Persistence
@testable import Services
import Testing

/// The optional playlist-read observer seam on `get_playlist`, and the guarantee
/// that installing it changes NOTHING about the tool's answer.
///
/// The golden below is written out by hand rather than computed from the tool, so
/// a future edit to `playlistResult` that silently reshapes the answer fails here
/// instead of agreeing with itself.
@Suite("LibraryToolbox get_playlist read observer")
struct LibraryToolboxPlaylistReadObserverTests {
    // MARK: - The golden

    /// Exactly what `get_playlist` answered for ``ToolboxFixtures/playlistID``
    /// BEFORE the observer seam existed — summary, rows (text AND payload),
    /// `totalCount` and `resultCount`.
    static let golden = ToolResult(
        summary: "\"Evening Set\" — 3 tracks.",
        rows: [
            ToolResultRow(
                text: "#3 Ember Waltz — Paper Lanterns · Slow Burn (1995)",
                payload: .object([
                    "id": .int(3),
                    "title": .string("Ember Waltz"),
                    "artist": .string("Paper Lanterns"),
                    "album": .string("Slow Burn"),
                    "genre": .string("Jazz"),
                    "year": .int(1995),
                    "durationSeconds": .number(312),
                    "availability": .string("present"),
                ])
            ),
            ToolResultRow(
                text: "#1 Aurora Drift — Nova Field · Northern Lights (2001)",
                payload: .object([
                    "id": .int(1),
                    "title": .string("Aurora Drift"),
                    "artist": .string("Nova Field"),
                    "album": .string("Northern Lights"),
                    "genre": .string("Ambient"),
                    "year": .int(2001),
                    "durationSeconds": .number(245),
                    "availability": .string("present"),
                ])
            ),
            ToolResultRow(
                text: "#5 Golden Hour — Paper Lanterns · Slow Burn (2008)",
                payload: .object([
                    "id": .int(5),
                    "title": .string("Golden Hour"),
                    "artist": .string("Paper Lanterns"),
                    "album": .string("Slow Burn"),
                    "genre": .null,
                    "year": .int(2008),
                    "durationSeconds": .number(265),
                    "availability": .string("present"),
                ])
            ),
        ],
        resultCount: 3
    )

    /// The same answer as the text a tier actually hands the model.
    static let goldenText = """
    "Evening Set" — 3 tracks.
    #3 Ember Waltz — Paper Lanterns · Slow Burn (1995)
    #1 Aurora Drift — Nova Field · Northern Lights (2001)
    #5 Golden Hour — Paper Lanterns · Slow Burn (2008)
    """

    static let getPlaylist = ToolArguments(["playlist_id": .int(ToolboxFixtures.playlistID)])

    /// A toolbox over the seeded library that differs from the fixture's only in
    /// the observer, so cases (c) and (d) are a true A/B on one variable.
    static func makeToolbox(
        _ database: AppDatabase,
        observer: (any ToolboxPlaylistReadObserving)? = nil
    ) -> LibraryToolbox {
        LibraryToolbox(context: LibraryToolboxContext(
            tracks: TrackRepository(database),
            playlists: PlaylistRepository(database),
            digests: ListeningDigestBuilder(database, now: { ToolboxFixtures.referenceNow }),
            reader: ToolboxLibraryReader(database),
            proposals: FakeToolboxProposalFiler(),
            profileId: ToolboxFixtures.profileID,
            now: { ToolboxFixtures.referenceNow },
            playlistReadObserver: observer
        ))
    }

    // MARK: - No-contract-change

    @Test("the shared fixture toolbox still answers the pre-change golden")
    func fixtureToolboxMatchesGolden() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database)

        let result = try await toolbox.execute("get_playlist", arguments: Self.getPlaylist)

        #expect(result == Self.golden)
        #expect(result.summary == Self.golden.summary)
        #expect(result.rows == Self.golden.rows)
        #expect(result.resultCount == 3)
        #expect(result.renderedText(profile: .cloud) == Self.goldenText)
    }

    @Test("with NO observer the answer is the pre-change golden, byte for byte")
    func nilObserverMatchesGolden() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = Self.makeToolbox(database, observer: nil)

        let result = try await toolbox.execute("get_playlist", arguments: Self.getPlaylist)

        #expect(result == Self.golden)
        #expect(result.renderedText(profile: .cloud) == Self.goldenText)
    }

    @Test("installing an observer changes the answer in NO way")
    func observedResultMatchesGolden() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let recorder = RecordingPlaylistReadObserver()
        let toolbox = Self.makeToolbox(database, observer: recorder)

        let result = try await toolbox.execute("get_playlist", arguments: Self.getPlaylist)

        #expect(result == Self.golden)
        #expect(result.summary == Self.golden.summary)
        #expect(result.rows == Self.golden.rows)
        #expect(result.resultCount == 3)
        #expect(result.renderedText(profile: .cloud) == Self.goldenText)
    }

    // MARK: - What the observer is told

    @Test("a successful read reports the served id and profile exactly once")
    func successfulReadReportsOnce() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let recorder = RecordingPlaylistReadObserver()
        let toolbox = Self.makeToolbox(database, observer: recorder)

        _ = try await toolbox.execute("get_playlist", arguments: Self.getPlaylist)

        let reads = await recorder.reads
        #expect(reads.count == 1)
        #expect(reads == [PlaylistRead(id: ToolboxFixtures.playlistID, profileId: ToolboxFixtures.profileID)])
    }

    @Test("every invocation reports afresh, in call order — nothing is cached or coalesced")
    func repeatedReadsReportEveryTime() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let recorder = RecordingPlaylistReadObserver()
        let toolbox = Self.makeToolbox(database, observer: recorder)

        _ = try await toolbox.execute("get_playlist", arguments: Self.getPlaylist)
        _ = try await toolbox.execute("get_playlist", arguments: Self.getPlaylist)

        let reads = await recorder.reads
        #expect(reads.count == 2)
        #expect(reads.allSatisfy { $0.id == ToolboxFixtures.playlistID })
    }

    @Test("a limited page still reports the whole playlist's id once")
    func limitedPageStillReportsOnce() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let recorder = RecordingPlaylistReadObserver()
        let toolbox = Self.makeToolbox(database, observer: recorder)

        _ = try await toolbox.execute("get_playlist", arguments: ToolArguments([
            "playlist_id": .int(ToolboxFixtures.playlistID),
            "limit": .int(1),
        ]))

        let reads = await recorder.reads
        #expect(reads == [PlaylistRead(id: ToolboxFixtures.playlistID, profileId: ToolboxFixtures.profileID)])
    }

    // MARK: - A refused read reports nothing

    @Test("another profile's playlist reports NOTHING")
    func foreignPlaylistReportsNothing() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let recorder = RecordingPlaylistReadObserver()
        let toolbox = Self.makeToolbox(database, observer: recorder)

        await #expect(throws: LibraryToolError.notFound(
            what: "playlist",
            id: ToolboxFixtures.otherPlaylistID
        )) {
            try await toolbox.execute("get_playlist", arguments: ToolArguments([
                "playlist_id": .int(ToolboxFixtures.otherPlaylistID),
            ]))
        }

        let reads = await recorder.reads
        #expect(reads.isEmpty)
    }

    @Test("a playlist id that does not exist reports NOTHING")
    func unknownPlaylistReportsNothing() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let recorder = RecordingPlaylistReadObserver()
        let toolbox = Self.makeToolbox(database, observer: recorder)

        let rendered = await toolbox.run("get_playlist", arguments: ToolArguments([
            "playlist_id": .int(4242),
        ]), profile: .cloud)

        #expect(rendered == "No playlist with id 4242 is available to this listener.")
        let reads = await recorder.reads
        #expect(reads.isEmpty)
    }

    @Test("a refused argument reports NOTHING — the read never happened")
    func missingArgumentReportsNothing() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let recorder = RecordingPlaylistReadObserver()
        let toolbox = Self.makeToolbox(database, observer: recorder)

        await #expect(throws: ToolArgumentError.missing(argument: "playlist_id")) {
            try await toolbox.execute("get_playlist")
        }

        let reads = await recorder.reads
        #expect(reads.isEmpty)
    }

    @Test("listing playlists is not a read of one, and reports NOTHING")
    func listingReportsNothing() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let recorder = RecordingPlaylistReadObserver()
        let toolbox = Self.makeToolbox(database, observer: recorder)

        _ = try await toolbox.execute("list_playlists")

        let reads = await recorder.reads
        #expect(reads.isEmpty)
    }
}

// MARK: - Recording observer

/// One `(playlistId, profileId)` pair the seam reported.
struct PlaylistRead: Equatable {
    let id: Int64
    let profileId: Int64
}

/// Records every report, in order. An `actor` because the seam is `Sendable` and
/// the tool layer calls it from a detached context.
actor RecordingPlaylistReadObserver: ToolboxPlaylistReadObserving {
    private(set) var reads: [PlaylistRead] = []

    func playlistWasRead(id: Int64, profileId: Int64) async {
        reads.append(PlaylistRead(id: id, profileId: profileId))
    }
}
