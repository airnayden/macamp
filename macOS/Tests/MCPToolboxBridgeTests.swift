// MCPToolboxBridgeTests — W1's registry as MCP sees it.
//
// Two claims that nothing downstream can make for itself:
//
//   1. SCHEMA FIDELITY. Every tool the `.external` tier publishes survives the trip
//      into MCP's own value type and back UNCHANGED — same name, same description,
//      same `required` list, same property types and bounds. A conversion that
//      silently dropped `maxItems` would let a client ask for 100000 track ids and
//      only fail at the far end.
//   2. THE isError SPLIT. A refusal is model-actionable text, not a protocol
//      failure; an unknown tool and an unreachable library are the reverse.
import Foundation
@testable import MacAMP
import MCP
import Persistence
import Services
import Testing
import ViewModels

@Suite("MCP toolbox bridge", .serialized)
@MainActor
struct MCPToolboxBridgeTests {
    private static func toolbox() -> LibraryToolbox {
        AppEnvironment.makeExternalToolbox(
            database: AppEnvironment.preview().database,
            profileId: ProfileRecord.guestID,
            proposals: ProposalStore()
        )
    }

    // MARK: Publication

    @Test("the external tier publishes the ten library tools, in registry order, unrenamed")
    func everyExternalToolIsPublished() {
        let toolbox = Self.toolbox()
        let published = MCPToolboxBridge.tools(toolbox)
        #expect(published.map(\.name) == toolbox.tools(profile: .external).map(\.name))
        #expect(published.count == 10)
        #expect(published.contains { $0.name == MCPToolboxBridge.proposalToolName })
    }

    @Test("every published tool round-trips its whole schema — names, types, required, bounds")
    func everySchemaRoundTrips() {
        let toolbox = Self.toolbox()
        for tool in toolbox.tools(profile: .external) {
            let published = MCPToolboxBridge.tools(toolbox).first { $0.name == tool.name }
            #expect(published?.description == tool.description)
            let recovered = published.map { MCPToolboxBridge.json($0.inputSchema) }
            #expect(recovered == tool.parametersSchema, "schema drift in \(tool.name)")
        }
    }

    @Test("a schema's required list and property types survive as JSON Schema")
    func requiredAndTypesSurvive() throws {
        let published = try #require(MCPToolboxBridge.tools(Self.toolbox()).first { $0.name == "search_tracks" })
        let schema = try #require(published.inputSchema.objectValue)
        #expect(schema["type"]?.stringValue == "object")
        #expect(schema["required"]?.arrayValue?.compactMap(\.stringValue) == ["query"])
        let properties = try #require(schema["properties"]?.objectValue)
        #expect(properties["query"]?.objectValue?["type"]?.stringValue == "string")
        #expect(properties["limit"]?.objectValue?["type"]?.stringValue == "integer")
        #expect(properties["limit"]?.objectValue?["maximum"]?.intValue == 200)
    }

    @Test("the one write seam is annotated as a write; every reader is annotated read-only")
    func annotationsDistinguishTheWriteSeam() throws {
        let published = MCPToolboxBridge.tools(Self.toolbox())
        for tool in published where tool.name != MCPToolboxBridge.proposalToolName {
            #expect(tool.annotations.readOnlyHint == true, "\(tool.name) should be read-only")
        }
        let proposal = try #require(published.first { $0.name == MCPToolboxBridge.proposalToolName })
        #expect(proposal.annotations.readOnlyHint == false)
        #expect(proposal.annotations.destructiveHint == false)
        // Offline by construction — W1 note 8.
        #expect(published.allSatisfy { $0.annotations.openWorldHint == false })
    }

    // MARK: JSON

    @Test("a whole number becomes an integer and a fractional one stays a double")
    func numbersRecoverTheirExactness() {
        #expect(MCPToolboxBridge.value(.number(100)) == .int(100))
        #expect(MCPToolboxBridge.value(.number(1.5)) == .double(1.5))
        #expect(MCPToolboxBridge.json(.int(100)) == .number(100))
        #expect(MCPToolboxBridge.json(.double(1.5)) == .number(1.5))
    }

    @Test("binary has no counterpart in W1's vocabulary and becomes null, not a guess")
    func binaryArgumentsBecomeNull() {
        #expect(MCPToolboxBridge.json(.data(mimeType: "audio/flac", Data([0x1]))) == .null)
    }

    @Test("nesting survives in both directions")
    func nestedValuesRoundTrip() {
        let original = ToolboxJSON.object([
            "a": .array([.string("x"), .number(2), .bool(true), .null]),
            "b": .object(["c": .number(0.25)]),
        ])
        #expect(MCPToolboxBridge.json(MCPToolboxBridge.value(original)) == original)
    }

    // MARK: Calls

    @Test("a real call comes back as text that is NOT an error")
    func aRealCallSucceeds() async throws {
        let result = await MCPToolboxBridge.call("list_genres", arguments: nil, toolbox: Self.toolbox())
        #expect(result.isError == false)
        guard case let .text(text, _, _) = try #require(result.content.first) else {
            Issue.record("expected text content")
            return
        }
        #expect(!text.isEmpty)
    }

    @Test("a refused ARGUMENT is model-actionable text, not a protocol error")
    func argumentRefusalsAreNotErrors() async throws {
        // `search_tracks` requires `query`; W1's `run` renders the refusal as the
        // sentence it wrote for a model to correct itself against.
        let result = await MCPToolboxBridge.call("search_tracks", arguments: [:], toolbox: Self.toolbox())
        #expect(result.isError == false)
        guard case let .text(text, _, _) = try #require(result.content.first) else {
            Issue.record("expected text content")
            return
        }
        #expect(text.localizedCaseInsensitiveContains("query"))
    }

    @Test("an out-of-range argument is also a refusal, not an error")
    func outOfRangeArgumentsAreNotErrors() async {
        let result = await MCPToolboxBridge.call(
            "search_tracks",
            arguments: ["query": .string("a"), "limit": .int(100_000)],
            toolbox: Self.toolbox()
        )
        #expect(result.isError == false)
    }

    @Test("a tool that does not exist IS an error, and names the ones that do")
    func unknownToolsAreErrors() async throws {
        let result = await MCPToolboxBridge.call("delete_everything", arguments: nil, toolbox: Self.toolbox())
        #expect(result.isError == true)
        guard case let .text(text, _, _) = try #require(result.content.first) else {
            Issue.record("expected text content")
            return
        }
        #expect(text.contains("search_tracks"))
        #expect(text.contains("delete_everything"))
    }

    @Test("a tool the external tier does not publish is refused like any unknown name")
    func unpublishedToolsAreErrors() async {
        // Every one of the ten IS published externally today; the guard is
        // structural, so it is exercised through a name outside the registry.
        let result = await MCPToolboxBridge.call("propose_playlist ", arguments: nil, toolbox: Self.toolbox())
        #expect(result.isError == true)
    }

    @Test("no library means an error, because a model cannot correct for a switched-off app")
    func anAbsentToolboxIsAnError() async {
        let result = await MCPToolboxBridge.call("list_genres", arguments: nil, toolbox: nil)
        #expect(result.isError == true)
    }
}
