// LibraryToolbox+Propose — `propose_playlist`, the only write-adjacent tool.
//
// ── IT FILES. IT DOES NOT WRITE. ──────────────────────────────────────────────
//
// This is the tool-layer restatement of the rule `AIProposal` already enforces by
// API shape: nothing an AI produces reaches disk without an explicit
// `apply(_:confirmedBatch:)` the listener triggered. ``ToolboxProposalFiling`` is
// deliberately the ONLY seam in ``LibraryToolboxContext`` that is not a read, and
// it cannot reach a repository — the composition root conforms it over the
// proposal store, which is itself inert.
//
// The returned text says so in words ("Nothing has been saved yet"), because a
// model that believed it had already created the playlist would go on to tell the
// listener it had.
//
// ── THE PROPOSAL ID IS PART OF THE ANSWER ─────────────────────────────────────
//
// Reported so a follow-up turn can refer to the offer the listener is looking at
// without re-describing it. It is a UUID, matching `AIProposal.id`, so the shell's
// conformer is a pass-through rather than a mapping table.
//
// ── A SHORTFALL IS ECHOED, NOT REFUSED ────────────────────────────────────────
//
// `target_count` is the total the listener asked for, and it is OPTIONAL: a model
// that was never given a number must not be forced to invent one. When it IS
// given and disagrees with the membership, the summary states both figures and
// asks for a second attempt — it does not throw. A small model routinely files
// eight tracks for a "twenty songs" request and has no way to notice, because
// nothing in the answer told it what it had promised; a refusal, meanwhile, would
// throw away a proposal that may well be the best the library can do. Stating the
// gap lets the model either extend the offer or explain the shortfall, which is
// the same self-correction ``ToolArgumentError/message`` is written for.
//
// ── THE MEMBERSHIP CAN BE NAMED, OR IT CAN BE DESCRIBED ──────────────────────
//
// A small on-device model cannot emit five hundred track ids: they do not fit in
// the window, and a list it half-remembers is worse than no list. So `track_ids`
// is OPTIONAL, and a caller may instead state a `genre` and a `target_count` and
// let the APP pick — the same `SmartPlaylistCompiler` read `sample_tracks`
// already uses, so criteria proposals are title-ordered (`(sortTitle, id)`) and
// present-only, and the same call twice files the same ids.
//
// This does NOT widen what the tool can do. It still only FILES; the review gate
// is unchanged; and the materialiser is a read that already had to be
// profile-scoped. What changes is who assembles the list.
//
// Keyword criteria are deliberately absent. They were measured against the
// on-device prefix budget and did not fit (see the todo-2 spike), so genre is the
// only criterion at every tier — a schema shared by three adapters cannot carry a
// field only two of them can afford.
//
// This file imports only Foundation; it MUST NOT import AppKit, UIKit or
// `ViewModels` (PlayerCore portability + layering invariants).
import Foundation

extension LibraryToolbox {
    /// Characters of a model-supplied playlist name echoed into the summary.
    static let echoedNameLimit = 60

    static func makeProposePlaylist(_ context: LibraryToolboxContext) -> LibraryTool {
        LibraryTool(
            name: "propose_playlist",
            description: "Offer a new playlist to the listener for review. Saves nothing by itself.",
            parametersSchema: proposalSchema,
            execute: { arguments in
                try await proposeResult(context, request: ProposalRequest(arguments))
            }
        )
    }

    static var proposalSchema: ToolboxJSON {
        ToolSchema.object([
            .init("name", ToolSchema.string("Name for the proposed playlist, in the listener's language.")),
            .init("track_ids", ToolSchema.integerArray(
                "Library ids to include, in playing order. Omit to pick by genre instead.",
                maxItems: ToolResultBudget.proposalIdentifierLimit
            )),
            .init("genre", ToolSchema.string(
                "Exact genre to fill the playlist from when no track_ids are given. Use list_genres first."
            )),
            .init("target_count", ToolSchema.integer(
                "Total tracks the listener asked for.",
                minimum: 1,
                maximum: ToolResultBudget.proposalIdentifierLimit
            )),
            .init("description", ToolSchema.string("One line explaining the selection.")),
        ], required: ["name"])
    }
}

// MARK: - The decoded call

/// One `propose_playlist` call: a name, and either an explicit membership or the
/// criteria to build one from.
///
/// A value type rather than five more parameters — `proposeResult` was already at
/// SwiftLint's `function_parameter_count` ceiling before `genre` existed.
private struct ProposalRequest {
    let name: String
    let trackIds: [Int64]?
    let genre: String?
    let targetCount: Int?
    let summary: String?

