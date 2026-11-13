import Foundation
import Testing
@testable import ViewModels

/// Data-model contract for the sidebar destination wrapper (Task 6). The fixed
/// sections must stay reachable through `.fixed`, and the wrapper must round-trip
/// through `Codable` with a stable, tagged wire format plus a backward-compatible
/// path for legacy bare `LibrarySection` raw values (so persisted selections
/// survive app updates).
struct SidebarDestinationTests {
    // MARK: Fixed-section coverage

    @Test func allFixedSectionsAreReachableViaFixed() {
        let destinations = LibrarySection.allCases.map(SidebarDestination.fixed)
        #expect(destinations.count == 12)
        #expect(Set(destinations).count == 12) // every wrapped section is distinct
        for section in LibrarySection.allCases {
            #expect(SidebarDestination.fixed(section) == .fixed(section))
        }
    }

    @Test func fixedSectionRawValuesAreStable() {
        #expect(LibrarySection.allTracks.rawValue == "allTracks")
        #expect(LibrarySection.albums.rawValue == "albums")
        #expect(LibrarySection.artists.rawValue == "artists")
        #expect(LibrarySection.favourites.rawValue == "favourites")
        #expect(LibrarySection.lyrics.rawValue == "lyrics")
        #expect(LibrarySection.playlists.rawValue == "playlists")
        #expect(LibrarySection.stats.rawValue == "stats")
        #expect(LibrarySection.queue.rawValue == "queue")
        #expect(LibrarySection.karaoke.rawValue == "karaoke")
        #expect(LibrarySection.karaokeQueue.rawValue == "karaokeQueue")
        #expect(LibrarySection.assistant.rawValue == "assistant")
        #expect(LibrarySection.downloads.rawValue == "downloads")
    }

    // MARK: Equality + hashing

    @Test func equalityDistinguishesCasesAndPayloads() {
        #expect(SidebarDestination.fixed(.allTracks) == .fixed(.allTracks))
        #expect(SidebarDestination.fixed(.allTracks) != .fixed(.albums))
        #expect(SidebarDestination.folder(rootId: 1) == .folder(rootId: 1))
        #expect(SidebarDestination.folder(rootId: 1) != .folder(rootId: 2))
        #expect(SidebarDestination.fixed(.allTracks) != .folder(rootId: 1))
    }

    @Test func hashableDeduplicatesInASet() {
        let set: Set<SidebarDestination> = [
            .fixed(.allTracks), .fixed(.allTracks), .fixed(.albums),
            .folder(rootId: 7), .folder(rootId: 7), .folder(rootId: 9),
        ]
        #expect(set.count == 4)
    }

    @Test func identityIsStableAndUniqueAcrossCases() {
        #expect(SidebarDestination.fixed(.albums).id == "fixed.albums")
        #expect(SidebarDestination.folder(rootId: 42).id == "folder.42")
        #expect(SidebarDestination.fixed(.albums).id != SidebarDestination.folder(rootId: 42).id)
    }

    // MARK: Codable round-trips

    @Test func everyFixedCaseRoundTripsThroughCodable() throws {
        for section in LibrarySection.allCases {
            let original = SidebarDestination.fixed(section)
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(SidebarDestination.self, from: data)
            #expect(decoded == original)
        }
    }

