// MCPStatelessTransportTests — the WIRE SHAPE the stateless migration promises.
//
// Every claim here was previously observable only by running the app and pointing
// a real client at it, which is why the session-registry defect it replaces could
// survive a green test run: `MCPServerHandlerTests` drives `InMemoryTransport`,
// which has no HTTP verbs, no headers and no sessions to get wrong.
//
// So this suite drives the PRODUCTION composition — `MCPServerFactory.transport`
// and `MCPServerFactory.make`, the same two calls `MCPHTTPConnectionLoop` makes —
// through `handleRequest`, using the framer's own `MCPHTTPRequestHead`. It is the
// whole server minus the socket.
import Foundation
import GRDB
@testable import MacAMP
import MCP
import Persistence
import Services
import Testing
import ViewModels

@Suite("MCP stateless transport", .serialized)
@MainActor
struct MCPStatelessTransportTests {
    private typealias Pair = (transport: StatelessHTTPServerTransport, server: Server)

    private static let port = 46114
    private static let listBody = #"{"jsonrpc":"2.0","id":7,"method":"tools/list"}"#

    /// One accepted connection's worth of server: exactly what the loop builds.
    private static func pair(_ toolbox: LibraryToolbox? = nil) async throws -> Pair {
        let transport = MCPServerFactory.transport(port: port)
        let server = await MCPServerFactory.make(source: MCPToolboxSource(currentToolbox: { toolbox }))
        try await server.start(transport: transport)
        return (transport, server)
    }

    private static func seededToolbox(_ titles: [String] = []) throws -> LibraryToolbox {
        let database = AppEnvironment.preview().database
        try database.writer.write { db in
            for (index, title) in titles.enumerated() {
                var record = TrackRecord(
                    filePath: "/Fixtures/\(index).flac",
                    title: title,
                    artistName: "Fixture Artist",
                    albumTitle: "Fixture Album",
                    genre: "Synthwave",
                    year: 1995
                )
                try record.insert(db)
            }
        }
        return AppEnvironment.makeExternalToolbox(
            database: database,
            profileId: ProfileRecord.guestID,
            proposals: ProposalStore()
        )
    }

    private static func request(
        method: String = "POST",
        headers: [String: String] = [:],
        body: String = ""
    ) -> HTTPRequest {
        var merged = [
            "Host": "127.0.0.1:\(port)",
            "Content-Type": "application/json",
            // What every real MCP client sends. Pinned because `.jsonOnly` COULD
            // have meant "application/json and nothing else"; it does not, and
            // interop with a 2025-11-25-speaking client depends on that.
            "Accept": "application/json, text/event-stream",
        ]
        merged.merge(headers) { _, new in new }
        return MCPHTTPRequestHead(method: method, target: "/mcp", headers: merged, body: Data(body.utf8))
            .transportRequest
    }

    private static func initializeBody(version: String = "2025-11-25", id: Int = 1) -> String {
        """
        {"jsonrpc":"2.0","id":\(id),"method":"initialize","params":{"protocolVersion":"\(version)",\
        "capabilities":{},"clientInfo":{"name":"macampMacTests","version":"1.0"}}}
        """
    }

    private static func envelope(_ response: HTTPResponse) throws -> [String: Any] {
        let data = try #require(response.bodyData)
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    private static func result(_ response: HTTPResponse) throws -> [String: Any] {
        let value = try envelope(response)["result"]
        return try #require(value as? [String: Any])
    }

    private static func carriesNoSession(_ response: HTTPResponse) -> Bool {
        let wanted = HTTPHeaderName.sessionID.lowercased()
        return response.headers.keys.allSatisfy { $0.lowercased() != wanted }
    }
}

// MARK: - No session, anywhere

extension MCPStatelessTransportTests {
    @Test("initialize mints NO session id, and answers plain JSON rather than an SSE stream")
    func initializeIssuesNoSessionAndNoStream() async throws {
        let (transport, server) = try await Self.pair()
        defer { Task { await server.stop() } }

        let response = await transport.handleRequest(Self.request(body: Self.initializeBody()))
        guard case let .data(_, headers) = response else {
            Issue.record("expected a length-framed JSON body, got \(response)")
            return
        }
        #expect(response.statusCode == 200)
        #expect(headers[HTTPHeaderName.contentType] == "application/json")
        #expect(Self.carriesNoSession(response))

        let result = try Self.result(response)
        #expect(result["protocolVersion"] as? String == "2025-11-25")
        let info = result["serverInfo"] as? [String: Any]
        #expect(info?["name"] as? String == MCPServerFactory.serverName)
    }

