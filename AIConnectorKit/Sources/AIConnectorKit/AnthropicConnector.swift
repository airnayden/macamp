// AnthropicConnector — Anthropic's Messages API, in both credential modes.
//
// ── TWO CREDENTIAL MODES, ONE WIRE PROTOCOL ────────────────────────────────────
//
// Anthropic accepts a console API key in `x-api-key` and a consumer sign-in token
// in `Authorization: Bearer …`. Everything BELOW that header — endpoints, request
// bodies, response shapes, failure statuses — is identical, so the two modes are a
// header-formatting choice, not two connectors. ``AnthropicAuth`` is that choice,
// and it is the whole of the difference. The bearer case ships NOW, fully
// implemented and tested, even though the OAuth engine that feeds it lands later:
// a mode bolted on afterwards arrives as a second code path, and the point is that
// there is only one. The subscription connector is then a wrapper supplying a
// different provider closure.
//
// ── REFERENCES (read 2026-08-21; these now serve from `platform.claude.com`) ────
//
//   Messages API   https://docs.anthropic.com/en/api/messages
//   Tool use       https://docs.anthropic.com/en/docs/agents-and-tools/tool-use/overview
//   List models    https://docs.anthropic.com/en/api/models-list
//
// ── THREE FIELDS THAT ARE A 400 WHEN OMITTED ───────────────────────────────────
//
//   `max_tokens`         REQUIRED top level on `/v1/messages`. There is no default.
//   `tool_choice.name`   REQUIRED once `tool_choice.type` is `tool`.
//   `anthropic-version`  REQUIRED header, on every endpoint.
//
// A fourth trap is silent rather than fatal: system framing is the TOP-LEVEL
// `system` field, NOT a `role: "system"` message — that role is rejected outright.
import Foundation

// MARK: - Credential

/// How an ``AnthropicConnector`` proves who it is.
///
/// Both cases carry an `async throws` PROVIDER rather than a stored string. That
/// buys two things at once: a credential is fetched at call time and never sits in
/// a value type that could be logged, and a *refreshing* token source — an OAuth
/// engine that may mint, rotate, or fail — fits the same shape as a static
/// Keychain read, with no branching at the call site.
///
/// A provider that throws a ``ConnectorFailure`` has it forwarded UNCHANGED, which
/// is how a token source says `.authExpired` precisely. Any other error becomes
/// ``ConnectorFailure/unconfigured``: no transport call was made, and the honest
/// reading of "the credential could not be produced" is "this is not set up".
public enum AnthropicAuth: Sendable {
    /// A console API key, sent in `x-api-key`.
    case apiKey(provider: @Sendable () async throws -> String)

    /// A consumer sign-in token, sent as `Authorization: Bearer …`.
    case bearer(provider: @Sendable () async throws -> String)

    /// The header field the API-key mode writes into.
    public static let apiKeyHeaderField = "x-api-key"

    /// The header field the bearer mode writes into.
    public static let bearerHeaderField = "Authorization"
}

extension AnthropicAuth {
    var headerField: String {
        switch self {
        case .apiKey: Self.apiKeyHeaderField
        case .bearer: Self.bearerHeaderField
        }
    }

    /// What the connector reports to the settings UI and the registry.
    ///
    /// `.bearer` maps to ``AuthDescriptor/subscription`` because that is what the
    /// mode *means*: a token minted by a sign-in flow, not a value the listener
    /// pastes. Both report `requiresStoredSecret == true`, so registry behaviour is
    /// identical either way.
    var descriptor: AuthDescriptor {
        switch self {
        case .apiKey: .apiKey(header: Self.apiKeyHeaderField)
        case .bearer: .subscription
        }
    }

    /// Resolves the credential and formats it for ``headerField``.
    func headerValue() async throws -> String {
        let secret = try await resolvedSecret()
        switch self {
        case .apiKey: return secret
        case .bearer: return "Bearer \(secret)"
        }
    }

    private func resolvedSecret() async throws -> String {
        let provider: @Sendable () async throws -> String
        switch self {
        case let .apiKey(value), let .bearer(value): provider = value
        }
        let secret: String
        do {
            secret = try await provider()
        } catch let failure as ConnectorFailure {
            throw failure
        } catch is CancellationError {
            throw ConnectorFailure.cancelled
        } catch {
            throw ConnectorFailure.unconfigured
        }
        // A blank key is not a key. Sending it spends a round-trip to be told 401,
        // which reads as "your key expired" rather than "you never entered one".
        guard !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConnectorFailure.unconfigured
        }
        return secret
    }
}

// MARK: - Connector

/// Anthropic's Messages API, in either credential mode.
public struct AnthropicConnector: AIProviderConnector {
    /// Persisted in settings and used as the Keychain account namespace.
    public static let connectorID = "anthropic"

