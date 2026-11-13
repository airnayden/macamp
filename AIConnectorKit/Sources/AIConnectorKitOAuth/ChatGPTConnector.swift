// ChatGPTConnector — the subscription-backed route to ChatGPT.
//
// ── THE DETERMINATION, UP FRONT (REVISED 2026-08-24) ──────────────────────────
//
// This connector shipped DISABLED from 2026-08-21. It is now LIVE:
// ``isUpstreamFlowVerified`` is `true`, so ``registrationStatus`` is the ordinary
// not-signed-in `.unconfigured`. One thing changed, and it was not the code — on
// **2026-08-21** OpenAI's Codex lead publicly endorsed third-party open-source
// clients using "Sign in with ChatGPT" per-user OAuth. That answers the objection
// the original determination rested on:
//
//   * IMPERSONATION WAS THE BLOCKER, AND IT IS GONE. Reaching the endpoint needs
//     `originator=codex_cli_rs`; before the endorsement, sending it meant claiming
//     to be OpenAI's own binary, which this implementation would not do (it sent
//     `originator=macamp` and consequently could not complete the flow). With an
//     endorsed third-party path, sending the value the endorsed flow expects is
//     using a sanctioned integration, not forging an identity.
//   * BOT MITIGATION IS NOW A RUNTIME FAILURE MODE, NOT A SHIPPING BLOCKER. The
//     `chatgpt.com/backend-api/*` edge can still answer a managed challenge, and
//     ``URLSessionTransport`` still cannot persist a `cf_clearance` cookie (it is
//     `.ephemeral` with cookies off — a deliberate privacy decision). So the
//     challenge is DETECTED and reported as ``ConnectorFailure/unreachable`` with
//     ``botMitigationToken`` rather than as "your session expired", which is the
//     honest thing to tell a listener whose credential is perfectly fine.
//   * THE STREAMING DIVERGENCE IS OVER — MEASURED 2026-09-06. `stream: false`
//     WAS a supported Responses shape, and this connector sent it; the backend
//     now answers a non-streaming POST with HTTP 400 `{"detail":"Stream must be
//     set to true"}`. So the WIRE is SSE. The CONNECTOR is still single-shot:
//     ``HTTPTransport`` is request/response and buffers the whole body, which
//     ``ChatGPTConnector/completedResponse(in:)`` reduces to the terminal
//     `response.completed` object so every decoder below it runs unchanged, and
//     the same `withDeadline` still bounds the call. The same day's second
//     measurement — `/models` now requires `client_version`, which also GATES
//     the catalog — lives beside it in `ChatGPTBackendContract.swift`.
//
// The disabled machinery is KEPT, not deleted: ``disabledReason`` and the
// ``registrationStatus`` branch are how a future breakage is expressed without
// rewriting a connector, which is exactly the situation the 2026-08-21 revision
// was in.
//
// ── WHERE THE REQUEST SHAPE COMES FROM ────────────────────────────────────────
//
// The subscription surface speaks the RESPONSES API, not Chat Completions, at
// `https://chatgpt.com/backend-api/codex` — never `api.openai.com`, which serves
// platform API keys. Two headers are mandatory: `Authorization: Bearer <access
// token>` and `ChatGPT-Account-Id`, the latter derived from the credential's own
// JWT claims so nothing has to persist it.
//
// STRUCTURED OUTPUT IS SUPPORTED, and rides `text.format` — not `response_format`,
// which is the Chat Completions dialect and a 400 here. The envelope is otherwise
// todo 8's discipline exactly: `type: "json_schema"`, a required `name`,
// `strict: true`, and a schema ``JSONSchemaObject`` already encodes to strict-mode
// rules (`additionalProperties: false`, every property in `required`, optionals as
// nullable unions). The client-side brace extraction in ``Self/jsonObject(in:)``
// runs anyway, because a model that wraps its object in prose is a failure mode no
// `strict` flag has ever fully closed and recovering is free.
import AIConnectorKit
import Foundation

