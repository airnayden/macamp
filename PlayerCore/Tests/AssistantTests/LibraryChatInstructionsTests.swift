// LibraryChatInstructionsTests — the tier split, asserted on BYTES rather than on
// intent.
//
// ── WHY SUBSTRINGS AND NOT "IT LOOKS RIGHT" ──────────────────────────────────
//
// The failure this split can have is one cloud-only line reaching the on-device
// window. That window has tens of tokens of headroom above the shipped prefix, and
// overrunning it does not throw — the session simply starts condensing its
// transcript on turn one, forever, which reads as a model that forgets rather than
// as a bug. `LibraryChatToolBudgetTests` prices the overrun; this suite is what
// says WHICH line caused it, and it is ungated so it runs on every host (the string
// is pure Foundation — no SDK, no Apple Intelligence, no macOS 26).
//
// The disjointness assertions are structural where they can be — on-device is a
// strict line-subset of cloud, and the web flag is a byte no-op on-device — so a
// reworded sentence does not fail a test that was never about its wording. The
// handful of literal substrings are the four claims the plan makes by name.
import Foundation
import Services
import Testing

@Suite("LibraryChat instructions")
struct LibraryChatInstructionsTests {
    private static let locale = Locale(identifier: "en_US")

    private static func text(
        _ profile: ToolProfile,
        canControlPlayback: Bool = false,
        webWorkflowEnabled: Bool = false,
        musicKnowledgeEnabled: Bool = false
    ) -> String {
        LibraryChatInstructions.text(
            locale: locale,
            profile: profile,
            canControlPlayback: canControlPlayback,
            webWorkflowEnabled: webWorkflowEnabled,
            musicKnowledgeEnabled: musicKnowledgeEnabled
        )
    }

    /// The same tier with every flag this function takes turned on.
    private static func everything(_ profile: ToolProfile) -> String {
        text(profile, canControlPlayback: true, webWorkflowEnabled: true, musicKnowledgeEnabled: true)
    }

    /// The cloud-only claims, by the fragment each is recognised by.
    private static let countAdherence = "as few lookups as possible"
    private static let playlistWorkflow = "call propose_playlist with target_count"
    private static let listFormatting = "Do not paste track lists into your prose"
    private static let webFragments = [
        "web_search", "mcp__", "match_tracks", "missing locally as links", "no web tool",
    ]
    /// The web fragments that ONLY the web block can produce. `match_tracks` is
    /// excluded because the knowledge permission names it too — verification through
    /// the library is the whole point of that line — so it is not evidence about
    /// which gate emitted what.
    private static let webOnlyFragments = webFragments.filter { $0 != "match_tracks" }
    /// The two music-knowledge sentences, by the fragment each is recognised by.
    private static let knowledgeFragments = ["your own knowledge of music", "General music questions"]
    /// The grounding rule's library SCOPE — the carve-out that lets the permission
    /// above and the prohibition coexist in one prompt.
    private static let libraryScopedInvention = "never invent a title or an artist as being in this library"

    // MARK: - On-device

    @Test("The on-device tier states the requested-count rule")
    func onDeviceCarriesTheCountSentence() {
        #expect(Self.text(.onDevice).contains("propose exactly that many"))
        #expect(Self.text(.onDevice).contains("say how many you found"))
    }

    @Test("The on-device tier carries none of the cloud-only guidance")
    func onDeviceOmitsTheRichLines() {
        let onDevice = Self.text(.onDevice, canControlPlayback: true, webWorkflowEnabled: true)
        #expect(!onDevice.contains(Self.countAdherence))
        #expect(!onDevice.contains(Self.playlistWorkflow))
        #expect(!onDevice.contains(Self.listFormatting))
        for fragment in Self.webFragments {
            #expect(!onDevice.contains(fragment), "cloud-only web fragment '\(fragment)' reached the on-device window")
        }
    }

    @Test("The on-device string is a strict line-subset of the cloud string")
    func onDeviceIsASubsetOfCloud() {
        let onDevice = Self.text(.onDevice).split(separator: "\n")
        let cloud = Set(Self.text(.cloud).split(separator: "\n"))
        #expect(onDevice.allSatisfy(cloud.contains))
        #expect(cloud.count > onDevice.count)
    }

    @Test("The subset holds with every flag on, LINE BY LINE rather than by length")
    func onDeviceIsASubsetOfCloudUnderEveryFlag() {
        let onDevice = Set(Self.everything(.onDevice).split(separator: "\n"))
        let cloud = Set(Self.everything(.cloud).split(separator: "\n"))
        // The ACTUAL line sets, not their counts: a cloud string built from
        // DIFFERENT sentences would satisfy any length comparison while having
        // silently reworded a line the on-device window still ships.
        #expect(onDevice.subtracting(cloud).isEmpty)
        #expect(cloud.isStrictSuperset(of: onDevice))
    }

    @Test("The music-knowledge flag is a byte no-op on-device, whatever else is set")
    func musicKnowledgeIsInertOnDevice() {
        #expect(Self.text(.onDevice, musicKnowledgeEnabled: true) == Self.text(.onDevice))
        #expect(Self.everything(.onDevice) == Self.text(.onDevice, canControlPlayback: true))
    }

