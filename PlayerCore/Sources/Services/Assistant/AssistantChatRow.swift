// AssistantChatRow — the STRUCTURED half of a tool answer, carried to the surface
// so a chat transcript can draw real track rows instead of prose.
//
// ── WHY THIS EXISTS AT ALL ────────────────────────────────────────────────────
//
// ``AssistantChatEvent/toolResult`` already carries the tool's rendered `summary`,
// and a shell that wanted a list could in principle read the titles back out of it.
// That is exactly the failure `LibraryChatToolCounts.swift` refuses for the RESULT
// COUNT, one type larger: the rendered text is model-facing prose, bounded by a
// tier's character budget, and its shape is free to change (the `+N more` suffix,
// the row cap, the elision mark). Parsing it would make a rendering decision into
// a wire format.
//
// So the rows take the same SHORT WAY ROUND the count does. ``ToolResultRow``
// already carries a machine form beside its line — `ToolboxRendering.payload(_:)`
// builds it from the record — and this file is the ONE place that payload becomes
// something a shell can render. Nothing is ever read out of `summary`.
//
// ── THE DISCRIMINATOR: SHAPE FIRST, THEN THE TOOL ─────────────────────────────
//
// `ToolboxJSON` is untyped, and the toolbox emits SEVEN payload shapes down one
// `ToolResultRow.payload` channel. Six of them are not tracks, and each is ruled
// out by the keys it does or does not carry:
//
//   track          {id, title, artist, album, genre, year, durationSeconds,
//                   availability}                                    ← WANTED
//   playback entry {id, title, artist, durationSeconds}              ← see below
//   genre          {genre, trackCount}              no `id`,    has `trackCount`
//   playlist       {id, name, trackCount}           no `title`, has `trackCount`
//   proposal       {proposalId, name, trackCount, status}
//                                                   no `id`,    has `proposalId`
//   feature        {id, analysed, bpm?, energy?, brightness?}        no `title`
//   stats          {kind, title|name, plays}        no `id`
//
// Hence ``AssistantChatRow/isTrackPayload(_:)``: REQUIRE `id` and `title`, FORBID
// `trackCount` and `proposalId`. That is total over the six non-track shapes on
// shape alone — five of them, at least.
//
// The playback entry is the sixth and it is NOT shape-separable: its keys are a
// strict SUBSET of the track payload's, so any predicate that admits a track
// admits it too. It is excluded by the OTHER gate — ``rowCarryingToolNames`` —
// which is why both gates exist and why neither may be dropped as redundant. A
// queue listing is a snapshot of the PLAYER, not a lookup in the library, and
// drawing it as a library list would offer library actions on rows that are not
// a library result.
//
// ── SUGGESTIONS ARE MISSES, NOT ROWS ──────────────────────────────────────────
//
// `match_tracks` answers one batch with both: the tracks it found (track payloads)
// and the ones it could not (a `kind: "miss"` payload carrying the title/artist
// that was ASKED for, which by definition has no library id). A miss is not a row
// — there is nothing to play — but it is the most useful thing on the screen, so
// it travels beside the rows as ``AssistantChatSuggestion`` rather than being
// dropped. The `kind` KEY is shared with the stats payloads (`track`/`artist`/
// `genre`); only the VALUE `"miss"` selects a suggestion.
//
// This file imports only Foundation; it MUST NOT import AppKit or UIKit
// (PlayerCore portability invariant).
import Foundation

/// One track a tool answered with, as a shell draws it.
///
/// Deliberately three fields and no more. This is what a transcript row needs to
/// show a line and offer the library's own actions on it (`trackId` is the handle
/// for every one of them); anything richer is a read the shell makes for itself
/// from the id, against live data, rather than a stale copy carried through a
/// model round-trip.
///
/// Every field is optional because the payload's are: ``ToolboxRendering`` writes
/// `.null` for a blank tag, and a row with no title still has an id to act on.
public struct AssistantChatRow: Sendable, Equatable, Hashable {
    /// The library row's id. Never `<= 0` when built by ``rows(from:)`` — the
    /// toolbox writes `0` for a record with no id, and `#0` is not a handle.
    public let trackId: Int64?
    public let title: String?
    public let artist: String?

