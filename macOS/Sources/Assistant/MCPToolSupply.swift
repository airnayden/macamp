// MCPToolSupply — the tools the listener's own MCP servers publish, held for the
// life of the process.
//
// ── WHY A SUPPLY, RATHER THAN A FETCH AT THE CALL SITE ───────────────────────
//
// `ConnectorChatEngine` takes its tool list at `init`, and the composition root
// mints one from `LibraryChatViewModel`'s SYNCHRONOUS `makeEngine` closure. What a
// server publishes, though, is only knowable after a `tools/list` round trip. So
// the projection cannot happen where the engine is built: something has to hold the
// answer, refresh it when the configuration changes, and be readable without
// awaiting. That is this type, and it is why it is read through a closure at
// engine-mint time rather than captured at graph-build time.
//
// ── THE CONNECTIONS ARE HELD STRONGLY, AND THAT IS THE WHOLE POINT ───────────
//
// `MCPClientManager.projectedTools()` captures the manager WEAKLY on purpose: a
// stray tool array must not keep a child process alive. The corollary is that every
// projected tool answers "is not reachable" the moment nothing else retains its
// manager — so ``connections`` below is the single strong reference this feature
// stands on. Emptying it is not a leak fix, it is an outage.
//
// ── ONE PASS PER CONFIGURATION, NEVER ONE PER TICK ───────────────────────────
//
// ``refresh()`` is a no-op when the usable set is byte-identical to the one already
// published, so an unrelated settings write cannot terminate and respawn a child
// process. A listener with no configured server therefore pays exactly nothing:
// `usableServers` is empty, no connection is built, no Keychain item is read, and
// the merged list is the library's own list unchanged.
//
// A server that is unreachable when its pass runs contributes NOTHING and is not
// retried until the configuration changes again or the app is relaunched. That is
// deliberate and is the same policy ``MCPClientManager`` states for its own
// reconnect: a retry loop would respawn programs on the listener's Mac on a
// schedule they never asked for.
//
// ── WHAT IS NOT HERE ─────────────────────────────────────────────────────────
//
// No `URLSession` and no `Process`. The transport is built by
// ``IntelligenceMCPProbe/transport(for:secrets:)`` — reused rather than restated so
// there is one definition of how MacAMP reaches a server — and that file's header
// explains why NAMING those two types is not the same as opening them.
import AIConnectorKit
import AIConnectorMCP
import Foundation

/// One external server's live connection, as this supply uses it.
///
/// A protocol rather than a concrete ``MCPClientManager`` for the repo's usual
/// reason — a test must be able to answer without a socket or a child process — and
/// for one specific to this file: the retention rule above is only observable
/// through a seam a test can hold the other end of.
protocol MCPToolProviding: AnyObject, Sendable {
    /// This server's tools, namespaced, budgeted and quarantine-framed.
    func projectedTools() async throws -> [AITool]
    /// Drops the connection. A command server terminates its child here.
    func disconnect() async
}

/// Free conformance — both are already the manager's shipped signatures.
extension MCPClientManager: MCPToolProviding {}

/// The tool list one CLOUD chat turn is published with.
enum LibraryChatToolMerge {
    /// THE PINNED ORDER: `library` first, then `builtIn`, then `external`.
    ///
    /// `Sequence<AITool>.tool(named:)` returns the FIRST match, so this order is
    /// what makes a frozen library name unshadowable: a server publishing its own
    /// `play_tracks` would have to come FIRST to be reached, and here it cannot.
    /// It additionally never arrives under that name at all, because
    /// ``MCPToolProjection`` namespaces every projected tool — but that is a second
    /// mechanism, and this is the one that keeps holding when a projection is
    /// bypassed or replaced.
    ///
    /// `builtIn` is MacAMP's OWN non-library tools — today exactly
    /// ``WebSearchTool``, published only once the listener enabled web suggestions
    /// AND accepted their disclosure. It sits in the MIDDLE rather than at either
    /// end, and both boundaries carry a claim:
    ///
    /// - AFTER `library`, so a built-in name can never shadow a frozen one. The
    ///   library's own tools are the ones whose names are a wire format.
    /// - BEFORE `external`, and NEVER inside that list, because a built-in is our
    ///   code calling a documented HTTP API while `mcp__` marks somebody else's
    ///   (see ``MCPToolProjection``'s header and ``WebSearchTool``'s). Merging
    ///   `web_search` into the external list — or letting it acquire that prefix —
    ///   would claim a provenance it does not have.
    ///
    /// The bare `web_search` name is therefore reachable exactly as published, and
    /// an external server publishing `web_search` of its own arrives namespaced and
    /// second, which is the same first-match rule applied one list further down.
    static func merged(library: [AITool], builtIn: [AITool], external: [AITool]) -> [AITool] {
        library + builtIn + external
    }
}

