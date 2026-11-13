// LibraryToolbox+Match — `match_tracks`.
//
// ── WHY A BATCH TOOL RATHER THAN N CALLS TO `search_tracks` ───────────────────
//
// A model handed a tracklist ("here are the twenty songs from that radio show")
// otherwise spends twenty round trips resolving it, and each one costs a full
// turn of context. One call resolves the whole list, and the answer states which
// of the requested tracks the library does NOT have — the fact a per-track search
// can only convey as twenty separate empty results the model has to correlate
// itself.
//
// ── A MISS IS A ROW, NOT AN OMISSION ──────────────────────────────────────────
//
// Every requested pair is answered. A pair with no match renders as its own
// `no match:` row carrying `{"kind":"miss"}`, because a model that cannot tell
// "absent from your library" from "I dropped it" will re-ask for it — and, worse,
// may propose a playlist entry for a track that does not exist.
//
// This file imports Foundation + Persistence; it MUST NOT import AppKit or UIKit
// (PlayerCore portability invariant).
import Foundation
import Persistence

/// One `{title, artist}` the caller asked to be resolved.
struct ToolboxMatchPair: Equatable {
    let title: String
    let artist: String?

    /// The FTS query this pair searches with: every token of both fields, since
    /// `searchTracks` prefix-matches ALL of them and the artist is the strongest
    /// disambiguator a tracklist carries.
    var query: String {
        [title, artist].compactMap(\.self).joined(separator: " ")
    }
}

extension LibraryToolbox {
    /// The most rows one pair may claim. Above three, a batch of a hundred pairs
    /// could not fit any tier's row budget and the answer would be truncation.
    static let maximumMatchesPerPair = 3

    static func makeMatchTracks(_ context: LibraryToolboxContext) -> LibraryTool {
        LibraryTool(
            name: "match_tracks",
            description: "Match a batch of title and artist pairs against the listener's library in one call.",
            parametersSchema: matchSchema,
            execute: { arguments in
                let pairs = try matchPairs(from: arguments)
                let limitPerPair = try arguments.optionalInteger(
                    "limit_per_pair",
                    lower: 1,
                    upper: maximumMatchesPerPair
                ) ?? 1
                return try await matchResult(context, pairs: pairs, limitPerPair: limitPerPair)
            }
        )
    }

    static var matchSchema: ToolboxJSON {
        ToolSchema.object([
            .init("pairs", ToolSchema.objectArray(
                "The tracks to look for, one entry per requested track.",
                properties: [
                    .init("title", ToolSchema.string("The track title to look for.")),
                    .init("artist", ToolSchema.string("The performing artist, when it is known.")),
                ],
                required: ["title"],
                maxItems: ToolResultBudget.identifierBatchLimit
            )),
            .init("limit_per_pair", ToolSchema.integer(
                "Matches to return for each pair.",
                minimum: 1,
                maximum: maximumMatchesPerPair
            )),
        ], required: ["pairs"])
    }
}

// MARK: - Body

private extension LibraryToolbox {
    static func matchPairs(from arguments: ToolArguments) throws -> [ToolboxMatchPair] {
        try arguments
            .objectArray("pairs", limit: ToolResultBudget.identifierBatchLimit)
            .map { try ToolboxMatchPair(title: $0.string("title"), artist: $0.optionalString("artist")) }
    }

    /// One off-main hop for the WHOLE batch: a hundred pairs are a hundred `MATCH`
    /// queries, and paying a `Task.detached` for each would cost more in hops than
    /// in SQLite.
    static func matchResult(
        _ context: LibraryToolboxContext,
        pairs: [ToolboxMatchPair],
        limitPerPair: Int
    ) async throws -> ToolResult {
        let repository = context.tracks
        let profileId = context.profileId
        let found = try await ToolboxExecutor.read {
            try pairs.map { pair in
                try repository.searchTracks(profileId: profileId, query: pair.query, limit: limitPerPair)
            }
        }
        return assembled(pairs: pairs, found: found)
    }

    static func assembled(pairs: [ToolboxMatchPair], found: [[TrackRecord]]) -> ToolResult {
        var matchRows: [ToolResultRow] = []
        var missRows: [ToolResultRow] = []
        var matchedPairs = 0
        for (pair, records) in zip(pairs, found) {
            guard !records.isEmpty else {
                missRows.append(missRow(pair))
                continue
            }
            matchedPairs += 1
            matchRows.append(contentsOf: records.map { ToolboxRendering.compactRow($0) })
        }
        return ToolResult(
            summary: "Matched \(matchedPairs) of \(pairs.count) requested tracks.",
            rows: matchRows + missRows,
            resultCount: matchRows.count
        )
    }

    static func missRow(_ pair: ToolboxMatchPair) -> ToolResultRow {
        let named = [pair.title, pair.artist].compactMap(\.self).joined(separator: " — ")
        return ToolResultRow(
            text: "no match: \(named)",
            payload: .object([
                "kind": .string("miss"),
                "title": .string(pair.title),
                "artist": pair.artist.map { ToolboxJSON.string($0) } ?? .null,
            ])
        )
    }
}
