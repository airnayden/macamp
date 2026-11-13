// RepeatMode — the end-of-track / end-of-queue repeat policy.
//
// Modelled as a three-case enum (never a pair of Bools) so the states are
// mutually exclusive by construction. `Codable` so it persists inside a
// ``CoordinatorSnapshot``; `CaseIterable` so a UI can cycle through the modes.
//
// This file imports only Foundation; it MUST NOT import AppKit or UIKit
// (PlayerCore portability invariant).
import Foundation

/// How the coordinator behaves when a track finishes or the queue ends.
public enum RepeatMode: String, Sendable, Codable, CaseIterable, Equatable {
    /// Play through the queue once, then stop.
    case off
    /// Repeat the current track indefinitely (auto-advance replays it).
    case one
    /// Wrap around to the start of the queue after the last track.
    case all
}
