// ChatDownloadRoutePolicyTests — the two-way switch at the finished seam, and the
// twelve-way table behind every sentence the listener reads.
//
// Both types under test are pure, so this suite needs no queue, no database and no
// temporary directory — the same trade `DownloadToastPolicyTests` makes for
// `DownloadImportAnnouncement`. The composition-level consequences (one scan, no legacy
// toast) are pinned separately in `ChatDownloadWiringTests`, which drives the real
// installed closures.
import Foundation
@testable import MacAMP
import Services
import Testing

@Suite("Chat download route policy")
struct ChatDownloadRoutePolicyTests {
    @Test("a claimed registration routes to the appender")
    func registeredRoutesToTheAppender() {
        #expect(ChatDownloadRoutePolicy.route(isRegistered: true) == .appender)
    }

    /// The default for every ordinary download, and for a registered one whose
    /// registration was evicted before the file landed — from the seam those are the
    /// same fact, and both must reach today's importer.
    @Test("an empty claim routes to the legacy importer")
    func unregisteredRoutesToLegacyImport() {
        #expect(ChatDownloadRoutePolicy.route(isRegistered: false) == .legacyImport)
    }

    @Test("the route is total: exactly two answers, and they never coincide")
    func theRouteIsTotal() {
        let answers = [true, false].map(ChatDownloadRoutePolicy.route(isRegistered:))
        #expect(Set(answers).count == 2)
    }
}

@Suite("Chat download toast decisions")
struct ChatDownloadToastDecisionTests {
    /// The two cases that render NOTHING, by design. `.heldForProposal` is an expected
    /// intermediate state whose summary arrives when the apply flushes it, and
    /// `.alreadyInPlaylist` reports that the desired end state already holds.
    @Test("held and already-a-member say nothing")
    func theTwoSilentCases() {
        #expect(ChatDownloadToastPolicy.decide(.heldForProposal(UUID())) == .silent)
        #expect(ChatDownloadToastPolicy.decide(.alreadyInPlaylist(playlistId: 7, trackId: 3)) == .silent)
    }

    @Test("an append is counted into its playlist's summary, never toasted on its own")
    func appendsAreCounted() {
        #expect(ChatDownloadToastPolicy.decide(.appended(playlistId: 42, trackId: 9)) == .summary(playlistId: 42))
    }

    @Test("the refused import gate earns the guidance sentence")
    func theGateEarnsGuidance() {
        #expect(ChatDownloadToastPolicy.decide(.gateFailed) == .gateGuidance)
    }

    /// Every remaining case gets its OWN sentence: they name different things that went
    /// wrong with different tracks, so collapsing them would invent a claim.
    @Test("the eight fault cases each map to their own distinct sentence")
    func theFaultsAreDistinct() {
        let table: [(ChatDownloadAppendEvent, ChatDownloadToastFault)] = [
            (.importFailed, .importFailed),
            (.playlistMissing(1), .playlistMissing),
            (.appendFailed(1), .appendFailed),
            (.skippedProfileChanged, .profileChanged),
            (.alreadyDownloadedUnresolved, .unresolved),
            (.appendAbandoned, .abandoned),
            (.queueFull(count: 3), .queueFull),
            (.notRegisteredNoPlaylist, .noPlaylist),
        ]
        for (event, expected) in table {
            #expect(ChatDownloadToastPolicy.decide(event) == .fault(expected))
        }
        #expect(table.count == ChatDownloadToastFault.allCases.count)
    }

    /// A fault whose copy resolved to an empty string would be a silent toast — the one
    /// failure shape a "never silent" policy cannot detect from its own decision.
    @Test("every fault resolves to real copy")
    func everyFaultHasCopy() {
        for fault in ChatDownloadToastFault.allCases {
            #expect(!String(localized: fault.message).isEmpty)
            #expect(!fault.icon.isEmpty)
        }
    }

    /// The guidance sentence must name BOTH exits — the auto-import switch and adding
    /// the folder as a library root — the way the Downloads pane's own off-caption does.
    @Test("the guidance sentence names both ways out")
    func theGuidanceNamesBothExits() {
        let text = String(localized: MacAMPStrings.chatDownloadGateGuidanceToast)
        #expect(text.contains("Downloads"))
        #expect(text.contains("Library"))
    }
}
