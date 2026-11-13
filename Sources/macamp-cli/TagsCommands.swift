// TagsCommands — the `tags` subcommand for macamp-cli.
//
// Exercises the read-only Metadata module (SFBAudioEngine / TagLib): reads a
// file's tags + stream properties and prints them, with optional sections for
// the derived sort keys, embedded artwork and ReplayGain. A typed
// `MetadataError` maps to a distinct non-zero exit status so shell QA can assert
// *which* failure occurred. Kept in its own file so the shared `main.swift`
// gains only one switch case (concurrency-friendly in a multi-agent tree).
import Foundation
import Metadata

/// Maps a typed ``MetadataError`` to a distinct non-zero exit status so QA can
/// assert *which* failure occurred from the shell (aligned with `decode`).
func exitCode(for error: MetadataError) -> Int32 {
    switch error {
    case .unsupportedFormat: 10
    case .corruptedFile: 11
    case .ioError: 13
    }
}

func runTags(_ args: [String]) {
    guard let path = args.first else { fail("tags requires a <file> argument", code: 2) }
    let url = URL(fileURLWithPath: path)
    do {
        let metadata = try SFBMetadataReader().readMetadata(from: url)
        printCoreTags(metadata, file: url)
        if args.contains("--print-sortkey") { printSortKeys(metadata) }
        if args.contains("--has-art") { printArtwork(metadata) }
        if args.contains("--print-replaygain") { printReplayGain(metadata) }
        print("RESULT:       OK")
    } catch let error as MetadataError {
        fail("\(error)", code: exitCode(for: error))
    } catch {
        fail("\(error)")
    }
}

// MARK: - Sections

private func printCoreTags(_ metadata: TrackMetadata, file url: URL) {
    print("file:         \(url.lastPathComponent)")
    print("reader:       SFBMetadataReader")
    print("title:        \(metadata.title ?? "-")")
    print("artist:       \(metadata.artist ?? "-")")
    print("album:        \(metadata.album ?? "-")")
    print("albumArtist:  \(metadata.albumArtist ?? "-")")
    print("genre:        \(metadata.genre ?? "-")")
    print("composer:     \(metadata.composer ?? "-")")
    print("year:         \(metadata.year.map(String.init) ?? "-")")
    print("track:        \(numberTotal(metadata.trackNumber, metadata.trackTotal))")
    print("disc:         \(numberTotal(metadata.discNumber, metadata.discTotal))")
    printProperties(metadata)
    print("lyrics:       \(lyricsSummary(metadata.lyrics))")
    print("artwork:      \(metadata.artwork.count) image(s)")
}

private func printProperties(_ metadata: TrackMetadata) {
    if let duration = metadata.duration { print(String(format: "duration:     %.3f s", duration)) }
    if let sampleRate = metadata.sampleRate { print("sampleRate:   \(Int(sampleRate)) Hz") }
    if let channels = metadata.channelCount { print("channels:     \(channels)") }
    if let bitDepth = metadata.bitDepth { print("bitDepth:     \(bitDepth)-bit") }
    if let bitrate = metadata.bitrate { print(String(format: "bitrate:      %.0f kbps", bitrate)) }
}

private func printSortKeys(_ metadata: TrackMetadata) {
    print("--- sort keys (NFC, article-stripped, folded) ---")
    print("sortTitle:    \(metadata.sortTitle ?? "-")")
    print("sortArtist:   \(metadata.sortArtist ?? "-")")
    print("sortAlbum:    \(metadata.sortAlbum ?? "-")")
    print("sortAlbumArt: \(metadata.sortAlbumArtist ?? "-")")
}

private func printArtwork(_ metadata: TrackMetadata) {
    print("--- artwork ---")
    print("hasArt:       \(metadata.hasArtwork)")
    for (index, art) in metadata.artwork.enumerated() {
        let mime = art.mimeType ?? "unknown"
        print("  art[\(index)]:     \(art.type) \(mime) \(art.data.count) bytes")
    }
}

private func printReplayGain(_ metadata: TrackMetadata) {
    print("--- replaygain ---")
    guard let gain = metadata.replayGain else {
        print("replayGain:   none")
        return
    }
    printGainField("trackGain", gain.trackGain, unit: "dB")
    printGainField("trackPeak", gain.trackPeak, unit: "")
    printGainField("albumGain", gain.albumGain, unit: "dB")
    printGainField("albumPeak", gain.albumPeak, unit: "")
    printGainField("refLoudness", gain.referenceLoudness, unit: "dB")
}

// MARK: - Formatting helpers

private func numberTotal(_ number: Int?, _ total: Int?) -> String {
    switch (number, total) {
    case let (.some(value), .some(count)): "\(value)/\(count)"
    case let (.some(value), .none): "\(value)"
    default: "-"
    }
}

private func lyricsSummary(_ lyrics: String?) -> String {
    guard let lyrics else { return "no" }
    return "yes (\(lyrics.count) chars)"
}

private func printGainField(_ label: String, _ value: Double?, unit: String) {
    guard let value else { return }
    let suffix = unit.isEmpty ? "" : " \(unit)"
    print(String(format: "  %@: %.6g%@", label, value, suffix))
}
