// Where the request field SITS, asserted in points.
//
// A sibling extension rather than more of `AssistantFlowTests.swift`, which sits at
// the SwiftLint `file_length` ceiling — the same reason `+PreviewHarness.swift` and
// `AssistantContextualActionsTests.swift` are their own files.
//
// ── WHY A GEOMETRY ASSERTION AND NOT AN EXISTENCE ONE ─────────────────────────
//
// `assistant.promptField` exists in every layout this pane has ever had, so every
// existing assertion about it passes with the field at the TOP of the pane, which is
// where it used to be. The regression this file guards is purely positional: the feed
// must take the free space and the bar must be the last thing above the player bar.
// Only a frame comparison can fail for that reason.
//
// ── THE SECOND STATE IS THE ONE THAT ACTUALLY BITES ───────────────────────────
//
// Pinning the bar is half the fix; the other half is that the status banner, the chat
// notice and the Apple Intelligence caption render ABOVE the field inside the bar. Put
// them below it and the empty state still measures correctly — the rows are not on
// screen yet — while a single failed request pushes the field the listener is about to
// retype into up by the banner's whole height. So the field is measured twice: once on
// the untouched pane, and once after a request that is GUARANTEED to report a failure.
import XCTest

extension AssistantFlowTests {
    /// The bar is pinned in both pane states, and reporting a failure does not move it.
    func testPromptFieldStaysPinnedToTheBottomInBothPaneStates() {
        app.launch()
        openAssistantPane()
        XCTAssertTrue(
            element("assistant.suggestionFeed").waitForExistence(timeout: 15),
            "the empty state should be the suggestion feed, which is the state being measured"
        )
        assertPromptFieldIsPinnedToTheBottom(state: "the suggestion feed")
        snap("assistant-prompt-pinned-empty")

        submitRequest(Self.unmatchableRequest)
        XCTAssertTrue(
            element("assistant.errorBanner").waitForExistence(timeout: 30),
            """
            the request should be reported as matching nothing, which is the state that \
            grows the request bar; on screen: \(visibleLabels())
            """
        )
        assertPromptFieldIsPinnedToTheBottom(state: "a reported failure")
        snap("assistant-prompt-pinned-after-send")
    }
}

// MARK: - Harness

extension AssistantFlowTests {
    /// The request the REAL heuristic tier resolves to `year BETWEEN 1990 AND 1999`,
    /// which the fixture library — no genres, no years — correctly matches nothing for.
    /// Deliberately sent WITHOUT `UITEST_ASSISTANT_FAKE`, because the fake resolves any
    /// request to an unconstrained spec and would open the preview sheet OVER the pane
    /// being measured instead of leaving the failure on it.
    static var unmatchableRequest: String {
        "upbeat 90s rock"
    }

    /// How far the field's bottom edge may sit above the window's.
    ///
    /// The pane does not reach the window's bottom: the 100 pt player bar is below it,
    /// and the bar adds `spacing.small` (12 pt) of its own padding under the field, for
    /// ~112 pt. The allowance is the next round number above that — loose enough to
    /// survive a token or player-bar tweak, far tighter than the ~200 pt a banner and
    /// caption below the field would cost and than the several hundred the field was
    /// off by when the bar was the FIRST child of the stack.
    static var pinnedBottomAllowance: CGFloat {
        140
    }

    func assertPromptFieldIsPinnedToTheBottom(
        state: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let field = element("assistant.promptField")
        XCTAssertTrue(field.exists, "the request field should be on screen with \(state)", file: file, line: line)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.exists, "the main window should be on screen", file: file, line: line)

        let gap = window.frame.maxY - field.frame.maxY
        XCTAssertGreaterThanOrEqual(
            gap,
            0,
            "the request field should sit inside the window with \(state) (gap \(gap) pt)",
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            gap,
            Self.pinnedBottomAllowance,
            """
            the request field should be pinned to the bottom of the pane with \(state), \
            but its bottom edge is \(gap) pt above the window's \
            (allowed \(Self.pinnedBottomAllowance) pt); field \(field.frame), \
            window \(window.frame)
            """,
            file: file,
            line: line
        )
    }
}
