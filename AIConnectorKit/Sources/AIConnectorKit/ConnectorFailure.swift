// ConnectorFailure — the TOTAL failure taxonomy for every connector call.
//
// ── NO CATCH-ALL, ON PURPOSE ───────────────────────────────────────────────────
//
// There is deliberately no `case other(Error)`. Every consumer — the registry's
// status mapping, the shell's diagnostic copy, the ladder's silent-degradation
// rule — switches over this enum without a `default:`, so adding a tenth case is a
// COMPILE ERROR at each of those sites rather than a silently-mishandled path. A
// catch-all would make the taxonomy technically total and practically useless: it
// would immediately become the bucket every unmapped provider quirk fell into.
//
// `ConnectorFailureTotalityTests` pins this with an exhaustive switch that carries
// no `default:`; final-verification wave F2 cites that test as the compile-time
// proof.
//
// ── NOTHING HERE IS USER-FACING, WITH ONE NAMED EXCEPTION ─────────────────────
//
// No case carries localized copy, and this type is deliberately NOT
// `LocalizedError`. The kit ships no user-visible strings (MacAMP routes all of
// those through String Catalogs in the shells), so the payloads are machine
// diagnostics: shells map a case to localized copy, they never render it raw.
// Payloads must also stay secret-free — never put a credential, an
// `Authorization` header, or a full request URL into `underlying` or `body`.
//
// `httpStatus(_:body:providerMessage:)` carries the ONE exception:
// `providerMessage` is the provider's own `error.message` sentence, sanitized by
// ``ConnectorFailure/sanitizedProviderMessage(in:)`` and INTENDED to be shown
// beneath a shell's own typed copy. It is still not localized — it is the
// provider's English — which is exactly why it is a secondary line rather than
// the sentence itself. `body` keeps its old contract and stays off the screen.
import Foundation

/// Everything that can go wrong on the way to a provider, and nothing else.
public enum ConnectorFailure: Error, Sendable, Equatable, Hashable {
    /// The listener has not finished setting this connector up — no host, no API
    /// key, no signed-in account. Raised WITHOUT performing a transport call.
    case unconfigured

    /// The endpoint could not be reached at all: connection refused, DNS failure,
    /// TLS failure, no network.
    ///
    /// - Parameter underlying: A machine-readable diagnostic token from
    ///   ``DiagnosticToken`` — never user-facing copy, never secret-bearing.
    case unreachable(underlying: String)

    /// A deadline elapsed: either the transport's own per-request timeout or the
    /// `withDeadline(seconds:operation:)` race wrapped around a whole call.
    case timeout

    /// The provider answered, with a status the connector could not use.
    ///
    /// - Parameters:
    ///   - code: The HTTP status.
    ///   - body: A truncated response body for diagnosis, or `nil` when the
    ///     connector chose not to retain it. Never include request headers here.
    ///     Machine diagnostics — a shell must never render this.
    ///   - providerMessage: The provider's own `error.message` sentence,
    ///     sanitized by ``sanitizedProviderMessage(in:)``, or `nil` when the body
    ///     carried none. The one payload a shell MAY show, beneath its own copy.
    case httpStatus(Int, body: String?, providerMessage: String?)

    /// The credential was rejected (401 / 403), or a refresh attempt failed. The
    /// listener must re-authenticate; retrying with the same secret cannot help.
    case authExpired

    /// The provider is throttling (429).
    ///
    /// - Parameter retryAfter: Seconds to wait, parsed from `Retry-After` when the
    ///   provider sent a parseable value; `nil` when it did not.
    case rateLimited(retryAfter: TimeInterval?)

    /// The provider answered successfully but the payload did not match the
    /// contract — non-JSON, a missing field, or a refusal where content was
    /// expected.
    case malformedResponse

