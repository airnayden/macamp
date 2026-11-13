// Preview-sheet harness for `AssistantFlowTests` (plan todo 23).
//
// Split out of `AssistantFlowTests.swift`, which sits at the SwiftLint `file_length`
// ceiling — the same reason `AssistantContextualActionsTests.swift` and
// `KaraokeFlowTests+Helpers.swift` are their own files. Internal rather than `private`
// so the test bodies in the main file can reach it.
//
// ── THE QUERY BUG THIS FILE EXISTS TO NOT REPEAT ───────────────────────────────
//
// From XCUIElementQuery.h, verbatim:
//
//   matchingPredicate:   "Returns a new query that applies the specified attributes or
//                         predicate to the receiver."
//   containingPredicate: "Returns a new query for finding elements that contain a
//                         DESCENDANT matching the specification."
//
// A static text is a LEAF. `app.staticTexts.containing(labelPredicate)` therefore has
// nothing to match against and never fires, whatever the app is showing — it fails
// identically when the app is correct and when it is broken, which is the worst
// possible shape for an assertion. Filter labels with `matching`; reserve `containing`
// for "the row that holds this text".
//
// ── THE SECOND HALF OF THE SAME BUG: `label` IS THE WRONG PROPERTY ─────────────
//
// The rule above fixed the query SHAPE and left the query FIELD wrong, so two cases
// kept failing in the identical can-never-pass way. Measured on this host against the
// live runner (Xcode 26.6 / macOS 26.5): EVERY SwiftUI `Text` in this app publishes
// its string as the accessibility VALUE and leaves `label` EMPTY.
//
//     predicate on `label CONTAINS "Fixture Artist"`   -> exists = false
//     predicate on `value CONTAINS "Fixture Artist"`   -> exists = true
//     app.staticTexts["Aurora Anthem — Fixture Artist"] -> exists = true
//
// Not a property of one screen: `Review Before Saving`, `All Tracks`, `TRACKS`,
// `AUTO MIXES` — all of them report `label=[] value=[…]`. Only AppKit-provided text
// (List section headers) and real CONTROLS (`Button`, `CheckBox`) carry a `label`.
//
// That is why the sibling tag-batch case passes while these did not: it looks its copy
// up with `app.staticTexts["Aurora Anthem.mp3"]`, and the SUBSCRIPT matches the value.
// Only the two helpers below reached for `label` through an explicit NSPredicate, and
// an NSPredicate reads the literal property.
//
// So: assert on label OR value. Anything narrower is a query that cannot fail for the
// right reason. `visibleLabels()` prints both for the same reason — dumping `label`
// alone is what produced the misleading " |  |  | " diagnostic that sent two separate
// investigations after a non-existent view-hierarchy defect.
import XCTest

extension AssistantFlowTests {
    /// The request text doubles as the created playlist's name: with the fake parser
    /// the backend stack carries no naming tier, so `AssistantViewModel` falls back to
    /// the listener's own words.
    static var fakeRequest: String {
        "upbeat 90s rock"
    }

    /// Any cell whose resolved title carries the fixture artist — either seeded track
    /// satisfies "the list shows at least one cell", and which one the mix ranks first
    /// is not this test's business.
    var fixtureTrackCell: XCUIElement {
        app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Fixture Artist", "Fixture Artist")
        ).firstMatch
    }

    /// Every static-text label currently on screen, for failure messages. A bare
    /// "element not found" cannot distinguish "the titles never resolved" from "the
    /// query was wrong", which is exactly the confusion that produced this file.
    func visibleLabels(limit: Int = 40) -> String {
        var copy: [String] = []
        for element in app.staticTexts.allElementsBoundByIndex.prefix(limit) {
            let spoken = element.label.isEmpty ? (element.value as? String ?? "") : element.label
            if !spoken.isEmpty { copy.append(spoken) }
        }
        return copy.isEmpty ? "<none>" : copy.joined(separator: " | ")
    }

    func openAssistantPane() {
        let row = element("sidebar.row.assistant")
        XCTAssertTrue(row.waitForExistence(timeout: 30), "the Assistant sidebar row should exist")
        row.click()
        XCTAssertTrue(
            element("assistant.promptField").waitForExistence(timeout: 15),
            "selecting the Assistant row should show its request field"
        )
    }

    func submitRequest(_ text: String) {
        let field = element("assistant.promptField")
        field.click()
        field.typeText(text)
        element("assistant.submitButton").click()
    }

    func waitForDisappearance(of identifier: String, timeout: TimeInterval = 20) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: element(identifier)
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}

// MARK: - Reading a banner's copy

extension XCUIElement {
    /// Whether this element's own copy, or any copy beneath it, carries `phrase`.
    ///
    /// Checks the label AND the value, at both levels. Whether SwiftUI exposes an
    /// icon-plus-text banner as a container with descendant static texts or folds it
    /// into one combined element depends on how it resolves the accessibility
    /// identifier, and a `Text`'s string lands in `value` rather than `label` — see the
    /// file header. The assertion is about the COPY, not about which of those shapes
    /// AppKit chose today or which property it parked the string in.
    func carriesCopy(containing phrase: String) -> Bool {
        if spokenCopy.localizedCaseInsensitiveContains(phrase) { return true }
        return descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", phrase, phrase))
            .firstMatch
            .exists
    }

    /// This element's copy plus its descendants', for failure messages.
    func copyDump(limit: Int = 10) -> String {
        var copy = [spokenCopy]
        for element in descendants(matching: .staticText).allElementsBoundByIndex.prefix(limit) {
            copy.append(element.spokenCopy)
        }
        return copy.filter { !$0.isEmpty }.joined(separator: " | ")
    }

    /// The element's label, or its value when the label is empty — what a listener
    /// actually hears, whichever property the platform parked the string in.
    var spokenCopy: String {
        label.isEmpty ? (value as? String ?? "") : label
    }
}
