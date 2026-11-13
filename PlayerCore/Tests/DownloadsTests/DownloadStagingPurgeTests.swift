// `DownloadStagingSweeper.purgeArtifacts` — the precise half of the fix for the worst
// defect this feature had.
//
// THE DEFECT: interrupting a download during post-processing kills the child mid-mux
// and leaves `Title [id].m4a` in staging — a structurally valid file that is merely
// short. It carries no partial marker, so nothing swept it. The next attempt at that
// video made yt-dlp ADOPT it as already-post-processed: tags embedded, file moved to
// the destination, `after_move:MACAMP-FILE|…` printed, exit 0. MacAMP called that a
// success, toasted it, and imported a truncated file. Measured: 10 h 04 m in, 6 h 26 m
// out. Nothing downstream can catch it — the file is valid and `ffprobe` is clean.
//
// THE TWO SCOPES exist because "the row is gone" and "the row is coming back" want
// different answers, and collapsing them costs real user value either way:
//   • cancel/quit  -> `.allArtifacts`     — the row is dropped, so its 655 MB `.part`
//                                           is waste, not an asset.
//   • pause        -> `.adoptableOutputs` — the row is requeued and yt-dlp resumes
//                                           into its own `.part`; deleting that would
//                                           throw away a nearly-complete transfer to
//                                           solve a problem a `.part` does not have.
//
// The queue-level proof that an interruption actually triggers this lives in
// `DownloadQueueStagingHygieneTests`.
import Foundation
import Services
import Testing

