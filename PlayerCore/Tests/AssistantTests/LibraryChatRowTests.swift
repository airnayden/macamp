// LibraryChatRowTests — the structured-row seam: which payloads become rows, which
// tools may carry them, and how a row reaches an event.
//
// ── THE PAYLOADS ARE REAL ─────────────────────────────────────────────────────
//
// The shape tests drive EVERY registered tool through the shipping toolbox and read
// the payloads it actually produced, reusing ``LibraryToolboxPrivacyTests/calls`` —
// the same table that already doubles as the `resultCount` oracle. A hand-written
// payload literal would keep passing after a key was renamed one layer down, which
// is precisely the drift this discriminator has to survive: it reads keys out of an
// untyped ``ToolboxJSON``, so the compiler cannot catch a rename for it.
//
// Floor-available on purpose: this is pure policy over value types, so it needs no
// SDK, no model and no macOS 26 host — the same reasoning `LibraryChatEventTests`
// records for the event mapping it feeds.
import Foundation
@testable import Services
import Testing

@Suite("LibraryChat structured rows")
struct LibraryChatRowTests {
    /// The tools whose payloads the SHAPE gate admits, over
    /// ``LibraryToolboxPrivacyTests/calls``.
    ///
    /// Five of the six non-track shapes are ruled out with no tool name consulted:
    /// genre (`list_genres`), playlist (`list_playlists`), proposal
    /// (`propose_playlist`), feature (`get_track_features`) and stats
    /// (`get_listening_stats`).
    ///
    /// All FOUR control tools are in this set DELIBERATELY. Every one of them
    /// answers through the shared `controlResult`, which reports the resulting
    /// player state — including its `upNext` rows — so a playback entry reaches the
    /// discriminator from four tools, not just from `get_playback_state`. A
    /// playback entry's keys are a strict subset of a track payload's, so no
    /// predicate that admits a track can exclude any of them: they are stopped by
    /// the OTHER gate, ``AssistantChatRow/rowCarryingToolNames``. If a control tool
    /// ever leaves this set, the two gates have silently become one and the
    /// allow-list would look redundant.
    static let shapeAdmitted: Set<String> = [
        "search_tracks",
        "get_tracks",
        "get_playlist",
        "sample_tracks",
        "match_tracks",
        "get_playback_state",
        "play_tracks",
        "queue_tracks",
        "transport",
    ]

    private static func payloads(_ result: ToolResult) -> [ToolboxJSON] {
        result.rows.map(\.payload)
    }

    // MARK: - The seven payload shapes

