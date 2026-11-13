// InfoPanelStrings — user-facing copy for the right-panel "Info" tab and the
// album/artist detail info sections, centralized as `LocalizedStringResource` keys
// with an English `defaultValue`, exactly like `TagsPanelStrings` / `MacAMPStrings`.
// This tab shows narrative info (biography, album story, track description) fetched
// from MusicBrainz + Wikipedia, distinct from the raw tag fields the Tags tab shows.
import Foundation

/// Localized copy for the online-info panel (tab label, section headers, states).
enum InfoPanelStrings {
    static let title = LocalizedStringResource(
        "app.info.title",
        defaultValue: "Info",
        comment: "Tab label for the artist/album/track info panel in the right sidebar"
    )
    static let emptyTitle = LocalizedStringResource(
        "app.info.empty.title",
        defaultValue: "No Track Playing",
        comment: "Title shown in the info panel when nothing is playing"
    )
    static let emptyMessage = LocalizedStringResource(
        "app.info.empty.message",
        defaultValue: "Artist, album, and track info appear here while a track is playing.",
        comment: "Body shown in the info panel when nothing is playing"
    )
    static let noInfo = LocalizedStringResource(
        "app.info.none",
        defaultValue: "No info available",
        comment: "Shown when no online info could be resolved for the current track"
    )

    // MARK: Section headers

    static let trackHeading = LocalizedStringResource(
        "app.info.section.track",
        defaultValue: "About This Track",
        comment: "Header for the track-description section of the info panel"
    )
    static let artistHeading = LocalizedStringResource(
        "app.info.section.artist",
        defaultValue: "About the Artist",
        comment: "Header for the artist-biography section of the info panel"
    )
    static let albumHeading = LocalizedStringResource(
        "app.info.section.album",
        defaultValue: "About the Album",
        comment: "Header for the album-description section of the info panel"
    )
    static let retry = LocalizedStringResource(
        "app.info.retry",
        defaultValue: "Retry",
        comment: "Button label to retry fetching info that failed to load"
    )
}
