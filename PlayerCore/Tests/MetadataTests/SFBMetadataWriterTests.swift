import CryptoKit
import Foundation
import Metadata
import Testing

@Suite("SFBMetadataWriterTests", .serialized)
struct SFBMetadataWriterTests {
    // MARK: - Working-copy helpers

    /// Copies a committed fixture into a fresh, writable temp directory and hands
    /// the copy's URL to `body`. The fixture itself is NEVER mutated — every test
    /// operates on a throw-away duplicate, then the whole scratch dir is removed.
    private func withWorkingCopy(
        of fixture: URL,
        perform body: (URL) throws -> Void
    ) throws {
        let manager = FileManager.default
        let scratch = manager.temporaryDirectory
            .appendingPathComponent("macamp-write-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer {
            // Restore writability so a 0444 test file can be torn down, then nuke.
            let copy = scratch.appendingPathComponent(fixture.lastPathComponent)
            try? manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: copy.path)
            try? manager.removeItem(at: scratch)
        }
        let copy = scratch.appendingPathComponent(fixture.lastPathComponent)
        try manager.copyItem(at: fixture, to: copy)
        try body(copy)
    }

    private func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Round-trip (the headline write path)

    @Test("write title + genre to a FLAC copy, re-read, and get the new values back")
    func roundTripTitleGenre() throws {
        try withWorkingCopy(of: TestFixtures.flac) { url in
            let writer = SFBMetadataWriter()
            try writer.writeMetadata(WritableMetadata(title: "Test Title", genre: "Jazz"), to: url)

            let readBack = try SFBMetadataReader().readMetadata(from: url)
            #expect(readBack.title == "Test Title")
            #expect(readBack.genre == "Jazz")
            // Patch semantics: fields we did NOT set must survive untouched.
            #expect(readBack.artist == "The Beatles")
            #expect(readBack.album == "Abbey Road")
        }
    }

    @Test("numeric + grouping fields (year, track/disc, albumArtist, composer) round-trip")
    func roundTripNumericFields() throws {
        try withWorkingCopy(of: TestFixtures.flac) { url in
            let edit = WritableMetadata(
                artist: "Miles Davis",
                albumArtist: "Miles Davis",
                composer: "Davis",
                year: 1959,
                trackNumber: 3,
                discNumber: 2
            )
            try SFBMetadataWriter().writeMetadata(edit, to: url)

            let readBack = try SFBMetadataReader().readMetadata(from: url)
            #expect(readBack.artist == "Miles Davis")
            #expect(readBack.albumArtist == "Miles Davis")
            #expect(readBack.composer == "Davis")
            #expect(readBack.year == 1959)
            #expect(readBack.trackNumber == 3)
            #expect(readBack.discNumber == 2)
        }
    }

    @Test("replacing artwork writes a new embedded cover that re-reads")
    func roundTripArtwork() throws {
        try withWorkingCopy(of: TestFixtures.flac) { url in
            // A minimal, valid 1x1 PNG.
            let png = Data([
                0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
                0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
                0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
                0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
                0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
                0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
                0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
                0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
                0x42, 0x60, 0x82,
            ])
            let art = EmbeddedArtwork(data: png, mimeType: "image/png", type: .frontCover)
            try SFBMetadataWriter().writeMetadata(WritableMetadata(artwork: [art]), to: url)

            let readBack = try SFBMetadataReader().readMetadata(from: url)
            #expect(readBack.hasArtwork)
            let cover = try #require(readBack.artwork.first)
            #expect(cover.data == png)
        }
    }

    // MARK: - Rollback: a read-only original is never mutated

    @Test("a 0444 (read-only) file throws .readOnlyFile and its bytes are unchanged")
    func readOnlyFileRollsBack() throws {
        try withWorkingCopy(of: TestFixtures.flac) { url in
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
            let before = try sha256(of: url)

            let error = #expect(throws: MetadataWriteError.self) {
                try SFBMetadataWriter().writeMetadata(WritableMetadata(title: "Nope"), to: url)
            }
            guard case .readOnlyFile = error else {
                Issue.record("expected .readOnlyFile, got \(String(describing: error))")
                return
            }

            let after = try sha256(of: url)
            #expect(before == after, "read-only original was modified")
        }
    }

    // MARK: - Unsupported formats are rejected without touching the file

    @Test("an unsupported extension (.shn) throws .unsupportedFormat and leaves bytes intact")
    func unsupportedFormatNotTouched() throws {
        let manager = FileManager.default
        let url = manager.temporaryDirectory.appendingPathComponent("track-\(UUID().uuidString).shn")
        let payload = Data("not really shorten".utf8)
        try payload.write(to: url)
        defer { try? manager.removeItem(at: url) }
        let before = try sha256(of: url)

        let error = #expect(throws: MetadataWriteError.self) {
            try SFBMetadataWriter().writeMetadata(WritableMetadata(title: "x"), to: url)
        }
        guard case .unsupportedFormat = error else {
            Issue.record("expected .unsupportedFormat, got \(String(describing: error))")
            return
        }
        #expect(try sha256(of: url) == before)
    }

    @Test("a missing file throws .fileNotFound")
    func missingFileThrows() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghost-\(UUID().uuidString).flac")
        let error = #expect(throws: MetadataWriteError.self) {
            try SFBMetadataWriter().writeMetadata(WritableMetadata(title: "x"), to: url)
        }
        guard case .fileNotFound = error else {
            Issue.record("expected .fileNotFound, got \(String(describing: error))")
            return
        }
    }

    // MARK: - Re-import hook + self-write suppression

    @Test("a successful write fires the onDidWrite re-import hook with the file URL")
    func didWriteHookFires() throws {
        try withWorkingCopy(of: TestFixtures.flac) { url in
            final class Box: @unchecked Sendable { var seen: URL? }
            let box = Box()
            let writer = SFBMetadataWriter(onDidWrite: { box.seen = $0 })
            try writer.writeMetadata(WritableMetadata(title: "Hooked"), to: url)
            #expect(box.seen == url)
        }
    }

    @Test("a successful write marks the path in the self-write registry")
    func selfWriteIsMarked() throws {
        try withWorkingCopy(of: TestFixtures.flac) { url in
            let registry = MetadataSelfWriteRegistry()
            let writer = SFBMetadataWriter(selfWriteRegistry: registry)
            #expect(!registry.isSelfWrite(url))
            try writer.writeMetadata(WritableMetadata(title: "Mine"), to: url)
            #expect(registry.isSelfWrite(url), "writer did not record its own write")
        }
    }
}
