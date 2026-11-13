// LibraryToolbox+ControlQueue — `play_tracks` and `queue_tracks`: the two control
// tools that name tracks, and therefore the two that have to validate them.
//
// ── VALIDATION IS PER ID, AND IT IS SAID OUT LOUD ─────────────────────────────
//
// A model composes a play request from ids it read out of an EARLIER lookup, and
// between those two turns a profile can be switched, a drive can be unmounted, or
// the model can simply have invented a number. Silently playing the subset that
// happened to work would teach it that every id it guesses is real. So each id is
// answered individually, and the answer distinguishes the two things it can be:
//
//   not in the library   — no such row, OR a row outside this profile's roots.
//                          Indistinguishable by construction, and the sentence
//                          says only what is true of both.
//   present but unplayable — the row exists and this profile can see it, but the
//                          file is missing or its drive is not connected.
//
// ── PARTIAL SUCCESS PLAYS; TOTAL FAILURE REFUSES ──────────────────────────────
//
// One valid id is enough to start: a listener who asked for five tracks and can
// have four wants the four, and the sentence names what was dropped so the model
// can correct the next request. Zero valid ids plays NOTHING and touches the
// player not at all — there is no such thing as "start playing an empty selection",
// and clearing someone's queue because the model guessed wrong would be the single
// most destructive thing this tool could do.
//
// ── THE SEAM IS ONLY REACHED AFTER VALIDATION ─────────────────────────────────
//
// ``ToolboxPlaybackControlling`` is documented as taking ids the tool has already
// checked. That ordering is the reason the seam can be total (nothing throws) and
// the reason its Fake is three stored arrays.
//
// This file imports Foundation + Persistence; it MUST NOT import AppKit or UIKit
// (PlayerCore portability invariant).
import Foundation
import Persistence

extension LibraryToolbox {
    /// Refusal sentences spelled out before the rest are counted.
    ///
    /// Three, because a hundred rejected ids would otherwise fill an on-device
    /// result's whole 600-character budget with the same sentence and leave no room
    /// for the state the tool is supposed to report.
    static let controlRefusalDetailLimit = 3

    /// The only `mode` v1 accepts. Declared as a vocabulary rather than omitted so
    /// adding "append" later is a new value on an existing argument instead of a
    /// new argument on a published tool.
    ///
    /// `public` because it is the argument's published vocabulary: an adapter or a
    /// test that names it must read the one definition, not a second copy.
    public static let playTracksModes = ["replace"]

    static func makePlayTracks(
        _ context: LibraryToolboxContext,
        _ playback: any ToolboxPlaybackControlling
    ) -> LibraryTool {
        LibraryTool(
            name: "play_tracks",
            description: "Start playing the given library tracks now, replacing whatever is queued.",
            parametersSchema: ToolSchema.object([
                .init("track_ids", ToolSchema.integerArray(
                    "Library ids to play, in the order they should play.",
                    maxItems: ToolResultBudget.identifierBatchLimit
                )),
                .init("mode", ToolSchema.string(
                    "How to start. Only \"replace\" is supported; omit it for that.",
                    allowed: playTracksModes
                )),
            ], required: ["track_ids"]),
            execute: { arguments in
                let ids = try arguments.identifiers(
                    "track_ids",
                    limit: ToolResultBudget.identifierBatchLimit
                )
                _ = try arguments.optionalEnumValue("mode", allowed: playTracksModes)
                let selection = try await controlSelection(context, ids: ids)
                guard !selection.playable.isEmpty else {
                    return refusedControl(selection, verb: "played")
                }
                let snapshot = await playback.playTracks(ids: selection.playable)
                return controlResult(
                    snapshot,
                    lead: startedLead(selection, asked: ids.count)
                )
            }
        )
    }

