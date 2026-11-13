// The staging sweep has exactly one way to be dangerous and two ways to be useless,
// and this suite pins every edge of that line.
//
// DANGEROUS: deleting a file a live process is still writing. A crash-orphaned yt-dlp
// is reparented to launchd and keeps streaming into its `.part`; an unguarded sweep on
// the next launch would truncate a download that was going to succeed. Every "KEPT"
// expectation below is that case. So is `theSweepNeverReachesTheDestinationFolder`,
// for a far worse version of it: a delete rule pointed at the listener's music folder
// would destroy their library, so the sweep is only ever handed the app-private
// staging directory and only ever reads the directory it was handed.
//
// USELESS (1): never deleting anything, so the staging directory grows forever.
//
// USELESS (2) — and this is the one that shipped: deleting only the files that carry
// a PARTIAL MARKER. An interruption during post-processing leaves `Title [id].m4a`, a
// valid but truncated container with no marker at all. It survived every relaunch, and
// the next
// attempt at that video made yt-dlp ADOPT it as finished output — exit 0, success
// toast, truncated file imported. Every output-container row below is that case.
//
// The clock is injected and both mtimes are written explicitly, so neither result
// depends on how long the test took to run.
import Foundation
import Services
import Testing

@Suite("Download staging sweeper")
struct DownloadStagingSweeperTests {
    /// The headline claim, as one sweep over one directory holding both files: the
    /// hour-old intermediate goes, the minute-old one — which a live orphan could
    /// still be writing — stays.
    @Test("a stale intermediate is deleted and a fresh one is KEPT")
    func theAgeGuardSeparatesAbandonedFromLive() throws {
        let staging = try Self.makeStagingDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }
        let stale = try Self.seed("abandoned.part", in: staging, age: 7200)
        let live = try Self.seed("downloading.part", in: staging, age: 60)

        let removed = DownloadStagingSweeper.sweep(directory: staging, now: Self.reference)

