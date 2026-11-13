// InstrumentalCache relocation — the safe "copy everything, switch, then delete"
// directory move. Extracted from `InstrumentalCache.swift` so each file stays within
// the SwiftLint file-length / type-body budgets; the logic is unchanged. It reaches
// the actor's `internal` storage (`directory`/`index`/`fileManager`) and helpers
// (`persist`/`emitEntriesChanged`/`indexURL`).
//
// Foundation-only — no AppKit/UIKit (PlayerCore portability invariant).
import Foundation

public extension InstrumentalCache {
    // MARK: Relocation

    /// Moves the cache to `newDirectory` without ever risking the rendered library.
    ///
    /// Strategy: copy every entry file + `index.json` to `newDirectory` FIRST; only
    /// once ALL copies succeed switch `directory` over, persist, then delete the old
    /// files. On ANY copy failure the partial copies are removed and the OLD directory
    /// is kept as the live cache (`false`) — nothing is lost. A fresh start at an empty
    /// `newDirectory` is reserved SOLELY for when the OLD directory is itself gone.
    func relocate(to newDirectory: URL) throws -> Bool {
        let oldDirectory = directory
        if newDirectory.standardizedFileURL == oldDirectory.standardizedFileURL {
            return true
        }
        try fileManager.createDirectory(at: newDirectory, withIntermediateDirectories: true)

        // Old directory gone/unreadable: nothing to carry and nothing to lose — adopt
        // the new directory as an empty cache and announce the now-empty ready set.
        guard fileManager.fileExists(atPath: oldDirectory.path) else {
            directory = newDirectory
            index = Index()
            try? persist()
            emitEntriesChanged()
            return true
        }

        let entries = Array(index.entries.values)
        var copied: [URL] = []
        do {
            for entry in entries {
                let source = oldDirectory.appendingPathComponent(entry.filePath)
                guard fileManager.fileExists(atPath: source.path) else { continue }
                let destination = newDirectory.appendingPathComponent(entry.filePath)
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.copyItem(at: source, to: destination)
                copied.append(destination)
            }
            let oldIndex = Self.indexURL(in: oldDirectory)
            if fileManager.fileExists(atPath: oldIndex.path) {
                let newIndex = Self.indexURL(in: newDirectory)
                if fileManager.fileExists(atPath: newIndex.path) {
                    try fileManager.removeItem(at: newIndex)
                }
                try fileManager.copyItem(at: oldIndex, to: newIndex)
                copied.append(newIndex)
            }
        } catch {
            // Roll back the partial copy; the OLD directory remains the live cache.
            for url in copied {
                try? fileManager.removeItem(at: url)
            }
            return false
        }

        directory = newDirectory
        try? persist()
        for entry in entries {
            try? fileManager.removeItem(at: oldDirectory.appendingPathComponent(entry.filePath))
        }
        try? fileManager.removeItem(at: Self.indexURL(in: oldDirectory))
        emitEntriesChanged()
        return true
    }
}
