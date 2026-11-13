// SFBMetadataWriter — the production tag writer (SFBAudioEngine / TagLib).
//
// The write-side counterpart to ``SFBMetadataReader``. It applies a
// ``WritableMetadata`` patch through SFBAudioEngine's TagLib-backed
// `AudioFile.writeMetadata()`, which can write tags for MP3, FLAC, MP4/AAC and
// Ogg (Vorbis/Opus/Speex). Formats that cannot carry writable tags (Shorten,
// tracker modules, …) fall outside ``writableExtensions`` and are rejected with
// ``MetadataWriteError/unsupportedFormat(url:)`` WITHOUT the file being touched.
//
// Atomic-write contract (the whole reason this type exists):
//
//   1. Preflight: reject a missing file, an unsupported extension, or a
//      non-writable (e.g. `0444`) file BEFORE creating anything.
//   2. Copy the original to a hidden sibling temp in the SAME directory (so the
//      final step is a same-volume, atomic rename).
//   3. Read the temp's existing tags, apply the patch, write the temp.
//   4. `FileManager.replaceItemAt` the original with the temp (atomic rename).
//
// If ANY step after the preflight fails, the temp is deleted and the original is
// left byte-for-byte unchanged — there is no in-place, half-written state. Tag
// writing reads the whole file and is an import-time operation: callers MUST run
// it OFF the audio render thread.
//
// FSEvents self-write suppression: a committed write triggers a filesystem
// change the folder watcher would otherwise re-scan. The writer records the path
// in an injected ``MetadataSelfWriteRegistry`` so the watcher can recognise its
// own write and skip the redundant pass (see that type's docs for the watcher
// integration). It also fires the ``onDidWrite`` re-import hook and posts
// ``Notification/Name/metadataDidWrite`` so the library can resync the DB row —
// the Metadata module itself never touches the database.
//
// `@preconcurrency import` keeps SFB's not-yet-Sendable types from tripping
// Swift 6 strict concurrency. This file imports only Foundation + SFBAudioEngine;
// it MUST NOT import AppKit or UIKit (PlayerCore portability invariant).
import Foundation
@preconcurrency import SFBAudioEngine

/// A ``MetadataWriting`` backed by SFBAudioEngine / TagLib. See the file header
/// for the atomic-write contract and the self-write suppression / re-import hook.
public struct SFBMetadataWriter: MetadataWriting {
    private let selfWriteRegistry: MetadataSelfWriteRegistry?
    private let onDidWrite: (@Sendable (URL) -> Void)?
    private let postsNotification: Bool

    /// - Parameters:
    ///   - selfWriteRegistry: marked after each committed write so the folder
    ///     watcher can skip its own change event. `nil` to disable suppression.
    ///   - onDidWrite: the re-import hook, invoked with the file URL after a
    ///     committed write so the caller can resync persistence.
    ///   - postsNotification: when `true` (default) a committed write also posts
    ///     ``Notification/Name/metadataDidWrite`` to `NotificationCenter.default`.
    public init(
        selfWriteRegistry: MetadataSelfWriteRegistry? = nil,
        onDidWrite: (@Sendable (URL) -> Void)? = nil,
        postsNotification: Bool = true
    ) {
        self.selfWriteRegistry = selfWriteRegistry
        self.onDidWrite = onDidWrite
        self.postsNotification = postsNotification
    }

    /// Lower-cased path extensions whose format can carry writable tags. Anything
    /// outside this set is rejected as ``MetadataWriteError/unsupportedFormat``.
    public static let writableExtensions: Set<String> = [
        "mp3",
        "flac",
        "m4a", "mp4", "m4b", "m4r", "aac",
        "ogg", "oga", "opus", "spx",
    ]

    public func writeMetadata(_ metadata: WritableMetadata, to url: URL) throws {
        try Self.preflight(url)
        guard !metadata.isEmpty else { return }

        let manager = FileManager.default
        let temp = Self.makeTempURL(for: url)
        do {
            try manager.copyItem(at: url, to: temp)
        } catch {
            try? manager.removeItem(at: temp)
            throw MetadataWriteError.permissionDenied(url: url)
        }
        do {
            try Self.patchAndWrite(metadata, at: temp)
            _ = try manager.replaceItemAt(url, withItemAt: temp)
        } catch {
            try? manager.removeItem(at: temp)
            throw MetadataWriteError.from(error, url: url)
        }
        commitHooks(for: url)
    }

    // MARK: - Post-commit hooks