    @Test func folderCaseRoundTripsThroughCodable() throws {
        let original = SidebarDestination.folder(rootId: 1_234_567_890_123)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SidebarDestination.self, from: data)
        #expect(decoded == original)
    }

    // MARK: Stable wire format (persisted selections must survive app updates)

    @Test func fixedEncodesWithStableTaggedKeys() throws {
        let data = try JSONEncoder().encode(SidebarDestination.fixed(.albums))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let unwrapped = try #require(object)
        #expect(unwrapped["kind"] as? String == "fixed")
        #expect(unwrapped["section"] as? String == "albums")
    }

    @Test func folderEncodesWithStableTaggedKeys() throws {
        let data = try JSONEncoder().encode(SidebarDestination.folder(rootId: 42))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let unwrapped = try #require(object)
        #expect(unwrapped["kind"] as? String == "folder")
        #expect(unwrapped["rootId"] as? Int == 42)
    }

    // MARK: Backward compatibility (legacy bare LibrarySection raw value)

    @Test func decodesLegacyBareRawValueAsFixed() throws {
        let legacy = Data("\"albums\"".utf8)
        let decoded = try JSONDecoder().decode(SidebarDestination.self, from: legacy)
        #expect(decoded == .fixed(.albums))
    }

    @Test func decodesUnknownLegacyRawValueAsAllTracksFallback() throws {
        let legacy = Data("\"totally-unknown\"".utf8)
        let decoded = try JSONDecoder().decode(SidebarDestination.self, from: legacy)
        #expect(decoded == .fixed(.allTracks))
    }

    @Test func decodesUnknownFixedSectionAsAllTracksFallback() throws {
        let payload = Data(#"{"kind":"fixed","section":"bogus"}"#.utf8)
        let decoded = try JSONDecoder().decode(SidebarDestination.self, from: payload)
        #expect(decoded == .fixed(.allTracks))
    }

    // MARK: Frozen compatibility — a NEW section survives an OLD build (Todo 11)

    /// `.lyrics` reuses the existing `fixed` envelope — no new `kind`, no schema
    /// change — which is what lets an older build fall back instead of failing.
    @Test func lyricsEncodesWithStableTaggedKeys() throws {
        let data = try JSONEncoder().encode(SidebarDestination.fixed(.lyrics))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let unwrapped = try #require(object)
        #expect(unwrapped["kind"] as? String == "fixed")
        #expect(unwrapped["section"] as? String == "lyrics")
    }

    /// `.queue` likewise reuses the existing `fixed` envelope (Todo 13) — the
    /// manual queue moved from a right-panel tab to a sidebar section, and the
    /// selection must persist across relaunch under its own stable tag.
    @Test func queueEncodesWithStableTaggedKeys() throws {
        let data = try JSONEncoder().encode(SidebarDestination.fixed(.queue))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let unwrapped = try #require(object)
        #expect(unwrapped["kind"] as? String == "fixed")
        #expect(unwrapped["section"] as? String == "queue")
    }

    @Test func queueRoundTripsAndIsUnaffectedByKaraokeAvailability() throws {
        let original = SidebarDestination.fixed(.queue)
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(SidebarDestination.self, from: data) == original)
        #expect(original.resolvedForKaraokeAvailability(false) == original)
        #expect(original.systemImage == "list.bullet")
        #expect(!original.showsLibraryBrowser)
    }

    /// An OLD build reading a NEWER build's persisted selection: the section raw
    /// value it does not recognize falls back to All Tracks, and — crucially — the
    /// stored bytes are NOT rewritten, so switching back to the new build restores
    /// the original selection intact. `"aFutureSection"` stands in for `"lyrics"`
    /// seen by a build that predates it (this build cannot un-know its own case).
    @Test func unrecognizedSectionFallsBackWithoutRewritingStoredBytes() throws {
        let stored = Data(#"{"kind":"fixed","section":"aFutureSection"}"#.utf8)
        let snapshot = stored

        let decoded = try JSONDecoder().decode(SidebarDestination.self, from: stored)

        #expect(decoded == .fixed(.allTracks))
        #expect(stored == snapshot)
        // The fallback is a READ-side coercion only: re-encoding the decoded value
        // would persist "allTracks" and destroy the selection, so nothing may write
        // it back. Proven by the two payloads differing.
        let reencoded = try JSONEncoder().encode(decoded)
        #expect(reencoded != stored)
    }

    // MARK: Wrapper-derived properties

    @Test func showsLibraryBrowserMatchesSectionAndIsTrueForFolders() {
        #expect(SidebarDestination.fixed(.allTracks).showsLibraryBrowser)
        #expect(!SidebarDestination.fixed(.albums).showsLibraryBrowser)
        #expect(!SidebarDestination.fixed(.artists).showsLibraryBrowser)
        #expect(!SidebarDestination.fixed(.assistant).showsLibraryBrowser)
        #expect(SidebarDestination.folder(rootId: 1).showsLibraryBrowser)
    }

    @Test func systemImageDelegatesToSectionAndFoldersUseFolderGlyph() {
        #expect(SidebarDestination.fixed(.allTracks).systemImage == "music.note")
        #expect(SidebarDestination.fixed(.albums).systemImage == "square.stack")
        #expect(SidebarDestination.fixed(.playlists).systemImage == "music.note.list")
        #expect(SidebarDestination.fixed(.assistant).systemImage == "sparkles")
        #expect(SidebarDestination.folder(rootId: 1).systemImage == "folder")
    }

    // MARK: Karaoke availability dangle guard (Task 14)

    @Test func karaokeResolvesToAllTracksWhenUnavailable() {
        #expect(SidebarDestination.fixed(.karaoke).resolvedForKaraokeAvailability(false) == .fixed(.allTracks))
    }

    @Test func karaokeSurvivesWhenAvailable() {
        #expect(SidebarDestination.fixed(.karaoke).resolvedForKaraokeAvailability(true) == .fixed(.karaoke))
    }

    @Test func karaokeQueueResolvesToAllTracksWhenUnavailable() {
        #expect(SidebarDestination.fixed(.karaokeQueue).resolvedForKaraokeAvailability(false) == .fixed(.allTracks))
    }

    @Test func karaokeQueueSurvivesWhenAvailable() {
        #expect(SidebarDestination.fixed(.karaokeQueue).resolvedForKaraokeAvailability(true) == .fixed(.karaokeQueue))
    }

    @Test func nonKaraokeDestinationsAreUnaffectedByKaraokeAvailability() {
        #expect(SidebarDestination.fixed(.allTracks).resolvedForKaraokeAvailability(false) == .fixed(.allTracks))
        #expect(SidebarDestination.fixed(.albums).resolvedForKaraokeAvailability(false) == .fixed(.albums))
        #expect(SidebarDestination.folder(rootId: 3).resolvedForKaraokeAvailability(false) == .folder(rootId: 3))
        #expect(SidebarDestination.playlist(id: 5).resolvedForKaraokeAvailability(false) == .playlist(id: 5))
    }
}
