// ClaudeSubscriptionConnector — the Pro/Max sign-in route onto the Messages API.
//
// ── WHY THIS WRAPS `AnthropicConnector` INSTEAD OF ALIASING IT ─────────────────
//
// Anthropic's subscription route speaks the SAME wire protocol as the console
// API-key route, so the request/response code must not be duplicated — but the
// two routes are DIFFERENT CONNECTORS to everything above them. `id` is both the
// settings key and the Keychain account namespace
// (``ConnectorSecretService/name(forConnectorID:)``), and `AnthropicConnector.id`
// is `"anthropic"` in both of its credential modes. A `typealias` — or anything
// else that inherited that `id` — would make a signed-in subscription and a
// pasted API key fight over one stored secret: configuring either would silently
// evict the other. So this type COMPOSES the connector and owns its own identity,
// `"claude-subscription"`, and its own credential store (the engine's blob, in a
// different Keychain service entirely).
//
// ── THE THREE THINGS THE SUBSCRIPTION ROUTE NEEDS THAT AN API KEY DOES NOT ─────
//
//   1. `Authorization: Bearer <token>` instead of `x-api-key` — already a mode on
//      ``AnthropicAuth``, fed here by ``OAuthCredentialEngine/accessToken()``.
//   2. `anthropic-beta: oauth-2025-04-20` — the flag that AUTHORISES a bearer
//      token against `/v1/messages` at all. Injected by a transport decorator
//      (below), because the base connector has no extra-header seam and must not
//      grow one for a mode that is not its own.
//   3. A system prompt whose FIRST BLOCK is the Claude Code identity string —
//      a discrete block, NOT a prefix concatenated into one string. The OAuth
//      edge refuses anything else, and disguises the refusal as a 429. Measured
//      2026-09-06; the evidence lives on ``AnthropicSystemPrompt``.
//
// Both (2) and (3) are UNOFFICIAL, undocumented constants on a surface Anthropic
// moves without notice, so both are injectable — exactly the discipline
// ``OAuthEndpointConfiguration`` applies to the endpoints themselves.
//
// ── SOURCES (read 2026-08-21) ─────────────────────────────────────────────────
//
//   `oauth-2025-04-20`   FIRST-PARTY: `anthropics/anthropic-sdk-python`
//                        `src/anthropic/lib/credentials/_auth.py` injects exactly
//                        this flag beside `Authorization: Bearer`, and names it
//                        "the *API* beta … which unlocks `Authorization: Bearer`
//                        auth on the API". Corroborated by `musistudio/claude-code-router`,
//                        `headroomlabs-ai/headroom`, `Kuberwastaken/claurst`.
//   `claude-code-20250219` COMMUNITY-EVIDENCED, and SENT BY DEFAULT since the
//                        fingerprinting-era 400s. `bytedance/deer-flow` and
//                        `akitaonrails/ai-memory` send it beside the API beta;
//                        the official SDK does NOT, so this default is
//                        deliberately NOT first-party-evidenced — it is a
//                        MITIGATION, adopted because the edge began refusing
//                        otherwise-valid requests with a 400 that blames usage
//                        while the quota is healthy
//                        (`griffinmartin/opencode-claude-auth#148` lineage). The
//                        working theory that fits the evidence: the edge
//                        attributes a request to Claude Code by the WHOLE client
//                        fingerprint — the beta list AND the system block — not
//                        by the bearer beta alone. Still a parameter, so a
//                        future measurement that clears the minimal set narrows
//                        it back without touching a call site.
//   identity preamble    `You are Claude Code, Anthropic's official CLI for Claude.`
//                        — Claude Code's own `DEFAULT_PREFIX`, and prepended by
//                        every independent OAuth client checked: `zgsm-ai/costrict`,
//                        `snipeship/ccflare`, `superagent-ai/vibekit`,
//                        `org2AI/ORG2`, `mateaix/mateclaw` ("Magic identity prefix
//                        Anthropic's OAuth edge requires in the system prompt").
//
// ── THE 401 CONTRACT: EXACTLY ONE RETRY ───────────────────────────────────────
//
// A 401 means the token the engine handed out was rejected even though our clock
// believed it fresh — revoked, or rotated by another client. The answer is ONE
// ``OAuthCredentialEngine/forceRefresh()`` and ONE retry. Never a loop: a
// permanently dead session would otherwise hammer the token endpoint forever, and
// the ladder above swallows the failure anyway, so the listener would see nothing
// but a stalled assistant. A second `.authExpired` surfaces unchanged.
import AIConnectorKit
import Foundation

