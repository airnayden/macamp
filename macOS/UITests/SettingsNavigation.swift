import XCTest

extension XCUIApplication {
    /// Navigates by stable section identity, independently of language and AX row type.
    func selectSettingsSection(_ section: String, file: StaticString = #filePath, line: UInt = #line) {
        activate()
        let window = windows.containing(.any, identifier: "preferences.sidebar").firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 20), "Settings should be open", file: file, line: line)
        let sidebar = window.descendants(matching: .any).matching(identifier: "preferences.sidebar").firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 10), "Settings should have a sidebar", file: file, line: line)
        let label = sidebar.descendants(matching: .any)
            .matching(identifier: "preferences.section.\(section)").firstMatch
        let row = sidebar.descendants(matching: .outlineRow)
            .containing(.any, identifier: "preferences.section.\(section)").firstMatch
        for _ in 0 ..< 8 {
            if label.isHittable { break }
            sidebar.scroll(byDeltaX: 0, deltaY: -160)
        }
        for _ in 0 ..< 8 {
            if label.isHittable { break }
            sidebar.scroll(byDeltaX: 0, deltaY: 160)
        }
        guard label.exists, label.isHittable, row.exists else {
            XCTFail(
                "Settings section \(section) should be reachable; label exists=\(label.exists), hittable=\(label.isHittable), row exists=\(row.exists). \(sidebar.debugDescription)",
                file: file, line: line
            )
            return
        }
        // AX exposes the row as a non-hittable container. Its visible label proves
        // reachability; click the row background to give the native list keyboard focus.
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).click()
    }
}
