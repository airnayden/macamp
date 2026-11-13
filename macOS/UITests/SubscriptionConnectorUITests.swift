import XCTest

/// XCUITest coverage for the connector surfaces that a build alone cannot prove.
///
/// A sign-in view that COMPILES and a sign-in view a listener can actually REACH
/// are different claims, and only the second one matters. Every assertion here is
/// about reachability and presentation:
///
///   * ChatGPT reports `unconfigured` ("Not set up yet…"), NOT the
///     `upstream-flow-unavailable` copy it carried until 2026-08-24. Those two
///     strings are the visible difference between a connector a listener can set
///     up and one the app has told them to give up on.
///   * Selecting ChatGPT offers a Sign In affordance, and pressing it PRESENTS the
///     loopback sign-in sheet.
///   * The Ollama setup sheet carries the optional Cloud key field beneath the
///     address.
///
/// NOTHING here starts a real login. The sheet is opened and dismissed; the button
/// that would open a browser and bind port 1455 is deliberately never pressed,
/// because a CI machine must not launch Safari and a developer must not have a
/// half-finished OAuth attempt left behind. The browser-open and port-bind halves
/// are covered hermetically by `macampMacTests`' `ChatGPTSignInTests`, which drives
/// the same model with a captured `openURL` and a real socket on a test port.
///
/// The provider selection is restored to "None" (the default) in `tearDown`, so a run
/// never leaves the developer's app routing through a provider they did not choose.
final class SubscriptionConnectorUITests: XCTestCase {
    private var app: XCUIApplication!
    private var seedPath: String!
    private var runID: String!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let identifier = UUID().uuidString
        runID = identifier
        seedPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("macamp-uitest-\(identifier)")

