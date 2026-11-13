// PlayerStrings — localized copy for the Task 26 player / EQ / lyrics surface.
//
// Defined as an `extension MacAMPStrings` so every player string lives under the
// same `app.*` namespace as Task 25's shell copy while staying inside the
// `Player/` folder (clean staging). Views reference these constants — never a
// bare literal — so the surface is localization-clean by construction and passes
// `scripts/check-hardcoded-strings.sh`. The "MacAMP" brand is NEVER localized.
import Foundation
import Services

extension MacAMPStrings {
    // MARK: Player panes

    static let playerNowPlaying = LocalizedStringResource(
        "app.player.nowPlaying",
        defaultValue: "Now Playing",
        comment: "Title of the now-playing pane in the full player"
    )
    static let playerEqualizer = LocalizedStringResource(
        "app.player.equalizer",
        defaultValue: "Equalizer",
        comment: "Title of the equalizer pane in the full player"
    )
    static let playerLyrics = LocalizedStringResource(
        "app.player.lyrics",
        defaultValue: "Lyrics",
        comment: "Title of the lyrics pane in the full player"
    )
    static let playerClose = LocalizedStringResource(
        "app.player.close",
        defaultValue: "Close",
        comment: "Accessibility label for the button that dismisses the full player"
    )
    static let playerOpen = LocalizedStringResource(
        "app.player.open",
        defaultValue: "Open the full player",
        comment: "Accessibility label for tapping the transport bar to open the full player"
    )

    // MARK: Replay heat

    /// Names the replay-heat curve drawn behind a seek scrubber. One key serves
    /// every surface: a visible caption where there is room (full player, expanded
    /// overlay) and a tooltip where there is not (the 18 pt player-bar row).
    static let playerMostReplayed = LocalizedStringResource(
        "app.player.mostReplayed",
        defaultValue: "Most Replayed",
        comment: "Caption and tooltip naming the replay-heat curve drawn behind the seek scrubber"
    )

    // MARK: ReplayGain

    static let playerReplayGain = LocalizedStringResource(
        "app.player.replayGain",
        defaultValue: "ReplayGain",
        comment: "Label for the ReplayGain normalization-mode control"
    )
    static let playerReplayGainOff = LocalizedStringResource(
        "app.player.replayGain.off",
        defaultValue: "Off",
        comment: "ReplayGain mode: normalization disabled"
    )
    static let playerReplayGainTrack = LocalizedStringResource(
        "app.player.replayGain.track",
        defaultValue: "Track",
        comment: "ReplayGain mode: normalize each track to a consistent loudness"
    )
    static let playerReplayGainAlbum = LocalizedStringResource(
        "app.player.replayGain.album",
        defaultValue: "Album",
        comment: "ReplayGain mode: normalize per album, preserving album dynamics"
    )

    /// The localized display name for a ReplayGain mode.
    static func playerReplayGainName(_ mode: ReplayGainMode) -> LocalizedStringResource {
        switch mode {
        case .off: playerReplayGainOff
        case .track: playerReplayGainTrack
        case .album: playerReplayGainAlbum
        }
    }

    // MARK: Equalizer

    static let eqPreset = LocalizedStringResource(
        "app.eq.preset",
        defaultValue: "Preset",
        comment: "Label for the EQ preset picker"
    )
    static let eqCustom = LocalizedStringResource(
        "app.eq.custom",
        defaultValue: "Custom",
        comment: "EQ preset picker entry shown after a manual band edit"
    )
    static let eqPreamp = LocalizedStringResource(
        "app.eq.preamp",
        defaultValue: "Preamp",
        comment: "Label for the EQ pre-amplification read-out"
    )
    static let eqReset = LocalizedStringResource(
        "app.eq.reset",
        defaultValue: "Reset",
        comment: "Button that flattens every EQ band to 0 dB"
    )
    static let eqBandGain = LocalizedStringResource(
        "app.eq.bandGain",
        defaultValue: "Band gain",
        comment: "Accessibility label prefix for one EQ band fader"
    )

    // MARK: Lyrics

    static let lyricsEmptyTitle = LocalizedStringResource(
        "app.lyrics.empty.title",
        defaultValue: "No Lyrics",
        comment: "Title shown when a track has no resolvable lyrics"
    )
    static let lyricsEmptyMessage = LocalizedStringResource(
        "app.lyrics.empty.message",
        defaultValue: "Lyrics will appear here when they're available for this track.",
        comment: "Body shown when a track has no resolvable lyrics"
    )
    static let lyricsFetch = LocalizedStringResource(
        "app.lyrics.fetch",
        defaultValue: "Fetch Lyrics",
        comment: "Button that manually triggers an online lyrics search for the current track"
    )
    static let lyricsFetchNoMatch = LocalizedStringResource(
        "app.lyrics.fetch.noMatch",
        defaultValue: "No lyrics found for this track",
        comment: "Status shown after a manual lyrics fetch that completed but matched nothing"
    )
    static let lyricsFetchFailed = LocalizedStringResource(
        "app.lyrics.fetch.failed",
        defaultValue: "Couldn't reach the lyrics service",
        comment: "Status shown when a manual lyrics fetch could not reach the online service"
    )
    static let lyricsFetching = LocalizedStringResource(
        "app.lyrics.fetch.loading",
        defaultValue: "Fetching lyrics…",
        comment: "Progress label while a lyrics lookup is running"
    )
    static let lyricsFetchInvalidRequest = LocalizedStringResource(
        "app.lyrics.fetch.invalidRequest",
        defaultValue: "The lyrics request could not be created.",
        comment: "Failure detail when the lyrics service request URL is invalid"
    )
    static let lyricsFetchInvalidResponse = LocalizedStringResource(
        "app.lyrics.fetch.invalidResponse",
        defaultValue: "The lyrics service returned an invalid response. Try again.",
        comment: "Failure detail when the lyrics service response cannot be decoded"
    )
    static func lyricsFetchHTTPFailure(_ status: Int, reason: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.lyrics.fetch.httpFailure",
            defaultValue: "LRCLIB returned HTTP \(status) (\(reason)).",
            comment: "Lyrics service failure with the HTTP status code and system-provided description"
        )
    }
    static func lyricsFetchNetworkFailure(_ code: Int, reason: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.lyrics.fetch.networkFailure",
            defaultValue: "Network error \(code). \(reason)",
            comment: "Lyrics network failure with the system error code and description"
        )
    }
    static func lyricsFetchFailureDetail(_ reason: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.lyrics.fetch.failureDetail",
            defaultValue: "Lyrics lookup failed. \(reason)",
            comment: "Lyrics lookup failure with the error description supplied by the provider"
        )
    }
}
