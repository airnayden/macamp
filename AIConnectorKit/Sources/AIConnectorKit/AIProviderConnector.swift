// AIProviderConnector — the one seam every provider is written to.
//
// Three methods, chosen because they are what the app actually needs and nothing
// more: enumerate models so the selector shows what the listener really has,
// obtain schema-constrained JSON for query parsing, and obtain plain prose for
// naming and narration. No streaming, no embeddings, no chat history — each would
// widen every conformer for a feature the app has no surface for.
//
// The kit's types stay decoupled from PlayerCore's assistant seams
// (`NaturalLanguageQueryParsing`, `PlaylistNaming`, `InsightNarrating`) on
// purpose: those speak `PlaylistQuerySpec` and `AssistantNameCount`, which are
// MacAMP's domain. `AIConnectorBridge` adapts one to the other, and that
// adaptation is the ONLY place the two vocabularies meet — which is what lets
// this whole target lift into another app unchanged.
import Foundation

/// A configured route to one AI provider.
///
/// Conformers are `Sendable` and their methods `async throws`. A conformer may be
/// an actor, a struct over an injected ``HTTPTransport``, or a test double; the
/// protocol does not care and deliberately imposes no isolation.
///
/// ── FAILURE CONTRACT ───────────────────────────────────────────────────────────
///
/// Every method throws ``ConnectorFailure`` and nothing else. A conformer that
/// lets a `URLError`, a `DecodingError`, or a provider-specific error escape has a
/// bug: callers switch over the total taxonomy without a `default:`, so an
/// off-taxonomy error becomes an unhandled path at every one of those sites.
///
/// ── DEADLINE CONTRACT ──────────────────────────────────────────────────────────
///
/// A conformer is NOT required to bound its own runtime — its caller wraps the
/// whole call in ``withDeadline(seconds:operation:)``, which covers the parts a
/// transport timeout cannot see (async credential providers, Keychain reads,
/// token refresh). A conformer MUST therefore be cancellation-cooperative: every
/// await in its body has to be one that observes cancellation.
public protocol AIProviderConnector: Sendable {
    /// Stable machine identifier — `ollama`, `anthropic`, `openai`. Persisted in
    /// settings and used as the Keychain account namespace, so it must never
    /// change once shipped.
    var id: String { get }

    /// The provider's own name, shown in the selector.
    ///
    /// NOT localized: these are brand names, in the same class as the MacAMP brand.
    /// Shells render them `Text(verbatim:)`.
    var displayName: String { get }

    /// Which credential this connector needs. Metadata only — never the credential.
    var authDescriptor: AuthDescriptor { get }

    /// The models this account can actually use, straight from the provider.
    ///
    /// Live rather than hardcoded: a hardcoded list goes stale the week a provider
    /// ships a model, and it cannot know which models a given key is entitled to.
    /// This call doubles as the registry's reachability probe.
    func listModels() async throws -> [ModelInfo]

    /// Asks for JSON that conforms to `schema`, returning the raw bytes.
    ///
    /// Returns `Data`, not a decoded type, because the kit does not know MacAMP's
    /// DTOs — the bridge decodes and validates. Providers reach schema-constrained
    /// output by three different routes (Ollama `format`, Anthropic forced tool
    /// `input_schema`, OpenAI `response_format.json_schema` + `strict`); unwrapping
    /// each to bare JSON is the conformer's job.
    ///
    /// - Parameters:
    ///   - schema: The shape the response must take.
    ///   - instructions: System-level framing.
    ///   - prompt: The listener-derived request, already payload-budgeted.
    ///   - model: A ``ModelInfo/id`` from ``listModels()``.
    func structuredCompletion(
        schema: JSONSchemaObject,
        instructions: String,
        prompt: String,
        model: String
    ) async throws -> Data

    /// Asks for plain prose — playlist names and listening narratives.
    ///
    /// Callers cap the result themselves (naming and narration have their own
    /// length limits); this method makes no promise about length.
    func completion(
        instructions: String,
        prompt: String,
        model: String
    ) async throws -> String
}
