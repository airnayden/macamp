// AIChatE2EUITests — the ai-chat-refinement epic driven end to end through the app.
//
// Three scenarios, all riding the SAME seam: `UITEST_CHAT_SCRIPT` substitutes a fake
// `ToolCallingConnector` at the composition root and short-circuits the surface's own
// availability gate. Everything under the connector is production code — the real
// `ToolLoopEngine`, the real merged `[AITool]`, the real `LibraryToolbox`, the real
// proposal filer, and for the MCP scenario the real `MCPClientManager` talking to a
// real spawned child process. Only the MODEL is scripted, which is what makes these
// tests about the app rather than about a mock of it.
//
// ── WHY THESE ARE XCUITESTS AND NOT COMPOSITION TESTS ────────────────────────
//
// Each claim here is about something a composition test structurally cannot see: that
// a filed proposal reaches the transcript as a CARD stating its size, that a tool
// result becomes a real track list with the library context menu attached, and that a
// namespaced MCP tool's answer comes back from another process.
//
// ── RUNNING THEM ─────────────────────────────────────────────────────────────
//
// XCUITest only initializes in an on-console GUI session, and this repo's evidence
// ledger records the off-console failure verbatim. The suite is therefore run under
// the todo-15 precondition protocol and is excluded from the required CI job, exactly
// as `uitest-smoke` is. Scenario (c) additionally needs the fixture server built:
//
//     swift build --package-path AIConnectorKit --product MCPFixtureServer
//
// and its path handed to the runner as `TEST_RUNNER_MACAMP_MCP_FIXTURE=<abs path>`;
// absent that, the `#filePath`-relative fallback finds the same binary.
import XCTest

final class AIChatE2EUITests: XCTestCase {
    var app: XCUIApplication!
    var seedPath: String!
    var audioPath: String!
    var runID: String!

    static let intelligenceKey = "com.example.macamp.settings.ai.intelligenceEnabled"
    /// The app's own defaults domain — NOT this test process's.
    static let applicationDomain = "si.macamp.MacAMP"
    static let mcpServersDefaultsKey = "com.example.macamp.settings.ai.mcp.servers"
    static let mcpConsentDefaultsKey = "com.example.macamp.settings.ai.mcp.consentedServerIds"

    override func setUpWithError() throws {
        continueAfterFailure = false
        Self.resetMCPConfiguration()
        let identifier = UUID().uuidString
        runID = identifier
        seedPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("macamp-aichat-e2e-\(identifier)")
        audioPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("macamp-aichat-audio-\(identifier)")
        app = XCUIApplication()
        app.launchEnvironment["UITEST_SEED_PATH"] = seedPath
        app.launchEnvironment["UITEST_RUN_ID"] = identifier
        app.launchArguments += ["-\(Self.intelligenceKey)", Self.xmlPlistBool(true)]
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
        Self.resetMCPConfiguration()
        if let seedPath { try? FileManager.default.removeItem(atPath: seedPath) }
        if let audioPath { try? FileManager.default.removeItem(atPath: audioPath) }
        if let runID { UserDefaults().removePersistentDomain(forName: "com.example.macamp.uitest.\(runID)") }
    }

    /// Drops any MCP server this suite configured, before AND after every test.
    ///
    /// REQUIRED, and the reason is a real gap in the hermetic seam rather than a
    /// nicety: `AppEnvironment.liveForUITesting` hands its throwaway `UserDefaults`
    /// suite to `ProfileService`, but `AppSettings` — which owns `mcpServers` and
    /// `mcpConsentedServerIDs` — keeps reading the app's REAL
    /// `com.example.macamp` domain. So a scenario that adds a server writes it into
    /// the developer's own preferences and it survives the run. Measured: five
    /// duplicate `fixture` servers accumulated across five executions, and the
    /// consent record from the FIRST of them made every later run's disclosure
    /// correctly not appear — which is what failed this scenario, not the product.
    /// `synchronize()` and the re-read are both load-bearing: `cfprefsd` caches the
    /// app's domain, and the app FLUSHES its own copy as it quits — so a removal that
    /// is not forced through and then confirmed can be resurrected under the next
    /// launch, which is precisely how a stale consent record made this scenario fail
    /// intermittently after the first fix.
    static func resetMCPConfiguration() {
        for _ in 0 ..< 20 {
            guard let defaults = UserDefaults(suiteName: applicationDomain) else { return }
            defaults.removeObject(forKey: mcpServersDefaultsKey)
            defaults.removeObject(forKey: mcpConsentDefaultsKey)
            defaults.synchronize()
            let fresh = UserDefaults(suiteName: applicationDomain)
            fresh?.synchronize()
            if fresh?.object(forKey: mcpServersDefaultsKey) == nil,
               fresh?.object(forKey: mcpConsentDefaultsKey) == nil
            {
                return
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }
}

// MARK: - (a) An exact-count playlist reaches the transcript as a card of 25

extension AIChatE2EUITests {
    func testAskingForTwentyFiveTracksFilesAProposalCardOfTwentyFive() throws {
        try seedRealAudioLibrary(copies: 30)
        app.launchEnvironment["UITEST_CHAT_SCRIPT"] = "proposal25"
        app.launch()
        openAssistantPane()
        submitChat("make me a playlist of 25 rock songs")

        let card = firstElement(withIdentifierPrefix: "assistant.chat.proposal.")
        XCTAssertTrue(
            card.waitForExistence(timeout: 60),
            "the filed proposal should appear as a card in the transcript"
        )
        XCTAssertTrue(
            waitUntil("the proposal card states its size", timeout: 15) {
                Self.combinedText(card).contains("25")
            },
            "the proposal card should state the count the listener asked for, got: \(Self.combinedText(card))"
        )
        snap("t15a-proposal-card")

        card.click()
        XCTAssertTrue(
            element("assistant.proposalList").waitForExistence(timeout: 30),
            "tapping the card should open the review sheet"
        )
        let rows = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "assistant.proposalTrack.")
        )
        XCTAssertEqual(rows.count, 25, "the review sheet should list exactly the 25 proposed tracks")
        snap("t15a-proposal-preview")
    }
}

