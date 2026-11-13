import XCTest

// MARK: - Contextual actions (plan todo 24)

/// The three AI actions wired into EXISTING menus: "More Like This" on a track,
/// "Organize…" on a playlist, "Surprise Me" in the library toolbar. Every one of them
/// produces a PROPOSAL — the assertions below all end at the same
/// `assistant.proposalList` sheet todo 23 built, never at a changed library.
///
/// `UITEST_SEED_AI_CONTEXT=1` widens the fixture (`AIContextualFixture`): the base
/// fixture's tracks carry no `artistId`, and `SimilarityService` narrows its
/// cold-start pool by that FOREIGN KEY, so without it "More Like This" would
/// correctly find no neighbours and the happy path would fail for a reason that has
/// nothing to do with the menu.
///
/// Menu items are queried by LABEL, not by identifier: SwiftUI lowers a
/// `.contextMenu` into an `NSMenu`, and accessibility identifiers set on its buttons
/// do not survive that lowering — the label does.
///
/// TWO LABELS MOVED, FOR TWO REPORTED BUGS:
///
///   * "More Like This" now NAMES its seed (`More Like “Aurora Anthem”`) because a
///     multi-row selection silently seeds from the first row only.
///   * "Organize…" moved OFF the per-song menu inside a playlist and onto the
///     playlist itself — the sidebar row and the detail toolbar — because all four of
///     its actions rewrite the whole playlist and none of them read the clicked song.
extension AssistantFlowTests {
    /// The plan's happy path: right-click → "More Like …" → a NAMED proposal in
    /// the same preview sheet, with nothing written until Apply.
    func testMoreLikeThisRightClickOpensANamedProposal() {
        launchWithContextualFixture()
        rightClickTrack("Aurora Anthem")

        let action = menuItem(Self.moreLikeAuroraLabel)
        XCTAssertTrue(action.waitForExistence(timeout: 15), "the track menu should name the seed it would use")
        XCTAssertTrue(action.isEnabled, "a present fixture track can seed a mix")
        snap("contextual-more-like-this-menu")
        action.click()

        XCTAssertTrue(
            element("assistant.proposalList").waitForExistence(timeout: 30),
            "a contextual proposal must open the same preview sheet a typed request does"
        )
        XCTAssertTrue(
            app.staticTexts["More Like Aurora Anthem"].waitForExistence(timeout: 15),
            "the proposal must carry a generated, non-empty name"
        )
        XCTAssertTrue(element("assistant.applyButton").exists, "and be applicable from the sheet")
        snap("contextual-more-like-this-proposal")
    }

    /// The plan's failure path. A track whose file is gone still SHOWS the item — so
    /// the listener can see why — but cannot be clicked, and no proposal is produced.
    func testMoreLikeThisIsDisabledForAMissingTrack() {
        launchWithContextualFixture()
        rightClickTrack("Vanished Echo")

        let action = menuItem("More Like “Vanished Echo”")
        XCTAssertTrue(action.waitForExistence(timeout: 15), "the item stays visible for a missing track")
        XCTAssertFalse(action.isEnabled, "but a missing file cannot seed a mix")
        XCTAssertFalse(element("assistant.proposalList").exists, "and no proposal may have been produced")
        snap("contextual-more-like-this-missing")
    }

    /// Bundle OFF ⇒ the item is ABSENT, not disabled.
    func testMoreLikeThisIsAbsentWhenNaturalLanguageCreationIsOff() {
        launchWithContextualFixture(disabling: Self.nlCreationKey)
        rightClickTrack("Aurora Anthem")

        XCTAssertTrue(menuItem("Play").waitForExistence(timeout: 15), "the ordinary track menu still opens")
        XCTAssertFalse(
            menuItem(Self.moreLikeAuroraLabel).exists,
            "the AI item must not exist while its bundle is off"
        )
        snap("contextual-more-like-this-absent")
    }

    /// The playlist path: right-click the PLAYLIST in the sidebar → "Organize…" →
    /// "Remove Duplicates" → the preview sheet, describing the membership rewrite it
    /// would make.
    ///
    /// Driven from the sidebar rather than from a song row on purpose: the sidebar row
    /// IS the playlist, and it is the surface that proves the relocation. It also
    /// proves the repository drain (`PlaylistOrganizeTrackSource.repositoryPages`),
    /// because the detail view is never opened here and the shared `PlaylistViewModel`
    /// therefore holds no membership to read.
    ///
    /// The fixture playlist holds the same recording twice under two library rows
    /// ("Aurora Anthem" and "AURORA ANTHEM"), which is the shape `PlaylistOrganizeDiff`
    /// can describe as a real removal — see `proposeMembershipCleanup`.
    func testOrganizeRemoveDuplicatesOpensTheProposalSheet() {
        launchWithContextualFixture()
        rightClickSidebarPlaylist()

        let organize = menuItem("Organize…")
        XCTAssertTrue(organize.waitForExistence(timeout: 15), "the playlist's own menu should offer Organize…")
        organize.click()
        let deduplicate = menuItem("Remove Duplicates")
        XCTAssertTrue(deduplicate.waitForExistence(timeout: 15), "the submenu should offer every organisation action")
        XCTAssertTrue(menuItem("Split by Theme").exists, "including a theme split")
        XCTAssertTrue(menuItem("Reorder by Energy").exists, "an energy reorder")
        XCTAssertTrue(menuItem("Suggest a Name").exists, "and a name suggestion")
        snap("contextual-organize-menu")
        deduplicate.click()

        XCTAssertTrue(
            element("assistant.proposalList").waitForExistence(timeout: 30),
            "the duplicate the fixture playlist lists twice should open a proposal"
        )
        XCTAssertTrue(
            app.staticTexts["AURORA ANTHEM"].waitForExistence(timeout: 15),
            "the preview should name the redundant entry it would drop"
        )
        XCTAssertTrue(element("assistant.discardButton").exists, "reviewable, and discardable, before anything changes")
        snap("contextual-organize-proposal")
    }

