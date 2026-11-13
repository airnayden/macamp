import XCTest

/// XCUITest coverage for the library-health card and the findings sheet it opens.
///
/// The card used to be inert — it counted findings and offered no way to see them.
/// These tests drive the whole repaired path end to end: card → findings sheet →
/// per-finding Review → proposal preview → Apply → the library actually changed.
///
/// Runs against the hermetic launch-environment-seeded app (temp database +
/// throwaway `UserDefaults` suite via `AppEnvironment.liveForUITesting()`), so it
/// never touches the user's real library or defaults.
///
/// ONE EXTRA SEAM, AND WHY IT IS NEEDED: `UITEST_SEED_HYGIENE=1` (`HygieneFixture`).
/// The base fixture's two tracks have a `nil` `fileSize`, and `LibraryHygieneService`
/// calls two rows the same recording only when title, artist, duration AND file size
/// all agree — a conjunct it cannot evaluate is one it cannot satisfy. So the stock
/// fixture can never produce a duplicate however many copies it holds, and the only
/// hygiene finding reachable from it is a metadata gap, whose proposal writes TAGS TO
/// DISK. The fixture files are zero bytes, so that write genuinely fails. The planted
/// duplicate is what makes an end-to-end Apply — a pure playlist-membership rewrite —
/// reachable at all.
final class HygieneFlowTests: XCTestCase {
    private var app: XCUIApplication!
    private var seedPath: String!
    private var runID: String!

    private static let hygieneKey = "com.example.macamp.settings.ai.hygieneEnabled"
    /// The row the duplicate finding always occupies: `findings` emits duplicates,
    /// then clusters, then gaps, and the fixture plants exactly one duplicate.
    private static let duplicateFindingIndex = 0

    override func setUpWithError() throws {
        continueAfterFailure = false
        let identifier = UUID().uuidString
        runID = identifier
        seedPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("macamp-hygiene-uitest-\(identifier)")
        app = XCUIApplication()
        app.launchEnvironment["UITEST_SEED_PATH"] = seedPath
        app.launchEnvironment["UITEST_RUN_ID"] = identifier
        app.launchEnvironment["UITEST_PRESERVE_DATABASE"] = "1"
        app.launchEnvironment["UITEST_SEED_HYGIENE"] = "1"
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
        if let seedPath { try? FileManager.default.removeItem(atPath: seedPath) }
        if let runID { UserDefaults().removePersistentDomain(forName: "com.example.macamp.uitest.\(runID)") }
    }

    /// The whole repaired path. Ends on a change the LIBRARY can be asked about, not
    /// on a sheet that closed.
    func testHygieneCardOpensItsFindingsAndAppliesADuplicateCleanup() {
        app.launch()
        openAssistantPane()

        let card = element("assistant.card.hygiene")
        XCTAssertTrue(card.waitForExistence(timeout: 20), "the fixture library should produce hygiene findings")
        XCTAssertTrue(card.isHittable, "the card must be pressable — it used to be inert chrome")
        snap("hygiene-card")

        card.click()
        XCTAssertTrue(
            element("assistant.hygiene.sheet").waitForExistence(timeout: 15),
            "pressing the card should open the findings sheet; on screen: \(visibleLabels())"
        )
        XCTAssertTrue(
            element("assistant.hygiene.reviewAll.duplicates").waitForExistence(timeout: 15),
            "the planted duplicate should give the Duplicates section a Review All affordance"
        )
        XCTAssertTrue(
            element("assistant.hygiene.reviewAll.gaps").exists,
            "and the untagged fixture tracks should give the Missing tags section one too"
        )
        snap("hygiene-sheet")

        let review = element("assistant.hygiene.finding.\(Self.duplicateFindingIndex).review")
        XCTAssertTrue(review.waitForExistence(timeout: 10), "the duplicate finding should offer its own Review")
        review.click()

        XCTAssertTrue(
            element("assistant.proposalList").waitForExistence(timeout: 20),
            "Review should hand the finding to the proposal preview"
        )
        XCTAssertTrue(
            element("assistant.proposalTrack.3.included").waitForExistence(timeout: 10),
            "the preview should offer a per-track checkbox for the redundant entry"
        )
        snap("hygiene-proposal-preview")

        let apply = element("assistant.applyButton")
        XCTAssertTrue(apply.isEnabled, "a duplicate cleanup is a membership rewrite and must be applicable")
        apply.click()
        XCTAssertTrue(waitForDisappearance(of: "assistant.proposalList"), "a successful apply should close the preview")

        // The findings sheet re-runs the pass after an apply. The duplicate ROW stays
        // — two copies are still on disk, and this layer cannot propose deleting one —
        // but it is no longer ACTIONABLE, because the playlist no longer plays it
        // twice. That is a statement about the database, re-derived from it.
        XCTAssertTrue(
            waitForDisappearance(of: "assistant.hygiene.reviewAll.duplicates"),
            "with the membership fixed, the Duplicates section must stop offering a change"
        )
        XCTAssertFalse(
            element("assistant.hygiene.finding.\(Self.duplicateFindingIndex).review").exists,
            "and the duplicate row must stop offering one too"
        )
        snap("hygiene-sheet-after-apply")

        element("assistant.hygiene.closeButton").click()
        assertPlaylistLostItsRedundantEntry()
    }

