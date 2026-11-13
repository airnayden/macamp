// Tests for the drag-and-drop import seam (Task 11): URL classification, root
// deduplication, and the folder-drop → scan → rows-inserted orchestration that
// the macOS shell wires into `.dropDestination`.
import Foundation
import GRDB
import Metadata
import Persistence
@testable import Services
import Testing

@Suite(.serialized)
struct DropImportTests {
    private func trackCount(_ database: AppDatabase) throws -> Int {
        try database.writer.read { try TrackRecord.fetchCount($0) }
    }

    // MARK: classification (pure)

    @Test func classifiesFolderAsRootAndAudioFileAsLoose() throws {
        let dir = try ScannerFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = try ScannerFixtures.writeFile(in: dir, name: "song.flac")
        let importer = DropImporter(scanner: FakeLibraryScanner())

        let plan = importer.plan(for: [dir, audio], existingRoots: [])

        #expect(plan.roots == [dir.standardizedFileURL])
        #expect(plan.looseFiles == [audio.standardizedFileURL])
        #expect(plan.rejected.isEmpty)
        #expect(!plan.isEmpty)
    }

    @Test func rejectsNonAudioFile() throws {
        let dir = try ScannerFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = try ScannerFixtures.writeFile(in: dir, name: "notes.txt")
        let importer = DropImporter(scanner: FakeLibraryScanner())

        let plan = importer.plan(for: [text], existingRoots: [])

        #expect(plan.roots.isEmpty)
        #expect(plan.looseFiles.isEmpty)
        #expect(plan.rejected == [text.standardizedFileURL])
        #expect(plan.isEmpty)
    }

    @Test func deduplicatesRootAlreadyPresent() throws {
        let dir = try ScannerFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let importer = DropImporter(scanner: FakeLibraryScanner())

        let plan = importer.plan(for: [dir], existingRoots: [dir])

        #expect(plan.roots.isEmpty)
        #expect(plan.rejected == [dir.standardizedFileURL])
        #expect(plan.isEmpty)
    }

    @Test func deduplicatesRepeatedRootWithinOneDrop() throws {
        let dir = try ScannerFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let importer = DropImporter(scanner: FakeLibraryScanner())

        let plan = importer.plan(for: [dir, dir], existingRoots: [])

        #expect(plan.roots == [dir.standardizedFileURL])
        #expect(plan.rejected == [dir.standardizedFileURL])
    }

    // MARK: orchestration (real scan → rows inserted)

    @MainActor
    @Test func droppingFolderAddsRootScansAndInsertsRows() async throws {
        let database = try AppDatabase.makeEmpty()
        let dir = try ScannerFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try ScannerFixtures.writeFile(in: dir, name: "a.flac")
        try ScannerFixtures.writeFile(in: dir, name: "b.mp3")
        let scanner = LibraryScanner(database: database, metadataReader: FakeMetadataReader())
        let importer = DropImporter(scanner: scanner)

        var addedRoots: [URL] = []
        let plan = importer.plan(for: [dir], existingRoots: [])
        let summary = await importer.run(plan) { addedRoots.append($0) }

        #expect(addedRoots == [dir.standardizedFileURL])
        #expect(summary.added == 2)
        try #expect(trackCount(database) == 2)
    }

    @MainActor
    @Test func droppingLooseAudioFilesImportsThem() async throws {
        let database = try AppDatabase.makeEmpty()
        let dir = try ScannerFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let flac = try ScannerFixtures.writeFile(in: dir, name: "one.flac")
        let mp3 = try ScannerFixtures.writeFile(in: dir, name: "two.mp3")
        let scanner = LibraryScanner(database: database, metadataReader: FakeMetadataReader())
        let importer = DropImporter(scanner: scanner)

        var addedRoots: [URL] = []
        let plan = importer.plan(for: [flac, mp3], existingRoots: [])
        let summary = await importer.run(plan) { addedRoots.append($0) }

        #expect(addedRoots.isEmpty)
        #expect(plan.looseFiles.count == 2)
        #expect(summary.added == 2)
        try #expect(trackCount(database) == 2)
    }

    @MainActor
    @Test func droppingTextFileAddsNoRootAndImportsNothing() async throws {
        let database = try AppDatabase.makeEmpty()
        let dir = try ScannerFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = try ScannerFixtures.writeFile(in: dir, name: "notes.txt")
        let scanner = LibraryScanner(database: database, metadataReader: FakeMetadataReader())
        let importer = DropImporter(scanner: scanner)

        var addedRoots: [URL] = []
        let plan = importer.plan(for: [text], existingRoots: [])
        let summary = await importer.run(plan) { addedRoots.append($0) }

        #expect(addedRoots.isEmpty)
        #expect(summary == ScanSummary())
        try #expect(trackCount(database) == 0)
    }
}