    /// Pinned, not tracked: Anthropic versions its wire format by this header, so
    /// following the latest automatically would change the contract under the
    /// parsers below without a code change.
    public static let anthropicVersion = "2023-06-01"

    /// The forced tool's name. REQUIRED inside `tool_choice` when its type is
    /// `tool`, and matched against the returned block's `name` on the way back —
    /// so a stray tool call can never be mistaken for the answer.
    public static let structuredToolName = "emit_playlist_query"

    /// `max_tokens` is a REQUIRED top-level field on `/v1/messages`; omitting it is
    /// a 400 and the endpoint has no default. 4096 covers a query object with room
    /// to spare — the tool schema, not this ceiling, bounds the shape.
    public static let maxTokensForStructuredCompletion = 4096

    /// The same ceiling for prose. Naming and narration cap themselves; this is
    /// only the wire-level guard against an unbounded generation.
    public static let maxTokensForCompletion = 4096

    /// The production host.
    public static let defaultBaseURL: URL = {
        guard let url = URL(string: "https://api.anthropic.com") else {
            // A compile-time constant. A nil here is a typo in this file, not a
            // runtime condition any caller could recover from.
            preconditionFailure("The Anthropic base URL literal is malformed.")
        }
        return url
    }()

    static let versionHeaderField = "anthropic-version"
    static let modelsPath = "v1/models"
    static let messagesPath = "v1/messages"

    /// How much of a failing response body is kept for diagnosis.
    static let maxDiagnosticBodyCharacters = 512

    // `internal`, not `private`: `AnthropicConnector+ToolLoop.swift` is a separate
    // FILE (SwiftLint's 400-line `file_length` ceiling forbids folding it in here),
    // and a `private` stored property is invisible across a file boundary. Nothing
    // outside this target can reach them, and no behaviour changes.
    let auth: AnthropicAuth
    let transport: any HTTPTransport
    let baseURL: URL
    let systemPrefix: String?

    /// - Parameters:
    ///   - auth: Which credential to send, and how to obtain it.
    ///   - transport: The single seam through which every byte leaves.
    ///   - baseURL: Overridable for a proxy; the default is the production host.
    ///   - systemPrefix: An identity line the provider requires as its OWN first
    ///     `system` block. `nil` — the API-key route — sends the plain-string
    ///     `system` field instead. See ``AnthropicSystemPrompt``.
    public init(
        auth: AnthropicAuth,
        transport: any HTTPTransport,
        baseURL: URL = AnthropicConnector.defaultBaseURL,
        systemPrefix: String? = nil
    ) {
        self.auth = auth
        self.transport = transport
        self.baseURL = baseURL
        self.systemPrefix = systemPrefix
    }

    public var id: String {
        Self.connectorID
    }

    /// Brand name — never localized, rendered `Text(verbatim:)` by the shells.
    public var displayName: String {
        "Anthropic Claude"
    }

    public var authDescriptor: AuthDescriptor {
        auth.descriptor
    }

    public func listModels() async throws -> [ModelInfo] {
        let request = try await makeRequest(path: Self.modelsPath, method: "GET", body: nil)
        let response = try await transport.send(request)
        try Self.throwIfFailed(response)
        guard let payload = try? JSONDecoder().decode(AnthropicModelsPayload.self, from: response.body) else {
            throw ConnectorFailure.malformedResponse
        }
        return payload.data.map(\.modelInfo)
    }

    public func structuredCompletion(
        schema: JSONSchemaObject,
        instructions: String,
        prompt: String,
        model: String
    ) async throws -> Data {
        let tool = AnthropicTool(
            name: Self.structuredToolName,
            description: Self.structuredToolDescription,
            inputSchema: schema
        )
        let body = AnthropicMessagesRequest(
            model: model,
            maxTokens: Self.maxTokensForStructuredCompletion,
            system: AnthropicSystemPrompt.value(prefix: systemPrefix, instructions: instructions),
            messages: [AnthropicMessage(role: "user", content: prompt)],
            tools: [tool],
            toolChoice: AnthropicToolChoice(type: AnthropicToolChoice.forcedType, name: Self.structuredToolName)
        )
        let response = try await sendMessages(body)
        guard let input = Self.toolInput(named: Self.structuredToolName, in: response.body) else {
            throw ConnectorFailure.malformedResponse
        }
        return input
    }

    public func completion(instructions: String, prompt: String, model: String) async throws -> String {
        let body = AnthropicMessagesRequest(
            model: model,
            maxTokens: Self.maxTokensForCompletion,
            system: AnthropicSystemPrompt.value(prefix: systemPrefix, instructions: instructions),
            messages: [AnthropicMessage(role: "user", content: prompt)],
            tools: nil,
            toolChoice: nil
        )
        let response = try await sendMessages(body)
        guard let text = Self.joinedText(in: response.body) else {
            throw ConnectorFailure.malformedResponse
        }
        return text
    }
}

