import XCTest

// MARK: - Reorder by Energy, and the Re-analyze affordance

/// The two reported defects, driven through the real app.
///
/// `UITEST_SEED_AUDIO_FEATURES` widens the contextual fixture with a current
/// `trackAudioFeature` row per PRESENT track (`AudioFeatureFixture`), because
/// without analysis rows "Reorder by Energy" is correctly disabled and correctly
/// proposes nothing — so every assertion about the bug would pass for the wrong
/// reason. `=1` seeds energies the arc really reorders; `=arced` seeds energies the
/// arc reproduces, which is the only way to reach the "already in energy order"
/// outcome from a UI test.
///
/// Menu items are queried by LABEL, not by identifier: SwiftUI lowers a
/// `.contextMenu` into an `NSMenu` and accessibility identifiers do not survive that
/// lowering. `AssistantContextualActionsTests` scopes its equivalents `fileprivate`,
/// so this file carries its own rather than widening another suite's surface.
extension AssistantFlowTests {
    /// SYMPTOM A. The menu is opened on a fully analysed library WITHOUT ever
    /// visiting Preferences ▸ Intelligence, which is the whole point: the coverage
    /// the gate reads must be true at launch, not only after the pane's `.task` has
    /// filled it in.
    func testReorderByEnergyIsEnabledOnAnAnalyzedLibraryWithoutVisitingThePane() {
        launchWithAnalyzedFixture()
        rightClickPlaylistRow()

        let organize = menuLabelled("Organize…")
        XCTAssertTrue(organize.waitForExistence(timeout: 15), "the playlist's own menu should offer Organize…")
        organize.click()

        let reorder = menuLabelled("Reorder by Energy")
        XCTAssertTrue(reorder.waitForExistence(timeout: 15), "the submenu should offer the energy reorder")
        XCTAssertTrue(
            reorder.isEnabled,
            "a fully analyzed library must enable Reorder by Energy at launch, with no visit to the Intelligence pane"
        )
        snap("energy-reorder-enabled")
    }

    /// SYMPTOM A + B together: the enabled item actually produces a reviewable
    /// proposal, which is the outcome the listener says never happens.
    func testReorderByEnergyOpensAProposalOnAnAnalyzedLibrary() {
        launchWithAnalyzedFixture()
        rightClickPlaylistRow()
        menuLabelled("Organize…").click()

        let reorder = menuLabelled("Reorder by Energy")
        XCTAssertTrue(reorder.waitForExistence(timeout: 15), "the submenu should offer the energy reorder")
        reorder.click()

        XCTAssertTrue(
            element("assistant.proposalList").waitForExistence(timeout: 30),
            "an analyzed playlist must open the same preview sheet every other proposal uses"
        )
        XCTAssertTrue(element("assistant.discardButton").exists, "reviewable, and discardable, before anything changes")
        snap("energy-reorder-proposal")
    }

    /// SYMPTOM B, the reporting half. With the arc already satisfied there is
    /// genuinely nothing to propose — and the toast must SAY that, instead of the
    /// old catch-all "Nothing to suggest here yet" that also stood for "too long",
    /// "too short" and "not analyzed enough".
    func testReorderByEnergyReportsAnAlreadyOrderedPlaylistDistinctly() {
        launchWithAnalyzedFixture(shape: "arced")
        rightClickPlaylistRow()
        menuLabelled("Organize…").click()

        let reorder = menuLabelled("Reorder by Energy")
        XCTAssertTrue(reorder.waitForExistence(timeout: 15), "the submenu should offer the energy reorder")
        XCTAssertTrue(reorder.isEnabled, "coverage is full, so the item is offered")
        reorder.click()

        XCTAssertTrue(
            app.staticTexts["This playlist is already in energy order"].waitForExistence(timeout: 30),
            "the outcome must name itself rather than fall back to the catch-all"
        )
        XCTAssertFalse(
            app.staticTexts["Nothing to suggest here yet"].exists,
            "and must not ALSO show the vague sentence it replaced"
        )
        snap("energy-reorder-already-ordered")
    }

