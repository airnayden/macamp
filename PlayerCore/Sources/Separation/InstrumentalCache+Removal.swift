// InstrumentalCache targeted removal — deleting the cached instrumentals for a set of
// SOURCE files ("Remove Karaoke Version"). Extracted from `InstrumentalCache.swift` so
// each file stays within the SwiftLint file-length / type-body budgets, exactly like
// `InstrumentalCache+Relocation.swift`. It reaches the actor's `internal` storage
// (`index`/`pinnedKeys`) and helpers (`removeEntry`/`persist`/`emitEntriesChanged`).
//
// Foundation-only — no AppKit/UIKit (PlayerCore portability invariant).
import Foundation

public extension InstrumentalCache {
    // MARK: Targeted removal

    /// Deletes the cached instrumentals rendered from `sourcePaths`.
    ///
    /// Three properties make this safe to wire straight to a destructive menu item:
    ///
    /// 1. **Spelling-proof matching** — the entry's stored `sourcePath` (recorded
    ///    verbatim at render time) and every caller-supplied path are BOTH canonicalized
    ///    through ``CanonicalSourcePath``, so a `/var/…` caller matches a `/private/var/…`
    ///    entry. Without this the match silently fails for temp/alias paths.
    /// 2. **Pin exemption** — a pinned entry is the playing or pre-scheduled
    ///    instrumental; its file may be open on the audio path, so it is skipped and
    ///    survives intact (file AND index entry). Pins themselves are left untouched.
    /// 3. **One change-seam bump** — `persist()` and `emitEntriesChanged()` run ONCE for
    ///    the whole batch, so removing a multi-selection re-derives downstream consumers
    ///    a single time instead of once per entry.
    ///
    /// Nothing outside the cache is touched: the source files, their library rows, play
    /// statistics, and the render queue are all left exactly as they were.
    @discardableResult
    func remove(sourcePaths: [String]) throws -> Int {
        let targets = Set(sourcePaths.map(CanonicalSourcePath.canonical))
        guard !targets.isEmpty else { return 0 }

        let victims = index.entries.values.filter { entry in
            guard let sourcePath = entry.sourcePath, !pinnedKeys.contains(entry.key) else {
                return false
            }
            return targets.contains(CanonicalSourcePath.canonical(sourcePath))
        }
        guard !victims.isEmpty else { return 0 }

        for entry in victims {
            try removeEntry(entry)
        }
        try persist()
        emitEntriesChanged()
        return victims.count
    }
}
