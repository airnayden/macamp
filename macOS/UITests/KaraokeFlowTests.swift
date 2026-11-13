import XCTest

/// End-to-end XCUITest for the macOS **on-demand** karaoke (vocal-removal) flow
/// (karaoke-refinements todo 15; queue management added by karaoke-queue-management todo 7).
///
/// Drives the karaoke feature end to end against the hermetic, launch-seeded app
/// (`AppEnvironment.liveForUITesting()`), so it never touches the user's real library or
/// standard defaults. Every wait is a `waitForExistence` / `XCTNSPredicateExpectation`
/// expectation — there are no wall-clock sleeps.
///
/// ## Launch contract (`AppEnvironment+UITesting` seam)
/// - `UITEST_SEED_PATH=<temp dir>` — seeds a throwaway GRDB library with the fixture tracks
///   "Aurora Anthem" / "Zephyr Waltz" (stored under their canonical paths) and a throwaway
///   `UserDefaults` suite.
/// - `UITEST_KARAOKE_FAKE=1` — swaps in an always-available fake stem separator plus an
///   shared instrumental cache. It starts empty unless `UITEST_KARAOKE_LEGACY_CACHED=1`
///   seeds the first fixture without source identity; otherwise the button boots `.renderable`
///   and pressing it runs an on-demand "render" — the fake stores the source
///   into the shared cache, firing the cache change-seam — which drives the ready store, the
///   row badge, the sidebar section and the button's `.ready`/`.active` states, with no Core ML
///   model required. The model SHA is the literal `"uitest-karaoke-model"`.
///
/// ## Button state ids (todo 13 `KaraokeButtonContent`)
/// Each visible state carries a DISTINCT accessibility identifier; `.hidden` collapses to
/// `EmptyView()` (absent from the tree): `player.karaokeButton.{disabled,preparing,renderable,
/// ready,active}`. The instant fake usually skips `.preparing`, so the flow asserts the
/// eventual `.ready`.
///
/// Helper queries / launch + settings steps / screenshots live in `KaraokeFlowTests+Helpers.swift`.
/// Screenshots per reached state are attached to the `.xcresult` and written under
/// `.omo/evidence/karaoke-refinements/`.
final class KaraokeFlowTests: XCTestCase {
    // `internal` (not `private`) so the sibling helpers file can reach them across files.
    var app: XCUIApplication!
    var seedPath: String!
    var runID: String!

