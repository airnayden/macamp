// The `.assistant` sidebar destination's persistence + dangle-guard contract.
//
// A separate file rather than more cases in `SidebarDestinationTests`: that struct
// body already sits close to SwiftLint's 250-line `type_body_length` ceiling, and
// the repo's established answer is a new `<Feature>Tests.swift` per feature.
//
// The DOWNGRADE path is what these cases exist for. `SidebarSelectionStore`
// (`macOS/Sources/Preferences/StateRestoration.swift`) persists a JSON-encoded
// `SidebarDestination`, so a build that predates `.assistant` will one day read
// bytes carrying it — and a build that ships it will read bytes written before it
// existed. Both directions must degrade to All Tracks instead of failing to decode.
import Foundation
import Testing
@testable import ViewModels

@Suite("Assistant sidebar destination")
struct SidebarDestinationAssistantTests {
    // MARK: Wire format

    /// `.assistant` reuses the existing `fixed` envelope — no new `kind`, no schema
    /// change — which is exactly what lets an older build fall back rather than fail.
    @Test func assistantEncodesWithStableTaggedKeys() throws {
        let data = try JSONEncoder().encode(SidebarDestination.fixed(.assistant))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let unwrapped = try #require(object)
        #expect(unwrapped["kind"] as? String == "fixed")
        #expect(unwrapped["section"] as? String == "assistant")
    }

    @Test func assistantRoundTripsThroughCodable() throws {
        let original = SidebarDestination.fixed(.assistant)
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(SidebarDestination.self, from: data) == original)
    }

    /// The literal bytes a UI test seeds into `UserDefaults` to stage a persisted
    /// assistant selection. Pinned here so the test harness and the encoder cannot
    /// drift apart without one of them failing.
    @Test func assistantDecodesFromTheHandWrittenPersistedPayload() throws {
        let stored = Data(#"{"kind":"fixed","section":"assistant"}"#.utf8)
        #expect(try JSONDecoder().decode(SidebarDestination.self, from: stored) == .fixed(.assistant))
    }

    // MARK: Decode fallback (both downgrade directions)

    /// Forward: every payload a build WITHOUT `.assistant` could have written still
    /// decodes to exactly the section it names. Adding a case must not disturb any
    /// previously persisted value.
    @Test func everyPreAssistantSectionStillDecodes() throws {
        let legacySections = [
            "allTracks", "albums", "artists", "favourites", "lyrics",
            "playlists", "stats", "queue", "karaoke", "karaokeQueue",
        ]
        for raw in legacySections {
            let stored = Data(#"{"kind":"fixed","section":"\#(raw)"}"#.utf8)
            let decoded = try JSONDecoder().decode(SidebarDestination.self, from: stored)
            #expect(decoded == .fixed(LibrarySection(rawValue: raw) ?? .allTracks))
            #expect(decoded != .fixed(.assistant))
        }
    }

    /// Backward: a section raw value this build does not know falls back to All
    /// Tracks. `"aFutureSection"` stands in for `"assistant"` read by a build that
    /// predates it — this build cannot un-know its own case.
    @Test func unknownSectionFallsBackToAllTracks() throws {
        let stored = Data(#"{"kind":"fixed","section":"aFutureSection"}"#.utf8)
        #expect(try JSONDecoder().decode(SidebarDestination.self, from: stored) == .fixed(.allTracks))
    }

    @Test func legacyBareRawValueStillDecodesAlongsideAssistant() throws {
        let bare = Data("\"assistant\"".utf8)
        #expect(try JSONDecoder().decode(SidebarDestination.self, from: bare) == .fixed(.assistant))
        let unknownBare = Data("\"totally-unknown\"".utf8)
        #expect(try JSONDecoder().decode(SidebarDestination.self, from: unknownBare) == .fixed(.allTracks))
    }

    // MARK: Dangle guard

    @Test func assistantResolvesToAllTracksWhenUnavailable() {
        #expect(SidebarDestination.fixed(.assistant).resolvedForAssistantAvailability(false) == .fixed(.allTracks))
    }

    @Test func assistantSurvivesWhenAvailable() {
        #expect(SidebarDestination.fixed(.assistant).resolvedForAssistantAvailability(true) == .fixed(.assistant))
    }

    @Test func nonAssistantDestinationsAreUnaffectedByAssistantAvailability() {
        #expect(SidebarDestination.fixed(.allTracks).resolvedForAssistantAvailability(false) == .fixed(.allTracks))
        #expect(SidebarDestination.fixed(.karaoke).resolvedForAssistantAvailability(false) == .fixed(.karaoke))
        #expect(SidebarDestination.folder(rootId: 3).resolvedForAssistantAvailability(false) == .folder(rootId: 3))
        #expect(SidebarDestination.playlist(id: 5).resolvedForAssistantAvailability(false) == .playlist(id: 5))
    }

    /// The two guards are independent: turning karaoke off must not evict an
    /// assistant selection, and turning Intelligence off must not evict a karaoke
    /// one. A merged guard would silently couple two unrelated toggles.
    @Test func theTwoAvailabilityGuardsDoNotOverlap() {
        let assistant = SidebarDestination.fixed(.assistant)
        let karaoke = SidebarDestination.fixed(.karaoke)
        #expect(assistant.resolvedForKaraokeAvailability(false) == assistant)
        #expect(karaoke.resolvedForAssistantAvailability(false) == karaoke)
    }
}