/// A route to ChatGPT authenticated by a subscription OAuth credential.
///
/// Reads its bearer token from a provider — in the shell that is
/// ``OAuthCredentialEngine/accessToken()``, so expiry, refresh and rotation are
/// handled before this type ever sees a string.
public struct ChatGPTConnector: AIProviderConnector {
    /// The API root for a ChatGPT-subscription credential.
    ///
    /// NOT `api.openai.com/v1` — that host serves platform API keys. A
    /// subscription token is accepted only by the ChatGPT backend, which is why
    /// ``OpenAIConnector`` and this type cannot be the same connector with two
    /// auth modes.
    ///
    /// A `String` rather than a `URL` because Swift has no non-optional URL
    /// literal and `force_unwrapping` is an error under SwiftLint `--strict`.
    public static let baseURLString = "https://chatgpt.com/backend-api/codex"

    /// The machine-readable status token this connector registers with WHEN it is
    /// disabled.
    ///
    /// Retained after the 2026-08-24 flip to live, on purpose: this is the shape a
    /// future breakage takes, and re-deriving it would mean rewriting a connector
    /// under time pressure. Deliberately the CANONICAL constant rather than a
    /// matching literal — a duplicated string would drift the first time either
    /// side was reworded, and the shell's localized mapping is keyed on it. Never
    /// user-facing copy and never rendered raw.
    public static let disabledReason = ConnectorStatus.DisabledReason.upstreamFlowUnavailable

    /// The status the composition root registers this connector with.
    ///
    /// Exposed as a value so the registration site states no policy of its own.
    /// The whole determination lives HERE, next to the evidence for it.
    public static var registrationStatus: ConnectorStatus {
        isUpstreamFlowVerified ? .unconfigured : .disabled(reason: disabledReason)
    }

    /// Whether the upstream flow is confirmed drivable.
    ///
    /// `true` since **2026-08-24**. It was `false` from 2026-08-21 because the flow
    /// could not be completed without claiming to be OpenAI's own client; the
    /// 2026-08-21 endorsement of third-party "Sign in with ChatGPT" clients removed
    /// that objection. See this file's header.
    ///
    /// A constant rather than a comment so the composition root can branch on it
    /// and a test can pin the shipped answer: this and the registry entry move
    /// together, and the suite says so if only one of them does.
    public static let isUpstreamFlowVerified = true

    /// The `text.format.name` sent with every structured call. REQUIRED by the
    /// envelope; a machine identifier the listener never sees.
    public static let structuredOutputName = "playlist_query"

    /// ``SecretStore`` account for this provider's credential blob, inside
    /// ``ConnectorOAuthInfo/keychainService``.
    ///
    /// Lives here rather than beside ``OAuthCredentialEngine/claudeAccount``
    /// because the engine is provider-agnostic and gains nothing from knowing
    /// its tenants. Composition passes it as the engine's `account:`; it must
    /// never change once shipped, or every signed-in listener is stranded.
    public static let credentialAccount = "chatgpt"

    /// ``ConnectorFailure/unreachable(underlying:)`` payload for a bot-mitigation
    /// challenge.
    ///
    /// Its own token because the shell must not tell a listener "your session
    /// expired" when the truth is "an edge network refused to believe you are a
    /// browser" — the first prompts a pointless re-login, the second does not.
    public static let botMitigationToken = "bot-mitigation-challenge"

    /// How much of a FAILING response body is retained for diagnosis.
    static let maxDiagnosticBodyLength = 512

    public let id = "chatgpt"
    public let displayName = "ChatGPT"
    public let authDescriptor = AuthDescriptor.subscription

