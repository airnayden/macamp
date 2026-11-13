// RealAudioLibraryFixture — a library whose rows point at REAL audio files.
//
// Every other UI-test fixture writes zero-byte placeholders, which is right for
// everything that only reads metadata. The re-analyze crash regression is the one
// scenario that cannot use them: it exists to prove that many concurrent decoder
// opens no longer race mpg123's process-global first init, and a zero-byte file
// never reaches a decoder at all. So this fixture takes a directory the TEST filled
// with real audio and inserts one row per file.
//
// The directory is the test's to build — that keeps the shell free of any knowledge
// of where the repo's `tone.mp3` fixture lives, and lets the same seam carry a
// deliberately corrupt file when the failure path is what is under test.
//
// Paths are canonicalized for the same reason ``AppEnvironment/seedFixtureTracks``
// canonicalizes: under `NSTemporaryDirectory()` the `/var` -> `/private/var` symlink
// otherwise makes every path-keyed lookup miss.
//
// `fileSize` and `mtime` are read from disk rather than left null, so the
// `(fileSize, mtime)` fingerprint an analysis row is written with is the real one and
// a second pass over an unchanged file is correctly a no-op.
#if DEBUG
    import Foundation
    import GRDB
    import Persistence
    import Services

    enum RealAudioLibraryFixture {
        /// Launch-environment switch, carrying the DIRECTORY to seed from. Absent ⇒
        /// this file changes nothing.
        static let environmentKey = "UITEST_SEED_REAL_AUDIO_DIR"

        /// Optional launch-environment switch stamping ONE genre onto every seeded
        /// row. Absent ⇒ the rows stay untagged, exactly as before, so no existing
        /// scenario sees a change. Present ⇒ `propose_playlist`'s criteria form has a
        /// genre to materialise a large membership from, which is the only way a
        /// scripted turn can exercise the server-side materialiser end to end.
        static let genreEnvironmentKey = "UITEST_SEED_REAL_AUDIO_GENRE"

        /// The extensions this fixture treats as audio. Deliberately narrow: anything
        /// else in the directory (a stray `.DS_Store`, a log) must not become a row.
        static let audioExtensions: Set<String> = ["mp3", "mp2", "mp1", "m4a", "flac", "wav", "aiff", "aif"]

        /// Inserts one present `TrackRecord` per audio file in `directoryPath`, in
        /// filename order so a test can predict the ids it will be given.
        static func seed(into database: AppDatabase, directoryPath: String, genre: String? = nil) throws {
            let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
            let manager = FileManager.default
            let names = try manager.contentsOfDirectory(atPath: directory.path)
                .filter { audioExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
                .sorted()
            try database.writer.write { db in
                for name in names {
                    var record = trackRecord(for: name, in: directory, manager: manager)
                    record.genre = genre
                    try record.insert(db)
                }
            }
        }

        private static func trackRecord(for name: String, in directory: URL, manager: FileManager) -> TrackRecord {
            let fileURL = directory.appendingPathComponent(name)
            let canonicalPath = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
            let attributes = try? manager.attributesOfItem(atPath: canonicalPath)
            let title = (name as NSString).deletingPathExtension
            var record = TrackRecord(
                filePath: canonicalPath,
                title: title,
                sortTitle: title.lowercased(),
                artistName: "Analysis Fixture",
                duration: 1,
                availability: .present
            )
            record.fileSize = (attributes?[.size] as? NSNumber)?.int64Value
            record.mtime = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970
            return record
        }
    }
#endif