@Suite("Download staging purge")
struct DownloadStagingPurgeTests {
    @Test("cancelling a row removes every artifact it owns, resumables included")
    func aCancelledRowLosesEveryArtifactItOwns() throws {
        let staging = try StagingFixture.makeDirectory()
        defer { StagingFixture.remove(staging) }
        let owned = try StagingFixture.seedAll(StagingFixture.ownedNames, in: staging)

        let removed = DownloadStagingSweeper.purgeArtifacts(
            ofVideoID: StagingFixture.videoID,
            in: staging,
            scope: .allArtifacts
        )

        #expect(Set(removed.map(\.lastPathComponent)) == Set(StagingFixture.ownedNames))
        #expect(owned.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    /// The adoptable container goes so a resumed run cannot inherit it; the `.part` and
    /// `.ytdl` stay so the resumed run does not restart from zero.
    @Test("pausing a row removes only what a retry could adopt")
    func aPausedRowKeepsItsResumablePartial() throws {
        let staging = try StagingFixture.makeDirectory()
        defer { StagingFixture.remove(staging) }
        try StagingFixture.seedAll(StagingFixture.ownedNames, in: staging)

        let removed = DownloadStagingSweeper.purgeArtifacts(
            ofVideoID: StagingFixture.videoID,
            in: staging,
            scope: .adoptableOutputs
        )

        #expect(Set(removed.map(\.lastPathComponent)) == [
            StagingFixture.adoptableContainer,
            StagingFixture.muxScratch,
            StagingFixture.thumbnail,
        ])
        #expect(StagingFixture.exists(StagingFixture.resumablePartial, in: staging))
        #expect(StagingFixture.exists(StagingFixture.resumeState, in: staging))
    }

    /// The queue is serial, but a purge that matched on shape alone would still reach
    /// the leftovers of every OTHER video in the directory.
    @Test("a purge never touches another row's files", arguments: [
        DownloadStagingPurgeScope.allArtifacts,
        DownloadStagingPurgeScope.adoptableOutputs,
    ])
    func aPurgeNeverTouchesAnotherRowsFiles(scope: DownloadStagingPurgeScope) throws {
        let staging = try StagingFixture.makeDirectory()
        defer { StagingFixture.remove(staging) }
        try StagingFixture.seedAll(StagingFixture.ownedNames, in: staging)
        let foreign = "Gangnam Style [\(DownloadFixture.otherVideoID)].m4a"
        try StagingFixture.seed(foreign, in: staging)
        try StagingFixture.seed("notes.txt", in: staging)

        DownloadStagingSweeper.purgeArtifacts(
            ofVideoID: StagingFixture.videoID,
            in: staging,
            scope: scope
        )

        #expect(StagingFixture.exists(foreign, in: staging))
        #expect(StagingFixture.exists("notes.txt", in: staging))
    }

    /// The same load-bearing claim the launch sweep makes: only the directory handed in
    /// is ever read. The destination holds the listener's real music, under filenames of
    /// exactly this shape.
    @Test("the purge never reaches the destination folder")
    func thePurgeNeverReachesTheDestinationFolder() throws {
        let root = try StagingFixture.makeDirectory()
        defer { StagingFixture.remove(root) }
        let staging = root.appendingPathComponent("Downloads-Staging", isDirectory: true)
        let destination = root.appendingPathComponent("MacAMP Downloads", isDirectory: true)
        for directory in [staging, destination] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try StagingFixture.seed(StagingFixture.adoptableContainer, in: staging)
        try StagingFixture.seed(StagingFixture.adoptableContainer, in: destination)

        DownloadStagingSweeper.purgeArtifacts(
            ofVideoID: StagingFixture.videoID,
            in: staging,
            scope: .allArtifacts
        )

        #expect(!StagingFixture.exists(StagingFixture.adoptableContainer, in: staging))
        #expect(StagingFixture.exists(StagingFixture.adoptableContainer, in: destination))
    }

    /// An empty id would build the marker `[]`, which half the directory contains.
    @Test("an empty video id matches nothing")
    func anEmptyVideoIDMatchesNothing() throws {
        let staging = try StagingFixture.makeDirectory()
        defer { StagingFixture.remove(staging) }
        try StagingFixture.seedAll(StagingFixture.ownedNames, in: staging)

        let removed = DownloadStagingSweeper.purgeArtifacts(
            ofVideoID: "",
            in: staging,
            scope: .allArtifacts
        )

        #expect(removed.isEmpty)
        #expect(StagingFixture.exists(StagingFixture.adoptableContainer, in: staging))
    }

    /// A directory named like an artifact is not a file, and a purge must not take its
    /// contents with it.
    @Test("a subdirectory carrying the marker is neither recursed into nor deleted")
    func thePurgeDoesNotRecurse() throws {
        let staging = try StagingFixture.makeDirectory()
        defer { StagingFixture.remove(staging) }
        let nested = staging.appendingPathComponent(StagingFixture.adoptableContainer, isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let buried = try StagingFixture.seed(StagingFixture.resumablePartial, in: nested)

        let removed = DownloadStagingSweeper.purgeArtifacts(
            ofVideoID: StagingFixture.videoID,
            in: staging,
            scope: .allArtifacts
        )

        #expect(removed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: buried.path))
    }

    // MARK: - Conversion progress (todo 9)

    //
    // ADDITIVE. Todo 3 promised this file would not be edited AT ALL, and kept that
    // promise — an empty `git diff --stat` was its compliance evidence. Todo 9 is the
    // todo that explicitly asks for these cases, so the cases below are appended and
    // every test above is left exactly as todo 3 left it.

    /// BOTH scopes, because they answer different questions and only one of them is
    /// load-bearing for the new predicate. `.allArtifacts` matches anything carrying the
    /// marker, so it would reclaim this file even if `isFFProgress` did not exist —
    /// `.adoptableOutputs` is the scope that actually binds it, and a failed row is
    /// exactly where a stale progress file would otherwise outlive its run.
    @Test("a purge reclaims the conversion progress file at either scope", arguments: [
        DownloadStagingPurgeScope.allArtifacts,
        DownloadStagingPurgeScope.adoptableOutputs,
    ])
    func aPurgeReclaimsTheConversionProgressFile(scope: DownloadStagingPurgeScope) throws {
        let staging = try StagingFixture.makeDirectory()
        defer { StagingFixture.remove(staging) }
        let name = YtDlpCommandBuilder.ffProgressFileName(forVideoID: StagingFixture.videoID)
        try StagingFixture.seed(name, in: staging)

        let removed = DownloadStagingSweeper.purgeArtifacts(
            ofVideoID: StagingFixture.videoID,
            in: staging,
            scope: scope
        )

        #expect(removed.map(\.lastPathComponent) == [name])
        #expect(!StagingFixture.exists(name, in: staging))
    }

    /// The resumable partial must still survive the failure scope now that a second
    /// shape joined it — a widening that also took the `.part` would throw away a
    /// nearly-complete transfer on every retryable error.
    @Test("reclaiming the progress file does not widen the failure scope")
    func theFailureScopeStillKeepsResumableState() throws {
        let staging = try StagingFixture.makeDirectory()
        defer { StagingFixture.remove(staging) }
        let name = YtDlpCommandBuilder.ffProgressFileName(forVideoID: StagingFixture.videoID)
        try StagingFixture.seedAll(StagingFixture.ownedNames + [name], in: staging)

        DownloadStagingSweeper.purgeArtifacts(
            ofVideoID: StagingFixture.videoID,
            in: staging,
            scope: .adoptableOutputs
        )

        #expect(!StagingFixture.exists(name, in: staging))
        #expect(StagingFixture.exists(StagingFixture.resumablePartial, in: staging))
        #expect(StagingFixture.exists(StagingFixture.resumeState, in: staging))
    }

    /// One row's purge must not reclaim a sibling's conversion progress, and a plain
    /// `.txt` in the directory is not engine bookkeeping at all.
    @Test("a purge never reaches another row's progress file", arguments: [
        DownloadStagingPurgeScope.allArtifacts,
        DownloadStagingPurgeScope.adoptableOutputs,
    ])
    func aPurgeNeverReachesAnotherRowsProgressFile(scope: DownloadStagingPurgeScope) throws {
        let staging = try StagingFixture.makeDirectory()
        defer { StagingFixture.remove(staging) }
        let foreign = YtDlpCommandBuilder.ffProgressFileName(forVideoID: DownloadFixture.otherVideoID)
        try StagingFixture.seed(foreign, in: staging)
        try StagingFixture.seed("notes.txt", in: staging)

        let removed = DownloadStagingSweeper.purgeArtifacts(
            ofVideoID: StagingFixture.videoID,
            in: staging,
            scope: scope
        )

        #expect(removed.isEmpty)
        #expect(StagingFixture.exists(foreign, in: staging))
        #expect(StagingFixture.exists("notes.txt", in: staging))
    }

    @Test("the marker is the output template's bracketed id")
    func theMarkerIsTheOutputTemplatesBracketedID() {
        let marker = DownloadStagingSweeper.artifactMarker(forVideoID: StagingFixture.videoID)

        #expect(marker == "[\(StagingFixture.videoID)]")
        #expect(StagingFixture.ownedNames.allSatisfy { $0.contains(marker) })
    }
}