    // `internal`, not `private`: `ChatGPTConnector+ToolLoop.swift` is a separate
    // FILE (SwiftLint's 400-line `file_length` ceiling forbids folding it in here),
    // and a `private` stored property is invisible across a file boundary. Nothing
    // outside this target can reach them, and no behaviour changes.
    let bearerToken: @Sendable () async throws -> String
    let accountID: @Sendable () async throws -> String?
    let signedIn: (@Sendable () async -> Bool)?
    let transport: any HTTPTransport

    /// - Parameters:
    ///   - bearerToken: Resolves the access token at call time. In the shell this
    ///     is `{ try await engine.accessToken() }`, so a stale token refreshes
    ///     before the request rather than after a 401.
    ///   - accountID: Overrides the `ChatGPT-Account-Id` header. `nil` — the
    ///     default — means "derive it from the token's own claims", which is
    ///     always current and needs nothing persisted.
    ///   - signedIn: A CHEAP "is a credential stored?" answer, without a refresh
    ///     or a request. In the shell this is
    ///     `{ await engine.hasStoredCredentials() }`. `nil` falls back to resolving
    ///     the token, which is correct but costs a store read and possibly a
    ///     refresh — see ``isSignedIn()``.
    ///   - transport: The HTTP seam. Injected so suites script responses instead
    ///     of touching the network.
    public init(
        bearerToken: @escaping @Sendable () async throws -> String,
        accountID: @escaping @Sendable () async throws -> String? = { nil },
        signedIn: (@Sendable () async -> Bool)? = nil,
        transport: any HTTPTransport
    ) {
        self.bearerToken = bearerToken
        self.accountID = accountID
        self.signedIn = signedIn
        self.transport = transport
    }

