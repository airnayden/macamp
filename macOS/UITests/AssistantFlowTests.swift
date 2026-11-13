import XCTest

/// XCUITest coverage for the `.assistant` sidebar destination (plan todo 22).
///
/// Runs against the hermetic launch-environment-seeded app (temp database +
/// throwaway `UserDefaults` suite via `AppEnvironment.liveForUITesting()`), so it
/// never touches the user's real library or defaults. Every wait is a
/// `waitForExistence` / `XCTNSPredicateExpectation` — there are no wall-clock sleeps.
///
/// TWO SEAMS MAKE THIS HERMETIC, AND BOTH ARE NON-OBVIOUS:
///
///   * **Turning the toggle off** goes through the NSArgumentDomain as a full XML
///     property list, NOT as `-key NO`. Measured: a bare `NO` lands as an
///     `NSTaggedPointerString`, so `AppSettings`' `object(forKey:) as? Bool ?? true`
///     reads `nil` and the toggle stays ON — the argument would be silently inert
///     (the same trap `AppEnvironment+UITesting` documents for karaoke). An XML
///     plist lands as `__NSCFBoolean` and reads back as a real `false`. Nothing is
///     written to any persistent domain.
///   * **Staging a persisted selection** hands the wrapper's ordinary tagged JSON to
///     the app through `UITEST_SIDEBAR_SELECTION`, which `SidebarSelectionStore` seeds
///     into its store when the key is absent. NOT a cross-process `UserDefaults` write
///     from this runner: that write is visible to the app, but the runner then holds it
///     in `UserDefaults`' in-process cache and can never observe the app's later
///     rewrite (`synchronize()` does not invalidate that cache), which made the
///     fallback test's read-back assertion unsatisfiable. The payload is pinned by
///     `SidebarDestinationAssistantTests.assistantDecodesFromTheHandWrittenPersistedPayload`,
///     so this harness and the encoder cannot drift apart silently.
final class AssistantFlowTests: XCTestCase {
    /// Internal, not `private`, for the same reason as the Harness extension below:
    /// `AssistantContextualActionsTests.swift` extends this suite from a sibling file.
    var app: XCUIApplication!
    private var seedPath: String!
    private var runID: String!

    private static let intelligenceKey = "com.example.macamp.settings.ai.intelligenceEnabled"
    private static let assistantPayload = #"{"kind":"fixed","section":"assistant"}"#

    override func setUpWithError() throws {
        continueAfterFailure = false
        let identifier = UUID().uuidString
        runID = identifier
        seedPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("macamp-assistant-uitest-\(identifier)")
        app = XCUIApplication()
        app.launchEnvironment["UITEST_SEED_PATH"] = seedPath
        app.launchEnvironment["UITEST_RUN_ID"] = identifier
        app.launchEnvironment["UITEST_PRESERVE_DATABASE"] = "1"
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
        if let seedPath { try? FileManager.default.removeItem(atPath: seedPath) }
        if let runID { UserDefaults().removePersistentDomain(forName: suiteName(runID)) }
    }

    /// The row exists, selects, and renders both regions the destination promises.
    /// The hygiene card is the one that is guaranteed present: the seeded fixture
    /// tracks carry no genre / year / album artist, so the pass finds real gaps.
    func testAssistantSidebarRowOpensThePromptFieldAndFeed() {
        app.launch()
        let row = element("sidebar.row.assistant")
        XCTAssertTrue(row.waitForExistence(timeout: 30), "the Assistant sidebar row should exist by default")
        row.click()

        XCTAssertTrue(
            element("assistant.promptField").waitForExistence(timeout: 15),
            "selecting the Assistant row should show its request field"
        )
        XCTAssertTrue(
            element("assistant.suggestionFeed").waitForExistence(timeout: 15),
            "the assistant pane should render its suggestion feed"
        )
        XCTAssertTrue(
            element("assistant.card.hygiene").waitForExistence(timeout: 15),
            "the feed should render at least the library-health card for the fixture library"
        )
        snap("assistant-pane")
    }

