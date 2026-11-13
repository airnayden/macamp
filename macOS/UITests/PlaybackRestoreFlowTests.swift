import XCTest

final class PlaybackRestoreFlowTests: XCTestCase {
    private var app: XCUIApplication!
    private var seedPath: String!
    private var runID: String!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let identifier = UUID().uuidString
        runID = identifier
        seedPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("macamp-restore-uitest-\(identifier)")
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

    func testLastPlayedTrackRestoresPausedAfterRelaunch() {
        app.launch()
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "player.bar").firstMatch
                .waitForExistence(timeout: 30),
            "the first launch should finish loading"
        )

        let fixtureTrack = app.staticTexts["Aurora Anthem"]
        XCTAssertTrue(fixtureTrack.waitForExistence(timeout: 15), "the seeded track should exist")
        fixtureTrack.doubleClick()
        let pauseButton = app.buttons["Pause"]
        XCTAssertTrue(pauseButton.waitForExistence(timeout: 10), "the fixture should start playing")
        pauseButton.click()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 10), "the fixture should be paused before quit")

        app.terminate()
        app.launch()

        let identity = app.descendants(matching: .any).matching(identifier: "player.identity").firstMatch
        XCTAssertTrue(identity.waitForExistence(timeout: 30), "the relaunched player bar should exist")
        XCTAssertTrue(
            identity.staticTexts["Aurora Anthem"].waitForExistence(timeout: 10),
            "the relaunched player bar should show the last-played track"
        )
        XCTAssertTrue(app.buttons["Play"].exists, "restored playback should remain paused")
    }
}