    private func commitHooks(for url: URL) {
        selfWriteRegistry?.markSelfWrite(url)
        onDidWrite?(url)
        guard postsNotification else { return }
        NotificationCenter.default.post(
            name: .metadataDidWrite,
            object: nil,
            userInfo: [metadataDidWriteURLKey: url]
        )
    }

    // MARK: - Preflight + temp staging

    private static func preflight(_ url: URL) throws {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw MetadataWriteError.fileNotFound(url: url)
        }
        guard writableExtensions.contains(url.pathExtension.lowercased()) else {
            throw MetadataWriteError.unsupportedFormat(url: url)
        }
        guard manager.isWritableFile(atPath: url.path) else {
            throw MetadataWriteError.readOnlyFile(url: url)
        }
    }

    /// A hidden sibling in the original's directory, KEEPING the extension so SFB
    /// can detect the format when it rewrites tags. Same directory ⇒ same volume
    /// ⇒ the final ``FileManager/replaceItemAt`` is an atomic rename.
    private static func makeTempURL(for url: URL) -> URL {
        let ext = url.pathExtension
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        let name = ".macamp-write-\(UUID().uuidString)\(suffix)"
        return url.deletingLastPathComponent().appendingPathComponent(name)
    }

    // MARK: - Patch + write (operates on the temp copy)

    private static func patchAndWrite(_ edit: WritableMetadata, at url: URL) throws {
        let audioFile: AudioFile
        do {
            audioFile = try AudioFile(readingPropertiesAndMetadataFrom: url)
        } catch {
            throw MetadataWriteError.from(error, url: url)
        }
        apply(edit, to: audioFile.metadata)
        do {
            try audioFile.writeMetadata()
        } catch {
            throw MetadataWriteError.from(error, url: url)
        }
    }

    private static func apply(_ edit: WritableMetadata, to metadata: AudioMetadata) {
        applyTextFields(edit, to: metadata)
        applyNumericFields(edit, to: metadata)
        applyReplayGainFields(edit, to: metadata)
        if let artwork = edit.artwork {
            applyArtwork(artwork, to: metadata)
        }
    }

    private static func applyTextFields(_ edit: WritableMetadata, to metadata: AudioMetadata) {
        if let title = edit.title { metadata.title = title }
        if let artist = edit.artist { metadata.artist = artist }
        if let album = edit.album { metadata.albumTitle = album }
        if let albumArtist = edit.albumArtist { metadata.albumArtist = albumArtist }
        if let genre = edit.genre { metadata.genre = genre }
        if let composer = edit.composer { metadata.composer = composer }
    }

    private static func applyNumericFields(_ edit: WritableMetadata, to metadata: AudioMetadata) {
        if let year = edit.year { metadata.releaseDate = String(year) }
        if let trackNumber = edit.trackNumber { metadata.trackNumber = trackNumber }
        if let discNumber = edit.discNumber { metadata.discNumber = discNumber }
    }

    /// Writes ReplayGain through SFB's dedicated `replayGain*` properties, which
    /// are the ONLY mechanism that persists: SFB re-derives the per-format tag
    /// spelling from them (Xiph `REPLAYGAIN_TRACK_GAIN`, ID3v2
    /// `TXXX:REPLAYGAIN_TRACK_GAIN` + `RVA2`). Routing the same keys through
    /// ``AudioMetadata/additionalMetadata`` instead is silently erased — SFB emits
    /// the additional-metadata block first and the ReplayGain block second, and a
    /// `nil` dedicated property *removes* the key the first block just wrote.
    ///
    /// MP4/M4A cannot carry ReplayGain on this pin at all, so the caller-facing
    /// action refuses it up front — see ``ReplayGainTagSupport``.
    private static func applyReplayGainFields(_ edit: WritableMetadata, to metadata: AudioMetadata) {
        if let trackGain = edit.replayGainTrackGain { metadata.replayGainTrackGain = trackGain }
        if let trackPeak = edit.replayGainTrackPeak { metadata.replayGainTrackPeak = trackPeak }
        if let albumGain = edit.replayGainAlbumGain { metadata.replayGainAlbumGain = albumGain }
        if let albumPeak = edit.replayGainAlbumPeak { metadata.replayGainAlbumPeak = albumPeak }
    }

    /// `[]` clears every picture; a non-empty array replaces all pictures with it.
    private static func applyArtwork(_ artwork: [EmbeddedArtwork], to metadata: AudioMetadata) {
        metadata.removeAllAttachedPictures()
        for art in artwork {
            metadata.attachPicture(makePicture(from: art))
        }
    }

    private static func makePicture(from art: EmbeddedArtwork) -> AttachedPicture {
        // SFB bridges `SFBAttachedPictureType` to Swift as `AttachedPicture.Type`,
        // which collides with metatype syntax and cannot be spelled directly.
        // Build a `.other` picture (a usable fallback that also yields an enum
        // value), then map our matching ID3-APIC rawValue via its metatype.
        let fallback = AttachedPicture(imageData: art.data, type: .other)
        guard let pictureType = Swift.type(of: fallback.type).init(rawValue: UInt(art.type.rawValue)) else {
            return fallback
        }
        return AttachedPicture(imageData: art.data, type: pictureType)
    }
}

