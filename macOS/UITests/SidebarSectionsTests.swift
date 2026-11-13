import XCTest

final class SidebarSectionsTests: XCTestCase {
    private var app: XCUIApplication!
    private var seedPath: String!
    private var runID: String!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let identifier = UUID().uuidString
        runID = identifier
        seedPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("macamp-sidebar-uitest-\(identifier)")
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

    func testLibrarySectionCollapseSurvivesRelaunch() {
        app.launch()
        XCTAssertTrue(row("allTracks").waitForExistence(timeout: 30), "the Library section should start expanded")

        toggleSection("library")
        XCTAssertTrue(row("allTracks").waitForNonExistence(timeout: 15), "collapsing Library should hide its rows")

        app.terminate()
        app.launch()

        XCTAssertTrue(header("library").waitForExistence(timeout: 30), "the relaunched sidebar should render")
        XCTAssertTrue(row("allTracks").waitForNonExistence(timeout: 10), "the collapsed state should be restored")

        toggleSection("library")
        XCTAssertTrue(row("allTracks").waitForExistence(timeout: 15), "re-expanding should bring the rows back")
    }

    func testPlaylistsDestinationIsSelectableInsideItsSection() {
        app.launch()
        let playlists = row("playlists")
        XCTAssertTrue(
            playlists.waitForExistence(timeout: 30),
            "the Playlists row should sit inside its expanded section"
        )
        playlists.click()
        let pane = app.descendants(matching: .any).matching(identifier: "playlists.view").firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 15), "selecting the Playlists row should open the playlists pane")
    }

    // MARK: - Helpers

    private func row(_ section: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "sidebar.row.\(section)").firstMatch
    }

    private func header(_ section: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "sidebar.section.\(section)").firstMatch
    }

    /// Prefers the section's own disclosure control and falls back to the header row:
    /// a collapsible `.sidebar` section reveals its chevron on hover, and which of the
    /// two the AX tree exposes as hit-testable is a styling detail this test must not
    /// depend on.
    private func toggleSection(_ section: String) {
        let element = header(section)
        XCTAssertTrue(element.waitForExistence(timeout: 30), "missing sidebar section header \(section)")
        element.hover()
        let band = element.frame.insetBy(dx: -240, dy: -2)
        let chevron = app.descendants(matching: .disclosureTriangle).allElementsBoundByIndex
            .first { band.intersects($0.frame) }
        (chevron ?? element).click()
    }
}