    public init(trackId: Int64? = nil, title: String? = nil, artist: String? = nil) {
        self.trackId = trackId
        self.title = title
        self.artist = artist
    }
}

/// Something a tool was asked for and could not find.
///
/// `title` is non-optional: a miss with nothing to name is not worth a line, and
/// `match_tracks` never files one (its `title` is the caller's own required field).
///
/// Deliberately NOT `Codable`, unchanged by the addition of ``videoURL``: a chat
/// transcript lives in memory for the length of a conversation and is discarded with
/// the engine that answered it, so there is nothing to serialise and therefore no
/// migration to own.
public struct AssistantChatSuggestion: Sendable, Equatable, Hashable {
    public let title: String
    public let artist: String?
    /// A watch link for this miss, resolved after the fact — `nil` for every
    /// suggestion any producer in this repo BUILDS.
    ///
    /// ── THE FIELD IS A DESTINATION, NOT A CHANNEL ────────────────────────────
    ///
    /// Nothing that builds a suggestion may fill this in — not
    /// ``AssistantChatRow/suggestion(fromPayload:)`` below, which reads an untyped
    /// payload a model's own tool call produced, and not the macOS shell's connector
    /// event mapping. The ONE writer is `LibraryChatViewModel`'s enrichment seam,
    /// which runs after a turn has landed and admits only a URL its shell already put
    /// through `YouTubeLinkResolver.validatedWatchURL` — AIConnectorKit's single
    /// sanctioned gate.
    ///
    /// That used to be free: with no field, a URL a model wrote had nowhere to sit,
    /// and "no unreviewed URL reaches the surface" was a property of the type system.
    /// This field retires that property, so two tests replace it — one per
    /// non-enricher producer (`LibraryChatRowTests+ProducerPin` here,
    /// `LibraryChatSuggestionProducerPinTests` in the shell).
    ///
    /// `URL?` and not `String?`: a value that has been parsed cannot carry a scheme
    /// nobody looked at.
    public let videoURL: URL?

    public init(title: String, artist: String? = nil, videoURL: URL? = nil) {
        self.title = title
        self.artist = artist
        self.videoURL = videoURL
    }
}

// MARK: - Building

public extension AssistantChatRow {
    /// How many rows one tool answer may contribute to the transcript.
    ///
    /// RECORDED DECISION: this is deliberately larger than what the on-device
    /// render shows. `ToolProfile.onDevice` drops rows past ten (and past 600
    /// characters) because the MODEL's context is scarce; a transcript on a
    /// Retina display is not. The rows come from the full ``ToolResult``, so the
    /// chat may legitimately list more tracks than the model was told about.
    static let limit = 50

    /// Keys the discriminator reads. Spelled once so the payload builders and this
    /// filter cannot drift apart silently.
    enum PayloadKey {
        static let id = "id"
        static let title = "title"
        static let artist = "artist"
        /// Present on the genre, playlist and proposal payloads. Never on a track.
        static let trackCount = "trackCount"
        /// Present on the proposal payload only.
        static let proposalId = "proposalId"
        /// Present on the stats and `match_tracks` miss payloads.
        static let kind = "kind"
        /// The one `kind` VALUE that is a suggestion. See the file header.
        static let missKind = "miss"
    }

    /// The tools whose rows a shell may draw as a library list.
    ///
    /// The second half of the discriminator, and the ONLY thing that separates a
    /// queue listing from a search result — see the file header. Adding a name
    /// here is a decision that the tool answers with LIBRARY tracks the listener
    /// may act on, not merely with something track-shaped.
    static let rowCarryingToolNames: Set<String> = [
        "search_tracks",
        "get_tracks",
        "get_playlist",
        "sample_tracks",
        "match_tracks",
    ]

    /// Whether `name` is a tool whose rows reach the transcript.
    static func carriesRows(toolNamed name: String) -> Bool {
        rowCarryingToolNames.contains(name)
    }

    /// The track rows in `payloads`, bounded by ``limit``.
    ///
    /// Malformed input is SKIPPED, never thrown on: a payload is built one layer
    /// down from data this layer does not own, and a chat turn that lost a row is
    /// strictly better than one that lost its answer. See the file header for the
    /// shape rules.
    ///
    /// `lazy` so the cap counts ACCEPTED rows rather than inspected ones: a
    /// hundred non-track payloads followed by fifty tracks still yields fifty.
    static func rows(from payloads: [ToolboxJSON]) -> [AssistantChatRow] {
        Array(payloads.lazy.compactMap { row(fromPayload: $0) }.prefix(limit))
    }

