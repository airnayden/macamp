// SFBMetadataReader — the production metadata backend (SFBAudioEngine / TagLib).
//
// Wraps SFBAudioEngine's `AudioFile(readingPropertiesAndMetadataFrom:)`, which
// reads stream properties + tags via TagLib in one pass, and maps the result to
// this module's ``TrackMetadata`` value type. Every textual value is NFC-
// normalised (by the ``TrackMetadata`` initialiser) and every SFB / Foundation
// error is caught and re-thrown as a typed ``MetadataError`` — a corrupt,
// unsupported or unreadable file can never crash a caller. The module is READ-
// ONLY: SFB's `writeMetadata()` is intentionally never invoked.
//
// `@preconcurrency import` keeps SFB's not-yet-Sendable-annotated types from
// tripping Swift 6 strict concurrency. This file imports only AVFAudio +
// Foundation + SFBAudioEngine; it MUST NOT import AppKit or UIKit (PlayerCore
// portability invariant).
import AVFAudio
import Foundation
@preconcurrency import SFBAudioEngine

/// A ``MetadataReading`` backed by SFBAudioEngine / TagLib.
///
/// Stateless and therefore `Sendable`: a single value can read any number of
/// files. Reads carry embedded artwork bytes in memory, so callers must invoke
/// it off the audio render thread (it is an import-time operation, never a hot
/// path).
public struct SFBMetadataReader: MetadataReading {
    public init() {}

    public func readMetadata(from url: URL) throws -> TrackMetadata {
        try Self.preflight(url)
        let audioFile = try Self.openFile(at: url)
        return Self.map(properties: audioFile.properties, metadata: audioFile.metadata)
    }

    /// Lower-cased path extensions the TagLib backend can read.
    public static var supportedPathExtensions: Set<String> {
        Set(AudioFile.supportedPathExtensions.map { $0.lowercased() })
    }

    /// MIME types the TagLib backend can read.
    public static var supportedMIMETypes: Set<String> {
        AudioFile.supportedMIMETypes
    }

    // MARK: - Backend access

    private static func openFile(at url: URL) throws -> AudioFile {
        do {
            return try AudioFile(readingPropertiesAndMetadataFrom: url)
        } catch {
            throw MetadataError.from(error, url: url)
        }
    }

    /// Rejects missing / unreadable inputs with a typed error *before* SFB is
    /// asked to parse them, so they never surface as opaque backend failures.
    private static func preflight(_ url: URL) throws {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw MetadataError.ioError(url: url, underlying: "file does not exist")
        }
        guard manager.isReadableFile(atPath: url.path) else {
            throw MetadataError.ioError(url: url, underlying: "file is not readable")
        }
    }

    // MARK: - Mapping SFB types -> TrackMetadata

    private static func map(properties: AudioProperties, metadata: AudioMetadata) -> TrackMetadata {
        TrackMetadata(
            title: metadata.title,
            artist: metadata.artist,
            album: metadata.albumTitle,
            albumArtist: metadata.albumArtist,
            genre: metadata.genre,
            composer: metadata.composer,
            year: parseYear(metadata.releaseDate),
            trackNumber: metadata.trackNumber,
            trackTotal: metadata.trackTotal,
            discNumber: metadata.discNumber,
            discTotal: metadata.discTotal,
            duration: properties.duration,
            bitrate: properties.bitrate,
            sampleRate: properties.sampleRate,
            bitDepth: positiveOrNil(properties.bitDepth),
            channelCount: properties.channelCount.map(Int.init),
            artwork: mapArtwork(metadata.attachedPictures),
            lyrics: metadata.lyrics,
            replayGain: mapReplayGain(metadata)
        )
    }

    /// Extracts the first four-consecutive-digit run from a release-date tag
    /// (`"1969"`, `"1969-08-08"`, `"August 1969"` all yield `1969`).
    private static func parseYear(_ raw: String?) -> Int? {
        guard let raw,
              let range = raw.range(of: "[0-9]{4}", options: .regularExpression)
        else { return nil }
        return Int(raw[range])
    }

    /// Maps a non-positive (or absent) bit depth to `nil` — lossy codecs report
    /// `0`, which is not a meaningful sample depth.
    private static func positiveOrNil(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }

    /// Maps SFB attached pictures to ``EmbeddedArtwork``, sorted by role for a
    /// deterministic order (SFB hands them back as an unordered `Set`).
    private static func mapArtwork(_ pictures: Set<AttachedPicture>) -> [EmbeddedArtwork] {
        pictures
            .map { picture in
                EmbeddedArtwork(
                    data: picture.imageData,
                    mimeType: sniffMIMEType(picture.imageData),
                    type: ArtworkType(rawValue: Int(picture.type.rawValue)) ?? .other
                )
            }
            .sorted { $0.type.rawValue < $1.type.rawValue }
    }

    /// Bundles the five ReplayGain fields, returning `nil` when the file carried
    /// none (so the value type stores absence rather than an all-`nil` struct).
    private static func mapReplayGain(_ metadata: AudioMetadata) -> ReplayGain? {
        let gain = ReplayGain(
            referenceLoudness: metadata.replayGainReferenceLoudness,
            trackGain: metadata.replayGainTrackGain,
            trackPeak: metadata.replayGainTrackPeak,
            albumGain: metadata.replayGainAlbumGain,
            albumPeak: metadata.replayGainAlbumPeak
        )
        return gain.isEmpty ? nil : gain
    }

    /// Sniffs an image MIME type from the leading magic bytes (SFB's
    /// `AttachedPicture` does not expose the tag's declared MIME type).
    private static func sniffMIMEType(_ data: Data) -> String? {
        let prefix = [UInt8](data.prefix(4))
        if prefix.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if prefix.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if prefix.starts(with: [0x47, 0x49, 0x46]) { return "image/gif" }
        return nil
    }
}

// MARK: - Error mapping

private extension MetadataError {
    /// SFB `AudioFile.ErrorDomain` codes (`SFBAudioFileErrorCode`).
    enum SFBCode {
        static let internalError = 0
        static let unknownFormatName = 1
        static let inputOutput = 2
        static let invalidFormat = 3
    }

    /// Translates any SFB / Foundation error into a typed ``MetadataError``.
    static func from(_ error: Error, url: URL) -> MetadataError {
        if let typed = error as? MetadataError { return typed }
        let nsError = error as NSError
        guard nsError.domain == AudioFile.ErrorDomain else {
            return .ioError(url: url, underlying: nsError.localizedDescription)
        }
        switch nsError.code {
        case SFBCode.unknownFormatName:
            return .unsupportedFormat(url: url)
        case SFBCode.inputOutput:
            return .ioError(url: url, underlying: nsError.localizedDescription)
        case SFBCode.invalidFormat:
            return classifyInvalidFormat(url: url, reason: nsError.localizedDescription)
        default:
            return .corruptedFile(url: url, reason: nsError.localizedDescription)
        }
    }

    /// SFB folds "unsupported type" and "recognised type, bad bytes" into one
    /// `invalidFormat` code. Disambiguate by extension: a known audio extension
    /// with bad bytes is corruption; an unknown extension is genuinely
    /// unsupported.
    static func classifyInvalidFormat(url: URL, reason: String) -> MetadataError {
        if AudioFile.handlesPaths(withExtension: url.pathExtension) {
            return .corruptedFile(url: url, reason: reason)
        }
        return .unsupportedFormat(url: url)
    }
}
