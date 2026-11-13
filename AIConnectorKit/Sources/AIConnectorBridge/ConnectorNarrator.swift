// ConnectorNarrator — the connector tier of ``InsightNarrating``.
//
// The simplest of the three conformers: ``AssistantNarrationPrompt`` already states
// the whole response contract ("two or three short sentences. No lists, no headings,
// no markdown"), so unlike ``ConnectorNamer`` there is nothing to add to it and
// nothing to parse out of the answer. Both tiers send byte-identical text.
//
// ── THE CAP IS THE FM TIER'S OWN ─────────────────────────────────────────────
//
// The answer is projected through ``FMNarrativeFields/result``, the exact expression
// `FMInsightNarrator` returns, so the 500-character clip
// (``FMNarrativeFields/maxLength``) and the whitespace trim in
// ``InsightNarrationResult/init(narrative:)`` are inherited rather than restated.
// The reason that cap exists applies identically to a remote model: a stats card is
// a fixed-size surface, and a model asked for three sentences occasionally writes ten.
//
// ── WHY A BLANK ANSWER THROWS ────────────────────────────────────────────────
//
// ``InsightNarrationResult`` tolerates an empty narrative — "the conformer produced
// nothing" is a legitimate state for the TEMPLATE tier. It is not one for a provider
// that was paid to answer: `FallbackInsightNarrating` wraps this tier and swallows
// every failure into a template narrative, so throwing yields a real sentence where
// returning empty would render a blank card.
//
// See `ConnectorQueryParser.swift` for why this is a `struct` and why the deadline
// wraps the whole body rather than only the HTTP call.
import AIConnectorKit
import Foundation
import Services

/// Writes a listening narrative through one AI provider.
public struct ConnectorNarrator: InsightNarrating {
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

    /// Narrates one listening window.
    ///
    /// - Throws: ``ConnectorFailure`` for anything the provider or its credentials
    ///   did, ``ConnectorFailure/malformedResponse`` for a blank answer, and
    ///   `CancellationError` when the call was cancelled.
    public func narrate(
        _ context: InsightNarrationContext,
        locale: Locale
    ) async throws -> InsightNarrationResult {
        try await runBoundedConnectorCall(seconds: deadlineSeconds) {
            let modelID = try await connectorModelID(model)
            let answer = try await connector.completion(
                instructions: AssistantNarrationPrompt.instructionsText(locale: locale),
                prompt: AssistantNarrationPrompt.promptText(for: context),
                model: modelID
            )
            guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ConnectorFailure.malformedResponse
            }
            // The RAW answer, so the clip and the trim happen in the FM tier's own
            // order rather than in a rearranged copy of them.
            return FMNarrativeFields(narrative: answer).result
        }
    }
}
