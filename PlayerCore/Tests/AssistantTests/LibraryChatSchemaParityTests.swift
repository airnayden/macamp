// LibraryChatSchemaParityTests — the drift guard between W1's published tool
// schemas and W3's hand-written FoundationModels argument structs.
//
// ── WHAT THIS PREVENTS, AND WHY NOTHING ELSE DOES ────────────────────────────
//
// `LibraryTool.parametersSchema` is a runtime `ToolboxJSON` document; a
// FoundationModels `Tool.parameters` is a `GenerationSchema` synthesised at
// COMPILE TIME from an `@Generable` struct. Neither can be derived from the other
// (see `LibraryChatTools.swift`'s header), so the five wrappers restate their
// arguments by hand — and an edit to a W1 schema would otherwise desync them in
// complete silence. The model would be offered a `limit` the tool no longer reads,
// or never offered a `seed` the tool now accepts, and every existing test would
// still pass.
//
// ── NEITHER SIDE IS A LIST A PERSON MAINTAINS ────────────────────────────────
//
// One side reads the toolbox's OWN `parametersSchema`. The other reflects over the
// wrapper's ACTUAL Swift stored properties. There is no third copy, so this cannot
// be satisfied by updating a manifest and forgetting the struct.
// `guardFailsOnRealDrift` is the negative control that proves the comparison is
// capable of failing — a parity assertion that could never go red would be worth
// nothing.
//
// ── NO MODEL, NO APPLE INTELLIGENCE ──────────────────────────────────────────
//
// Reflection over a struct calls nothing. This suite needs the macOS 26 SDK to
// COMPILE (the argument structs are `@Generable`) and a macOS 26 runtime to run,
// but it never constructs a `LanguageModelSession` and passes on a machine with
// Apple Intelligence switched off entirely.
import Foundation
import Persistence
import Services
import Testing