    @Test("Genre, playlist, proposal, feature and stats payloads each produce ZERO rows")
    func discriminatesEveryShippedPayloadShape() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let (toolbox, _) = ToolboxFixtures.makeControllableToolbox(database)
        var seen: Set<String> = []
        for call in LibraryToolboxPrivacyTests.calls {
            let result = try await toolbox.execute(call.name, arguments: ToolArguments(call.arguments))
            guard !result.rows.isEmpty else { continue }
            seen.insert(call.name)
            let rows = AssistantChatRow.rows(from: Self.payloads(result))
            #expect(
                rows.isEmpty == !Self.shapeAdmitted.contains(call.name),
                "\(call.name) produced \(rows.count) rows"
            )
        }
        // Every shape-admitting tool must actually have answered with rows, or the
        // assertion above passed vacuously for it.
        #expect(Self.shapeAdmitted.isSubset(of: seen))
    }

    @Test("A track payload becomes a row carrying the id, title and artist")
    func buildsRowFromTrackPayload() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database)
        let result = try await toolbox.execute("get_tracks", arguments: ToolArguments([
            "track_ids": .array([.int(1), .int(3)]),
        ]))
        #expect(AssistantChatRow.rows(from: Self.payloads(result)) == [
            AssistantChatRow(trackId: 1, title: "Aurora Drift", artist: "Nova Field"),
            AssistantChatRow(trackId: 3, title: "Ember Waltz", artist: "Paper Lanterns"),
        ])
    }

    // MARK: - Malformed and edge payloads

    @Test("An id of zero or below is dropped — `#0` is not a handle")
    func dropsNonPositiveIdentifiers() {
        // `ToolboxRendering` writes `id: 0` for a record with no row of its own.
        for identifier in [0, -1] {
            let payload = ToolboxJSON.object(["id": .int(identifier), "title": .string("Aurora Drift")])
            #expect(AssistantChatRow.rows(from: [payload]).isEmpty)
        }
    }

    @Test("A malformed payload is SKIPPED rather than throwing, and its neighbours survive")
    func skipsMalformedPayloadsWithoutThrowing() {
        let wellFormed = ToolboxJSON.object(["id": .int(1), "title": .string("Aurora Drift")])
        let malformed: [ToolboxJSON] = [
            .object(["title": .string("no id")]),
            .object(["id": .int(3)]),
            .object(["id": .string("3"), "title": .string("id is a string")]),
            .object(["id": .number(1.5), "title": .string("id is not an integer")]),
            .null,
            .string("not an object"),
            .array([]),
        ]
        #expect(AssistantChatRow.rows(from: malformed).isEmpty)
        #expect(AssistantChatRow.rows(from: malformed + [wellFormed]).count == 1)
    }

    @Test("A blank title arrives as null and the row keeps its id")
    func keepsIdentifierWhenTagsAreBlank() {
        // `ToolboxRendering.string` writes `.null` for a blank tag, so the KEY is
        // present and the VALUE is not a string — the shape gate reads the key.
        let payload = ToolboxJSON.object([
            "id": .int(1),
            "title": .null,
            "artist": .null,
            "availability": .string("present"),
        ])
        #expect(AssistantChatRow.rows(from: [payload]) == [AssistantChatRow(trackId: 1)])
    }

    @Test("Rows are capped, and the cap is larger than the on-device render's")
    func capsRowsAtTheDocumentedLimit() {
        // RECORDED DECISION: the chat may show MORE rows than the 600-character
        // on-device render exposed to the model. Rows come from the full result.
        #expect(AssistantChatRow.limit == 50)
        #expect(AssistantChatRow.limit > ToolProfile.onDevice.rowLimit)
        let many = (1 ... 120).map { identifier in
            ToolboxJSON.object(["id": .int(identifier), "title": .string("t\(identifier)")])
        }
        let rows = AssistantChatRow.rows(from: many)
        #expect(rows.count == AssistantChatRow.limit)
        #expect(rows.first?.trackId == 1)
    }

    // MARK: - Suggestions

    @Test("A miss payload becomes a suggestion; the stats payloads sharing the `kind` key do not")
    func buildsSuggestionsFromMissesOnly() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database)
        let matched = try await toolbox.execute("match_tracks", arguments: ToolArguments(["pairs": .array([
            .object(["title": .string("Aurora Drift"), "artist": .string("Nova Field")]),
            .object(["title": .string("Ghost Song"), "artist": .string("Nobody")]),
            .object(["title": .string("Second Ghost")]),
        ])]))
        #expect(AssistantChatRow.suggestions(from: Self.payloads(matched)) == [
            AssistantChatSuggestion(title: "Ghost Song", artist: "Nobody"),
            AssistantChatSuggestion(title: "Second Ghost"),
        ])
        // A miss has no id, so it is never also a row — the two sets never overlap.
        #expect(AssistantChatRow.rows(from: Self.payloads(matched)).allSatisfy { ($0.trackId ?? 0) > 0 })

        let stats = try await toolbox.execute("get_listening_stats", arguments: ToolArguments([
            "window": .string("all"),
        ]))
        #expect(!stats.rows.isEmpty)
        #expect(AssistantChatRow.suggestions(from: Self.payloads(stats)).isEmpty)
    }

    @Test("Suggestions are capped on the same limit rows are")
    func capsSuggestions() {
        let many = (1 ... 120).map { index in
            ToolboxJSON.object(["kind": .string("miss"), "title": .string("t\(index)")])
        }
        #expect(AssistantChatRow.suggestions(from: many).count == AssistantChatRow.limit)
    }

    // MARK: - The allow-list

    @Test("Exactly the five row-carrying tools are on the allow-list")
    func allowListIsTheFiveRowCarryingTools() {
        #expect(AssistantChatRow.rowCarryingToolNames == [
            "search_tracks",
            "get_tracks",
            "get_playlist",
            "sample_tracks",
            "match_tracks",
        ])
        let excluded = [
            "list_genres", "get_track_features", "get_listening_stats", "list_playlists",
            "propose_playlist", "get_playback_state", "play_tracks", "queue_tracks", "transport",
        ]
        for name in excluded {
            #expect(AssistantChatRow.carriesRows(toolNamed: name) == false, "\(name) must not carry rows")
        }
    }

    @Test("Every allow-listed name is a tool the registry actually publishes")
    func allowListNamesRealTools() throws {
        // A typo here would be silent: an unknown name simply never matches, and
        // the rows for the tool that WAS meant would quietly never appear.
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database)
        #expect(AssistantChatRow.rowCarryingToolNames.isSubset(of: Set(toolbox.allTools.map(\.name))))
    }
}

