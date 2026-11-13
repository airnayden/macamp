// PlaylistImportExportViewModel — the tested seam between the playlist file
// formats (``PlaylistIO``, Task 8/9) and the macOS / iOS playlist import/export
// UIs (Task 21).
//
// This view model owns NO format parsing: it composes the existing
// ``PlaylistFileIO`` (m3u / m3u8 / pls / JSPF-json) with the
// ``PlaylistRepositoryProviding`` membership writes. The shells provide the
// platform file affordances (macOS `NSSavePanel`/`NSOpenPanel`, iOS
// `ShareLink`/`fileImporter`) and hand this model either a `String` (tested,
// pure) or a `URL` (file IO, off the main actor).
//
// Off-main-actor discipline (the Task 3 hang-risk class): every file read/write
// and every format parse/render runs inside a `Task.detached` (the injected
// `PlaylistIO` and the `[TrackRecord]` value types are `Sendable`); only the
// observable state mutation and the GRDB-native `async` repository calls touch
// the `@MainActor`. The repository's own `async` overloads suspend on a reader/
// writer rather than parking the main thread.
//
// Unresolved import entries are REPORTED via the observable ``unresolved`` array
// (and the returned ``ImportOutcome``), never silently dropped — the shells
// surface "N of M tracks could not be found" in a sheet.
//
// Imports only Foundation + Observation + Persistence; MUST NOT import AppKit or
// UIKit (PlayerCore portability invariant).
import Foundation
import Observation
import Persistence

// MARK: - ImportOutcome

/// The result of an import: the new playlist's id, how many entries resolved to
/// library tracks, and every entry that did not.
public struct ImportOutcome: Sendable, Equatable {
    public let playlistId: Int64
    public let resolvedCount: Int
    public let unresolved: [UnresolvedPlaylistEntry]

    public init(playlistId: Int64, resolvedCount: Int, unresolved: [UnresolvedPlaylistEntry]) {
        self.playlistId = playlistId
        self.resolvedCount = resolvedCount
        self.unresolved = unresolved
    }
}

// MARK: - PlaylistImportExportError

public enum PlaylistImportExportError: Error, Equatable {
    /// The inserted playlist row came back without a primary key.
    case playlistInsertFailed
    /// The picked file could not be decoded as UTF-8 or Latin-1 text.
    case unreadableFile
}

// MARK: - PlaylistImportExportViewModel

/// Exports a playlist to a file (or string) and imports a file (or string) into a
/// new playlist, reusing ``PlaylistFileIO`` for all format work.
@MainActor
@Observable
public final class PlaylistImportExportViewModel {
    /// Entries from the most recent import whose path did not resolve to a track.
    /// Drives the "could not be found" sheet; cleared by ``clearUnresolved()``.
    public private(set) var unresolved: [UnresolvedPlaylistEntry] = []
    /// The playlist created by the most recent successful import, if any.
    public private(set) var lastImportedPlaylistId: Int64?
    /// `true` while an import/export operation is in flight (UI can disable input).
    public private(set) var isBusy = false

    @ObservationIgnored private let playlistIO: any PlaylistIO
    @ObservationIgnored private let repository: any PlaylistRepositoryProviding
    @ObservationIgnored private let pageSize: Int

    /// Creates the model over an injected ``PlaylistIO`` + playlist repository.
    ///
    /// - Parameters:
    ///   - playlistIO: Format reader/writer (production: `PlaylistFileIO`).
    ///   - repository: Playlist membership reads/writes.
    ///   - pageSize: Rows per keyset page when collecting a playlist for export.
    public init(
        playlistIO: any PlaylistIO,
        repository: any PlaylistRepositoryProviding,
        pageSize: Int = 200
    ) {
        self.playlistIO = playlistIO
        self.repository = repository
        self.pageSize = max(1, pageSize)
    }

    /// Clears the surfaced unresolved entries (e.g. when the user dismisses the
    /// import-summary sheet).
    public func clearUnresolved() {
        unresolved = []
    }
}

// MARK: - Export

public extension PlaylistImportExportViewModel {
    /// Renders a playlist to a `String` in `format`. Pure (no file IO); the format
    /// render runs off the main actor. `basePath` is required only for relative
    /// paths — when `relativePaths` is true and `basePath` is nil, the common
    /// ancestor directory of the tracks is used (falling back to absolute).
    func exportContents(
        playlistId: Int64,
        format: PlaylistFormat,
        relativePaths: Bool,
        basePath: String? = nil
    ) async throws -> String {
        let tracks = try await fetchAllTrackRecords(playlistId: playlistId)
        return try await Self.render(
            tracks: tracks,
            format: format,
            relativePaths: relativePaths,
            basePath: basePath,
            using: playlistIO
        )
    }