    static func makeQueueTracks(
        _ context: LibraryToolboxContext,
        _ playback: any ToolboxPlaybackControlling
    ) -> LibraryTool {
        LibraryTool(
            name: "queue_tracks",
            description: "Add the given library tracks to the play queue without interrupting what is playing.",
            parametersSchema: ToolSchema.object([
                .init("track_ids", ToolSchema.integerArray(
                    "Library ids to queue, in the order they should play.",
                    maxItems: ToolResultBudget.identifierBatchLimit
                )),
                .init("position", ToolSchema.string(
                    "\"next\" to play them before anything else queued, \"last\" to add them after. Omit for last.",
                    allowed: ToolboxQueuePosition.allCases.map(\.rawValue)
                )),
            ], required: ["track_ids"]),
            execute: { arguments in
                let ids = try arguments.identifiers(
                    "track_ids",
                    limit: ToolResultBudget.identifierBatchLimit
                )
                let raw = try arguments.optionalEnumValue(
                    "position",
                    allowed: ToolboxQueuePosition.allCases.map(\.rawValue)
                )
                let position = raw.flatMap { ToolboxQueuePosition(rawValue: $0) } ?? .last
                let selection = try await controlSelection(context, ids: ids)
                guard !selection.playable.isEmpty else {
                    return refusedControl(selection, verb: "queued")
                }
                let snapshot = await playback.queueTracks(ids: selection.playable, position: position)
                return controlResult(
                    snapshot,
                    lead: queuedLead(selection, asked: ids.count, position: position)
                )
            }
        )
    }
}

// MARK: - Validation

extension LibraryToolbox {
    /// Which of the asked-for ids this profile may actually play, and why the rest
    /// may not.
    struct ControlSelection: Equatable {
        var playable: [Int64]
        var refusals: [String]
    }

    /// Partitions `ids` against the ACTIVE profile's visible library, preserving the
    /// caller's order so the queue plays in the order it was asked for.
    static func controlSelection(_ context: LibraryToolboxContext, ids: [Int64]) async throws -> ControlSelection {
        let visible = try await ToolboxExecutor.readAsync {
            try await context.reader.visibleTracks(profileId: context.profileId, trackIds: ids)
        }
        var playable: [Int64] = []
        var refusals: [String] = []
        playable.reserveCapacity(ids.count)
        for identifier in ids {
            guard let track = visible[identifier] else {
                refusals.append("#\(identifier) is not in this listener's library")
                continue
            }
            guard track.availability == .present else {
                let reason = ToolboxRendering.unavailableReason(track.availability)
                refusals.append("\(ToolboxRendering.compactLine(track)) is \(reason)")
                continue
            }
            playable.append(identifier)
        }
        return ControlSelection(playable: playable, refusals: refusals)
    }

    /// The refusal clause, capped so it cannot crowd out the state sentence.
    static func refusalClause(_ selection: ControlSelection) -> String? {
        guard !selection.refusals.isEmpty else { return nil }
        let shown = selection.refusals.prefix(controlRefusalDetailLimit)
        var clause = shown.joined(separator: "; ") + "."
        let omitted = selection.refusals.count - shown.count
        if omitted > 0 {
            clause += " \(omitted) more could not be used."
        }
        return clause
    }

    /// Nothing was playable, so the player was NOT touched. Never list-shaped.
    static func refusedControl(_ selection: ControlSelection, verb: String) -> ToolResult {
        let detail = refusalClause(selection) ?? "None of those ids are usable."
        return ToolResult.message("Nothing was \(verb); the player was not changed. \(detail)")
    }

    /// `nil` when every id was accepted — the state sentence that follows already
    /// names what started, so a lead would only repeat it. A lead appears exactly
    /// when something was DROPPED, which is the case the model needs told.
    static func startedLead(_ selection: ControlSelection, asked: Int) -> String? {
        guard selection.playable.count < asked else { return nil }
        return appendingRefusals(
            "Playing \(selection.playable.count) of \(asked) tracks.",
            selection
        )
    }

    /// Always present, unlike ``startedLead(_:asked:)``: the state sentence after a
    /// queue call describes what is PLAYING, which the call did not change, so
    /// nothing else would report that anything happened.
    static func queuedLead(_ selection: ControlSelection, asked: Int, position: ToolboxQueuePosition) -> String {
        let count = selection.playable.count
        let placement = position == .next ? "to play next" : "at the end of the queue"
        let head = count < asked
            ? "Queued \(count) of \(asked) tracks \(placement)."
            : "Queued \(count) \(count == 1 ? "track" : "tracks") \(placement)."
        return appendingRefusals(head, selection)
    }

    private static func appendingRefusals(_ lead: String, _ selection: ControlSelection) -> String {
        guard let clause = refusalClause(selection) else { return lead }
        return lead + " " + clause
    }
}
