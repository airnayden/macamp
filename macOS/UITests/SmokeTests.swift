import XCTest

final class SmokeTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    func testAppLaunchesMainWindowExists() {
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 30))
    }

    func testAlbumsSidebarSwitchesContent() {
        let albumsRow = app.descendants(matching: .any)
            .matching(identifier: "sidebar.row.albums").firstMatch
        XCTAssertTrue(albumsRow.waitForExistence(timeout: 30))
        albumsRow.click()
        let albumsView = app.descendants(matching: .any)
            .matching(identifier: "albums.view").firstMatch
        XCTAssertTrue(albumsView.waitForExistence(timeout: 15))
    }

    func testLyricsSidebarSwitchesContent() {
        let lyricsRow = app.descendants(matching: .any)
            .matching(identifier: "sidebar.row.lyrics").firstMatch
        XCTAssertTrue(lyricsRow.waitForExistence(timeout: 30))
        lyricsRow.click()
        let lyricsView = app.descendants(matching: .any)
            .matching(identifier: "lyrics.view").firstMatch
        XCTAssertTrue(lyricsView.waitForExistence(timeout: 15))
    }

    func testQueueSidebarRowFollowsStats() {
        let statsRow = app.descendants(matching: .any)
            .matching(identifier: "sidebar.row.stats").firstMatch
        let queueRow = app.descendants(matching: .any)
            .matching(identifier: "sidebar.row.queue").firstMatch
        XCTAssertTrue(statsRow.waitForExistence(timeout: 30))
        XCTAssertTrue(queueRow.waitForExistence(timeout: 30))
        XCTAssertGreaterThan(queueRow.frame.minY, statsRow.frame.minY)
    }

    func testQueueSidebarSwitchesContent() {
        let queueRow = app.descendants(matching: .any)
            .matching(identifier: "sidebar.row.queue").firstMatch
        XCTAssertTrue(queueRow.waitForExistence(timeout: 30))
        queueRow.click()
        let queueView = app.descendants(matching: .any)
            .matching(identifier: "queue.view").firstMatch
        XCTAssertTrue(queueView.waitForExistence(timeout: 15))
    }

    func testRightPanelShowsFourTabsWithoutQueue() {
        let picker = app.descendants(matching: .any)
            .matching(identifier: "rightPanel.tabPicker").firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 30))
        for tab in ["lyrics", "tags", "info", "stats"] {
            let element = app.descendants(matching: .any)
                .matching(identifier: "rightPanel.tab.\(tab)").firstMatch
            XCTAssertTrue(element.waitForExistence(timeout: 15), "missing right-panel tab \(tab)")
        }
        let queueTab = app.descendants(matching: .any)
            .matching(identifier: "rightPanel.tab.queue").firstMatch
        XCTAssertFalse(queueTab.exists)
    }

    func testPlayerBarExists() {
        let bar = app.descendants(matching: .any)
            .matching(identifier: "player.bar").firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 30))
    }

    func testSearchFieldAcceptsInput() {
        let field = app.textFields["library.searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 30))
        field.click()
        field.typeText("smoke")
        XCTAssertEqual(field.value as? String, "smoke")
    }
}
