import XCTest

/// Settings navigation, detail sizing and user-resize contracts. Every section
/// must remain reachable at the 800 pt minimum, independently of sidebar scrolling.
final class SettingsWindowTests: XCTestCase {
    private var app: XCUIApplication!
    private var seedPath: String!
    private var runID: String!

    /// English titles paired with their stable lowercase section identifiers.
    private let sectionTitles = [
        "General", "Library", "Downloads", "Playback", "Output", "Equalizer", "Visualizer",
        "Karaoke", "Intelligence", "Online", "Profiles", "Updates", "Acknowledgments",
    ]

    /// `PreferenceMetrics.windowMinWidth` / `.windowMinHeight`. Kept in step by hand:
    /// left behind, the floor assertion stops enforcing the real floor and the
    /// resize-wait passes vacuously at open.
    private let minWidth: CGFloat = 800
    private let minHeight: CGFloat = 520

    override func setUpWithError() throws {
        continueAfterFailure = false
        let identifier = UUID().uuidString
        runID = identifier
        seedPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("macamp-uitest-\(identifier)")

        app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["UITEST_SEED_PATH"] = seedPath
        app.launchEnvironment["UITEST_RUN_ID"] = identifier
        app.launch()

        let playerBar = app.descendants(matching: .any).matching(identifier: "player.bar").firstMatch
        XCTAssertTrue(playerBar.waitForExistence(timeout: 30), "main window should finish loading")
        app.typeKey(",", modifierFlags: .command)
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
        if let seedPath { try? FileManager.default.removeItem(atPath: seedPath) }
        if let runID { UserDefaults().removePersistentDomain(forName: "com.example.macamp.uitest.\(runID)") }
    }

    func testEveryPreferencesSectionIsReachableAtDefaultSize() throws {
        try assertEverySectionIsReachable(in: openedSettingsWindow())
    }

    func testEveryPreferencesSectionIsReachableAtMinimumSize() throws {
        let window = try openedSettingsWindow()
        dragWindowCorner(
            of: window,
            by: CGVector(dx: minWidth - window.frame.width, dy: minHeight - window.frame.height)
        )
        XCTAssertTrue(waitUntil("Settings reaches its minimum width") { abs(window.frame.width - self.minWidth) <= 2 })
        XCTAssertGreaterThanOrEqual(window.frame.height, minHeight)
        try assertEverySectionIsReachable(in: window)
    }

    func testArrowKeysSelectTheAdjacentSection() throws {
        let window = try openedSettingsWindow()
        app.selectSettingsSection("general")
        window.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(waitUntil("the window title follows keyboard selection") { window.title.contains("Library") })
        window.typeKey(.upArrow, modifierFlags: [])
        XCTAssertTrue(waitUntil("keyboard selection returns to General") { window.title.contains("General") })
    }

    /// The Sparkle wiring's user-visible contract: the button that was a permanently
    /// `.disabled(true)` placeholder is now live, so a real update check can be started.
    func testCheckForUpdatesButtonIsEnabled() throws {
        let window = try openedSettingsWindow()
        app.selectSettingsSection("updates")
        let button = window.descendants(matching: .any)
            .matching(identifier: "preferences.updates.checkButton").firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 15), "the Updates pane should host a check button")
        XCTAssertTrue(button.isEnabled, "Check for Updates should be live once Sparkle's updater has started")
    }

    /// The Output pane's one load-bearing control. A pane that is reachable but empty
    /// would still pass `testEveryPreferencesSectionIsReachableAtDefaultSize`, so the device
    /// picker is asserted by identifier rather than inferred from the tab existing.
    func testOutputPaneHostsTheDevicePicker() throws {
        let window = try openedSettingsWindow()
        app.selectSettingsSection("output")
        let picker = window.descendants(matching: .any)
            .matching(identifier: "output.devicePicker").firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 15), "the Output pane should host a device picker")
    }

    func testSettingsWindowOpensAboveItsMinimumSize() throws {
        let window = try openedSettingsWindow()
        XCTAssertGreaterThanOrEqual(window.frame.width, minWidth, "Settings should open at least \(minWidth) pt wide")
        XCTAssertGreaterThanOrEqual(
            window.frame.height,
            minHeight,
            "Settings should open at least \(minHeight) pt tall"
        )
    }

    /// Locks the removal of the old fixed `PreferenceMetrics.paneWidth` (500 pt): the pane
    /// tracks the window's width instead of leaving a dead margin beside it.
    func testPaneContentFillsTheDetailColumn() throws {
        let window = try openedSettingsWindow()
        let pane = form(in: window)
        XCTAssertTrue(pane.waitForExistence(timeout: 15), "the selected pane's form should be present")
        assertPaneFillsDetail(pane, in: window)
    }

    func testResizingTheWindowWidensPaneContent() throws {
        let window = try openedSettingsWindow()
        let pane = form(in: window)
        XCTAssertTrue(pane.waitForExistence(timeout: 15), "the selected pane's form should be present")
        // A window whose style mask lacks `.resizable` disables its zoom button, so an
        // enabled one proves the flag reached the NSWindow.
        XCTAssertTrue(
            window.buttons[XCUIIdentifierZoomWindow].isEnabled,
            "a resizable Settings window keeps its zoom button live"
        )

        let openedSize = window.frame.size
        let openedPaneWidth = pane.frame.width
        dragWindowCorner(of: window, by: CGVector(dx: 200, dy: 150))

        XCTAssertTrue(
            waitUntil("the window grows past \(openedSize.width) pt") { window.frame.width > openedSize.width },
            "dragging the corner should resize the Settings window"
        )
        XCTAssertGreaterThan(window.frame.height, openedSize.height, "the drag should also grow the height")
        XCTAssertTrue(
            waitUntil("the pane grows past \(openedPaneWidth) pt") { pane.frame.width > openedPaneWidth },
            "pane content should track the widened window"
        )
        XCTAssertEqual(pane.frame.width - openedPaneWidth, window.frame.width - openedSize.width, accuracy: 2)
        assertPaneFillsDetail(pane, in: window)
    }

    func testSwitchingSectionsKeepsAManualResize() throws {
        let window = try openedSettingsWindow()
        let openedWidth = window.frame.width
        dragWindowCorner(of: window, by: CGVector(dx: 200, dy: 150))
        XCTAssertTrue(
            waitUntil("the window grows") { window.frame.width > openedWidth },
            "the drag should resize the Settings window"
        )
        let resized = window.frame.size

        for title in ["Karaoke", "General"] {
            app.selectSettingsSection(title.lowercased())
            XCTAssertEqual(
                window.frame.width,
                resized.width,
                accuracy: 1,
                "selecting \(title) must not snap the window back to a pane's ideal width"
            )
            XCTAssertEqual(
                window.frame.height,
                resized.height,
                accuracy: 1,
                "selecting \(title) must not snap the window back to a pane's ideal height"
            )
        }
    }
}

