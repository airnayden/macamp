// ChatGPTWireTypes.swift — the `Encodable`/`Decodable` mirrors of the ChatGPT
// backend's Responses-API request and response JSON, split out of
// `ChatGPTConnector.swift`.
//
// Split for one mechanical reason: `.swiftlint.yml` does not override
// `file_length`, so SwiftLint's 400-line ceiling applies and CI runs `--strict`.
// Direct precedent: `AnthropicWireTypes.swift`, split from `AnthropicConnector.swift`
// for exactly this. These types own no behaviour, which makes them the block that
// moves.
//
// FLAT, not nested inside the request: two of them need their own `CodingKeys`,
// and SwiftLint's `nesting` rule caps types at one level deep. They are
// `internal` rather than `private` only because they now live across a file
// boundary — the `ChatGPT` prefix keeps them from colliding with a sibling
// connector's mirrors.
//
// The wire contract they encode, and the researched sources behind it, are
// documented in `ChatGPTConnector.swift`'s header.
import AIConnectorKit
import Foundation

/// The `POST /responses` body.
///
/// `store: false` keeps the listener's prompt off the provider's conversation
/// history — the observed client sends the same, and that is unchanged.
///
/// `stream: true` is NOT a preference. This connector sent `stream: false` until
/// 2026-09-06, when the backend began answering a non-streaming request with
/// HTTP 400 `{"detail":"Stream must be set to true"}`. Asking for a stream does
/// not make the connector streaming: the transport buffers the whole body and
/// ``ChatGPTConnector/completedResponse(in:)`` reduces it back to one response
/// object. See `ChatGPTBackendContract.swift` for the measurement.
///
/// `max_output_tokens` is DELIBERATELY ABSENT — the backend refuses it with
/// HTTP 400 `{"detail":"Unsupported parameter: max_output_tokens"}`, measured
/// live 2026-09-09. See ``ChatGPTConnector/ToolLoopKey`` for the record.
struct ChatGPTResponsesRequest: Encodable {
    var model: String
    var instructions: String
    var input: [ChatGPTInputItem]
    /// `nil` for a plain completion. `encodeIfPresent` omits the key rather than
    /// sending null, which a strict endpoint rejects.
    var text: ChatGPTTextControls?
    var store = false
    var stream = true
}

/// One Responses-API input message. The nested content array is the shape this
/// endpoint requires — a bare `content: String` is a different, older dialect.
struct ChatGPTInputItem: Encodable {
    var type = "message"
    var role = "user"
    var content: [ChatGPTInputContent]

    init(text: String) {
        content = [ChatGPTInputContent(text: text)]
    }
}

struct ChatGPTInputContent: Encodable {
    var type = "input_text"
    var text: String
}

struct ChatGPTTextControls: Encodable {
    var format: ChatGPTTextFormat
}

/// The Responses-API equivalent of todo 8's `json_schema` envelope. `strict` is
/// fixed `true` — a connector that could send `false` would quietly stop
/// enforcing the schema. `name` has no default because the envelope is rejected
/// without it.
struct ChatGPTTextFormat: Encodable {
    var type = "json_schema"
    var name: String
    var strict = true
    var schema: JSONSchemaObject
}

/// `GET /models`. Tolerant on purpose: the catalog is served under `data` on one
/// observed shape and `models` on another, and the identifier is spelled `id` or
/// `slug`. Anything else is a shape this connector does not understand, and
/// ``identifiers`` being empty is what the caller turns into a visible failure —
/// silently reporting "no models" would look like an empty account.
struct ChatGPTModelList: Decodable {
    struct Entry: Decodable {
        var id: String?
        var slug: String?
    }

    enum CodingKeys: String, CodingKey {
        case data
        case models
    }

    /// Non-empty identifiers, in the order the provider listed them.
    let identifiers: [String]

    /// Hand-written so that "neither key present" is a DECODE FAILURE rather
    /// than an empty list.
    ///
    /// With synthesised decoding both properties are optional, so ANY JSON
    /// object parses and an endpoint whose payload shape has drifted reports
    /// zero models — indistinguishable, in the selector, from an account that
    /// genuinely has none. Failing here routes drift to
    /// ``ConnectorFailure/malformedResponse`` instead, which is the one signal
    /// the shell can act on.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let entries = try container.decodeIfPresent([Entry].self, forKey: .data)
            ?? container.decodeIfPresent([Entry].self, forKey: .models)
        guard let entries else {
            throw DecodingError.keyNotFound(
                CodingKeys.data,
                DecodingError.Context(codingPath: container.codingPath, debugDescription: "no model array")
            )
        }
        identifiers = entries
            .compactMap { $0.id ?? $0.slug }
            .filter { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
    }
}

/// `POST /responses`. Two spellings are read because the API offers both: the
/// canonical `output` array of message items, and the `output_text` convenience
/// field. Neither is guaranteed, so ``text`` is optional and its absence is a
/// ``ConnectorFailure/malformedResponse``.
struct ChatGPTResponsesReply: Decodable {
    struct Content: Decodable {
        var type: String?
        var text: String?
    }

    struct Item: Decodable {
        var type: String?
        var content: [Content]?
    }

    var outputText: String?
    var output: [Item]?

    enum CodingKeys: String, CodingKey {
        case outputText = "output_text"
        case output
    }

    /// The assistant's text, preferring the convenience field.
    var text: String? {
        if let outputText, outputText.isEmpty == false {
            return outputText
        }
        let joined = (output ?? [])
            .flatMap { $0.content ?? [] }
            .compactMap(\.text)
            .joined()
        return joined.isEmpty ? nil : joined
    }
}
