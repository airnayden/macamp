// AppSettings+FolderSort — how `AppSettings.folderSort` reaches and leaves `UserDefaults`.
//
// A sibling file for the mechanical reason `AppSettings+Downloads.swift` is one:
// `AppSettings.swift` sits at `swiftlint --strict`'s 400-line ceiling, and only
// declarations that own NO stored state may leave it (`@Observable` transforms the
// primary class declaration alone). The stored `folderSort` property therefore stays
// there; its type, its two keys and its hydration live here.
//
// ── ONE STORED PROPERTY, TWO SURFACES ─────────────────────────────────────────
//
// The sidebar folder TREE and the folder BROWSER are ordered independently, but they
// travel as one `@Observable` stored property rather than two. `@Observable`
// instruments stored properties, so a single one is the smallest thing both the
// sidebar's Sort menu and the browser's Sort menu can observe, and a change to either
// re-renders both menus correctly. They still PERSIST as two flat scalars, so one
// unreadable token degrades on its own.
import Foundation
import Models

/// How the two folder surfaces are ordered.
///
/// `browser` is a ``FolderFilesSort`` rather than a ``FolderSort`` because a folder's
/// direct files carry a user-owned manual drag order, which is that surface's default
/// and the only order a drag may rewrite. Subfolders have no such order, so the tree
/// is a plain ``FolderSort``.
public struct FolderSortSettings: Equatable, Sendable {
    public var tree: FolderSort
    public var browser: FolderFilesSort

    public init(tree: FolderSort = .default, browser: FolderFilesSort = .default) {
        self.tree = tree
        self.browser = browser
    }
}

extension AppSettings {
    /// Writes both folder-sort scalars, from ``folderSort``' `didSet` — so a mutation
    /// through a Sort menu's binding persists with no save step.
    func persistFolderSort() {
        defaults.set(folderSort.tree.rawValue, forKey: AppSettingsKeys.folderTreeSort)
        defaults.set(folderSort.browser.rawValue, forKey: AppSettingsKeys.folderBrowserSort)
    }

    /// Hydrates the folder sorts from `defaults`.
    ///
    /// `static` because `init` calls it before `self` is fully initialized. Each token
    /// degrades on its own: `FolderSort`/`FolderFilesSort` answer `nil` for anything
    /// they do not recognise — a hand-edited plist, or a token a NEWER build wrote —
    /// and the fallback is applied here, by the caller that owns it.
    static func loadFolderSort(from defaults: UserDefaults) -> FolderSortSettings {
        FolderSortSettings(
            tree: FolderSort(rawValue: defaults.string(forKey: AppSettingsKeys.folderTreeSort) ?? "")
                ?? .default,
            browser: FolderFilesSort(rawValue: defaults.string(forKey: AppSettingsKeys.folderBrowserSort) ?? "")
                ?? .default
        )
    }
}