    @Test("The on-device window never learns the knowledge permission, nor the web tool's name")
    func onDeviceOmitsTheKnowledgeLines() {
        let onDevice = Self.everything(.onDevice)
        #expect(!onDevice.contains("web_search"))
        for fragment in Self.knowledgeFragments {
            #expect(!onDevice.contains(fragment), "knowledge fragment '\(fragment)' reached the on-device window")
        }
    }

    // MARK: - Cloud

    @Test("The cloud tier adds lookup efficiency, the playlist workflow and the list-formatting rule")
    func cloudCarriesTheRichLines() {
        let cloud = Self.text(.cloud)
        #expect(cloud.contains(Self.countAdherence))
        #expect(cloud.contains("up to 500"))
        #expect(cloud.contains("call list_genres"))
        #expect(cloud.contains(Self.playlistWorkflow))
        #expect(cloud.contains(Self.listFormatting))
        #expect(cloud.contains("Summarize in one sentence instead."))
        #expect(cloud.contains("Never repeat a lookup"))
        #expect(cloud.contains("end with one sentence"))
    }

    @Test("The external tier reads the same rich guidance as cloud")
    func externalMatchesCloud() {
        #expect(Self.text(.external) == Self.text(.cloud))
    }

    // MARK: - The music-knowledge gate

    @Test("With the gate on the cloud tier may draw on its own knowledge, and must verify it")
    func musicKnowledgeAppearsWhenGated() {
        let gated = Self.text(.cloud, musicKnowledgeEnabled: true)
        for fragment in Self.knowledgeFragments {
            #expect(gated.contains(fragment), "knowledge fragment '\(fragment)' is missing from the gated cloud text")
        }
        #expect(gated.contains("verify candidates with match_tracks before proposing"))
        #expect(gated.contains(Self.libraryScopedInvention))
        let plain = Self.text(.cloud, musicKnowledgeEnabled: false)
        #expect(plain.split(separator: "\n").allSatisfy(Set(gated.split(separator: "\n")).contains))
    }

    @Test("With both gates off not one new line is emitted, on any tier")
    func bothGatesOffEmitNothingNew() {
        for profile in ToolProfile.allCases {
            let text = Self.text(profile, canControlPlayback: true)
            for fragment in Self.knowledgeFragments + Self.webFragments {
                #expect(!text.contains(fragment), "'\(fragment)' leaked into \(profile) with both gates off")
            }
        }
    }

    @Test("The gate is the SETTING, not the presence of a web tool — neither flag implies the other")
    func theTwoGatesAreIndependent() {
        // A listener with an MCP server and the setting OFF must keep the strict
        // rules: gating the knowledge lines on `webWorkflowEnabled` would relax them
        // for exactly that person, silently.
        let webOnly = Self.text(.cloud, webWorkflowEnabled: true, musicKnowledgeEnabled: false)
        for fragment in Self.knowledgeFragments {
            #expect(!webOnly.contains(fragment), "'\(fragment)' followed the web tools rather than the setting")
        }
        let knowledgeOnly = Self.text(.cloud, webWorkflowEnabled: false, musicKnowledgeEnabled: true)
        for fragment in Self.webOnlyFragments {
            #expect(!knowledgeOnly.contains(fragment), "'\(fragment)' followed the setting rather than the web tools")
        }
    }

    // MARK: - The web-workflow flag

    @Test("With the flag off no web line is emitted, on any tier")
    func webWorkflowIsAbsentByDefault() {
        for profile in ToolProfile.allCases {
            let text = Self.text(profile, canControlPlayback: true)
            for fragment in Self.webFragments {
                #expect(!text.contains(fragment), "'\(fragment)' leaked into \(profile) with the flag off")
            }
        }
    }

    @Test("The flag is a byte no-op on-device, which never sees a web tool")
    func webWorkflowIsInertOnDevice() {
        #expect(Self.text(.onDevice, webWorkflowEnabled: true) == Self.text(.onDevice, webWorkflowEnabled: false))
    }

    @Test("With the flag on the cloud tier gets the web workflow, and only then")
    func webWorkflowAppearsWhenFlagged() {
        let flagged = Self.text(.cloud, webWorkflowEnabled: true)
        for fragment in Self.webFragments {
            #expect(flagged.contains(fragment), "web fragment '\(fragment)' is missing from the flagged cloud text")
        }
        let plain = Self.text(.cloud, webWorkflowEnabled: false)
        #expect(flagged.count > plain.count)
        #expect(plain.split(separator: "\n").allSatisfy(Set(flagged.split(separator: "\n")).contains))
    }

    // MARK: - The lines that did not move

    @Test("The playback-grant sentence stays conditional on both tiers")
    func controlLineStaysConditional() {
        for profile in ToolProfile.allCases {
            #expect(!Self.text(profile).contains("CALL play_tracks or transport"))
            #expect(Self.text(profile, canControlPlayback: true).contains("CALL play_tracks or transport"))
        }
    }

    @Test("Every tier still grounds the model, LIBRARY-SCOPED, and names the listener's locale")
    func groundingAndLocaleSurvive() {
        for profile in ToolProfile.allCases {
            let text = Self.text(profile)
            #expect(text.contains(Self.libraryScopedInvention))
            #expect(text.hasSuffix("The listener writes in en_US."))
        }
    }
}
