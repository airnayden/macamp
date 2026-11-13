// PlaySegmentPlayhead — the three live readings the replay-heatmap tracker samples.
//
// Its own file so `PlaySegmentTracker.swift` stays inside the SwiftLint file
// budget, and because this is the seam a test replaces: hand it three closures and
// the tracker runs with no engine, no queue and no coordinator.
//
// This file imports only Foundation; it MUST NOT import AppKit or UIKit
// (PlayerCore portability invariant).
import Foundation

/// The live playback readings the tracker samples.
///
/// Injected as closures rather than a coordinator reference: the tracker needs
/// three scalars, and taking them this way keeps it drivable from a test with no
/// engine and no queue.
@MainActor
public struct PlaySegmentPlayhead {
    /// The track the transport is on right now, if any.
    public var currentTrack: () -> TrackRef?
    /// The engine's playhead, in seconds. Read on the main actor, never the render thread.
    public var currentTime: () -> TimeInterval
    /// The profile listening right now.
    public var activeProfileId: () -> Int64

    public init(
        currentTrack: @escaping () -> TrackRef?,
        currentTime: @escaping () -> TimeInterval,
        activeProfileId: @escaping () -> Int64
    ) {
        self.currentTrack = currentTrack
        self.currentTime = currentTime
        self.activeProfileId = activeProfileId
    }
}
