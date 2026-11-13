// MCPControlGrantTests — what an EXTERNAL client can see and do, per grant.
//
// The grant is implemented by publishing a different registry, and the transport
// is stateless — so the two properties that matter are wire-visible and neither is
// covered by the toolbox's own suites:
//
//   1. Ungranted, the four control tools are ABSENT from `tools/list`, and calling
//      one by name is answered as an UNKNOWN TOOL. A client cannot discover a
//      capability it was not given, and cannot reach one by guessing its name.
//   2. Granted, they are INSERTED contiguously and every name an existing client
//      already indexed keeps its position.
//
// Driven through `MCPServerFactory.transport(port:)` + `make(source:)` over
// `handleRequest`, the same composition `MCPHTTPConnectionLoop` builds, because
// `InMemoryTransport` cannot express any of this.
import Foundation
import GRDB
@testable import MacAMP
import MCP
import Persistence
import Services
import Testing
import ViewModels

@Suite("MCP control grant", .serialized)
@MainActor
struct MCPControlGrantTests {
    private static let port = 46114
    private static let listBody = #"{"jsonrpc":"2.0","id":11,"method":"tools/list"}"#

    private static let libraryToolNames = [
        "search_tracks",
        "list_genres",
        "get_tracks",
        "get_track_features",
        "get_listening_stats",
        "list_playlists",
        "get_playlist",
        "sample_tracks",
        "propose_playlist",
        "match_tracks",
    ]

    /// The library names registered BEFORE the conditional control block. See
    /// `LibraryToolbox.makeTools`: `match_tracks` is registered after it and is
    /// therefore last at either grant.
    private static let leadingLibraryToolNames = Array(libraryToolNames.dropLast())

    // MARK: Fixtures

    /// Both registries, the player they share, and the queue they file into.
    private struct Fixtures {
        let reading: LibraryToolbox
        let controlling: LibraryToolbox
        let player: RecordingPlaybackController
        let proposals: ProposalStore
    }

    private static func toolboxes() throws -> Fixtures {
        let database = AppEnvironment.preview().database
        try database.writer.write { db in
            var record = TrackRecord(
                filePath: "/Fixtures/aurora.flac",
                title: "Aurora Anthem",
                artistName: "Fixture Artist",
                albumTitle: "Fixture Album",
                genre: "Synthwave",
                year: 1995
            )
            try record.insert(db)
        }
        let player = RecordingPlaybackController()
        let proposals = ProposalStore()
        let pair = AppEnvironment.makeExternalToolboxes(
            database: database,
            profileId: ProfileRecord.guestID,
            proposals: proposals,
            playback: player
        )
        return Fixtures(
            reading: pair.reading,
            controlling: pair.controlling,
            player: player,
            proposals: proposals
        )
    }

    private static func names(servedBy toolbox: LibraryToolbox) async throws -> [String] {
        let transport = MCPServerFactory.transport(port: port)
        let server = await MCPServerFactory.make(source: MCPToolboxSource(currentToolbox: { toolbox }))
        try await server.start(transport: transport)
        defer { Task { await server.stop() } }

        let response = await transport.handleRequest(request(body: listBody))
        #expect(response.statusCode == 200)
        let listed = try result(response)["tools"] as? [[String: Any]]
        return try #require(listed?.compactMap { $0["name"] as? String })
    }

    private static func call(
        _ name: String,
        arguments: String,
        on toolbox: LibraryToolbox
    ) async throws -> (text: String, isError: Bool) {
        let transport = MCPServerFactory.transport(port: port)
        let server = await MCPServerFactory.make(source: MCPToolboxSource(currentToolbox: { toolbox }))
        try await server.start(transport: transport)
        defer { Task { await server.stop() } }

        let body = """
        {"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"\(name)","arguments":\(arguments)}}
        """
        let response = await transport.handleRequest(request(body: body))
        let payload = try result(response)
        let content = try #require(payload["content"] as? [[String: Any]])
        let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        return (text, payload["isError"] as? Bool ?? false)
    }

    private static func request(body: String) -> HTTPRequest {
        MCPHTTPRequestHead(
            method: "POST",
            target: "/mcp",
            headers: [
                "Host": "127.0.0.1:\(port)",
                "Content-Type": "application/json",
                "Accept": "application/json, text/event-stream",
            ],
            body: Data(body.utf8)
        ).transportRequest
    }

    private static func result(_ response: HTTPResponse) throws -> [String: Any] {
        let data = try #require(response.bodyData)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(object["result"] as? [String: Any])
    }
}

// MARK: - The matrix

extension MCPControlGrantTests {
    @Test("ungranted, tools/list is exactly the ten library tools")
    func ungrantedListIsUnchanged() async throws {
        let fixtures = try Self.toolboxes()
        #expect(try await Self.names(servedBy: fixtures.reading) == Self.libraryToolNames)
    }

