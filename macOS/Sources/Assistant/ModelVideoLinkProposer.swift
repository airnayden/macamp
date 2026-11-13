// ModelVideoLinkProposer — asks the provider that just named these songs for their
// YouTube video ids, instead of spending a rate-capped web search on each one.
//
// ── WHY THIS EXISTS ──────────────────────────────────────────────────────────
//
// ``YouTubeLinkResolver``'s search half runs on a KEYLESS provider with a DAILY
// CAP. Measured 2026-09-09: once the cap trips the endpoint answers HTTP 429
// `daily_cap_reached`, the resolver reads that as "no candidate", and every
// remaining song silently degrades to a search link — which is what a listener
// sees as "some links open the video, some open a search page".
//
// A model that has just listed "Vogue — Madonna" as missing from the library
// usually knows that video's canonical id already. Asking it costs one small
// structured call and NOTHING against the search quota. Measured the same day,
// through the shipped ChatGPT route: `Vogue` → `GuJQSAiODqI`, `Wannabe` →
// `gJLIiF15wjQ`, `Torn` → `VV1XWJN3nJo` — three for three, each confirmed by
// oEmbed as the official upload.
//
// ── THE MODEL IS A SOURCE OF CANDIDATES, NEVER A SOURCE OF TRUST ─────────────
//
// Nothing here decides that a link is good. Every id this type returns is handed
// to ``YouTubeLinkResolver/verify(_:proposedIDs:)``, which applies the SAME gate
// a searched candidate passes: `validatedWatchURL` for shape, oEmbed for "the
// video exists and is embeddable", and the token-overlap rule for "it is the song
// that was asked for". A hallucinated id fails that gate and the song falls back
// to the search link it would have had anyway — so this can only improve on the
// status quo, never degrade it.
//
// That is also why this file builds no URL and renders nothing: it answers ids,
// and `YouTubeSearchLink`'s "the app builds the link, never the model" rule is
// preserved by the verifier upstream of every rendered row.
import AIConnectorKit
import Foundation
import Services

/// Asks a connector for the YouTube video id of each song, in order.
struct ModelVideoLinkProposer {
    /// The provider that answered the turn these songs came from.
    let connector: any AIProviderConnector
    /// The model id the route resolved — the same one the conversation used.
    let model: String

    /// How many songs one call may ask about.
    ///
    /// A long list is where a wrong id is most likely and where the answer is
    /// most likely to be cut off, and the enricher's own batch is bounded anyway.
    static let maximumSongsPerCall = 50

    /// Ids for `suggestions`, positionally, `nil` where the model offered none.
    ///
    /// Never throws: this is an OPTIONAL upgrade over the search path, so every
    /// failure — a refusal, a malformed answer, a provider outage — answers
    /// all-`nil` and lets the caller fall back.
    func proposedIDs(for suggestions: [AssistantChatSuggestion]) async -> [String?] {
        let empty = [String?](repeating: nil, count: suggestions.count)
        guard suggestions.isEmpty == false, suggestions.count <= Self.maximumSongsPerCall else { return empty }
        guard let data = try? await connector.structuredCompletion(
            schema: Self.schema,
            instructions: Self.instructions,
            prompt: Self.prompt(for: suggestions),
            model: model
        ) else {
            return empty
        }
        return Self.identifiers(in: data, count: suggestions.count)
    }
}

// MARK: - The wire shape

extension ModelVideoLinkProposer {
    /// Songs are addressed by INDEX, never by echoed title: a model that
    /// re-spells "…Baby One More Time" would otherwise pair its id to no song at
    /// all, and a fuzzy re-match would risk pairing it to the WRONG one.
    static let schema = JSONSchemaObject(
        properties: [
            .init(
                name: "videos",
                schema: .array(
                    of: .object(JSONSchemaObject(
                        properties: [
                            .init(name: "index", schema: .integer(
                                description: "The number shown beside the song in the prompt."
                            )),
                            .init(name: "video_id", schema: .string(
                                isNullable: true,
                                description: "The 11-character YouTube id of that song's official video, "
                                    + "or null if you do not know it. Never guess."
                            )),
                        ]
                    )),
                    description: "One entry per song, in the order given."
                )
            ),
        ]
    )

    static let instructions =
        "You identify official YouTube music videos. For each numbered song, give the 11-character id from "
            + "its watch URL. Answer null for any song whose id you do not actually know — a wrong id is "
            + "worse than none, and every id is checked before it is shown."

    static func prompt(for suggestions: [AssistantChatSuggestion]) -> String {
        suggestions.enumerated().map { offset, suggestion in
            let artist = suggestion.artist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return artist.isEmpty
                ? "\(offset). \(suggestion.title)"
                : "\(offset). \(suggestion.title) — \(artist)"
        }
        .joined(separator: "\n")
    }

    /// The ids in `data`, placed at the index each entry names.
    ///
    /// An entry naming an out-of-range index is DROPPED rather than clamped: it
    /// is evidence the answer did not track the prompt, and a clamp would pair an
    /// id with a song nobody asked about.
    static func identifiers(in data: Data, count: Int) -> [String?] {
        var identifiers = [String?](repeating: nil, count: count)
        guard let entries = AIJSONValue.decoded(from: data)?["videos"]?.arrayValue else { return identifiers }
        for entry in entries {
            guard let index = entry["index"]?.intValue, index >= 0, index < count,
                  let identifier = entry["video_id"]?.stringValue
            else {
                continue
            }
            let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            identifiers[index] = trimmed.isEmpty ? nil : trimmed
        }
        return identifiers
    }
}
