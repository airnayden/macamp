// PlayEventSignal — the coordinator's "a play just ended" transition signal.
//
// The pre-existing lifecycle hooks (`onTrackPlayed` / `onTrackStarted` /
// `onTrackListened`) carry only an `Int64`, which is not enough to write a play
// event: the recorder runs AFTER the coordinator has already mutated its queue,
// so the outgoing track's identity, begin time and elapsed position are gone by
// then. This value type is the pre-mutation snapshot of exactly those facts,
// captured at the single emission choke point (``PlaybackCoordinator``'s
// `emitOutgoingPlayEvent(reason:)`) and handed to the listener verbatim.
//
// This file imports only Foundation; it MUST NOT import AppKit or UIKit
// (PlayerCore portability invariant).
import Foundation

/// Why a play ended.
public enum PlayEndReason: String, Sendable, Equatable, Hashable, CaseIterable, Codable {
    /// The item played through to its natural end.
    case natural
    /// The listener skipped forward.
    case userNext
    /// The listener stepped backward.
    case userPrevious
    /// The listener jumped elsewhere — picked another track, or replaced the queue.
    case jump
    /// Playback ended outright: stop, clear-queue, or app termination.
    case stopped
    /// The active profile changed underneath the play.
    case profileSwitch
}

/// One finished play, snapshotted at the instant the transition happened.
///
/// Every field describes the **outgoing** item — the one that just stopped being
/// heard — never its successor. ``startedAt`` and ``elapsedSeconds`` are captured
/// before any queue or engine mutation, which is what lets a listener write a
/// durable history row without re-reading state that no longer exists.
public struct PlayEventSignal: Sendable, Equatable, Hashable {
    /// The outgoing item's library `track.id`, or `nil` when it had none.
    public var outgoingTrackId: Int64?
    /// Title as known at capture time.
    public var title: String?
    /// Artist as known at capture time.
    public var artist: String?
    /// When the play began, in seconds since the Unix epoch.
    public var startedAt: Double
    /// The playhead position when the play ended, in seconds.
    public var elapsedSeconds: Double
    /// The outgoing item's full length in seconds (`0` when unknown).
    public var durationSeconds: Double
    /// What ended the play.
    public var reason: PlayEndReason
    /// Whether shuffle was engaged for this play.
    public var shuffle: Bool
    /// The surface playback was started from — see ``PlayEventSourceSurface``.
    public var sourceSurface: String

    public init(
        outgoingTrackId: Int64? = nil,
        title: String? = nil,
        artist: String? = nil,
        startedAt: Double,
        elapsedSeconds: Double,
        durationSeconds: Double,
        reason: PlayEndReason,
        shuffle: Bool = false,
        sourceSurface: String = PlayEventSourceSurface.unknown
    ) {
        self.outgoingTrackId = outgoingTrackId
        self.title = title
        self.artist = artist
        self.startedAt = startedAt
        self.elapsedSeconds = elapsedSeconds
        self.durationSeconds = durationSeconds
        self.reason = reason
        self.shuffle = shuffle
        self.sourceSurface = sourceSurface
    }
}

/// The flat, persisted spelling of the surface a play was started from.
///
/// Deliberately a `String` rather than a second enum: ``PlaybackSource`` is
/// already frozen and persisted with a tagged representation whose decode rejects
/// unknown *tags*, so introducing a new tag would break forward compatibility.
/// This is a pure, total projection of that type onto stable analytics tokens —
/// it adds no case and changes no encoding.
public enum PlayEventSourceSurface {
    /// No navigable source was in effect.
    public static let unknown = "unknown"
    /// The play came from the user's manual queue, which carries no context source.
    public static let manualQueue = "queue"
    /// The library's "all tracks" section.
    public static let library = "library"

    /// The `librarySection` payload that projects onto ``library``.
    static let allTracksSection = "allTracks"

    /// Projects a (possibly absent) playback source onto its stable token.
    public static func surface(for source: PlaybackSource?) -> String {
        guard let source else { return unknown }
        return token(for: source)
    }

    private static func token(for source: PlaybackSource) -> String {
        switch source {
        case let .librarySection(section): librarySurface(section)
        case .folder: "folder"
        case .playlist: "playlist"
        case .favourites: "favourites"
        case .karaokeReady: "karaoke"
        case .search: "search"
        case .albumDetail: "album"
        case .artistDetail: "artist"
        case .stats: "stats"
        }
    }

    /// Library sections carry their own stable raw string, so they pass through
    /// unchanged — except "all tracks", which reads better as ``library``.
    private static func librarySurface(_ section: String) -> String {
        section == allTracksSection ? library : section
    }
}