    /// Organisation bundle OFF ⇒ the whole submenu is ABSENT.
    func testOrganizeIsAbsentWhenOrganizationIsOff() {
        launchWithContextualFixture(disabling: Self.organizationKey)
        rightClickSidebarPlaylist()

        XCTAssertTrue(
            menuItem("Rename…").waitForExistence(timeout: 15),
            "the ordinary playlist menu still opens"
        )
        XCTAssertFalse(menuItem("Organize…").exists, "the Organize submenu must not exist while its bundle is off")
        snap("contextual-organize-absent")
    }

    /// The reported bug, pinned: the four whole-playlist actions must NOT appear on a
    /// song's own context menu inside a playlist.
    ///
    /// The positive control is `testOrganizeRemoveDuplicatesOpensTheProposalSheet`,
    /// which proves the same submenu IS reachable with the same bundle on — so a green
    /// absence here cannot be a mis-typed label or a feature switched off.
    func testOrganizeIsAbsentFromASongsOwnMenu() {
        launchWithContextualFixture()
        openFixturePlaylist()
        rightClickTrack("Zephyr Waltz")

        XCTAssertTrue(menuItem("Play").waitForExistence(timeout: 15), "the ordinary track menu still opens")
        XCTAssertFalse(
            menuItem("Organize…").exists,
            "playlist-wide actions must not be offered from a single song's menu"
        )
        XCTAssertFalse(menuItem("Remove Duplicates").exists, "nor any of the four actions directly")
        snap("contextual-organize-not-on-song-row")
    }

    /// The POSITIVE CONTROL for the absence below: without it a passing "the button
    /// is gone" would equally describe a mis-typed identifier.
    ///
    /// Deliberately a separate method rather than a terminate-and-relaunch inside the
    /// negative one — `setUpWithError` mints a fresh seed path and defaults suite per
    /// TEST, so two methods are two genuinely independent launches, while a second
    /// launch in one method reuses the first's database and preferences.
    func testSurpriseMeIsOfferedByDefault() {
        launchWithContextualFixture()
        XCTAssertTrue(
            element("library.action.surpriseMe").waitForExistence(timeout: 30),
            "the library toolbar should offer Surprise Me by default"
        )
        snap("contextual-surprise-me")
    }

    /// Rediscovery bundle OFF ⇒ the toolbar button is ABSENT.
    func testSurpriseMeIsAbsentWhenRediscoveryIsOff() {
        launchWithContextualFixture(disabling: Self.rediscoveryKey)
        XCTAssertTrue(
            element("sidebar.row.allTracks").waitForExistence(timeout: 30),
            "the window should finish launching"
        )
        XCTAssertFalse(
            element("library.action.surpriseMe").exists,
            "the toolbar button must not exist while the rediscovery bundle is off"
        )
        snap("contextual-surprise-me-absent")
    }
}

// MARK: - Contextual harness

private extension AssistantFlowTests {
    static let nlCreationKey = "com.example.macamp.settings.ai.nlCreationEnabled"
    static let organizationKey = "com.example.macamp.settings.ai.organizationEnabled"
    static let rediscoveryKey = "com.example.macamp.settings.ai.rediscoveryEnabled"

    /// Launches with the widened fixture, optionally with one bundle switched off
    /// through the NSArgumentDomain as a full XML plist — see the suite's doc
    /// comment for why a bare `NO` would be silently inert.
    func launchWithContextualFixture(disabling key: String? = nil) {
        app.launchEnvironment[Self.contextualFixtureKey] = "1"
        if let key {
            app.launchArguments += ["-\(key)", Self.xmlPlistBool(false)]
        }
        app.launch()
    }

    static var contextualFixtureKey: String {
        "UITEST_SEED_AI_CONTEXT"
    }

    /// The seed-naming label the widened fixture produces for its first track.
    static var moreLikeAuroraLabel: String {
        "More Like “Aurora Anthem”"
    }

    /// Right-clicks the playlist in the SIDEBAR, without opening it.
    ///
    /// Deliberately before any navigation: once the detail view is showing, its back
    /// bar and the window toolbar both render the same name, and `staticTexts` would
    /// stop being unambiguous.
    func rightClickSidebarPlaylist(_ name: String = "Fixture Mix") {
        let row = app.staticTexts[name]
        XCTAssertTrue(row.waitForExistence(timeout: 30), "the fixture playlist should be listed in the sidebar")
        row.rightClick()
    }

    func openFixturePlaylist() {
        let row = app.staticTexts["Fixture Mix"]
        XCTAssertTrue(row.waitForExistence(timeout: 30), "the fixture playlist should be listed in the sidebar")
        row.click()
        XCTAssertTrue(
            app.staticTexts["Zephyr Waltz"].waitForExistence(timeout: 15),
            "selecting it should show the playlist's tracks"
        )
    }

    func rightClickTrack(_ title: String) {
        let row = app.staticTexts[title]
        XCTAssertTrue(row.waitForExistence(timeout: 30), "the fixture track \"\(title)\" should be listed")
        row.rightClick()
    }

    func menuItem(_ label: String) -> XCUIElement {
        app.menuItems[label].firstMatch
    }
}
