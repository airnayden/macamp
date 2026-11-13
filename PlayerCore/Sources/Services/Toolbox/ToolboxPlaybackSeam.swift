// ToolboxPlaybackSeam — the one seam through which a tool may touch the PLAYER.
//
// ── WHY THIS IS A SEAM AND NOT A COORDINATOR REFERENCE ────────────────────────
//
// `PlaybackCoordinating` is `@MainActor` and lives beside the toolbox in
// `Services`, so a direct reference would compile. It is still wrong for the same
// reason ``ToolboxProposalFiling`` is a seam: a `LibraryTool.execute` closure is
// `@Sendable` and nonisolated, the toolbox is a `Sendable` value copied into three
// adapters, and hanging a main-actor class off it would make every tool call an
// actor hop the toolbox cannot see. The requirements are therefore `async`, which
// is precisely what lets a `@MainActor` composition root witness them — the
// mechanism ``ToolboxProposalFiling`` documents, reused verbatim.
//
// ── WHY THE SEAM SPEAKS IDS, NOT `TrackRef`s ──────────────────────────────────
//
// `TrackRef` carries `filePath`, and the standing invariant this whole layer is
// built around is that NO file path exists anywhere under `Toolbox/` (see
// `ToolboxRendering.swift`'s header). Handing the seam `[TrackRef]` would put one
// there — inside a value the tool constructed — and the privacy sweep, which reads
// rendered text and payload JSON, would not catch it.
//
// So the tool validates ids against the ACTIVE profile's visible library and hands
// the seam ids. The witness resolves them again, on the main actor, where paths
// legitimately live. That is one extra indexed batch read of at most
// ``ToolResultBudget/identifierBatchLimit`` rows per call, and it buys an
// invariant that can be stated absolutely rather than nearly.
//
// ── EVERY ACTION ANSWERS WITH THE RESULTING STATE ─────────────────────────────
//
// A control tool has to tell the model what actually happened, and "what happened"
// is a state, not a return code. Answering with a fresh ``ToolboxPlaybackSnapshot``
// means `play_tracks` can say which track started without a second `tools/call`,
// and means a `transport("next")` at the end of the queue reports "nothing is
// playing" instead of claiming success. No requirement throws: a player that
// refused to do something still has a state, and a thrown error would cost the
// model a round-trip for information it can read.
//
// ── THESE ACTIONS ARE IMMEDIATE, AND THAT IS DELIBERATE ───────────────────────
//
// ``ToolboxProposalFiling`` files an offer because a library MUTATION is durable,
// invisible until reviewed, and expensive to undo. Playback is none of those: it is
// ephemeral, local, audible the instant it happens, and reversed by pressing pause.
// A review gate on "play this" would be a confirmation dialog for an action the
// listener can hear and cancel — friction with no safety in it. There is
// deliberately NO settings-mutation seam here: theme, EQ and preferences are
// durable, silent and off-limits to every tier.
//
// This file imports only Foundation; it MUST NOT import AppKit or UIKit
// (PlayerCore portability invariant).
import Foundation

// MARK: - What a player reports

/// One track as the PLAYER sees it: identity and display text, never a path.
///
/// Deliberately not `TrackRecord`: what is playing may have left the visible
/// library since it started (a profile switch, a root removed), and the player
/// still has to be able to name it. Every field is optional because a queue entry
/// built from a bare file has no library row behind it.
public struct ToolboxPlaybackEntry: Sendable, Equatable, Hashable {
    /// The library row id, or `nil` for an entry with no row behind it.
    public var trackId: Int64?
    public var title: String?
    public var artist: String?
    public var durationSeconds: Double?

    public init(
        trackId: Int64? = nil,
        title: String? = nil,
        artist: String? = nil,
        durationSeconds: Double? = nil
    ) {
        self.trackId = trackId
        self.title = title
        self.artist = artist
        self.durationSeconds = durationSeconds
    }
}

/// What the transport is doing. The three states a listener would name.
///
/// `PlaybackState` has a fourth (`idle`), which is `stopped` with nothing loaded —
/// a distinction the player needs and a model does not.
public enum ToolboxPlaybackActivity: String, Sendable, Equatable, Hashable, CaseIterable {
    case playing
    case paused
    case stopped
}

