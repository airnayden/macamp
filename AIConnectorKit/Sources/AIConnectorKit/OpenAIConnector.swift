// OpenAIConnector — OpenAI, over the Chat Completions API.
//
// ── WHY STRICT MODE IS THE WHOLE STORY ─────────────────────────────────────────
//
// Structured output rides `response_format`:
//
//   {"type": "json_schema",
//    "json_schema": {"name": "playlist_query", "strict": true, "schema": {…}}}
//
// The `name` field is REQUIRED inside that envelope — a `json_schema` block
// without it is a 400 even when the schema itself is perfectly valid.
//
// `strict: true` then imposes two rules on the schema document: every object must
// carry `additionalProperties: false`, and `required` must list EVERY declared
// property. An optional field therefore cannot be modelled by leaving it out of
// `required` — it has to be a nullable type union (`"type": ["integer", "null"]`),
// and a nullable enum has to carry `null` in its `enum` array too. A naive mirror
// of Swift optionals is a 400 from this endpoint.
//
// ``JSONSchemaObject`` already encodes exactly that BY DEFAULT (`requiredPolicy:
// .allProperties`, `allowsAdditionalProperties: false`, optionality expressed
// through ``JSONSchemaNode/isNullable``), so this connector needs no special
// construction path and does not post-process the schema it is handed.
// `OpenAIStrictSchemaTests` proves that on the recorded request body rather than
// trusting the claim.
//
// Docs:
//   https://platform.openai.com/docs/guides/structured-outputs
//   https://platform.openai.com/docs/api-reference/chat/create
//   https://platform.openai.com/docs/api-reference/models/list
import Foundation

/// A route to OpenAI, authenticated with a bearer API key.
public struct OpenAIConnector: AIProviderConnector {
    /// The API root.
    ///
    /// A `String` rather than a `URL` because Swift has no non-optional URL
    /// literal and `force_unwrapping` is an error under SwiftLint `--strict`;
    /// ``endpoint(_:)`` performs the one guarded conversion.
    public static let baseURLString = "https://api.openai.com/v1"

    /// The `json_schema.name` sent with every structured call.
    ///
    /// REQUIRED by the envelope. It is a machine identifier the listener never
    /// sees, so it is neither localized nor configurable.
    public static let structuredOutputName = "playlist_query"

    /// How much of a FAILING response body is retained for diagnosis.
    static let maxDiagnosticBodyLength = 512

    public let id = "openai"
    public let displayName = "OpenAI"
    public let authDescriptor = AuthDescriptor.apiKey(header: "Authorization")

    // `internal`, not `private`: `OpenAIConnector+ToolLoop.swift` is a separate
    // FILE (SwiftLint's 400-line `file_length` ceiling forbids folding it in here),
    // and a `private` stored property is invisible across a file boundary. Nothing
    // outside this target can reach them, and no behaviour changes.
    let apiKey: @Sendable () async throws -> String
    let transport: any HTTPTransport
    let onRefusal: (@Sendable (String) -> Void)?

    /// - Parameters:
    ///   - apiKey: Resolves the secret at call time — `async throws` because the
    ///     real provider reads the Keychain. Throwing or returning blank means
    ///     "not configured yet", which is a normal state, not an error.
    ///   - transport: The HTTP seam. Injected so suites script responses instead
    ///     of touching the network.
    ///   - onRefusal: Receives the model's refusal text when a structured call is
    ///     declined. ``ConnectorFailure/malformedResponse`` carries no payload by
    ///     design, so this sink is the ONLY place that text surfaces; it is
    ///     model-authored prose about the prompt and never carries a credential.
    public init(
        apiKey: @escaping @Sendable () async throws -> String,
        transport: any HTTPTransport,
        onRefusal: (@Sendable (String) -> Void)? = nil
    ) {
        self.apiKey = apiKey
        self.transport = transport
        self.onRefusal = onRefusal
    }

    /// Every model this key can reach, exactly as OpenAI reports them.
    ///
    /// Deliberately UNFILTERED. `/v1/models` also lists embedding, audio and
    /// image models, but the only way to exclude them is a hardcoded family
    /// prefix list — which goes stale the week a family ships, the very failure
    /// ``AIProviderConnector/listModels()`` exists to avoid. Capabilities come
    /// back empty because the endpoint states none, and per ``ModelInfo`` an
    /// empty set means "unstated", never "incapable".
    public func listModels() async throws -> [ModelInfo] {
        let request = try await getRequest("/models")
        let response = try await transport.send(request)
        try Self.validate(response)
        let payload: OpenAIModelList = try Self.decode(response.body)
        return payload.data
            .map(\.id)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { ModelInfo(id: $0) }
    }

