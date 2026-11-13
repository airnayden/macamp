import Foundation
@testable import MacAMP
import Persistence
import Services
import Testing
import ViewModels

@Suite("Sidebar restore mapping", .serialized)
struct SidebarRestoreMappingTests {
    @Test("every playback source maps to its sidebar destination or no write")
    func everySourceMapsToExpectedDestination() {
        let roots = [
            LibraryRootRecord(id: 41, profileId: 7, path: "/Music/Library"),
        ]
        let cases: [(PlaybackSource, SidebarDestination?)] = [
            (.librarySection("allTracks"), .fixed(.allTracks)),
            (.folder(path: "/Music/Library/../Library"), .folder(rootId: 41)),
            (.playlist(id: 73), .playlist(id: 73)),
            (.favourites, .fixed(.favourites)),
            (.karaokeReady, .fixed(.karaoke)),
            (.search, nil),
            (.albumDetail(id: 11), nil),
            (.artistDetail(id: 12), nil),
            (.stats, nil),
        ]

        for (source, expected) in cases {
            #expect(source.sidebarDestination(among: roots) == expected)
        }
    }

    @Test("unknown library sections and absent folders do not navigate")
    func unresolvedContainersDoNotNavigate() {
        #expect(PlaybackSource.librarySection("future").sidebarDestination(among: []) == nil)
        #expect(PlaybackSource.folder(path: "/Missing").sidebarDestination(among: []) == nil)
    }

    @Test("sidebar selection keys round-trip independently per profile")
    func profileScopedStoreRoundTrip() {
        let suiteName = "com.example.macamp.tests.sidebar.\(UUID().uuidString)"
        let key = "sidebar-selection"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let first = SidebarSelectionStore(profileId: 7, suiteName: suiteName, key: key)
        let second = SidebarSelectionStore(profileId: 8, suiteName: suiteName, key: key)

        first.save(.fixed(.albums))
        second.save(.playlist(id: 99))

        #expect(first.load() == .fixed(.albums))
        #expect(second.load() == .playlist(id: 99))
    }
}
