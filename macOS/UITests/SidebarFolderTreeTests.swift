import XCTest

final class SidebarFolderTreeTests: XCTestCase {
    private var app: XCUIApplication!
    private var seedPath: String!
    private var runID: String!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let identifier = UUID().uuidString
        runID = identifier
        seedPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("macamp-foldertree-uitest-\(identifier)")
        app = XCUIApplication()
        app.launchEnvironment["UITEST_SEED_PATH"] = seedPath
        app.launchEnvironment["UITEST_RUN_ID"] = identifier
        app.launchEnvironment["UITEST_SEED_FOLDER_TREE"] = "1"
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

    func testExpandingARootRevealsItsSubfolderAndSelectingItRetitlesTheContentPane() {
        app.launch()
        let root = folderRow(named: "Fixture Library")
        XCTAssertTrue(root.waitForExistence(timeout: 30), "the seeded library root should appear in the sidebar")

        let subfolder = folderRow(named: "Live Sets")
        XCTAssertTrue(subfolder.waitForNonExistence(timeout: 5), "a collapsed root should hide its subfolders")

        expand(root)
        XCTAssertTrue(subfolder.waitForExistence(timeout: 15), "expanding the root should load its child level")

        subfolder.click()
        XCTAssertTrue(
            app.staticTexts["Live Sets"].waitForExistence(timeout: 15),
            "selecting a subfolder should retitle the content pane to that folder"
        )
    }

    func testFolderFilterNarrowsTheTreeAndClearingItRestoresTheTree() {
        app.launch()
        let root = folderRow(named: "Fixture Library")
        XCTAssertTrue(root.waitForExistence(timeout: 30), "the seeded library root should appear in the sidebar")
        expand(root)
        XCTAssertTrue(folderRow(named: "Live Sets").waitForExistence(timeout: 15), "the child level should load")

        let field = app.descendants(matching: .any).matching(identifier: "sidebar.folderFilter").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15), "the Folders section should carry a filter field")
        field.click()
        field.typeText("Rarities")

        XCTAssertTrue(
            folderRow(named: "Rarities").waitForExistence(timeout: 15),
            "a matching subfolder should stay visible under its ancestor"
        )
        XCTAssertTrue(
            folderRow(named: "Live Sets").waitForNonExistence(timeout: 15),
            "a non-matching sibling should disappear while the filter is active"
        )
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "sidebar.row.allTracks").firstMatch.exists,
            "the folder filter must not filter any other sidebar section"
        )

        for _ in 0 ..< "Rarities".count {
            field.typeKey(.delete, modifierFlags: [])
        }
        XCTAssertTrue(
            folderRow(named: "Live Sets").waitForExistence(timeout: 15),
            "clearing the filter should restore the full tree"
        )
    }

    func testRemovingSelectedFolderFromSettingsRefreshesTheSidebar() {
        app.launch()
        let root = folderRow(named: "Fixture Singles")
        XCTAssertTrue(root.waitForExistence(timeout: 30))
        root.click()

        app.typeKey(",", modifierFlags: .command)
        app.selectSettingsSection("library")
        let settings = app.windows.containing(.any, identifier: "preferences.sidebar").firstMatch
        let remove = settings.buttons.matching(identifier: "Remove Folder")
            .allElementsBoundByIndex.first { button in
                settings.staticTexts["Fixture Singles"].frame.insetBy(dx: -500, dy: -14).intersects(button.frame)
            }
        XCTAssertNotNil(remove)
        remove?.click()
        XCTAssertTrue(settings.staticTexts["Fixture Singles"].waitForNonExistence(timeout: 10))
        settings.buttons[XCUIIdentifierCloseWindow].click()

        XCTAssertTrue(root.waitForNonExistence(timeout: 15))
        XCTAssertTrue(folderRow(named: "Fixture Library").exists)
        XCTAssertTrue(app.staticTexts["All Tracks"].firstMatch.waitForExistence(timeout: 10))
        let capture = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        capture.name = "Sidebar after removing a folder"
        capture.lifetime = .keepAlways
        add(capture)
    }

    // MARK: - Helpers

    /// Folder rows are identified by their STABLE path hash, which a test cannot
    /// compute, so they are located by their visible name inside the sidebar list.
    private func folderRow(named name: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "sidebar.list").firstMatch
            .staticTexts[name]
    }

    /// Clicks the row's own disclosure triangle, falling back to the row: which of the
    /// two a `.sidebar` list exposes as hit-testable is a styling detail.
    private func expand(_ row: XCUIElement) {
        row.hover()
        let band = row.frame.insetBy(dx: -240, dy: -2)
        let chevron = app.descendants(matching: .disclosureTriangle).allElementsBoundByIndex
            .first { band.intersects($0.frame) }
        (chevron ?? row).click()
    }
}
