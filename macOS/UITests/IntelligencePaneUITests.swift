import XCTest

/// XCUITest coverage for the Intelligence preferences pane (local-ai-playlists todo 21).
///
/// Two contracts a build alone cannot prove. First, the pane's switch is a real
/// preference: flipping it writes through `AppSettings` to disk and survives a
/// relaunch. Second, the audio-analysis controls are inert while the feature is
/// off — which in this design is not a flag the view reads but the absence of the
/// whole object graph (`AppEnvironment.intelligence` is `nil`), so an enabled
/// button here would mean the graph was built regardless of the switch.
///
/// The switch is restored to its shipped ON state at the end of the relaunch test:
/// `AppSettings` is backed by the app's real `.standard` defaults (the throwaway
/// UI-test suite covers the profile service only), so a run must not leave the
/// developer's app with Intelligence turned off.
final class IntelligencePaneUITests: XCTestCase {
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

    /// Happy path: the tab opens, the switch flips, and the new value survives a
    /// full quit-and-relaunch.
    func testIntelligenceToggleSurvivesARelaunch() {
        openIntelligenceTab()
        let toggle = intelligenceToggle
        XCTAssertTrue(toggle.waitForExistence(timeout: 15), "the Intelligence pane should host the feature switch")
        XCTAssertTrue(isOn(toggle), "Intelligence ships on")
        snapshot("todo-21-intelligence-pane")

        toggle.click()
        XCTAssertTrue(waitUntil("the switch turns off") { !self.isOn(toggle) }, "clicking should turn it off")

        relaunch()
        openIntelligenceTab()
        let reopened = intelligenceToggle
        XCTAssertTrue(reopened.waitForExistence(timeout: 15), "the pane should come back after a relaunch")
        XCTAssertFalse(isOn(reopened), "the off state should have been written to disk and read back")
        snapshot("todo-21-intelligence-pane-off-after-relaunch")

        reopened.click()
        XCTAssertTrue(
            waitUntil("the switch turns back on") { self.isOn(reopened) },
            "restoring the shipped default should leave Intelligence on"
        )
    }

    /// Failure path: with the feature off there is no analysis service in the
    /// process, so its start control must be present but inert.
    func testAnalysisControlsAreDisabledWhileIntelligenceIsOff() {
        openIntelligenceTab()
        let toggle = intelligenceToggle
        XCTAssertTrue(toggle.waitForExistence(timeout: 15), "the Intelligence pane should host the feature switch")
        let start = element("intelligence.analysisStart")
        XCTAssertTrue(start.waitForExistence(timeout: 15), "the analysis section should host a start button")
        XCTAssertTrue(start.isEnabled, "analysis should be startable while Intelligence is on")

        toggle.click()
        XCTAssertTrue(waitUntil("the switch turns off") { !self.isOn(toggle) }, "clicking should turn it off")

        XCTAssertTrue(
            waitUntil("the start button goes inert") { !start.isEnabled },
            "with Intelligence off there is no analysis service, so the control must be disabled"
        )
        snapshot("todo-21-intelligence-analysis-disabled")

        toggle.click()
        XCTAssertTrue(
            waitUntil("analysis becomes startable again") { start.isEnabled },
            "turning Intelligence back on should rebuild the graph and re-enable the control"
        )
    }

    /// Provider picker flow (ai-provider-connectors todo 14): the model picker and
    /// the per-connector status row exist only once a connector is chosen, and the
    /// choice is restored to the shipped default (no provider) afterwards.
    ///
    /// Selecting Ollama probes `127.0.0.1:11434`, which refuses instantly when no
    /// server is running — a loopback round-trip, never an outbound one, and the
    /// exact failure path the status row must survive.
    func testConnectorPickerRevealsModelPickerAndStatus() {
        openIntelligenceTab()
        let picker = element("intelligence.connectorPicker")
        XCTAssertTrue(picker.waitForExistence(timeout: 15), "the pane should host the provider picker")
        XCTAssertFalse(
            element("intelligence.modelPicker").exists,
            "with no provider selected (the shipped default) there is no model to pick"
        )
        snapshot("todo-14-provider-picker-default")

        guard selectFirstConnector(in: picker) else {
            XCTFail("the provider picker should offer at least one registered connector")
            return
        }

        XCTAssertTrue(
            element("intelligence.modelPicker").waitForExistence(timeout: 15),
            "choosing a provider should reveal its model picker"
        )
        XCTAssertTrue(
            element("intelligence.connectorStatus.\(Self.firstConnectorID)").waitForExistence(timeout: 30),
            "choosing a provider should reveal that provider's own status row"
        )
        snapshot("todo-14-provider-picker-selected")

        restoreNoProvider(in: picker)
        XCTAssertTrue(
            waitUntil("the model picker disappears") { !self.element("intelligence.modelPicker").exists },
            "restoring the shipped default should leave no provider selected"
        )
    }
}

// MARK: - Helpers

private extension IntelligencePaneUITests {
    var playerBar: XCUIElement {
        element("player.bar")
    }

    var intelligenceToggle: XCUIElement {
        app.switches.matching(identifier: "intelligence.masterToggle").firstMatch
    }

    /// The first connector `makeConnectorRegistry` registers, in both builds — its
    /// brand name is the picker entry, its id the status row's identifier suffix.
    static var firstConnectorID: String {
        "ollama"
    }

    static var firstConnectorName: String {
        "Ollama"
    }

    /// Opens the provider popup and picks the first registered connector.
    func selectFirstConnector(in picker: XCUIElement) -> Bool {
        picker.click()
        let entry = app.menuItems[Self.firstConnectorName]
        guard entry.waitForExistence(timeout: 10) else { return false }
        entry.click()
        return true
    }

    /// Puts the shipped default back, so a run never leaves the developer's app
    /// routing requests through a provider they did not choose.
    /// Picks the "None (built-in matcher)" entry, the shipped default since Apple
    /// Intelligence was retired as a provider.
    func restoreNoProvider(in picker: XCUIElement) {
        picker.click()
        let entry = app.menuItems["None (built-in matcher)"]
        if entry.waitForExistence(timeout: 10) {
            entry.click()
        }
    }

    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func relaunch() {
        app.terminate()
        app.launch()
        XCTAssertTrue(playerBar.waitForExistence(timeout: 30), "the relaunched window should finish loading")
    }

    func openIntelligenceTab() {
        app.typeKey(",", modifierFlags: .command)
        app.selectSettingsSection("intelligence")
    }

    /// Reads a checkbox's on/off state across the value representations XCUITest may vend.
    func isOn(_ toggle: XCUIElement) -> Bool {
        switch toggle.value {
        case let number as Int: number != 0
        case let flag as Bool: flag
        case let text as String: text == "1" || text.lowercased() == "true"
        default: false
        }
    }

    func waitUntil(_ description: String, timeout: TimeInterval = 10, _ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        expectation.expectationDescription = description
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Attaches the reached state to the `.xcresult` and best-effort writes a PNG
    /// into this todo's evidence directory.
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
            .appendingPathComponent(".omo/evidence/local-ai-playlists", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
