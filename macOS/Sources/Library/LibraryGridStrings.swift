// LibraryGridStrings — user-facing copy for the Albums and Artists grid browsers.
//
// Every label resolves through a `LocalizedStringResource` with an English
// `defaultValue`; counts use automatic grammar agreement (`^[…](inflect: true)`)
// so "1 track" / "2 tracks" read correctly without a stringsdict. The dotted keys
// (`app.library.<area>.<element>`) are the handoff list for localization.
import Foundation

/// Localized copy for the Albums / Artists grids and their detail screens.
enum LibraryGridStrings {
    static let albumsTitle = LocalizedStringResource(
        "app.library.albums.title",
        defaultValue: "Albums",
        comment: "Navigation title for the Albums grid"
    )
    static let artistsTitle = LocalizedStringResource(
        "app.library.artists.title",
        defaultValue: "Artists",
        comment: "Navigation title for the Artists grid"
    )
    static let untitledAlbum = LocalizedStringResource(
        "app.library.album.untitled",
        defaultValue: "Untitled Album",
        comment: "Placeholder shown for an album with no title"
    )
    static let unknownArtist = LocalizedStringResource(
        "app.library.artist.unknown",
        defaultValue: "Unknown Artist",
        comment: "Placeholder shown for an artist with no name"
    )
    static let albumsEmpty = LocalizedStringResource(
        "app.library.albums.empty",
        defaultValue: "No albums yet",
        comment: "Empty-state message when the library has no albums"
    )
    static let artistsEmpty = LocalizedStringResource(
        "app.library.artists.empty",
        defaultValue: "No artists yet",
        comment: "Empty-state message when the library has no artists"
    )
    static let playAll = LocalizedStringResource(
        "app.library.album.playAll",
        defaultValue: "Play All",
        comment: "Button that plays every track on the album in order"
    )
    static let shuffle = LocalizedStringResource(
        "app.library.album.shuffle",
        defaultValue: "Shuffle",
        comment: "Button that plays the album's tracks in a shuffled order"
    )

    /// `String(localized:)` does NOT run `^[…](inflect: true)` morphology on an
    /// inline `defaultValue` (it returns raw markup); `AttributedString` does.
    private static func resolvedInflection(_ resource: LocalizedStringResource) -> String {
        String(AttributedString(localized: resource).characters)
    }

    static func trackCount(_ count: Int) -> String {
        resolvedInflection(LocalizedStringResource(
            "app.library.album.trackCount",
            defaultValue: "^[\(count) track](inflect: true)",
            comment: "Number of tracks on an album, e.g. '12 tracks'"
        ))
    }

    static func albumCount(_ count: Int) -> String {
        resolvedInflection(LocalizedStringResource(
            "app.library.artist.albumCount",
            defaultValue: "^[\(count) album](inflect: true)",
            comment: "Number of albums by an artist, e.g. '3 albums'"
        ))
    }

    static let sortByName = LocalizedStringResource(
        "app.library.sort.byName",
        defaultValue: "Sort by Name",
        comment: "Tooltip for the sort-by-name button in album/artist grids"
    )
    static let sortByYear = LocalizedStringResource(
        "app.library.sort.byYear",
        defaultValue: "Sort by Year",
        comment: "Tooltip for the sort-by-year button in album/artist grids"
    )
}
