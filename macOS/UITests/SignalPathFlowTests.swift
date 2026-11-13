import XCTest

/// XCUITest smoke for the player-bar signal-path panel (plan todo 17).
///
/// Runs against the hermetic launch-environment-seeded app, whose two fixture
/// tracks are zero-byte `.mp3` placeholders with NO bitrate, sample rate or bit
/// depth recorded. That is deliberately the failure path: the mapper must degrade
/// each absent field rather than fabricate one, so the source line reads exactly
/// `"MP3"` — the container token, and nothing invented around it.
///
/// One test, not three. Every assertion here needs the same expensive setup (a
/// launch, a library selection, a play, a popover), and three launches in a row
/// measurably starved the library list past its own wait.
final class SignalPathFlowTests: XCTestCase {
    private var app: XCUIApplication!
    private var seedPath: String!
    private var runID: String!

    /// The container token the fixture's own file extension maps to.
    private static let fixtureSourceFormat = "MP3"
    private static let fixtureTrack = "Aurora Anthem"
    /// The claim MacAMP may never make: two mixer nodes, float conversion and the
    /// system output volume are unconditionally downstream of this app.
    private static let forbiddenClaim = "bit-perfect"

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
        if let seedPath { try? FileManager.default.removeItem(atPath: seedPath) }
        if let runID { UserDefaults().removePersistentDomain(forName: "com.example.macamp.uitest.\(runID)") }
    }

    /// Playing a track exposes the format capsule; opening it reports the mapped
    /// source line, states the conversion verdict either way, and never implies a
    /// bit-perfect path.
    func testSignalPathPanelReportsTheMappedChain() {
        launch()
        playFixtureTrack()

        let capsule = app.buttons["player.signalPathButton"]
        XCTAssertTrue(capsule.waitForExistence(timeout: 20), "playing a track should expose the format capsule")
        capsule.click()

        let sourceFormat = staticText("signalPath.sourceFormat")
        XCTAssertTrue(sourceFormat.waitForExistence(timeout: 15), "the panel should report the source format")
        XCTAssertEqual(
            text(of: sourceFormat),
            Self.fixtureSourceFormat,
            "an untagged fixture should read as its container alone, with no fabricated rate or depth"
        )

        let indicator = staticText("signalPath.srcIndicator")
        XCTAssertTrue(
            indicator.waitForExistence(timeout: 15),
            "the conversion indicator should be present whether or not resampling is happening"
        )
        XCTAssertFalse(text(of: indicator).isEmpty, "the indicator should state a value, not render blank")

        assertVerdictNeverClaimsBitPerfect()
        snap("signal-path-panel")
    }
}

// MARK: - Assertions

private extension SignalPathFlowTests {
    func assertVerdictNeverClaimsBitPerfect() {
        let verdict = staticText("signalPath.verdict")
        XCTAssertTrue(verdict.waitForExistence(timeout: 15), "the panel should state a verdict")
        XCTAssertFalse(text(of: verdict).isEmpty, "the verdict should name itself, not render blank")
        XCTAssertFalse(
            text(of: verdict).lowercased().contains(Self.forbiddenClaim),
            "MacAMP cannot promise bit-perfect output and must never imply it"
        )
        // TYPED and SCOPED to the popover: an `app.descendants(.any)` predicate
        // query over the whole window times out before it answers (measured at
        // 113 s here, and already documented on `KaraokeFlowTests+Helpers`).
        XCTAssertFalse(
            app.popovers.firstMatch.staticTexts
                .matching(NSPredicate(
                    format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@",
                    Self.forbiddenClaim,
                    Self.forbiddenClaim
                ))
                .firstMatch
                .exists,
            "no text on the signal-path panel may carry a bit-perfect claim"
        )
    }
}

// MARK: - Harness

private extension SignalPathFlowTests {
    func launch() {
        continueAfterFailure = false
        let identifier = UUID().uuidString
        runID = identifier
        seedPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("macamp-uitest-\(identifier)")

        app = XCUIApplication()
        app.launchEnvironment["UITEST_SEED_PATH"] = seedPath
        app.launchEnvironment["UITEST_RUN_ID"] = identifier
        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "player.bar").firstMatch
                .waitForExistence(timeout: 30),
            "the main window should finish loading"
        )
    }

    /// Selection must be driven from the sidebar's outline CELL, not the inner
    /// label: a macOS `List(selection:)` row commits from a click on the row.
    func playFixtureTrack() {
        let cell = app.outlines["sidebar.list"].cells
            .containing(.staticText, identifier: "sidebar.row.allTracks").firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 20), "the All Tracks sidebar row should exist")
        cell.click()

        let track = app.staticTexts[Self.fixtureTrack]
        XCTAssertTrue(track.waitForExistence(timeout: 30), "the fixture track should be listed")
        track.doubleClick()
    }

    /// A TYPED query, because an untyped `descendants(.any)` match resolves to the
    /// enclosing container first and containers expose an empty `label` — which
    /// would turn every assertion on a rendered token into a vacuous pass.
    func staticText(_ identifier: String) -> XCUIElement {
        app.staticTexts.matching(identifier: identifier).firstMatch
    }

    /// MEASURED: a macOS SwiftUI `StaticText` carries its string in `value`, not
    /// `label` — so an assertion written against `label` compares against `""` and
    /// passes or fails for the wrong reason. `label` is kept as the fallback for
    /// elements that do use it.
    func text(of element: XCUIElement) -> String {
        (element.value as? String) ?? element.label
    }

    func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
