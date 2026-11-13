// LibraryChatToolTests — the five wrappers actually decode, call and answer.
//
// Every case here drives the REAL wrapper against the REAL toolbox over the REAL
// repositories on a seeded in-memory database. Nothing is faked but the proposal
// filer, which is the one seam that leaves this layer. No `LanguageModelSession`
// is ever constructed, so this suite needs the macOS 26 SDK and runtime but NOT
// Apple Intelligence — the live conversation lives in `LibraryChatLiveSmokeTests`.
//
// The central assertion shape is "the wrapper answers exactly what
// `toolbox.run(...)` answers". That is the contract: a wrapper projects arguments
// and NOTHING else. A wrapper that quietly clamped a limit or defaulted a window
// would be a second, unreviewed policy sitting between the model and W1.
import Foundation
import Persistence
import Services
import Testing

#if canImport(FoundationModels)
    import FoundationModels

    @Suite("LibraryChat tools")
    struct LibraryChatToolTests {
        @Test("search_tracks projects its arguments and answers exactly what the toolbox answers")
        func searchProjectsArguments() async throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            let toolbox = try ToolboxFixtures.makeToolbox(ToolboxFixtures.makeLibrary())
            let tool = LibraryChatSearchTool(toolbox: toolbox, counts: LibraryChatToolCounts())

            let answered = await tool.call(arguments: .init(query: "Nova", limit: 2))
            let expected = await toolbox.run("search_tracks", arguments: ToolArguments([
                "query": .string("Nova"),
                "limit": .int(2),
            ]), profile: .onDevice)
            #expect(answered == expected)
            #expect(answered.contains("Aurora Drift"))
        }

        @Test("An omitted optional is ABSENT, so the toolbox's own default applies")
        func omittedOptionalFallsToTheToolboxDefault() async throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            let toolbox = try ToolboxFixtures.makeToolbox(ToolboxFixtures.makeLibrary())
            let tool = LibraryChatSearchTool(toolbox: toolbox, counts: LibraryChatToolCounts())

            // The wrapper must not invent `limit: 20` itself — that number is
            // `LibraryToolbox.defaultSearchLimit` and belongs to W1.
            let omitted = await tool.call(arguments: .init(query: "Fillerton"))
            let bare = await toolbox.run(
                "search_tracks",
                arguments: ToolArguments(["query": .string("Fillerton")]),
                profile: .onDevice
            )
            #expect(omitted == bare)
        }

        @Test("A refusal comes back as a SENTENCE the model can correct itself against, not a throw")
        func refusalIsASentence() async throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            let toolbox = try ToolboxFixtures.makeToolbox(ToolboxFixtures.makeLibrary())

            // Apple's guidance for a small on-device model: a recoverable tool
            // failure should be readable text, not a thrown error that ends the
            // turn. `call` is non-throwing for exactly this reason.
            let blank = await LibraryChatSearchTool(toolbox: toolbox, counts: LibraryChatToolCounts())
                .call(arguments: .init(query: " "))
            #expect(blank == ToolArgumentError.empty(argument: "query").message)

            let window = await LibraryChatStatsTool(toolbox: toolbox, counts: LibraryChatToolCounts())
                .call(arguments: .init(window: "yesterday"))
            #expect(window == ToolArgumentError.notAllowed(
                argument: "window",
                allowed: ["7d", "30d", "12m", "all"]
            ).message)
            // The message LISTS the vocabulary, which is what makes the next
            // attempt a lookup rather than a second guess.
            #expect(window.contains("7d, 30d, 12m, all"))
        }

        @Test("list_genres needs no arguments and reports this library's own spelling")
        func genresNeedsNoArguments() async throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            let toolbox = try ToolboxFixtures.makeToolbox(ToolboxFixtures.makeLibrary())
            let answered = await LibraryChatGenresTool(toolbox: toolbox, counts: LibraryChatToolCounts())
                .call(arguments: .init())
            #expect(await answered == (toolbox.run("list_genres", profile: .onDevice)))
            #expect(answered.contains("Jazz"))
        }

        @Test("sample_tracks carries all nine bounds through, and the seed still determines the draw")
        func sampleProjectsEveryBound() async throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            let toolbox = try ToolboxFixtures.makeToolbox(ToolboxFixtures.makeLibrary())
            let tool = LibraryChatSampleTool(toolbox: toolbox, counts: LibraryChatToolCounts())

            let filtered = await tool.call(arguments: .init(
                genre: "Electronic",
                year_min: 2010,
                year_max: 2020,
                tempo_min: 100,
                tempo_max: 140,
                energy_min: 0.5,
                energy_max: 1,
                limit: 5,
                seed: 7
            ))
            let expected = await toolbox.run("sample_tracks", arguments: ToolArguments([
                "genre": .string("Electronic"),
                "year_min": .int(2010),
                "year_max": .int(2020),
                "tempo_min": .number(100),
                "tempo_max": .number(140),
                "energy_min": .number(0.5),
                "energy_max": .number(1),
                "limit": .int(5),
                "seed": .int(7),
            ]), profile: .onDevice)
            #expect(filtered == expected)
            // Track 4 is the only other Electronic row and it is `missing`, so a
            // bound that reached the reader can only have produced track 2.
            #expect(filtered.contains("Crimson Pulse"))
            #expect(filtered.contains("Frostbite") == false)

            let repeated = await tool.call(arguments: .init(genre: "Electronic", seed: 7))
            let sameSeed = await tool.call(arguments: .init(genre: "Electronic", seed: 7))
            #expect(repeated == sameSeed)
        }

        @Test("propose_playlist widens [Int] to the row ids the toolbox files, and still saves nothing")
        func proposalWidensIdentifiers() async throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            // `Int64` has no `Generable` conformance, so the wrapper takes `[Int]`.
            // This proves the widening reaches `ToolboxPlaylistProposal` intact.
            let database = try ToolboxFixtures.makeLibrary()
            let filer = FakeToolboxProposalFiler()
            let toolbox = ToolboxFixtures.makeToolbox(database, filer: filer)
            let before = try ToolboxFixtures.playlistNames(database)

            let answered = await LibraryChatProposalTool(toolbox: toolbox, counts: LibraryChatToolCounts())
                .call(arguments: .init(
                    name: "Late Night",
                    track_ids: [3, 1],
                    description: "Slow ones."
                ))

            let filed = await filer.filed
            #expect(filed.count == 1)
            #expect(filed.first?.trackIds == [3, 1])
            #expect(filed.first?.name == "Late Night")
            #expect(filed.first?.summary == "Slow ones.")
            #expect(answered.contains("Nothing has been saved yet"))
            #expect(try ToolboxFixtures.playlistNames(database) == before)
        }

        @Test("propose_playlist carries target_count through, and the shortfall comes back in the answer")
        func proposalProjectsTheTargetCount() async throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            let toolbox = try ToolboxFixtures.makeToolbox(
                ToolboxFixtures.makeLibrary(),
                filer: FakeToolboxProposalFiler()
            )

            let answered = await LibraryChatProposalTool(toolbox: toolbox, counts: LibraryChatToolCounts())
                .call(arguments: .init(name: "Short", track_ids: [3, 1], target_count: 10))
            let expected = await toolbox.run("propose_playlist", arguments: ToolArguments([
                "name": .string("Short"),
                "track_ids": .array([.int(3), .int(1)]),
                "target_count": .int(10),
            ]), profile: .onDevice)

            #expect(answered == expected)
            #expect(answered.contains("The listener asked for 10 tracks but this proposal has 2."))
        }

        @Test("A wrapper files its answer's result count without changing the answer")
        func wrapperFilesTheResultCount() async throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            let toolbox = try ToolboxFixtures.makeToolbox(ToolboxFixtures.makeLibrary())
            let ledger = LibraryChatToolCounts()

            let answered = await LibraryChatSearchTool(toolbox: toolbox, counts: ledger)
                .call(arguments: .init(query: "Nova"))

            // The model's view is byte-identical to `run`'s: the count travels
            // beside the text, never inside it, so it costs no context and cannot
            // be misread as prose.
            let expected = await toolbox.run(
                "search_tracks",
                arguments: ToolArguments(["query": .string("Nova")]),
                profile: .onDevice
            )
            #expect(answered == expected)

            let recorded = await ledger.snapshot()
            let found = try await toolbox.execute(
                "search_tracks",
                arguments: ToolArguments(["query": .string("Nova")])
            ).resultCount
            #expect(recorded.resultCount(forRenderedText: answered) == found)
            #expect(found != nil)
        }

        @Test("A wrapper whose tool cannot count files nothing")
        func countlessWrappersFileNothing() async throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            let toolbox = try ToolboxFixtures.makeToolbox(ToolboxFixtures.makeLibrary())
            let ledger = LibraryChatToolCounts()

            _ = await LibraryChatStatsTool(toolbox: toolbox, counts: ledger)
                .call(arguments: .init(window: "all"))
            _ = await LibraryChatProposalTool(toolbox: toolbox, counts: ledger)
                .call(arguments: .init(name: "Late Night", track_ids: [3, 1]))

            #expect(await ledger.snapshot().isEmpty)
        }

        @Test("The tool set is built over ONE ledger, so every wrapper files into the same turn")
        func everyWrapperSharesOneLedger() async throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            let toolbox = try ToolboxFixtures.makeToolbox(ToolboxFixtures.makeLibrary())
            let ledger = LibraryChatToolCounts()
            let tools = LibraryChatTools.onDevice(toolbox, counts: ledger)

            #expect(tools.count == ToolResultBudget.onDeviceToolLimit)
            let genres = await LibraryChatGenresTool(toolbox: toolbox, counts: ledger)
                .call(arguments: .init())
            let search = await LibraryChatSearchTool(toolbox: toolbox, counts: ledger)
                .call(arguments: .init(query: "Nova"))

            let recorded = await ledger.snapshot()
            #expect(recorded.resultCount(forRenderedText: genres) != nil)
            #expect(recorded.resultCount(forRenderedText: search) != nil)
        }

        @Test("Every wrapper's answer fits the on-device character budget")
        func answersFitTheOnDeviceBudget() async throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            // The property the whole 4096-token policy rests on: a tool result is
            // billed against the same window the conversation lives in, and
            // `renderedText(profile:)` guarantees the cap unconditionally.
            let toolbox = try ToolboxFixtures.makeToolbox(ToolboxFixtures.makeLibrary())
            let answers = await [
                LibraryChatSearchTool(toolbox: toolbox, counts: LibraryChatToolCounts())
                    .call(arguments: .init(query: "Fillerton")),
                LibraryChatGenresTool(toolbox: toolbox, counts: LibraryChatToolCounts()).call(arguments: .init()),
                LibraryChatSampleTool(toolbox: toolbox, counts: LibraryChatToolCounts())
                    .call(arguments: .init(limit: 50)),
                LibraryChatStatsTool(toolbox: toolbox, counts: LibraryChatToolCounts())
                    .call(arguments: .init(window: "all")),
            ]
            for answer in answers {
                #expect(answer.count <= ToolProfile.onDevice.characterLimit)
            }
        }
    }

    // MARK: - The gated translation

    @Suite("LibraryChat transcript mirror")
    struct LibraryChatTranscriptTests {
        @Test("Each of the five SDK entry kinds mirrors onto its floor-available twin")
        func mirrorsEveryEntryKind() throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            let entries: [Transcript.Entry] = try [
                .instructions(.init(segments: [.text(.init(content: "grounding"))], toolDefinitions: [])),
                .prompt(.init(segments: [.text(.init(content: "what jazz do I have?"))])),
                .toolCalls(.init([
                    .init(id: "a", toolName: "list_genres", arguments: GeneratedContent(json: "{}")),
                    .init(id: "b", toolName: "search_tracks", arguments: GeneratedContent(json: "{}")),
                ])),
                .toolOutput(.init(id: "c", toolName: "list_genres", segments: [.text(.init(content: "3 genres."))])),
                .response(.init(assetIDs: [], segments: [.text(.init(content: "You have one."))])),
            ]

            #expect(LibraryChatTranscript.mirror(entries) == [
                .instructions("grounding"),
                .prompt("what jazz do I have?"),
                .toolCalls(["list_genres", "search_tracks"]),
                .toolOutput(name: "list_genres", text: "3 genres."),
                .response("You have one."),
            ])
        }

        @Test("A structured segment is read as JSON, never silently dropped")
        func readsStructuredSegments() throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            // These five tools return `String`, so `.structure` is off the live path
            // today. It is still read, because an empty tool result would look
            // exactly like a tool that answered with nothing.
            let content = try GeneratedContent(json: #"{"genre":"Jazz"}"#)
            let output = Transcript.Entry.toolOutput(.init(
                id: "d",
                toolName: "list_genres",
                segments: [.structure(.init(source: "list_genres", content: content))]
            ))
            guard case let .toolOutput(_, text) = LibraryChatTranscript.mirror(output) else {
                Issue.record("a toolOutput entry must mirror to a toolOutput")
                return
            }
            #expect(text.contains("Jazz"))
        }

        @Test("A wrapped tool-call failure is UNWRAPPED, not flattened to .unknown")
        func unwrapsToolCallErrors() throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            let toolbox = try ToolboxFixtures.makeToolbox(ToolboxFixtures.makeLibrary())
            let tool = LibraryChatGenresTool(toolbox: toolbox, counts: LibraryChatToolCounts())

            // Built from Apple's OWN types, so this pins the unwrapping against the
            // SDK. A `ToolCallError` is a wrapper: reporting it as `.unknown` would
            // discard a `GenerationError` a caller can act on.
            let guardrail = LanguageModelSession.GenerationError.guardrailViolation(
                .init(debugDescription: "test")
            )
            let wrapped = LanguageModelSession.ToolCallError(tool: tool, underlyingError: guardrail)
            #expect(LibraryChatSession.failure(unwrapping: wrapped) as? AssistantFailure == .refused)

            let cancelled = LanguageModelSession.ToolCallError(tool: tool, underlyingError: CancellationError())
            #expect(LibraryChatSession.failure(unwrapping: cancelled) is CancellationError)

            // Anything outside the mapped surface is still `.unknown` — a real,
            // reachable path (an XPC drop, a Foundation error from the plumbing),
            // not defensive padding.
            let opaque = LanguageModelSession.ToolCallError(tool: tool, underlyingError: ToolboxFilingFailure())
            #expect(LibraryChatSession.failure(unwrapping: opaque) as? AssistantFailure == .unknown)
        }
    }
#endif