/// Anthropic's Messages API, authenticated by a Claude Pro/Max subscription.
///
/// Construct one per signed-in engine. Everything mutable lives in the engine, so
/// this value is cheap to rebuild whenever composition rebuilds the AI graph.
public struct ClaudeSubscriptionConnector: AIProviderConnector {
    /// Persisted in settings, and DELIBERATELY not `AnthropicConnector.connectorID`
    /// — see this file's header.
    public static let connectorID = "claude-subscription"

    /// The `anthropic-beta` feature that unlocks bearer auth on `/v1/messages`.
    public static let oauthAPIBeta = "oauth-2025-04-20"

    /// The additional feature the Claude Code CLI sends. SENT BY DEFAULT, beside
    /// ``oauthAPIBeta``, as a fingerprinting-era mitigation — see this file's
    /// header. COMMUNITY-EVIDENCED, not SDK-evidenced: the official SDK's OAuth
    /// path still injects ``oauthAPIBeta`` alone, so the pair is what independent
    /// clients send rather than what Anthropic documents. Narrow the default back
    /// through `betaFeatures` if a measurement ever clears the minimal set.
    public static let claudeCodeBeta = "claude-code-20250219"

    /// The `anthropic-beta` list every request carries unless a caller overrides
    /// it. BOTH tokens: see ``claudeCodeBeta``.
    public static let defaultBetaFeatures = [oauthAPIBeta, claudeCodeBeta]

    /// Header carrying the beta feature list.
    public static let betaHeaderField = "anthropic-beta"

    /// The identity line the OAuth edge expects to lead the system prompt.
    public static let claudeCodeSystemPreamble = "You are Claude Code, Anthropic's official CLI for Claude."

    private let engine: OAuthCredentialEngine
    private let wrapped: AnthropicConnector

    /// Non-nil while the identity framing is on. Kept here as well as inside
    /// ``wrapped`` because the instruction relocation below is gated on it: with
    /// no identity block there is no fingerprint to keep clean.
    private let systemPreamble: String?

    /// - Parameters:
    ///   - engine: Owns the stored credential and every rotation of it. The
    ///     connector never reads or writes the Keychain itself.
    ///   - transport: The single network seam, decorated with the beta header.
    ///   - baseURL: Overridable for a proxy; the default is the production host.
    ///   - betaFeatures: `anthropic-beta` values, joined with commas. Empty skips
    ///     the header entirely.
    ///   - systemPreamble: The ONLY `system` block of every request. `nil`
    ///     disables the framing — restoring both the plain-string `system` field
    ///     and the caller's instructions in it — which is useful only for a
    ///     provider that stops requiring the identity block, or for a test
    ///     asserting the un-framed body.
    public init(
        engine: OAuthCredentialEngine,
        transport: any HTTPTransport = URLSessionTransport(),
        baseURL: URL = AnthropicConnector.defaultBaseURL,
        betaFeatures: [String] = ClaudeSubscriptionConnector.defaultBetaFeatures,
        systemPreamble: String? = ClaudeSubscriptionConnector.claudeCodeSystemPreamble
    ) {
        self.engine = engine
        self.systemPreamble = systemPreamble
        wrapped = AnthropicConnector(
            // The token is resolved at CALL time, not here: a connector built at
            // launch must still work eight hours later, and only the engine knows
            // whether that needs a refresh first.
            auth: .bearer(provider: { try await engine.accessToken() }),
            transport: Self.decorated(transport, betaFeatures: betaFeatures),
            baseURL: baseURL,
            // NOT prepended to the instructions: the OAuth edge matches a
            // DISCRETE first `system` block, and a concatenated string is
            // refused as a disguised 429. See ``AnthropicSystemPrompt``. The
            // caller's instructions never reach this parameter at all — every
            // entry point below relocates them into the prose first.
            systemPrefix: systemPreamble
        )
    }

    public var id: String {
        Self.connectorID
    }

    /// Brand name — never localized, rendered `Text(verbatim:)` by the shells.
    public var displayName: String {
        "Claude Subscription"
    }

