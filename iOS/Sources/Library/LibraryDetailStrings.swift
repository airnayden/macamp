// LibraryDetailStrings — localized copy for the iOS album / artist detail
// destinations (Task 33). Kept in its own file (an `extension MacAMPStrings`) so
// it never clobbers the shared MacAMPStrings.swift while concurrent feature tasks
// land — the same convention GenreFilterStrings.swift follows. Album, artist, and
// track NAMES are non-translatable display text rendered with `Text(verbatim:)` at
// the call site; only these chrome labels are localized. The `defaultValue`
// renders real English until Task 44 syncs the keys into `Localizable.xcstrings`.
import Foundation

extension MacAMPStrings {
    // MARK: Album detail

    static let albumPlay = LocalizedStringResource(
        "ios.album.play",
        defaultValue: "Play",
        comment: "Button that plays an album from its first track"
    )
    static let albumShuffle = LocalizedStringResource(
        "ios.album.shuffle",
        defaultValue: "Shuffle",
        comment: "Button that plays an album in shuffled order"
    )
    static let albumSongsHeader = LocalizedStringResource(
        "ios.album.songs",
        defaultValue: "Songs",
        comment: "Section header above an album's track list"
    )
    static let albumEmptyTitle = LocalizedStringResource(
        "ios.album.empty.title",
        defaultValue: "No Songs",
        comment: "Title shown when an album has no tracks in the library"
    )
    static let albumEmptyMessage = LocalizedStringResource(
        "ios.album.empty.message",
        defaultValue: "This album has no songs in your library.",
        comment: "Body shown when an album has no tracks in the library"
    )

    // MARK: Artist detail

    static let artistPlay = LocalizedStringResource(
        "ios.artist.play",
        defaultValue: "Play",
        comment: "Button that plays every track by an artist from the first"
    )
    static let artistShuffle = LocalizedStringResource(
        "ios.artist.shuffle",
        defaultValue: "Shuffle",
        comment: "Button that plays every track by an artist in shuffled order"
    )
    static let artistAlbumsHeader = LocalizedStringResource(
        "ios.artist.albums",
        defaultValue: "Albums",
        comment: "Section header above an artist's album grid"
    )
    static let artistSongsHeader = LocalizedStringResource(
        "ios.artist.songs",
        defaultValue: "Songs",
        comment: "Section header above an artist's track list"
    )
    static let artistEmptyTitle = LocalizedStringResource(
        "ios.artist.empty.title",
        defaultValue: "Nothing Here",
        comment: "Title shown when an artist has no albums or tracks in the library"
    )
    static let artistEmptyMessage = LocalizedStringResource(
        "ios.artist.empty.message",
        defaultValue: "This artist has no songs in your library.",
        comment: "Body shown when an artist has no albums or tracks in the library"
    )
}
