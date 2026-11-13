import Foundation
@testable import MacAMP
import Persistence
import Testing
import ViewModels

@MainActor
@Suite("Folder selection ownership across a profile switch", .serialized)
struct FolderSelectionOwnershipTests {
    private static let rootPath = "/Music/Shared"
    private static let subfolderPath = "/Music/Shared/Live Sets"
    private static let foreignPath = "/Music/Other/Bootlegs"

    @Test("a root of the incoming profile is owned")
    func rootIsOwned() {
        let ownership = Self.ownership(persisted: nil)
        #expect(ownership.owns(rootId: Self.identifier(Self.rootPath)))
    }

    @Test("a subfolder is owned when the persisted pair places it under an owned root")
    func subfolderUnderOwnedRootIsOwned() {
        let subfolderId = Self.identifier(Self.subfolderPath)
        let ownership = Self.ownership(
            persisted: FolderTreeSelection(rootId: subfolderId, path: Self.subfolderPath)
        )

        #expect(ownership.owns(rootId: subfolderId))
        #expect(ownership.disowns(rootId: subfolderId) == false)
    }

    @Test("a subfolder under another profile's root is disowned")
    func foreignSubfolderIsDisowned() {
        let foreignId = Self.identifier(Self.foreignPath)
        let ownership = Self.ownership(
            persisted: FolderTreeSelection(rootId: foreignId, path: Self.foreignPath)
        )

        #expect(ownership.owns(rootId: foreignId) == false)
        #expect(ownership.disowns(rootId: foreignId))
    }

    /// The playback-restore path writes `.folder` ids from `LibraryRootRecord.id`,
    /// which the stable path hash never produces — so an id nothing resolves must not
    /// count as evidence of a foreign profile.
    @Test("an unresolvable id is neither owned nor disowned")
    func unresolvableIdIsNotDisowned() {
        let ownership = Self.ownership(persisted: nil)

        #expect(ownership.owns(rootId: 4) == false)
        #expect(ownership.disowns(rootId: 4) == false)
    }

    @Test("a prefix that is not a path boundary is not owned")
    func siblingPathSharingAPrefixIsNotOwned() {
        let siblingPath = Self.rootPath + "Archive"
        let siblingId = Self.identifier(siblingPath)
        let ownership = Self.ownership(
            persisted: FolderTreeSelection(rootId: siblingId, path: siblingPath)
        )

        #expect(ownership.owns(rootId: siblingId) == false)
    }

    @Test("a subfolder selection survives resetForProfileSwitch")
    func subfolderSelectionSurvivesReset() {
        let suiteName = Self.makeSuiteName()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let subfolderId = Self.identifier(Self.subfolderPath)
        let incoming = SidebarSelectionStore(profileId: 9, suiteName: suiteName)
        incoming.save(.folder(rootId: subfolderId))

        let nav = NavigationModel(store: SidebarSelectionStore(profileId: 7, suiteName: suiteName))
        nav.resetForProfileSwitch(
            profileId: 9,
            folderOwnership: Self.ownership(
                persisted: FolderTreeSelection(rootId: subfolderId, path: Self.subfolderPath)
            )
        )

        #expect(nav.sidebar == .folder(rootId: subfolderId))
    }

    @Test("a foreign folder selection still drops to All Tracks")
    func foreignSelectionDropsToAllTracks() {
        let suiteName = Self.makeSuiteName()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let foreignId = Self.identifier(Self.foreignPath)
        SidebarSelectionStore(profileId: 9, suiteName: suiteName).save(.folder(rootId: foreignId))

        let nav = NavigationModel(store: SidebarSelectionStore(profileId: 7, suiteName: suiteName))
        nav.resetForProfileSwitch(
            profileId: 9,
            folderOwnership: Self.ownership(
                persisted: FolderTreeSelection(rootId: foreignId, path: Self.foreignPath)
            )
        )

        #expect(nav.sidebar == .fixed(.allTracks))
    }

    @Test("restoreSidebarForProfileSwitch keeps a folder it cannot resolve")
    func restoreKeepsUnresolvableFolder() {
        let suiteName = Self.makeSuiteName()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        SidebarSelectionStore(profileId: 9, suiteName: suiteName).save(.folder(rootId: 4))

        let nav = NavigationModel(store: SidebarSelectionStore(profileId: 7, suiteName: suiteName))
        nav.restoreSidebarForProfileSwitch(profileId: 9, folderOwnership: Self.ownership(persisted: nil))

        #expect(nav.sidebar == .folder(rootId: 4))
    }

    @Test("restoreSidebarForProfileSwitch rejects a positively foreign folder")
    func restoreRejectsForeignFolder() {
        let suiteName = Self.makeSuiteName()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let foreignId = Self.identifier(Self.foreignPath)
        SidebarSelectionStore(profileId: 9, suiteName: suiteName).save(.folder(rootId: foreignId))

        let nav = NavigationModel(store: SidebarSelectionStore(profileId: 7, suiteName: suiteName))
        nav.restoreSidebarForProfileSwitch(
            profileId: 9,
            folderOwnership: Self.ownership(
                persisted: FolderTreeSelection(rootId: foreignId, path: Self.foreignPath)
            )
        )

        #expect(nav.sidebar == .fixed(.allTracks))
    }

    private static func identifier(_ path: String) -> Int64 {
        FolderSidebarViewModel.stableRootId(forPath: path)
    }

    private static func ownership(persisted: FolderTreeSelection?) -> FolderSelectionOwnership {
        FolderSelectionOwnership(
            rootIds: [identifier(rootPath)],
            rootPaths: [rootPath],
            pathForId: { rootId in persisted.flatMap { $0.rootId == rootId ? $0.path : nil } }
        )
    }

    private static func makeSuiteName() -> String {
        "com.example.macamp.tests.folderOwnership.\(UUID().uuidString)"
    }
}