#if canImport(FoundationModels)
    @Suite("LibraryChat schema parity")
    struct LibraryChatSchemaParityTests {
        @Test("Every .onDevice tool has a wrapper publishing the same name, sentence and arguments")
        func wrappersMatchPublishedTools() throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            // The GRANTED toolbox, because that is the widest set the tier can
            // publish — a parity run over the ungranted five would leave the three
            // control wrappers unchecked.
            let (toolbox, _) = try ToolboxFixtures.makeControllableToolbox(ToolboxFixtures.makeLibrary())
            let published = toolbox.tools(profile: .onDevice)
            let wrappers = LibraryChatTools.onDevice(toolbox, counts: LibraryChatToolCounts())
            let reflected = LibraryChatTools.reflectedManifests
            let expectedNames = LibraryToolbox.onDeviceToolNames + LibraryToolbox.onDeviceControlToolNames

            #expect(published.count == ToolResultBudget.onDeviceToolLimit
                + ToolResultBudget.onDeviceControlToolLimit)
            #expect(wrappers.count == published.count)
            #expect(reflected.count == published.count)

            // The NAMES are a wire format and the ORDER is load-bearing: tool
            // definitions are injected into the instructions in this order, and a
            // small model reaches for what it read first.
            #expect(wrappers.map(\.name) == expectedNames)
            #expect(published.map(\.name) == expectedNames)

            // The DESCRIPTION is billed on every turn and is W1's sentence. A
            // wrapper paraphrasing it would silently change what the model is told
            // the tool does.
            #expect(wrappers.map(\.description) == published.map(\.description))

            for (tool, manifest) in zip(published, reflected) {
                let expected = try #require(
                    ChatToolManifest.published(tool),
                    "\(tool.name): parametersSchema is not a shape ChatToolManifest can read"
                )
                let actual = try #require(
                    manifest,
                    "\(tool.name): the wrapper's Arguments has a property type ChatArgumentKind cannot express"
                )
                #expect(actual == expected, "\(tool.name) drifted: wrapper \(actual) vs schema \(expected)")
            }
        }

        @Test("Without a playback grant the session attaches exactly the five that shipped before")
        func anUngrantedSessionIsUnchanged() throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            let toolbox = try ToolboxFixtures.makeToolbox(ToolboxFixtures.makeLibrary())
            let wrappers = LibraryChatTools.onDevice(toolbox, counts: LibraryChatToolCounts())
            #expect(wrappers.map(\.name) == LibraryToolbox.onDeviceToolNames)
            #expect(wrappers.count == ToolResultBudget.onDeviceToolLimit)
        }

        @Test("The three control wrappers restate exactly the arguments their tools publish")
        func controlWrappersRestateTheirArguments() throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            #expect(try #require(LibraryChatTools.reflectedManifests[5]).arguments.isEmpty)

            let play = try #require(LibraryChatTools.reflectedManifests[6])
            #expect(play.name == "play_tracks")
            #expect(play.arguments == [
                ChatToolArgument(name: "mode", kind: .string, isRequired: false),
                ChatToolArgument(name: "track_ids", kind: .integerArray, isRequired: true),
            ])

            let transport = try #require(LibraryChatTools.reflectedManifests[7])
            #expect(transport.name == "transport")
            #expect(transport.arguments == [
                ChatToolArgument(name: "action", kind: .string, isRequired: true),
            ])
        }

        @Test("The reflected arguments are the ones the parity check thinks they are")
        func reflectsTheDocumentedArguments() throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            // Pins the reading itself. Without this, a `reflected(...)` that silently
            // returned an EMPTY argument list would still equal a `published(...)`
            // that had also failed to read anything.
            let sample = try #require(LibraryChatTools.reflectedManifests[2])
            #expect(sample.name == "sample_tracks")
            #expect(sample.arguments == [
                ChatToolArgument(name: "energy_max", kind: .number, isRequired: false),
                ChatToolArgument(name: "energy_min", kind: .number, isRequired: false),
                ChatToolArgument(name: "genre", kind: .string, isRequired: false),
                ChatToolArgument(name: "limit", kind: .integer, isRequired: false),
                ChatToolArgument(name: "seed", kind: .integer, isRequired: false),
                ChatToolArgument(name: "tempo_max", kind: .number, isRequired: false),
                ChatToolArgument(name: "tempo_min", kind: .number, isRequired: false),
                ChatToolArgument(name: "year_max", kind: .integer, isRequired: false),
                ChatToolArgument(name: "year_min", kind: .integer, isRequired: false),
            ])

            // `track_ids` is OPTIONAL: a criteria-shaped proposal names a genre and
            // a count instead, and the app materialises the membership. The flip is
            // parity-visible, so W1's `required` list moved with the wrapper.
            let proposal = try #require(LibraryChatTools.reflectedManifests[4])
            #expect(proposal.arguments == [
                ChatToolArgument(name: "description", kind: .string, isRequired: false),
                ChatToolArgument(name: "genre", kind: .string, isRequired: false),
                ChatToolArgument(name: "name", kind: .string, isRequired: true),
                ChatToolArgument(name: "target_count", kind: .integer, isRequired: false),
                ChatToolArgument(name: "track_ids", kind: .integerArray, isRequired: false),
            ])

            #expect(try #require(LibraryChatTools.reflectedManifests[1]).arguments.isEmpty)
        }

        @Test("The guard goes RED on a real drift, in each of the four ways one can happen")
        func guardFailsOnRealDrift() throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            let wrapper = try #require(LibraryChatTools.reflectedManifests[0])
            #expect(wrapper == ChatToolManifest.published(Self.searchLike()))

            // A renamed argument.
            #expect(wrapper != ChatToolManifest.published(Self.searchLike(queryName: "q")))
            // A retyped argument.
            #expect(wrapper != ChatToolManifest.published(Self.searchLike(limit: ToolSchema.string("…"))))
            // An added argument.
            #expect(wrapper != ChatToolManifest.published(
                Self.searchLike(extra: .init("seed", ToolSchema.integer("…")))
            ))
            // A required/optional flip.
            #expect(wrapper != ChatToolManifest.published(Self.searchLike(required: ["query", "limit"])))
        }

        @Test("An argument shape no wrapper could restate is nil, never a silent skip")
        func rejectsUnreadableSchemas() {
            #expect(ChatArgumentKind(schema: ToolSchema.string("a")) == .string)
            #expect(ChatArgumentKind(schema: ToolSchema.integer("a")) == .integer)
            #expect(ChatArgumentKind(schema: ToolSchema.number("a")) == .number)
            #expect(ChatArgumentKind(schema: ToolSchema.integerArray("a", maxItems: 100)) == .integerArray)
            // A boolean and an array of anything but integers have no builder in
            // `ToolSchema` today, so a schema carrying one has grown a shape the
            // wrappers do not know how to restate.
            #expect(ChatArgumentKind(schema: .object(["type": .string("boolean")])) == nil)
            #expect(ChatArgumentKind(schema: .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
            ])) == nil)
            #expect(ChatArgumentKind(schema: .string("not an object")) == nil)
        }

        /// A stand-in for `search_tracks`, mutable one axis at a time.
        private static func searchLike(
            queryName: String = "query",
            limit: ToolboxJSON = ToolSchema.integer("Maximum tracks to return.", minimum: 1, maximum: 200),
            extra: ToolSchema.Property? = nil,
            required: [String] = ["query"]
        ) -> LibraryTool {
            var properties: [ToolSchema.Property] = [
                .init(queryName, ToolSchema.string("Words to match.")),
                .init("limit", limit),
            ]
            if let extra {
                properties.append(extra)
            }
            return LibraryTool(
                name: "search_tracks",
                description: "…",
                parametersSchema: ToolSchema.object(properties, required: required),
                execute: { _ in ToolResult.message("…") }
            )
        }
    }
#endif
