import Foundation
@testable import MacAMP
import Persistence
import Testing
import ViewModels

@MainActor
@Suite("Sidebar section expansion", .serialized)
struct SidebarSectionExpansionTests {
    @Test("a sidebar with nothing persisted reports every section expanded")
    func absentStateReadsAsExpanded() {
        let suiteName = Self.makeSuiteName()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let nav = NavigationModel(store: Self.store(suiteName, profileId: 7))

        #expect(nav.sidebarSectionExpanded.isEmpty)
        for section in SidebarSectionID.allCases {
            #expect(nav.isSectionExpanded(section), "\(section.rawValue) should default to expanded")
        }
    }

    @Test("unreadable persisted state degrades to a fully expanded sidebar")
    func corruptStateReadsAsExpanded() throws {
        let suiteName = Self.makeSuiteName()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set(Data("not json".utf8), forKey: "\(SidebarSelectionStore.sectionExpansionKey).profile.7")
        let nav = NavigationModel(store: Self.store(suiteName, profileId: 7))

        #expect(nav.sidebarSectionExpanded.isEmpty)
        #expect(nav.isSectionExpanded(.library))
    }

    @Test("collapsing a section survives a relaunch of the same profile")
    func collapseSurvivesRelaunch() {
        let suiteName = Self.makeSuiteName()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let nav = NavigationModel(store: Self.store(suiteName, profileId: 7))
        nav.sidebarSectionExpanded[SidebarSectionID.library.rawValue] = false

        let relaunched = NavigationModel(store: Self.store(suiteName, profileId: 7))
        #expect(relaunched.isSectionExpanded(.library) == false)
        #expect(relaunched.isSectionExpanded(.playlists))
    }

    @Test("expansion is per profile and is swapped by a profile switch")
    func expansionIsProfileScoped() {
        let suiteName = Self.makeSuiteName()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let nav = NavigationModel(store: Self.store(suiteName, profileId: 7))
        nav.sidebarSectionExpanded[SidebarSectionID.folders.rawValue] = false

        let guest = NavigationModel(store: Self.store(suiteName, profileId: 8))
        #expect(guest.isSectionExpanded(.folders), "a sibling profile keeps its own expansion")

        nav.restoreSidebarForProfileSwitch(profileId: 8)
        #expect(nav.isSectionExpanded(.folders))

        nav.restoreSidebarForProfileSwitch(profileId: 7)
        #expect(nav.isSectionExpanded(.folders) == false)
    }

    @Test("the sidebar selection and the section expansion persist independently")
    func selectionAndExpansionDoNotShareStorage() {
        let suiteName = Self.makeSuiteName()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let nav = NavigationModel(store: Self.store(suiteName, profileId: 7))
        nav.sidebar = .fixed(.albums)
        nav.sidebarSectionExpanded[SidebarSectionID.karaoke.rawValue] = false

        let relaunched = NavigationModel(store: Self.store(suiteName, profileId: 7))
        #expect(relaunched.sidebar == .fixed(.albums))
        #expect(relaunched.isSectionExpanded(.karaoke) == false)
    }

    private static func makeSuiteName() -> String {
        "com.example.macamp.tests.sidebarSections.\(UUID().uuidString)"
    }

    private static func store(_ suiteName: String, profileId: Int64) -> SidebarSelectionStore {
        SidebarSelectionStore(profileId: profileId, suiteName: suiteName)
    }
}