    /// Renders a playlist and writes it to `url` (a save-panel destination). The
    /// render + write run off the main actor. Relative paths resolve against the
    /// destination's own directory.
    func exportPlaylist(
        playlistId: Int64,
        to url: URL,
        format: PlaylistFormat,
        relativePaths: Bool
    ) async throws {
        isBusy = true
        defer { isBusy = false }
        let tracks = try await fetchAllTrackRecords(playlistId: playlistId)
        let exporter = playlistIO
        let directory = url.deletingLastPathComponent().path
        try await Task.detached {
            let contents = try Self.renderSync(
                tracks: tracks,
                format: format,
                relativePaths: relativePaths,
                basePath: directory,
                using: exporter
            )
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }.value
    }

    /// Renders a playlist to a temporary file (for `ShareLink`) and returns its
    /// URL. The file is named after the playlist with the format's extension.
    func exportToTemporaryFile(
        playlistId: Int64,
        playlistName: String,
        format: PlaylistFormat,
        relativePaths: Bool
    ) async throws -> URL {
        isBusy = true
        defer { isBusy = false }
        let tracks = try await fetchAllTrackRecords(playlistId: playlistId)
        let exporter = playlistIO
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            Self.fileName(for: playlistName, format: format)
        )
        try await Task.detached {
            let contents = try Self.renderSync(
                tracks: tracks,
                format: format,
                relativePaths: relativePaths,
                basePath: nil,
                using: exporter
            )
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }.value
        return url
    }
}

// MARK: - Import

public extension PlaylistImportExportViewModel {
    /// Imports a playlist from a picked `url`, creating a new playlist named after
    /// the file (unless `name` is given). The read + parse run off the main actor;
    /// unresolved entries are published to ``unresolved``.
    @discardableResult
    func importPlaylist(
        from url: URL,
        named name: String? = nil,
        profileId: Int64 = ProfileRecord.guestID
    ) async throws -> ImportOutcome {
        let format = Self.format(forFileExtension: url.pathExtension)
        let basePath = url.deletingLastPathComponent().path
        let importer = playlistIO
        isBusy = true
        defer { isBusy = false }
        let result = try await Task.detached {
            let contents = try Self.readContents(of: url)
            return try importer.importPlaylist(contents: contents, format: format, basePath: basePath)
        }.value
        let playlistName = name ?? url.deletingPathExtension().lastPathComponent
        return try await finishImport(result, named: playlistName, profileId: profileId)
    }

    /// Imports a playlist from in-memory `contents` (the tested, file-free path).
    /// Creates a new playlist named `name`; publishes unresolved entries.
    @discardableResult
    func importContents(
        _ contents: String,
        format: PlaylistFormat,
        basePath: String,
        named name: String,
        profileId: Int64 = ProfileRecord.guestID
    ) async throws -> ImportOutcome {
        let importer = playlistIO
        isBusy = true
        defer { isBusy = false }
        let result = try await Task.detached {
            try importer.importPlaylist(contents: contents, format: format, basePath: basePath)
        }.value
        return try await finishImport(result, named: name, profileId: profileId)
    }
}

// MARK: - Playlist build + collection (off-actor friendly)

private extension PlaylistImportExportViewModel {
    /// Creates the playlist, appends each resolved track in order, and publishes
    /// the unresolved entries + new playlist id.
    func finishImport(
        _ result: PlaylistImportResult,
        named name: String,
        profileId: Int64
    ) async throws -> ImportOutcome {
        let playlistId = try await createPlaylist(named: name, from: result.tracks, profileId: profileId)
        unresolved = result.unresolved
        lastImportedPlaylistId = playlistId
        return ImportOutcome(
            playlistId: playlistId,
            resolvedCount: result.tracks.count,
            unresolved: result.unresolved
        )
    }

    /// Inserts a new (plain) playlist owned by `profileId` and appends `tracks` in
    /// order via the repository's `addTrack` (append) write.
    func createPlaylist(named name: String, from tracks: [TrackRecord], profileId: Int64) async throws -> Int64 {
        let playlist = try await repository.create(named: name, profileId: profileId)
        guard let playlistId = playlist.id else {
            throw PlaylistImportExportError.playlistInsertFailed
        }
        for track in tracks {
            guard let trackId = track.id else { continue }
            try await repository.addTrack(trackId: trackId, toPlaylist: playlistId)
        }
        return playlistId
    }