    /// `internal` (not `private`) so the sibling `+Removal` file can reach it across files.
    let fixtureTrack = "Aurora Anthem"
    /// The second seeded fixture (`AppEnvironment+UITesting`). Used to observe a MULTI-item
    /// render queue while paused (the instant fake separator drains a running queue too fast).
    private let secondFixtureTrack = "Zephyr Waltz"
    /// `DesignSystemStrings.transportPause` English default — the transport button's a11y label
    /// once a track is playing (a deterministic "playback started" signal).
    private let transportPauseLabel = "Pause"
    /// `KaraokeBadgeStrings.ready` English default (todo 12) — the a11y label on a track row's
    /// "ready" karaoke badge.
    let karaokeReadyBadgeLabel = "Karaoke version ready"
    /// `KaraokeBadgeStrings.rendering` English default — the a11y label on a row's in-flight
    /// render ring; the deterministic "this track is now rendering" signal under the HOLD fake.
    private let karaokeRenderingLabel = "Creating karaoke version"
    /// `PreferencesStrings.tabKaraoke` English default (todo 10) — the RELOCATED karaoke tab that
    /// now hosts `preferences.karaoke.toggle` (moved off the Playback tab).
    private let karaokeTabTitle = "Karaoke"
    /// `PreferencesStrings.karaokePrune` English default — the cache-size-limit toggle.
    private let pruneToggleLabel = "Limit cache size"
    /// `PreferencesStrings.karaokeCacheCap` English default — the cap picker shown only while
    /// pruning is enabled. Internal so the sibling helpers file's `capPicker` can read it.
    let capPickerLabel = "Maximum size"

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
        if let seedPath { try? FileManager.default.removeItem(atPath: seedPath) }
        if let runID { UserDefaults().removePersistentDomain(forName: "com.example.macamp.uitest.\(runID)") }
    }

    // MARK: - Tests

    /// The on-demand happy path: enable via the relocated Karaoke tab, render the current track
    /// on demand (`.renderable` → `.ready`), engage karaoke (`.active`), and confirm the ready
    /// badge, the sidebar Karaoke section and its ready list all light up.
    func testOnDemandKaraokeFlow() {
        launchApp(karaokeFake: true)
        expect(playerBar, timeout: 30, "the main window should finish loading")

        // (a) Setting OFF by default ⇒ no karaoke button in any state.
        XCTAssertFalse(anyKaraokeButtonExists, "the karaoke button must be hidden while the setting is off")
        setKaraokeSetting(enabled: true)

        // (b) Nothing cached ⇒ the button boots `.renderable` (a press renders on demand).
        expect(karaokeButton(.renderable), "with nothing cached the karaoke button should be .renderable")
        snapshot("01-renderable")

        // A present `current` track is the precondition for both the render and engaging karaoke.
        playFixtureTrack()
        expect(karaokeButton(.renderable), timeout: 10, "the button stays .renderable until rendered")

        // (c) Press `.renderable` ⇒ on-demand render ⇒ the button reaches `.ready` (may skip
        //     `.preparing` because the fake render is instant).
        XCTAssertTrue(karaokeButton(.renderable).isHittable, "the renderable karaoke button should be hittable")
        karaokeButton(.renderable).click()
        expect(karaokeButton(.ready), timeout: 20, "rendering the current track should flip it to .ready")
        snapshot("02-ready")

        // (d) Press `.ready` ⇒ engage karaoke ⇒ `.active` (the cached instrumental plays).
        karaokeButton(.ready).click()
        expect(karaokeButton(.active), "engaging karaoke on the ready track should flip it to .active")
        snapshot("03-active")

        // (e) The rendered track's library row shows the "ready" badge (todo 12 a11y label).
        selectSidebarRow("allTracks")
        expect(firstElement(labelContaining: karaokeReadyBadgeLabel), "the library row should show the ready badge")
        snapshot("04-row-badge")

        // (f) The sidebar Karaoke section appears and its ready list contains the track.
        let karaokeSidebarRow = element("sidebar.row.karaoke")
        expect(karaokeSidebarRow, "the sidebar Karaoke section should appear once karaoke is enabled")
        karaokeSidebarRow.click()
        expect(app.staticTexts[fixtureTrack], "the Karaoke ready list should list the rendered track")
        snapshot("05-sidebar-karaoke")
    }

    /// Todo 6: playing a track from the **Karaoke Ready list** auto-engages karaoke via the atomic
    /// `setQueue(engagingKaraoke: true)` path. The fixture is rendered from its inline row icon
    /// (`trackRow.karaokeRender`, which renders WITHOUT starting playback), so nothing is playing —
    /// karaoke is not engaged (no `.active`) AND no now-playing title exists to collide with the
    /// ready-list row when it is double-clicked. Double-clicking the ready track then flips the
    /// karaoke button to `.active` and it STAYS there: the explicit path suppresses the
    /// auto-deactivate callback, so a track shown as ready never falls back with a spurious toast.
    /// Reaching the ready list needs the badged `sidebar.row.karaoke`, whose `List(selection:)` can
    /// fail to commit under XCUITest, so navigation is guarded by `openKaraokeReadyListOrSkip`.
    func testPlayingFromKaraokeReadyListEngagesKaraoke() throws {
        launchApp(karaokeFake: true, karaokeEnabledAtLaunch: true)
        expect(playerBar, timeout: 30, "the main window should finish loading")

        // Render the fixture from its inline icon — no playback, so the ready-list row is later the
        // ONLY "Aurora Anthem" on screen (no player-bar now-playing title to make the click ambiguous).
        selectSidebarRow("allTracks")
        expect(karaokeRenderIcons.element(boundBy: 0), "a renderable library row should show the inline render icon")
        karaokeRenderIcons.element(boundBy: 0).click()
        expect(
            firstElement(labelContaining: karaokeReadyBadgeLabel),
            timeout: 20,
            "rendering the track should flip its row to the ready badge"
        )

        // Precondition: nothing is playing, so karaoke is NOT engaged — the .active below is caused
        // by the ready-list play, not a leftover state.
        XCTAssertFalse(karaokeButton(.active).exists, "karaoke must not be engaged before playing from the list")

        // Its own search field proves the ready-list pane actually switched in (vs. All Tracks lingering).
        try openKaraokeReadyListOrSkip()
        let track = app.staticTexts[fixtureTrack]
        expect(track, "the rendered track should be listed in the Karaoke ready list")
        track.doubleClick()

        // The atomic engage flips the button to .active and it STAYS there (no spurious deactivate).
        expect(karaokeButton(.active), "playing from the Karaoke ready list should engage karaoke (.active)")
        XCTAssertFalse(karaokeButton(.ready).exists, "the button should stay .active, not fall back to .ready")
        snapshot("06-ready-list-play-active")
    }

    func testAlreadyCachedTrackUsesDistinctToastWithoutQueueCompleteToast() {
        launchApp(
            karaokeFake: true,
            karaokeEnabledAtLaunch: true,
            legacyCachedFixture: true
        )
        expect(playerBar, timeout: 30, "the main window should finish loading")
        selectSidebarRow("allTracks")

        let renderButton = karaokeRenderIcons.element(boundBy: 0)
        expect(renderButton, "an identity-less cached track should initially offer the render action")
        renderButton.click()

        expect(
            app.staticTexts["Karaoke version already available"],
            "a cache hit should show the distinct already-available toast"
        )
        expect(
            firstElement(labelContaining: karaokeReadyBadgeLabel),
            "the cache-hit identity repair should flip the row to its ready badge"
        )
        XCTAssertFalse(
            app.staticTexts["All karaoke versions finished"].waitForExistence(timeout: 1),
            "an already-cached-only request must not show the queue-complete toast"
        )
        snapshot("cached-01-already-available")
    }

    /// Inline scheduling from the row icons (`trackRow.karaokeRender`) while paused: each scheduled
    /// row flips to the queued clock (`trackRow.karaokeDequeue`) — the reachable part, verified
    /// here. The queue pane then confirms both sit pending with a Start-now control and an enabled
    /// pause/resume button; resuming drains the queue so both reach the ready badge + ready list
    /// (bug 5, live). Reaching the pane needs the badged Karaoke Queue sidebar row, so the pane
    /// portion is guarded by `openKaraokeQueuePaneOrSkip` — the test verifies scheduling, then
    /// SKIPS, and self-heals once that navigation works (see `openKaraokeQueuePaneOrSkip`).
    func testKaraokeQueueSchedulingAndPause() throws {
        launchApp(karaokeFake: true, startPaused: true, karaokeEnabledAtLaunch: true)
        expect(playerBar, timeout: 30, "the main window should finish loading")

        // (a) Karaoke is enabled at launch, so the Karaoke Queue sidebar row is present.
        expect(
            element("sidebar.row.karaokeQueue"),
            "the Karaoke Queue sidebar row should appear when karaoke is enabled"
        )

        // (b) Schedule BOTH fixtures from their inline row icons. Paused (startPaused) ⇒ each
        //     appends and stays pending; scheduling flips that row's render icon to the queued
        //     clock, so the second click re-reads the first STILL-renderable row (index 0).
        selectSidebarRow("allTracks")
        expect(karaokeRenderIcons.element(boundBy: 0), "a renderable library row should show the inline render icon")
        karaokeRenderIcons.element(boundBy: 0).click()
        expect(karaokeDequeueIcons.element(boundBy: 0), "the first scheduled row should flip to the queued clock")
        karaokeRenderIcons.element(boundBy: 0).click()
        expect(karaokeDequeueIcons.element(boundBy: 1), "the second scheduled row should flip to the queued clock")
        snapshot("q-01-scheduled-paused")

        // (c) The queue pane lists both pending tracks, offers Start-now, and its pause/resume
        //     control is enabled (non-empty). Reaching the pane needs the badged sidebar row.
        try openKaraokeQueuePaneOrSkip()
        expect(app.staticTexts[fixtureTrack], "the first scheduled track should be pending in the queue")
        expect(app.staticTexts[secondFixtureTrack], "the second scheduled track should be pending in the queue")
        expect(karaokeQueueStartNowButton, "a pending queue row should offer a Start-now control")
        expect(karaokeQueuePauseButton, "the header pause/resume button should exist with items queued")
        XCTAssertTrue(karaokeQueuePauseButton.isEnabled, "a non-empty queue should enable the pause/resume button")
        XCTAssertTrue(karaokeQueuePauseButton.isHittable, "the header pause/resume button should be hittable")
        snapshot("q-02-pending")

        // (d) Resume ⇒ the instant fake drains the queue → both tracks reach the ready badge and
        //     the Karaoke ready list (bug 5 fixed: the ready set populates from the drain).
        karaokeQueuePauseButton.click()
        selectSidebarRow("allTracks")
        expect(
            firstElement(labelContaining: karaokeReadyBadgeLabel),
            timeout: 20,
            "a scheduled track should show the ready badge once the queue drains"
        )
        selectSidebarRow("karaoke")
        expect(app.staticTexts[fixtureTrack], "the first track should be ready in the karaoke list")
        expect(app.staticTexts[secondFixtureTrack], "the second track should be ready in the karaoke list")
        snapshot("q-03-ready")
    }

    /// Per-row queue controls (todo F). The HOLD fake keeps the first scheduled track rendering (a
    /// cancellable sleep), so its row shows the in-flight ring while a second, pending row shows the
    /// queued clock — the reachable part, verified here. The queue pane then exposes Stop on the
    /// in-flight row and Start-now on the pending row, and Stop cancels + requeues the render.
    /// Reaching the pane needs the badged Karaoke Queue sidebar row, so the pane portion is guarded
    /// by `openKaraokeQueuePaneOrSkip` — the test verifies the ring + queued clock, then SKIPS, and
    /// self-heals once that navigation works.
    func testKaraokeQueueRowControls() throws {
        launchApp(karaokeFake: true, hold: true, karaokeEnabledAtLaunch: true)
        expect(playerBar, timeout: 30, "the main window should finish loading")

        // (a) Schedule the first fixture. The HOLD fake keeps it in flight (its row shows the
        //     rendering ring), so its inline render icon is replaced and index 0 becomes the
        //     second, still-renderable row.
        selectSidebarRow("allTracks")
        expect(karaokeRenderIcons.element(boundBy: 0), "a renderable library row should show the inline render icon")
        karaokeRenderIcons.element(boundBy: 0).click()
        expect(
            firstElement(labelContaining: karaokeRenderingLabel),
            "the first scheduled track should show the in-flight rendering ring"
        )

        // (b) Schedule the second fixture — it queues behind the held render and its row flips to
        //     the queued clock (`trackRow.karaokeDequeue`).
        karaokeRenderIcons.element(boundBy: 0).click()
        expect(karaokeDequeueIcons.element(boundBy: 0), "the pending track's row should show the queued clock")
        snapshot("r-01-inflight-and-pending")

        // (c) The queue pane exposes Stop on the in-flight row and Start-now on the pending row;
        //     Stop then cancels the in-flight render. Reaching the pane needs the badged sidebar row.
        try openKaraokeQueuePaneOrSkip()
        expect(karaokeQueueStopButton, "the in-flight queue row should offer a Stop control")
        expect(karaokeQueueStartNowButton, "the pending queue row should offer a Start-now control")
        karaokeQueueStopButton.click()
        let stopCleared = wait(karaokeQueueStopButton, "exists == false", timeout: 10)
        XCTAssertTrue(stopCleared, "stopping should clear the in-flight row")
        snapshot("r-02-stopped")
    }

    /// Queued-badge dequeue (todo E), entirely in All Tracks — no queue-pane navigation, so this
    /// runs unconditionally. Schedules two fixtures while paused so both rows show the queued clock
    /// (`trackRow.karaokeDequeue`), then clicks the first clock and confirms that row leaves the
    /// queue: its inline render icon (`trackRow.karaokeRender`) returns while one queued clock stays.
    func testKaraokeQueuedIconDequeues() {
        launchApp(karaokeFake: true, startPaused: true, karaokeEnabledAtLaunch: true)
        expect(playerBar, timeout: 30, "the main window should finish loading")
        selectSidebarRow("allTracks")

        // Schedule BOTH fixtures inline (paused) ⇒ both rows flip to the queued clock.
        expect(karaokeRenderIcons.element(boundBy: 0), "a renderable library row should show the inline render icon")
        karaokeRenderIcons.element(boundBy: 0).click()
        expect(karaokeDequeueIcons.element(boundBy: 0), "the first scheduled row should flip to the queued clock")
        karaokeRenderIcons.element(boundBy: 0).click()
        expect(karaokeDequeueIcons.element(boundBy: 1), "the second scheduled row should flip to the queued clock")
        snapshot("d-01-both-queued")

        // Click the first row's queued clock ⇒ it leaves the queue: its inline render icon returns
        // and exactly one queued clock remains.
        karaokeDequeueIcons.element(boundBy: 0).click()
        expect(karaokeRenderIcons.element(boundBy: 0), "dequeuing a track should restore its inline render icon")
        XCTAssertTrue(
            wait(karaokeDequeueIcons.element(boundBy: 1), "exists == false", timeout: 10),
            "only one track should remain queued after dequeuing the other"
        )
        snapshot("d-02-one-dequeued")
    }

    /// The cap picker is shown only while pruning is on: it is visible with pruning enabled,
    /// disappears when pruning is turned off, and returns when it is re-enabled (todo 10).
    func testKaraokePruneToggleControlsCapPicker() {
        launchApp(karaokeFake: true)
        expect(playerBar, timeout: 30, "the main window should finish loading")

        openSettings()
        selectPreferencesTab(karaokeTabTitle)
        expect(element("preferences.karaoke.toggle"), "the Karaoke preferences pane should load")

        // Pruning is forced ON at launch ⇒ the "Maximum size" cap picker is visible.
        expect(capPicker, timeout: 10, "with pruning on, the cap picker should be visible")

        // Pruning OFF ⇒ the cap picker is removed from the pane. The prune section sits below the
        // window fold, so scroll it into view before clicking.
        expect(pruneToggle, timeout: 10, "the '\(pruneToggleLabel)' toggle should be reachable")
        revealInSettings(pruneToggle)
        pruneToggle.click()
        XCTAssertTrue(wait(capPicker, "exists == false", timeout: 10), "pruning off should hide the cap picker")
        snapshot("06-prune-off")

        // Pruning ON again ⇒ the cap picker reappears.
        revealInSettings(pruneToggle)
        pruneToggle.click()
        expect(capPicker, timeout: 10, "pruning back on should show the cap picker again")
        snapshot("07-prune-on")

        closeSettingsWindow()
    }

    /// Failure mode: launched WITHOUT `UITEST_KARAOKE_FAKE` and with no bundled model, enabling
    /// the setting surfaces the button in `.disabled` (present but NOT enabled) — the unified
    /// model-not-bundled path (CI / fresh clone / iOS).
    func testKaraokeButtonDisabledWithoutModelStaysInert() throws {
        // A dev machine with the converted model in `macOS/Resources/SeparationModel/` bundles it
        // into the UITest host app, so the "model-less ⇒ disabled" premise only holds where that
        // git-ignored directory is absent (CI / fresh clones).
        try XCTSkipIf(
            Self.repoBundlesSeparationModel,
            "separation model bundled locally — the model-less disabled path is CI-only"
        )
        launchApp(karaokeFake: false)
        expect(playerBar, timeout: 30, "the main window should finish loading")

        XCTAssertFalse(anyKaraokeButtonExists, "the karaoke button must be hidden while the setting is off")
        setKaraokeSetting(enabled: true)

        let disabled = karaokeButton(.disabled)
        expect(disabled, "the disabled karaoke button is present in every visible state")
        XCTAssertFalse(disabled.isEnabled, "without a bundled model the separator is unavailable, so it is inert")
        snapshot("08-disabled-no-model")
    }
}

// MARK: - Steps

private extension KaraokeFlowTests {
    /// Plays the seeded fixture track via the library table's double-click primary action so the
    /// coordinator gains a present `current` track (the precondition for render + engage).
    func playFixtureTrack() {
        selectSidebarRow("allTracks")
        let track = app.staticTexts[fixtureTrack]
        expect(track, "the seeded track should be listed in All Tracks")
        track.doubleClick()
        expect(app.buttons[transportPauseLabel], timeout: 10, "double-clicking the track should start playback")
    }

    /// Toggles the karaoke enable switch in Preferences ▸ **Karaoke** (todo 10 relocated it off
    /// the Playback tab), then closes the window.
    func setKaraokeSetting(enabled: Bool) {
        openSettings()
        selectPreferencesTab(karaokeTabTitle)
        let toggle = element("preferences.karaoke.toggle")
        expect(toggle, "the karaoke settings toggle should be reachable")
        if toggleIsOn(toggle) != enabled {
            toggle.click()
        }
        closeSettingsWindow()
    }
}