    /// ``AuthDescriptor/subscription``, which is what routes the settings UI to a
    /// sign-in button instead of a secret field.
    public var authDescriptor: AuthDescriptor {
        .subscription
    }

    /// Whether a credential is stored, WITHOUT decoding or refreshing it.
    ///
    /// The cheap gate a registry probe wants: `listModels()` on a connector that
    /// was never signed into would spend a store read and a decode to learn
    /// nothing this call cannot answer.
    public func isSignedIn() async -> Bool {
        await engine.hasStoredCredentials()
    }

    public func listModels() async throws -> [ModelInfo] {
        try await refreshingOnce {
            try await wrapped.listModels()
        }
    }

    public func structuredCompletion(
        schema: JSONSchemaObject,
        instructions: String,
        prompt: String,
        model: String
    ) async throws -> Data {
        let relocated = relocating(instructions: instructions, into: prompt)
        return try await refreshingOnce {
            try await wrapped.structuredCompletion(
                schema: schema,
                instructions: relocated.instructions,
                prompt: relocated.prompt,
                model: model
            )
        }
    }

    public func completion(instructions: String, prompt: String, model: String) async throws -> String {
        let relocated = relocating(instructions: instructions, into: prompt)
        return try await refreshingOnce {
            try await wrapped.completion(
                instructions: relocated.instructions,
                prompt: relocated.prompt,
                model: model
            )
        }
    }
}

// MARK: - Instruction relocation

/// Moves the caller's framing OUT of the `system` field and into the prose, so
/// the block array the OAuth edge reads holds the identity line and NOTHING else.
///
/// ── WHY (fingerprinting-era 400s) ────────────────────────────────────────────
///
/// ``AnthropicSystemPrompt`` already proves the identity line must be a DISCRETE
/// first block. What that measurement did not settle is what the edge does with
/// the SECOND block: a request whose `system` is `[identity, "Answer with the
/// library."]` announces itself as Claude Code and then carries a system prompt
/// Claude Code would never send, and the edge answers some of those with a 400
/// blaming usage against a healthy quota
/// (`griffinmartin/opencode-claude-auth#148` lineage). Sending ONE block removes
/// the discrepancy at the cost of nothing: an instruction is equally binding as
/// the opening of the user's own turn, which is where it goes instead.
///
/// Relocation is gated on ``systemPreamble``. With no identity block there is no
/// fingerprint to protect, and `nil` is the documented escape hatch back to the
/// un-framed body — moving the instructions anyway would make that hatch lossy.
private extension ClaudeSubscriptionConnector {
    /// The two strings a completion entry point forwards after relocation.
    typealias RelocatedPrompt = (instructions: String, prompt: String)