// MARK: - Error mapping

private extension MetadataWriteError {
    /// SFB `AudioFile.ErrorDomain` codes (`SFBAudioFileErrorCode`).
    enum SFBCode {
        static let unknownFormatName = 1
        static let invalidFormat = 3
    }

    /// Translates any SFB / Foundation error raised during the write phase into a
    /// typed ``MetadataWriteError`` (already-typed errors pass through).
    static func from(_ error: Error, url: URL) -> MetadataWriteError {
        if let typed = error as? MetadataWriteError { return typed }
        let nsError = error as NSError
        guard nsError.domain == AudioFile.ErrorDomain else {
            return .writeFailed(url: url, reason: nsError.localizedDescription)
        }
        switch nsError.code {
        case SFBCode.unknownFormatName, SFBCode.invalidFormat:
            return .unsupportedFormat(url: url)
        default:
            return .writeFailed(url: url, reason: nsError.localizedDescription)
        }
    }
}

// MARK: - MetadataSelfWriteRegistry

/// Records paths MacAMP has just written itself, so the FSEvents folder watcher
/// can tell its own writes apart from external edits and skip a redundant
/// re-scan.
///
/// Why this exists: writing a tag rewrites the file, which fires an FSEvents
/// change for the watched root. Without suppression the watcher would re-scan and
/// reconcile a change MacAMP already knows about (the writer fires its own,
/// precise re-import hook). Each committed write calls ``markSelfWrite(_:)``;
/// the watcher, on each changed path, calls ``isSelfWrite(_:)`` (or the one-shot
/// ``consumeSelfWrite(_:)``) and drops paths that match.
///
/// A marker lives for `graceInterval` seconds — long enough to outlast the
/// kernel's FSEvents latency plus the watcher's debounce — then expires so a
/// later genuine external edit of the same path is never wrongly suppressed.
/// Paths are normalised (symlinks resolved, `.`/`..` collapsed) so the watcher's
/// `/private`-prefixed event paths match the URL the writer recorded.
///
/// Thread-safe via an `NSLock` (FSEvents fires on the watcher's queue while the
/// writer runs on an import queue), hence `@unchecked Sendable`.
public final class MetadataSelfWriteRegistry: @unchecked Sendable {
    private let graceInterval: TimeInterval
    private let now: @Sendable () -> TimeInterval
    private let lock = NSLock()
    private var expiries: [String: TimeInterval] = [:]

    public init(
        graceInterval: TimeInterval = 5,
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.graceInterval = graceInterval
        self.now = now
    }

    /// Records `url` as a self-write for the grace window.
    public func markSelfWrite(_ url: URL) {
        let key = Self.key(for: url)
        lock.lock()
        defer { lock.unlock() }
        purgeExpiredLocked()
        expiries[key] = now() + graceInterval
    }

    /// `true` if `url` was self-written within the grace window (non-consuming).
    public func isSelfWrite(_ url: URL) -> Bool {
        let key = Self.key(for: url)
        lock.lock()
        defer { lock.unlock() }
        purgeExpiredLocked()
        return expiries[key] != nil
    }

    /// One-shot variant: returns the same as ``isSelfWrite(_:)`` and removes the
    /// marker so a second call returns `false`.
    public func consumeSelfWrite(_ url: URL) -> Bool {
        let key = Self.key(for: url)
        lock.lock()
        defer { lock.unlock() }
        purgeExpiredLocked()
        return expiries.removeValue(forKey: key) != nil
    }

    /// Drops every marker (e.g. when the watcher restarts).
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        expiries.removeAll()
    }

    private func purgeExpiredLocked() {
        let instant = now()
        expiries = expiries.filter { $0.value > instant }
    }

    private static func key(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
