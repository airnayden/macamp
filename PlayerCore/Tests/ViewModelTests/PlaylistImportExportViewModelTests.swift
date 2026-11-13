import Foundation
import Persistence
import Testing
@testable import ViewModels

@MainActor
struct PlaylistImportExportViewModelTests {
    private func makeModel(_ database: AppDatabase) -> PlaylistImportExportViewModel {
        PlaylistImportExportViewModel(
            playlistIO: PlaylistFileIO(database),
            repository: PlaylistRepository(database)
        )
    }

    /// Seeds `paths` as library tracks and returns a playlist containing them in order.
    private func makeSourcePlaylist(
        _ database: AppDatabase,
        paths: [String]
    ) async throws -> Int64 {
        let trackRepository = TrackRepository(database)
        let inserted = try paths.enumerated().map { index, path in
            try trackRepository.insert(makeTrackRecord(filePath: path, title: "Track \(index)"))
        }
        let playlistRepository = PlaylistRepository(database)
        let source = try await playlistRepository.insert(PlaylistRecord(name: "Source"))
        let sourceId = try #require(source.id)
        for track in inserted {
            let trackId = try #require(track.id)
            try await playlistRepository.addTrack(trackId: trackId, toPlaylist: sourceId)
        }
        return sourceId
    }

    private func filePaths(
        _ database: AppDatabase,
        playlistId: Int64
    ) async throws -> [String] {
        let page = try await PlaylistRepository(database)
            .playlistTracksPage(playlistId: playlistId, after: nil, limit: 100)
        return page.items.map(\.track.filePath)
    }

    // MARK: - Round-trip (export -> JSPF -> import)

    @Test func roundtripJSPFThreeTracks() async throws {
        let database = try AppDatabase.makeEmpty()
        let paths = ["/Music/Album/01.flac", "/Music/Album/02.flac", "/Music/Album/03.flac"]
        let sourceId = try await makeSourcePlaylist(database, paths: paths)
        let model = makeModel(database)

        let jspf = try await model.exportContents(playlistId: sourceId, format: .json, relativePaths: false)
        #expect(jspf.contains("file:///Music/Album/01.flac"))

        let outcome = try await model.importContents(jspf, format: .json, basePath: "/", named: "Imported")
        #expect(outcome.resolvedCount == 3)
        #expect(outcome.unresolved.isEmpty)
        #expect(model.unresolved.isEmpty)

        let imported = try await filePaths(database, playlistId: outcome.playlistId)
        #expect(imported == paths)
    }

    // MARK: - Unresolved entries are surfaced, not dropped

    @Test func importSurfacesUnresolvedEntries() async throws {
        let database = try AppDatabase.makeEmpty()
        let trackRepository = TrackRepository(database)
        _ = try trackRepository.insert(makeTrackRecord(filePath: "/Music/exists.flac", title: "Exists"))
        let model = makeModel(database)

        let m3u = "#EXTM3U\n/Music/exists.flac\n/Music/missing.flac\n"
        let outcome = try await model.importContents(m3u, format: .m3u, basePath: "/", named: "Partial")

        #expect(outcome.resolvedCount == 1)
        #expect(outcome.unresolved.count == 1)
        let entry = try #require(outcome.unresolved.first)
        #expect(entry.rawPath == "/Music/missing.flac")
        #expect(model.unresolved.count == 1)

        // The one resolved track still landed in the new playlist.
        let imported = try await filePaths(database, playlistId: outcome.playlistId)
        #expect(imported == ["/Music/exists.flac"])

        model.clearUnresolved()
        #expect(model.unresolved.isEmpty)
    }

    // MARK: - Every format round-trips

