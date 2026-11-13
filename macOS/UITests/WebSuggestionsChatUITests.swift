// WebSuggestionsChatUITests — the three listener-visible claims the web-suggestions
// and criteria-proposal work makes, driven end to end through the real UI.
//
// A class of its own rather than more of `AIChatE2EUITests`: that suite's harness is
// an extension on ITS class, so reuse would mean either a base class or moving the
// helpers, and both are larger changes than the three scenarios justify. The helpers
// below are the small subset these tests need, kept deliberately identical in
// behaviour to the originals — including reading `value` as well as `label`, which is
// the measured shape of SwiftUI's accessibility output on this platform.
//
// Like `uitest-smoke`, this suite is NON-REQUIRED: it does not gate merges or
// releases.
import XCTest

final class WebSuggestionsChatUITests: XCTestCase {
    var app: XCUIApplication!
    private var seedPath: String!
    private var audioPath: String!
    private var runID: String!

    private static let intelligenceKey = "com.example.macamp.settings.ai.intelligenceEnabled"
    private static let webEnabledKey = "com.example.macamp.settings.ai.webSuggestions.enabled"
    private static let webConsentedKey = "com.example.macamp.settings.ai.webSuggestions.consented"

    /// Duplicated from `ScriptedChatUITestSeam` and `RealAudioLibraryFixture` rather
    /// than imported: the UITest target links no app code.
    private static let criteriaGenre = "Scripted Criteria Genre"
    private static let criteriaPlaylistName = "Scripted Criteria 150"
    private static let truncationCaption = "Only the first tracks are listed here."

    override func setUpWithError() throws {
        continueAfterFailure = false
        let identifier = UUID().uuidString
        runID = identifier
        seedPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("macamp-websuggestions-\(identifier)")
        audioPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("macamp-websuggestions-audio-\(identifier)")
        app = XCUIApplication()
        app.launchEnvironment["UITEST_SEED_PATH"] = seedPath
        app.launchEnvironment["UITEST_RUN_ID"] = identifier
        app.launchArguments += ["-\(Self.intelligenceKey)", Self.xmlPlistBool(true)]
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
        if let seedPath { try? FileManager.default.removeItem(atPath: seedPath) }
        if let audioPath { try? FileManager.default.removeItem(atPath: audioPath) }
        if let runID {
            UserDefaults().removePersistentDomain(forName: "com.example.macamp.uitest.\(runID)")
        }
    }
}

// MARK: - (i) A criteria proposal draws the row cap, and says nothing about truncation

extension WebSuggestionsChatUITests {
    /// 150 materialised tracks: more than the preview's 100-row cap, and well under
    /// the 500-id proposal ceiling that is the ONLY thing the truncation caption
    /// speaks to. Its absence here is correct, not a missing string.
    func testCriteriaProposalOfOneHundredFiftyDrawsTheRowCapWithoutATruncationCaption() throws {
        try seedRealAudioLibrary(copies: 150, genre: Self.criteriaGenre)
        app.launchEnvironment["UITEST_CHAT_SCRIPT"] = "criteria150"
        app.launch()
        openAssistantPane()
        submitChat("make me a long playlist of that genre")

        let card = firstElement(withIdentifierPrefix: "assistant.chat.proposal.")
        XCTAssertTrue(
            card.waitForExistence(timeout: 120),
            "the materialised criteria proposal should reach the transcript as a card"
        )
        XCTAssertTrue(
            waitUntil("the card names the proposed playlist", timeout: 20) {
                Self.combinedText(card).contains(Self.criteriaPlaylistName)
            },
            "the card should name the proposal, got: \(Self.combinedText(card))"
        )
        snap("t12i-criteria-card")

        card.click()
        XCTAssertTrue(
            element("assistant.proposalList").waitForExistence(timeout: 30),
            "tapping the card should open the review sheet"
        )
        let rows = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "assistant.proposalTrack.")
        )
        XCTAssertTrue(
            waitUntil("the sheet finishes resolving its rows", timeout: 60) { rows.count == 100 },
            "the review sheet should draw exactly the 100-row preview cap, drew \(rows.count)"
        )
        XCTAssertTrue(
            waitUntil("the header states the whole membership", timeout: 20) {
                Self.combinedText(self.element("assistant.proposalSelectionCount")).contains("150")
            },
            "the header badge should still count all 150 proposed tracks"
        )
        XCTAssertFalse(
            containsText(Self.truncationCaption),
            "a 150-track proposal is under the 500-id ceiling, so no truncation caption may appear"
        )
        snap("t12i-criteria-preview")
    }
}

