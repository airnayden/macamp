// LibraryToolbox+Stats — `get_listening_stats`.
//
// ── THE DIGEST IS THE ONLY SOURCE, AND IT CARRIES NO ROW IDS ──────────────────
//
// Everything here comes from ``ListeningDigestBuilding``, which reads `playEvent`,
// `playEventRollup` and `playSegmentHeat` and NEVER joins `track` or `playlist`.
// So a stats answer names a track by its captured `(artist, title, album)` text
// and cannot name a library id at all — which is why these rows carry no `id`
// field while every other tool's do. That is the digest's survivability rule
// showing through, not an omission: the history outlives the rows.
//
// ── FOUR WINDOWS, NAMED THE WAY A MODEL WOULD SAY THEM ────────────────────────
//
// The argument vocabulary is `7d` / `30d` / `12m` / `all` rather than the Swift
// case names, because it is a closed `enum` in the published schema and a model
// reproduces a short token far more reliably than `last12Months`.
//
// This file imports only Foundation; it MUST NOT import AppKit or UIKit
// (PlayerCore portability invariant).
import Foundation

extension LibraryToolbox {
    /// The wire vocabulary for the `window` argument, in the order the schema
    /// publishes it.
    static let statsWindowNames = ["7d", "30d", "12m", "all"]

    /// The window a caller that states none gets — long enough to have shape,
    /// short enough to describe what the listener is into NOW.
    static let defaultStatsWindow = "30d"

    static func makeGetListeningStats(_ context: LibraryToolboxContext) -> LibraryTool {
        LibraryTool(
            name: "get_listening_stats",
            description: "Summarise what this listener actually played, with their top tracks, artists and genres.",
            parametersSchema: ToolSchema.object([
                .init("window", ToolSchema.string(
                    "Time span to summarise: 7d, 30d, 12m or all.",
                    allowed: statsWindowNames
                )),
            ], required: []),
            execute: { arguments in
                let name = try arguments.optionalEnumValue("window", allowed: statsWindowNames)
                    ?? defaultStatsWindow
                return try await statsResult(context, windowName: name)
            }
        )
    }

    /// Maps the wire token onto the digest's own enum. Total by construction —
    /// ``statsWindowNames`` and this switch are the same four tokens, and the
    /// argument accessor rejects anything else before it reaches here.
    static func statsWindow(_ name: String) -> ListeningWindowKind {
        switch name {
        case "7d": .last7Days
        case "12m": .last12Months
        case "all": .allTime
        default: .last30Days
        }
    }
}

// MARK: - Body

private extension LibraryToolbox {
    static func statsResult(_ context: LibraryToolboxContext, windowName: String) async throws -> ToolResult {
        let digest = try await ToolboxExecutor.readAsync {
            try await context.digests.buildDigest(profileId: context.profileId)
        }
        guard let window = digest.window(statsWindow(windowName)), window.totalPlays > 0 else {
            return ToolResult(summary: "No listening history recorded for \(windowName).")
        }
        return ToolResult(summary: headline(window, windowName: windowName), rows: facetRows(window))
    }

    static func headline(_ window: ListeningWindowDigest, windowName: String) -> String {
        let hours = window.totalListenedSeconds / 3600
        let skipPercent = Int((window.skipRate * 100).rounded())
        return "\(windowName): \(window.totalPlays) plays, "
            + "\(ToolboxRendering.measure(hours, decimals: 1)) hours listened, "
            + "\(skipPercent)% skipped."
    }

    /// Top tracks, then artists, then genres — each already totally ordered by the
    /// digest, so the rendered block is stable run to run.
    static func facetRows(_ window: ListeningWindowDigest) -> [ToolResultRow] {
        let limit = ToolResultBudget.statsFacetLimit
        var rows = window.topTracks.prefix(limit).map(trackRow)
        rows += window.topArtists.prefix(limit).map { nameRow($0, label: "Top artist") }
        rows += window.topGenres.prefix(limit).map { nameRow($0, label: "Top genre") }
        return rows
    }

    static func trackRow(_ stat: ListeningTrackStat) -> ToolResultRow {
        var name = stat.track.title ?? "(untitled)"
        if let artist = stat.track.artistName, !artist.isEmpty {
            name += " — \(artist)"
        }
        return ToolResultRow(
            text: "Top track: \(name) (\(stat.plays) \(stat.plays == 1 ? "play" : "plays"))",
            payload: .object([
                "kind": .string("track"),
                "title": stat.track.title.map { ToolboxJSON.string($0) } ?? .null,
                "artist": stat.track.artistName.map { ToolboxJSON.string($0) } ?? .null,
                "album": stat.track.albumTitle.map { ToolboxJSON.string($0) } ?? .null,
                "plays": .int(stat.plays),
            ])
        )
    }

    /// An artist or genre the listener never tagged arrives as `""` — the same
    /// empty-name sentinel `playEventRollup` groups on. Named, not hidden.
    static func nameRow(_ stat: ListeningNameStat, label: String) -> ToolResultRow {
        let shown = stat.name.isEmpty ? "(unknown)" : stat.name
        return ToolResultRow(
            text: "\(label): \(shown) (\(stat.plays) \(stat.plays == 1 ? "play" : "plays"))",
            payload: .object([
                "kind": .string(label == "Top genre" ? "genre" : "artist"),
                "name": stat.name.isEmpty ? .null : .string(stat.name),
                "plays": .int(stat.plays),
            ])
        )
    }
}