    init(_ arguments: ToolArguments) throws {
        name = try arguments.string("name")
        trackIds = try arguments.optionalIdentifiers(
            "track_ids",
            limit: ToolResultBudget.proposalIdentifierLimit
        )
        genre = try arguments.optionalString("genre")
        targetCount = try arguments.optionalInteger(
            "target_count",
            lower: 1,
            upper: ToolResultBudget.proposalIdentifierLimit
        )
        summary = try arguments.optionalString("description")
    }

    /// How many tracks a materialised membership may reach.
    ///
    /// The caller's own figure, NOT ``ToolResultBudget/fetchLimit`` — a proposal is
    /// reviewed rather than read back to the model, so the 200-row render bound
    /// does not apply and a 500-track ask must reach the materialiser intact. The
    /// ceiling is ``ToolResultBudget/proposalIdentifierLimit``, which lands exactly
    /// on `SmartPlaylistRules.maximumLimit`, so nothing is clamped on the way down.
    var materialisationLimit: Int {
        min(targetCount ?? LibraryToolbox.defaultSearchLimit, ToolResultBudget.proposalIdentifierLimit)
    }
}

// MARK: - Body

private extension LibraryToolbox {
    /// The correction a model reads when it filed fewer tracks than were asked for.
    ///
    /// Model-facing English, deliberately not a `LocalizedStringResource`: it is
    /// protocol payload on the same footing as ``ToolArgumentError/message``, and a
    /// shell that rendered it to a person verbatim would have a bug.
    static func shortfallSentence(asked: Int, filed: Int) -> String {
        "The listener asked for \(asked) tracks but this proposal has \(filed). "
            + "Add more tracks and propose again, or tell the listener why not."
    }

    /// The sentence a criteria call gets when the library holds nothing matching.
    ///
    /// Nothing is filed: an empty playlist is not an offer, and the listener would
    /// have to reject it by hand. Naming `list_genres` turns the dead end into the
    /// next call, which is the same self-correction a refusal message is for.
    static func noMatchSentence(genre: String) -> String {
        let echoed = ToolResult.elide(genre, limit: echoedNameLimit)
        return "No playable tracks are tagged \"\(echoed)\". "
            + "Call list_genres for this library's own spellings."
    }

    static func proposeResult(
        _ context: LibraryToolboxContext,
        request: ProposalRequest
    ) async throws -> ToolResult {
        if let named = request.trackIds {
            return try await fileProposal(context, request: request, trackIds: named)
        }
        guard let genre = request.genre else {
            throw ToolArgumentError.missingAny(arguments: ["track_ids", "genre"])
        }
        let materialised = try await ToolboxExecutor.readAsync {
            try await context.reader.sampleTrackIds(
                profileId: context.profileId,
                filter: ToolboxSampleFilter(genre: genre),
                limit: request.materialisationLimit,
                now: context.now()
            )
        }
        guard !materialised.isEmpty else {
            return ToolResult(summary: noMatchSentence(genre: genre), resultCount: 0)
        }
        return try await fileProposal(context, request: request, trackIds: materialised)
    }

    static func fileProposal(
        _ context: LibraryToolboxContext,
        request: ProposalRequest,
        trackIds: [Int64]
    ) async throws -> ToolResult {
        let name = request.name
        let proposal = ToolboxPlaylistProposal(
            profileId: context.profileId,
            name: name,
            trackIds: trackIds,
            summary: request.summary
        )
        let filer = context.proposals
        let identifier: UUID
        do {
            identifier = try await filer.fileCreatePlaylistProposal(proposal)
        } catch {
            throw LibraryToolError.proposalFailed(reason: "\(error)")
        }
        let echoed = ToolResult.elide(name, limit: echoedNameLimit)
        let count = trackIds.count
        let filed = "Filed \"\(echoed)\" (\(count) \(count == 1 ? "track" : "tracks")) "
            + "for the listener to review. Nothing has been saved yet."
        let shortfall = request.targetCount.flatMap {
            $0 == count ? nil : shortfallSentence(asked: $0, filed: count)
        }
        return ToolResult(
            summary: [filed, shortfall].compactMap(\.self).joined(separator: " "),
            rows: [ToolResultRow(
                text: "proposal_id \(identifier.uuidString)",
                payload: .object([
                    "proposalId": .string(identifier.uuidString),
                    "name": .string(name),
                    "trackCount": .int(count),
                    "status": .string("awaiting_review"),
                ])
            )]
        )
    }
}
