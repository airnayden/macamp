// MCPServerDescriptor — how MacAMP reaches ONE external MCP server.
//
// ── THIS TARGET IS THE CLIENT HALF, NOT THE SERVER HALF ──────────────────────
//
// MacAMP already SERVES MCP: `macOS/Sources/MCP/` publishes the library toolbox to
// external programs. This target is the mirror image — MacAMP as a CLIENT of
// somebody else's MCP server — and it is a separate target for a link-time reason,
// not a tidiness one: it is the only place the MCP Swift SDK is linked, so an
// embedder that wants plain provider connectors can leave the whole protocol stack
// out. It depends on the CORE `AIConnectorKit` target because an external server's
// tools have to arrive as ``AITool`` to be callable, and never on PlayerCore.
//
// ── REACHING A SERVER IS TWO CASES, AND ONLY TWO ─────────────────────────────
//
// A server is either already listening somewhere (an address) or has to be started
// by us (an executable). ``Endpoint`` is that fork and nothing more. The nested
// type is `Endpoint` rather than the more obvious `Transport` on purpose: the SDK
// vends a `Transport` PROTOCOL that this module conforms concrete types to, and two
// spellings of the same word — one a value describing an address, one a live
// connection — is a name collision waiting to be resolved the wrong way.
//
// ── CREDENTIALS TRAVEL AS NAMES, NEVER AS VALUES ─────────────────────────────
//
// A stdio server is frequently a CLI that reads its credential out of the
// environment (`GITHUB_TOKEN`, `BRAVE_API_KEY`); an HTTP server is frequently one
// that wants a bearer token in a header (`Authorization`). This descriptor
// therefore stores only KEY NAMES on both arms —
// ``Endpoint/stdio(command:arguments:environmentKeys:)`` and
// ``Endpoint/streamableHTTP(url:headerKeys:)``. The values live in the Keychain
// under ``MCPServerSecretService`` and are resolved at connect time by whoever
// builds the transport. That is not a convention, it is what makes this type safe
// to write to disk as JSON, safe to log, and safe to put in an error message.
//
// The two arms are deliberately SYMMETRIC. An HTTP endpoint that carried only a
// URL would have nowhere to record which headers hold a credential, so removing
// the server could not know which Keychain entries to purge — the orphaned secret
// would outlive the configuration that explained it.
import Foundation
import MCP

/// One external MCP server MacAMP may connect to.
///
/// `Codable` because this is the unit a later todo persists as JSON in settings;
/// there is deliberately no secret-bearing field to leave out of that encoding.
public struct MCPServerDescriptor: Sendable, Equatable, Hashable, Identifiable, Codable {
    /// Where the server is, or how to start it.
    public enum Endpoint: Sendable, Equatable, Hashable, Codable {
        /// Already listening; speak Streamable HTTP (with SSE) to this URL.
        ///
        /// - Parameters:
        ///   - url: Where the server answers.
        ///   - headerKeys: NAMES of request headers that carry a credential.
        ///     Never values — see this file's header.
        case streamableHTTP(url: URL, headerKeys: [String])

        /// Not running; launch this executable and speak over its pipes.
        ///
        /// - Parameters:
        ///   - command: An absolute path, or a bare name resolved through `PATH`.
        ///   - arguments: Argument vector, excluding the command itself.
        ///   - environmentKeys: NAMES of environment variables the child needs.
        ///     Never values — see this file's header.
        case stdio(command: String, arguments: [String], environmentKeys: [String])
    }

    /// Stable identity, used to key user consent, saved configuration and the
    /// Keychain namespace a later todo derives from it.
    public let id: UUID

    /// The name shown to the listener, and the name the model sees inside every
    /// projected tool name and quarantine frame.
    public var name: String

    public var endpoint: Endpoint

    /// Whether the listener wants this server used at all.
    public var isEnabled: Bool

    /// Whether the listener has read and accepted the trust warning for this
    /// server. Separate from ``isEnabled`` because consent is a one-time act and
    /// enablement is a toggle: revoking the toggle must not silently re-ask.
    public var isConsented: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        endpoint: Endpoint,
        isEnabled: Bool = false,
        isConsented: Bool = false
    ) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.isEnabled = isEnabled
        self.isConsented = isConsented
    }
}

public extension MCPServerDescriptor {
    /// Whether this server may be contacted right now.
    ///
    /// Both flags, always. A server the listener enabled before the consent sheet
    /// existed must not become reachable by upgrade.
    var isUsable: Bool {
        isEnabled && isConsented
    }

    /// The MCP revision this build negotiates, read from the pinned SDK rather
    /// than restated — a hardcoded copy would drift silently past a pin bump.
    static var protocolVersion: String {
        MCP.Version.latest
    }
}
