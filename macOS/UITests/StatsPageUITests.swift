import XCTest

/// XCUITest smoke for the Stats sidebar page (plan todo 10).
///
/// Runs against the hermetic launch-environment-seeded app (temp database +
/// throwaway `UserDefaults` suite via `AppEnvironment.liveForUITesting()`), so it
/// never touches the user's real library or defaults. Every wait is a
/// `waitForExistence` / `XCTNSPredicateExpectation` — there are no wall-clock sleeps.
///
/// The page has TWO distinct empty shapes and both are covered here, because they
/// are produced by different gates and only one of them renders the dashboard:
///
///   * **No history at all** — nothing recorded and no lifetime counters, so
///     `StatsView.isEmpty` replaces the WHOLE page with the "No Stats Yet" state.
///     The period filter does not exist in this shape.
///   * **Lifetime counters, no `playEvent` rows** (`UITEST_SEED_PLAY_COUNTS=1`) — a
///     library predating the v15 event log. The dashboard renders, so the filter is
///     present and switchable, while every window-scoped section is individually
///     empty: no hour chart, no top lists.
final class StatsPageUITests: XCTestCase {
    private var app: XCUIApplication!
    private var seedPath: String!
    private var runID: String!

    /// The main window's `minWidth` is 880 (`MainWindowView`); anything at or below
    /// this proves the drag really reached the constraint rather than nudging.
    private static let minimumWindowWidth: CGFloat = 900

    /// Far wider than any screen, so the resize drag always lands on the clamp.
    private static let oversizedDragDistance: CGFloat = 1600

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
        if let seedPath { try? FileManager.default.removeItem(atPath: seedPath) }
        if let runID { UserDefaults().removePersistentDomain(forName: "com.example.macamp.uitest.\(runID)") }
    }

    /// The filter renders, all four periods are selectable, and — with no recorded
    /// events behind them — every window-scoped section stays absent rather than
    /// drawing a fabricated empty chart.
    func testStatsPageFilterSwitchesAndHistorySectionsStayEmpty() {
        launch(lifetimePlayCounts: true)
        openStats()
        snap("stats-page")

        let filter = element("stats.windowFilter")
        XCTAssertTrue(filter.waitForExistence(timeout: 30), "the period filter should render on the stats page")

        let segments = windowFilterSegments()
        XCTAssertEqual(segments.count, 4, "the period filter should offer four windows")
        for (index, segment) in segments.enumerated() {
            segment.click()
            XCTAssertTrue(
                wait(segment, "isSelected == true"),
                "clicking period segment \(index) should select it"
            )
            snap("stats-window-\(index)")
        }

        XCTAssertFalse(
            element("stats.hourChart").exists,
            "the listening clock must stay hidden while no plays are recorded"
        )
        XCTAssertFalse(
            element("stats.recentPlays").exists,
            "recent plays must stay hidden while no plays are recorded"
        )
        XCTAssertTrue(
            app.staticTexts["Nothing played in this period yet."].waitForExistence(timeout: 15),
            "the top list should show its empty line"
        )
        XCTAssertTrue(filter.exists, "the page must survive cycling every period")
        snap("stats-empty-sections")
    }

    /// The page still exposes its primary control at the window's minimum width.
    func testStatsPageKeepsTheFilterAtTheMinimumWindowWidth() {
        launch(lifetimePlayCounts: true)
        openStats()

        let filter = element("stats.windowFilter")
        XCTAssertTrue(filter.waitForExistence(timeout: 30))
        snap("stats-before-resize")

        shrinkWindowToMinimumWidth()
        XCTAssertTrue(
            waitForWindowWidth(atMost: Self.minimumWindowWidth),
            "dragging the corner should clamp the window at its minimum width"
        )
        XCTAssertTrue(filter.waitForExistence(timeout: 15), "the period filter must survive the narrowest layout")
        snap("stats-minimum-width")
    }

    /// Nothing recorded anywhere: the whole page is the empty state, and the
    /// dashboard — filter and insights card included — is absent rather than showing
    /// zeroed figures or narrating a period that does not exist.
    func testStatsPageShowsTheWholePageEmptyStateWithoutAnyHistory() {
        launch(lifetimePlayCounts: false)
        openStats()

        XCTAssertTrue(
            app.staticTexts["No Stats Yet"].waitForExistence(timeout: 30),
            "an untouched library should show the whole-page empty state"
        )
        XCTAssertFalse(element("stats.hourChart").exists, "there is no clock to draw without plays")
        XCTAssertFalse(element("stats.windowFilter").exists, "the dashboard should not render over an empty page")
        XCTAssertFalse(element("stats.insightsCard").exists, "there is no period to narrate over an empty page")
        snap("stats-no-history")
    }

    /// The insights card renders for the selected period, and with no recorded events
    /// behind it says exactly that instead of fabricating a summary.
    ///
    /// The sentence is deterministic because the hermetic launch seam pins the narrator
    /// to its template tier (`AppEnvironment.modelInsightNarrator`), so this assertion
    /// does not depend on whether the host's on-device model happens to be available.
    func testStatsInsightsCardNarratesTheSelectedPeriod() {
        launch(lifetimePlayCounts: true)
        openStats()

        let card = element("stats.insightsCard")
        XCTAssertTrue(card.waitForExistence(timeout: 30), "the insights card should render on the stats page")
        XCTAssertTrue(
            app.staticTexts["Nothing has been played in this period yet."].waitForExistence(timeout: 15),
            "a period with no plays should narrate the deterministic template line"
        )
        snap("stats-insights-card")

        let refresh = element("stats.insights.refreshButton")
        XCTAssertTrue(refresh.waitForExistence(timeout: 15), "the card should offer a refresh affordance")
        refresh.click()
        XCTAssertTrue(card.waitForExistence(timeout: 15), "refreshing must rewrite the card, never remove it")
        XCTAssertTrue(
            app.staticTexts["Nothing has been played in this period yet."].waitForExistence(timeout: 15),
            "an explicit refresh over the same empty period should narrate the same line"
        )
        snap("stats-insights-refreshed")
    }
}

