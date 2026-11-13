// FolderBrowserSortMenuTests — the folder browser's Sort menu as a mapping.
//
// The menu flattens a two-field value (`FolderFilesSort`: manual, or a key plus a
// direction) onto two pickers. Three ways that can be wrong while still rendering
// perfectly, each pinned below:
//
//   1. Switching the KEY silently resets the DIRECTION, so a listener who chose
//      Name ↓ and then picks Date added lands on ascending without asking.
//   2. Manual order claims a direction, which would leave the Ascending /
//      Descending picker live over a value nothing reads.
//   3. The bindings look right but never reach `UserDefaults`, because a menu that
//      writes a sub-struct field has to reach `AppSettings.folderSort`'s `didSet`.
//
// `settings.folderSort.browser` is written exactly as the two `Binding`s write it,
// so a persistence break shows up here rather than on the next launch.
import Foundation
@testable import MacAMP
import Models
import Testing
import ViewModels

@Suite("Folder browser sort menu")
@MainActor
struct FolderBrowserSortMenuTests {
    @Test("every stored order ticks exactly one key, and every key round-trips back")
    func keysRoundTripThroughTheMenu() {
        for direction in [FolderSortDirection.ascending, .descending] {
            for key in FolderBrowserSortKey.allCases {
                let sort = FolderBrowserSortMenu.sort(for: key, direction: direction)
                #expect(FolderBrowserSortMenu.key(for: sort) == key)
            }
        }
        #expect(FolderBrowserSortMenu.key(for: .manual) == .manual)
        #expect(FolderBrowserSortMenu.key(for: .sorted(.default)) == .name)
        #expect(
            FolderBrowserSortMenu.key(for: .sorted(FolderSort(key: .dateAdded, direction: .descending)))
                == .dateAdded
        )
    }

    @Test("Manual order has no direction, and the direction picker is disabled under it")
    func manualOrderHasNoDirection() {
        #expect(!FolderBrowserSortMenu.allowsDirection(.manual))
        #expect(FolderBrowserSortMenu.direction(of: .manual) == .ascending)
        #expect(FolderBrowserSortMenu.sort(for: .manual, direction: .descending) == .manual)

        for key in [FolderSortKey.name, .dateAdded] {
            for direction in [FolderSortDirection.ascending, .descending] {
                let sort = FolderFilesSort.sorted(FolderSort(key: key, direction: direction))
                #expect(FolderBrowserSortMenu.allowsDirection(sort))
                #expect(FolderBrowserSortMenu.direction(of: sort) == direction)
            }
        }
    }

    @Test("picking a different key keeps the direction already chosen")
    func switchingKeyKeepsTheDirection() {
        var browser = FolderBrowserSortMenu.sort(for: .name, direction: .descending)

        browser = FolderBrowserSortMenu.sort(
            for: .dateAdded,
            direction: FolderBrowserSortMenu.direction(of: browser)
        )

        #expect(browser == .sorted(FolderSort(key: .dateAdded, direction: .descending)))
    }

    @Test("the menu's writes reach UserDefaults and survive a relaunch")
    func theMenuWritesPersist() {
        let name = "com.example.macamp.tests.folderBrowserSortMenu"
        guard let store = UserDefaults(suiteName: name) else { return }
        store.removePersistentDomain(forName: name)
        let settings = AppSettings(defaults: store)

        settings.folderSort.browser = FolderBrowserSortMenu.sort(for: .name, direction: .descending)
        settings.folderSort.browser = FolderBrowserSortMenu.sort(
            for: .dateAdded,
            direction: FolderBrowserSortMenu.direction(of: settings.folderSort.browser)
        )

        let reloaded = AppSettings(defaults: store)
        #expect(reloaded.folderSort.browser == .sorted(FolderSort(key: .dateAdded, direction: .descending)))
        #expect(FolderBrowserSortMenu.key(for: reloaded.folderSort.browser) == .dateAdded)
    }

    /// Returning to Manual must restore the order a drag may rewrite, not a sorted
    /// one that merely looks manual.
    @Test("returning to Manual restores the reorderable order")
    func returningToManualRestoresTheDraggableOrder() {
        let browser = FolderBrowserSortMenu.sort(
            for: .manual,
            direction: FolderBrowserSortMenu.direction(of: .sorted(FolderSort(key: .name, direction: .descending)))
        )

        #expect(browser == .manual)
        #expect(FolderReorderPolicy.allowsReorder(
            filterRootPath: "/Music/Root",
            isGenreFilterAll: true,
            filesSort: browser
        ))
    }

    @Test("the Sort menu keeps its accessibility identifier")
    func theIdentifierIsStable() {
        #expect(FolderBrowserSortMenu.identifier == "library.folder.sort")
    }
}