    /// Collects a playlist's full ordered `[TrackRecord]` via bounded keyset pages
    /// (never loads the whole library at once).
    func fetchAllTrackRecords(playlistId: Int64) async throws -> [TrackRecord] {
        var all: [TrackRecord] = []
        var cursor: PageCursor<Int>?
        repeat {
            let page = try await repository.playlistTracksPage(
                playlistId: playlistId,
                after: cursor,
                limit: pageSize
            )
            all.append(contentsOf: page.items.map(\.track))
            cursor = page.nextCursor
        } while cursor != nil
        return all
    }
}

// MARK: - Format render + path helpers (pure, Sendable)

public extension PlaylistImportExportViewModel {
    /// Maps a file extension (case-insensitive) to a ``PlaylistFormat``. `jspf`
    /// and `json` both map to JSPF-json; unknown extensions default to m3u8.
    nonisolated static func format(forFileExtension ext: String) -> PlaylistFormat {
        switch ext.lowercased() {
        case "m3u": .m3u
        case "m3u8": .m3u8
        case "pls": .pls
        case "json", "jspf": .json
        default: .m3u8
        }
    }

    /// The on-disk file extension for a ``PlaylistFormat`` (JSPF exports as
    /// `.json`, matching the JSPF-in-JSON container).
    nonisolated static func fileExtension(for format: PlaylistFormat) -> String {
        switch format {
        case .m3u: "m3u"
        case .m3u8: "m3u8"
        case .pls: "pls"
        case .json: "json"
        }
    }
}

private extension PlaylistImportExportViewModel {
    /// Renders off the main actor (a `Task.detached` hop around the pure renderer).
    nonisolated static func render(
        tracks: [TrackRecord],
        format: PlaylistFormat,
        relativePaths: Bool,
        basePath: String?,
        using playlistIO: any PlaylistIO
    ) async throws -> String {
        try await Task.detached {
            try renderSync(
                tracks: tracks,
                format: format,
                relativePaths: relativePaths,
                basePath: basePath,
                using: playlistIO
            )
        }.value
    }

    /// Resolves the effective path style + base, then calls ``PlaylistIO``.
    /// Relative-with-no-base falls back to a computed common ancestor, and to
    /// absolute when the tracks share no ancestor (never throws on missing base).
    nonisolated static func renderSync(
        tracks: [TrackRecord],
        format: PlaylistFormat,
        relativePaths: Bool,
        basePath: String?,
        using playlistIO: any PlaylistIO
    ) throws -> String {
        guard relativePaths else {
            return try playlistIO.exportPlaylist(
                tracks: tracks,
                format: format,
                pathStyle: .absolute,
                basePath: nil
            )
        }
        let base = basePath ?? commonAncestorDirectory(of: tracks.map(\.filePath))
        guard let base else {
            return try playlistIO.exportPlaylist(
                tracks: tracks,
                format: format,
                pathStyle: .absolute,
                basePath: nil
            )
        }
        return try playlistIO.exportPlaylist(
            tracks: tracks,
            format: format,
            pathStyle: .relative,
            basePath: base
        )
    }

    /// A sanitized, format-suffixed file name for a temporary export.
    nonisolated static func fileName(for playlistName: String, format: PlaylistFormat) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = playlistName
            .components(separatedBy: invalid)
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? "playlist" : cleaned
        return "\(base).\(fileExtension(for: format))"
    }

    /// Reads a file as text, tolerating non-UTF-8 (legacy m3u) via Latin-1.
    nonisolated static func readContents(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        if let latin1 = String(data: data, encoding: .isoLatin1) {
            return latin1
        }
        throw PlaylistImportExportError.unreadableFile
    }

    /// The deepest directory shared by all `paths` (or nil if they share only the
    /// filesystem root / there are no paths).
    nonisolated static func commonAncestorDirectory(of paths: [String]) -> String? {
        let componentLists = paths.map {
            URL(fileURLWithPath: $0).deletingLastPathComponent().standardizedFileURL.pathComponents
        }
        guard var shared = componentLists.first else { return nil }
        for list in componentLists.dropFirst() {
            var index = 0
            let bound = min(shared.count, list.count)
            while index < bound, shared[index] == list[index] {
                index += 1
            }
            shared = Array(shared.prefix(index))
            if shared.count <= 1 { return nil }
        }
        return shared.count > 1 ? NSString.path(withComponents: shared) : nil
    }
}
