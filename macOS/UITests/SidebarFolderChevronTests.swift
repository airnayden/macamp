import XCTest

/// The rendered proof that a library root's disclosure chevron is EXACT on the very
/// first frame.
///
/// `SidebarFolderTreeNode` draws a `DisclosureGroup` only when `node.hasChildren`, so
/// the chevron's presence in the accessibility tree is a direct read of that flag.
/// The fixture seeds two roots of different shape — "Fixture Library" nests, "Fixture
/// Singles" holds files only — and every assertion here runs BEFORE any expansion, so
/// a root that assumed a chevron until its first child load would fail immediately.
final class SidebarFolderChevronTests: XCTestCase {
    private var app: XCUIApplication!
    private var seedPath: String!
    private var runID: String!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let identifier = UUID().uuidString
        runID = identifier
        seedPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("macamp-folderchevron-uitest-\(identifier)")
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

    func testOnlyTheNestingRootOffersAChevronBeforeAnythingIsExpanded() {
        app.launch()
        let nesting = folderRow(named: FixtureNames.nestingRoot)
        let leaf = folderRow(named: FixtureNames.leafRoot)
        XCTAssertTrue(nesting.waitForExistence(timeout: 30), "the nesting root should appear in the sidebar")
        XCTAssertTrue(leaf.waitForExistence(timeout: 30), "the leaf root should appear in the sidebar")

        attachSidebarScreenshot(named: "sidebar-root-chevrons")

        XCTAssertTrue(
            hasDisclosureTriangle(nesting),
            "a root that holds subfolders must offer a chevron on the first frame"
        )
        XCTAssertFalse(
            hasDisclosureTriangle(leaf),
            "a root that holds only files must NOT offer a chevron, even before any expansion"
        )
    }

    func testTheLeafRootStillOffersNoChevronAfterARefresh() {
        app.launch()
        let leaf = folderRow(named: FixtureNames.leafRoot)
        XCTAssertTrue(leaf.waitForExistence(timeout: 30), "the leaf root should appear in the sidebar")

        // Selecting the nesting root's subtree and coming back re-runs the sidebar's
        // node rebuild, which must serve the cached probe rather than re-guessing.
        folderRow(named: FixtureNames.nestingRoot).click()
        XCTAssertTrue(leaf.waitForExistence(timeout: 15), "the leaf root should survive the rebuild")

        XCTAssertFalse(
            hasDisclosureTriangle(leaf),
            "a cached leaf root must not grow a chevron on a later rebuild"
        )
    }

    // MARK: - Helpers

    private enum FixtureNames {
        static let nestingRoot = "Fixture Library"
        static let leafRoot = "Fixture Singles"
    }

    /// Folder rows are identified by their STABLE path hash, which a test cannot
    /// compute, so they are located by their visible name inside the sidebar list.
    private func folderRow(named name: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "sidebar.list").firstMatch
            .staticTexts[name]
    }

    /// Whether a disclosure triangle sits on `row`'s own line. The triangle is a
    /// sibling of the label rather than a child, so it is matched by vertical overlap
    /// across the sidebar's width — the same band trick `SidebarFolderTreeTests` uses
    /// to click one.
    private func hasDisclosureTriangle(_ row: XCUIElement) -> Bool {
        let band = row.frame.insetBy(dx: -240, dy: -2)
        return app.descendants(matching: .disclosureTriangle).allElementsBoundByIndex
            .contains { band.intersects($0.frame) }
    }

    private func attachSidebarScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
