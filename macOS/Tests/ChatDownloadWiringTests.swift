// ChatDownloadWiringTests — the orderings that only the COMPOSITION can get wrong.
//
// Every test here drives the closures `connectDownloads(settings:)` installed, never a
// hand-assembled pipeline: the pieces are already covered by `PlayerCore`'s own suites,
// and the defects this file exists for are all installation-order defects that a
// piece-level test keeps passing through. See `+Support.swift` for the rig.
//
// The two headline locks:
//
//   * SUPPRESSION — a registered download must be scanned ONCE and must not raise the
//     legacy "added to your library" toast. With auto-import on, a chained-but-not-
//     routing handler would scan twice and say it twice.
//   * ORDERING — the driver publishes the terminal `onItemProgress(.finished)` BEFORE
//     `onItemFinished`. If the progress chain claimed on that state, the finished route
//     would find an empty registry, return `false`, and the legacy importer would
//     swallow the primary success path in silence.
import Foundation
@testable import MacAMP
import Persistence
import Services
import Testing
import ViewModels

@Suite("Chat download wiring", .serialized)
@MainActor
struct ChatDownloadWiringTests {
    // MARK: - Suppression

    @Test("a REGISTERED finished download is scanned once and raises no legacy toast")
    func registeredDownloadScansOnceAndStaysQuiet() async throws {
        let harness = try ChatDownloadWiringHarness(autoImport: true)
        defer { harness.cleanUp() }
        let playlistId = try harness.makePlaylist(named: "Suppression")
        let file = try harness.importedTrack(named: "Registered [\(ChatDownloadFixtureIDs.first)].m4a")
        harness.registry.register(
            videoID: ChatDownloadFixtureIDs.first,
            target: .playlist(playlistId),
            profileId: ProfileRecord.guestID
        )
        let item = try harness.item(ChatDownloadFixtureIDs.first)

        await harness.finish(item, at: file.url)

        #expect(harness.scanner.fileScanCount == 1)
        #expect(try await harness.membership(playlistId: playlistId) == [file.trackId])
        #expect(harness.activeToastText != harness.legacyImportedToast)
        #expect(harness.registry.count == 0)
    }

    /// The other half of the lock: an unregistered id must keep today's behaviour, or
    /// the routing parameter would have broken every ordinary download.
    @Test("an UNREGISTERED finished download still imports and still says so")
    func unregisteredDownloadKeepsTodaysBehaviour() async throws {
        let harness = try ChatDownloadWiringHarness(autoImport: true)
        defer { harness.cleanUp() }
        let file = try harness.importedTrack(named: "Plain [\(ChatDownloadFixtureIDs.second)].m4a")
        let item = try harness.item(ChatDownloadFixtureIDs.second)

        await harness.finish(item, at: file.url)
        await harness.waitUntil { harness.activeToastText == harness.legacyImportedToast }

        #expect(harness.scanner.fileScanCount == 1)
        #expect(harness.activeToastText == harness.legacyImportedToast)
    }

    // MARK: - Ordering

    /// `settle` emits the terminal progress state first in production, so the suite
    /// emits it first too. `.finished` classifies `.ignore`, which must touch NEITHER
    /// the registry nor the map.
    @Test("the terminal .finished progress state arriving FIRST still leaves the append to the route")
    func terminalFinishedBeforeTheFinishedSeamStillAppends() async throws {
        let harness = try ChatDownloadWiringHarness(autoImport: true)
        defer { harness.cleanUp() }
        let playlistId = try harness.makePlaylist(named: "Ordering")
        let file = try harness.importedTrack(named: "Ordered [\(ChatDownloadFixtureIDs.first)].m4a")
        harness.registry.register(
            videoID: ChatDownloadFixtureIDs.first,
            target: .playlist(playlistId),
            profileId: ProfileRecord.guestID
        )
        let item = try harness.item(ChatDownloadFixtureIDs.first)
        await harness.publishPending([item])

        await harness.emitProgress(item.id, .finished(fileURL: file.url))
        await harness.finish(item, at: file.url)

        #expect(harness.scanner.fileScanCount == 1)
        #expect(try await harness.membership(playlistId: playlistId) == [file.trackId])
        #expect(harness.activeToastText != harness.legacyImportedToast)
    }

    // MARK: - Terminal failure through the installed chain

    @Test("a terminal .failed for a registered id evicts it and says so exactly once")
    func terminalFailureEvictsAndAnnouncesOnce() async throws {
        let harness = try ChatDownloadWiringHarness(autoImport: true)
        defer { harness.cleanUp() }
        let playlistId = try harness.makePlaylist(named: "Abandoned")
        harness.registry.register(
            videoID: ChatDownloadFixtureIDs.first,
            target: .playlist(playlistId),
            profileId: ProfileRecord.guestID
        )
        let item = try harness.item(ChatDownloadFixtureIDs.first)
        await harness.publishPending([item])

        await harness.emitProgress(item.id, .failed(.toolMissing))

        #expect(harness.registry.count == 0)
        #expect(harness.activeToastText == String(localized: MacAMPStrings.chatDownloadAbandonedToast))
        #expect(harness.scanner.fileScanCount == 0)
    }

    /// A cancellation is the listener's own doing. It evicts, and says nothing.
    @Test("a cancelled download evicts silently")
    func cancellationEvictsSilently() async throws {
        let harness = try ChatDownloadWiringHarness(autoImport: true)
        defer { harness.cleanUp() }
        harness.registry.register(
            videoID: ChatDownloadFixtureIDs.first,
            target: .playlist(1),
            profileId: ProfileRecord.guestID
        )
        let item = try harness.item(ChatDownloadFixtureIDs.first)
        await harness.publishPending([item])

        await harness.emitProgress(item.id, .cancelled)

        #expect(harness.registry.count == 0)
        #expect(harness.activeToastText == nil)
    }

    // MARK: - Interleave

    /// Claim-in-route is what makes the discard / chat-reset interleave harmless: the
    /// registrations were already taken out of the registry before the Task ran, so
    /// emptying it afterwards cannot cancel an append that was already decided.
    @Test("emptying the registry after the claim but before the appender runs still appends")
    func emptyingTheRegistryAfterTheClaimStillAppends() async throws {
        let harness = try ChatDownloadWiringHarness(autoImport: true)
        defer { harness.cleanUp() }
        let playlistId = try harness.makePlaylist(named: "Interleave")
        let file = try harness.importedTrack(named: "Interleaved [\(ChatDownloadFixtureIDs.first)].m4a")
        harness.registry.register(
            videoID: ChatDownloadFixtureIDs.first,
            target: .playlist(playlistId),
            profileId: ProfileRecord.guestID
        )
        let item = try harness.item(ChatDownloadFixtureIDs.first)

        // The seam is synchronous, so this runs after the claim and before the appender
        // Task the route queued has had a chance to execute.
        harness.seams.onItemFinished?(item, file.url)
        harness.registry.removeAll()
        await harness.environment.drainChatDownloadWork()

        #expect(try await harness.membership(playlistId: playlistId) == [file.trackId])
        #expect(harness.scanner.fileScanCount == 1)
    }
}