    @Test("no response on any verb carries a session header")
    func noResponseCarriesASessionHeader() async throws {
        let toolbox = try Self.seededToolbox(["Aurora Anthem"])
        let (transport, server) = try await Self.pair(toolbox)
        defer { Task { await server.stop() } }

        let initialize = await transport.handleRequest(Self.request(body: Self.initializeBody()))
        let list = await transport.handleRequest(Self.request(body: Self.listBody))
        let delete = await transport.handleRequest(Self.request(method: "DELETE"))
        let get = await transport.handleRequest(Self.request(method: "GET"))

        let responses = [initialize, list, delete, get]
        #expect(responses.allSatisfy(Self.carriesNoSession))
        #expect(responses.map(\.statusCode) == [200, 200, 405, 405])
    }

    @Test("a request that presents a session id is served anyway — the header means nothing now")
    func aStaleSessionHeaderIsIgnored() async throws {
        let toolbox = try Self.seededToolbox()
        let (transport, server) = try await Self.pair(toolbox)
        defer { Task { await server.stop() } }

        let response = await transport.handleRequest(Self.request(
            headers: [HTTPHeaderName.sessionID: "642E74C2-CC93-44B9-80AF-49983A0096EA"],
            body: Self.listBody
        ))
        #expect(response.statusCode == 200)
        let tools = try Self.result(response)["tools"] as? [[String: Any]]
        #expect(tools?.isEmpty == false)
    }
}

// MARK: - The verbs

extension MCPStatelessTransportTests {
    @Test("DELETE is 405 with Allow: POST — a client's quit no longer terminates anything")
    func deleteIsMethodNotAllowed() async throws {
        let (transport, server) = try await Self.pair()
        defer { Task { await server.stop() } }

        let response = await transport.handleRequest(Self.request(method: "DELETE"))
        #expect(response.statusCode == 405)
        #expect(response.headers[HTTPHeaderName.allow] == "POST")

        // And the transport SURVIVES it, where the stateful one latched
        // `terminated` and answered 404 forever after.
        let after = await transport.handleRequest(Self.request(body: Self.initializeBody()))
        #expect(after.statusCode == 200)
    }

    @Test("GET is 405 too: there is no standalone SSE stream to open")
    func getIsMethodNotAllowed() async throws {
        let (transport, server) = try await Self.pair()
        defer { Task { await server.stop() } }
        let response = await transport.handleRequest(Self.request(method: "GET"))
        #expect(response.statusCode == 405)
    }

    @Test("a notification is 202 Accepted with no body")
    func notificationsAreAccepted() async throws {
        let (transport, server) = try await Self.pair()
        defer { Task { await server.stop() } }

        let body = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
        let response = await transport.handleRequest(Self.request(body: body))
        #expect(response.statusCode == 202)
        #expect(response.bodyData == nil)
    }
}

// MARK: - Every POST is self-contained

extension MCPStatelessTransportTests {
    @Test("tools/list is served with NO initialize first — that is what stateless means")
    func aCallWithNoInitializeIsServed() async throws {
        let toolbox = try Self.seededToolbox()
        let (transport, server) = try await Self.pair(toolbox)
        defer { Task { await server.stop() } }

        let response = await transport.handleRequest(Self.request(body: Self.listBody))
        #expect(response.statusCode == 200)
        let listed = try Self.result(response)["tools"] as? [[String: Any]]
        let names = listed?.compactMap { $0["name"] as? String }
        #expect(names == toolbox.tools(profile: .external).map(\.name))
    }

