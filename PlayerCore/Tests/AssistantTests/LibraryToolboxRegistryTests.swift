import Foundation
@testable import Services
import Testing

/// The registry contract every downstream adapter reads: stable names, a bounded
/// on-device subset, and a schema each of them can project without guessing.
@Suite("LibraryToolbox registry")
struct LibraryToolboxRegistryTests {
    /// The v1 tool set, in publication order. This list is a WIRE FORMAT — a
    /// failure here means a saved provider conversation or an external MCP client
    /// just broke, not that the test is stale.
    static let expectedNames = [
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

    /// The whole registry a caller WITH a playback grant sees: the four control
    /// tools slot between `propose_playlist` and `match_tracks`, because the
    /// control block is registered before the post-control library additions.
    static let expectedGrantedNames = Array(expectedNames.dropLast())
        + LibraryToolbox.controlToolNames
        + ["match_tracks"]

    @Test("every library tool is registered, in publication order")
    func registersTheVersionOneSet() throws {
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database)
        #expect(toolbox.allTools.map(\.name) == Self.expectedNames)
        #expect(toolbox.allTools.count == 10)
    }

    @Test("a playback grant publishes fourteen, and the ten library names keep their identity")
    func registersTheGrantedSet() throws {
        let database = try ToolboxFixtures.makeLibrary()
        let (toolbox, _) = ToolboxFixtures.makeControllableToolbox(database)
        #expect(toolbox.allTools.map(\.name) == Self.expectedGrantedNames)
        #expect(toolbox.allTools.count == 14)
    }

    @Test("names are snake_case and unique")
    func namesAreWireSafe() throws {
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database)
        let names = toolbox.allTools.map(\.name)
        #expect(Set(names).count == names.count)
        for name in names {
            #expect(name == name.lowercased())
            #expect(!name.contains(" "))
            #expect(!name.contains("-"))
        }
    }

    @Test("descriptions stay one short sentence — they are billed every turn")
    func descriptionsAreShort() throws {
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database)
        for tool in toolbox.allTools {
            #expect(!tool.description.isEmpty)
            #expect(tool.description.count <= 120, "\(tool.name) description is too long")
            #expect(!tool.description.contains("\n"))
        }
    }

    @Test("the on-device tier publishes at most five tools, and the documented five")
    func onDeviceIsSubsetted() throws {
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database)
        let onDevice = toolbox.tools(profile: .onDevice)
        #expect(onDevice.count <= ToolResultBudget.onDeviceToolLimit)
        #expect(onDevice.map(\.name) == LibraryToolbox.onDeviceToolNames)
    }

    @Test("every other tier publishes the whole set")
    func otherTiersPublishEverything() throws {
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database)
        #expect(toolbox.tools(profile: .cloud).map(\.name) == Self.expectedNames)
        #expect(toolbox.tools(profile: .external).map(\.name) == Self.expectedNames)
    }

    @Test("an unknown tool name is a typed refusal, never a crash")
    func unknownToolRefuses() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database)
        await #expect(throws: LibraryToolError.unknownTool(name: "delete_everything")) {
            try await toolbox.execute("delete_everything")
        }
        let rendered = await toolbox.run("delete_everything", profile: .cloud)
        #expect(rendered == "There is no tool named \"delete_everything\".")
    }
}

// MARK: - Schema validity

@Suite("LibraryToolbox schemas")
struct LibraryToolboxSchemaTests {
    @Test("every schema is a strict object that round-trips through ToolboxJSON")
    func schemasRoundTrip() throws {
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database)
        for tool in toolbox.allTools {
            let data = try tool.parametersSchema.encodedData()
            let decoded = try ToolboxJSON.decoded(from: data)
            #expect(decoded == tool.parametersSchema, "\(tool.name) schema did not round-trip")
        }
    }

    @Test("every schema declares type, properties, required and additionalProperties")
    func schemasAreWellFormed() throws {
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database)
        for tool in toolbox.allTools {
            let schema = try #require(tool.parametersSchema.objectValue, "\(tool.name)")
            #expect(schema["type"]?.stringValue == "object")
            #expect(schema["additionalProperties"]?.boolValue == false)
            #expect(schema["properties"]?.objectValue != nil, "\(tool.name) declares no properties object")
            #expect(schema["required"]?.arrayValue != nil, "\(tool.name) declares no required list")
        }
    }

    @Test("every declared property states a type, and every required name is declared")
    func propertiesAreTyped() throws {
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database)
        for tool in toolbox.allTools {
            let schema = try #require(tool.parametersSchema.objectValue)
            let properties = try #require(schema["properties"]?.objectValue)
            let required = try #require(schema["required"]?.arrayValue).compactMap(\.stringValue)
            for (name, node) in properties {
                let declared = try #require(node.objectValue, "\(tool.name).\(name)")
                #expect(declared["type"]?.stringValue != nil, "\(tool.name).\(name) has no type")
                #expect(declared["description"]?.stringValue?.isEmpty == false, "\(tool.name).\(name) undocumented")
            }
            for name in required {
                #expect(properties[name] != nil, "\(tool.name) requires undeclared \"\(name)\"")
            }
        }
    }

    /// `propose_playlist` is the ONE tool with its own ceiling: it files an offer the
    /// listener still has to approve, so a long playlist costs nothing but rows in a
    /// sheet. Every other id list bounds a read or a playback command and stays at the
    /// shared batch limit, so the expectation is split rather than widened.
    @Test("every id-list argument publishes its batch ceiling in the schema itself")
    func identifierListsAreBounded() throws {
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database)
        let shared = Double(ToolResultBudget.identifierBatchLimit)
        let proposal = Double(ToolResultBudget.proposalIdentifierLimit)
        for tool in toolbox.allTools {
            guard let properties = tool.parametersSchema.objectValue?["properties"]?.objectValue else { continue }
            let expected = tool.name == "propose_playlist" ? proposal : shared
            for (name, node) in properties where node.objectValue?["type"]?.stringValue == "array" {
                #expect(node.objectValue?["maxItems"]?.numberValue == expected, "\(tool.name).\(name) unbounded")
            }
        }
    }
}
