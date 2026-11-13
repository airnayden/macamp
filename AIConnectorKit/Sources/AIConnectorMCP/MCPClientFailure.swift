// MCPClientFailure — everything that can go wrong reaching an external MCP
// server, and nothing else.
//
// ── SAME SHAPE AS `ConnectorFailure`, DELIBERATELY NOT THE SAME TYPE ──────────
//
// This mirrors ``ConnectorFailure``'s discipline — a total enum with NO
// `case other(Error)`, machine tokens instead of prose, no localized copy, no
// secret-bearing payload — because every argument in that file's header applies
// here verbatim. It is a SEPARATE type because the two taxonomies answer different
// questions: `ConnectorFailure` is about a MODEL PROVIDER (auth expiry, rate
// limits, HTTP status), an MCP server has none of those and has three failures a
// provider cannot have (a child process that would not spawn, a tool the server
// does not publish, a result that is not text).
//
// ── THE RENDERING IS THE POINT ───────────────────────────────────────────────
//
// A tool the model called must always answer in SENTENCES — ``AITool/execute``
// cannot throw, by that file's own design ("A tool result is CONVERSATION, not
// control flow"). So every case here carries a model-facing English sentence, and
// ``MCPToolProjection`` returns it instead of letting the error escape into the
// loop. English and never localized: this text is read by a model, not a listener.
//
// ── WHY THE SENTENCE IS NOT QUARANTINE-FRAMED ────────────────────────────────
//
// ``MCPToolProjection`` frames server-ORIGINATED content as untrusted. A failure
// sentence is MacAMP's own words about a server that produced nothing, so framing
// it would teach the model to distrust the app itself, and would make the exact
// sentence this file promises unrecoverable from the tool output. Server content
// is framed; our sentences are not. `MCPToolProjectionTests` pins both halves.
import Foundation

/// Everything that can go wrong talking to an external MCP server.
public enum MCPClientFailure: Error, Sendable, Equatable, Hashable {
    /// The server could not be reached at all: connection refused, DNS failure,
    /// a child process that would not spawn, or a connection that closed under us.
    ///
    /// - Parameter underlying: A machine-readable token from ``DiagnosticToken`` —
    ///   never user-facing copy, never secret-bearing, never an env-var VALUE.
    case unreachable(underlying: String)

    /// A call did not finish inside ``MCPClientManager/callTimeoutSeconds``.
    case timeout

    /// The server answered, but not in a shape this client can use: a malformed
    /// JSON-RPC payload, or a protocol-level rejection.
    case protocolViolation(underlying: String)

    /// The server does not publish a tool by that name.
    case unknownTool(name: String)

    /// The call was cancelled cooperatively. Distinct from ``timeout``: nothing
    /// went wrong, the caller simply stopped caring.
    case cancelled
}

public extension MCPClientFailure {
    /// The closed vocabulary of ``unreachable(underlying:)`` and
    /// ``protocolViolation(underlying:)`` payloads.
    ///
    /// Tokens, not sentences, for the same reason `ConnectorFailure` uses them: a
    /// shell owns any localized rendering, so these values must stay stable and
    /// machine-comparable. The catch-all lives HERE, in a string vocabulary,
    /// precisely so it never has to exist in the enum.
    enum DiagnosticToken {
        /// The transport refused or dropped the connection.
        public static let connectionClosed = "connection-closed"
        /// The child process could not be launched at all.
        public static let processLaunchFailed = "process-launch-failed"
        /// The server's `initialize` handshake did not complete.
        public static let handshakeFailed = "handshake-failed"
        /// The server answered with a payload this client could not decode.
        public static let malformedPayload = "malformed-payload"
        /// Anything else the transport surfaced.
        public static let transportFailure = "transport-failure"
    }

    /// The sentence the MODEL reads when this failure ends a tool call.
    ///
    /// - Parameter serverName: The listener's own name for the server, so the
    ///   model can say which one broke. Never a URL, never a command line — a
    ///   stdio command line can carry a token in an argument.
    func modelFacingSentence(serverName: String) -> String {
        switch self {
        case .unreachable:
            "The MCP server \(serverName) is not reachable."
        case .timeout:
            "The MCP server \(serverName) did not answer in time."
        case .protocolViolation:
            "The MCP server \(serverName) sent a response this app could not read."
        case let .unknownTool(name):
            "The MCP server \(serverName) does not offer a tool called \(name)."
        case .cancelled:
            "The call to the MCP server \(serverName) was cancelled."
        }
    }
}
