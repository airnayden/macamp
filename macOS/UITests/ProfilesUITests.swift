import XCTest

/// End-to-end XCUITest smoke for the macOS user-profiles feature (plan todo 19).
///
/// Drives the full six-step flow against a hermetic, launch-environment-seeded app
/// (temp database + throwaway `UserDefaults` suite via
/// `AppEnvironment.liveForUITesting()`), so it never touches the user's real
/// library or defaults. Every wait is a `waitForExistence` /
/// `XCTNSPredicateExpectation` expectation — there are no wall-clock sleeps.
final class ProfilesUITests: XCTestCase {
    private var app: XCUIApplication!
    private var seedPath: String!
    private var runID: String!
    private var exportPath: String!

    private let fixtureTrack = "Aurora Anthem"

    override func setUpWithError() throws {
        continueAfterFailure = false
        let identifier = UUID().uuidString
        runID = identifier
        seedPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("macamp-uitest-\(identifier)")
        exportPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("macamp-uitest-export-\(identifier)")

        app = XCUIApplication()
        app.launchEnvironment["UITEST_SEED_PATH"] = seedPath
        app.launchEnvironment["UITEST_RUN_ID"] = identifier
        app.launchEnvironment["UITEST_ARCHIVE_EXPORT_DIR"] = exportPath
        // Force the feature flag off at launch regardless of any persisted value.
        // NSArgumentDomain is volatile — it shadows the read without writing disk.
        app.launchArguments += ["-com.example.macamp.settings.profilesEnabled", "NO"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
        if let seedPath { try? FileManager.default.removeItem(atPath: seedPath) }
        if let exportPath { try? FileManager.default.removeItem(atPath: exportPath) }
        if let runID { UserDefaults().removePersistentDomain(forName: "com.example.macamp.uitest.\(runID)") }
    }

    func testProfilesEndToEndSmoke() {
        XCTAssertTrue(playerBar.waitForExistence(timeout: 30), "main window should finish loading")
        stepEnableProfiles()
        stepCreateAlex()
        stepSwitchToAlexWithPIN()
        stepFavouriteTrackAsAlex()
        stepSwitchToGuestAndVerifyIsolation()
        stepDisableProfiles()
    }

    func testProfileArchiveEntryExistsAndWritesAFile() {
        XCTAssertTrue(playerBar.waitForExistence(timeout: 30), "main window should finish loading")
        openSettings()
        selectProfilesTab()

        let exportButton = element("preferences.profiles.exportButton")
        XCTAssertTrue(exportButton.waitForExistence(timeout: 15), "export entry should exist in the Profiles pane")
        let importButton = element("preferences.profiles.importButton")
        XCTAssertTrue(importButton.waitForExistence(timeout: 5), "import entry should exist in the Profiles pane")

        exportButton.click()
        XCTAssertTrue(waitForExportedArchive(), "exporting should write a .macampprofile file")
    }

    /// Polls the scripted export directory rather than driving the modal
    /// `NSSavePanel`, which XCUITest cannot reach.
    private func waitForExportedArchive(timeout: TimeInterval = 30) -> Bool {
        let directory = exportPath ?? ""
        let predicate = NSPredicate { _, _ in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
            return names.contains { $0.hasSuffix(".macampprofile") }
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}

// MARK: - Steps

private extension ProfilesUITests {
    func stepEnableProfiles() {
        XCTAssertFalse(profileButton.exists, "avatar button must be absent while profiles are disabled")
        openSettings()
        selectProfilesTab()
        let toggle = element("preferences.profiles.toggle")
        XCTAssertTrue(toggle.waitForExistence(timeout: 15), "profiles toggle should be reachable")
        toggle.click()
        closeSettingsWindow()
        XCTAssertTrue(
            profileButton.waitForExistence(timeout: 15),
            "avatar button must appear once profiles are enabled"
        )
    }

    func stepCreateAlex() {
        ensureOverlayOpen()
        let createTile = app.buttons["profiles.createTile"]
        XCTAssertTrue(createTile.waitForExistence(timeout: 15), "create tile should be present")
        createTile.click()

        let nameField = app.textFields["profiles.editor.nameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 15), "editor name field should appear")
        nameField.click()
        nameField.typeText("Alex")

        let avatarTile = app.buttons["profiles.editor.avatarTile.bolt-sunset"]
        XCTAssertTrue(avatarTile.waitForExistence(timeout: 5), "avatar preset tile should be present")
        avatarTile.click()

        let editorPIN = app.secureTextFields["profiles.editor.pinField"]
        XCTAssertTrue(editorPIN.waitForExistence(timeout: 5), "editor PIN field should be present")
        editorPIN.click()
        editorPIN.typeText("1234")

        app.buttons["profiles.editor.saveButton"].click()
    }

    func stepSwitchToAlexWithPIN() {
        let alexTile = app.buttons.matching(NSPredicate(format: "label == %@", "Alex")).firstMatch
        XCTAssertTrue(alexTile.waitForExistence(timeout: 15), "Alex's tile should appear after creation")
        alexTile.click()

        let pinField = app.secureTextFields["profiles.pinField"]
        XCTAssertTrue(pinField.waitForExistence(timeout: 15), "PIN prompt should appear for a locked profile")
        let unlock = app.buttons["Unlock"]

        // Wrong PIN first: the error must surface and the switch must not happen.
        typeIntoPINPrompt(pinField, "9999")
        XCTAssertTrue(unlock.waitForExistence(timeout: 5))
        XCTAssertTrue(wait(unlock, "isEnabled == true"), "Unlock should enable once four digits are entered")
        unlock.click()
        XCTAssertTrue(
            app.staticTexts["Incorrect PIN. Try again."].waitForExistence(timeout: 15),
            "a wrong PIN must surface the error message"
        )
        // The prompt clears the field after a failed attempt; observing Unlock
        // becoming disabled is the deterministic signal that the clear completed.
        XCTAssertTrue(wait(unlock, "isEnabled == false"), "the field should clear after a wrong PIN")

        // Correct PIN: the overlay dismisses and Alex becomes active.
        typeIntoPINPrompt(pinField, "1234")
        XCTAssertTrue(wait(unlock, "isEnabled == true"))
        unlock.click()
        XCTAssertTrue(wait(overlay, "exists == false", timeout: 15), "overlay should dismiss after the correct PIN")
        XCTAssertTrue(profileButton.waitForExistence(timeout: 10))
        XCTAssertTrue(wait(profileButton, "label CONTAINS 'Alex'", timeout: 10), "avatar button should reflect Alex")
    }

    func stepFavouriteTrackAsAlex() {
        selectSidebarRow("allTracks")
        XCTAssertTrue(
            app.staticTexts[fixtureTrack].waitForExistence(timeout: 15),
            "the seeded track should be listed in All Tracks"
        )
        let heart = app.buttons["Add to Favourites"].firstMatch
        XCTAssertTrue(heart.waitForExistence(timeout: 10), "the favourite toggle should be present on a track row")
        heart.click()
        assertFavouriteVisible(fixtureTrack)
    }

    func stepSwitchToGuestAndVerifyIsolation() {
        profileButton.click()
        let guestTile = app.buttons["profiles.tile.1"]
        XCTAssertTrue(guestTile.waitForExistence(timeout: 15), "Guest's tile should be present")
        guestTile.click()
        XCTAssertTrue(wait(overlay, "exists == false", timeout: 15), "overlay should dismiss after switching to Guest")

        selectSidebarRow("favourites")
        XCTAssertTrue(
            app.staticTexts["No Favourites"].waitForExistence(timeout: 15),
            "Guest's favourites should be empty"
        )
        XCTAssertFalse(
            app.staticTexts[fixtureTrack].exists,
            "a track favourited by Alex must not appear for Guest"
        )
    }

    func stepDisableProfiles() {
        openSettings()
        selectProfilesTab()
        let toggle = element("preferences.profiles.toggle")
        XCTAssertTrue(toggle.waitForExistence(timeout: 15))
        toggle.click()
        closeSettingsWindow()
        XCTAssertTrue(
            wait(profileButton, "exists == false", timeout: 15),
            "avatar button must disappear when profiles are disabled"
        )
    }
}

// MARK: - Helpers

private extension ProfilesUITests {
    var playerBar: XCUIElement {
        element("player.bar")
    }

    var profileButton: XCUIElement {
        element("player.profileButton")
    }

    var overlay: XCUIElement {
        element("profiles.overlay")
    }

    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func openSettings() {
        app.typeKey(",", modifierFlags: .command)
    }

    func selectProfilesTab() {
        app.selectSettingsSection("profiles")
    }

    /// Closes the Settings window without any focus/title assumptions: locate the
    /// window that hosts the profiles toggle and click its standard close button.
    func closeSettingsWindow() {
        for window in app.windows.allElementsBoundByIndex {
            let toggle = window.descendants(matching: .any)
                .matching(identifier: "preferences.profiles.toggle").firstMatch
            if toggle.exists {
                window.buttons[XCUIIdentifierCloseWindow].firstMatch.click()
                return
            }
        }
    }

    func ensureOverlayOpen() {
        if overlay.waitForExistence(timeout: 5) { return }
        profileButton.click()
        XCTAssertTrue(overlay.waitForExistence(timeout: 10), "overlay should open from the avatar button")
    }

    func selectSidebarRow(_ rawValue: String) {
        let row = element("sidebar.row.\(rawValue)")
        XCTAssertTrue(row.waitForExistence(timeout: 15), "sidebar row \(rawValue) should exist")
        row.click()
    }

    /// Types a PIN into the overlay's near-invisible secure field. The field
    /// auto-focuses on appear, so typing at the app level lands in it; a click
    /// first re-asserts focus when the element is hittable.
    func typeIntoPINPrompt(_ field: XCUIElement, _ digits: String) {
        if field.isHittable { field.click() }
        app.typeText(digits)
    }

    /// Re-enters Favourites a few times so the asynchronous favourite write is
    /// observed — each re-entry recreates the view and re-reads the database.
    func assertFavouriteVisible(_ title: String) {
        for _ in 0 ..< 5 {
            selectSidebarRow("favourites")
            if app.staticTexts[title].waitForExistence(timeout: 3) { return }
            selectSidebarRow("allTracks")
        }
        XCTFail("favourited track \(title) never appeared in Favourites")
    }

    func wait(_ element: XCUIElement, _ predicateFormat: String, timeout: TimeInterval = 10) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: predicateFormat),
            object: element
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
