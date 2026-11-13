import Foundation
import GRDB
import Persistence
import Testing

@Suite("PlaylistIO")
struct PlaylistIOTests {
    private let basePath = "/Music"

    @Test("m3u import resolves library tracks and reports unresolved with line numbers")
    func m3uImportReportsUnresolved() throws {
        let playlistIO = try seededIO()
        let contents = try PlaylistIOFixtures.fixtureContents("sample.m3u")
        let result = try playlistIO.importPlaylist(contents: contents, format: .m3u, basePath: basePath)

        #expect(result.tracks.compactMap(\.title) == ["Song One", "Song Two", "Song Three"])
        #expect(result.tracks.count == 3)
        #expect(result.unresolved.count == 1)
        let ghost = try #require(result.unresolved.first)
        #expect(ghost.resolvedPath == "/Music/ghost.flac")
        #expect(ghost.rawPath == "ghost.flac")
        #expect(ghost.lineNumber == 9)
    }

    @Test("pls import resolves library tracks and reports unresolved with line numbers")
    func plsImportReportsUnresolved() throws {
        let playlistIO = try seededIO()
        let contents = try PlaylistIOFixtures.fixtureContents("sample.pls")
        let result = try playlistIO.importPlaylist(contents: contents, format: .pls, basePath: basePath)

        #expect(result.tracks.count == 3)
        #expect(result.unresolved.count == 1)
        let ghost = try #require(result.unresolved.first)
        #expect(ghost.resolvedPath == "/Music/ghost.flac")
        #expect(ghost.lineNumber == 11)
    }

    @Test("m3u round-trips: import, export relative, re-import yields the same tracks")
    func m3uRoundTrip() throws {
        let playlistIO = try seededIO()
        let original = try playlistIO.importPlaylist(
            contents: PlaylistIOFixtures.fixtureContents("sample.m3u"),
            format: .m3u,
            basePath: basePath
        )
        let exported = try playlistIO.exportPlaylist(
            tracks: original.tracks, format: .m3u, pathStyle: .relative, basePath: basePath
        )
        let reimported = try playlistIO.importPlaylist(contents: exported, format: .m3u, basePath: basePath)

        #expect(reimported.tracks.compactMap(\.id) == original.tracks.compactMap(\.id))
        #expect(reimported.unresolved.isEmpty)
        #expect(exported.contains("#EXTM3U"))
        #expect(exported.contains("#EXTINF:210,Artist One - Song One"))
        #expect(exported.contains("song-one.flac"))
        #expect(exported.contains("sub/song-two.flac"))
    }

    @Test("pls round-trips and renders numbered absolute entries")
    func plsRoundTrip() throws {
        let playlistIO = try seededIO()
        let original = try playlistIO.importPlaylist(
            contents: PlaylistIOFixtures.fixtureContents("sample.pls"),
            format: .pls,
            basePath: basePath
        )
        let exported = try playlistIO.exportPlaylist(
            tracks: original.tracks, format: .pls, pathStyle: .absolute, basePath: nil
        )
        let reimported = try playlistIO.importPlaylist(contents: exported, format: .pls, basePath: basePath)

        #expect(reimported.tracks.compactMap(\.id) == original.tracks.compactMap(\.id))
        #expect(exported.contains("[playlist]"))
        #expect(exported.contains("File1=/Music/song-one.flac"))
        #expect(exported.contains("NumberOfEntries=3"))
        #expect(exported.contains("Version=2"))
    }

    @Test("m3u8 parses identically to m3u (content-equivalent)")
    func m3u8MatchesM3U() throws {
        let playlistIO = try seededIO()
        let contents = try PlaylistIOFixtures.fixtureContents("sample.m3u")
        let asM3U = try playlistIO.importPlaylist(contents: contents, format: .m3u, basePath: basePath)
        let asM3U8 = try playlistIO.importPlaylist(contents: contents, format: .m3u8, basePath: basePath)

        #expect(asM3U.tracks.compactMap(\.id) == asM3U8.tracks.compactMap(\.id))
        let exported = try playlistIO.exportPlaylist(
            tracks: asM3U8.tracks, format: .m3u8, pathStyle: .relative, basePath: basePath
        )
        #expect(exported.contains("#EXTM3U"))
    }