/// The enabled-and-consented servers' tools, refreshed when their configuration
/// changes and readable synchronously in between.
@MainActor
final class MCPToolSupply {
    /// Builds the live connection to one server, credentials already resolved.
    typealias ConnectionMaking = @MainActor (MCPServerDescriptor, [String: String]) -> any MCPToolProviding

    /// Every usable server's tools, in the order the listener arranged them.
    ///
    /// Empty until the first ``refresh()`` lands, and empty forever for a listener
    /// who configured nothing — which is what makes the cloud tier's published list
    /// identical to the pre-MCP one in that case.
    private(set) var tools: [AITool] = []

    private let store: MCPServerConfigStore
    private let makeConnection: ConnectionMaking
    /// STRONG, deliberately — see the file header.
    private var connections: [UUID: any MCPToolProviding] = [:]
    /// The descriptors ``tools`` was projected from, so an unchanged configuration
    /// costs nothing and a changed one is detected without asking a server.
    private var sources: [MCPServerDescriptor] = []

    init(store: MCPServerConfigStore, makeConnection: @escaping ConnectionMaking) {
        self.store = store
        self.makeConnection = makeConnection
    }

    /// Re-projects the usable servers' tools.
    ///
    /// - Returns: whether the published list was replaced, so a caller can rebuild
    ///   the conversation graph only when a live conversation would otherwise keep
    ///   answering from a tool list the listener has retired.
    @discardableResult
    func refresh() async -> Bool {
        let usable = store.usableServers
        guard usable != sources else { return false }
        let unchanged = Set(sources)
        sources = usable
        await retire(keeping: Set(usable.filter(unchanged.contains).map(\.id)))

        var projected: [AITool] = []
        for descriptor in usable {
            await projected.append(contentsOf: published(by: descriptor))
        }
        tools = projected
        return true
    }
}

// MARK: - One server at a time

private extension MCPToolSupply {
    /// What `descriptor` publishes, or nothing at all.
    ///
    /// A server that will not spawn, will not connect or will not list contributes
    /// an empty array rather than taking the whole turn's tool list down with it —
    /// the same disposition ``MCPToolProjection`` applies to a failed CALL, one
    /// level up.
    func published(by descriptor: MCPServerDescriptor) async -> [AITool] {
        guard let connection = await connection(for: descriptor),
              let projected = try? await connection.projectedTools()
        else { return [] }
        return projected
    }

    /// The live connection for `descriptor`, built on first use.
    ///
    /// A descriptor whose credentials cannot be read yields no connection at all:
    /// an empty bearer is a wrong answer a server rejects in a way that reads like
    /// a bad token, which is the same call ``IntelligenceMCPProbe`` makes.
    func connection(for descriptor: MCPServerDescriptor) async -> (any MCPToolProviding)? {
        if let live = connections[descriptor.id] { return live }
        guard let secrets = try? await store.resolvedSecrets(for: descriptor) else { return nil }
        let made = makeConnection(descriptor, secrets)
        connections[descriptor.id] = made
        return made
    }

    /// Hangs up on every connection the new configuration no longer describes.
    ///
    /// A server whose descriptor CHANGED is retired too, not just one that was
    /// removed: the old connection points at the old command line, and reusing it
    /// would keep talking to a program the listener has edited away.
    func retire(keeping survivors: Set<UUID>) async {
        let retiring = connections.filter { survivors.contains($0.key) == false }
        for (id, connection) in retiring {
            connections[id] = nil
            await connection.disconnect()
        }
    }
}

// MARK: - Live wiring

extension MCPToolSupply {
    /// The supply the shipped app runs on: the real Keychain, and connections that
    /// really reach a server.
    static func live(settings: AppSettings) -> MCPToolSupply {
        MCPToolSupply(
            store: MCPServerConfigStore(settings: settings, secrets: KeychainSecretStore())
        ) { descriptor, secrets in
            MCPClientManager(
                descriptor: descriptor,
                transportFactory: IntelligenceMCPProbe.transportFactory(secrets: secrets)
            )
        }
    }
}
