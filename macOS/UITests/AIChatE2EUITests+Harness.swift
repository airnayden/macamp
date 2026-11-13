// AIChatE2EUITests+Harness — the launch, navigation and fixture-building helpers the
// three end-to-end scenarios share.
//
// A sibling extension rather than more of `AIChatE2EUITests.swift`, which SwiftLint's
// 400-line `file_length` ceiling would otherwise reject — the same split
// `AssistantFlowTests+PreviewHarness.swift` already makes.
//
// ── READ `value`, NEVER `label` ──────────────────────────────────────────────
//
// Measured on this platform and recorded by `AssistantFlowTests+PreviewHarness`: every
// SwiftUI `Text` publishes its string as the accessibility VALUE and leaves `label`
// empty. Predicates here therefore match on `value`.
import XCTest

extension AIChatE2EUITests {
    /// The distinctive string `ScriptedChatConnector` asks the fixture server to echo.
    /// Duplicated rather than imported: the UITest target links no app code.
    static let echoedText = "macamp-mcp-e2e"

    /// Copies the repo's real `tone.mp3` fixture `copies` times into this run's audio
    /// directory and points the seeder at it, so the seeded rows are ids 3…(2+copies)
    /// and every one of them is a file a decoder can really open.
    func seedRealAudioLibrary(copies: Int) throws {
        let directory = URL(fileURLWithPath: audioPath, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = Self.repositoryRoot
            .appendingPathComponent("PlayerCore/Tests/DecodingTests/Fixtures/tone.mp3")
        for index in 0 ..< copies {
            let name = String(format: "tone-%03d.mp3", index)
            try FileManager.default.copyItem(at: source, to: directory.appendingPathComponent(name))
        }
        app.launchEnvironment["UITEST_SEED_REAL_AUDIO_DIR"] = audioPath
    }

    /// The repo root, walked from this file: `UITests` → `macOS` → root.
    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// The built `MCPFixtureServer`, from the runner environment the todo-15 command
    /// injects, or from the SwiftPM build directory it is always written to.
    static func fixtureServerPath() -> String? {
        if let injected = ProcessInfo.processInfo.environment["MACAMP_MCP_FIXTURE"],
           FileManager.default.isExecutableFile(atPath: injected)
        {
            return injected
        }
        let built = repositoryRoot.appendingPathComponent("AIConnectorKit/.build/debug/MCPFixtureServer").path
        return FileManager.default.isExecutableFile(atPath: built) ? built : nil
    }
}

// MARK: - Navigation

extension AIChatE2EUITests {
    func openAssistantPane() {
        let row = element("sidebar.row.assistant")
        XCTAssertTrue(row.waitForExistence(timeout: 60), "the Assistant sidebar row should exist")
        row.click()
        XCTAssertTrue(
            element("assistant.promptField").waitForExistence(timeout: 30),
            "selecting the Assistant row should show its request field"
        )
    }

    func submitChat(_ text: String) {
        type(text, into: "assistant.promptField", focusVia: "assistant.submitButton")
        element("assistant.submitButton").click()
    }

