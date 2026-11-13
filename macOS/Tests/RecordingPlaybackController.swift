// RecordingPlaybackController — the shell's own recording ``ToolboxPlaybackControlling``.
//
// A LOCAL double rather than `PlayerCoreTestSupport`'s `FakeToolboxPlaybackController`,
// and the reason is a build-graph fact rather than a preference: Tuist does not
// expose `PlayerCoreTestSupport` as an external product to this target, and adding
// it would mean changing the workspace manifest and re-resolving the lockfile to
// borrow forty lines.
//
// It is deliberately SIMPLER than the package's fake, because these tests ask a
// different question. The package suite asks "does the tool render the state the
// seam returned"; this one asks "does a call that crossed the MCP wire reach the
// seam at all". So there is no transport model here — just a ledger and a fixed
// answer.
import Foundation
import Services

actor RecordingPlaybackController: ToolboxPlaybackControlling {
    struct QueueCall: Equatable {
        var ids: [Int64]
        var position: ToolboxQueuePosition
    }

    private(set) var playCalls: [[Int64]] = []
    private(set) var queueCalls: [QueueCall] = []
    private(set) var transportCalls: [ToolboxTransportAction] = []
    private(set) var snapshotRequests: [Int] = []

    private var current: ToolboxPlaybackEntry?

    func playbackSnapshot(upNextLimit: Int) -> ToolboxPlaybackSnapshot {
        snapshotRequests.append(upNextLimit)
        return snapshot()
    }

    func playTracks(ids: [Int64]) -> ToolboxPlaybackSnapshot {
        playCalls.append(ids)
        current = ids.first.map { ToolboxPlaybackEntry(trackId: $0, title: "Aurora Anthem", artist: "Fixture Artist") }
        return snapshot()
    }

    func queueTracks(ids: [Int64], position: ToolboxQueuePosition) -> ToolboxPlaybackSnapshot {
        queueCalls.append(QueueCall(ids: ids, position: position))
        return snapshot()
    }

    func perform(_ action: ToolboxTransportAction) -> ToolboxPlaybackSnapshot {
        transportCalls.append(action)
        if action == .stop { current = nil }
        return snapshot()
    }

    private func snapshot() -> ToolboxPlaybackSnapshot {
        ToolboxPlaybackSnapshot(activity: current == nil ? .stopped : .playing, current: current)
    }
}