// MARK: - The ledger and the event

/// The on-device half: what the ledger stores beside its counts, and what the
/// mapper is willing to attach.
@Suite("LibraryChat row ledger")
struct LibraryChatRowLedgerTests {
    private static let searchText = "12 tracks matching \"jazz\"."
    private static let genresText = "3 genres in this listener's library."

    private static var rows: [AssistantChatRow] {
        [AssistantChatRow(trackId: 1, title: "Aurora Drift", artist: "Nova Field")]
    }

    @Test("Rows recorded against an answer reach the event for that answer")
    func recordedRowsReachTheEvent() {
        var counts = ChatToolResultCounts()
        counts.record(renderedText: Self.searchText, resultCount: 12, rows: Self.rows)

        let events = AssistantChatEventMapping.events(
            from: [.toolOutput(name: "search_tracks", text: Self.searchText)],
            counts: counts
        )
        #expect(events == [
            .toolResult(name: "search_tracks", summary: Self.searchText, resultCount: 12, rows: Self.rows),
        ])
    }

    @Test("The join is by ANSWER, so rows recorded for one answer do not reach another's event")
    func rowsAreJoinedByRenderedText() {
        var counts = ChatToolResultCounts()
        counts.record(renderedText: Self.searchText, resultCount: 12, rows: Self.rows)
        counts.record(renderedText: Self.genresText, resultCount: 3)

        let events = AssistantChatEventMapping.events(
            from: [
                .toolOutput(name: "search_tracks", text: Self.genresText),
                .toolOutput(name: "search_tracks", text: Self.searchText),
            ],
            counts: counts
        )
        #expect(events == [
            .toolResult(name: "search_tracks", summary: Self.genresText, resultCount: 3),
            .toolResult(name: "search_tracks", summary: Self.searchText, resultCount: 12, rows: Self.rows),
        ])
    }

    @Test("The allow-list is enforced at the mapper, so a recorded row cannot leak through a non-row tool")
    func allowListIsEnforcedWhenAttaching() {
        // The ledger is keyed on TEXT and knows nothing about tool names, so two
        // tools that answered identically would otherwise share rows. This is also
        // the only thing that keeps a queue listing out of a library list.
        var counts = ChatToolResultCounts()
        counts.record(renderedText: Self.searchText, resultCount: 12, rows: Self.rows)

        let events = AssistantChatEventMapping.events(
            from: [.toolOutput(name: "list_genres", text: Self.searchText)],
            counts: counts
        )
        #expect(events == [.toolResult(name: "list_genres", summary: Self.searchText, resultCount: 12)])
    }

    @Test("Recording rows leaves the count ledger untouched")
    func countLedgerIsUnchangedByRows() {
        var counts = ChatToolResultCounts()
        // A nil count is still not stored, and rows still are — the two are
        // recorded independently against the same key.
        counts.record(renderedText: Self.searchText, resultCount: nil, rows: Self.rows)
        #expect(counts.resultCount(forRenderedText: Self.searchText) == nil)
        #expect(counts.rows(forRenderedText: Self.searchText) == Self.rows)
        #expect(counts.isEmpty == false)

        var countsOnly = ChatToolResultCounts()
        countsOnly.record(renderedText: Self.searchText, resultCount: 12)
        #expect(countsOnly.rows(forRenderedText: Self.searchText).isEmpty)
        #expect(countsOnly.suggestions(forRenderedText: Self.searchText).isEmpty)
    }

    @Test("Suggestions travel the same path rows do")
    func suggestionsRoundTrip() {
        let suggestions = [AssistantChatSuggestion(title: "Ghost Song", artist: "Nova Field")]
        var counts = ChatToolResultCounts()
        counts.record(
            renderedText: Self.searchText,
            resultCount: 1,
            rows: Self.rows,
            suggestions: suggestions
        )
        let events = AssistantChatEventMapping.events(
            from: [.toolOutput(name: "match_tracks", text: Self.searchText)],
            counts: counts
        )
        #expect(events == [.toolResult(
            name: "match_tracks",
            summary: Self.searchText,
            resultCount: 1,
            rows: Self.rows,
            suggestions: suggestions
        )])
    }

    @Test("The actor ledger carries rows through a snapshot, and clears them on reset")
    func actorLedgerCarriesAndClearsRows() async {
        let ledger = LibraryChatToolCounts()
        await ledger.record(renderedText: Self.searchText, resultCount: 12, rows: Self.rows)
        #expect(await ledger.snapshot().rows(forRenderedText: Self.searchText) == Self.rows)
        await ledger.reset()
        #expect(await ledger.snapshot().isEmpty)
    }

    // MARK: - Reaching the transcript

    @Test("A turn's activity carries the rows of the lookup it drew")
    func activityCarriesRows() {
        let turn = AssistantChatTurn(text: "…", events: [
            .toolCall(name: "search_tracks"),
            .toolResult(name: "search_tracks", summary: "a", resultCount: 12, rows: Self.rows),
            .toolCall(name: "list_genres"),
            .toolResult(name: "list_genres", summary: "b", resultCount: 3),
        ])
        #expect(turn.toolActivity == [
            AssistantChatActivity(name: "search_tracks", resultCount: 12, rows: Self.rows),
            AssistantChatActivity(name: "list_genres", resultCount: 3),
        ])
    }

    @Test("An outcome carries the structured rows the on-device render dropped")
    func runOutcomeCarriesStructuredRows() async throws {
        // The on-device render keeps ten rows of a larger answer; the ledger takes
        // its rows from the FULL result, which is what lets the chat list more.
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database)
        let outcome = await toolbox.runResult(
            "search_tracks",
            arguments: ToolArguments(["query": .string("Fillerton"), "limit": .int(40)]),
            profile: .onDevice
        )
        #expect(outcome.rows.count > ToolProfile.onDevice.rowLimit)
        let rows = AssistantChatRow.rows(from: outcome.rows.map(\.payload))
        #expect(rows.count == min(outcome.rows.count, AssistantChatRow.limit))
        #expect(rows.allSatisfy { ($0.trackId ?? 0) > 0 })
    }

    @Test("A refusal carries no rows at all")
    func refusalCarriesNoRows() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database)
        let refused = await toolbox.runResult("search_tracks", profile: .onDevice)
        #expect(refused.resultCount == nil)
        #expect(refused.rows.isEmpty)
    }
}
