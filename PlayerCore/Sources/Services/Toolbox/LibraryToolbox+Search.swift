// LibraryToolbox+Search — `search_tracks` and `list_genres`.
//
// Both are in the `.onDevice` five. `list_genres` is there because a small model
// asked for "something jazzy" will otherwise INVENT a genre string, and an exact
// `= ? COLLATE NOCASE` match against an invented spelling returns nothing; giving
// it the library's own vocabulary first turns a guess into a lookup.
//
// This file imports only Foundation; it MUST NOT import AppKit or UIKit
// (PlayerCore portability invariant).
import Foundation

extension LibraryToolbox {
    /// Tracks returned when the caller states no `limit`. Well under the
    /// `.onDevice` row budget, so the common call renders whole.
    static let defaultSearchLimit = 20

    /// Characters of the caller's own query echoed back in the summary. Bounded
    /// because the query is model-supplied and would otherwise be free rein over
    /// the result budget.
    static let echoedQueryLimit = 40

    static func makeSearchTracks(_ context: LibraryToolboxContext) -> LibraryTool {
        LibraryTool(
            name: "search_tracks",
            description: "Search the listener's library by title, artist or album and return matching tracks.",
            parametersSchema: ToolSchema.object([
                .init("query", ToolSchema.string(
                    "Words to match. Each word prefix-matches a title, artist or album token."
                )),
                .init("limit", ToolSchema.integer(
                    "Maximum tracks to return.",
                    minimum: 1,
                    maximum: ToolResultBudget.fetchLimit
                )),
            ], required: ["query"]),
            execute: { arguments in
                let query = try arguments.string("query")
                let limit = try arguments.optionalInteger(
                    "limit",
                    lower: 1,
                    upper: ToolResultBudget.fetchLimit
                ) ?? defaultSearchLimit
                return try await searchResult(context, query: query, limit: limit)
            }
        )
    }

    static func makeListGenres(_ context: LibraryToolboxContext) -> LibraryTool {
        LibraryTool(
            name: "list_genres",
            description: "List the genres present in the listener's library with a track count for each.",
            parametersSchema: ToolSchema.noArguments,
            execute: { _ in try await genreResult(context) }
        )
    }
}

// MARK: - Bodies

private extension LibraryToolbox {
    static func searchResult(
        _ context: LibraryToolboxContext,
        query: String,
        limit: Int
    ) async throws -> ToolResult {
        let repository = context.tracks
        let profileId = context.profileId
        let records = try await ToolboxExecutor.read {
            try repository.searchTracks(profileId: profileId, query: query, limit: limit)
        }
        let echoed = ToolResult.elide(query, limit: echoedQueryLimit)
        guard !records.isEmpty else {
            return ToolResult(summary: "No tracks match \"\(echoed)\".", resultCount: 0)
        }
        return ToolResult(
            summary: "\(records.count) \(records.count == 1 ? "track" : "tracks") matching \"\(echoed)\".",
            rows: records.map { ToolboxRendering.compactRow($0) },
            resultCount: records.count
        )
    }

    static func genreResult(_ context: LibraryToolboxContext) async throws -> ToolResult {
        let counts = try await ToolboxExecutor.readAsync {
            try await context.reader.genreCounts(
                profileId: context.profileId,
                limit: ToolResultBudget.fetchLimit
            )
        }
        guard !counts.isEmpty else {
            return ToolResult(summary: "This listener's library has no tracks yet.", resultCount: 0)
        }
        let named = counts.count(where: { !$0.name.isEmpty })
        return ToolResult(
            summary: "\(named) \(named == 1 ? "genre" : "genres") in this listener's library.",
            rows: counts.map(genreRow),
            resultCount: counts.count
        )
    }

    /// The untagged bucket is named rather than hidden: "42 tracks have no genre"
    /// is exactly the fact that stops a model proposing a genre filter that would
    /// silently drop them.
    static func genreRow(_ count: ToolboxGenreCount) -> ToolResultRow {
        let label = count.name.isEmpty ? "(no genre)" : count.name
        return ToolResultRow(
            text: "\(label) — \(count.trackCount) \(count.trackCount == 1 ? "track" : "tracks")",
            payload: .object([
                "genre": count.name.isEmpty ? .null : .string(count.name),
                "trackCount": .int(count.trackCount),
            ])
        )
    }
}
