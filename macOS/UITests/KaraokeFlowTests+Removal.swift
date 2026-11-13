import XCTest

/// "Remove Karaoke Version" coverage for the karaoke ready list (stats-expansion todo 15).
/// Split out of `KaraokeFlowTests.swift` to keep that file within the SwiftLint file-length
/// budget; reuses its `app` / fixture labels / launch + navigation helpers.
extension KaraokeFlowTests {
    /// `MacAMPStrings.karaokeReadyRemove` English default, matched as a SUBSTRING so the assertion
    /// holds whichever singular/plural form the inflection resolves to.
    var removeKaraokeVersionLabel: String {
        "Karaoke Version"
    }

    /// The ready list offers a destructive "Remove Karaoke Version" action. The fixture is
    /// rendered from its inline row icon (which renders WITHOUT starting playback), so its
    /// instrumental is never pinned and the action is genuinely available. Reaching the ready
    /// list needs the badged `sidebar.row.karaoke`, whose `List(selection:)` can fail to commit
    /// under XCUITest, so navigation is guarded by `openKaraokeReadyListOrSkip`.
    func testKaraokeReadyListOffersRemoveKaraokeVersion() throws {
        launchApp(karaokeFake: true, karaokeEnabledAtLaunch: true)
        expect(playerBar, timeout: 30, "the main window should finish loading")

        selectSidebarRow("allTracks")
        expect(karaokeRenderIcons.element(boundBy: 0), "a renderable library row should show the inline render icon")
        karaokeRenderIcons.element(boundBy: 0).click()
        expect(
            firstElement(labelContaining: karaokeReadyBadgeLabel),
            timeout: 20,
            "rendering the track should flip its row to the ready badge"
        )

        try openKaraokeReadyListOrSkip()
        let track = app.staticTexts[fixtureTrack]
        expect(track, "the rendered track should be listed in the Karaoke ready list")
        track.rightClick()

        expect(
            firstElement(labelContaining: removeKaraokeVersionLabel),
            "the ready-list context menu should offer the Remove Karaoke Version action"
        )
        snapshot("07-ready-list-remove-menu")
    }
}
