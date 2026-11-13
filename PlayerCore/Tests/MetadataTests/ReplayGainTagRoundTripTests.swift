import Foundation
import Metadata
import Testing

/// On-disk ReplayGain round-trips through the real SFBAudioEngine / TagLib
/// backend, plus the pins that record what that backend can and cannot do.
///
/// These are the shipped form of the mechanism spike: SFB's dedicated
/// `replayGain*` properties persist for FLAC and MP3 and are re-read by
/// ``SFBMetadataReader``; `additionalMetadata` does not persist at all; and MP4 /
/// M4A drops the tags entirely on the pinned backend.
@Suite("ReplayGainTagRoundTripTests", .serialized)
struct ReplayGainTagRoundTripTests {
    /// Chosen so every field is distinguishable from the fixtures' committed
    /// values and from each other, and so both signs of gain are covered.
    private static let trackGain = 3.21
    private static let trackPeak = 0.987_654_32
    private static let albumGain = -6.54
    private static let albumPeak = 1.012_345_67

    /// SFB writes gains as `%+2.2f dB`, so a round-trip is exact to two decimals.
    private static let gainTolerance = 0.01
    /// Peaks are written as `%1.8f`.
    private static let peakTolerance = 1e-6

    private static var values: ReplayGainTagValues {
        ReplayGainTagValues(
            trackGainDB: trackGain,
            trackPeak: trackPeak,
            albumGainDB: albumGain,
            albumPeak: albumPeak
        )
    }

    private func expectRoundTrip(of fixture: URL) throws {
        try Scratch.withWorkingCopy(of: fixture) { url in
            try ReplayGainTagWriter().writeReplayGainTags(Self.values, to: url)

            let readBack = try SFBMetadataReader().readMetadata(from: url)
            let gain = try #require(readBack.replayGain)
            let trackGain = try #require(gain.trackGain)
            let trackPeak = try #require(gain.trackPeak)
            let albumGain = try #require(gain.albumGain)
            let albumPeak = try #require(gain.albumPeak)

            #expect(abs(trackGain - Self.trackGain) <= Self.gainTolerance)
            #expect(abs(trackPeak - Self.trackPeak) <= Self.peakTolerance)
            #expect(abs(albumGain - Self.albumGain) <= Self.gainTolerance)
            #expect(abs(albumPeak - Self.albumPeak) <= Self.peakTolerance)
        }
    }

    // MARK: - Round-trip on the verified formats

    @Test("FLAC: the four ReplayGain figures round-trip through SFBMetadataReader")
    func roundTripFLAC() throws {
        try expectRoundTrip(of: TestFixtures.flac)
    }

    @Test("MP3: the four ReplayGain figures round-trip through SFBMetadataReader")
    func roundTripMP3() throws {
        try expectRoundTrip(of: TestFixtures.mp3)
    }

    @Test("a ReplayGain-only write leaves every other tag and the artwork alone")
    func replayGainWriteIsAPatch() throws {
        try Scratch.withWorkingCopy(of: TestFixtures.flac) { url in
            let before = try SFBMetadataReader().readMetadata(from: url)
            try ReplayGainTagWriter().writeReplayGainTags(Self.values, to: url)

            let after = try SFBMetadataReader().readMetadata(from: url)
            #expect(after.title == before.title)
            #expect(after.artist == before.artist)
            #expect(after.album == before.album)
            #expect(after.year == before.year)
            #expect(after.trackNumber == before.trackNumber)
            #expect(after.hasArtwork == before.hasArtwork)
        }
    }

    @Test("a partial patch writes only the supplied figures and keeps the rest on disk")
    func partialPatchKeepsUntouchedFigures() throws {
        try Scratch.withWorkingCopy(of: TestFixtures.flac) { url in
            let committed = try #require(
                try SFBMetadataReader().readMetadata(from: url).replayGain
            )
            let committedAlbumGain = try #require(committed.albumGain)

            try ReplayGainTagWriter()
                .writeReplayGainTags(ReplayGainTagValues(trackGainDB: Self.trackGain), to: url)

            let gain = try #require(try SFBMetadataReader().readMetadata(from: url).replayGain)
            let trackGain = try #require(gain.trackGain)
            let albumGain = try #require(gain.albumGain)
            #expect(abs(trackGain - Self.trackGain) <= Self.gainTolerance)
            #expect(abs(albumGain - committedAlbumGain) <= Self.gainTolerance)
        }
    }

    // MARK: - Backend limitation pin (MP4 / M4A)

    /// Bypasses ``ReplayGainTagWriter``'s refusal on purpose and drives
    /// ``SFBMetadataWriter`` straight at an M4A, to pin WHY the refusal exists.
    ///
    /// On SFBAudioEngine 0.12.1 + CXXTagLib 2.1.x the write commits (the title
    /// lands) but the ReplayGain atoms are discarded: SFB names them
    /// `---:com.apple.iTunes:replaygain_*` (three hyphens) and TagLib only renders
    /// a freeform atom whose name starts `----` (four). If this test ever fails,
    /// the backend has been fixed and `ReplayGainTagSupport.writableExtensions`
    /// should gain the MP4 family.
    @Test("M4A: the backend silently discards ReplayGain while committing the rest")
    func mp4BackendDiscardsReplayGain() throws {
        try Scratch.withWorkingCopy(of: TestFixtures.m4a) { url in
            var patch = Self.values.patch
            patch.title = "Commit Probe"
            try SFBMetadataWriter().writeMetadata(patch, to: url)

            let readBack = try SFBMetadataReader().readMetadata(from: url)
            #expect(readBack.title == "Commit Probe", "the write itself did not commit")
            #expect(
                readBack.replayGain == nil,
                "SFB 0.12.1 now persists MP4 ReplayGain — widen ReplayGainTagSupport"
            )
        }
    }

    // MARK: - Failure paths leave the original untouched

    @Test("a 0444 file surfaces .writeFailed(.readOnlyFile) and is byte-identical after")
    func readOnlyFileRollsBack() throws {
        try Scratch.withWorkingCopy(of: TestFixtures.flac) { url in
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
            let before = try Scratch.identity(of: url)

            let error = #expect(throws: ReplayGainTagWriteError.self) {
                try ReplayGainTagWriter().writeReplayGainTags(Self.values, to: url)
            }
            guard case let .writeFailed(_, underlying) = error, case .readOnlyFile = underlying else {
                Issue.record("expected .writeFailed(.readOnlyFile), got \(String(describing: error))")
                return
            }
            #expect(try Scratch.identity(of: url) == before, "read-only original was modified")
        }
    }

    @Test("a missing file surfaces .writeFailed(.fileNotFound)")
    func missingFileThrows() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghost-\(UUID().uuidString).flac")
        let error = #expect(throws: ReplayGainTagWriteError.self) {
            try ReplayGainTagWriter().writeReplayGainTags(Self.values, to: url)
        }
        guard case let .writeFailed(_, underlying) = error, case .fileNotFound = underlying else {
            Issue.record("expected .writeFailed(.fileNotFound), got \(String(describing: error))")
            return
        }
    }
}
