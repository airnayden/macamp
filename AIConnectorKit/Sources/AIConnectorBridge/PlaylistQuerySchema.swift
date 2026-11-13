// PlaylistQuerySchema — the canonical structured-output contract, and its inverse.
//
// ``FMQuerySpecDTO`` is what Apple's guided generation fills in on macOS 26+; this
// is the SAME nine fields expressed as a provider-agnostic JSON Schema, so a remote
// connector lands in exactly the raw bag ``FMQuerySpecFields/resolve(validGenres:)``
// already validates. One shape, one validator, two transports.
//
// ── WHY IT MIRRORS `FMQuerySpecFields`, NOT `PlaylistQuerySpec` ───────────────
//
// ``PlaylistQuerySpec`` is the RESOLVED spec: real `PlaylistMoodTag` cases, assembled
// ranges, a clamped `targetCount`, genres rewritten to the library's own spelling. A
// model cannot be asked for that — deciding whether "Rockk" is a genre is precisely
// what the validator exists to do. So the schema mirrors the UNVALIDATED bag, and the
// answer goes through the identical `resolve` the FoundationModels tier uses.
//
// `lowConfidence` is therefore NOT a schema field and must never become one. It is
// derived CLIENT-SIDE from `spec.isUnconstrained` in the second-pass rebuild at
// `FMQuerySpecDTO.swift:148-157` — a model asserting its own confidence would be
// asserting exactly the thing it is worst at.
//
// ── STRICT MODE COMES FREE ───────────────────────────────────────────────────
//
// ``JSONSchemaObject``'s defaults are OpenAI strict mode: `additionalProperties:
// false` and every property listed in `required`. Optionality is expressed ONLY
// through ``JSONSchemaNode/isNullable`` (a `"type": ["integer", "null"]` union),
// never by dropping a name from `required`. Nothing below opts out, so the one
// document serves Ollama's `format`, Anthropic's forced-tool `input_schema` and
// OpenAI's `response_format.json_schema` unchanged.
//
// ── RANGES LIVE IN PROSE, CLAMPING LIVES CLIENT-SIDE ─────────────────────────
//
// `JSONSchemaNode` emits no `minimum`/`maximum`, by design: a numeric bound a
// provider silently ignores is a bound that was never enforced. The plausible
// windows are stated in each field's `description` (where they steer decoding) and
// ENFORCED afterwards — years and tempi against `FMQuerySpecFields.plausibleYears` /
// `plausibleTempi`, `targetCount` by `PlaylistQuerySpec.init`, which clamps to
// `1 ... MixSpec.maxTargetCount`. The schema advertises; `resolve` decides.
import AIConnectorKit
import Foundation
import Services

/// The one structured-output schema every connector sends, plus the decoder that
/// turns a provider's answer back into ``FMQuerySpecFields``.
public enum PlaylistQuerySchema {
    /// The nine fields of ``FMQuerySpecFields``, in its own declaration order.
    ///
    /// Declaration order is load-bearing twice over: it is the order `required` is
    /// emitted in, which keeps recorded-request assertions byte-stable, and it is the
    /// order a reader compares against the Swift type when checking the mirror is
    /// still exact.
    public static let canonical = JSONSchemaObject(
        properties: [
            .init(
                name: "genres",
                schema: .array(
                    of: .string(),
                    description: "Genres named or implied, spelled exactly as in the library genre list given in the instructions."
                )
            ),
            .init(
                name: "yearLowerBound",
                schema: .integer(
                    isNullable: true,
                    description: "Earliest release year allowed, e.g. 1990 for 'the 90s'. Between 1860 and 2999. Null if unmentioned."
                )
            ),
            .init(
                name: "yearUpperBound",
                schema: .integer(
                    isNullable: true,
                    description: "Latest release year allowed, e.g. 1999 for 'the 90s'. Between 1860 and 2999. Null if unmentioned."
                )
            ),
            .init(
                name: "moodTags",
                schema: .array(
                    of: .string(allowedValues: FMQuerySpecFields.moodVocabulary),
                    description: "Moods asked for. calm/energetic describe drive; dark/bright describe tone. Empty if none."
                )
            ),
            .init(
                name: "tempoLowerBPM",
                schema: .number(
                    isNullable: true,
                    description: "Slowest tempo in BPM allowed, between 20 and 400. Null if the request says nothing about tempo."
                )
            ),
            .init(
                name: "tempoUpperBPM",
                schema: .number(
                    isNullable: true,
                    description: "Fastest tempo in BPM allowed, between 20 and 400. Null if the request says nothing about tempo."
                )
            ),
            .init(
                name: "recency",
                schema: .string(
                    allowedValues: FMQuerySpecFields.recencyVocabulary,
                    isNullable: true,
                    description: "How to weigh listening history. Use none if the request says nothing."
                )
            ),
            .init(
                name: "seedArtists",
                schema: .array(
                    of: .string(),
                    description: "Artists named explicitly, e.g. 'more like Radiohead'. Empty if none."
                )
            ),
            .init(
                name: "targetCount",
                schema: .integer(
                    isNullable: true,
                    description: "How many tracks the listener asked for, between 1 and 100. Null if unmentioned."
                )
            ),
        ],
        description: "A listener's request for a playlist, broken into filters"
    )