    public func structuredCompletion(
        schema: JSONSchemaObject,
        instructions: String,
        prompt: String,
        model: String
    ) async throws -> Data {
        let envelope = OpenAISchemaEnvelope(name: Self.structuredOutputName, schema: schema)
        let body = OpenAIChatRequest(
            model: model,
            messages: Self.messages(instructions: instructions, prompt: prompt),
            responseFormat: OpenAIResponseFormat(jsonSchema: envelope)
        )
        return try await Data(chat(body).utf8)
    }

    public func completion(instructions: String, prompt: String, model: String) async throws -> String {
        let body = OpenAIChatRequest(
            model: model,
            messages: Self.messages(instructions: instructions, prompt: prompt),
            responseFormat: nil
        )
        // Trimmed, not capped: callers own length limits, but a leading newline in
        // a playlist name is never what anyone meant.
        return try await chat(body).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Round trip

private extension OpenAIConnector {
    /// One chat round-trip, returning the assistant's text content.
    func chat(_ body: OpenAIChatRequest) async throws -> String {
        let request = try await postRequest(Self.chatCompletionsPath, body: body)
        let response = try await transport.send(request)
        try Self.validate(response)
        let payload: OpenAIChatResponse = try Self.decode(response.body)
        guard let message = payload.choices.first?.message else {
            throw ConnectorFailure.malformedResponse
        }
        if let refusal = message.refusal, !refusal.isEmpty {
            onRefusal?(refusal)
            throw ConnectorFailure.malformedResponse
        }
        guard let content = message.content, !content.isEmpty else {
            throw ConnectorFailure.malformedResponse
        }
        return content
    }

    /// The two messages every call sends.
    ///
    /// `system` rather than `developer`: the newer spelling is what the reasoning
    /// models document, but the older one is still accepted and transparently
    /// mapped on every model, so it is the portable choice across the whole model
    /// list this connector reports.
    static func messages(instructions: String, prompt: String) -> [OpenAIChatMessage] {
        [
            OpenAIChatMessage(role: "system", content: instructions),
            OpenAIChatMessage(role: "user", content: prompt),
        ]
    }
}

// MARK: - Requests

/// `internal` for the same reason as the stored properties above.
extension OpenAIConnector {
    func getRequest(_ path: String) async throws -> URLRequest {
        let url = try Self.endpoint(path)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        try await authorize(&request)
        return request
    }

    func postRequest(_ path: String, body: some Encodable) async throws -> URLRequest {
        let url = try Self.endpoint(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.encode(body)
        try await authorize(&request)
        return request
    }

    /// Resolves the secret and attaches the bearer header.
    ///
    /// A missing, failing or blank key is ``ConnectorFailure/unconfigured`` and is
    /// raised BEFORE any transport call — the registry's probe relies on an
    /// unconfigured connector performing zero requests.
    func authorize(_ request: inout URLRequest) async throws {
        let resolved: String
        do {
            resolved = try await apiKey()
        } catch let failure as ConnectorFailure {
            throw failure
        } catch is CancellationError {
            throw ConnectorFailure.cancelled
        } catch {
            throw ConnectorFailure.unconfigured
        }
        let key = resolved.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ConnectorFailure.unconfigured }
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    }

    static func endpoint(_ path: String) throws -> URL {
        guard let url = URL(string: baseURLString + path) else {
            throw ConnectorFailure.unconfigured
        }
        return url
    }
}

// MARK: - Coding

/// `internal` for the same reason as the stored properties above.
extension OpenAIConnector {
    /// `.sortedKeys` makes the body BYTE-STABLE, which is what lets the
    /// recorded-request assertions compare exact strings;
    /// `.withoutEscapingSlashes` keeps schema descriptions readable in those
    /// comparisons.
    ///
    /// The throw is unreachable in practice — every value encoded here is built
    /// from `String`, `Bool` and ``JSONSchemaObject`` — and maps to
    /// ``ConnectorFailure/malformedResponse`` only because the taxonomy is
    /// deliberately total and has no request-side case.
    static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(value)
        } catch {
            throw ConnectorFailure.malformedResponse
        }
    }