    /// Adds a stdio MCP server called `fixture`, accepts its disclosure, and closes
    /// Preferences — the whole listener-facing path scenario (c) depends on.
    func addConsentedFixtureServer(command: String) {
        app.typeKey(",", modifierFlags: .command)
        selectIntelligenceTab()
        let add = element("intelligence.mcp.addButton")
        XCTAssertTrue(add.waitForExistence(timeout: 30), "the MCP section should offer an add button")
        // The rows this test did NOT create, so the switch it drives afterwards is
        // provably its own. `firstMatch` on the identifier prefix is NOT good enough:
        // `AppSettings` persists MCP servers in the app's REAL defaults domain (see
        // `resetMCPConfiguration`), so a leftover row from an earlier run can sit
        // first — and because that row is already CONSENTED, toggling it correctly
        // raises no disclosure and the scenario fails against working software.
        let existing = toggleIdentifiers()
        add.click()
        type(command, into: "intelligence.mcp.edit.commandField")
        type("fixture", into: "intelligence.mcp.edit.nameField")
        element("intelligence.mcp.edit.saveButton").click()

        var saved: String?
        _ = waitUntil("the new server row appears", timeout: 30) {
            saved = self.toggleIdentifiers().subtracting(existing).first
            return saved != nil
        }
        guard let saved else {
            attachAccessibilityTree(named: "mcp-server-not-saved")
            snap("mcp-server-not-saved")
            return XCTFail("saving the edit sheet should add a server row")
        }
        let toggle = element(saved)
        XCTAssertTrue(toggle.waitForExistence(timeout: 30), "the saved server should have an enable switch")
        let accept = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
                "intelligence.mcp.consent.", ".acceptButton"
            )
        ).firstMatch
        // The switch is a SwiftUI `Toggle`; a click that lands on its label rather than
        // its knob flips nothing, so the disclosure is retried rather than assumed.
        for _ in 0 ..< Self.focusAttempts where accept.exists == false {
            toggle.click()
            _ = waitUntil("the disclosure appears", timeout: 3) { accept.exists }
        }
        if accept.exists == false {
            attachAccessibilityTree(named: "mcp-consent-missing")
            snap("mcp-consent-missing")
        }
        XCTAssertTrue(accept.waitForExistence(timeout: 15), "the first enable should raise the disclosure")
        accept.click()
        app.typeKey("w", modifierFlags: .command)
    }

    private func selectIntelligenceTab() {
        app.selectSettingsSection("intelligence")
    }

    /// Types `text` into `identifier`, retrying until the field really holds it.
    ///
    /// `focusVia` names the control that FOLLOWS the field in the window's key-view
    /// loop, used only when clicking the field does not focus it — see
    /// ``grantFocus(to:via:)``.
    ///
    /// The verdict is the field's own value rather than any focus flag, because that
    /// is the one claim that stays true however the next OS chooses to report focus.
    /// Typing goes through the APPLICATION element on purpose: `XCUIElement.typeText`
    /// fails the test outright ("Failed to synthesize event: Neither element nor any
    /// descendant has keyboard focus") instead of throwing, so it cannot be used to
    /// probe, while the application element's own check spans the whole window.
    func type(_ text: String, into identifier: String, focusVia successor: String? = nil) {
        let field = element(identifier)
        XCTAssertTrue(field.waitForExistence(timeout: 30), "\(identifier) should be on screen")
        for attempt in 0 ..< Self.focusAttempts {
            if attempt > 0 { clearField() }
            grantFocus(to: field, via: successor)
            app.typeText(text)
            if waitUntil("\(identifier) carries the typed text", timeout: 3, {
                (field.value as? String)?.contains(text) == true
            }) {
                return
            }
        }
        attachAccessibilityTree(named: "type-failure-\(identifier)")
        snap("type-failure-\(identifier)")
        XCTFail("\(identifier) never accepted the typed text")
    }

    /// Gives `field` keyboard focus: a plain click first, then the key-view loop.
    ///
    /// MEASURED, because every intuitive alternative fails. A throwaway probe suite
    /// ran ten strategies against `assistant.promptField` on this machine:
    ///
    ///     plain field.click()                       focus=false  typed=no
    ///     coordinate(0.5, 0.5) / (0.02, 0.5) click  focus=false  typed=no
    ///     coordinate click in the capsule padding   focus=false  typed=no
    ///     doubleClick()                             focus=false  typed=no
    ///     click, wait 3 s, click again              focus=false  typed=no
    ///     settle 5 s / 10 s, then click             focus=false  typed=no
    ///     click, then Tab and Shift-Tab             focus=false  typed=no
    ///     app.activate() / NSRunningApplication     focus=false  typed=no
    ///     window title-bar click, then click        focus=false  typed=no
    ///     CLICK THE SUBMIT BUTTON, THEN SHIFT-TAB   focus=TRUE   typed=YES
    ///
    /// So this field cannot be focused by pointing at it at all; it is reachable only
    /// by landing on its SUCCESSOR in AppKit's key-view loop and stepping backwards.
    /// `library.searchField` — same `.textFieldStyle(.plain)`, same window — focuses
    /// from a plain click, so this is specific to the assistant's field and not a
    /// general property of the app. Recorded rather than worked around silently: see
    /// `.omo/notepads/ai-chat-refinement/issues.md`.
    ///
    /// Clicking the successor is safe here because `assistant.submitButton` is
    /// DISABLED while the field is empty, which is exactly when this runs — and the
    /// retry loop clears the field before every repeat.
    func grantFocus(to field: XCUIElement, via successor: String?) {
        field.click()
        if waitUntil("the field takes keyboard focus", timeout: 2, { Self.holdsKeyboardFocus(field) }) { return }
        guard let successor else { return }
        let neighbour = element(successor)
        guard neighbour.exists else { return }
        neighbour.click()
        app.typeKey(.tab, modifierFlags: .shift)
        _ = waitUntil("the field takes keyboard focus", timeout: 2) { Self.holdsKeyboardFocus(field) }
    }

    private func clearField() {
        app.typeKey("a", modifierFlags: .command)
        app.typeKey(.delete, modifierFlags: [])
    }
}