    /// The same, over the rows a ``ToolResult`` answered with.
    ///
    /// The overload an ADAPTER wants: it reads ``ToolResultRow/trackRowProjection``
    /// instead of flattening to payloads first, which is what lets the cloud
    /// bridge — which cannot name this type from the kit's side of the boundary —
    /// apply the very same rule.
    static func rows(from rows: [ToolResultRow]) -> [AssistantChatRow] {
        Array(rows.lazy.compactMap(\.trackRowProjection).prefix(limit))
    }

    /// The misses in `payloads`, bounded by ``limit``.
    static func suggestions(from payloads: [ToolboxJSON]) -> [AssistantChatSuggestion] {
        Array(payloads.lazy.compactMap { suggestion(fromPayload: $0) }.prefix(limit))
    }

    /// The same, over the rows a ``ToolResult`` answered with.
    static func suggestions(from rows: [ToolResultRow]) -> [AssistantChatSuggestion] {
        Array(rows.lazy.compactMap(\.suggestionProjection).prefix(limit))
    }

    /// ONE payload as a track row, or `nil`.
    ///
    /// The single application of the shape half of the discriminator — every
    /// other entry point on either tier routes through here.
    static func row(fromPayload payload: ToolboxJSON) -> AssistantChatRow? {
        guard
            let object = payload.objectValue,
            isTrackPayload(object),
            let trackId = identifier(in: object)
        else {
            return nil
        }
        return AssistantChatRow(
            trackId: trackId,
            title: object[PayloadKey.title]?.stringValue,
            artist: object[PayloadKey.artist]?.stringValue
        )
    }

    /// ONE payload as a miss, or `nil`. See the file header for why a miss is not
    /// a row.
    static func suggestion(fromPayload payload: ToolboxJSON) -> AssistantChatSuggestion? {
        guard
            let object = payload.objectValue,
            object[PayloadKey.kind]?.stringValue == PayloadKey.missKind,
            let title = object[PayloadKey.title]?.stringValue
        else {
            return nil
        }
        return AssistantChatSuggestion(
            title: title,
            artist: object[PayloadKey.artist]?.stringValue
        )
    }

    /// The shape half of the discriminator. Required keys present, forbidden keys
    /// absent — see the seven-shape table in the file header.
    static func isTrackPayload(_ object: [String: ToolboxJSON]) -> Bool {
        object[PayloadKey.id] != nil
            && object[PayloadKey.title] != nil
            && object[PayloadKey.trackCount] == nil
            && object[PayloadKey.proposalId] == nil
    }

    /// The payload's `id` as a usable library handle, or `nil`.
    ///
    /// `ToolboxJSON` has ONE number case, so an id arrives as a `Double` and is
    /// only an id if it is exactly an integer. `<= 0` is dropped because that is
    /// what ``ToolboxRendering`` writes for a record with no row of its own.
    static func identifier(in object: [String: ToolboxJSON]) -> Int64? {
        guard
            let number = object[PayloadKey.id]?.numberValue,
            let exact = Int64(exactly: number.rounded()),
            number == number.rounded(),
            exact > 0
        else {
            return nil
        }
        return exact
    }
}

// MARK: - The projection both chat tiers share

public extension ToolResultRow {
    /// This row as a track a chat surface can draw, or `nil` when its payload is
    /// not a track.
    ///
    /// Exposed on the ROW, rather than kept inside ``AssistantChatRow``, because
    /// `AIConnectorBridge` builds the cloud tier's rows from a ``ToolRunOutcome``
    /// and has to apply the identical rule. Two implementations of a
    /// discriminator over an UNTYPED payload would drift the first time a payload
    /// key is renamed, and nothing would fail to compile.
    var trackRowProjection: AssistantChatRow? {
        AssistantChatRow.row(fromPayload: payload)
    }

    /// This row as a miss, or `nil`. The suggestion half of the same seam.
    var suggestionProjection: AssistantChatSuggestion? {
        AssistantChatRow.suggestion(fromPayload: payload)
    }
}
