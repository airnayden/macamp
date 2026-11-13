// IntelligenceMCPProbe — the live wiring behind "Test Connection".
//
// ── ONE CONNECTION, THEN NOTHING ─────────────────────────────────────────────
//
// A probe is a full round trip — `initialize`, then `tools/list` — and it is torn
// down on BOTH paths, success included. That is not tidiness: a command server is a
// CHILD PROCESS, and a pane that leaves one running because the listener pressed a
// button is a pane that spawns programs nobody is watching. ``MCPClientManager``'s
// reconnect-on-demand policy exists for the same reason, and this respects it.
//
// ── THE GUARD, AND WHY THIS FILE IS STILL ALLOWED TO LIVE HERE ───────────────
//
// `scripts/check-ai-network-boundary.sh` scans every
// `macOS/Sources/Preferences/Intelligence*` file for `URLSession` and for process
// spawning (`Process(`, `posix_spawn`, `NSTask`). Neither appears below. The child
// process is `MCPProcessTransport`'s — the guard's single exemption, and the only
// file in the AI surface permitted to construct one — and the HTTP session belongs
// to the pinned SDK's own transport. This file NAMES those two types and hands them
// a descriptor; it opens nothing itself. That is the same arrangement
// ``IntelligenceConnectorConfigModel`` uses for a provider credential check.
//
// ── SECRETS ARRIVE RESOLVED AND ARE NEVER LOGGED ─────────────────────────────
//
// The values come from ``MCPServerConfigStore/resolvedSecrets(for:)``, keyed by the
// account names the descriptor declares. They are handed straight to a transport.
// Nothing here logs them, and ``MCPServerProbeOutcome`` has no field one could land
// in — its `diagnostic` is a fixed ``MCPClientFailure/DiagnosticToken``.
import AIConnectorKit
import AIConnectorMCP
import Foundation
import MCP

/// Builds the probe the MCP section runs when the listener asks.
enum IntelligenceMCPProbe {
    /// A probe that really connects, lists, and hangs up.
    static func live() -> MCPServerProbing {
        { descriptor, secrets, timeout in
            let manager = MCPClientManager(
                descriptor: descriptor,
                timeoutSeconds: timeout,
                transportFactory: { server in transport(for: server, secrets: secrets) }
            )
            do {
                let tools = try await manager.listTools()
                await manager.disconnect()
                return .connected(toolCount: tools.count)
            } catch {
                await manager.disconnect()
                return .unreachable(diagnostic: diagnostic(for: error))
            }
        }
    }

    /// How MacAMP reaches a server, as ``MCPClientManager`` wants it.
    ///
    /// Exposed — the one member of this enum that is — because ``MCPToolSupply``
    /// builds long-lived connections to the SAME endpoints this button probes, and
    /// two definitions of "how we reach a server" would drift the first time one
    /// arm gained a header. The factory shape rather than the transport itself so a
    /// caller never has to name the SDK's `Transport` protocol.
    static func transportFactory(secrets: [String: String]) -> MCPClientManager.TransportFactory {
        { descriptor in transport(for: descriptor, secrets: secrets) }
    }

    /// The transport for one endpoint, credentials folded in.
    ///
    /// A name the descriptor declares but the Keychain has nothing for is OMITTED
    /// rather than sent empty: an empty bearer is a wrong answer a server will
    /// reject in a way that reads like a bad token, and a missing one reads like
    /// what it is.
    private static func transport(
        for descriptor: MCPServerDescriptor,
        secrets: [String: String]
    ) -> any Transport {
        switch descriptor.endpoint {
        case let .stdio(command, arguments, environmentKeys):
            MCPProcessTransport(
                command: command,
                arguments: arguments,
                environment: resolved(names: environmentKeys, from: secrets)
            )
        case let .streamableHTTP(url, headerKeys):
            httpTransport(url: url, headers: resolved(names: headerKeys, from: secrets))
        }
    }

    private static func resolved(names: [String], from secrets: [String: String]) -> [String: String] {
        names.reduce(into: [String: String]()) { resolved, name in
            guard let value = secrets[name] else { return }
            resolved[name] = value
        }
    }

    /// Streaming is OFF for a probe. A probe wants one answer and then silence; an
    /// SSE channel would hold a socket open behind a button press that is finished.
    private static func httpTransport(url: URL, headers: [String: String]) -> any Transport {
        HTTPClientTransport(endpoint: url, streaming: false) { request in
            var authorized = request
            for (name, value) in headers {
                authorized.setValue(value, forHTTPHeaderField: name)
            }
            return authorized
        }
    }

    /// Every failure reduced to the token the status row renders.
    ///
    /// A timeout is reported as its own token rather than folded into
    /// `connection-closed`: "it did not answer in 30 seconds" and "it refused the
    /// connection" send a listener to different places.
    private static func diagnostic(for error: any Error) -> String {
        guard let failure = error as? MCPClientFailure else {
            return MCPClientFailure.DiagnosticToken.transportFailure
        }
        switch failure {
        case let .unreachable(underlying), let .protocolViolation(underlying):
            return underlying
        case .timeout:
            return Self.timedOutToken
        case .unknownTool, .cancelled:
            return MCPClientFailure.DiagnosticToken.transportFailure
        }
    }

    /// The one token this layer adds to ``MCPClientFailure/DiagnosticToken``'s
    /// vocabulary, for the deadline the manager enforces but does not name.
    static let timedOutToken = "timed-out"
}
