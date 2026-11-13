import Foundation
import Metadata
import PlayerCoreTestSupport
import Testing

/// The service-level contract of ``ReplayGainTagWriter``: which formats it
/// refuses, that a refusal never touches the file, and that everything it does
/// accept goes through the injected ``MetadataWriting`` unchanged.
@Suite("ReplayGainTagWriterTests")
struct ReplayGainTagWriterTests {
    private static let values = ReplayGainTagValues(
        trackGainDB: -7.5,
        trackPeak: 0.988_553,
        albumGainDB: -8.2,
        albumPeak: 0.997_162
    )

    // MARK: - Support policy

    @Test("only MP3 and FLAC are accepted")
    func allowListIsMP3AndFLAC() {
        #expect(ReplayGainTagSupport.writableExtensions == ["mp3", "flac"])
        #expect(ReplayGainTagSupport.unsupportedReason(forPathExtension: "mp3") == nil)
        #expect(ReplayGainTagSupport.unsupportedReason(forPathExtension: "FLAC") == nil)
    }

    @Test(
        "the whole Ogg family is refused because the container cannot prove it is not Opus",
        arguments: ["ogg", "oga", "opus", "spx"]
    )
    func oggFamilyIsRefused(pathExtension: String) {
        #expect(
            ReplayGainTagSupport.unsupportedReason(forPathExtension: pathExtension)
                == .oggFamilyMayCarryR128
        )
    }

    @Test(
        "the whole MP4 family is refused because the backend discards the atoms",
        arguments: ["m4a", "mp4", "m4b", "m4r", "aac"]
    )
    func mp4FamilyIsRefused(pathExtension: String) {
        #expect(
            ReplayGainTagSupport.unsupportedReason(forPathExtension: pathExtension)
                == .mp4BackendDiscardsTags
        )
    }

    @Test("an extension nobody verified is refused rather than attempted")
    func unverifiedFormatIsRefused() {
        #expect(ReplayGainTagSupport.unsupportedReason(forPathExtension: "wv") == .formatNotVerified)
        #expect(ReplayGainTagSupport.unsupportedReason(forPathExtension: "") == .formatNotVerified)
    }

    // MARK: - Refusals never touch the file

    @Test(
        "a refused format throws before any I/O and leaves bytes and mtime alone",
        arguments: [
            ("opus", ReplayGainTagUnsupportedReason.oggFamilyMayCarryR128),
            ("ogg", .oggFamilyMayCarryR128),
            ("m4a", .mp4BackendDiscardsTags),
            ("shn", .formatNotVerified),
        ]
    )
    func refusalLeavesFileUntouched(
        pathExtension: String,
        expected: ReplayGainTagUnsupportedReason
    ) throws {
        try Scratch.withStubFile(pathExtension: pathExtension) { url in
            let before = try Scratch.identity(of: url)

            let error = #expect(throws: ReplayGainTagWriteError.self) {
                try ReplayGainTagWriter().writeReplayGainTags(Self.values, to: url)
            }
            guard case let .unsupportedFormat(_, reason) = error else {
                Issue.record("expected .unsupportedFormat, got \(String(describing: error))")
                return
            }
            #expect(reason == expected)
            #expect(try Scratch.identity(of: url) == before, "a refused write touched the file")
        }
    }

    @Test("a refusal never reaches the underlying writer")
    func refusalDoesNotDelegate() throws {
        let backend = FakeMetadataWriter()
        let url = URL(fileURLWithPath: "/tmp/anything.opus")
        _ = #expect(throws: ReplayGainTagWriteError.self) {
            try ReplayGainTagWriter(writer: backend).writeReplayGainTags(Self.values, to: url)
        }
        #expect(backend.calls.isEmpty)
    }

    // MARK: - Empty input is reported, not silently skipped

    @Test("an all-nil measurement throws .noValuesToWrite and writes nothing")
    func emptyValuesAreRefused() throws {
        let backend = FakeMetadataWriter()
        let url = URL(fileURLWithPath: "/tmp/anything.flac")
        let error = #expect(throws: ReplayGainTagWriteError.self) {
            try ReplayGainTagWriter(writer: backend)
                .writeReplayGainTags(ReplayGainTagValues(), to: url)
        }
        guard case .noValuesToWrite = error else {
            Issue.record("expected .noValuesToWrite, got \(String(describing: error))")
            return
        }
        #expect(backend.calls.isEmpty)
    }

    @Test("a silent track (gain nil, peak present) still has something to write")
    func peakOnlyIsNotEmpty() throws {
        let backend = FakeMetadataWriter()
        let url = URL(fileURLWithPath: "/tmp/silent.flac")
        try ReplayGainTagWriter(writer: backend)
            .writeReplayGainTags(ReplayGainTagValues(trackPeak: 0.0), to: url)

        let call = try #require(backend.calls.first)
        #expect(call.metadata.replayGainTrackPeak == 0.0)
        #expect(call.metadata.replayGainTrackGain == nil)
    }

    // MARK: - Delegation carries exactly the four figures

    @Test("an accepted write hands the backend a ReplayGain-only patch")
    func acceptedWriteDelegatesReplayGainOnly() throws {
        let backend = FakeMetadataWriter()
        let url = URL(fileURLWithPath: "/tmp/track.flac")
        try ReplayGainTagWriter(writer: backend).writeReplayGainTags(Self.values, to: url)

        let call = try #require(backend.calls.first)
        #expect(backend.calls.count == 1)
        #expect(call.url == url)
        #expect(call.metadata.replayGainTrackGain == Self.values.trackGainDB)
        #expect(call.metadata.replayGainTrackPeak == Self.values.trackPeak)
        #expect(call.metadata.replayGainAlbumGain == Self.values.albumGainDB)
        #expect(call.metadata.replayGainAlbumPeak == Self.values.albumPeak)
        #expect(call.metadata.title == nil)
        #expect(call.metadata.artist == nil)
        #expect(call.metadata.artwork == nil)
    }

    @Test("a backend failure is wrapped, keeping the underlying MetadataWriteError")
    func backendFailureIsWrapped() {
        let url = URL(fileURLWithPath: "/tmp/track.flac")
        let backend = FakeMetadataWriter(errorToThrow: .permissionDenied(url: url))
        let error = #expect(throws: ReplayGainTagWriteError.self) {
            try ReplayGainTagWriter(writer: backend).writeReplayGainTags(Self.values, to: url)
        }
        guard case let .writeFailed(_, underlying) = error else {
            Issue.record("expected .writeFailed, got \(String(describing: error))")
            return
        }
        #expect(underlying == .permissionDenied(url: url))
        #expect(error?.url == url)
    }

    // MARK: - WritableMetadata carries the fields

    @Test("a ReplayGain-only patch is NOT empty, so the writer cannot short-circuit it")
    func replayGainOnlyPatchIsNotEmpty() {
        #expect(WritableMetadata().isEmpty)
        #expect(!WritableMetadata().hasReplayGain)

        let patch = Self.values.patch
        #expect(!patch.isEmpty)
        #expect(patch.hasReplayGain)
    }

    @Test("each ReplayGain field alone is enough to make a patch non-empty")
    func everyFieldCountsTowardsEmptiness() {
        let patches = [
            WritableMetadata(replayGainTrackGain: -1),
            WritableMetadata(replayGainTrackPeak: 1),
            WritableMetadata(replayGainAlbumGain: -1),
            WritableMetadata(replayGainAlbumPeak: 1),
        ]
        for patch in patches {
            #expect(!patch.isEmpty)
        }
    }
}