    /// With the master toggle off the row is gone entirely — hidden, not disabled.
    func testAssistantRowIsAbsentWhenIntelligenceIsOff() {
        launchWithIntelligenceOff()
        XCTAssertTrue(
            element("sidebar.row.allTracks").waitForExistence(timeout: 30),
            "the sidebar should still render its Library section"
        )
        XCTAssertFalse(
            element("sidebar.row.assistant").exists,
            "the Assistant row must not exist while the Intelligence toggle is off"
        )
        XCTAssertFalse(element("assistant.promptField").exists, "no assistant surface may render")
        snap("assistant-row-absent")
    }

    /// POSITIVE CONTROL for the fallback case below. Without this, a fallback test
    /// would pass even if the staged selection never reached the app at all.
    func testPersistedAssistantSelectionOpensTheAssistantPane() {
        stagePersistedAssistantSelection()
        app.launch()
        XCTAssertTrue(
            element("assistant.promptField").waitForExistence(timeout: 30),
            "a persisted assistant selection should restore straight into the assistant pane"
        )
        snap("assistant-restored")
    }

    /// The dangle guard: a selection persisted by an earlier run resolves to the
    /// default destination when the toggle is off, so the window shows the library
    /// rather than a blank or orphaned pane.
    func testPersistedAssistantSelectionFallsBackWhenIntelligenceIsOff() {
        stagePersistedAssistantSelection()
        launchWithIntelligenceOff()

        XCTAssertTrue(
            element("sidebar.row.allTracks").waitForExistence(timeout: 30),
            "the window should finish launching"
        )
        XCTAssertFalse(element("sidebar.row.assistant").exists, "the Assistant row must be gone")
        XCTAssertFalse(element("assistant.promptField").exists, "the assistant pane must not render")
        XCTAssertTrue(
            app.staticTexts["Aurora Anthem"].waitForExistence(timeout: 15),
            "falling back must land on the library browser, not an empty pane"
        )
        snap("assistant-fallback")

        // The guard also has to PERSIST the resolution, or the selection dangles again
        // on the next launch. Asserted through the product rather than by reading the
        // store: relaunch with Intelligence back ON and with staging switched off, so
        // the only thing that can decide the destination is what the app itself wrote.
        // Were the stored value still `.assistant`, this launch would open the pane —
        // proven by `testPersistedAssistantSelectionOpensTheAssistantPane`.
        app.terminate()
        stopStagingPersistedSelection()
        app.launchArguments = []
        app.launch()

        XCTAssertTrue(
            element("sidebar.row.assistant").waitForExistence(timeout: 30),
            "the relaunch should have Intelligence on again"
        )
        XCTAssertFalse(
            element("assistant.promptField").exists,
            "the guard should have rewritten the persisted selection, so the relaunch "
                + "must NOT restore into the assistant pane"
        )
        XCTAssertTrue(
            app.staticTexts["Aurora Anthem"].exists,
            "the relaunch should restore the default destination it fell back to"
        )
        snap("assistant-fallback-persisted")
    }
}

// MARK: - Proposal preview (plan todo 23)