    /// Bytes ``canonical`` occupies in a request body, encoded the way every
    /// connector encodes it.
    ///
    /// The schema is the largest FIXED cost in a request, so
    /// ``ConnectorPromptBuilder`` measures the variable text against what is left of
    /// the budget after this. Computed once, at first use.
    ///
    /// A failure to encode falls back to the whole budget rather than to zero: an
    /// unmeasurable schema must make the builder shrink MORE, never less. The
    /// fallback is unreachable in practice — every value in the document is a
    /// `String`, a `Bool` or an array of them.
    public static let canonicalByteCount: Int = {
        guard let data = try? canonicalEncoder().encode(canonical) else {
            return ConnectorPayloadBudget.maxSerializedBodyBytes
        }
        return data.count
    }()

    /// The encoder every connector must use for a request body.
    ///
    /// `.sortedKeys` is what makes a body byte-stable: key order inside a keyed
    /// container is otherwise an implementation detail, and every recorded-request
    /// assertion in the connector suites depends on it. `.withoutEscapingSlashes`
    /// keeps genre names like "R&B/Soul" readable in a fixture diff.
    public static func canonicalEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

// MARK: - Decoding a provider's answer

public extension PlaylistQuerySchema {
    /// Turns one provider's structured answer into the raw bag the validator accepts.
    ///
    /// DROP, NEVER FAIL — the same policy ``FMQuerySpecFields`` documents for its own
    /// guards, applied one layer earlier. A field of the wrong JSON type (a provider
    /// that writes `1990.0` for a year, or `"120"` for a tempo) is dropped to its
    /// empty value; the other eight still land. Failing the whole response over one
    /// loose scalar would throw away a request the library can serve, and a dropped
    /// bound is already spelled "no constraint".
    ///
    /// The one genuine failure is a payload that is not a JSON object at all — prose,
    /// a code fence, an error envelope. That is a malformed RESPONSE rather than an
    /// unservable value, so it throws.
    ///
    /// - Throws: ``ConnectorFailure/malformedResponse`` when `data` does not decode
    ///   as a JSON object.
    static func decodeFields(from data: Data) throws -> FMQuerySpecFields {
        guard let payload = try? JSONDecoder().decode(CanonicalPayload.self, from: data) else {
            throw ConnectorFailure.malformedResponse
        }
        return payload.fields
    }
}

/// The lenient reader behind ``PlaylistQuerySchema/decodeFields(from:)``.
///
/// Every field is read through ``lenient(_:_:in:)`` so one wrong type costs one
/// field. Nested rather than fileprivate-free so the `CodingKeys` names — which must
/// stay identical to ``PlaylistQuerySchema/canonical``'s property names — sit beside
/// the schema that declares them.
struct CanonicalPayload: Decodable {
    let fields: FMQuerySpecFields

    enum CodingKeys: String, CodingKey {
        case genres
        case yearLowerBound
        case yearUpperBound
        case moodTags
        case tempoLowerBPM
        case tempoUpperBPM
        case recency
        case seedArtists
        case targetCount
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fields = FMQuerySpecFields(
            genres: Self.lenient([String].self, .genres, in: container) ?? [],
            yearLowerBound: Self.lenient(Int.self, .yearLowerBound, in: container),
            yearUpperBound: Self.lenient(Int.self, .yearUpperBound, in: container),
            moodTags: Self.lenient([String].self, .moodTags, in: container) ?? [],
            tempoLowerBPM: Self.lenient(Double.self, .tempoLowerBPM, in: container),
            tempoUpperBPM: Self.lenient(Double.self, .tempoUpperBPM, in: container),
            recency: Self.lenient(String.self, .recency, in: container),
            seedArtists: Self.lenient([String].self, .seedArtists, in: container) ?? [],
            targetCount: Self.lenient(Int.self, .targetCount, in: container)
        )
    }

    /// One field, or `nil` when it is absent, explicitly null, or the wrong type.
    private static func lenient<Value: Decodable>(
        _ type: Value.Type,
        _ key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>
    ) -> Value? {
        (try? container.decodeIfPresent(type, forKey: key)) ?? nil
    }
}