    /// Whether a credential is stored, WITHOUT decoding, refreshing, or calling
    /// the provider.
    ///
    /// The gate a registry probe wants now that this connector is live: an
    /// unconfigured connector must cost zero round-trips, and `listModels()` on
    /// one that was never signed into would spend a request to learn what this
    /// already knows. Mirrors ``ClaudeSubscriptionConnector/isSignedIn()``.
    public func isSignedIn() async -> Bool {
        if let signedIn {
            return await signedIn()
        }
        guard let token = try? await bearerToken() else { return false }
        return token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    /// The models this subscription can reach.
    ///
    /// The catalog endpoint is a sibling of the completion endpoint on the same
    /// backend root. Its payload shape is the loosest thing this connector
    /// touches — hence ``ChatGPTModelList``'s two accepted spellings and the
    /// drift test that pins an unrecognised shape to
    /// ``ConnectorFailure/malformedResponse`` rather than a crash.
    public func listModels() async throws -> [ModelInfo] {
        let request = try await authorizedRequest(Self.modelsPath, method: "GET")
        let response = try await transport.send(request)
        try Self.validate(response)
        let payload: ChatGPTModelList = try Self.decode(response.body)
        return payload.identifiers.map { ModelInfo(id: $0) }
    }

    /// Schema-constrained JSON, via the Responses API's `text.format`.
    ///
    /// Structured output IS supported on this surface — same request type serves
    /// the platform and the subscription backends upstream — so this takes todo
    /// 8's route rather than the plain-completion fallback. The client-side
    /// extraction in ``Self/jsonObject(in:)`` still runs, because a model that
    /// wraps its object in prose is a failure mode no `strict` flag has ever
    /// fully closed, and recovering is free.
    public func structuredCompletion(
        schema: JSONSchemaObject,
        instructions: String,
        prompt: String,
        model: String
    ) async throws -> Data {
        let body = ChatGPTResponsesRequest(
            model: model,
            instructions: instructions,
            input: [ChatGPTInputItem(text: prompt)],
            text: ChatGPTTextControls(
                format: ChatGPTTextFormat(name: Self.structuredOutputName, schema: schema)
            )
        )
        let text = try await respond(body)
        guard let json = Self.jsonObject(in: text) else {
            throw ConnectorFailure.malformedResponse
        }
        return json
    }

    public func completion(instructions: String, prompt: String, model: String) async throws -> String {
        let body = ChatGPTResponsesRequest(
            model: model,
            instructions: instructions,
            input: [ChatGPTInputItem(text: prompt)],
            text: nil
        )
        // Trimmed, not capped: callers own length limits, but a leading newline
        // in a playlist name is never what anyone meant.
        return try await respond(body).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Round trip

private extension ChatGPTConnector {
    /// One `/responses` round-trip, returning the assistant's text.
    func respond(_ body: ChatGPTResponsesRequest) async throws -> String {
        let request = try await authorizedRequest(
            Self.responsesPath,
            method: "POST",
            accept: Self.streamAccept,
            body: body
        )
        let response = try await transport.send(request)
        try Self.validate(response)
        let payload: ChatGPTResponsesReply = try Self.decode(Self.completedResponse(in: response.body))
        guard let text = payload.text, text.isEmpty == false else {
            throw ConnectorFailure.malformedResponse
        }
        return text
    }

    /// The first balanced top-level JSON object in `text`, as bytes.
    ///
    /// Brace COUNTING, not a regex and not `firstIndex(of: "}")`: the canonical
    /// query schema nests objects, so the first closing brace is routinely not
    /// the last one. Braces inside string literals are skipped, escape sequences
    /// included, or a genre named `{jazz` would end the object early.
    static func jsonObject(in text: String) -> Data? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        for index in text[start...].indices {
            let character = text[index]
            if escaped {
                escaped = false
            } else if character == "\\", inString {
                escaped = true
            } else if character == "\"" {
                inString.toggle()
            } else if inString == false, character == "{" {
                depth += 1
            } else if inString == false, character == "}" {
                depth -= 1
                if depth == 0 {
                    return Data(text[start ... index].utf8)
                }
            }
        }
        return nil
    }
}

// MARK: - Requests

/// `internal` for the same reason as the stored properties above.
extension ChatGPTConnector {
    /// Builds a request with every header the subscription surface requires.
    ///
    /// `ChatGPT-Account-Id` names the workspace the token belongs to; the backend
    /// rejects a request without it on multi-workspace accounts. It is derived
    /// from the token's own claims by default, so nothing has to persist it and
    /// it can never go stale relative to the credential.
    func authorizedRequest(
        _ path: String,
        method: String,
        accept: String = ChatGPTConnector.jsonAccept,
        body: (some Encodable)? = ChatGPTResponsesRequest?.none
    ) async throws -> URLRequest {
        let token = try await resolvedToken()
        guard let url = URL(string: Self.baseURLString + path) else {
            throw ConnectorFailure.unconfigured
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if let account = try await resolvedAccountID(for: token) {
            request.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try Self.encode(body)
        }
        return request
    }

    /// Resolves the bearer token, mapping every "not signed in yet" shape onto
    /// ``ConnectorFailure/unconfigured`` BEFORE any transport call — the
    /// registry's probe relies on an unconfigured connector performing zero
    /// requests.
    func resolvedToken() async throws -> String {
        let resolved: String
        do {
            resolved = try await bearerToken()
        } catch let failure as ConnectorFailure {
            throw failure
        } catch is CancellationError {
            throw ConnectorFailure.cancelled
        } catch {
            throw ConnectorFailure.unconfigured
        }
        let token = resolved.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.isEmpty == false else { throw ConnectorFailure.unconfigured }
        return token
    }

    /// The override when one was supplied, else the token's `chatgpt_account_id`
    /// claim. A failing override is not fatal: the header is omitted and the
    /// backend decides, which is strictly better than refusing to call at all.
    func resolvedAccountID(for token: String) async throws -> String? {
        // `try?` flattens the double optional: a THROWN provider and a provider
        // that returned nil both land here as "no override", which is the same
        // outcome and needs no distinction.
        if let override = try? await accountID(), override.isEmpty == false {
            return override
        }
        return ChatGPTOAuthFlow.accountIdentifier(inJWT: token)
    }
}
