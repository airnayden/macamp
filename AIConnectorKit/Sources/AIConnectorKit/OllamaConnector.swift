// OllamaConnector — the route to a locally-hosted Ollama server.
//
// The only connector with no credential at all: Ollama is a server the listener
// runs themselves, so ``AuthDescriptor/none(defaultHost:)`` applies and the entire
// configuration surface is one URL. That also makes it the connector that works on
// a Mac with no Apple Intelligence and no provider account — the headline case for
// the whole connector tier.
//
// ── WIRE FORMAT ────────────────────────────────────────────────────────────────
//
// Ollama REST API: https://github.com/ollama/ollama/blob/main/docs/api.md
// (the same reference is being migrated to https://docs.ollama.com/api)
//
//   GET  /api/tags   → { "models": [ { "name": "llama3.2:latest", … } ] }
//   POST /api/chat   → { "message": { "role": "assistant", "content": "…" }, … }
//
// Both completion methods ride `/api/chat`, not `/api/generate`. `/api/chat` takes
// a `system` turn as a first-class message, which is exactly what `instructions`
// is; `/api/generate` would force the connector to splice instructions into the
// prompt text and hope the model's own template cooperated.
//
// `stream: false` is sent on EVERY chat request. Ollama streams by default and
// answers a streaming request with newline-delimited JSON OBJECTS — which is not
// one JSON document, so a single `JSONDecoder.decode` over the body fails.
// Omitting the flag is therefore not "a slower path", it is a guaranteed
// ``ConnectorFailure/malformedResponse``.
//
// Structured output rides `format`, which accepts a full JSON-schema object (docs:
// "Structured outputs are supported by providing a JSON schema in the `format`
// parameter"). Ollama constrains DECODING against it server-side, so unlike
// Anthropic's forced-tool detour and OpenAI's `response_format` envelope there is
// nothing to unwrap: the assistant message content IS the JSON document.
//
// ── THE OPTIONAL BEARER (Ollama Cloud) ────────────────────────────────────────
//
// A self-hosted `ollama serve` has no authentication at all — which is why this
// connector's ``AuthDescriptor`` is ``AuthDescriptor/none(defaultHost:)`` and why
// it works on a Mac with no provider account. Ollama Cloud (`https://ollama.com`)
// speaks the SAME native API at the same paths and adds one requirement:
// `Authorization: Bearer <OLLAMA_API_KEY>` (ollama.com docs, verified 2026-08-24).
//
// So the key is OPTIONAL, not a second connector and not a mode switch. With no
// key the requests are byte-identical to what this connector has always sent; with
// one, the single header is added. Nothing else about the wire changes, which is
// what makes "point the host at ollama.com and paste a key" the whole of the Cloud
// story.
//
// The key is resolved at CALL time through a closure, like every other credential
// in this kit, so entering one in Preferences takes effect without a relaunch and
// no secret is ever held by this value type.
import Foundation

/// A configured route to one Ollama server.
///
/// Stateless and `Sendable` — it owns a host and a transport and nothing else, so
/// a settings change is expressed by building a new connector rather than mutating
/// a live one. That is what lets the composition root rebuild the whole AI graph
/// on a host edit without an in-flight call observing a half-applied change.
public struct OllamaConnector: AIProviderConnector {
    /// Where a stock `ollama serve` listens.
    ///
    /// `127.0.0.1` rather than `localhost`: `localhost` resolves through DNS and
    /// may hand back `::1` first, which fails against a server that bound IPv4
    /// only — surfacing as "connection refused" from a server that is plainly
    /// running. The numeric form removes the resolver from the picture entirely.
    public static let defaultHost: URL = {
        guard let url = URL(string: "http://127.0.0.1:11434") else {
            preconditionFailure("The default Ollama host is a compile-time literal and always parses.")
        }
        return url
    }()

