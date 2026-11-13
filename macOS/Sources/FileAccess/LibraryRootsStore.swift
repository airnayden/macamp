// LibraryRootsStore — persists the user's chosen library root folders.
//
// MacAMP's macOS build is NOT sandboxed (see `macampMac.entitlements`: direct
// distribution, App Group only). So roots are stored as **plain filesystem
// paths** — there is no need for, and no benefit to, security-scoped bookmarks
// (those are an iOS / Mac-App-Store-sandbox requirement, per the project issues
// log). A simple `UserDefaults` string array is the right persistence.
//
// The protocol seam keeps the access controller and the watch wiring testable
// against an in-memory double.
import Foundation

// MARK: - LibraryRootsStoring

/// Persists and restores the set of library root folders the user has chosen.
public protocol LibraryRootsStoring: Sendable {
    /// Restores the saved roots (empty on first run).
    func load() -> [URL]
    /// Persists `roots`, replacing whatever was stored.
    func save(_ roots: [URL])
}

// MARK: - UserDefaultsLibraryRootsStore

/// The production ``LibraryRootsStoring`` over `UserDefaults`, storing plain paths.
///
/// `UserDefaults` is documented thread-safe but is not `Sendable`, so — exactly
/// as the now-playing snapshot writers do — this struct stores only the
/// `Sendable` suite name + key and resolves the defaults object per call.
public struct UserDefaultsLibraryRootsStore: LibraryRootsStoring {
    /// The default `UserDefaults` key under which the path array is stored.
    public static let defaultKey = "com.example.macamp.libraryRoots"

    private let suiteName: String?
    private let key: String

    /// - Parameters:
    ///   - suiteName: a `UserDefaults` suite (nil ⇒ `.standard`).
    ///   - key: the defaults key for the path array.
    public init(suiteName: String? = nil, key: String = UserDefaultsLibraryRootsStore.defaultKey) {
        self.suiteName = suiteName
        self.key = key
    }

    public func load() -> [URL] {
        let paths = defaults.array(forKey: key) as? [String] ?? []
        return paths.map { URL(fileURLWithPath: $0) }
    }

    public func save(_ roots: [URL]) {
        let paths = roots.map(\.path)
        defaults.set(paths, forKey: key)
    }

    private var defaults: UserDefaults {
        if let suiteName, let suite = UserDefaults(suiteName: suiteName) {
            return suite
        }
        return .standard
    }
}

// MARK: - FakeLibraryRootsStore

/// A hermetic in-memory ``LibraryRootsStoring`` for tests and previews — never
/// touches `UserDefaults` or disk.
public final class FakeLibraryRootsStore: LibraryRootsStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var roots: [URL]

    public init(roots: [URL] = []) {
        self.roots = roots
    }

    public func load() -> [URL] {
        lock.withLock { roots }
    }

    public func save(_ newRoots: [URL]) {
        lock.withLock { roots = newRoots }
    }
}