        app = XCUIApplication()
        app.launchEnvironment["UITEST_SEED_PATH"] = seedPath
        app.launchEnvironment["UITEST_RUN_ID"] = identifier
        app.launchEnvironment["UITEST_PRESERVE_DATABASE"] = "1"
        app.launch()
        XCTAssertTrue(playerBar.waitForExistence(timeout: 30), "main window should finish loading")
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
        if let seedPath { try? FileManager.default.removeItem(atPath: seedPath) }
        if let runID { UserDefaults().removePersistentDomain(forName: "com.example.macamp.uitest.\(runID)") }
    }

    /// ChatGPT is live: it reports "not set up yet" and offers a way to set it up.
    func testChatGPTOffersAReachableSignInSheet() throws {
        openIntelligenceTab()
        let picker = element("intelligence.connectorPicker")
        XCTAssertTrue(picker.waitForExistence(timeout: 15), "the provider picker should exist")
        try select(connector: "ChatGPT", in: picker)

        let status = element("intelligence.connectorStatus.chatgpt")
        XCTAssertTrue(status.waitForExistence(timeout: 15), "the ChatGPT status row should render")
        let text = status.label.isEmpty ? (status.value as? String ?? "") : status.label
        XCTAssertTrue(
            text.contains("Not set up yet"),
            "ChatGPT should report unconfigured, not disabled — got \(text)"
        )
        XCTAssertFalse(text.contains("Unavailable"), "the disabled copy should be gone — got \(text)")

        let signIn = element("intelligence.connectorSignIn")
        XCTAssertTrue(signIn.waitForExistence(timeout: 10), "a subscription connector should offer Sign In")
        signIn.click()

        // PRESENTED, not merely built: the sheet's own sign-in button has to exist.
        let sheetButton = element("externalOAuth.chatGPT.signInButton")
        XCTAssertTrue(sheetButton.waitForExistence(timeout: 15), "the ChatGPT sign-in sheet should present")
        snapshot("wave-b-chatgpt-signin-sheet")

        // Dismiss WITHOUT starting a login — no browser, no bound port.
        element("intelligence.connectorSignIn.doneButton").click()
        restoreNoProvider(in: picker)
    }

    /// Claude Subscription keeps its own, separate sheet — and reports a session
    /// borrowed from the Claude Code CLI when this Mac has one.
    ///
    /// The assertion anchors on the STATUS ROW rather than on the sign-in button,
    /// because which controls the sheet offers depends on the machine: a Mac with a
    /// CLI login already shows "Signed in via Claude CLI" and a Stop-Using button,
    /// with no sign-in button and no code field at all. Asserting the button would
    /// make this test pass or fail on whether the developer happens to use Claude
    /// Code — which is not a property of MacAMP.
    func testClaudeSubscriptionStillPresentsItsOwnSheet() throws {
        openIntelligenceTab()
        let picker = element("intelligence.connectorPicker")
        XCTAssertTrue(picker.waitForExistence(timeout: 15), "the provider picker should exist")
        try select(connector: "Claude Subscription", in: picker)

        let signIn = element("intelligence.connectorSignIn")
        XCTAssertTrue(signIn.waitForExistence(timeout: 15), "Claude should still offer Sign In")
        signIn.click()

        let status = element("externalOAuth.claude.status")
        XCTAssertTrue(status.waitForExistence(timeout: 15), "the Claude sign-in sheet should present")
        snapshot("wave-b-claude-signin-sheet")

        // A borrowed CLI session is the ONE state that must never offer a
        // destructive-sounding "Sign Out": we cannot delete another app's login.
        if element("externalOAuth.claude.cliCaption").exists {
            XCTAssertTrue(
                element("externalOAuth.claude.signOutButton").exists,
                "a reused CLI session should offer the stop-using control"
            )
            XCTAssertFalse(
                element("externalOAuth.claude.codeField").exists,
                "a reused session needs no code paste field"
            )
        }

        element("intelligence.connectorSignIn.doneButton").click()
        restoreNoProvider(in: picker)
    }

    /// The Ollama setup sheet carries the optional Cloud key beneath the address.
    func testOllamaSetUpSheetOffersTheOptionalKeyField() throws {
        openIntelligenceTab()
        let picker = element("intelligence.connectorPicker")
        XCTAssertTrue(picker.waitForExistence(timeout: 15), "the provider picker should exist")
        try select(connector: "Ollama", in: picker)

        let configure = element("intelligence.connectorConfigure")
        XCTAssertTrue(configure.waitForExistence(timeout: 15), "Ollama should offer a setup sheet")
        configure.click()

        XCTAssertTrue(
            element("intelligence.connectorConfig.ollama.hostField").waitForExistence(timeout: 15),
            "the sheet should carry the address field"
        )
        XCTAssertTrue(
            element("intelligence.connectorConfig.ollama.optionalKeyField").waitForExistence(timeout: 10),
            "the sheet should carry the OPTIONAL Cloud key field beneath the address"
        )
        snapshot("wave-b-ollama-optional-key-field")

        element("intelligence.connectorConfig.ollama.cancelButton").click()
        restoreNoProvider(in: picker)
    }
}

// MARK: - Helpers

private extension SubscriptionConnectorUITests {
    var playerBar: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "player.bar").firstMatch
    }

    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func openIntelligenceTab() {
        app.typeKey(",", modifierFlags: .command)
        app.selectSettingsSection("intelligence")
    }

    func select(connector name: String, in picker: XCUIElement) throws {
        picker.click()
        let entry = app.menuItems[name]
        guard entry.waitForExistence(timeout: 10) else {
            throw XCTSkip("\(name) is not registered in this build")
        }
        entry.click()
    }

    func restoreNoProvider(in picker: XCUIElement) {
        picker.click()
        let entry = app.menuItems["None (built-in matcher)"]
        if entry.waitForExistence(timeout: 10) {
            entry.click()
        }
    }

    /// Attaches the reached state to the `.xcresult` and best-effort writes a PNG
    /// into this wave's evidence directory.
    func snapshot(_ name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".omo/evidence/ai-fixes-round2", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
