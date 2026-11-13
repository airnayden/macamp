// ReanalyzeCrashUITests — the C6 crash regression, driven through the pane that
// produced it.
//
// The crash was a SIGBUS inside mpg123's process-global first init, reached when
// `startFullReanalysis` fanned seven-plus concurrent extractions at a cold library.
// Todo 1 fixed it with a serial warm-up plus an analysis-scoped decoder-open gate and
// pinned the INVARIANT in `DecodingTests` (observed max-concurrent-inside-open == 1),
// which is the assertion that belongs in a package suite. This suite is the other
// half, deferred from todo 1 because it needs two things that did not exist then: a
// library of REAL audio files (`UITEST_SEED_REAL_AUDIO_DIR`) and a UITests target that
// compiles new files (todo 5's buildable-folder conversion).
//
// ── WHAT IT ASSERTS, AND WHY IT IS NOT A "DOES NOT CRASH" TEST ───────────────
//
// A bare "the process is alive" check passes on a build where the pass never started.
// So the run is gated on the pass actually STARTING (running controls, or a coverage
// figure that moved), on it RETURNING TO IDLE, and only then on the app still being
// frontmost. The fixture deliberately includes one corrupt file, so the same run also
// exercises the failure path: an unreadable file is counted and skipped, and the pass
// still completes.
//
// XCUITest only initializes in an on-console GUI session; this suite is run under the
// todo-15 precondition protocol and is excluded from the required CI job.
import XCTest

final class ReanalyzeCrashUITests: XCTestCase {
    private var app: XCUIApplication!
    private var seedPath: String!
    private var audioPath: String!
    private var runID: String!

    private static let intelligenceKey = "com.example.macamp.settings.ai.intelligenceEnabled"
    /// Enough files that the pass really fans out past `concurrencyCap`, which is what
    /// the original crash needed.
    private static let audioFileCount = 50

    override func setUpWithError() throws {
        continueAfterFailure = false
        let identifier = UUID().uuidString
        runID = identifier
        seedPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("macamp-reanalyze-uitest-\(identifier)")
        audioPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("macamp-reanalyze-audio-\(identifier)")
        app = XCUIApplication()
        app.launchEnvironment["UITEST_SEED_PATH"] = seedPath
        app.launchEnvironment["UITEST_RUN_ID"] = identifier
        app.launchEnvironment["UITEST_SEED_REAL_AUDIO_DIR"] = audioPath
        app.launchArguments += ["-\(Self.intelligenceKey)", Self.xmlPlistBool(true)]
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
        if let seedPath { try? FileManager.default.removeItem(atPath: seedPath) }
        if let audioPath { try? FileManager.default.removeItem(atPath: audioPath) }
        if let runID { UserDefaults().removePersistentDomain(forName: "com.example.macamp.uitest.\(runID)") }
    }

    func testReanalyzingARealMP3LibraryCompletesWithoutCrashing() throws {
        try buildAudioFixture()
        app.launch()
        openIntelligencePane()

        let coverage = element("intelligence.analysisCoverage")
        XCTAssertTrue(coverage.waitForExistence(timeout: 60), "the Intelligence pane should report library coverage")
        let before = coverage.value as? String ?? ""

        startReanalysis()
        XCTAssertTrue(
            waitUntil("the re-analyze pass starts", timeout: 120) {
                self.element("intelligence.analysisStop").exists || (coverage.value as? String ?? "") != before
            },
            "confirming the destructive dialog should start a pass"
        )
        XCTAssertTrue(
            waitUntil("the re-analyze pass finishes", timeout: 600) {
                self.element("intelligence.analysisRescan").exists
                    && !self.element("intelligence.analysisStop").exists
            },
            "the pass should return the section to idle"
        )
        XCTAssertEqual(app.state, .runningForeground, "the app must survive a full re-analyze")
        snap("t15d-reanalyze-complete")

        reopenIntelligencePane()
        let refreshed = element("intelligence.analysisCoverage")
        XCTAssertTrue(refreshed.waitForExistence(timeout: 60), "the reopened pane should report coverage")
        XCTAssertNotEqual(
            refreshed.value as? String ?? "",
            before,
            "a completed pass must have written analysis rows, not silently done nothing"
        )
        snap("t15d-reanalyze-coverage")
    }
}

// MARK: - Fixture

private extension ReanalyzeCrashUITests {
    /// Fifty real copies of the repo's `tone.mp3`, plus one file that is not audio at
    /// all — the failure path todo 1's package suite pins, exercised here end to end.
    func buildAudioFixture() throws {
        let directory = URL(fileURLWithPath: audioPath, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("PlayerCore/Tests/DecodingTests/Fixtures/tone.mp3")
        for index in 0 ..< Self.audioFileCount {
            let name = String(format: "tone-%03d.mp3", index)
            try FileManager.default.copyItem(at: source, to: directory.appendingPathComponent(name))
        }
        // Sorts last, so the fifty real ids stay contiguous from 3.
        try Data("this is not an MPEG frame".utf8)
            .write(to: directory.appendingPathComponent("zz-corrupt.mp3"))
    }
}

// MARK: - Driving the pane

private extension ReanalyzeCrashUITests {
    func openIntelligencePane() {
        app.typeKey(",", modifierFlags: .command)
        selectIntelligenceTab()
    }

    func reopenIntelligencePane() {
        app.typeKey("w", modifierFlags: .command)
        openIntelligencePane()
    }

    func selectIntelligenceTab() {
        app.selectSettingsSection("intelligence")
    }

    func startReanalysis() {
        let rescan = element("intelligence.analysisRescan")
        XCTAssertTrue(rescan.waitForExistence(timeout: 60), "the pane should offer Re-analyze Library")
        rescan.click()
        let confirm = element("intelligence.analysisRescanConfirm")
        XCTAssertTrue(confirm.waitForExistence(timeout: 30), "Re-analyze should be behind a destructive confirmation")
        confirm.click()
    }
}

// MARK: - Queries and waiting

private extension ReanalyzeCrashUITests {
    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func waitUntil(_ description: String, timeout: TimeInterval, _ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        expectation.expectationDescription = description
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    static func xmlPlistBool(_ value: Bool) -> String {
        let literal = value ? "true" : "false"
        return """
        <?xml version="1.0" encoding="UTF-8"?>\
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\
        <plist version="1.0"><\(literal)/></plist>
        """
    }
}
