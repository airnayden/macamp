// FolderTreeStore — `UserDefaults` backing for the folder sidebar's expansion and
// selection (PlayerCore's `FolderTreePersistence` seam).
//
// Its own file rather than an addition to `StateRestoration.swift`, which is at 393
// of SwiftLint's 400-line `file_length` budget.
//
// Keyed by profile id for the same reason `SidebarSelectionStore` is: at a profile
// switch the live registry still holds the OUTGOING profile's tree, so the incoming
// profile's selected SUBFOLDER can only be resolved from its own persisted
// id→path pair.
import Foundation
import ViewModels

struct FolderTreeStore {
    static let defaultKey = "com.example.macamp.folderTreeState"

    private let suiteName: String?
    private let key: String

    init(suiteName: String? = nil, key: String = FolderTreeStore.defaultKey) {
        self.suiteName = suiteName
        self.key = key
    }

    /// Absent or unreadable data degrades to ``FolderTreeState/empty`` — a first
    /// launch, a decode failure, and a state written by a later build all land on the
    /// same collapsed-and-unselected tree rather than failing the sidebar.
    func load(profileId: Int64) -> FolderTreeState {
        guard let data = defaults.data(forKey: profileKey(profileId)) else { return .empty }
        return (try? JSONDecoder().decode(FolderTreeState.self, from: data)) ?? .empty
    }

    func save(profileId: Int64, _ state: FolderTreeState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: profileKey(profileId))
    }

    var persistence: FolderTreePersistence {
        let store = self
        return FolderTreePersistence(
            load: { store.load(profileId: $0) },
            save: { store.save(profileId: $0, $1) }
        )
    }

    private func profileKey(_ profileId: Int64) -> String {
        "\(key).profile.\(profileId)"
    }

    /// Resolves the same throwaway UI-test suite ``SidebarSelectionStore`` uses, so a
    /// UI test's folder expansion never leaks into the real user's standard defaults.
    private var defaults: UserDefaults {
        if let suiteName, let suite = UserDefaults(suiteName: suiteName) {
            return suite
        }
        #if DEBUG
            if let uiTestSuite = SidebarSelectionStore.uiTestDefaults() {
                return uiTestSuite
            }
        #endif
        return .standard
    }
}