    static func decode<Value: Decodable>(_ data: Data) throws -> Value {
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            throw ConnectorFailure.malformedResponse
        }
    }
}

// MARK: - Failure mapping

/// `internal` for the same reason as the stored properties above.
extension OpenAIConnector {
    /// Maps a non-2xx answer onto the taxonomy.
    ///
    /// 403 joins 401: OpenAI returns it for a revoked key and for a key whose
    /// project lost access, both of which retrying cannot fix — which is exactly
    /// what ``ConnectorFailure/authExpired`` means.
    static func validate(_ response: HTTPResponse) throws {
        guard !response.isSuccess else { return }
        switch response.statusCode {
        case 401, 403:
            throw ConnectorFailure.authExpired
        case 429:
            throw ConnectorFailure.rateLimited(retryAfter: retryAfter(in: response))
        default:
            throw ConnectorFailure.httpStatus(
                response.statusCode,
                body: diagnosticBody(response.body),
                providerMessage: ConnectorFailure.sanitizedProviderMessage(in: response.body)
            )
        }
    }

    /// `Retry-After` in seconds, falling back to OpenAI's own `retry-after-ms`.
    ///
    /// Both are read because the millisecond header is the one that actually
    /// accompanies most rate-limit responses. An HTTP-date `Retry-After` reads as
    /// absent: the taxonomy wants a duration, and deriving one from a possibly
    /// skewed clock is worse than `nil`.
    static func retryAfter(in response: HTTPResponse) -> TimeInterval? {
        if let seconds = response.headerValue("Retry-After").flatMap(TimeInterval.init) {
            return seconds
        }
        return response.headerValue("retry-after-ms")
            .flatMap(TimeInterval.init)
            .map { $0 / 1000 }
    }

    /// A truncated copy of a FAILING response body, for diagnosis only.
    ///
    /// Response side ONLY — the request, and therefore the `Authorization`
    /// header, never reaches a ``ConnectorFailure`` payload.
    static func diagnosticBody(_ body: Data) -> String? {
        guard let text = String(data: body, encoding: .utf8), !text.isEmpty else { return nil }
        guard text.count > maxDiagnosticBodyLength else { return text }
        return String(text.prefix(maxDiagnosticBodyLength))
    }
}

// MARK: - Wire types

/// The `POST /v1/chat/completions` body.
///
/// `CodingKeys` spell the snake_case wire names by hand rather than switching the
/// encoder to `.convertToSnakeCase`: that strategy would also rewrite the property
/// names INSIDE `json_schema.schema`, silently corrupting the contract the model
/// is being asked to fill in.
/// The wire types are FLAT rather than nested inside the request: SwiftLint's
/// `nesting` rule allows one level, and a `CodingKeys` enum inside a nested
/// `ResponseFormat` would be two.
struct OpenAIChatRequest: Encodable {
    var model: String
    var messages: [OpenAIChatMessage]
    /// `nil` for a plain completion. Synthesized encoding uses `encodeIfPresent`,
    /// so the key is absent rather than null — which matters, because a null
    /// `response_format` is a 400.
    var responseFormat: OpenAIResponseFormat?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case responseFormat = "response_format"
    }
}

struct OpenAIChatMessage: Encodable {
    var role: String
    var content: String
}

/// The `json_schema` envelope. `strict` is fixed `true` — a connector that could
/// send `false` would quietly stop enforcing the schema. `name` has no default
/// because OpenAI rejects the envelope without it.
struct OpenAISchemaEnvelope: Encodable {
    var name: String
    var strict = true
    var schema: JSONSchemaObject
}

struct OpenAIResponseFormat: Encodable {
    var type = "json_schema"
    var jsonSchema: OpenAISchemaEnvelope

    enum CodingKeys: String, CodingKey {
        case type
        case jsonSchema = "json_schema"
    }
}

/// `GET /v1/models`. Only `id` is read; the rest of the payload (pricing,
/// ownership, creation date) drives nothing in the app.
struct OpenAIModelList: Decodable {
    struct Entry: Decodable {
        var id: String
    }

    var data: [Entry]
}

/// `POST /v1/chat/completions`. `refusal` is OpenAI's structured-output safety
/// channel: when the model declines, `content` is null and `refusal` carries the
/// explanation.
struct OpenAIChatResponse: Decodable {
    struct Message: Decodable {
        var content: String?
        var refusal: String?
    }

    struct Choice: Decodable {
        var message: Message
    }

    var choices: [Choice]
}