/// Three seams, all launch-environment only and all `#if DEBUG` (`AssistantUITestSeam`):
///
///   * `UITEST_ASSISTANT_FAKE=1` replaces the parser ladder with one that resolves any
///     request to an unconstrained spec. The fixture tracks carry no genre and no year,
///     so the real heuristic tier reads "upbeat 90s rock" as `year BETWEEN 1990 AND 1999`
///     and correctly matches nothing — the fake is what lets the REST of the production
///     path (rule variants → read-only preview → mix → naming → proposal → apply) run.
///   * `UITEST_ASSISTANT_PROPOSAL=tagChangeSet` stages the one kind `submit` can never
///     produce, so the batch-confirmation gate is reachable from the pane.
///   * `UITEST_ASSISTANT_PROPOSAL=failingRename` stages a rename of a playlist id no
///     fixture database holds. The failure is REAL — `applyRename`'s `fetchPlaylist`
///     misses and production code raises `playlistNotFound` — not a stubbed throw.
extension AssistantFlowTests {
    /// The whole happy path: request → sheet → resolved titles → apply → the playlist
    /// the assistant just created appears in the sidebar.
    func testProposalPreviewAppliesAndTheNewPlaylistReachesTheSidebar() {
        app.launchEnvironment["UITEST_ASSISTANT_FAKE"] = "1"
        app.launch()
        openAssistantPane()

        XCTAssertFalse(
            app.staticTexts[Self.fakeRequest].exists,
            "no playlist may carry the request's name before the proposal is applied"
        )
        submitRequest(Self.fakeRequest)

        XCTAssertTrue(
            element("assistant.proposalList").waitForExistence(timeout: 30),
            "a produced proposal should open the preview sheet"
        )
        XCTAssertTrue(
            fixtureTrackCell.waitForExistence(timeout: 15),
            "the proposal list should render at least one resolved track cell; on screen: \(visibleLabels())"
        )
        let apply = element("assistant.applyButton")
        XCTAssertTrue(apply.waitForExistence(timeout: 5), "the sheet should offer an apply button")
        XCTAssertTrue(apply.isEnabled, "a resolved proposal must be applicable")
        XCTAssertTrue(element("assistant.discardButton").exists, "and a discard button beside it")
        snap("assistant-proposal-preview")

        apply.click()
        XCTAssertTrue(
            waitForDisappearance(of: "assistant.proposalList"),
            "a successful apply should close the sheet"
        )
        XCTAssertTrue(
            app.staticTexts[Self.fakeRequest].waitForExistence(timeout: 20),
            "the created playlist should appear in the sidebar's Playlists section"
        )
        snap("assistant-proposal-applied")
    }

    /// The batch gate: Apply alone never writes tags, and cancelling the confirmation
    /// leaves the proposal exactly where it was.
    func testTagChangeSetNeedsItsOwnConfirmationAndCancellingWritesNothing() {
        app.launchEnvironment["UITEST_ASSISTANT_PROPOSAL"] = "tagChangeSet"
        app.launch()
        openAssistantPane()
        submitRequest("fix my tags")

        XCTAssertTrue(
            element("assistant.proposalList").waitForExistence(timeout: 30),
            "the staged tag change-set should open the preview sheet"
        )
        XCTAssertTrue(
            app.staticTexts["Aurora Anthem.mp3"].waitForExistence(timeout: 15),
            "the tag table should name the file each patch would rewrite"
        )
        XCTAssertTrue(app.staticTexts["Shoegaze"].exists, "and the value each field would take")
        snap("assistant-tag-changeset")

        element("assistant.applyButton").click()
        XCTAssertTrue(
            element("assistant.confirmTagsButton").waitForExistence(timeout: 15),
            "applying a tag change-set must raise its own confirmation, not write"
        )
        XCTAssertFalse(element("assistant.applyError").exists, "nothing may have been attempted yet")
        snap("assistant-tag-confirm-dialog")
        element("assistant.cancelTagsButton").click()

        XCTAssertTrue(
            element("assistant.proposalList").waitForExistence(timeout: 15),
            "cancelling must leave the preview open"
        )
        XCTAssertFalse(
            element("assistant.applyError").exists,
            "cancelling must not attempt a write, so no failure may be reported"
        )
        // RE-QUERY: pressing Apply again re-raises the gate. It can only do that while
        // the proposal is still in the store — an applied one would throw
        // `unknownProposal` into the error banner instead.
        element("assistant.applyButton").click()
        XCTAssertTrue(
            element("assistant.confirmTagsButton").waitForExistence(timeout: 15),
            "the cancelled proposal must still be listed and still gated"
        )
        XCTAssertFalse(element("assistant.applyError").exists, "and must not have been consumed")
        element("assistant.cancelTagsButton").click()
    }