// MARK: - Keyboard focus

extension AIChatE2EUITests {
    /// How many click/settle rounds to spend before giving up on first responder.
    static let focusAttempts = 8

    /// Focus as `typeText` defines it: the element OR any descendant.
    ///
    /// Scanned by KVC over a BOUNDED slice of the subtree rather than by an
    /// `NSPredicate(format: "hasKeyboardFocus == …")` query — `hasKeyboardFocus` is
    /// not a documented `XCUIElementAttributes` key, and an unsupported key in a
    /// query predicate raises where a KVC read guarded by `responds(to:)` cannot.
    /// A text field's subtree is one or two nodes, so the bound costs nothing.
    static func holdsKeyboardFocus(_ element: XCUIElement) -> Bool {
        if focusFlag(element) { return true }
        let children = element.descendants(matching: .any)
        for index in 0 ..< min(children.count, descendantFocusScanLimit)
            where focusFlag(children.element(boundBy: index))
        {
            return true
        }
        return false
    }

    /// How much of a field's subtree to scan for the field editor.
    static let descendantFocusScanLimit = 8

    /// `hasKeyboardFocus` is not on the public `XCUIElementAttributes` protocol, so
    /// the `responds(to:)` guard is load-bearing: a bare `value(forKey:)` would raise
    /// an uncatchable `NSUnknownKeyException` on a toolchain that dropped it.
    static func focusFlag(_ element: XCUIElement) -> Bool {
        guard element.responds(to: NSSelectorFromString("hasKeyboardFocus")) else { return false }
        return (element.value(forKey: "hasKeyboardFocus") as? Bool) ?? false
    }

    /// The whole AX tree, attached to the report — the only way to see WHICH element
    /// holds focus when the one under test does not.
    func attachAccessibilityTree(named name: String) {
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

// MARK: - Queries and waiting

extension AIChatE2EUITests {
    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// An element's text wherever SwiftUI chose to publish it.
    ///
    /// A bare `Text` publishes its string as the accessibility VALUE and leaves
    /// `label` empty; a view carrying `.accessibilityElement(children: .combine)` plus
    /// an explicit `.accessibilityLabel` — which is what every chat row, proposal card
    /// and player-identity control in this app does — publishes it as the LABEL and
    /// leaves `value` empty. Asserting on one of the two is how four of these tests
    /// failed against UI that was in fact correct.
    static func combinedText(_ element: XCUIElement) -> String {
        [element.label, element.value as? String ?? ""]
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
    }

    /// Every MCP enable-switch identifier currently on screen.
    func toggleIdentifiers() -> Set<String> {
        let query = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "intelligence.mcp.enableToggle.")
        )
        return Set((0 ..< query.count).map { query.element(boundBy: $0).identifier })
    }

    /// The first element whose identifier starts with `prefix` — the only way to reach
    /// a view keyed on a UUID the test did not mint.
    func firstElement(withIdentifierPrefix prefix: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
            .firstMatch
    }

    func waitUntil(_ description: String, timeout: TimeInterval = 60, _ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        expectation.expectationDescription = description
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    static func xmlPlistBool(_ value: Bool) -> String {
        let literal = value ? "true" : "false"
        return """
        <?xml version="1.0" encoding="UTF-8"?>\
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\
        <plist version="1.0"><\(literal)/></plist>
        """
    }
}
