// ConnectorStatus — what one connector can do RIGHT NOW, and nothing else.
//
// ── TOTAL FROM DAY ONE ─────────────────────────────────────────────────────────
//
// Five cases, no catch-all, the same discipline ``ConnectorFailure`` is written
// to. The settings pane, the model picker and the ladder's connector-tier
// predicate all switch over this WITHOUT a `default:`, so a sixth case would be a
// compile error at each of those sites rather than a silently-unrendered state.
//
// ``disabled(reason:)`` exists NOW even though no shipped connector produces it
// yet. The ChatGPT-subscription connector's exit condition is "ship it disabled
// with an explanation", and the Claude engine is linked only by the non-App-Store
// build — both need this case. Declaring it here means those todos add a VALUE,
// not a case, and therefore do not reopen this enum or the shell's exhaustive
// rendering switch after the UI has been written against it.
//
// ── NOTHING HERE IS USER-FACING ────────────────────────────────────────────────
//
// ``disabled(reason:)`` carries a machine-readable TOKEN — `upstream-flow-unavailable`,
// never "The ChatGPT sign-in flow is unavailable." The kit ships no user-visible
// strings (MacAMP routes every one of those through a String Catalog in the
// shell), so the shell maps a token to localized copy and NEVER renders the token
// raw. Same contract as ``ConnectorFailure/DiagnosticToken``: stable, comparable,
// secret-free.
import Foundation

/// The state a connector is in, as far as the last probe could tell.
///
/// This is what the settings pane renders and what the assistant ladder's
/// connector-tier predicate consumes. It is a SNAPSHOT, not a subscription: a
/// caller that needs a fresh answer probes again.
public enum ConnectorStatus: Sendable, Equatable {
    /// The listener has not finished setting this connector up — no API key, no
    /// signed-in account. Reached WITHOUT a transport call, which is the whole
    /// reason ``ConnectorFailure/unconfigured`` is raised before one.
    case unconfigured

    /// The connector answered and can be used.
    ///
    /// - Parameter models: What the provider listed, or `nil` when this probe did
    ///   not ask. `nil` and `[]` are deliberately different answers: `nil` means
    ///   "reachable, not enumerated" (a cheap credential-presence gate), `[]`
    ///   means "the provider listed nothing", which is a real, renderable state —
    ///   an Ollama server with no models pulled.
    case ready(models: [ModelInfo]?)

    /// The provider could not be used this time, for a reason that may not
    /// survive to the next attempt.
    ///
    /// - Parameter failure: The taxonomy value verbatim, so a consumer that cares
    ///   about the difference between a refused connection, a 500 and a throttle
    ///   can still tell them apart. Nothing is flattened into a token here — that
    ///   is precisely why the payload is the whole failure.
    case unreachable(ConnectorFailure)

    /// The credential was rejected or expired. Distinct from ``unreachable(_:)``
    /// because it is the one state the listener can fix, and the UI says so.
    case authExpired

    /// The connector is registered but deliberately not usable in this build or
    /// against this provider today.
    ///
    /// - Parameter reason: A machine-readable token from ``DisabledReason`` —
    ///   NEVER user-facing copy, never rendered raw. The shell maps it to catalog
    ///   copy.
    case disabled(reason: String)
}

public extension ConnectorStatus {
    /// The closed vocabulary of ``disabled(reason:)`` payloads.
    ///
    /// Tokens, not sentences, for the same reason
    /// ``ConnectorFailure/DiagnosticToken`` is: the shell owns localized
    /// rendering, so these values must stay stable and machine-comparable. A
    /// connector that needs a new reason adds a constant HERE, so the shell's
    /// mapping has one place to look.
    enum DisabledReason {
        /// The provider's own sign-in flow is gone or changed shape, so the
        /// connector cannot be driven end to end. The best-effort exit condition
        /// for a subscription connector.
        public static let upstreamFlowUnavailable = "upstream-flow-unavailable"

        /// The connector's engine is not linked into this build — how the App
        /// Store binary reports a subscription connector whose OAuth product it
        /// deliberately does not contain.
        public static let notLinkedInThisBuild = "not-linked-in-this-build"
    }

    /// Maps a probe failure onto the status the UI shows.
    ///
    /// The switch is EXHAUSTIVE with no `default:` on purpose — this is one of the
    /// consumer sites ``ConnectorFailure``'s no-catch-all rule exists to protect,
    /// so a tenth failure case breaks the build here instead of quietly landing in
    /// ``unreachable(_:)``.
    ///
    /// ``ConnectorFailure/cancelled`` maps to ``unreachable(_:)`` carrying the
    /// cancellation verbatim rather than to a case of its own: a cancelled probe
    /// learned nothing, and the payload keeps "the listener navigated away"
    /// distinguishable from "the provider is down" for anyone who looks.
    init(_ failure: ConnectorFailure) {
        switch failure {
        case .unconfigured:
            self = .unconfigured
        case .authExpired:
            self = .authExpired
        case .unreachable, .timeout, .httpStatus, .rateLimited, .malformedResponse, .truncated, .cancelled:
            self = .unreachable(failure)
        }
    }

    /// Whether the connector can be asked to do work.
    ///
    /// The ladder's connector-tier predicate is exactly this: a tier is eligible
    /// when its connector is ready, and every other status falls through to the
    /// next tier silently.
    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    /// The models this probe enumerated, or `nil` when it did not ask or the
    /// connector is not ready. Feeds the model picker.
    var reportedModels: [ModelInfo]? {
        guard case let .ready(models) = self else { return nil }
        return models
    }
}
