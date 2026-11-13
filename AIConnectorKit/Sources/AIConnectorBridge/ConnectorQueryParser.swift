// ConnectorQueryParser — the connector tier of ``NaturalLanguageQueryParsing``.
//
// One request, one round-trip, no retry: ``ConnectorPromptBuilder`` bounds the
// payload deterministically, so unlike `FMAssistantBackend` there is no
// "context exceeded" failure to halve a prompt and try again. What IS mirrored is
// the part that decides correctness — the answer goes through the SAME
// `FMQuerySpecFields.resolve(validGenres:)` the FoundationModels tier uses, so the
// genre vocabulary guard, the plausible-year/tempo windows, the mood mapping and the
// `lowConfidence: spec.isUnconstrained` second pass all come from one implementation
// rather than from a copy that could drift.
//
// ── WHY A `struct`, NOT AN ACTOR WITH A BUSY LATCH ────────────────────────────
//
// `FMAssistantBackend` is an actor that REJECTS a second in-flight request, because
// on-device generation is expensive, memory-hungry work that must not run
// concurrently with itself. Neither half of that applies here: the work happens on
// somebody else's hardware, and this type owns no mutable state to isolate — it
// holds a connector, two providers and a number. That is the same reasoning
// `FMNamingNarrating.swift` records for its own `struct` conformers, and the same
// reasoning `OllamaConnector` records for being a `struct`: a settings change is
// expressed by BUILDING A NEW conformer, never by mutating a live one, which is
// exactly what todo 13's widened observation does.
//
// Single-flighting is not lost — `AssistantViewModel.submit` already holds one busy
// latch for the whole ladder, and `connectorSpec` cancels the tier's task when its
// own deadline fires.
//
// ── THE DEADLINE COVERS THE WHOLE BODY, NOT THE HTTP CALL ─────────────────────
//
// `URLSessionTransport` times out a REQUEST. It cannot see the awaits around one:
// resolving the selected model through a main-actor settings read, a Keychain read
// on a locked keychain, or an OAuth refresh that performs its own round-trip. Every
// one of those runs INSIDE ``withDeadline`` here, so nothing unbounded can escape
// into the ladder — `AssistantViewModel.connectorSpec` cancels-and-ABANDONS a tier
// that overruns, and an abandoned unbounded await would keep working for free.
import AIConnectorKit
import Foundation
import Services

// MARK: - Shared conformer plumbing

// Declared in this file rather than one of its own: todo 12 ships exactly three
// conformer files, and triplicating six lines of credential-and-deadline plumbing
// across them would be three places for the invariant to drift. Extracting it into
// `ConnectorConformerSupport.swift` is a clean, behaviour-free follow-up.

/// How long a bridge conformer may take, end to end.
public enum ConnectorConformerDeadline {
    /// Mirrors `AssistantBackendStack.defaultConnectorDeadlineSeconds`, which cannot
    /// be referenced here — that type lives in `ViewModels`, and this target depends
    /// on `Services` only. The ladder applies its own bound on top; this one exists
    /// so a conformer used outside the ladder is bounded too.
    public static let seconds: TimeInterval = 20
}

/// The selected model id, or ``ConnectorFailure/unconfigured``.
///
/// Resolved BEFORE any transport call, deliberately: the three shipped connectors
/// all resolve their credential first for the same reason, and todo 9's registry
/// probe depends on "unconfigured costs zero requests". A blank or whitespace-only
/// selection is unconfigured, not a model named `" "`.
func connectorModelID(_ provider: @Sendable () async -> String?) async throws -> String {
    guard let raw = await provider() else { throw ConnectorFailure.unconfigured }
    let identifier = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !identifier.isEmpty else { throw ConnectorFailure.unconfigured }
    return identifier
}

/// Runs one conformer's ENTIRE body under `seconds`, surfacing a cancelled call as
/// cancellation rather than as a failure.
///
/// ``ConnectorFailure/cancelled`` means "nothing went wrong, the caller stopped
/// caring". PlayerCore's tiers spell that `CancellationError` — `FMSessionQueryResponder`
/// re-throws it unchanged precisely so a cancelled request never reads as a model
/// failure — and PlayerCore cannot name `ConnectorFailure` at all, so the translation
/// belongs at this boundary. Every other failure propagates UNCHANGED: the ladder
/// swallows it with `try?`, and laundering a `.unreachable` into a `.timeout` would
/// destroy the one diagnostic the settings pane has.
func runBoundedConnectorCall<Value: Sendable>(
    seconds: TimeInterval,
    _ operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    do {
        return try await withDeadline(seconds: seconds, operation: operation)
    } catch ConnectorFailure.cancelled {
        throw CancellationError()
    }
}

// MARK: - The parser

/// Turns a listener's request into a ``PlaylistQuerySpec`` through one AI provider.
public struct ConnectorQueryParser: NaturalLanguageQueryParsing {
    private let connector: any AIProviderConnector
    private let model: @Sendable () async -> String?
    private let contextProvider: @Sendable () async -> ConnectorPromptContext
    private let deadlineSeconds: TimeInterval

    /// - Parameters:
    ///   - connector: The configured provider route. Built fresh whenever a setting
    ///     changes, never mutated in place.
    ///   - model: The listener's selected model id, or `nil` when they have not
    ///     chosen one. `async` because the real one reads `@MainActor` settings.
    ///   - contextProvider: The library facts one request is interpreted against.
    ///     Its ``ConnectorPromptContext/requestText`` is IGNORED and replaced with
    ///     the listener's own text — a provider supplies the library half only,
    ///     exactly as `FMAssistantBackend.contextProvider` does. Uncapped on purpose:
    ///     ``ConnectorPromptBuilder`` owns the caps, and the FULL genre list is what
    ///     the answer is validated against.
    ///   - deadlineSeconds: Budget for the whole call — credentials, refresh and HTTP.
    public init(
        connector: any AIProviderConnector,
        model: @escaping @Sendable () async -> String?,
        contextProvider: @escaping @Sendable () async -> ConnectorPromptContext,
        deadlineSeconds: TimeInterval = ConnectorConformerDeadline.seconds
    ) {
        self.connector = connector
        self.model = model
        self.contextProvider = contextProvider
        self.deadlineSeconds = deadlineSeconds
    }

    /// Parses one request.
    ///
    /// - Throws: ``ConnectorFailure`` for anything the provider or its credentials
    ///   did — every case is a thrown error the ladder falls through silently — and
    ///   `CancellationError` when the call was cancelled. Never returns a spec it did
    ///   not derive: a malformed answer throws rather than degrading to a default,
    ///   because the ladder's OWN next tier is a better default than an empty spec.
    public func parse(text: String, locale: Locale) async throws -> PlaylistQuerySpec {
        try await runBoundedConnectorCall(seconds: deadlineSeconds) {
            let modelID = try await connectorModelID(model)
            var context = await contextProvider()
            context.requestText = text
            let request = ConnectorPromptBuilder.build(context, locale: locale)
            let answer = try await connector.structuredCompletion(
                schema: PlaylistQuerySchema.canonical,
                instructions: request.instructions,
                prompt: request.prompt,
                model: modelID
            )
            // `decodeFields` owns the leniency (a loose scalar costs its own field,
            // a non-object answer is `.malformedResponse`) and `resolve` owns the
            // validation. Adding either here would be a second, disagreeing copy.
            let fields = try PlaylistQuerySchema.decodeFields(from: answer)
            return fields.resolve(validGenres: context.genres.map(\.name))
        }
    }
}