// MARK: - Requests

/// `internal` for the same reason as the stored properties above.
extension AnthropicConnector {
    /// What the forced tool tells the model it is for. Provider-facing prose that
    /// never reaches a screen, so it stays out of String Catalogs.
    static let structuredToolDescription =
        "Emit the requested structured result. Call this tool exactly once and fill every property of its schema."

    func makeRequest(path: String, method: String, body: Data?) async throws -> URLRequest {
        let credential = try await auth.headerValue()
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue(credential, forHTTPHeaderField: auth.headerField)
        request.setValue(Self.anthropicVersion, forHTTPHeaderField: Self.versionHeaderField)
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = body
        }
        return request
    }

    func sendMessages(_ body: AnthropicMessagesRequest) async throws -> HTTPResponse {
        let encoded: Data
        do {
            encoded = try Self.makeEncoder().encode(body)
        } catch {
            // Unreachable with the shapes above — `JSONEncoder` only throws on
            // non-finite numbers, which this body cannot contain. Mapped rather
            // than trapped so a future schema change degrades instead of crashing.
            throw ConnectorFailure.malformedResponse
        }
        let request = try await makeRequest(path: Self.messagesPath, method: "POST", body: encoded)
        let response = try await transport.send(request)
        try Self.throwIfFailed(response)
        return response
    }

    /// `.sortedKeys` is what makes a recorded-request assertion byte-stable — key
    /// order inside a keyed container is otherwise an implementation detail.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

// MARK: - Failure mapping

extension AnthropicConnector {
    /// Maps a non-2xx answer onto the taxonomy.
    ///
    /// 403 joins 401 on ``ConnectorFailure/authExpired``: Anthropic returns it for a
    /// revoked or permission-less key, and retrying with the same secret cannot
    /// help — exactly what that case means. Everything else that is not a 429 lands
    /// on ``ConnectorFailure/httpStatus(_:body:)``, 5xx included.
    static func throwIfFailed(_ response: HTTPResponse) throws {
        guard !response.isSuccess else { return }
        switch response.statusCode {
        case 401, 403:
            throw ConnectorFailure.authExpired
        case 429:
            throw ConnectorFailure.rateLimited(retryAfter: retryAfter(in: response))
        default:
            throw ConnectorFailure.httpStatus(
                response.statusCode,
                body: diagnosticBody(of: response),
                providerMessage: ConnectorFailure.sanitizedProviderMessage(in: response.body)
            )
        }
    }

    /// Parses `retry-after` as delta-seconds, the form Anthropic sends.
    ///
    /// The HTTP-date form is deliberately NOT parsed: it would need a locale-fixed
    /// formatter for a value this provider does not emit, and the taxonomy already
    /// documents `nil` as "nothing parseable arrived". Negative and non-finite
    /// values are treated the same way.
    static func retryAfter(in response: HTTPResponse) -> TimeInterval? {
        guard let raw = response.headerValue("retry-after") else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let seconds = TimeInterval(trimmed), seconds.isFinite, seconds >= 0 else { return nil }
        return seconds
    }

    /// A truncated copy of the provider's error payload — the RESPONSE body only,
    /// never the request, which carries the credential.
    static func diagnosticBody(of response: HTTPResponse) -> String? {
        guard let text = String(data: response.body, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxDiagnosticBodyCharacters))
    }
}

// MARK: - Response parsing

extension AnthropicConnector {
    /// The `input` of the forced tool's `tool_use` block, re-serialized.
    ///
    /// `JSONSerialization` rather than a `Decodable` mirror because `input` is
    /// caller-defined JSON the kit has no type for — the bridge decodes it. Output
    /// is `.sortedKeys`, so the bytes a test asserts on are stable.
    static func toolInput(named toolName: String, in body: Data) -> Data? {
        guard let blocks = contentBlocks(in: body) else { return nil }
        let match = blocks.first {
            $0["type"] as? String == "tool_use" && $0["name"] as? String == toolName
        }
        guard let input = match?["input"] as? [String: Any] else { return nil }
        return try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// Every `text` block, concatenated. Unknown block types are skipped rather
    /// than rejected: a response may legitimately carry blocks this connector never
    /// asked for, and dropping the prose over one would be a regression.
    static func joinedText(in body: Data) -> String? {
        guard let blocks = contentBlocks(in: body) else { return nil }
        let text = blocks
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        return text.isEmpty ? nil : text
    }

    private static func contentBlocks(in body: Data) -> [[String: Any]]? {
        guard
            let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
            let content = root["content"] as? [[String: Any]]
        else {
            return nil
        }
        return content
    }
}
