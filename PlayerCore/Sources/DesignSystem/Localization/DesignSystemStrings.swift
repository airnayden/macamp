import Foundation

/// Every user-facing string in the design system, centralized as
/// `LocalizedStringResource` keys with an English `defaultValue`.
///
/// Components reference these constants — never a bare literal — so the layer is
/// localization-clean by construction. Until Task 44 syncs the keys into the app
/// String Catalogs (`macOS/Sources/Localizable.xcstrings` et al.), the
/// `defaultValue` renders, so previews and the gallery show real copy. The dotted
/// keys follow the project convention (`designSystem.<area>.<element>`).
public enum DesignSystemStrings {
    // MARK: Transport (accessibility labels)

    public static let transportPlay = LocalizedStringResource(
        "designSystem.transport.play",
        defaultValue: "Play",
        comment: "Accessibility label for the play button"
    )
    public static let transportPause = LocalizedStringResource(
        "designSystem.transport.pause",
        defaultValue: "Pause",
        comment: "Accessibility label for the pause button"
    )
    public static let transportStop = LocalizedStringResource(
        "designSystem.transport.stop",
        defaultValue: "Stop",
        comment: "Accessibility label for the stop button"
    )
    public static let transportNext = LocalizedStringResource(
        "designSystem.transport.next",
        defaultValue: "Next track",
        comment: "Accessibility label for the skip-forward button"
    )
    public static let transportPrevious = LocalizedStringResource(
        "designSystem.transport.previous",
        defaultValue: "Previous track",
        comment: "Accessibility label for the skip-back button"
    )
    public static let transportShuffle = LocalizedStringResource(
        "designSystem.transport.shuffle",
        defaultValue: "Shuffle",
        comment: "Accessibility label for the shuffle toggle"
    )
    public static let transportRepeat = LocalizedStringResource(
        "designSystem.transport.repeat",
        defaultValue: "Repeat",
        comment: "Accessibility label for the repeat toggle"
    )

    // MARK: Sliders (accessibility labels)

    public static let seekLabel = LocalizedStringResource(
        "designSystem.slider.seek",
        defaultValue: "Playback position",
        comment: "Accessibility label for the seek slider"
    )
    public static let volumeLabel = LocalizedStringResource(
        "designSystem.slider.volume",
        defaultValue: "Volume",
        comment: "Accessibility label for the volume slider"
    )
    public static let balanceLabel = LocalizedStringResource(
        "designSystem.slider.balance",
        defaultValue: "Balance",
        comment: "Accessibility label for the stereo balance slider"
    )

    // MARK: Artwork

    public static let artworkLabel = LocalizedStringResource(
        "designSystem.artwork.label",
        defaultValue: "Album artwork",
        comment: "Accessibility label for displayed album artwork"
    )
    public static let artworkPlaceholder = LocalizedStringResource(
        "designSystem.artwork.placeholder",
        defaultValue: "No album artwork",
        comment: "Accessibility label for the artwork placeholder when none is available"
    )

    // MARK: Empty / loading / offline states

    public static let emptyTitle = LocalizedStringResource(
        "designSystem.state.empty.title",
        defaultValue: "Nothing here yet",
        comment: "Title shown when a list or view has no content"
    )
    public static let emptyMessage = LocalizedStringResource(
        "designSystem.state.empty.message",
        defaultValue: "Your music will appear here once you add it.",
        comment: "Supporting text for the empty state"
    )
    public static let loadingTitle = LocalizedStringResource(
        "designSystem.state.loading.title",
        defaultValue: "Loading…",
        comment: "Title shown while content is loading"
    )
    public static let offlineTitle = LocalizedStringResource(
        "designSystem.state.offline.title",
        defaultValue: "You're offline",
        comment: "Title shown when the device has no network connection"
    )
    public static let offlineMessage = LocalizedStringResource(
        "designSystem.state.offline.message",
        defaultValue: "Reconnect to stream and sync your library.",
        comment: "Supporting text for the offline state"
    )

    // MARK: Acknowledgments

    public static let acknowledgmentsTitle = LocalizedStringResource(
        "designSystem.acknowledgments.title",
        defaultValue: "Open-Source Software",
        comment: "Heading of the acknowledgments screen"
    )
    public static let acknowledgmentsIntro = LocalizedStringResource(
        "designSystem.acknowledgments.intro",
        defaultValue: "Built with the help of these open-source projects.",
        comment: "Introductory line above the list of bundled open-source components"
    )
    public static let acknowledgmentsLearnMore = LocalizedStringResource(
        "designSystem.acknowledgments.learnMore",
        defaultValue: "Learn More",
        comment: "Link that opens a bundled component's project homepage"
    )

    // MARK: Replay heat (accessibility label)

    public static let replayHeatLabel = LocalizedStringResource(
        "designSystem.replayHeat.label",
        defaultValue: "Most replayed",
        comment: "Accessibility label for the replay-heat curve drawn behind the seek scrubber"
    )
}