    @Test("tools/call reaches the real library over the transport, with no file path and no session")
    func aToolCallReachesTheLibrary() async throws {
        let toolbox = try Self.seededToolbox(["Aurora Anthem"])
        let (transport, server) = try await Self.pair(toolbox)
        defer { Task { await server.stop() } }

        let response = await transport.handleRequest(Self.request(body: """
        {"jsonrpc":"2.0","id":3,"method":"tools/call",\
        "params":{"name":"search_tracks","arguments":{"query":"Aurora"}}}
        """))
        #expect(response.statusCode == 200)
        let content = try Self.result(response)["content"] as? [[String: Any]]
        let text = try #require(content?.first?["text"] as? String)
        #expect(text.contains("Aurora Anthem"))
        #expect(!text.contains("/Fixtures"))
        #expect(!text.contains(".flac"))
        #expect(Self.carriesNoSession(response))
    }
}

// MARK: - Two clients, and why the pair is connection-scoped

extension MCPStatelessTransportTests {
    @Test("two clients each initialize successfully — the original bricking scenario, gone")
    func twoClientsBothInitialize() async throws {
        let toolbox = try Self.seededToolbox(["Aurora Anthem"])
        let first = try await Self.pair(toolbox)
        let second = try await Self.pair(toolbox)
        defer {
            Task {
                await first.server.stop()
                await second.server.stop()
            }
        }

        for connection in [first, second] {
            let response = await connection.transport.handleRequest(Self.request(body: Self.initializeBody()))
            #expect(response.statusCode == 200)
            let negotiated = try Self.result(response)["protocolVersion"] as? String
            #expect(negotiated == "2025-11-25")
            #expect(Self.carriesNoSession(response))
        }
    }

    @Test("the SECOND initialize on ONE pair is refused by the SDK — which is why a connection owns its own")
    func aSecondInitializeOnOnePairIsRefused() async throws {
        let (transport, server) = try await Self.pair()
        defer { Task { await server.stop() } }

        let first = await transport.handleRequest(Self.request(body: Self.initializeBody()))
        #expect(first.statusCode == 200)

        // 200 at the HTTP layer, an error inside the envelope: `Server` latches
        // `isInitialized`, and that guard is NOT gated on `Configuration.strict`.
        let repeated = await transport.handleRequest(Self.request(body: Self.initializeBody(id: 2)))
        let error = try Self.envelope(repeated)["error"] as? [String: Any]
        #expect((error?["message"] as? String)?.contains("already initialized") == true)
    }
}

// MARK: - Negotiation, and the validators that remain

extension MCPStatelessTransportTests {
    @Test("an unsupported future revision negotiates DOWN to this SDK's latest")
    func anUnknownVersionNegotiatesDown() async throws {
        let (transport, server) = try await Self.pair()
        defer { Task { await server.stop() } }

        let body = Self.initializeBody(version: "2026-07-28")
        let response = await transport.handleRequest(Self.request(body: body))
        let negotiated = try Self.result(response)["protocolVersion"] as? String
        #expect(negotiated == Version.latest)
        #expect(Version.supported.contains("2025-11-25"))
    }

    @Test("Accept must name application/json; the pair every real client sends is served")
    func acceptIsJSONOnlyButToleratesSSE() async throws {
        let (transport, server) = try await Self.pair()
        defer { Task { await server.stop() } }

        let refused = await transport.handleRequest(Self.request(
            headers: ["Accept": "text/event-stream"],
            body: Self.initializeBody()
        ))
        #expect(refused.statusCode == 406)

        let served = await transport.handleRequest(Self.request(
            headers: ["Accept": "application/json"],
            body: Self.initializeBody()
        ))
        #expect(served.statusCode == 200)
    }

    @Test("origin validation survives the swap, pinned to the bound port")
    func aForeignOriginIsRefused() async throws {
        let toolbox = try Self.seededToolbox(["Aurora Anthem"])
        let (transport, server) = try await Self.pair(toolbox)
        defer { Task { await server.stop() } }

        let rebound = await transport.handleRequest(Self.request(
            headers: [HTTPHeaderName.origin: "http://attacker.example"],
            body: Self.initializeBody()
        ))
        #expect(rebound.statusCode == 403)

        let otherPort = await transport.handleRequest(Self.request(
            headers: ["Host": "127.0.0.1:1"],
            body: Self.initializeBody()
        ))
        #expect(otherPort.statusCode == 421)
    }
}
