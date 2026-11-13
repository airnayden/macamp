// ConnectorProbing — "is this connector usable, and what can it run?"
//
// ── WHY `listModels()` IS THE PROBE ────────────────────────────────────────────
//
// It is the one call that answers both halves of the question at once. A dedicated
// `/ping` does not exist on any of the three providers; a completion would spend
// tokens and take seconds to prove reachability. `listModels()` exercises the
// whole path — credential resolution, host, TLS, auth — and its RESULT is what the
// model picker needs anyway, so a successful probe leaves the UI with nothing left
// to fetch.
//
// ── WHY `probe()` DOES NOT THROW ───────────────────────────────────────────────
//
// ``ConnectorStatus`` is total, so every outcome including "off-taxonomy error
// from a third-party conformer" has a case to land in. A throwing probe would
// force the same mapping into every call site — the settings pane, the ladder
// predicate, the registry — and each would be free to get it wrong differently.
//
// ── WHY AN UNCONFIGURED PROBE MUST COST NOTHING ────────────────────────────────
//
// The settings pane probes on appearance and the ladder probes before every
// connector-tier attempt. If an unconfigured connector spent a round-trip to be
// told 401, a listener who never set one up would pay a timeout on every
// interaction and read "authentication failed" for a key they never entered. Both
// shipped API-key connectors therefore raise ``ConnectorFailure/unconfigured``
// from their credential step, BEFORE any `transport.send`, and this file relies on
// that rather than re-checking it: `AnthropicConnector` resolves
// `auth.headerValue()` inside `makeRequest`, and `OpenAIConnector` inside
// `authorize(_:)`. `ConnectorRegistryProbeTests` pins the zero-request claim
// against the real connectors, not against a stub.
import Foundation

/// Reports what a connector can currently do.
///
/// Separate from ``AIProviderConnector`` because the two answer to different
/// callers: a connector is what the assistant *uses*, a probe is what settings and
/// the ladder *ask about*. Conformers that are also ``AIProviderConnector`` get a
/// working ``probe()`` for free from the extension below and declare conformance
/// with an empty extension; a connector with a cheaper truth available — a stored
/// OAuth credential it can check without a refresh — overrides it.
public protocol ConnectorProbing: Sendable {
    /// The connector's state right now. Never throws: every outcome maps onto
    /// ``ConnectorStatus``.
    func probe() async -> ConnectorStatus
}

/// Probe-wide constants.
public enum ConnectorProbe {
    /// How long a probe may take before it is reported unreachable.
    ///
    /// Matches ``URLSessionTransport/requestTimeout`` deliberately: the transport
    /// bounds the HTTP round-trip, this bounds the WHOLE call — the async
    /// credential provider, the Keychain read and a token refresh included — which
    /// is the gap ``withDeadline(seconds:operation:)`` exists to close. Equal
    /// budgets mean a stalled socket is reported by the transport (with its
    /// specific reason) and only a stall OUTSIDE the socket reaches this race.
    public static let deadlineSeconds: TimeInterval = 20
}

public extension ConnectorProbing where Self: AIProviderConnector {
    func probe() async -> ConnectorStatus {
        await probe(deadlineSeconds: ConnectorProbe.deadlineSeconds)
    }

    /// ``probe()`` with an explicit budget — the seam tests use to prove the
    /// deadline fires without waiting twenty seconds for it.
    ///
    /// The `catch` ladder is defensive by design. ``AIProviderConnector`` promises
    /// only ``ConnectorFailure`` escapes, but this is a NON-throwing function: an
    /// off-taxonomy error from a conformer written in another app would otherwise
    /// have nowhere to go. It becomes an unreachable-with-transport-failure rather
    /// than a trap.
    func probe(deadlineSeconds: TimeInterval) async -> ConnectorStatus {
        do {
            let models = try await withDeadline(seconds: deadlineSeconds) {
                try await self.listModels()
            }
            return .ready(models: models)
        } catch let failure as ConnectorFailure {
            return ConnectorStatus(failure)
        } catch is CancellationError {
            return .unreachable(.cancelled)
        } catch {
            return .unreachable(.unreachable(underlying: ConnectorFailure.DiagnosticToken.transportFailure))
        }
    }
}

// MARK: - Shipped conformances

// Declared here rather than in each connector file so the three provider files
// stay about their provider. All three qualify for the default `probe()` above
// unchanged: Ollama cannot be unconfigured at all (`init` takes a non-optional
// host, and its `AuthDescriptor` reports `requiresStoredSecret == false`), while
// Anthropic and OpenAI raise `.unconfigured` from their credential step before
// reaching the transport.

extension OllamaConnector: ConnectorProbing {}

extension AnthropicConnector: ConnectorProbing {}

extension OpenAIConnector: ConnectorProbing {}