    @Test func allFormatsRoundtrip() async throws {
        for format in PlaylistFormat.allCases {
            let database = try AppDatabase.makeEmpty()
            let paths = ["/Songs/a.flac", "/Songs/b.flac"]
            let sourceId = try await makeSourcePlaylist(database, paths: paths)
            let model = makeModel(database)

            let contents = try await model.exportContents(playlistId: sourceId, format: format, relativePaths: false)
            let outcome = try await model.importContents(
                contents,
                format: format,
                basePath: "/",
                named: "Imported-\(format.rawValue)"
            )
            #expect(outcome.resolvedCount == 2, "format \(format.rawValue) should resolve both tracks")
            #expect(outcome.unresolved.isEmpty, "format \(format.rawValue) should leave nothing unresolved")
            let imported = try await filePaths(database, playlistId: outcome.playlistId)
            #expect(imported == paths, "format \(format.rawValue) should preserve order")
        }
    }

    // MARK: - Relative export resolves a common ancestor base

    @Test func relativeExportUsesCommonAncestor() async throws {
        let database = try AppDatabase.makeEmpty()
        let paths = ["/Music/Rock/a.flac", "/Music/Rock/b.flac"]
        let sourceId = try await makeSourcePlaylist(database, paths: paths)
        let model = makeModel(database)

        // No basePath supplied: relative falls back to the common ancestor /Music/Rock,
        // so each path line is relativized to a bare filename (titles are distinct).
        let m3u = try await model.exportContents(playlistId: sourceId, format: .m3u8, relativePaths: true)
        #expect(m3u.contains("\na.flac\n"))
        #expect(!m3u.contains("/Music/Rock"))

        // Importing back relative to that base re-resolves the absolute tracks.
        let outcome = try await model.importContents(m3u, format: .m3u8, basePath: "/Music/Rock", named: "Rel")
        #expect(outcome.resolvedCount == 2)
        #expect(outcome.unresolved.isEmpty)
    }

    // MARK: - File write: the outcome the shell must surface

    @Test func exportPlaylistWritesNonEmptyFile() async throws {
        let database = try AppDatabase.makeEmpty()
        let paths = ["/Music/Album/01.flac", "/Music/Album/02.flac"]
        let sourceId = try await makeSourcePlaylist(database, paths: paths)
        let model = makeModel(database)
        let directory = try makeTemporaryDirectory("macamp-export")
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("Playlist.json")

        try await model.exportPlaylist(playlistId: sourceId, to: destination, format: .json, relativePaths: false)

        #expect(FileManager.default.fileExists(atPath: destination.path))
        let written = try String(contentsOf: destination, encoding: .utf8)
        #expect(!written.isEmpty)
        for path in paths {
            #expect(written.contains(path), "exported JSPF should carry \(path)")
        }
        #expect(model.isBusy == false)
    }

    @Test func exportPlaylistToUnwritableDestinationThrows() async throws {
        let database = try AppDatabase.makeEmpty()
        let sourceId = try await makeSourcePlaylist(database, paths: ["/Music/Album/01.flac"])
        let model = makeModel(database)
        let directory = try makeTemporaryDirectory("macamp-export-readonly")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        // r-x, no w: an atomic write needs to create a sibling temp file here first.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        let destination = directory.appendingPathComponent("Playlist.json")

        await #expect(throws: (any Error).self) {
            try await model.exportPlaylist(
                playlistId: sourceId,
                to: destination,
                format: .json,
                relativePaths: false
            )
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(model.isBusy == false)
    }

    private func makeTemporaryDirectory(_ prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - Format <-> extension mapping

    @Test func formatExtensionMappingIsStable() {
        #expect(PlaylistImportExportViewModel.format(forFileExtension: "M3U") == .m3u)
        #expect(PlaylistImportExportViewModel.format(forFileExtension: "m3u8") == .m3u8)
        #expect(PlaylistImportExportViewModel.format(forFileExtension: "pls") == .pls)
        #expect(PlaylistImportExportViewModel.format(forFileExtension: "json") == .json)
        #expect(PlaylistImportExportViewModel.format(forFileExtension: "jspf") == .json)
        #expect(PlaylistImportExportViewModel.format(forFileExtension: "wat") == .m3u8)
        #expect(PlaylistImportExportViewModel.fileExtension(for: .json) == "json")
        #expect(PlaylistImportExportViewModel.fileExtension(for: .pls) == "pls")
    }
}
