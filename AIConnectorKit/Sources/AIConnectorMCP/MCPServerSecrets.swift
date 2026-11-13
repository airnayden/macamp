// MCPServerSecrets — where ONE external server's credentials live, and what they
// are called.
//
// ── THE MIRROR OF `ConnectorSecretService`, AND WHY IT IS A SEPARATE NAMESPACE ─
//
// `AIConnectorKit` addresses a provider's key at
// `com.macamp.aiconnectors.<connector-id>`, keyed by an id this build registers.
// An MCP server is the opposite kind of thing: the listener invents it, there is
// no registry, and its identity is a `UUID` MacAMP minted. Sharing the connector
// prefix would put two populations with different lifecycles and different
// deletion rules in one namespace, so this is its own prefix — the naming SHAPE
// is copied, the namespace deliberately is not.
//
// ── THE ACCOUNT NAMES ARE DERIVED, NOT STORED SEPARATELY ─────────────────────
//
// ``MCPServerDescriptor/secretAccountNames`` reads the endpoint's own key names,
// so the configuration that DECLARES a credential is the same value that locates
// it. A parallel list would be a second source of truth, and the first time the
// two disagreed the loser would be a Keychain entry nothing could ever reach —
// still on disk, still holding a token, invisible to the UI that would offer to
// delete it.
import Foundation

/// Builds the Keychain service namespace for one external MCP server.
///
/// Backend-neutral for the same reason ``ConnectorSecretService`` is: tests inject
/// an in-memory store but must address secrets exactly as production does, so a
/// namespace bug fails in the fake run rather than only against the real Keychain.
public enum MCPServerSecretService {
    /// Reverse-DNS prefix shared by every MCP server's Keychain service name.
    public static let keychainServicePrefix = "com.macamp.mcpservers"

    /// `com.macamp.mcpservers.<uuid>`.
    ///
    /// The `UUID` is spelled with Foundation's own `uuidString` and nothing else —
    /// no case folding, no dash stripping. Any normalization here would have to be
    /// reproduced byte-for-byte by every future caller, and the first one that got
    /// it wrong would silently address a namespace that has never held anything.
    public static func name(forServerID serverID: UUID) -> String {
        "\(keychainServicePrefix).\(serverID.uuidString)"
    }
}

public extension MCPServerDescriptor {
    /// This server's Keychain service namespace.
    var secretService: String {
        MCPServerSecretService.name(forServerID: id)
    }

    /// The Keychain ACCOUNT names this server's credentials occupy inside
    /// ``secretService`` — environment-variable names for stdio, header names for
    /// HTTP. Names only; a value never appears in this type.
    ///
    /// Total over the endpoint on purpose: a new transport arm cannot be added
    /// without the compiler demanding an answer here, and an arm that answered
    /// nothing would leak its secrets past removal.
    var secretAccountNames: [String] {
        switch endpoint {
        case let .streamableHTTP(_, headerKeys): headerKeys
        case let .stdio(_, _, environmentKeys): environmentKeys
        }
    }
}
