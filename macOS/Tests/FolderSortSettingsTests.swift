// FolderSortSettingsTests — `AppSettings.folderSort` as a persisted value.
//
// Four claims that would each look correct in the sidebar while being wrong:
//
//   1. A default that is not Name ascending / manual. A fresh install must open on
//      the order it always had, so the defaults are asserted against a freshly wiped
//      domain rather than a live app.
//   2. A choice that does not survive a relaunch. `folderSort` is ONE stored property
//      over TWO flat keys, so the round trip runs through a second `AppSettings` built
//      on the same suite — the relaunch this shell will do.
//   3. A garbage token that takes the settings store down at launch, or that takes its
//      neighbour with it. Each key is seeded with a token or a type it will never
//      legitimately hold, and the surviving key is asserted alongside.
//   4. A blob. The tree and the browser must degrade independently, which only two
//      separate scalars give.
import Foundation
@testable import MacAMP
import Models
import Testing

@Suite("Folder sort settings")
@MainActor
struct FolderSortSettingsTests {
    @Test("a fresh install sorts folders by name, ascending, and keeps manual file order")
    func theDefaultStateIsNameAscendingAndManual() {
        let settings = AppSettings(defaults: Self.store(named: "\(Self.suitePrefix).default"))

        #expect(settings.folderSort.tree == .default)
        #expect(settings.folderSort.tree == FolderSort(key: .name, direction: .ascending))
        #expect(settings.folderSort.browser == .manual)
        #expect(settings.folderSort == FolderSortSettings())
    }

    @Test("both folder sorts round-trip through a reload")
    func eachFolderSortRoundTrips() {
        let store = Self.store(named: "\(Self.suitePrefix).roundTrip")
        let settings = AppSettings(defaults: store)

        settings.folderSort = FolderSortSettings(
            tree: FolderSort(key: .dateAdded, direction: .descending),
            browser: .sorted(FolderSort(key: .name, direction: .descending))
        )

        let reloaded = AppSettings(defaults: store)
        #expect(reloaded.folderSort.tree == FolderSort(key: .dateAdded, direction: .descending))
        #expect(reloaded.folderSort.browser == .sorted(FolderSort(key: .name, direction: .descending)))
    }

    /// The Sort menu mutates one field of one sub-struct through a `Binding`; that has
    /// to reach `didSet` on the whole stored property or nothing persists.
    @Test("mutating one field through the binding persists without disturbing the other")
    func aFieldMutationPersistsOnItsOwn() {
        let store = Self.store(named: "\(Self.suitePrefix).fieldMutation")
        let settings = AppSettings(defaults: store)
        settings.folderSort.browser = .sorted(FolderSort(key: .dateAdded, direction: .ascending))

        settings.folderSort.tree.direction = .descending

        let reloaded = AppSettings(defaults: store)
        #expect(reloaded.folderSort.tree == FolderSort(key: .name, direction: .descending))
        #expect(reloaded.folderSort.browser == .sorted(FolderSort(key: .dateAdded, direction: .ascending)))
    }

    @Test("a corrupt stored token degrades to the default instead of trapping")
    func garbagePersistedValuesDegrade() {
        let store = Self.store(named: "\(Self.suitePrefix).garbage")
        store.set("bogus", forKey: Self.treeKey)
        store.set(["name", "ascending"], forKey: Self.browserKey)

        let settings = AppSettings(defaults: store)
        #expect(settings.folderSort.tree == .default)
        #expect(settings.folderSort.browser == .manual)
    }

    /// `"manual"` is a legal `FolderFilesSort` token and an ILLEGAL `FolderSort` one —
    /// the pair that proves each key is decoded by its own type, not a shared one.
    @Test("one unreadable key leaves its neighbour intact")
    func aSingleGarbageKeyDoesNotResetTheOther() {
        let store = Self.store(named: "\(Self.suitePrefix).partialGarbage")
        let settings = AppSettings(defaults: store)
        settings.folderSort = FolderSortSettings(
            tree: FolderSort(key: .dateAdded, direction: .ascending),
            browser: .sorted(FolderSort(key: .dateAdded, direction: .descending))
        )

        store.set(FolderFilesSort.manualRawValue, forKey: Self.treeKey)

        let reloaded = AppSettings(defaults: store)
        #expect(reloaded.folderSort.tree == .default)
        #expect(reloaded.folderSort.browser == .sorted(FolderSort(key: .dateAdded, direction: .descending)))
    }

    @Test("folder sorts persist as two flat scalars, never as an encoded blob")
    func theStorageVocabularyIsFlatScalars() {
        let name = "\(Self.suitePrefix).flatKeys"
        let store = Self.store(named: name)
        let settings = AppSettings(defaults: store)

        settings.folderSort = FolderSortSettings(
            tree: FolderSort(key: .dateAdded, direction: .descending),
            browser: .sorted(FolderSort(key: .name, direction: .ascending))
        )

        let domain = store.persistentDomain(forName: name) ?? [:]
        let persisted = domain.keys.filter { $0.hasPrefix(Self.folderPrefix) }.sorted()
        #expect(persisted == [Self.browserKey, Self.treeKey])
        for key in persisted {
            #expect(domain[key] as? Data == nil, "\(key) must persist a scalar, not an encoded blob")
        }
        #expect(store.string(forKey: Self.treeKey) == "dateAdded.descending")
        #expect(store.string(forKey: Self.browserKey) == "name.ascending")
    }

    // MARK: Helpers

    private static let suitePrefix = "com.example.macamp.tests.folderSort"
    private static let folderPrefix = "com.example.macamp.settings.folder"
    private static let treeKey = "com.example.macamp.settings.folderTreeSort"
    private static let browserKey = "com.example.macamp.settings.folderBrowserSort"

    private static func store(named name: String) -> UserDefaults {
        guard let store = UserDefaults(suiteName: name) else { return .standard }
        store.removePersistentDomain(forName: name)
        return store
    }
}