        #expect(removed.map(\.lastPathComponent) == ["abandoned.part"])
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: live.path))
    }

    /// A file exactly at the threshold is KEPT — the comparison is strictly greater
    /// than, so the boundary falls on the safe side.
    @Test("a file exactly at the age threshold is KEPT")
    func theThresholdIsExclusive() throws {
        let staging = try Self.makeStagingDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }
        let borderline = try Self.seed("borderline.part", in: staging, age: DownloadStagingSweeper.staleAge)

        let removed = DownloadStagingSweeper.sweep(directory: staging, now: Self.reference)

        #expect(removed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: borderline.path))
    }

    @Test("every sweepable shape is swept when stale", arguments: [
        // Partial markers.
        "abandoned.part",
        "abandoned.ytdl",
        "Song [dQw4w9WgXcQ].temp.m4a",
        "Song [dQw4w9WgXcQ].webm.part-Frag7",
        // Abandoned containers — the shapes that carry NO marker and were adopted.
        "Never Gonna Give You Up [dQw4w9WgXcQ].m4a",
        "Never Gonna Give You Up [dQw4w9WgXcQ].webm",
        "Never Gonna Give You Up [dQw4w9WgXcQ].opus",
        "Never Gonna Give You Up [dQw4w9WgXcQ].flac",
        "Never Gonna Give You Up [dQw4w9WgXcQ].mp3",
        "Never Gonna Give You Up [dQw4w9WgXcQ].webp",
    ])
    func everySweepableShapeIsSweptWhenStale(name: String) throws {
        let staging = try Self.makeStagingDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }
        let seeded = try Self.seed(name, in: staging, age: 7200)

        let removed = DownloadStagingSweeper.sweep(directory: staging, now: Self.reference)

        #expect(removed.map(\.lastPathComponent) == [name])
        #expect(!FileManager.default.fileExists(atPath: seeded.path))
    }

    /// The age guard covers the WIDENED set too, not just the three original markers:
    /// the container a live orphan is muxing right now is as protected as its `.part`
    /// was.
    @Test("a FRESH abandoned container is KEPT, exactly like a fresh partial")
    func theAgeGuardCoversOutputContainersToo() throws {
        let staging = try Self.makeStagingDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }
        let live = try Self.seed("Never Gonna Give You Up [dQw4w9WgXcQ].m4a", in: staging, age: 60)

        let removed = DownloadStagingSweeper.sweep(directory: staging, now: Self.reference)

        #expect(removed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: live.path))
    }

    /// Widening the rule to bare containers is only safe because it is applied to an
    /// app-private directory. A file that is neither a marker nor a known engine
    /// container still survives forever.
    @Test("a stale NON-sweepable file is never touched", arguments: [
        "notes.txt",
        "README",
        // Dotfiles that merely share a name with an engine shape.
        ".m4a",
        ".part",
    ])
    func aForeignFileSurvivesAnyAge(name: String) throws {
        let staging = try Self.makeStagingDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }
        let seeded = try Self.seed(name, in: staging, age: 90 * 24 * 3600)

        let removed = DownloadStagingSweeper.sweep(directory: staging, now: Self.reference)

        #expect(removed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: seeded.path))
    }

    /// The load-bearing safety claim of the whole widening: the sweep reads the ONE
    /// directory it is handed and never walks a sibling. `~/Music/MacAMP Downloads`
    /// holds finished music whose names are the same shape as a staging leftover, so a
    /// sweep that reached it would delete the listener's library.
    @Test("the sweep never reaches the destination folder")
    func theSweepNeverReachesTheDestinationFolder() throws {
        let root = try Self.makeStagingDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("Downloads-Staging", isDirectory: true)
        let destination = root.appendingPathComponent("MacAMP Downloads", isDirectory: true)
        for directory in [staging, destination] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let leftover = try Self.seed("Never Gonna Give You Up [dQw4w9WgXcQ].m4a", in: staging, age: 7200)
        let music = try Self.seed(
            "Never Gonna Give You Up [dQw4w9WgXcQ].m4a",
            in: destination,
            age: 90 * 24 * 3600
        )

        let removed = DownloadStagingSweeper.sweep(directory: staging, now: Self.reference)

        // Compared by name, not by URL: `contentsOfDirectory` resolves the `/var`
        // symlink to `/private/var`, so equality on the URLs would fail on a match.
        #expect(removed.map(\.lastPathComponent) == [leftover.lastPathComponent])
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
        #expect(FileManager.default.fileExists(atPath: music.path))
    }

    /// A directory named like an intermediate is not a file and is never removed —
    /// `isRegularFile` is checked, so a stray folder cannot take its contents with it.
    @Test("a subdirectory is neither recursed into nor deleted")
    func theSweepDoesNotRecurse() throws {
        let staging = try Self.makeStagingDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }
        let nested = staging.appendingPathComponent("nested.part", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let buried = try Self.seed("buried.part", in: nested, age: 7200)

        let removed = DownloadStagingSweeper.sweep(directory: staging, now: Self.reference)

        #expect(removed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: nested.path))
        #expect(FileManager.default.fileExists(atPath: buried.path))
    }

    /// The first launch after install has no staging directory at all, and a launch
    /// must not fail because of it.
    @Test("a missing staging directory sweeps nothing and does not throw")
    func anAbsentDirectoryIsNotAnError() throws {
        let absent = try Self.makeStagingDirectory()
        try FileManager.default.removeItem(at: absent)

        #expect(DownloadStagingSweeper.sweep(directory: absent, now: Self.reference).isEmpty)
    }

    @Test("the partial-marker patterns require a non-empty stem", arguments: [
        IntermediateCell("abandoned.part", true),
        IntermediateCell("abandoned.ytdl", true),
        IntermediateCell("a.temp.b", true),
        IntermediateCell("Song [id].temp.m4a", true),
        // Fragmented downloads: an abandoned `.part-Frag<N>` is the same
        // unbounded-growth problem as an abandoned container, in a smaller file.
        IntermediateCell("Song.m4a.part-Frag1", true),
        // A dotfile that merely shares the name has no stem and is not a leftover.
        IntermediateCell(".part", false),
        IntermediateCell(".ytdl", false),
        IntermediateCell(".temp.", false),
        IntermediateCell(".part-Frag1", false),
        // The index is what makes it a fragment; the bare marker is not one.
        IntermediateCell("Song.part-Frag", false),
        IntermediateCell("temp.m4a", false),
        // Still not a MARKER — it is an abandoned container, matched by the other
        // predicate. The two are deliberately separable.
        IntermediateCell("Song.m4a", false),
    ])
    func theShapeTestIsExact(cell: IntermediateCell) {
        #expect(DownloadStagingSweeper.isIntermediate(cell.name) == cell.isIntermediate)
    }

    @Test("the abandoned-container test is extension-based and needs a stem", arguments: [
        IntermediateCell("Never Gonna Give You Up [dQw4w9WgXcQ].m4a", true),
        IntermediateCell("Song.WEBM", true),
        IntermediateCell("Song.info.json", true),
        IntermediateCell("Song.description", true),
        IntermediateCell(".m4a", false),
        IntermediateCell("Song.part", false),
        IntermediateCell("Song.ytdl", false),
        IntermediateCell("Song.m4a.part-Frag1", false),
        IntermediateCell("notes.txt", false),
        IntermediateCell("README", false),
    ])
    func theOutputShapeTestIsExact(cell: IntermediateCell) {
        #expect(DownloadStagingSweeper.isAbandonedOutput(cell.name) == cell.isIntermediate)
    }

    /// The conversion progress file is matched by NAME, not by extension, and the
    /// negative rows are the whole reason it has a predicate of its own: `.txt` is the
    /// one extension a person plausibly drops into a directory by hand, so widening
    /// ``DownloadStagingSweeper/abandonedOutputExtensions`` instead would have made the
    /// sweep delete someone's notes.
    @Test("the conversion-progress test matches the engine's generated name only", arguments: [
        IntermediateCell("ffprogress [dQw4w9WgXcQ].txt", true),
        IntermediateCell("ffprogress x.txt", true),
        IntermediateCell("notes.txt", false),
        IntermediateCell("my ffprogress [dQw4w9WgXcQ].txt", false),
        IntermediateCell("ffprogress [dQw4w9WgXcQ].log", false),
        IntermediateCell("ffprogress.txt", false),
        // Prefix and suffix with NOTHING between them is not a generated name.
        IntermediateCell("ffprogress .txt", false),
    ])
    func theConversionProgressShapeTestIsExact(cell: IntermediateCell) {
        #expect(DownloadStagingSweeper.isFFProgress(cell.name) == cell.isIntermediate)
    }

    /// The name this matches must be the name the builder emits, or a crashed conversion
    /// leaves its bookkeeping in staging forever.
    @Test("the generated progress name is the one the sweep recognizes")
    func theGeneratedNameIsRecognized() {
        let name = YtDlpCommandBuilder.ffProgressFileName(forVideoID: StagingFixture.videoID)

        #expect(DownloadStagingSweeper.isFFProgress(name))
        #expect(DownloadStagingSweeper.isSweepable(name))
        #expect(name.contains(DownloadStagingSweeper.artifactMarker(forVideoID: StagingFixture.videoID)))
    }

    /// What the sweep actually consults: any predicate is enough.
    @Test("sweepable is the union of the three predicates", arguments: [
        IntermediateCell("Song.part", true),
        IntermediateCell("Song.m4a", true),
        IntermediateCell("Song.m4a.part-Frag1", true),
        IntermediateCell("ffprogress [dQw4w9WgXcQ].txt", true),
        IntermediateCell("notes.txt", false),
    ])
    func theSweepableUnionIsExact(cell: IntermediateCell) {
        #expect(DownloadStagingSweeper.isSweepable(cell.name) == cell.isIntermediate)
    }

    /// A conversion the app died during leaves its progress file behind with nothing to
    /// read it — the launch sweep is the only thing that ever reclaims one.
    @Test("a stale conversion progress file is swept at launch")
    func aStaleConversionProgressFileIsSwept() throws {
        let staging = try Self.makeStagingDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }
        let name = YtDlpCommandBuilder.ffProgressFileName(forVideoID: StagingFixture.videoID)
        let stale = try Self.seed(name, in: staging, age: DownloadStagingSweeper.staleAge + 60)
        let fresh = try Self.seed("ffprogress [\(DownloadFixture.otherVideoID)].txt", in: staging, age: 10)

        let removed = DownloadStagingSweeper.sweep(directory: staging, now: Self.reference)

        #expect(removed.map(\.lastPathComponent) == [name])
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }

    @Test("the staging directory hangs off Application Support under MacAMP")
    func theStagingPathIsStable() {
        let base = URL(fileURLWithPath: "/tmp/AppSupport", isDirectory: true)

        let directory = DownloadStagingLocation.directory(inApplicationSupport: base)

        #expect(directory.path.hasSuffix("/AppSupport/MacAMP/Downloads-Staging"))
        #expect(DownloadStagingLocation.applicationSupportSubpath == "MacAMP/Downloads-Staging")
    }

    // MARK: Fixtures

    /// A fixed clock, so an aged file's staleness never depends on the wall time the
    /// suite happened to run at.
    static let reference = Date(timeIntervalSince1970: 1_800_000_000)

    static func makeStagingDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("macamp-staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Writes `name` with an mtime of exactly `age` seconds before ``reference``.
    @discardableResult
    static func seed(_ name: String, in directory: URL, age: TimeInterval) throws -> URL {
        let url = directory.appendingPathComponent(name, isDirectory: false)
        try Data("x".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: reference.addingTimeInterval(-age)],
            ofItemAtPath: url.path
        )
        return url
    }
}

/// One row of the shape table: a file name and whether it is a yt-dlp intermediate.
struct IntermediateCell: CustomStringConvertible {
    let name: String
    let isIntermediate: Bool

    init(_ name: String, _ isIntermediate: Bool) {
        self.name = name
        self.isIntermediate = isIntermediate
    }

    var description: String {
        "\(name) -> \(isIntermediate)"
    }
}