    /// The provider answered successfully and stopped MID-ANSWER at its own
    /// output ceiling: ChatGPT's terminal `response.incomplete` with
    /// `incomplete_details.reason == "max_output_tokens"`, Anthropic's
    /// `stop_reason == "max_tokens"`.
    ///
    /// Its own case rather than ``malformedResponse`` because the two ask for
    /// different things from a listener. A malformed answer is a contract
    /// violation nobody can act on; a cut-off answer means "that was too much to
    /// ask for at once", and asking for less is a real fix. This is also NOT
    /// ``httpStatus(_:body:providerMessage:)`` — truncation arrives on an HTTP
    /// **200** with no error payload at all, so there is no status to name and no
    /// `error.message` to quote.
    ///
    /// Carries no payload on purpose: the partial text IS discarded. Resuming a
    /// truncated generation is a different feature (a continuation protocol),
    /// and half a list rendered as a whole answer is worse than saying it was
    /// cut off.
    case truncated

    /// The call was cancelled cooperatively. Distinct from ``timeout``: nothing
    /// went wrong, the caller simply stopped caring. Callers propagate this as
    /// cancellation rather than degrading to a lower tier.
    case cancelled
}

public extension ConnectorFailure {
    /// The closed vocabulary of ``unreachable(underlying:)`` payloads.
    ///
    /// Tokens, not sentences: the shell owns the localized rendering (a later todo
    /// maps each token to catalog copy), so these values must stay stable and
    /// machine-comparable. Same discipline as the registry's `disabled(reason:)`.
    enum DiagnosticToken {
        /// The host answered the ARP/TCP layer but refused the connection — the
        /// classic "Ollama isn't running" signal.
        public static let connectionRefused = "connection-refused"
        /// DNS could not resolve the host, or the host does not exist.
        public static let hostNotFound = "host-not-found"
        /// No usable network path (offline, connection dropped mid-flight).
        public static let networkUnavailable = "network-unavailable"
        /// TLS negotiation failed — bad certificate, pinned-cert mismatch, MITM.
        public static let secureConnectionFailed = "secure-connection-failed"
        /// The response was not an HTTP response at all.
        public static let invalidResponse = "invalid-response"
        /// Anything else the transport surfaced. The catch-all lives HERE, in a
        /// string vocabulary, precisely so it never has to exist in the enum.
        public static let transportFailure = "transport-failure"
    }

    /// How much of a provider's own sentence may reach a listener.
    ///
    /// Far below the 512 every connector truncates ``httpStatus(_:body:providerMessage:)``'s
    /// `body` to, because these are different jobs: the body is a diagnostic
    /// nobody reads, this is a line under a failure banner. 200 characters is
    /// about two lines at the banner's width — long enough for "max_tokens: 8192
    /// > 4096, which is the maximum allowed for this model", short enough that a
    /// provider echoing a whole request back cannot take over the transcript.
    static let maxProviderMessageCharacters = 200

    /// The provider's own explanation of a failure, sanitized for display.
    ///
    /// Reads `error.message`, then a top-level `detail` string, and NOTHING
    /// else. `error.message` is where Anthropic, OpenAI and Ollama put their
    /// human-readable reason; `detail` is the ChatGPT subscription backend's
    /// spelling (measured 2026-09-09: `{"detail":"Unsupported parameter:
    /// max_output_tokens"}` reached a listener as a bare "(400)" because this
    /// extractor did not know the shape). Confining the extraction to these two
    /// paths is what keeps the rest of a response — echoed request fields,
    /// headers, ids — structurally unable to reach a screen. A body that is not
    /// JSON, is JSON without either path, or holds a blank string reads as `nil`
    /// and the shell falls back to its own typed sentence.
    static func sanitizedProviderMessage(in body: Data) -> String? {
        guard let root = AIJSONValue.decoded(from: body) else { return nil }
        let message = root["error"]?["message"]?.stringValue ?? root["detail"]?.stringValue
        guard let message else { return nil }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        return String(trimmed.prefix(maxProviderMessageCharacters))
    }
}