// MARK: - (ii) The on-device pointer, shown only when the grant is on

extension WebSuggestionsChatUITests {
    func testWebPointerBannerAppearsOnTheOnDeviceRouteWhenTheGrantIsOn() throws {
        try seedRealAudioLibrary(copies: 5, genre: nil)
        app.launchEnvironment["UITEST_CHAT_SCRIPT"] = "trackList"
        grantWebSuggestions()
        app.launch()
        openAssistantPane()

        let pointer = element("assistant.chat.webPointer")
        XCTAssertTrue(
            pointer.waitForExistence(timeout: 60),
            "with the grant on and the on-device tier answering, the pointer should explain why"
        )
        snap("t12ii-web-pointer")

        let dismiss = element("assistant.chat.webPointer.dismiss")
        XCTAssertTrue(dismiss.waitForExistence(timeout: 15), "the pointer should be dismissible")
        dismiss.click()
        XCTAssertTrue(
            waitUntil("the dismissed pointer leaves the pane", timeout: 20) { !pointer.exists },
            "dismissing the pointer should remove it"
        )
        snap("t12ii-web-pointer-dismissed")
    }
}

// MARK: - (iii) Both suggestion link kinds, told apart

extension WebSuggestionsChatUITests {
    /// The scripted enricher links the EVEN positions only, so one turn renders a
    /// verified video row beside a search fallback — the two claims the surface makes.
    func testSuggestionRowsRenderBothTheVerifiedVideoAndTheSearchFallback() throws {
        try seedRealAudioLibrary(copies: 5, genre: nil)
        app.launchEnvironment["UITEST_CHAT_SCRIPT"] = "webLinks"
        app.launch()
        openAssistantPane()
        submitChat("find me those two songs")

        let list = element("assistant.chat.suggestions.1.0")
        XCTAssertTrue(
            list.waitForExistence(timeout: 120),
            "two misses should render as a suggestion list beneath the lookup"
        )
        let video = element("assistant.chat.suggestions.1.0.link.video.0")
        XCTAssertTrue(
            video.waitForExistence(timeout: 30),
            "the enriched miss should render as a verified video link"
        )
        let search = element("assistant.chat.suggestions.1.0.link.search.1")
        XCTAssertTrue(
            search.waitForExistence(timeout: 30),
            "the unenriched miss should fall back to the search link this app builds"
        )
        XCTAssertFalse(
            element("assistant.chat.suggestions.1.0.link.search.0").exists,
            "position 0 carries a validated video, so it must not also draw a search row"
        )
        XCTAssertFalse(
            element("assistant.chat.suggestions.1.0.link.video.1").exists,
            "position 1 carries no link, so it must not claim a verified video"
        )
        snap("t12iii-suggestion-links")
    }
}

// MARK: - Fixtures