    @Test("granted, the four control tools are INSERTED and every library name keeps its place")
    func grantedListAppendsControlTools() async throws {
        let fixtures = try Self.toolboxes()
        let names = try await Self.names(servedBy: fixtures.controlling)
        #expect(Array(names.prefix(Self.leadingLibraryToolNames.count)) == Self.leadingLibraryToolNames)
        // The control four are CONTIGUOUS, and `match_tracks` is last at either
        // grant — so the granted list no longer ENDS in the control block.
        let afterLeading = names.dropFirst(Self.leadingLibraryToolNames.count)
        #expect(Array(afterLeading.dropLast()) == LibraryToolbox.controlToolNames)
        #expect(names.last == "match_tracks")
    }

    @Test("ungranted, naming a control tool is an UNKNOWN TOOL and the player is not touched")
    func ungrantedControlCallIsUnknown() async throws {
        let fixtures = try Self.toolboxes()
        for name in LibraryToolbox.controlToolNames {
            let outcome = try await Self.call(name, arguments: #"{"track_ids":[1]}"#, on: fixtures.reading)
            #expect(outcome.isError, "\(name) must be an error: it is not published at this grant")
            // The bridge's refusal ENUMERATES what does exist, so the assertion is
            // on that list: a client must not be able to learn the control tools
            // exist even from the error it gets for guessing one.
            let halves = outcome.text.components(separatedBy: "Available tools: ")
            #expect(halves.first?.trimmingCharacters(in: .whitespaces) == "There is no tool named \(name).")
            let offered = (halves.last ?? "")
                .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
                .components(separatedBy: ", ")
            #expect(offered == Self.libraryToolNames)
        }
        #expect(await fixtures.player.playCalls.isEmpty)
        #expect(await fixtures.player.transportCalls.isEmpty)
    }

    @Test("granted, an external play_tracks reaches the player over the wire")
    func grantedControlCallReachesThePlayer() async throws {
        let fixtures = try Self.toolboxes()
        let outcome = try await Self.call(
            "play_tracks",
            arguments: #"{"track_ids":[1]}"#,
            on: fixtures.controlling
        )
        #expect(!outcome.isError)
        #expect(outcome.text.contains("Playing #1 Aurora Anthem — Fixture Artist"))
        #expect(await fixtures.player.playCalls == [[1]])
    }

    @Test("granted, an invisible id is refused honestly and is NOT a protocol error")
    func grantedRefusalIsNotAnError() async throws {
        let fixtures = try Self.toolboxes()
        let outcome = try await Self.call(
            "play_tracks",
            arguments: #"{"track_ids":[4242]}"#,
            on: fixtures.controlling
        )
        // W5 note 6: a refusal is `isError: false`, because it is model-actionable.
        #expect(!outcome.isError)
        #expect(outcome.text.contains("#4242 is not in this listener's library"))
        #expect(await fixtures.player.playCalls.isEmpty)
    }

    @Test("no control answer names a file, over the wire")
    func controlAnswersCarryNoPaths() async throws {
        let fixtures = try Self.toolboxes()
        _ = try await Self.call("play_tracks", arguments: #"{"track_ids":[1]}"#, on: fixtures.controlling)
        let state = try await Self.call("get_playback_state", arguments: "{}", on: fixtures.controlling)
        for marker in ["/Fixtures", ".flac", "filePath"] {
            #expect(!state.text.contains(marker), "the playback report leaked \"\(marker)\"")
        }
    }
}

// MARK: - The composition that chooses between them

extension MCPControlGrantTests {
    @Test("the environment publishes the controlling registry only while the grant is on")
    func theEnvironmentSwitchesAtCallTime() throws {
        let environment = AppEnvironment.preview()
        let settings = AppSettings(defaults: UserDefaults(suiteName: "mcp.control.grant") ?? .standard)
        settings.intelligenceEnabled = true
        environment.connectAI(settings: settings)

        let stack = try #require(environment.intelligence)

        environment.externalControlGranted = false
        #expect(environment.currentExternalToolbox?.allTools.count == stack.externalToolbox.allTools.count)
        #expect(environment.currentExternalToolbox?.tool(named: "play_tracks") == nil)

        environment.externalControlGranted = true
        #expect(environment.currentExternalToolbox?.tool(named: "play_tracks") != nil)
        #expect(
            environment.currentExternalToolbox?.allTools.count
                == stack.externalToolbox.allTools.count + LibraryToolbox.controlToolNames.count
        )

        UserDefaults.standard.removePersistentDomain(forName: "mcp.control.grant")
    }

    @Test("both external registries file into the SAME review queue")
    func bothRegistriesShareOneProposalQueue() async throws {
        let fixtures = try Self.toolboxes()
        for (toolbox, name) in [(fixtures.reading, "Read"), (fixtures.controlling, "Control")] {
            _ = await toolbox.run(
                "propose_playlist",
                arguments: ToolArguments(["name": .string(name), "track_ids": .array([.int(1)])]),
                profile: .external
            )
        }
        // One `LibraryChatProposalFiler` behind both registries, so flipping the
        // control grant can never orphan an offer in a store nothing reads.
        #expect(fixtures.proposals.proposals.count == 2)
        #expect(fixtures.proposals.proposals.allSatisfy { $0.affectedCount == 1 })
    }
}