    /// What `/api/tags` lets this connector honestly claim.
    ///
    /// `chat` is the floor every listed model meets. `structuredOutput` is a
    /// SERVER capability here rather than a model one — Ollama constrains decoding
    /// against `format` itself, so every model it serves obeys the schema.
    /// `toolUse` and `vision` genuinely are per-model and `/api/tags` does not
    /// report them; asserting either would be a guess, and ``ModelInfo`` reads an
    /// absent capability as "unstated", never as "incapable".
    public static let modelCapabilities: Set<ModelCapability> = [.chat, .structuredOutput]

    public let id = "ollama"
    public let displayName = "Ollama"

    /// The header an Ollama Cloud key rides in.
    public static let authorizationHeaderField = "Authorization"

    // `internal`, not `private`: `OllamaConnector+ToolLoop.swift` is a separate
    // FILE (SwiftLint's 400-line `file_length` ceiling forbids folding it in here),
    // and a `private` stored property is invisible across a file boundary. Nothing
    // outside this target can reach them, and no behaviour changes.
    let host: URL
    let apiKey: (@Sendable () async throws -> String)?
    let transport: any HTTPTransport

    /// - Parameters:
    ///   - host: The server root, e.g. `http://127.0.0.1:11434`. Endpoint paths are
    ///     APPENDED, so a reverse-proxy prefix (`https://box.lan/ollama`) works
    ///     without special handling.
    ///   - apiKey: An OPTIONAL Ollama Cloud key, resolved at call time. `nil` — the
    ///     default — sends exactly what a self-hosted server expects: no
    ///     `Authorization` header at all.
    ///   - transport: The one seam through which this connector reaches the
    ///     network. Injected so every test in the kit runs without a socket.
    public init(
        host: URL = OllamaConnector.defaultHost,
        apiKey: (@Sendable () async throws -> String)? = nil,
        transport: any HTTPTransport
    ) {
        self.host = host
        self.apiKey = apiKey
        self.transport = transport
    }

    /// Always ``AuthDescriptor/none(defaultHost:)``, and the payload is the STOCK
    /// address rather than this instance's `host`.
    ///
    /// The descriptor answers "what should the settings field be pre-filled with
    /// before the listener overrides it", which is a constant. Returning the
    /// configured host would make the placeholder equal to the value already
    /// typed, and the field would look filled in when it is not.
    public var authDescriptor: AuthDescriptor {
        .none(defaultHost: Self.defaultHost)
    }

    public func listModels() async throws -> [ModelInfo] {
        let response = try await perform(authorized(makeRequest(path: Endpoint.tags, body: nil)))
        let payload = try Self.decode(TagsPayload.self, from: response.body)
        return payload.models.compactMap(\.identifier).map {
            ModelInfo(id: $0, capabilities: Self.modelCapabilities)
        }
    }

    public func structuredCompletion(
        schema: JSONSchemaObject,
        instructions: String,
        prompt: String,
        model: String
    ) async throws -> Data {
        let content = try await chat(model: model, instructions: instructions, text: prompt, format: schema)
        // `format` is grammar-constrained decoding, NOT a guarantee: a model that
        // exhausts its token budget mid-object still answers 200 with truncated
        // JSON. Parsing here turns that into a taxonomy failure at the connector
        // boundary instead of a decode error surfacing inside the bridge, where
        // the caller has no way to tell it apart from a schema mismatch.
        let data = Data(content.utf8)
        guard (try? JSONSerialization.jsonObject(with: data)) != nil else {
            throw ConnectorFailure.malformedResponse
        }
        return data
    }

    public func completion(
        instructions: String,
        prompt: String,
        model: String
    ) async throws -> String {
        try await chat(model: model, instructions: instructions, text: prompt, format: nil)
    }
}

// MARK: - Chat

