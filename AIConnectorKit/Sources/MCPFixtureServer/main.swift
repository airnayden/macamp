// MCPFixtureServer — a real MCP server over stdio, existing only so
// ``MCPProcessTransport`` can be tested against a child process rather than
// against a mock of one.
//
// ── WHY THIS TARGET EXISTS AT ALL ────────────────────────────────────────────
//
// `MCPClientManagerTests` covers the client end thoroughly over
// `InMemoryTransport`, and that fake exercises ZERO of what
// `MCPProcessTransport` is for: spawning a child, wiring its pipes, draining its
// stderr, and terminating it. Those are precisely the parts that fail in
// production and cannot fail in a test that never forks. So the suite needs a
// counterparty that is a real program speaking real JSON-RPC over real pipes, and
// it needs to be one this repo controls — an SDK example whose presence in the
// 0.12.1 pin is unverified would make the gate conditional on somebody else's
// packaging decisions.
//
// It is deliberately tiny: `initialize` (handled by the SDK), `tools/list` with
// one `echo` tool, and `tools/call`. Nothing here is shipped in the app.
import Foundation
import MCP

let echoTool = Tool(
    name: "echo",
    description: "Returns its text argument unchanged.",
    inputSchema: .object([
        "type": .string("object"),
        "properties": .object(["text": .object(["type": .string("string")])]),
        "required": .array([.string("text")]),
    ])
)

let server = Server(
    name: "MCPFixtureServer",
    version: "1.0.0",
    capabilities: .init(tools: .init(listChanged: false))
)

await server.withMethodHandler(ListTools.self) { _ in
    ListTools.Result(tools: [echoTool])
}

await server.withMethodHandler(CallTool.self) { parameters in
    guard parameters.name == echoTool.name else {
        return CallTool.Result(
            content: [.text(text: "no such tool: \(parameters.name)", annotations: nil, _meta: nil)],
            isError: true
        )
    }
    let text = parameters.arguments?["text"]?.stringValue ?? ""
    return CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)])
}

try await server.start(transport: StdioTransport())
await server.waitUntilCompleted()
