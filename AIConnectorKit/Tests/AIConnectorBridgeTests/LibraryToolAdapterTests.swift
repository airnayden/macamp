// LibraryToolAdapterTests — the toolbox → kit projection, over a fake toolbox.
//
// The fake is a hand-built `[LibraryTool]` plus a recording `run`, NOT a
// `LibraryToolbox`: the real registry needs a concrete `TrackRepository` and
// therefore a migrated GRDB database, and driving one here would test the
// database rather than the adapter. `LibraryTool`'s initializer is public and its
// `parametersSchema` is built with the SAME `ToolSchema` helpers the nine shipped
// tools use, so the schemas under test are real ones — including the `minimum` /
// `maximum` / `maxItems` bounds that are exactly what a schema-builder-shaped
// conversion would have dropped.
import AIConnectorBridge
import AIConnectorKit
import Foundation
import Services
import Testing

@Suite("LibraryToolAdapterTests")
struct LibraryToolAdapterTests {
    // MARK: - Schema fidelity

    @Test("A real ToolSchema document survives conversion with every bound intact")
    func schemaConversionKeepsEveryBound() throws {
        // `search_tracks`' actual schema shape: one required string, one bounded
        // optional integer.
        let schema = ToolSchema.object(
            [
                ToolSchema.Property("query", ToolSchema.string("What to search for.")),
                ToolSchema.Property("limit", ToolSchema.integer("How many rows.", minimum: 1, maximum: 200)),
            ],
            required: ["query"]
        )

        let converted = ToolboxJSONBridge.value(schema)

        // The bounds are the point: `JSONSchemaObject` cannot express `minimum`
        // or `maximum`, so routing a toolbox schema through it would silently
        // publish an unbounded `limit`.
        let limit = try #require(converted["properties"]?["limit"])
        #expect(limit["minimum"]?.numberValue == 1)
        #expect(limit["maximum"]?.numberValue == 200)
        #expect(converted["required"] == .array([.string("query")]))
        #expect(converted["additionalProperties"] == .bool(false))
        // And the canonical text round-trips identically through both types.
        #expect(converted.jsonText == schema.jsonText)
    }

    @Test("`maxItems` on an id-array schema survives too")
    func arrayBoundsSurvive() throws {
        let schema = ToolSchema.object(
            [ToolSchema.Property("track_ids", ToolSchema.integerArray("Track ids.", maxItems: 100))],
            required: ["track_ids"]
        )
        let converted = ToolboxJSONBridge.value(schema)
        let ids = try #require(converted["properties"]?["track_ids"])
        #expect(ids["maxItems"]?.numberValue == 100)
        #expect(ids["type"]?.stringValue == "array")
    }

    @Test("Every JSON case converts, including null, nested objects and mixed arrays")
    func conversionIsTotal() {
        let source = ToolboxJSON.object([
            "null": .null,
            "bool": .bool(true),
            "number": .number(1.5),
            "int": .int(42),
            "string": .string("text"),
            "array": .array([.null, .bool(false), .string("x")]),
            "object": .object(["nested": .array([.number(0)])]),
        ])
        #expect(ToolboxJSONBridge.value(source).jsonText == source.jsonText)
    }

    // MARK: - Publication and routing

    @Test("Name, description and schema are copied verbatim, in publication order")
    func toolsAreCopiedInOrder() {
        let toolbox = FakeToolPublisher.standard()
        let tools = LibraryToolAdapter.aiTools(toolbox)

        #expect(tools.map(\.name) == ["search_tracks", "list_genres"])
        #expect(tools[0].description == "Finds tracks.")
        #expect(tools[1].parametersSchema == ToolboxJSONBridge.value(ToolSchema.noArguments))
    }