    /// The honest negative: with nothing analyzed the item really is unavailable,
    /// so the permissive "unknown coverage" branch cannot be hiding a broken gate.
    /// This is the positive control for the two cases above.
    func testReorderByEnergyStaysDisabledOnAnUnanalyzedLibrary() {
        launchWithUnanalyzedFixture()
        rightClickPlaylistRow()
        menuLabelled("Organize…").click()

        let reorder = menuLabelled("Reorder by Energy")
        XCTAssertTrue(reorder.waitForExistence(timeout: 15), "the item stays visible so the listener can see why")
        XCTAssertFalse(reorder.isEnabled, "but an unanalyzed library cannot support an energy arc")
        snap("energy-reorder-disabled-unanalyzed")
    }
}

// MARK: - Re-analyze Library

extension AssistantFlowTests {
    /// The new affordance exists, and asks before it destroys anything.
    func testReanalyzeAsksForConfirmationAndCancelChangesNothing() {
        launchWithAnalyzedFixture()
        openIntelligencePane()

        let rescan = element("intelligence.analysisRescan")
        XCTAssertTrue(rescan.waitForExistence(timeout: 30), "the Audio Analysis section should offer a re-analysis")
        let coverageBefore = element("intelligence.analysisCoverage").value as? String
        rescan.click()

        let cancel = element("intelligence.analysisRescanCancel")
        XCTAssertTrue(cancel.waitForExistence(timeout: 15), "a destructive full pass must be confirmed first")
        XCTAssertTrue(
            element("intelligence.analysisRescanConfirm").exists,
            "with an explicit destructive confirm beside the cancel"
        )
        // `label OR value`: a SwiftUI `Text` publishes its string as the accessibility
        // VALUE on macOS and leaves `label` empty, so a label-only predicate can never
        // match app copy. See the wave-A note in the project notepad.
        XCTAssertTrue(
            app.descendants(matching: .any).matching(
                NSPredicate(
                    format: "label CONTAINS %@ OR value CONTAINS %@",
                    "decodes every audio file",
                    "decodes every audio file"
                )
            ).firstMatch.waitForExistence(timeout: 10),
            "and the confirmation must say plainly what it costs"
        )
        snap("analysis-rescan-confirm")
        cancel.click()

        XCTAssertEqual(
            element("intelligence.analysisCoverage").value as? String,
            coverageBefore,
            "cancelling must leave every cached measurement in place"
        )
        snap("analysis-rescan-cancelled")
    }
}

// MARK: - Harness

private extension AssistantFlowTests {
    /// The contextual fixture plus a current analysis row for every present track.
    func launchWithAnalyzedFixture(shape: String = "1") {
        app.launchEnvironment["UITEST_SEED_AI_CONTEXT"] = "1"
        app.launchEnvironment["UITEST_SEED_AUDIO_FEATURES"] = shape
        app.launch()
    }

    /// The contextual fixture with NO analysis rows — the positive control.
    func launchWithUnanalyzedFixture() {
        app.launchEnvironment["UITEST_SEED_AI_CONTEXT"] = "1"
        app.launch()
    }

    /// Right-clicks the playlist in the SIDEBAR, without opening it: once the detail
    /// view is showing, its back bar and the window toolbar render the same name and
    /// `staticTexts` stops being unambiguous.
    func rightClickPlaylistRow(_ name: String = "Fixture Mix") {
        let row = app.staticTexts[name]
        XCTAssertTrue(row.waitForExistence(timeout: 30), "the fixture playlist should be listed in the sidebar")
        row.rightClick()
    }

    func menuLabelled(_ label: String) -> XCUIElement {
        app.menuItems[label].firstMatch
    }

    /// Mirrors `IntelligencePaneUITests.openIntelligenceTab()`: the tab is reached by
    /// TITLE across both element types SwiftUI may vend for it, because the pane's
    /// identifier does not survive `TabView`'s AppKit lowering on every OS.
    func openIntelligencePane() {
        XCTAssertTrue(
            element("sidebar.row.allTracks").waitForExistence(timeout: 30),
            "the window should finish launching"
        )
        app.typeKey(",", modifierFlags: .command)
        app.selectSettingsSection("intelligence")
    }
}