private extension OllamaConnector {
    /// One non-streaming `/api/chat` round-trip, returning the assistant's content.
    ///
    /// - Parameter format: The schema to constrain decoding with, or `nil` for an
    ///   unconstrained turn. Synthesized `Encodable` conformance encodes an
    ///   optional with `encodeIfPresent`, so `nil` omits the key entirely — which
    ///   is why both public completion methods share one request type.
    func chat(
        model: String,
        instructions: String,
        text: String,
        format: JSONSchemaObject?
    ) async throws -> String {
        let request = ChatRequest(
            model: model,
            messages: Self.messages(instructions: instructions, text: text),
            stream: false,
            format: format
        )
        let encoded = try Self.encode(request)
        let response = try await perform(authorized(makeRequest(path: Endpoint.chat, body: encoded)))
        let payload = try Self.decode(ChatPayload.self, from: response.body)
        let content = payload.message?.content ?? ""
        // Ollama answers `done_reason: "load"` (and an empty content) when it was
        // asked to warm a model rather than to say something. A caller that wanted
        // prose or JSON and got nothing has a contract violation, not a result.
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConnectorFailure.malformedResponse
        }
        return content
    }

    /// Builds the turn list, dropping an empty system turn.
    ///
    /// Several chat templates render a system block unconditionally once the role
    /// is present, so an empty `instructions` would prepend a blank block to the
    /// context instead of nothing at all.
    static func messages(instructions: String, text: String) -> [ChatRequest.Message] {
        var turns: [ChatRequest.Message] = []
        let framing = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !framing.isEmpty {
            turns.append(ChatRequest.Message(role: Role.system, content: framing))
        }
        turns.append(ChatRequest.Message(role: Role.user, content: text))
        return turns
    }
}

// MARK: - Transport

/// `internal` for the same reason as the stored properties above.
extension OllamaConnector {
    enum Endpoint {
        static let tags = "api/tags"
        static let chat = "api/chat"
    }

    enum Role {
        static let system = "system"
        static let user = "user"
    }

    /// How much of an error body is retained for diagnosis.
    static var maximumBodyCharacters: Int {
        512
    }

