import Foundation

extension MacAMPStrings {
    static let filterTracks = LocalizedStringResource(
        "app.library.filter.tracks", defaultValue: "Filter tracks",
        comment: "Filter only the tracks in the current list; separate from global library search"
    )
    static let filterAlbums = LocalizedStringResource(
        "app.library.filter.albums", defaultValue: "Filter albums",
        comment: "Filter the albums grid"
    )
    static let filterArtists = LocalizedStringResource(
        "app.library.filter.artists", defaultValue: "Filter artists",
        comment: "Filter the artists grid"
    )
    static let resetBalance = LocalizedStringResource(
        "app.player.balance.reset", defaultValue: "Reset balance",
        comment: "Restore centered stereo balance, accessibility label and help for the icon button"
    )
}