// MARK: - (b) A track-list result renders real rows with the library context menu

extension AIChatE2EUITests {
    func testATrackListResultRendersRowsWhoseContextMenuPlays() throws {
        try seedRealAudioLibrary(copies: 5)
        app.launchEnvironment["UITEST_CHAT_SCRIPT"] = "trackList"
        app.launch()
        openAssistantPane()
        // Deliberately not a playlist ask: the corrective follow-up turn would append
        // a second assistant row and make the transcript indices ambiguous.
        submitChat("show me those five songs")

        let list = element("assistant.chat.tracks.1.0")
        XCTAssertTrue(list.waitForExistence(timeout: 60), "the tool result should render as a track list")
        let firstRow = element("assistant.chat.tracks.1.0.row.1")
        XCTAssertTrue(firstRow.waitForExistence(timeout: 15), "the first resolved id should have a row")
        snap("t15b-track-list")

        firstRow.rightClick()
        let play = app.menuItems.element(boundBy: 0)
        XCTAssertTrue(play.waitForExistence(timeout: 15), "the row should carry the library context menu")
        play.click()

        let identity = element("player.identity")
        XCTAssertTrue(identity.waitForExistence(timeout: 15), "the player bar should be on screen")
        XCTAssertTrue(
            waitUntil("the player bar names the played track") {
                Self.combinedText(identity).contains("Aurora Anthem")
            },
            "Play from the chat context menu should start the row the listener acted on, "
                + "player identity reads: \(Self.combinedText(identity))"
        )
        snap("t15b-context-menu-play")
    }
}

// MARK: - (c) An MCP tool answers from a real child process

extension AIChatE2EUITests {
    func testAnMCPToolRoundTripsThroughARealChildProcess() throws {
        let fixture = try XCTUnwrap(Self.fixtureServerPath(), "MCPFixtureServer must be built before this scenario")
        app.launchEnvironment["UITEST_CHAT_SCRIPT"] = "mcpEcho"
        app.launch()
        addConsentedFixtureServer(command: fixture)
        openAssistantPane()
        submitChat("ask the fixture server to echo something")

        let answer = element("assistant.chat.assistant.1")
        XCTAssertTrue(answer.waitForExistence(timeout: 90), "the scripted turn should produce an assistant answer")
        XCTAssertTrue(
            waitUntil("the transcript carries the child process's own words") {
                Self.combinedText(answer).contains(Self.echoedText)
            },
            "the echo tool's answer should reach the transcript through the real manager and transport, "
                + "transcript reads: \(Self.combinedText(answer))"
        )
        snap("t15c-mcp-echo")
    }

    /// The same scripted turn with NO server configured, which is what a listener sees
    /// when the one they added is unreachable: the loop answers the model with a
    /// sentence, that sentence lands in the transcript, and nothing crashes.
    func testAnUnreachableMCPToolAnswersWithASentenceRatherThanCrashing() {
        app.launchEnvironment["UITEST_CHAT_SCRIPT"] = "mcpEcho"
        app.launch()
        openAssistantPane()
        submitChat("ask the fixture server to echo something")

        let answer = element("assistant.chat.assistant.1")
        XCTAssertTrue(answer.waitForExistence(timeout: 90), "an unreachable tool must still produce an answer")
        XCTAssertTrue(
            element("assistant.chat.tool.mcp__fixture__echo").waitForExistence(timeout: 30),
            "the unreachable tool should still be reported as an activity row in the transcript"
        )
        // The claim is that the loop ANSWERED rather than threw: a thrown failure
        // renders as `assistant.chat.failure.<index>`, so its absence beside a present
        // assistant bubble is exactly "reported as prose, not as a failure".
        XCTAssertFalse(
            firstElement(withIdentifierPrefix: "assistant.chat.failure.").exists,
            "an unknown tool must not surface as a chat failure banner"
        )
        XCTAssertEqual(app.state, .runningForeground, "an unreachable MCP tool must not take the app down")
        snap("t15c-mcp-unreachable")
    }
}