/// The repeat setting, in the wire vocabulary a tool reports it with.
///
/// Mirrors `RepeatMode` rather than re-exporting it: `RepeatMode` is the player's
/// enum and may grow a case that has no place in a tool's answer, and this side is
/// a wire format that must not move when that happens.
public enum ToolboxRepeatSetting: String, Sendable, Equatable, Hashable, CaseIterable {
    case off
    case one
    case all
}

/// Everything a control tool may report about the player.
public struct ToolboxPlaybackSnapshot: Sendable, Equatable {
    public var activity: ToolboxPlaybackActivity
    /// What is loaded, whether or not it is advancing.
    public var current: ToolboxPlaybackEntry?
    /// Seconds into ``current``. `0` when nothing is loaded.
    public var elapsedSeconds: Double
    /// ``current``'s length as the ENGINE reports it, `0` when unknown.
    public var durationSeconds: Double
    public var isShuffling: Bool
    public var repeatSetting: ToolboxRepeatSetting
    /// The next entries in play order, already bounded by the witness to the
    /// `upNextLimit` it was asked for.
    public var upNext: [ToolboxPlaybackEntry]
    /// How many entries follow ``current`` in total — always `>= upNext.count`, so
    /// a tool can say "10 of 214" honestly.
    public var upNextTotal: Int

    public init(
        activity: ToolboxPlaybackActivity = .stopped,
        current: ToolboxPlaybackEntry? = nil,
        elapsedSeconds: Double = 0,
        durationSeconds: Double = 0,
        isShuffling: Bool = false,
        repeatSetting: ToolboxRepeatSetting = .off,
        upNext: [ToolboxPlaybackEntry] = [],
        upNextTotal: Int? = nil
    ) {
        self.activity = activity
        self.current = current
        self.elapsedSeconds = elapsedSeconds
        self.durationSeconds = durationSeconds
        self.isShuffling = isShuffling
        self.repeatSetting = repeatSetting
        self.upNext = upNext
        self.upNextTotal = max(upNextTotal ?? upNext.count, upNext.count)
    }

    /// Nothing loaded, nothing queued — what a fresh launch reports.
    public static let idle = ToolboxPlaybackSnapshot()
}

// MARK: - What a player is asked to do

/// Where `queue_tracks` puts what it is given.
///
/// Both land in the coordinator's MANUAL queue, which takes precedence over the
/// browsing context on every forward advance — so "next" and "last" are positions
/// within that queue, not edits to whatever list the listener is browsing. That is
/// the existing "Play Next" / "Add to Queue" semantics, unchanged.
public enum ToolboxQueuePosition: String, Sendable, Equatable, Hashable, CaseIterable {
    /// Before everything already queued manually — the next thing to play.
    case next
    /// After everything already queued manually.
    case last
}

/// The transport verbs a tool may press.
///
/// No volume verb, deliberately: v1 excludes it (see the decisions entry). It is
/// cheap to add later precisely because this enum is the only place that would
/// change.
public enum ToolboxTransportAction: String, Sendable, Equatable, Hashable, CaseIterable {
    case play
    case pause
    case next
    case previous
    case stop
}

/// The player, as much of it as a tool may reach.
///
/// Nothing here mutates the LIBRARY, the settings, or anything that outlives the
/// session — see the file header for why that boundary is where it is. The
/// composition root witnesses this over the real `PlaybackCoordinating`; a Fake
/// ships in `PlayerCoreTestSupport` so every tool test is hermetic.
public protocol ToolboxPlaybackControlling: Sendable {
    /// The player's current state, with at most `upNextLimit` upcoming entries.
    func playbackSnapshot(upNextLimit: Int) async -> ToolboxPlaybackSnapshot

    /// Replaces the queue with `ids`, in the given order, and starts playing.
    ///
    /// `ids` have ALREADY been validated against the active profile's visible
    /// library by the tool; a witness that cannot resolve one drops it rather than
    /// failing the call, because the tool has already told the model which ids it
    /// accepted.
    func playTracks(ids: [Int64]) async -> ToolboxPlaybackSnapshot

    /// Adds `ids` to the manual queue at `position`, without disturbing what is
    /// playing.
    func queueTracks(ids: [Int64], position: ToolboxQueuePosition) async -> ToolboxPlaybackSnapshot

    /// Presses one transport verb.
    func perform(_ action: ToolboxTransportAction) async -> ToolboxPlaybackSnapshot
}
