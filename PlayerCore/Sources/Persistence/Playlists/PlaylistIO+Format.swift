import Foundation

// MARK: - ParsedPlaylistEntry

/// A raw path extracted from a playlist, tagged with its 1-based source line.
struct ParsedPlaylistEntry: Equatable {
    let lineNumber: Int
    let rawPath: String
}

// MARK: - PlaylistParser

enum PlaylistParser {
    static func parse(contents: String, format: PlaylistFormat) throws -> [ParsedPlaylistEntry] {
        switch format {
        case .m3u, .m3u8:
            parseM3U(contents)
        case .pls:
            parsePLS(contents)
        case .json:
            try parseJSON(contents)
        }
    }

    static func parseM3U(_ contents: String) -> [ParsedPlaylistEntry] {
        var entries: [ParsedPlaylistEntry] = []
        for (index, line) in numberedLines(contents).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }
            entries.append(ParsedPlaylistEntry(lineNumber: index + 1, rawPath: trimmed))
        }
        return entries
    }

    static func parsePLS(_ contents: String) -> [ParsedPlaylistEntry] {
        var entries: [ParsedPlaylistEntry] = []
        for (index, line) in numberedLines(contents).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let path = fileValue(from: trimmed) else {
                continue
            }
            entries.append(ParsedPlaylistEntry(lineNumber: index + 1, rawPath: path))
        }
        return entries
    }

    /// Returns the value of a PLS `FileN=...` line (key matched case-insensitively),
    /// or `nil` for any other line (`Title`/`Length`/headers/blank).
    static func fileValue(from line: String) -> String? {
        guard let separator = line.firstIndex(of: "=") else {
            return nil
        }
        let key = line[line.startIndex ..< separator].lowercased()
        guard key.hasPrefix("file") else {
            return nil
        }
        let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    static func parseJSON(_ contents: String) throws -> [ParsedPlaylistEntry] {
        let document: JSPFDocument
        do {
            document = try JSONDecoder().decode(JSPFDocument.self, from: Data(contents.utf8))
        } catch {
            throw PlaylistIOError.malformedPlaylist
        }
        var entries: [ParsedPlaylistEntry] = []
        for (index, track) in (document.playlist.track ?? []).enumerated() {
            guard let location = track.location?.first(where: { !$0.isEmpty }) else {
                continue
            }
            entries.append(ParsedPlaylistEntry(lineNumber: index + 1, rawPath: locationPath(location)))
        }
        return entries
    }

    static func locationPath(_ location: String) -> String {
        guard location.hasPrefix("file://") else {
            return location
        }
        return URL(string: location)?.path ?? location
    }

    /// Splits on `\n` after normalizing CRLF, so line numbers track the source file
    /// exactly (a Windows `\r\n` counts as one line, not two).
    private static func numberedLines(_ contents: String) -> [String] {
        contents.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    }
}

// MARK: - PlaylistRenderRow

struct PlaylistRenderRow: Equatable {
    let path: String
    let title: String
    let durationSeconds: Double?
}

// MARK: - PlaylistRenderer

enum PlaylistRenderer {
    static func renderM3U(_ rows: [PlaylistRenderRow]) -> String {
        var lines = ["#EXTM3U"]
        for row in rows {
            lines.append("#EXTINF:\(seconds(row.durationSeconds)),\(row.title)")
            lines.append(row.path)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func renderPLS(_ rows: [PlaylistRenderRow]) -> String {
        var lines = ["[playlist]"]
        for (index, row) in rows.enumerated() {
            let number = index + 1
            lines.append("File\(number)=\(row.path)")
            lines.append("Title\(number)=\(row.title)")
            lines.append("Length\(number)=\(seconds(row.durationSeconds))")
        }
        lines.append("NumberOfEntries=\(rows.count)")
        lines.append("Version=2")
        return lines.joined(separator: "\n") + "\n"
    }

    private static let macampJSPFVersion = 1

    static func renderJSPF(_ rows: [PlaylistRenderRow]) throws -> String {
        let tracks = rows.map { row in
            JSPFTrack(
                location: [locationURI(row.path)],
                title: row.title,
                duration: milliseconds(row.durationSeconds)
            )
        }
        let document = JSPFDocument(
            playlist: JSPFPlaylist(
                title: nil,
                track: tracks,
                extension: JSPFExtension(macampVersion: macampJSPFVersion)
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(document)
        guard let json = String(bytes: data, encoding: .utf8) else {
            throw PlaylistIOError.malformedPlaylist
        }
        return json.hasSuffix("\n") ? json : json + "\n"
    }

    static func locationURI(_ path: String) -> String {
        guard path.hasPrefix("/") else {
            return path
        }
        return URL(fileURLWithPath: path).absoluteString
    }

    private static func milliseconds(_ duration: Double?) -> Int? {
        guard let duration else {
            return nil
        }
        return Int((duration * 1000).rounded())
    }

    private static func seconds(_ duration: Double?) -> Int {
        guard let duration else {
            return -1
        }
        return Int(duration.rounded())
    }
}

// MARK: - JSPF model

private struct JSPFDocument: Codable {
    var playlist: JSPFPlaylist
}

private struct JSPFPlaylist: Codable {
    var title: String?
    var track: [JSPFTrack]?
    var `extension`: JSPFExtension?
}

private struct JSPFTrack: Codable {
    var location: [String]?
    var title: String?
    var duration: Int?
}

private struct JSPFExtension: Codable {
    var macampVersion: Int?

    enum CodingKeys: String, CodingKey {
        case macampVersion = "macamp:version"
    }
}

// MARK: - Path & title resolution

extension PlaylistFileIO {
    /// Resolves a raw playlist path to an absolute, standardized library path:
    /// absolute paths pass through; relative paths resolve against `basePath`.
    static func normalizedPath(_ rawPath: String, basePath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let url: URL
        if trimmed.hasPrefix("/") {
            url = URL(fileURLWithPath: trimmed)
        } else {
            let base = URL(fileURLWithPath: basePath, isDirectory: true)
            url = URL(fileURLWithPath: trimmed, relativeTo: base)
        }
        return url.standardizedFileURL.path
    }

    static func outputPath(
        for absolutePath: String,
        pathStyle: PlaylistPathStyle,
        basePath: String?
    ) -> String {
        switch pathStyle {
        case .absolute:
            return absolutePath
        case .relative:
            guard let basePath else {
                return absolutePath
            }
            return relativePath(for: absolutePath, basePath: basePath)
        }
    }

    static func relativePath(for absolutePath: String, basePath: String) -> String {
        let base = URL(fileURLWithPath: basePath, isDirectory: true).standardizedFileURL.path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard absolutePath.hasPrefix(prefix) else {
            return absolutePath
        }
        return String(absolutePath.dropFirst(prefix.count))
    }

    static func displayTitle(for track: TrackRecord) -> String {
        let title = track.title ?? URL(fileURLWithPath: track.filePath).lastPathComponent
        if let artist = track.artistName, !artist.isEmpty {
            return "\(artist) - \(title)"
        }
        return title
    }
}
