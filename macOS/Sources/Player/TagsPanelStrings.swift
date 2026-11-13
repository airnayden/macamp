// TagsPanelStrings — user-facing copy for the right-panel "Tags" tab that shows
// the playing track's ID3 metadata, centralized as `LocalizedStringResource` keys
// with an English `defaultValue`, exactly like `PlayerStrings` / `MacAMPStrings`.
// Unit tokens (kbps, kHz, -bit) and raw values (paths, numbers) are rendered with
// `Text(verbatim:)` at the call site and are deliberately not localized here.
import Foundation

/// Localized copy for the ID3 tags panel (tab label, sections, field labels).
enum TagsPanelStrings {
    static let title = LocalizedStringResource(
        "app.tags.title",
        defaultValue: "Tags",
        comment: "Tab label for the ID3 metadata panel in the right sidebar"
    )
    static let emptyTitle = LocalizedStringResource(
        "app.tags.empty.title",
        defaultValue: "No Track Playing",
        comment: "Title shown in the tags panel when nothing is playing"
    )
    static let emptyMessage = LocalizedStringResource(
        "app.tags.empty.message",
        defaultValue: "Tag details appear here while a track is playing.",
        comment: "Body shown in the tags panel when nothing is playing"
    )

    // MARK: Section headers

    static let sectionMetadata = LocalizedStringResource(
        "app.tags.section.metadata",
        defaultValue: "Metadata",
        comment: "Header for the tag metadata section (title/artist/album/…)"
    )
    static let sectionAudio = LocalizedStringResource(
        "app.tags.section.audio",
        defaultValue: "Audio",
        comment: "Header for the audio-format section (bitrate/sample rate/…)"
    )
    static let sectionFile = LocalizedStringResource(
        "app.tags.section.file",
        defaultValue: "File",
        comment: "Header for the file section (path/size)"
    )

    // MARK: Field labels

    static let fieldTitle = LocalizedStringResource(
        "app.tags.field.title",
        defaultValue: "Title",
        comment: "Field label for the track title tag"
    )
    static let fieldArtist = LocalizedStringResource(
        "app.tags.field.artist",
        defaultValue: "Artist",
        comment: "Field label for the artist tag"
    )
    static let fieldAlbum = LocalizedStringResource(
        "app.tags.field.album",
        defaultValue: "Album",
        comment: "Field label for the album tag"
    )
    static let fieldAlbumArtist = LocalizedStringResource(
        "app.tags.field.albumArtist",
        defaultValue: "Album Artist",
        comment: "Field label for the album-artist tag"
    )
    static let fieldGenre = LocalizedStringResource(
        "app.tags.field.genre",
        defaultValue: "Genre",
        comment: "Field label for the genre tag"
    )
    static let fieldYear = LocalizedStringResource(
        "app.tags.field.year",
        defaultValue: "Year",
        comment: "Field label for the release-year tag"
    )
    static let fieldTrackNumber = LocalizedStringResource(
        "app.tags.field.trackNumber.short",
        defaultValue: "Track No.",
        comment: "Field label for the track-number tag"
    )
    static let fieldDiscNumber = LocalizedStringResource(
        "app.tags.field.discNumber.short",
        defaultValue: "Disc No.",
        comment: "Field label for the disc-number tag"
    )
    static let fieldBitrate = LocalizedStringResource(
        "app.tags.field.bitrate",
        defaultValue: "Bitrate",
        comment: "Field label for the audio bitrate"
    )
    static let fieldSampleRate = LocalizedStringResource(
        "app.tags.field.sampleRate",
        defaultValue: "Sample Rate",
        comment: "Field label for the audio sample rate"
    )
    static let fieldBitDepth = LocalizedStringResource(
        "app.tags.field.bitDepth",
        defaultValue: "Bit Depth",
        comment: "Field label for the audio bit depth"
    )
    static let fieldChannels = LocalizedStringResource(
        "app.tags.field.channels",
        defaultValue: "Channels",
        comment: "Field label for the audio channel count"
    )
    static let fieldDuration = LocalizedStringResource(
        "app.tags.field.duration",
        defaultValue: "Duration",
        comment: "Field label for the track duration"
    )
    static let fieldFilePath = LocalizedStringResource(
        "app.tags.field.filePath",
        defaultValue: "File Path",
        comment: "Field label for the backing file path"
    )
    static let fieldFileSize = LocalizedStringResource(
        "app.tags.field.fileSize",
        defaultValue: "File Size",
        comment: "Field label for the backing file size"
    )
}