    /// The caller's framing, ready to lead a turn — trimmed, and with a
    /// caller-supplied copy of the identity line dropped so it cannot appear
    /// twice. `nil` when there is nothing to move, which every caller reads as
    /// "forward what you were given, untouched".
    ///
    /// The prefix-dropping mirrors ``AnthropicSystemPrompt/value(prefix:instructions:)``
    /// deliberately: callers that pre-framed their instructions for the old shape
    /// keep working, and the identity line stays in block 0 where it is read.
    func relocatableInstructions(_ instructions: String) -> String? {
        guard let systemPreamble, systemPreamble.isEmpty == false else { return nil }
        let trimmed = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let remainder = trimmed.hasPrefix(systemPreamble)
            ? String(trimmed.dropFirst(systemPreamble.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            : trimmed
        return remainder.isEmpty ? nil : remainder
    }

    func relocating(instructions: String, into prompt: String) -> RelocatedPrompt {
        guard let framing = relocatableInstructions(instructions) else {
            return (instructions, prompt)
        }
        return ("", Self.leading(framing, ahead: prompt))
    }

    /// `request` with its framing moved onto the OLDEST prose turn.
    ///
    /// The oldest, not the newest: ``ToolTurnRequest/messages`` is oldest-first
    /// with the turn being answered LAST, so prepending to the last one would
    /// re-state the instructions on every round of the same conversation.
    ///
    /// An EMPTY `messages` array leaves the request untouched — instructions
    /// included. That request is already a 400 from Anthropic (`messages` may not
    /// be empty), and degrading to the previous two-block shape is strictly more
    /// honest than silently discarding the caller's framing.
    func relocatingInstructions(_ request: ToolTurnRequest) -> ToolTurnRequest {
        guard let framing = relocatableInstructions(request.instructions),
              let oldest = request.messages.first
        else {
            return request
        }
        var relocated = request
        relocated.instructions = ""
        relocated.messages[0].text = Self.leading(framing, ahead: oldest.text)
        return relocated
    }

    /// `framing`, then a blank line, then `text` — unless `text` already opens
    /// with `framing`.
    ///
    /// The idempotence guard protects against the CALLER, not the loop — worth
    /// stating precisely, because the plausible-sounding reason is the wrong one.
    /// ``ToolLoopEngine`` builds its `messages` ONCE per turn and thereafter
    /// mutates only `transcript`/`outcomes`, and the relocation above rewrites a
    /// COPY, so twenty rounds could not double the framing by themselves. What
    /// can is a caller handing back a history whose oldest turn a previous call
    /// already framed. Without the guard that accumulates one copy per turn.
    static func leading(_ framing: String, ahead text: String) -> String {
        guard text.hasPrefix(framing) == false else { return text }
        return text.isEmpty ? framing : "\(framing)\n\n\(text)"
    }
}

// MARK: - Retry

private extension ClaudeSubscriptionConnector {
    /// Runs `attempt`; on ``ConnectorFailure/authExpired`` forces ONE rotation and
    /// runs it exactly once more.
    ///
    /// Written as a straight-line `do`/`catch` rather than a loop or a recursive
    /// call on purpose: the "exactly once" bound is then a property of the SHAPE,
    /// not of a counter a later edit could get wrong.
    ///
    /// A failure thrown by ``OAuthCredentialEngine/forceRefresh()`` propagates
    /// UNCHANGED, which preserves the engine's own mapping discipline: the
    /// provider refusing the refresh is `.authExpired` (sign in again), but a
    /// provider that was never REACHED stays `.unreachable` / `.timeout` /
    /// `.cancelled`. Collapsing the latter into `.authExpired` would throw away a
    /// perfectly valid session over a flaky network and demand a re-login the
    /// listener cannot complete offline.
    func refreshingOnce<Value>(_ attempt: () async throws -> Value) async throws -> Value {
        do {
            return try await attempt()
        } catch ConnectorFailure.authExpired {
            _ = try await engine.forceRefresh()
            return try await attempt()
        }
    }

    static func decorated(_ transport: any HTTPTransport, betaFeatures: [String]) -> any HTTPTransport {
        let features = betaFeatures.filter { $0.isEmpty == false }
        guard features.isEmpty == false else { return transport }
        return SubscriptionBetaTransport(base: transport, betaHeaderValue: features.joined(separator: ","))
    }
}

// MARK: - Tool loop

/// The subscription route's tool-calling round.
///
/// Kept in THIS file rather than a `+ToolLoop.swift` sibling — the opposite of
/// what the four base connectors do — because it needs `wrapped` and the
/// `private` helpers above, and there is no wire code here to make the file long:
/// the whole adapter is "relocate the framing, then apply the same exactly-once
/// refresh rule every other method applies". Duplicating either rule in a second
/// file is how a fifth method eventually gets a sixth retry policy.
extension ClaudeSubscriptionConnector: ToolCallingConnector {
    public func chatTurn(_ request: ToolTurnRequest) async throws -> ToolTurnResponse {
        let relocated = relocatingInstructions(request)
        return try await refreshingOnce {
            try await wrapped.chatTurn(relocated)
        }
    }
}

// MARK: - Beta-header transport

/// Adds `anthropic-beta` to every request before handing it on.
///
/// A DECORATOR rather than a parameter on ``AnthropicConnector`` because the
/// header belongs to the subscription route alone. Threading it through the base
/// connector would put an OAuth-shaped concern into the target that ships in the
/// App Store binary — the exact coupling the package split exists to prevent.
///
/// An existing value is left untouched, so a caller (or a future decorator) that
/// already set its own feature list wins.
struct SubscriptionBetaTransport: HTTPTransport {
    let base: any HTTPTransport
    let betaHeaderValue: String

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        var request = request
        if request.value(forHTTPHeaderField: ClaudeSubscriptionConnector.betaHeaderField) == nil {
            request.setValue(betaHeaderValue, forHTTPHeaderField: ClaudeSubscriptionConnector.betaHeaderField)
        }
        return try await base.send(request)
    }
}