    func makeRequest(path: String, body: Data?) -> URLRequest {
        var request = URLRequest(url: host.appending(path: path))
        guard let body else { return request }
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    /// Adds the Ollama Cloud bearer when one is configured, and otherwise returns
    /// `request` UNCHANGED.
    ///
    /// A missing or failing key is deliberately NOT ``ConnectorFailure/unconfigured``
    /// here, unlike in the API-key connectors: a self-hosted server needs no key, so
    /// "there is no key" is the DEFAULT state of a perfectly working connector. An
    /// empty string is treated as absent for the same reason — the config sheet
    /// stores what was typed, and a cleared field must not send `Bearer `.
    func authorized(_ request: URLRequest) async -> URLRequest {
        guard let apiKey, let resolved = try? await apiKey() else { return request }
        let key = resolved.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.isEmpty == false else { return request }
        var authorized = request
        authorized.setValue("Bearer \(key)", forHTTPHeaderField: Self.authorizationHeaderField)
        return authorized
    }

    /// Sends, and converts anything that is not a usable 2xx into the taxonomy.
    ///
    /// The `catch` ladder exists even though ``HTTPTransport`` already promises to
    /// throw only ``ConnectorFailure``: ``AIProviderConnector`` makes totality the
    /// CONNECTOR's obligation, and a bespoke transport (a decorator, a test double
    /// in another app that lifts this target) is exactly the thing that would break
    /// the promise upstream.
    func perform(_ request: URLRequest) async throws -> HTTPResponse {
        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch let failure as ConnectorFailure {
            throw failure
        } catch is CancellationError {
            throw ConnectorFailure.cancelled
        } catch {
            throw ConnectorFailure.unreachable(underlying: ConnectorFailure.DiagnosticToken.transportFailure)
        }
        guard response.isSuccess else { throw Self.failure(for: response) }
        return response
    }

    /// A stock `ollama serve` has no authentication and no throttle, so 401/403 and
    /// 429 can only come from something in front of it — a reverse proxy, a tunnel,
    /// a shared box. Mapping them properly is what makes "Ollama behind nginx" a
    /// diagnosable configuration rather than an opaque `httpStatus`.
    static func failure(for response: HTTPResponse) -> ConnectorFailure {
        switch response.statusCode {
        case 401, 403:
            .authExpired
        case 429:
            .rateLimited(retryAfter: response.headerValue("Retry-After").flatMap { TimeInterval($0) })
        default:
            .httpStatus(
                response.statusCode,
                body: errorMessage(from: response.body),
                providerMessage: ConnectorFailure.sanitizedProviderMessage(in: response.body)
            )
        }
    }

    /// Ollama reports a failure as `{"error": "…"}`. Anything else — an HTML page
    /// from a proxy, an empty body — is surfaced as truncated text so the shell's
    /// diagnostics still have something to show.
    static func errorMessage(from body: Data) -> String? {
        if let payload = try? JSONDecoder().decode(ErrorPayload.self, from: body) {
            return String(payload.error.prefix(maximumBodyCharacters))
        }
        guard let text = String(bytes: body, encoding: .utf8), !text.isEmpty else { return nil }
        return String(text.prefix(maximumBodyCharacters))
    }

    static func decode<Payload: Decodable>(_ type: Payload.Type, from body: Data) throws -> Payload {
        do {
            return try JSONDecoder().decode(type, from: body)
        } catch {
            throw ConnectorFailure.malformedResponse
        }
    }

    /// `.sortedKeys` makes the request body byte-stable, which is what lets a
    /// recorded-request assertion compare exact JSON instead of re-parsing it;
    /// `.withoutEscapingSlashes` keeps a URL inside a schema `description` legible
    /// on the wire.
    ///
    /// The `nil` branch is unreachable by construction — ``ChatRequest`` is a
    /// closed value type over `String` / `Bool` / ``JSONSchemaObject``, none of
    /// which can fail to encode. It exists so this method stays inside the
    /// taxonomy rather than letting an `EncodingError` escape a connector.
    /// `fileprivate` because ``ChatRequest`` is: a member of an `internal`
    /// extension may not be more visible than its own parameter type.
    fileprivate static func encode(_ request: ChatRequest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let body = try? encoder.encode(request) else {
            throw ConnectorFailure.malformedResponse
        }
        return body
    }
}

// MARK: - Wire types

/// The `/api/chat` request body. Only the four fields MacAMP needs — Ollama's
/// `tools`, `think`, `options` and `keep_alive` have no surface in this app, and
/// modelling them would be four more fields to keep in sync with a moving API.
private struct ChatRequest: Encodable {
    struct Message: Encodable {
        var role: String
        var content: String
    }

    var model: String
    var messages: [Message]
    var stream: Bool
    var format: JSONSchemaObject?
}

/// The `/api/chat` response. `message` is optional because Ollama omits it on some
/// terminal frames (a history-only final object carries statistics and no turn).
private struct ChatPayload: Decodable {
    struct Message: Decodable {
        var content: String
    }

    var message: Message?
}

/// The `/api/tags` response. Every other field the endpoint sends — `size`,
/// `digest`, `modified_at`, `details` — is deliberately unmodelled: none of it
/// drives a selector, and `JSONDecoder` ignores unknown keys, so a server that
/// grows a field cannot break model listing.
private struct TagsPayload: Decodable {
    struct Entry: Decodable {
        var name: String?
        var model: String?

        /// The string sent back as `model` on a chat request.
        ///
        /// `name` is the field every Ollama version has emitted; `model` arrived
        /// later carrying the identical `family:tag` value. Preferring `name` with
        /// a fallback keeps both an old server and a future one that drops the
        /// legacy field from listing blank models.
        var identifier: String? {
            if let name, !name.isEmpty { return name }
            if let model, !model.isEmpty { return model }
            return nil
        }
    }

    var models: [Entry]
}

/// Ollama's error envelope, e.g. `{"error": "model \"x\" not found…"}`.
private struct ErrorPayload: Decodable {
    var error: String
}
