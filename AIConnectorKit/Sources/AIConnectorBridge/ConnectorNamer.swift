// ConnectorNamer — the connector tier of ``PlaylistNaming``.
//
// Plain prose, not structured output: naming is one short answer, and every provider
// reaches structured output by a different route (Ollama `format`, Anthropic's forced
// tool, OpenAI's `response_format`) with its own failure modes. Spending that
// machinery on two fields would make the cheapest request in the app the most
// fragile, so this tier asks ``AIProviderConnector/completion(instructions:prompt:model:)``
// for text and splits it.
//
// ── THE CAP IS THE FM TIER'S OWN, NOT A COPY OF ITS VALUE ─────────────────────
//
// The result is projected through ``FMNameFields/result``, the exact expression
// `FMPlaylistNaming` returns. So the trim, the empty-description-is-`nil` rule and
// the 60-character ceiling (`PlaylistNamingResult.maxNameLength`) are inherited from
// one implementation — a literal `60` here would be a second copy of a contract that
// `PlaylistNamingResult.init` already enforces structurally.
//
// ── THE PROMPT IS THE ON-DEVICE TIER'S, PLUS ONE LINE ─────────────────────────
//
// ``AssistantNamingPrompt`` is floor-available and already bounded (five ranked
// names, 40 characters each), so both tiers send byte-identical facts. The single
// added line names the RESPONSE SHAPE, which guided generation gives the FM tier for
// free and a plain completion does not. Same trade ``ConnectorPromptBuilder``
// documents for its own "answer with JSON only" line.
//
// See `ConnectorQueryParser.swift` for why this is a `struct` and why the deadline
// wraps the whole body rather than only the HTTP call.
import AIConnectorKit
import Foundation
import Services

/// Suggests a playlist name through one AI provider.
public struct ConnectorNamer: PlaylistNaming {
    /// The one instruction a plain completion needs and a guided generation does not.
    ///
    /// English is correct here for the same reason the rest of ``AssistantNamingPrompt``
    /// is English: nothing in it reaches a screen, and the language the ANSWER must be
    /// written in is named from `locale` in the shared instructions.
    public static let responseShapeInstruction = """
    Write the name on the first line and the description on the second line. \
    No labels, no quotation marks, no markdown.
    """

    private let connector: any AIProviderConnector
    private let model: @Sendable () async -> String?
    private let deadlineSeconds: TimeInterval

    /// - Parameters:
    ///   - connector: The configured provider route.
    ///   - model: The listener's selected model id, or `nil` when unchosen.
    ///   - deadlineSeconds: Budget for the whole call — credentials, refresh and HTTP.
    public init(
        connector: any AIProviderConnector,
        model: @escaping @Sendable () async -> String?,
        deadlineSeconds: TimeInterval = ConnectorConformerDeadline.seconds
    ) {
        self.connector = connector
        self.model = model
        self.deadlineSeconds = deadlineSeconds
    }

    /// The exact instructions one naming request sends.
    ///
    /// Public and pure so a token-budget test can measure the sent text without a
    /// connector — the same reason ``AssistantNamingPrompt/instructionsText(locale:)``
    /// is public.
    public static func instructionsText(locale: Locale) -> String {
        AssistantNamingPrompt.instructionsText(locale: locale) + "\n" + responseShapeInstruction
    }

    /// Names one draft.
    ///
    /// - Throws: ``ConnectorFailure`` for anything the provider or its credentials
    ///   did, and `CancellationError` when the call was cancelled. A blank answer is
    ///   ``ConnectorFailure/malformedResponse`` rather than an empty name: callers
    ///   fall back to a localized template, which is a better outcome than a playlist
    ///   named nothing.
    public func suggestName(
        for context: PlaylistNamingContext,
        locale: Locale
    ) async throws -> PlaylistNamingResult {
        try await runBoundedConnectorCall(seconds: deadlineSeconds) {
            let modelID = try await connectorModelID(model)
            let answer = try await connector.completion(
                instructions: Self.instructionsText(locale: locale),
                prompt: AssistantNamingPrompt.promptText(for: context),
                model: modelID
            )
            return try Self.fields(from: answer).result
        }
    }

    /// Splits a prose answer into the raw bag the FM tier fills in structurally.
    ///
    /// First non-blank line is the name; everything after it is the description,
    /// rejoined with spaces so a model that wrapped one sentence over two lines does
    /// not produce a description containing a newline.
    ///
    /// - Throws: ``ConnectorFailure/malformedResponse`` when nothing survives.
    static func fields(from answer: String) throws -> FMNameFields {
        let lines = answer
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let name = lines.first else { throw ConnectorFailure.malformedResponse }
        return FMNameFields(name: name, description: lines.dropFirst().joined(separator: " "))
    }
}