// MARK: - Helpers

private extension SettingsWindowTests {
    /// Resolved through a QUERY, never `allElementsBoundByIndex`: an index-bound handle
    /// re-resolves to whichever window is frontmost, so the frame assertions silently
    /// measure the main window instead.
    var settingsWindow: XCUIElement {
        app.windows.containing(.any, identifier: "preferences.sidebar").firstMatch
    }

    func openedSettingsWindow() throws -> XCUIElement {
        let window = settingsWindow
        XCTAssertTrue(window.waitForExistence(timeout: 20), "the Settings window should open on ⌘,")
        return window
    }

    /// Grabs 2 pt inside the bottom-trailing corner — the window's resize zone.
    func dragWindowCorner(of window: XCUIElement, by delta: CGVector) {
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
            .withOffset(CGVector(dx: -2, dy: -2))
        corner.press(forDuration: 0.4, thenDragTo: corner.withOffset(delta))
    }

    func waitUntil(_ description: String, timeout: TimeInterval = 10, _ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in condition() },
            object: nil
        )
        expectation.expectationDescription = description
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    func form(in window: XCUIElement) -> XCUIElement {
        window.descendants(matching: .any).matching(identifier: "preferences.form").firstMatch
    }

    func detail(in window: XCUIElement) -> XCUIElement {
        window.descendants(matching: .any).matching(identifier: "preferences.detail").firstMatch
    }

    func sidebarScroller(in window: XCUIElement) -> XCUIElement {
        window.scrollViews.containing(.outline, identifier: "preferences.sidebar").firstMatch
    }

    func assertPaneFillsDetail(_ pane: XCUIElement, in window: XCUIElement) {
        let divider = window.descendants(matching: .splitter).firstMatch
        XCTAssertTrue(divider.exists, "the native split divider should be present")
        XCTAssertEqual(pane.frame.minX, divider.frame.maxX, accuracy: 2, "the Form starts after the divider")
        XCTAssertEqual(pane.frame.maxX, window.frame.maxX, accuracy: 2, "the Form fills the trailing region")
    }

    func assertEverySectionIsReachable(in window: XCUIElement) throws {
        let initialWidth = window.frame.width
        for title in sectionTitles {
            app.selectSettingsSection(title.lowercased())
            let row = window.descendants(matching: .any)
                .matching(identifier: "preferences.section.\(title.lowercased())").firstMatch
            XCTAssertTrue(row.isHittable, "the \(title) section should be reachable")
            let scroller = detail(in: window).scrollViews.firstMatch
            XCTAssertTrue(scroller.waitForExistence(timeout: 15), "the \(title) detail should have scrolling content")
            XCTAssertTrue(
                waitUntil("the window title follows \(title)") { window.title.contains(title) },
                "the window title should identify the selected section"
            )
            XCTAssertGreaterThan(scroller.frame.width, 0)
            XCTAssertEqual(window.frame.width, initialWidth, accuracy: 2, "selecting \(title) must preserve the width")
            XCTAssertGreaterThanOrEqual(scroller.frame.minX, sidebarScroller(in: window).frame.maxX - 2)
            XCTAssertLessThanOrEqual(scroller.frame.maxX, window.frame.maxX + 2)
            let capture = XCTAttachment(screenshot: window.screenshot())
            capture.name = "settings-\(title.lowercased())-\(Int(initialWidth))"
            capture.lifetime = .keepAlways
            add(capture)
        }
    }
}
