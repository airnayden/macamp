// LibraryToolbox+Sample — `sample_tracks`.
//
// ── "RANDOM-ISH" MEANS SEEDED, AND THE SEED IS AN ARGUMENT ────────────────────
//
// A genuinely random sample cannot be tested and cannot be reproduced when a
// listener asks "why did it pick those?". So the candidate ids come back from the
// database in a deterministic `(sortTitle, id)` order and are then shuffled with a
// SEEDED Fisher–Yates. Same seed, same library, same answer. The default seed is
// `0`, which makes an un-parameterised call reproducible too; a model that wants a
// different draw passes a different seed rather than calling again and hoping.
//
// ``SplitMix64`` is eight lines rather than a reuse of `Visualizer`'s
// `SeededGenerator`: `Services` does not depend on `Visualizer`, and adding that
// edge — from the layer that owns playback to the layer that draws pictures — to
// borrow a PRNG would be exactly backwards.
//
// ── WHAT THE FILTER CAN AND CANNOT PROMISE ────────────────────────────────────
//
// The narrowing is `SmartPlaylistCompiler`'s, reused unmodified (see
// ``ToolboxLibraryReader``). Two inherited properties the description states out
// loud so a model is not surprised: an UNANALYSED track is never excluded by a
// tempo or energy bound, and only `present` tracks are ever sampled.
//
// This file imports only Foundation; it MUST NOT import AppKit or UIKit
// (PlayerCore portability invariant).
import Foundation

extension LibraryToolbox {
    /// Tracks a sample returns when the caller states no `limit`.
    static let defaultSampleLimit = 20

    /// The largest sample a single call may ask for. Below
    /// ``ToolResultBudget/identifierBatchLimit`` so the resolve that follows is
    /// always a single batch.
    static let maximumSampleLimit = 50

    static func makeSampleTracks(_ context: LibraryToolboxContext) -> LibraryTool {
        LibraryTool(
            name: "sample_tracks",
            description: "Draw a varied sample of playable tracks matching optional genre, year, tempo and energy bounds.",
            parametersSchema: sampleSchema,
            execute: { arguments in
                let filter = try sampleFilter(from: arguments)
                let limit = try arguments.optionalInteger(
                    "limit",
                    lower: 1,
                    upper: maximumSampleLimit
                ) ?? defaultSampleLimit
                let seed = try arguments.optionalInteger("seed", lower: 0, upper: Int.max) ?? 0
                return try await sampleResult(context, filter: filter, limit: limit, seed: UInt64(seed))
            }
        )
    }

    static var sampleSchema: ToolboxJSON {
        ToolSchema.object([
            .init("genre", ToolSchema.string("Exact genre to match, case-insensitively. Use list_genres first.")),
            .init("year_min", ToolSchema.integer("Earliest release year, inclusive.")),
            .init("year_max", ToolSchema.integer("Latest release year, inclusive.")),
            .init("tempo_min", ToolSchema.number("Slowest tempo in bpm. Unanalysed tracks are not excluded.")),
            .init("tempo_max", ToolSchema.number("Fastest tempo in bpm. Unanalysed tracks are not excluded.")),
            .init("energy_min", ToolSchema.number("Lowest energy, 0 to 1.", minimum: 0, maximum: 1)),
            .init("energy_max", ToolSchema.number("Highest energy, 0 to 1.", minimum: 0, maximum: 1)),
            .init("limit", ToolSchema.integer("Tracks to draw.", minimum: 1, maximum: maximumSampleLimit)),
            .init("seed", ToolSchema.integer("Shuffle seed. The same seed always draws the same sample.", minimum: 0)),
        ], required: [])
    }
}

// MARK: - Body

private extension LibraryToolbox {
    /// Year bounds are unbounded integers on purpose — a library legitimately holds
    /// 1928 recordings, and a hard floor would be a guess about the collection.
    static func sampleFilter(from arguments: ToolArguments) throws -> ToolboxSampleFilter {
        try ToolboxSampleFilter(
            genre: arguments.optionalString("genre"),
            minimumYear: arguments.optionalInteger("year_min", lower: 0, upper: Int.max),
            maximumYear: arguments.optionalInteger("year_max", lower: 0, upper: Int.max),
            minimumTempo: arguments.optionalNumber("tempo_min", lower: 0, upper: 400),
            maximumTempo: arguments.optionalNumber("tempo_max", lower: 0, upper: 400),
            minimumEnergy: arguments.optionalNumber("energy_min", lower: 0, upper: 1),
            maximumEnergy: arguments.optionalNumber("energy_max", lower: 0, upper: 1)
        )
    }

    static func sampleResult(
        _ context: LibraryToolboxContext,
        filter: ToolboxSampleFilter,
        limit: Int,
        seed: UInt64
    ) async throws -> ToolResult {
        let candidates = try await ToolboxExecutor.readAsync {
            try await context.reader.sampleTrackIds(
                profileId: context.profileId,
                filter: filter,
                limit: ToolResultBudget.fetchLimit,
                now: context.now()
            )
        }
        guard !candidates.isEmpty else {
            return ToolResult(summary: "No playable tracks match those bounds.", resultCount: 0)
        }
        let drawn = Array(ToolboxSampling.shuffled(candidates, seed: seed).prefix(limit))
        let resolved = try await ToolboxExecutor.readAsync {
            try await context.tracks.resolvedTracks(profileId: context.profileId, trackIds: drawn)
        }
        let rows = drawn.compactMap { resolved[$0] }.map { ToolboxRendering.compactRow($0.track) }
        return ToolResult(
            summary: "\(rows.count) of \(candidates.count) matching tracks, sampled with seed \(seed).",
            rows: rows,
            resultCount: rows.count
        )
    }
}

// MARK: - Seeded shuffle

/// A reproducible draw. See the file header for why this is not `SeededGenerator`.
enum ToolboxSampling {
    /// Fisher–Yates over a SplitMix64 stream.
    ///
    /// The stream is advanced once per swap, so the permutation is a pure function
    /// of `(seed, count)` — which is what makes the sample assertable.
    static func shuffled(_ values: [Int64], seed: UInt64) -> [Int64] {
        guard values.count > 1 else { return values }
        var state = seed
        var shuffled = values
        for index in stride(from: shuffled.count - 1, to: 0, by: -1) {
            let pick = Int(next(&state) % UInt64(index + 1))
            shuffled.swapAt(index, pick)
        }
        return shuffled
    }

    /// SplitMix64 — the standard constants; a fixed-point mixing function, not a
    /// magic number soup, so they are quoted rather than derived.
    static func next(_ state: inout UInt64) -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}