    @Test("Execution routes at the `.cloud` tier by default, with the model's arguments decoded")
    func executionRoutesAtCloud() async {
        let toolbox = FakeToolPublisher.standard()
        let tools = LibraryToolAdapter.aiTools(toolbox)

        let answer = await tools[0].execute("{\"query\":\"shoegaze\",\"limit\":5}")

        #expect(answer.text == "ran search_tracks")
        #expect(toolbox.calls == [
            FakeToolCall(name: "search_tracks", profile: .cloud, keys: ["limit", "query"]),
        ])
    }

    @Test("A tool's result count survives the adapter, and a tool without one stays nil")
    func resultCountSurvivesTheAdapter() async {
        let standard = FakeToolPublisher.standard()
        let toolbox = FakeToolPublisher(
            published: [.cloud: standard.tools(profile: .cloud)],
            answers: ["search_tracks": "12 tracks matching \"x\"."],
            resultCounts: ["search_tracks": 12]
        )
        let tools = LibraryToolAdapter.aiTools(toolbox)

        let listShaped = await tools[0].execute("{\"query\":\"x\"}")
        #expect(listShaped == AIToolOutput(text: "12 tracks matching \"x\".", resultCount: 12))

        // `list_genres` reports none here, and the adapter must not invent one by
        // counting lines in the text it just received.
        let countless = await tools[1].execute("")
        #expect(countless == AIToolOutput(text: "ran list_genres", resultCount: nil))
    }

    // MARK: - Rows

    @Test("A tool's rows and misses survive the adapter; a non-track row does not")
    func rowsSurviveTheAdapter() async {
        let standard = FakeToolPublisher.standard()
        let toolbox = FakeToolPublisher(
            published: [.cloud: standard.tools(profile: .cloud)],
            answers: ["search_tracks": "2 tracks matching \"x\"."],
            resultCounts: ["search_tracks": 2],
            rows: ["search_tracks": [
                ToolRowFixture.track(id: 7, title: "Sometimes", artist: "My Bloody Valentine"),
                ToolRowFixture.genre(name: "Shoegaze", trackCount: 12),
                ToolRowFixture.track(id: 9, title: "Only Shallow", artist: "My Bloody Valentine"),
                ToolRowFixture.miss(title: "Cigarette", artist: "Slowdive"),
            ]]
        )

        let answer = await LibraryToolAdapter.aiTools(toolbox)[0].execute("{\"query\":\"x\"}")

        #expect(answer.rows == [
            AIToolRow(trackId: 7, title: "Sometimes", artist: "My Bloody Valentine"),
            AIToolRow(trackId: 9, title: "Only Shallow", artist: "My Bloody Valentine"),
        ])
        #expect(answer.suggestions == [AIToolSuggestion(title: "Cigarette", artist: "Slowdive")])
        // The text and the count are untouched by the widening.
        #expect(answer.text == "2 tracks matching \"x\".")
        #expect(answer.resultCount == 2)
    }

    @Test("A tool outside the allow-list projects NO rows, however track-shaped its payload")
    func nonAllowListedToolProjectsNothing() async {
        // A control tool's entry is a strict SUBSET of a track payload, so no
        // shape predicate can reject it — and the cloud tier publishes all four
        // control tools, so this gate does strictly more work here than on-device.
        let playback = LibraryTool(
            name: "get_playback_state",
            description: "Reports what is playing.",
            parametersSchema: ToolSchema.noArguments,
            execute: { _ in ToolResult.message("unused: the adapter routes through `run`") }
        )
        let toolbox = FakeToolPublisher(
            published: [.cloud: [playback]],
            answers: [:],
            resultCounts: ["get_playback_state": 1],
            rows: ["get_playback_state": [
                ToolRowFixture.playbackEntry(id: 7, title: "Sometimes", artist: "My Bloody Valentine"),
            ]]
        )

        let answer = await LibraryToolAdapter.aiTools(toolbox)[0].execute("")

        #expect(answer.rows.isEmpty)
        #expect(answer.suggestions.isEmpty)
        // Only the LIST is withheld; the answer itself still reaches the model.
        #expect(answer.text == "ran get_playback_state")
        #expect(answer.resultCount == 1)
    }

    @Test("The adapter's row cap is PlayerCore's own, applied to the leading rows")
    func rowsAreCappedAtTheSharedLimit() async {
        let over = AssistantChatRow.limit + 10
        let standard = FakeToolPublisher.standard()
        let toolbox = FakeToolPublisher(
            published: [.cloud: standard.tools(profile: .cloud)],
            answers: [:],
            rows: ["search_tracks": (1 ... over).map {
                ToolRowFixture.track(id: Int64($0), title: "track \($0)", artist: "An Artist")
            }]
        )

        let answer = await LibraryToolAdapter.aiTools(toolbox)[0].execute("{\"query\":\"x\"}")

        #expect(answer.rows.count == AssistantChatRow.limit)
        #expect(answer.rows.first?.trackId == 1)
        #expect(answer.rows.last?.trackId == Int64(AssistantChatRow.limit))
    }

    @Test("A refusal carries no rows: nothing was looked up")
    func refusalsCarryNoRows() async {
        let standard = FakeToolPublisher.standard()
        let toolbox = FakeToolPublisher(
            published: [.cloud: standard.tools(profile: .cloud)],
            answers: [:],
            rows: ["search_tracks": [ToolRowFixture.track(id: 7, title: "Sometimes", artist: "MBV")]]
        )

        let answer = await LibraryToolAdapter.aiTools(toolbox)[0].execute("not json at all")

        #expect(answer.rows.isEmpty)
        #expect(answer.suggestions.isEmpty)
        #expect(answer.text.hasPrefix("Arguments were not valid JSON"))
    }

    @Test("The tier is a parameter: `.onDevice` publishes fewer tools and routes at its own budget")
    func tierIsThreadedThrough() async {
        let toolbox = FakeToolPublisher.standard()
        let onDevice = LibraryToolAdapter.aiTools(toolbox, profile: .onDevice)

        // The FAKE decides what each tier publishes, exactly as `LibraryToolbox`
        // does — the adapter must never hardcode a subset of its own.
        #expect(onDevice.map(\.name) == ["search_tracks"])
        _ = await onDevice[0].execute("{}")
        #expect(toolbox.calls.first?.profile == .onDevice)

        let external = LibraryToolAdapter.aiTools(toolbox, profile: .external)
        #expect(external.map(\.name) == ["search_tracks", "list_genres"])
    }

    // MARK: - Argument handling

    @Test("Blank arguments are an EMPTY object, not a refusal")
    func blankArgumentsAreEmptyNotRefused() async {
        let toolbox = FakeToolPublisher.standard()
        let tools = LibraryToolAdapter.aiTools(toolbox)

        for text in ["", "   ", "\n"] {
            _ = await tools[1].execute(text)
        }
        // Two of the four wire formats send `""` for an argument-less call.
        // Refusing it would refuse a correct call to `list_genres`.
        #expect(toolbox.calls.count == 3)
        // Bound first: `#expect` decomposes its argument into a NON-throwing
        // closure, which loses `allSatisfy`'s `rethrows` inference and fails to
        // compile. Same family as the `#require(try …)` trap.
        let everyCallHadNoArguments = toolbox.calls.map(\.keys).allSatisfy(\.isEmpty)
        #expect(everyCallHadNoArguments)
    }

    @Test("`{}` and a null-valued argument both reach the tool as an empty read")
    func emptyObjectAndNullsReachTheTool() async {
        let toolbox = FakeToolPublisher.standard()
        let tools = LibraryToolAdapter.aiTools(toolbox)

        _ = await tools[1].execute("{}")
        // A model filling every declared property under strict mode sends `null`
        // for the ones it does not mean; `ToolArguments.value` reads that as
        // absent, and the adapter must not intercept it first.
        _ = await tools[0].execute("{\"query\":\"x\",\"limit\":null}")

        #expect(toolbox.calls[0].keys.isEmpty)
        #expect(toolbox.calls[1].keys == ["limit", "query"])
    }

    @Test("Malformed argument text is refused in the SAME prose the toolbox itself would use")
    func malformedArgumentsAreRefusedInProse() async {
        let toolbox = FakeToolPublisher.standard()
        let tools = LibraryToolAdapter.aiTools(toolbox)

        let answer = await tools[0].execute("not json at all")

        // Never thrown, and never the adapter's own wording: byte-identical to
        // `LibraryToolbox.run`'s rendering of the same refusal, so a model sees
        // one voice whichever side rejected it.
        #expect(answer.text.hasPrefix("Arguments were not valid JSON"))
        #expect(answer.resultCount == nil, "A refusal looked nothing up, so it counts nothing")
        #expect(toolbox.calls.isEmpty, "A malformed payload must never reach the toolbox")
    }

    @Test("A non-object payload is refused rather than coerced")
    func nonObjectPayloadIsRefused() async {
        let toolbox = FakeToolPublisher.standard()
        let tools = LibraryToolAdapter.aiTools(toolbox)

        for text in ["[1,2,3]", "\"a string\"", "42"] {
            let answer = await tools[0].execute(text)
            #expect(answer.text == ToolArgumentError.notAnObject.message)
        }
        #expect(toolbox.calls.isEmpty)
    }

    @Test("A refusal is rendered at the CALLER's tier, so its budget applies")
    func refusalsAreRenderedAtTheCallersTier() async {
        let toolbox = FakeToolPublisher.standard()
        let onDevice = LibraryToolAdapter.aiTools(toolbox, profile: .onDevice)

        let answer = await onDevice[0].execute("nope")
        #expect(answer.text.count <= ToolProfile.onDevice.characterLimit)
    }
}
