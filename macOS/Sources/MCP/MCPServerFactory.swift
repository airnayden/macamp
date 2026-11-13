// MCPServerFactory — one `MCP.Server`, wired to W1's registry at the `.external`
// tier, and the STATELESS transport it is started on.
//
// A FACTORY rather than a singleton because a `Server` is bound to exactly one
// transport, and ``MCPHTTPConnectionLoop`` gives every accepted TCP connection its
// own pair. Two SDK facts force that shape, and both were read out of the pinned
// 0.12.1 checkout rather than assumed:
//
//   1. `Server`'s built-in `initialize` handler answers a SECOND initialize with
//      `-32600 Server is already initialized`, and that guard is NOT gated on
//      `Configuration.strict`. One shared `Server` would therefore refuse the
//      second client outright — the exact failure this migration exists to end.
//   2. `StatelessHTTPServerTransport` keys its response waiters by JSON-RPC id
//      with a plain dictionary assignment, and `Server` dispatches every request
//      in its own `Task`. Two clients that both number a request `1` at the same
//      moment would overwrite one another's continuation: one answer delivered to
//      the wrong asker, the other parked forever.
//
// A connection-scoped pair makes both unreachable without a session, a map, a cap
// or an eviction rule — the loop serves one request at a time per connection, and
// a fresh connection is a fresh `Server`. Nothing is remembered BETWEEN requests:
// the transport mints no `Mcp-Session-Id`, requires none, and a POST that never
// initialized is still served (`Configuration.default` is non-strict).
import Foundation
import MCP
import Services

enum MCPServerFactory {
    static let serverName = "MacAMP"

    /// The bundle's marketing version, so a client's `initialize` result names the
    /// build it is actually talking to.
    static var serverVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0"
    }

    /// Grounding for the model on the other end. Protocol payload, not UI copy, so
    /// English and not localized — W1 note 2, and the same audience
    /// `LibraryChatInstructions` writes for.
    static let instructions = """
    These tools read one listener's local music library inside MacAMP. \
    Track titles, artists, albums, genres, years and listening statistics are available; \
    file paths and audio are not, and cannot be requested. \
    Nothing you do here changes the library: propose_playlist FILES a proposal that the \
    listener must review and apply inside MacAMP before anything is saved. \
    Call list_genres before guessing at a genre — it returns this library's own vocabulary.
    """

    static func make(source: MCPToolboxSource) async -> Server {
        let server = Server(
            name: serverName,
            version: serverVersion,
            instructions: instructions,
            // `listChanged: false` is the honest declaration: the registry is ten
            // fixed tools, and a profile switch changes the ROWS they return, never
            // the list. Promising notifications that can never fire would make a
            // client wait for one.
            capabilities: .init(tools: .init(listChanged: false))
        )
        await server.withMethodHandler(ListTools.self) { _ in
            guard let toolbox = await source.currentToolbox() else { return ListTools.Result(tools: []) }
            return ListTools.Result(tools: MCPToolboxBridge.tools(toolbox))
        }
        await server.withMethodHandler(CallTool.self) { parameters in
            await MCPToolboxBridge.call(
                parameters.name,
                arguments: parameters.arguments,
                toolbox: source.currentToolbox()
            )
        }
        return server
    }

    /// The transport a connection is served on.
    ///
    /// The pipeline is the SDK's stateless default with ONE substitution: origin
    /// validation is pinned to the port actually bound, where `.localhost()` would
    /// accept a loopback `Host`/`Origin` naming any port at all. There is no
    /// `SessionValidator` because there is no session to validate.
    static func transport(port: Int) -> StatelessHTTPServerTransport {
        StatelessHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [
                OriginValidator.localhost(port: port),
                AcceptHeaderValidator(mode: .jsonOnly),
                ContentTypeValidator(),
                ProtocolVersionValidator(),
            ])
        )
    }
}
