// LibraryToolbox+Tracks — `get_tracks` and `get_track_features`.
//
// ── UNANALYSED IS SAID, NOT ZEROED ────────────────────────────────────────────
//
// `trackAudioFeature` is populated by an opt-in background pass, so most libraries
// have gaps, and `bpm` is nullable even inside an analysed row (ambient material
// legitimately has no reliable beat). Reporting either as `0` would hand a model a
// measurement nobody took — and "energy 0.0" is a claim, not a gap. Both are
// therefore reported in words: "not analysed" for an absent row, "tempo unknown"
// for a null beat.
//
// ── IDS ARE ANSWERED IN THE ORDER THEY WERE ASKED ─────────────────────────────
//
// `resolvedTracks` returns a dictionary. Rows are rebuilt by walking the CALLER's
// id list, so the answer's order is the question's order and two runs over the
// same input render byte-identically.
//
// This file imports Foundation + Persistence; it MUST NOT import AppKit or UIKit
// (PlayerCore portability invariant).
import Foundation
import Persistence

extension LibraryToolbox {
    static func makeGetTracks(_ context: LibraryToolboxContext) -> LibraryTool {
        LibraryTool(
            name: "get_tracks",
            description: "Look up full details for specific tracks by their library ids.",
            parametersSchema: ToolSchema.object([
                .init("track_ids", ToolSchema.integerArray(
                    "Library ids of the tracks to look up.",
                    maxItems: ToolResultBudget.identifierBatchLimit
                )),
            ], required: ["track_ids"]),
            execute: { arguments in
                let ids = try arguments.identifiers(
                    "track_ids",
                    limit: ToolResultBudget.identifierBatchLimit
                )
                return try await trackResult(context, ids: ids)
            }
        )
    }

    static func makeGetTrackFeatures(_ context: LibraryToolboxContext) -> LibraryTool {
        LibraryTool(
            name: "get_track_features",
            description: "Read cached tempo, energy and brightness for specific tracks, saying which are unanalysed.",
            parametersSchema: ToolSchema.object([
                .init("track_ids", ToolSchema.integerArray(
                    "Library ids of the tracks to measure.",
                    maxItems: ToolResultBudget.identifierBatchLimit
                )),
            ], required: ["track_ids"]),
            execute: { arguments in
                let ids = try arguments.identifiers(
                    "track_ids",
                    limit: ToolResultBudget.identifierBatchLimit
                )
                return try await featureResult(context, ids: ids)
            }
        )
    }
}

// MARK: - Bodies

private extension LibraryToolbox {
    static func trackResult(_ context: LibraryToolboxContext, ids: [Int64]) async throws -> ToolResult {
        let resolved = try await ToolboxExecutor.readAsync {
            try await context.tracks.resolvedTracks(profileId: context.profileId, trackIds: ids)
        }
        let rows = ids.compactMap { resolved[$0] }.map { ToolboxRendering.detailedRow($0.track) }
        return ToolResult(
            summary: resolvedSummary(asked: ids.count, found: rows.count),
            rows: rows,
            resultCount: rows.count
        )
    }

    static func featureResult(_ context: LibraryToolboxContext, ids: [Int64]) async throws -> ToolResult {
        let features = try await ToolboxExecutor.readAsync {
            try await context.reader.audioFeatures(trackIds: ids)
        }
        let resolved = try await ToolboxExecutor.readAsync {
            try await context.tracks.resolvedTracks(profileId: context.profileId, trackIds: ids)
        }
        let rows = ids.map { trackId in
            featureRow(trackId: trackId, track: resolved[trackId]?.track, feature: features[trackId])
        }
        let analysed = features.count
        return ToolResult(
            summary: "\(analysed) of \(ids.count) requested \(ids.count == 1 ? "track is" : "tracks are") analysed.",
            rows: rows,
            resultCount: rows.count
        )
    }

    static func resolvedSummary(asked: Int, found: Int) -> String {
        guard found < asked else {
            return "\(found) \(found == 1 ? "track" : "tracks")."
        }
        let missing = asked - found
        return "\(found) of \(asked) tracks found; \(missing) unknown to this listener's library."
    }

    static func featureRow(
        trackId: Int64,
        track: TrackRecord?,
        feature: TrackAudioFeatureRecord?
    ) -> ToolResultRow {
        let name = track.map { ToolboxRendering.compactLine($0) } ?? "#\(trackId) (unknown track)"
        guard let feature else {
            return ToolResultRow(text: "\(name) — not analysed", payload: featurePayload(trackId: trackId))
        }
        let tempo = feature.bpm.map { "tempo \(ToolboxRendering.measure($0, decimals: 0)) bpm" } ?? "tempo unknown"
        let facets = [
            tempo,
            "energy \(ToolboxRendering.measure(feature.energy))",
            "brightness \(ToolboxRendering.measure(feature.brightness))",
        ]
        return ToolResultRow(
            text: "\(name) — " + facets.joined(separator: ToolboxRendering.separator),
            payload: featurePayload(trackId: trackId, feature: feature)
        )
    }

    static func featurePayload(trackId: Int64, feature: TrackAudioFeatureRecord? = nil) -> ToolboxJSON {
        guard let feature else {
            return .object(["id": .int(trackId), "analysed": .bool(false)])
        }
        return .object([
            "id": .int(trackId),
            "analysed": .bool(true),
            "bpm": feature.bpm.map { ToolboxJSON.number($0) } ?? .null,
            "energy": .number(feature.energy),
            "brightness": .number(feature.brightness),
        ])
    }
}
