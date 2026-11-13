import XCTest

/// Todo 12 smoke: Downloads has a sidebar row — the last entry of the Library section —
/// selecting it opens the queue pane (empty state plus a live pause/resume control), and
/// the toolbar `+` raises the paste sheet with every accessibility identifier the flow
/// depends on resolving.
///
/// Deliberately drives no download: spawning yt-dlp from an XCUITest would put a real
/// network transfer inside a UI smoke run. The queue's own behaviour is covered
/// hermetically by `DownloadsTests` and `ViewModelTests`; what only a running app can
/// prove is that these surfaces exist and are reachable.
final class DownloadsFlowTests: XCTestCase {
    private var app: XCUIApplication!
    private var seedPath: String!
    private var runID: String!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let identifier = UUID().uuidString
        runID = identifier
        seedPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("macamp-downloads-uitest-\(identifier)")
        app = XCUIApplication()
        app.launchEnvironment["UITEST_SEED_PATH"] = seedPath
        app.launchEnvironment["UITEST_RUN_ID"] = identifier
        app.launchEnvironment["UITEST_PRESERVE_DATABASE"] = "1"
        app.launchArguments += [
            "-com.example.macamp.settings.karaokeEnabled", "NO",
            "-com.example.macamp.settings.profilesEnabled", "NO",
        ]
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
        if let seedPath { try? FileManager.default.removeItem(atPath: seedPath) }
        if let runID { UserDefaults().removePersistentDomain(forName: "com.example.macamp.uitest.\(runID)") }
    }

    func testDownloadsDestinationOpensItsQueuePane() {
        app.launch()
        click("sidebar.row.downloads")

        XCTAssertTrue(
            element("downloads.queue.pauseButton").waitForExistence(timeout: 15),
            "the Downloads pane should render its pause/resume control even on an empty queue"
        )
        XCTAssertTrue(
            element("downloads.addButton").waitForExistence(timeout: 15),
            "the Downloads destination should carry a toolbar button that opens the paste sheet"
        )
    }

    func testPasteSheetOpensWithItsIdentifiersResolving() {
        app.launch()
        click("sidebar.row.downloads")
        click("downloads.addButton")

        XCTAssertTrue(
            element("downloads.pasteSheet").waitForExistence(timeout: 15),
            "the toolbar button should present the paste sheet"
        )
        XCTAssertTrue(element("downloads.pasteSheet.editor").exists, "the paste sheet should expose its text editor")
        XCTAssertTrue(element("downloads.pasteSheet.addButton").exists, "the paste sheet should expose its Add button")
        XCTAssertTrue(
            element("downloads.pasteSheet.dismissButton").exists,
            "the paste sheet should expose its dismiss button"
        )
    }

    /// A block of non-links must enqueue nothing, report what it refused, and leave the
    /// sheet standing — the QA failure scenario, driven end to end.
    func testPastingGarbageReportsSkippedLinesAndQueuesNothing() {
        app.launch()
        click("sidebar.row.downloads")
        click("downloads.addButton")

        let editor = element("downloads.pasteSheet.editor")
        XCTAssertTrue(editor.waitForExistence(timeout: 15), "missing the paste sheet's editor")
        editor.click()
        // One line, not a block: the Add button owns `.defaultAction`, so a typed
        // newline is a coin-flip on whether the text view consumes it or the sheet
        // submits early. Multi-line splitting is proven hermetically in
        // `DownloadsPasteFlowTests`; what only a running app can show is the round trip.
        editor.typeText("hello there, not a link")

        click("downloads.pasteSheet.addButton")

        XCTAssertTrue(
            element("downloads.pasteSheet.report").waitForExistence(timeout: 15),
            "submitting junk should still produce an inline report"
        )
        XCTAssertTrue(element("downloads.pasteSheet.skipped").exists, "the refused lines should be listed by name")
        // Two identifiers, because the queue pane has two row families since todo 6:
        // `downloads.queue.row.0` is now the first PENDING row (it used to be the
        // in-flight one, which had no separate identifier), and
        // `downloads.queue.activeRow.0` is the first transferring row. Junk must produce
        // neither, so asserting only the pending family would leave half the claim
        // unchecked.
        XCTAssertTrue(
            element("downloads.queue.row.0").waitForNonExistence(timeout: 5),
            "junk must not enqueue a pending download row"
        )
        XCTAssertTrue(
            element("downloads.queue.activeRow.0").waitForNonExistence(timeout: 5),
            "junk must not start a download"
        )
    }

    /// Todo 14 smoke: the Downloads destination is now a CONTAINER over two tabs, so the
    /// pane must carry the tab control, open on Queue, and swap panes on selection.
    ///
    /// Asserting the outgoing pane DISAPPEARS is what separates a working switch from a
    /// picker wired to nothing: `downloads.history.clearButton` appearing while
    /// `downloads.queue.pauseButton` also still resolves would mean both panes are
    /// mounted, which is exactly the always-mounted shape the macOS UI performance rules
    /// reserve for the main window's sliding panes and not for a tab switch.
    func testDownloadsTabsSwitchBetweenTheQueueAndTheHistory() {
        app.launch()
        click("sidebar.row.downloads")

        XCTAssertTrue(
            element("downloads.tabs").waitForExistence(timeout: 15),
            "the Downloads pane should carry a Queue/History tab control"
        )
        XCTAssertTrue(
            element("downloads.queue.pauseButton").waitForExistence(timeout: 15),
            "the Downloads pane should open on the Queue tab"
        )

        click("downloads.tabs.history")

        XCTAssertTrue(
            element("downloads.history.clearButton").waitForExistence(timeout: 15),
            "the History tab should carry its Clear History control"
        )
        XCTAssertTrue(
            element("downloads.queue.pauseButton").waitForNonExistence(timeout: 5),
            "selecting History should take the queue pane off screen, not stack it behind"
        )

        click("downloads.tabs.queue")

        XCTAssertTrue(
            element("downloads.queue.pauseButton").waitForExistence(timeout: 15),
            "selecting Queue again should bring the queue pane back"
        )
    }

    func testFailedDownloadAppearsInHistoryAndRetryReturnsToQueue() throws {
        // The isolated QA bundle omits yt-dlp, making the preflight fail locally.
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MACAMP_TEST_MISSING_DOWNLOAD_TOOL"] == "1")
        app.launch()
        click("sidebar.row.downloads")
        click("downloads.addButton")
        let editor = element("downloads.pasteSheet.editor")
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        editor.click()
        editor.typeText("https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        click("downloads.pasteSheet.addButton")
        click("downloads.pasteSheet.dismissButton")
        click("downloads.tabs.history")
        XCTAssertTrue(element("downloads.history.row.0.failureReason").waitForExistence(timeout: 15))
        addCapture("Failed download in History")

        click("downloads.history.row.0.retryButton")
        XCTAssertTrue(element("downloads.queue.pauseButton").waitForExistence(timeout: 15))
        click("downloads.tabs.history")
        XCTAssertTrue(element("downloads.history.row.0.retryButton").waitForExistence(timeout: 15))
        XCTAssertFalse(element("downloads.history.row.1.retryButton").exists)
    }

    func testLyricsShowProgressAndHTTPFailure() {
        app.launchEnvironment["UITEST_LYRICS_HTTP_FAILURE"] = "1"
        app.launch()
        let play = app.buttons["Play All"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        play.click()

        XCTAssertTrue(element("lyrics.fetch.progress").waitForExistence(timeout: 5))
        addCapture("Lyrics fetch in progress")
        let failure = element("lyrics.fetch.failure")
        XCTAssertTrue(failure.waitForExistence(timeout: 15))
        let message = (failure.value as? String) ?? failure.label
        XCTAssertTrue(message.contains("503"), message)
        addCapture("Lyrics HTTP failure")
        click("lyrics.fetch")
        XCTAssertTrue(element("lyrics.fetch.progress").waitForExistence(timeout: 5))
    }

    private func addCapture(_ name: String) {
        let capture = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        capture.name = name
        capture.lifetime = .keepAlways
        add(capture)
    }

    // MARK: - Helpers

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Waits for HITTABILITY, not merely existence, before clicking.
    ///
    /// `waitForExistence` returns as soon as the element is in the accessibility tree,
    /// which for a sidebar row is before the list has settled — clicking then resolves
    /// against a container with no hit point ("Unable to find hit point for
    /// ScrollView"), which is a flake rather than a defect. Observed once on the
    /// Downloads row while the two sibling tests doing the identical thing passed.
    private func click(_ identifier: String, timeout: TimeInterval = 30) {
        let target = element(identifier)
        XCTAssertTrue(target.waitForExistence(timeout: timeout), "missing \(identifier)")
        let hittable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isHittable == true"),
            object: target
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [hittable], timeout: timeout),
            .completed,
            "\(identifier) never became hittable"
        )
        target.click()
    }
}