// MARK: - Harness

private extension StatsPageUITests {
    func launch(lifetimePlayCounts: Bool) {
        continueAfterFailure = false
        let identifier = UUID().uuidString
        runID = identifier
        seedPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("macamp-uitest-\(identifier)")

        app = XCUIApplication()
        app.launchEnvironment["UITEST_SEED_PATH"] = seedPath
        app.launchEnvironment["UITEST_RUN_ID"] = identifier
        if lifetimePlayCounts {
            app.launchEnvironment["UITEST_SEED_PLAY_COUNTS"] = "1"
        }
        app.launch()
    }

    func openStats() {
        let row = element("sidebar.row.stats")
        XCTAssertTrue(row.waitForExistence(timeout: 30), "the Stats sidebar row should exist")
        row.click()
    }

    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// A segmented `Picker` exposes its options as radio buttons on macOS; the button
    /// fallback keeps the test honest if AppKit ever reshapes that control.
    func windowFilterSegments() -> [XCUIElement] {
        let filter = element("stats.windowFilter")
        let radios = filter.radioButtons.allElementsBoundByIndex
        return radios.isEmpty ? filter.buttons.allElementsBoundByIndex : radios
    }

    /// Drags the window's bottom-right corner far to the left so AppKit clamps the
    /// frame at `minWidth`. XCUITest has no direct resize API.
    func shrinkWindowToMinimumWidth() {
        let corner = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
        let target = corner.withOffset(CGVector(dx: -Self.oversizedDragDistance, dy: 0))
        corner.press(forDuration: 0.4, thenDragTo: target)
    }

    func waitForWindowWidth(atMost limit: CGFloat, timeout: TimeInterval = 15) -> Bool {
        let window = app.windows.firstMatch
        let predicate = NSPredicate { _, _ in window.frame.width <= limit }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    func wait(_ element: XCUIElement, _ predicateFormat: String, timeout: TimeInterval = 10) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: predicateFormat),
            object: element
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