private extension WebSuggestionsChatUITests {
    /// Copies the repo's real `tone.mp3` fixture `copies` times and points the seeder
    /// at the result, optionally stamping one genre on every seeded row.
    func seedRealAudioLibrary(copies: Int, genre: String?) throws {
        let directory = URL(fileURLWithPath: audioPath, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = Self.repositoryRoot
            .appendingPathComponent("PlayerCore/Tests/DecodingTests/Fixtures/tone.mp3")
        for index in 0 ..< copies {
            let name = String(format: "tone-%03d.mp3", index)
            try FileManager.default.copyItem(at: source, to: directory.appendingPathComponent(name))
        }
        app.launchEnvironment["UITEST_SEED_REAL_AUDIO_DIR"] = audioPath
        if let genre { app.launchEnvironment["UITEST_SEED_REAL_AUDIO_GENRE"] = genre }
    }

    /// Both records, because the grant is their conjunction and neither implies the
    /// other — the same reason `AppSettings.webSuggestionsGrant` reads them apart.
    func grantWebSuggestions() {
        app.launchArguments += [
            "-\(Self.webEnabledKey)", Self.xmlPlistBool(true),
            "-\(Self.webConsentedKey)", Self.xmlPlistBool(true),
        ]
    }

    /// The repo root, walked from this file: `UITests` → `macOS` → root.
    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// A bare `NO` lands in the argument domain as an `NSTaggedPointerString`, which
    /// `AppSettings`' `object(forKey:) as? Bool` reads as `nil` — so a boolean default
    /// must be written as a full property list or it is silently inert.
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

// MARK: - Navigation

private extension WebSuggestionsChatUITests {
    func openAssistantPane() {
        let row = element("sidebar.row.assistant")
        XCTAssertTrue(row.waitForExistence(timeout: 120), "the Assistant sidebar row should exist")
        row.click()
        XCTAssertTrue(
            element("assistant.promptField").waitForExistence(timeout: 60),
            "selecting the Assistant row should show its request field"
        )
    }

    func submitChat(_ text: String) {
        type(text, into: "assistant.promptField", focusVia: "assistant.submitButton")
        element("assistant.submitButton").click()
    }

    /// Types into a field that cannot be focused by pointing at it — measured and
    /// recorded by `AIChatE2EUITests+Harness`: the assistant's prompt field is
    /// reachable only by clicking its key-view-loop SUCCESSOR and stepping back.
    func type(_ text: String, into identifier: String, focusVia successor: String) {
        let field = element(identifier)
        XCTAssertTrue(field.waitForExistence(timeout: 60), "\(identifier) should be on screen")
        for attempt in 0 ..< Self.focusAttempts {
            if attempt > 0 {
                app.typeKey("a", modifierFlags: .command)
                app.typeKey(.delete, modifierFlags: [])
            }
            field.click()
            let neighbour = element(successor)
            if neighbour.exists {
                neighbour.click()
                app.typeKey(.tab, modifierFlags: .shift)
            }
            app.typeText(text)
            if waitUntil("\(identifier) carries the typed text", timeout: 3, {
                (field.value as? String)?.contains(text) == true
            }) {
                return
            }
        }
        attachAccessibilityTree(named: "type-failure-\(identifier)")
        XCTFail("\(identifier) never accepted the typed text")
    }

    static let focusAttempts = 8
}

// MARK: - Queries and waiting

private extension WebSuggestionsChatUITests {
    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func firstElement(withIdentifierPrefix prefix: String) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", prefix)
        ).firstMatch
    }

    /// A bare `Text` publishes its string as the accessibility VALUE; a combined
    /// element with an explicit label publishes it as the LABEL. Reading one alone is
    /// how a correct surface fails a test.
    static func combinedText(_ element: XCUIElement) -> String {
        [element.label, element.value as? String ?? ""]
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
    }

    /// Whether any static text on screen carries `text`. Used for the ABSENCE
    /// assertion, which has no identifier of its own to query.
    func containsText(_ text: String) -> Bool {
        app.staticTexts.matching(
            NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", text, text)
        ).firstMatch.exists
    }

    func waitUntil(
        _ description: String,
        timeout: TimeInterval = 60,
        _ condition: @escaping () -> Bool
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in condition() },
            object: nil
        )
        expectation.expectationDescription = description
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func attachAccessibilityTree(named name: String) {
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