    /// The bundle gate is unchanged by the card gaining an action: with library
    /// hygiene switched off the card is absent, so the sheet is unreachable.
    func testHygieneCardIsAbsentWhenTheHygieneBundleIsOff() {
        app.launchArguments += ["-\(Self.hygieneKey)", AssistantFlowTests.xmlPlistBool(false)]
        app.launch()
        openAssistantPane()

        XCTAssertTrue(
            element("assistant.suggestionFeed").waitForExistence(timeout: 20)
                || element("assistant.promptField").exists,
            "the assistant pane itself must still render"
        )
        XCTAssertFalse(element("assistant.card.hygiene").exists, "the library-health card must be gone")
        XCTAssertFalse(element("assistant.hygiene.sheet").exists, "and its sheet must be unreachable")
        snap("hygiene-card-absent")
    }
}

// MARK: - Harness

private extension HygieneFlowTests {
    /// The fixture playlist keeps the FIRST-positioned copy and drops the later one,
    /// so the original title survives and the duplicate's does not.
    func assertPlaylistLostItsRedundantEntry() {
        let playlistRow = app.staticTexts["Hygiene Mix"]
        XCTAssertTrue(playlistRow.waitForExistence(timeout: 15), "the fixture playlist should be in the sidebar")
        playlistRow.click()

        XCTAssertTrue(
            app.staticTexts["Aurora Anthem"].waitForExistence(timeout: 15),
            "the kept copy should still be in the playlist; on screen: \(visibleLabels())"
        )
        XCTAssertFalse(
            app.staticTexts["AURORA ANTHEM"].exists,
            "the redundant copy should have been removed from the playlist by the apply"
        )
        snap("hygiene-playlist-after-apply")
    }

    func openAssistantPane() {
        let row = element("sidebar.row.assistant")
        XCTAssertTrue(row.waitForExistence(timeout: 30), "the Assistant sidebar row should exist by default")
        row.click()
        XCTAssertTrue(
            element("assistant.promptField").waitForExistence(timeout: 15),
            "selecting the Assistant row should show the pane"
        )
    }

    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func waitForDisappearance(of identifier: String) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element(identifier))
        return XCTWaiter().wait(for: [expectation], timeout: 20) == .completed
    }

    /// Every label currently on screen, for failure messages — the AX transcript a
    /// bare "element not found" does not give you.
    ///
    /// A loop, not `map(\.label)`: `XCUIElement.label` is main-actor isolated, so a
    /// key path to it does not compile — and SwiftFormat's `preferKeyPath` rewrites
    /// the equivalent `map { $0.label }` INTO that key path.
    func visibleLabels() -> String {
        var labels: [String] = []
        for candidate in app.descendants(matching: .any).allElementsBoundByIndex.prefix(120) {
            let label = candidate.label
            guard !label.isEmpty else { continue }
            labels.append(label)
        }
        return labels.joined(separator: " | ")
    }

    func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