    /// A repository failure mid-apply is reported in the listener's language and costs
    /// them nothing: `AssistantViewModel.apply` removes a proposal only after the routed
    /// write returns, so the sheet stays open with the same proposal on it.
    func testApplyFailureShowsALocalizedErrorAndKeepsTheProposalListed() {
        app.launchEnvironment["UITEST_ASSISTANT_PROPOSAL"] = "failingRename"
        app.launch()
        openAssistantPane()
        submitRequest("rename that playlist")

        XCTAssertTrue(
            element("assistant.proposalList").waitForExistence(timeout: 30),
            "the staged rename should open the preview sheet"
        )
        XCTAssertTrue(
            app.staticTexts["Renamed By Assistant"].waitForExistence(timeout: 15),
            "the rename preview should show the proposed name verbatim"
        )
        element("assistant.applyButton").click()

        let banner = element("assistant.applyError")
        XCTAssertTrue(
            banner.waitForExistence(timeout: 20),
            "a repository failure must surface an error rather than fail silently"
        )
        // "exist any more" is UNIQUE to `failurePlaylistNotFound` among the failure copy;
        // the obvious "nothing was changed" also appears in `failureUnexpected`, so it
        // would pass even if the `as? AssistantProposalError` cast had fallen through to
        // the generic message. This phrase proves the cast landed on the right case.
        XCTAssertTrue(
            banner.carriesCopy(containing: "exist any more"),
            """
            the error must be the localized playlistNotFound copy, not the generic \
            fallback and not a raw Swift error description; banner said: \
            \(banner.exists ? banner.copyDump() : "<no banner>")
            """
        )
        XCTAssertTrue(
            element("assistant.proposalList").exists,
            "the proposal must remain listed after a failed apply"
        )
        XCTAssertTrue(
            element("assistant.applyButton").isEnabled,
            "and must stay applicable so the listener can retry"
        )
        snap("assistant-apply-failure")
    }
}

// MARK: - Harness

/// Internal, not `private`: `AssistantContextualActionsTests.swift` extends this same
/// suite from a sibling file (this one sits at the SwiftLint `file_length` ceiling)
/// and needs `element`, `snap` and the XML-plist boolean. Every method below is
/// otherwise unchanged.
extension AssistantFlowTests {
    func suiteName(_ identifier: String) -> String {
        "com.example.macamp.uitest.\(identifier)"
    }

    func launchWithIntelligenceOff() {
        app.launchArguments += ["-\(Self.intelligenceKey)", Self.xmlPlistBool(false)]
        app.launch()
    }

    /// Stages the selection through the app's own launch-environment seam. An earlier
    /// draft wrote it into the run's `UserDefaults` suite from here; that is measurably
    /// the wrong mechanism — see `SidebarSelectionStore.seedFromLaunchEnvironmentIfNeeded`.
    func stagePersistedAssistantSelection() {
        app.launchEnvironment["UITEST_SIDEBAR_SELECTION"] = Self.assistantPayload
    }

    /// Drops the staging seam so the NEXT launch reads whatever the app itself
    /// persisted. The seed is skip-if-present, so this is belt and braces — but it
    /// makes the relaunch assertion depend on the app's write and nothing else.
    func stopStagingPersistedSelection() {
        app.launchEnvironment.removeValue(forKey: "UITEST_SIDEBAR_SELECTION")
    }

    /// A boolean the NSArgumentDomain preserves as a boolean. See the type note in
    /// the suite's doc comment — a bare `NO` becomes a `String` and reads as `nil`.
    static func xmlPlistBool(_ value: Bool) -> String {
        let literal = value ? "true" : "false"
        return """
        <?xml version="1.0" encoding="UTF-8"?>\
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\
        <plist version="1.0"><\(literal)/></plist>
        """
    }

    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
