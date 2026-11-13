// MCPServerHandlerTests — the REAL protocol, over the SDK's in-memory transport.
//
// A real `MCP.Client` talks to the real `MCP.Server` this shell builds: initialize,
// capability negotiation, `tools/list`, `tools/call`. Everything but the socket is
// the shipping path, so a handler wired to the wrong method name or a capability we
// declare but do not serve fails HERE rather than in front of a live agent.
//
// The proposal test is the one that matters: a track seeded into a real database,
// proposed through the real `propose_playlist` over the real wire, arriving in the
// SAME `ProposalStore` the Assistant pane reviews — with NOTHING written.
import Foundation
import GRDB
@testable import MacAMP
import MCP
import Persistence
import Services
import Testing
import ViewModels

@Suite("MCP server handlers", .serialized)
@MainActor
struct MCPServerHandlerTests {
    private struct Harness {
        let database: AppDatabase
        let store: ProposalStore
        let toolbox: LibraryToolbox
    }

    private static func harness(seeding tracks: [String] = []) throws -> Harness {
        let environment = AppEnvironment.preview()
        let database = environment.database
        try database.writer.write { db in
            for (index, title) in tracks.enumerated() {
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
        let store = ProposalStore()
        return Harness(
            database: database,
            store: store,
            toolbox: AppEnvironment.makeExternalToolbox(
                database: database,
                profileId: ProfileRecord.guestID,
                proposals: store
            )
        )
    }

    /// A connected client/server pair over the SDK's own in-memory transport.
    private static func connect(_ toolbox: LibraryToolbox?) async throws -> (Client, Server) {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let source = MCPToolboxSource(currentToolbox: { toolbox })
        let server = await MCPServerFactory.make(source: source)
        try await server.start(transport: serverTransport)
        let client = Client(name: "macampMacTests", version: "1.0")
        try await client.connect(transport: clientTransport)
        return (client, server)
    }

    // MARK: Lifecycle

    @Test("initialize names this app, its version, and exactly the tools capability")
    func initializeNegotiates() async throws {
        let harness = try Self.harness()
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let server = await MCPServerFactory.make(source: MCPToolboxSource(currentToolbox: { harness.toolbox }))
        try await server.start(transport: serverTransport)
        let client = Client(name: "macampMacTests", version: "1.0")
        let result = try await client.connect(transport: clientTransport)
        defer { Task { await server.stop() } }

        #expect(result.serverInfo.name == MCPServerFactory.serverName)
        #expect(result.capabilities.tools != nil)
        // Declared false on purpose: a fixed registry, so the list never changes.
        #expect(result.capabilities.tools?.listChanged == false)
        #expect(result.capabilities.resources == nil)
        #expect(result.capabilities.prompts == nil)
        #expect(result.instructions?.isEmpty == false)
        await client.disconnect()
    }

    // MARK: tools/list

    @Test("tools/list publishes the external tier with its schemas attached")
    func toolsListPublishesTheExternalTier() async throws {
        let harness = try Self.harness()
        let (client, server) = try await Self.connect(harness.toolbox)
        defer { Task { await server.stop() } }

        let listed = try await client.listTools()
        #expect(listed.tools.map(\.name) == harness.toolbox.tools(profile: .external).map(\.name))
        #expect(listed.tools.allSatisfy { $0.inputSchema.objectValue?["type"]?.stringValue == "object" })
        #expect(listed.tools.allSatisfy { $0.description?.isEmpty == false })
        await client.disconnect()
    }

    @Test("tools/list publishes nothing when the library is switched off")
    func toolsListIsEmptyWithoutALibrary() async throws {
        let (client, server) = try await Self.connect(nil)
        defer { Task { await server.stop() } }
        #expect(try await client.listTools().tools.isEmpty)
        await client.disconnect()
    }

    // MARK: tools/call

    @Test("tools/call reaches the real library and returns the seeded row, with no file path")
    func toolsCallReachesTheLibrary() async throws {
        let harness = try Self.harness(seeding: ["Aurora Anthem"])
        let (client, server) = try await Self.connect(harness.toolbox)
        defer { Task { await server.stop() } }

        let result = try await client.callTool(name: "search_tracks", arguments: ["query": .string("Aurora")])
        #expect(result.isError != true)
        guard case let .text(text, _, _) = try #require(result.content.first) else {
            Issue.record("expected text content")
            return
        }
        #expect(text.contains("Aurora Anthem"))
        // The privacy invariant, asserted over the WIRE rather than over a renderer.
        #expect(!text.contains("/Fixtures"))
        #expect(!text.contains(".flac"))
        await client.disconnect()
    }

    @Test("a hallucinated tool name comes back as isError, over the real protocol")
    func unknownToolsSurfaceAsErrors() async throws {
        let harness = try Self.harness()
        let (client, server) = try await Self.connect(harness.toolbox)
        defer { Task { await server.stop() } }
        #expect(try await client.callTool(name: "rm_rf").isError == true)
        await client.disconnect()
    }

    // MARK: The proposal

    @Test("propose_playlist over the wire FILES into the shell's store and writes nothing")
    func proposalsReachTheReviewQueue() async throws {
        let harness = try Self.harness(seeding: ["Aurora Anthem", "Neon Drive"])
        let ids = try await harness.database.writer.read { db in
            try Int64.fetchAll(db, sql: "SELECT id FROM track ORDER BY id")
        }
        #expect(ids.count == 2)
        let (client, server) = try await Self.connect(harness.toolbox)
        defer { Task { await server.stop() } }

        #expect(harness.store.proposals.isEmpty)
        let result = try await client.callTool(
            name: "propose_playlist",
            arguments: [
                "name": .string("Night Drive"),
                "track_ids": .array(ids.map { .int(Int($0)) }),
            ]
        )
        #expect(result.isError != true)

        // FILED, not written: one reviewable proposal, and no playlist row.
        #expect(harness.store.proposals.count == 1)
        let filed = try #require(harness.store.proposals.first)
        guard case let .createPlaylist(request) = filed.kind else {
            Issue.record("expected a createPlaylist proposal")
            return
        }
        #expect(request.name == "Night Drive")
        #expect(filed.affectedCount == 2)
        let playlistCount = try await harness.database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playlist") ?? -1
        }
        #expect(playlistCount == 0)
        await client.disconnect()
    }

    // MARK: Profile scoping

    @Test("the toolbox is read per call, so a profile switch is visible without reconnecting")
    func theToolboxIsReadPerCall() async throws {
        let harness = try Self.harness(seeding: ["Aurora Anthem"])
        // The source starts empty and gains the library while the session is live —
        // the same shape a profile switch produces at the composition root.
        let box = ToolboxBox()
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let server = await MCPServerFactory.make(source: MCPToolboxSource(currentToolbox: { await box.value }))
        try await server.start(transport: serverTransport)
        let client = Client(name: "macampMacTests", version: "1.0")
        try await client.connect(transport: clientTransport)
        defer { Task { await server.stop() } }

        #expect(try await client.callTool(name: "list_genres").isError == true)
        await box.set(harness.toolbox)
        #expect(try await client.callTool(name: "list_genres").isError != true)
        await client.disconnect()
    }
}

/// A swappable toolbox slot, so a test can move the library under a live session.
private actor ToolboxBox {
    var value: LibraryToolbox?

    func set(_ toolbox: LibraryToolbox) {
        value = toolbox
    }
}
