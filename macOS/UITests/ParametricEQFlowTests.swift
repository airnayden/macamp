import XCTest

/// Covers the parametric editor's two entry points.
///
/// Both assertions are reachability checks, not behaviour checks: the editor's
/// logic is pinned by `ParametricEQViewModelTests` in PlayerCore, and what a UI
/// test can add here is that the controls are actually on screen and hittable —
/// a view model wired to nothing passes every unit test.
final class ParametricEQFlowTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    func testEQOverlayHostsTheModeToggle() {
        let eqToggle = app.descendants(matching: .any)
            .matching(identifier: "player.eqToggle").firstMatch
        XCTAssertTrue(eqToggle.waitForExistence(timeout: 30))
        eqToggle.click()

        let modeToggle = app.descendants(matching: .any)
            .matching(identifier: "eq.modeToggle").firstMatch
        XCTAssertTrue(modeToggle.waitForExistence(timeout: 15))
        XCTAssertTrue(modeToggle.isHittable)
    }

    /// Selecting Parametric must reveal the editor. A mode toggle that changes a
    /// flag and nothing visible would satisfy the assertion above on its own.
    func testParametricModeRevealsTheEditor() {
        let eqToggle = app.descendants(matching: .any)
            .matching(identifier: "player.eqToggle").firstMatch
        XCTAssertTrue(eqToggle.waitForExistence(timeout: 30))
        eqToggle.click()

        let modeToggle = app.descendants(matching: .any)
            .matching(identifier: "eq.modeToggle").firstMatch
        XCTAssertTrue(modeToggle.waitForExistence(timeout: 15))
        // A segmented `Picker` is an `NSSegmentedControl`, so its segments are
        // radio buttons rather than buttons — index 1 is Parametric.
        let parametric = modeToggle.descendants(matching: .radioButton).element(boundBy: 1)
        XCTAssertTrue(parametric.waitForExistence(timeout: 5))
        parametric.click()

        let importButton = app.descendants(matching: .any)
            .matching(identifier: "eq.parametric.import").firstMatch
        XCTAssertTrue(importButton.waitForExistence(timeout: 15))

        let addBand = app.descendants(matching: .any)
            .matching(identifier: "eq.parametric.addBand").firstMatch
        XCTAssertTrue(addBand.waitForExistence(timeout: 5))
    }
}
