// LibraryToolbox+Playlists — `list_playlists` and `get_playlist`.
//
// ── OWNERSHIP IS CHECKED, NOT ASSUMED ─────────────────────────────────────────
//
// `playlistTracksPage` takes a playlist id and no profile: it is a membership read
// on a row the caller already proved it may see. Nothing proves that here, because
// the id came from a MODEL. So `get_playlist` fetches the row first and refuses
// unless `playlist.profileId` is this profile — and refuses with ``notFound``
// rather than a "not yours", so a probing caller cannot use the tool to discover
// that another profile's playlist exists.
//
// A `NULL` `profileId` reads as Guest, matching the `v12` FK ADD COLUMN's own
// backfill.
//
// ── AND WHY THE READ OBSERVER FIRES WHERE IT DOES ─────────────────────────────
//
// ``LibraryToolboxContext/playlistReadObserver`` is told the served id from inside
// `playlistResult`, which is the only place the fact is exact — the answer itself
// carries track rows, never the playlist's id, so any caller downstream would be
// inferring it from prose a model wrote.
//
// The call sits AFTER `ownedPlaylist` has already succeeded, so the `notFound`
// refusal above keeps its whole point: a probing caller must not be able to learn
// through a side channel that another profile's playlist exists. It also sits
// OUTSIDE ``ToolboxExecutor/readAsync(_:)``, whose `do`/`catch` would otherwise be
// in a position to swallow it, and the requirement neither throws nor answers — so
// the ``ToolResult`` below is byte-identical whether or not anyone is watching.
//
// This file imports Foundation + Persistence; it MUST NOT import AppKit or UIKit
// (PlayerCore portability invariant).
import Foundation
import Persistence

extension LibraryToolbox {
    /// Membership rows one `get_playlist` call returns when none is stated.
    static let defaultPlaylistPageLimit = 50

    static func makeListPlaylists(_ context: LibraryToolboxContext) -> LibraryTool {
        LibraryTool(
            name: "list_playlists",
            description: "List this listener's playlists with their track counts.",
            parametersSchema: ToolSchema.noArguments,
            execute: { _ in try await playlistListResult(context) }
        )
    }

    static func makeGetPlaylist(_ context: LibraryToolboxContext) -> LibraryTool {
        LibraryTool(
            name: "get_playlist",
            description: "Read one playlist's tracks, in playing order.",
            parametersSchema: ToolSchema.object([
                .init("playlist_id", ToolSchema.integer("Library id of the playlist.", minimum: 1)),
                .init("limit", ToolSchema.integer(
                    "Maximum tracks to return.",
                    minimum: 1,
                    maximum: ToolResultBudget.fetchLimit
                )),
            ], required: ["playlist_id"]),
            execute: { arguments in
                let playlistId = try arguments.integer("playlist_id", lower: 1, upper: Int.max)
                let limit = try arguments.optionalInteger(
                    "limit",
                    lower: 1,
                    upper: ToolResultBudget.fetchLimit
                ) ?? defaultPlaylistPageLimit
                return try await playlistResult(context, playlistId: Int64(playlistId), limit: limit)
            }
        )
    }
}

// MARK: - Bodies

private extension LibraryToolbox {
    static func playlistListResult(_ context: LibraryToolboxContext) async throws -> ToolResult {
        let page = try await ToolboxExecutor.readAsync {
            try await context.playlists.playlistsWithTrackCounts(
                profileId: context.profileId,
                after: nil,
                limit: ToolResultBudget.fetchLimit
            )
        }
        guard !page.items.isEmpty else {
            return ToolResult(summary: "This listener has no playlists yet.", resultCount: 0)
        }
        return ToolResult(
            summary: "\(page.items.count) \(page.items.count == 1 ? "playlist" : "playlists").",
            rows: page.items.map(playlistRow),
            resultCount: page.items.count
        )
    }

    static func playlistResult(
        _ context: LibraryToolboxContext,
        playlistId: Int64,
        limit: Int
    ) async throws -> ToolResult {
        let record = try await ownedPlaylist(context, playlistId: playlistId)
        let page = try await ToolboxExecutor.readAsync {
            try await context.playlists.playlistTracksPage(
                playlistId: playlistId,
                after: nil,
                limit: limit
            )
        }
        let rows = page.items.map { ToolboxRendering.compactRow($0.track) }
        let count = rows.count
        await context.playlistReadObserver?.playlistWasRead(id: playlistId, profileId: context.profileId)
        return ToolResult(
            summary: "\"\(record.name)\" — \(count) \(count == 1 ? "track" : "tracks").",
            rows: rows,
            resultCount: count
        )
    }

    /// The playlist, or ``LibraryToolError/notFound(what:id:)``. See the file header.
    static func ownedPlaylist(
        _ context: LibraryToolboxContext,
        playlistId: Int64
    ) async throws -> PlaylistRecord {
        let repository = context.playlists
        let record = try await ToolboxExecutor.read {
            try repository.fetchPlaylist(id: playlistId)
        }
        guard let record, (record.profileId ?? ProfileRecord.guestID) == context.profileId else {
            throw LibraryToolError.notFound(what: "playlist", id: playlistId)
        }
        return record
    }

    static func playlistRow(_ item: PlaylistWithTrackCount) -> ToolResultRow {
        let identifier = item.playlist.id ?? 0
        let count = item.trackCount
        return ToolResultRow(
            text: "#\(identifier) \(item.playlist.name) — \(count) \(count == 1 ? "track" : "tracks")",
            payload: .object([
                "id": .int(identifier),
                "name": .string(item.playlist.name),
                "trackCount": .int(count),
            ])
        )
    }
}