    @Test("relative export without a base path throws")
    func relativeExportRequiresBasePath() throws {
        let playlistIO = try seededIO()
        #expect(throws: PlaylistIOError.missingBasePathForRelativeExport) {
            _ = try playlistIO.exportPlaylist(tracks: [], format: .m3u, pathStyle: .relative, basePath: nil)
        }
    }

    @Test("jspf round-trips: export 3 tracks, re-import yields the same ids, ms duration + location array")
    func jspfRoundTrip() throws {
        let playlistIO = try seededIO()
        let original = try playlistIO.importPlaylist(
            contents: PlaylistIOFixtures.fixtureContents("sample.m3u"),
            format: .m3u,
            basePath: basePath
        )
        let exported = try playlistIO.exportPlaylist(
            tracks: original.tracks, format: .json, pathStyle: .absolute, basePath: nil
        )
        let reimported = try playlistIO.importPlaylist(contents: exported, format: .json, basePath: basePath)

        #expect(reimported.tracks.compactMap(\.id) == original.tracks.compactMap(\.id))
        #expect(reimported.tracks.count == 3)
        #expect(reimported.unresolved.isEmpty)

        let root = try JSONSerialization.jsonObject(with: Data(exported.utf8))
        let json = try #require(root as? [String: Any])
        let playlist = try #require(json["playlist"] as? [String: Any])
        let trackArray = try #require(playlist["track"] as? [[String: Any]])
        #expect(trackArray.count == 3)
        let firstTrack = try #require(trackArray.first)
        let location = try #require(firstTrack["location"] as? [String])
        #expect(location.count == 1)
        #expect(location.first?.hasPrefix("file://") == true)
        #expect(firstTrack["duration"] as? Int == 210_000)
        let pextension = try #require(playlist["extension"] as? [String: Any])
        #expect(pextension["macamp:version"] as? Int == 1)
    }

    @Test("jspf relative export resolves against basePath on re-import")
    func jspfRelativeRoundTrip() throws {
        let playlistIO = try seededIO()
        let original = try playlistIO.importPlaylist(
            contents: PlaylistIOFixtures.fixtureContents("sample.m3u"),
            format: .m3u,
            basePath: basePath
        )
        let exported = try playlistIO.exportPlaylist(
            tracks: original.tracks, format: .json, pathStyle: .relative, basePath: basePath
        )
        #expect(exported.contains("song-one.flac"))
        #expect(exported.contains("sub/song-two.flac"))

        let reimported = try playlistIO.importPlaylist(contents: exported, format: .json, basePath: basePath)
        #expect(reimported.tracks.compactMap(\.id) == original.tracks.compactMap(\.id))
        #expect(reimported.unresolved.isEmpty)
    }

    @Test("jspf import without a version defaults gracefully; missing files go to unresolved")
    func jspfMissingVersionAndUnresolved() throws {
        let playlistIO = try seededIO()
        let json = """
        {
          "playlist": {
            "title": "Edge",
            "track": [
              { "location": ["file:///Music/song-one.flac"], "duration": 210000 },
              { "location": ["file:///Music/ghost.flac"], "duration": 1000 }
            ]
          }
        }
        """
        let result = try playlistIO.importPlaylist(contents: json, format: .json, basePath: basePath)

        #expect(result.tracks.count == 1)
        #expect(result.tracks.first?.title == "Song One")
        #expect(result.unresolved.count == 1)
        let ghost = try #require(result.unresolved.first)
        #expect(ghost.resolvedPath == "/Music/ghost.flac")
        #expect(ghost.lineNumber == 2)
    }

    @Test("jspf import throws on malformed json")
    func jspfMalformedThrows() throws {
        let playlistIO = try seededIO()
        #expect(throws: PlaylistIOError.malformedPlaylist) {
            _ = try playlistIO.importPlaylist(
                contents: "{ \"playlist\": ", format: .json, basePath: basePath
            )
        }
    }

    private func seededIO() throws -> PlaylistFileIO {
        let appDB = try AppDatabase.makeEmpty()
        try appDB.writer.write { db in
            _ = try PlaylistIOFixtures.insertNamedTrack(
                db, path: "/Music/song-one.flac", title: "Song One", artist: "Artist One", duration: 210
            )
            _ = try PlaylistIOFixtures.insertNamedTrack(
                db, path: "/Music/sub/song-two.flac", title: "Song Two", artist: "Artist Two", duration: 185
            )
            _ = try PlaylistIOFixtures.insertNamedTrack(
                db, path: "/Music/song-three.flac", title: "Song Three", artist: "Artist Three", duration: 240
            )
        }
        return PlaylistFileIO(appDB)
    }
}
