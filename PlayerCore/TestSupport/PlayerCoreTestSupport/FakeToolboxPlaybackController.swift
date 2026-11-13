import Foundation
import Services

/// A recording ``ToolboxPlaybackControlling`` with just enough player behaviour to
/// make an assertion meaningful.
///
/// Two jobs, and both are needed. It CAPTURES every call, so a test can assert
/// that a tool forwarded exactly the ids it said it accepted — which is the whole
/// point of the per-id validation. And it MODELS a tiny transport, so the state
/// sentence a control tool renders is a consequence of the call rather than a
/// constant the test also wrote; asserting "Playing #2" after `play_tracks([2, 3])`
/// proves the snapshot round-tripped, where a fixed snapshot would pass even if
/// the tool never called the seam.
///
/// An `actor` because the protocol is `Sendable` and every requirement is `async`.
public actor FakeToolboxPlaybackController: ToolboxPlaybackControlling {
    /// One `queue_tracks` call, in a shape a test can compare whole.
    public struct QueueCall: Sendable, Equatable {
        public var ids: [Int64]
        public var position: ToolboxQueuePosition

        public init(ids: [Int64], position: ToolboxQueuePosition) {
            self.ids = ids
            self.position = position
        }
    }

    /// The `upNextLimit` of every ``playbackSnapshot(upNextLimit:)``, in call order.
    public private(set) var snapshotRequests: [Int] = []
    /// The ids of every ``playTracks(ids:)``, in call order.
    public private(set) var playCalls: [[Int64]] = []
    public private(set) var queueCalls: [QueueCall] = []
    public private(set) var transportCalls: [ToolboxTransportAction] = []

    /// What each id is called. An id with no entry is synthesised, so a test only
    /// seeds the tracks whose titles it actually asserts on.
    private var known: [Int64: ToolboxPlaybackEntry]
    private var order: [Int64] = []
    private var manual: [Int64] = []
    private var currentIndex: Int?
    private var activity: ToolboxPlaybackActivity = .stopped
    private var elapsedSeconds: Double = 0
    private var isShuffling = false
    private var repeatSetting: ToolboxRepeatSetting = .off

    public init(known: [Int64: ToolboxPlaybackEntry] = [:]) {
        self.known = known
    }

    /// Seeds display text for `id`, so a rendered row can be asserted verbatim.
    public func setEntry(_ entry: ToolboxPlaybackEntry, for id: Int64) {
        known[id] = entry
    }

    public func setShuffling(_ shuffling: Bool) {
        isShuffling = shuffling
    }

    public func setRepeatSetting(_ setting: ToolboxRepeatSetting) {
        repeatSetting = setting
    }

    public func setElapsedSeconds(_ seconds: Double) {
        elapsedSeconds = seconds
    }

    // MARK: ToolboxPlaybackControlling

    public func playbackSnapshot(upNextLimit: Int) -> ToolboxPlaybackSnapshot {
        snapshotRequests.append(upNextLimit)
        return snapshot(upNextLimit: upNextLimit)
    }

    public func playTracks(ids: [Int64]) -> ToolboxPlaybackSnapshot {
        playCalls.append(ids)
        order = ids
        manual = []
        currentIndex = ids.isEmpty ? nil : 0
        activity = ids.isEmpty ? .stopped : .playing
        elapsedSeconds = 0
        return snapshot()
    }

    public func queueTracks(ids: [Int64], position: ToolboxQueuePosition) -> ToolboxPlaybackSnapshot {
        queueCalls.append(QueueCall(ids: ids, position: position))
        switch position {
        case .next: manual.insert(contentsOf: ids, at: 0)
        case .last: manual.append(contentsOf: ids)
        }
        return snapshot()
    }

    public func perform(_ action: ToolboxTransportAction) -> ToolboxPlaybackSnapshot {
        transportCalls.append(action)
        switch action {
        case .play: activity = currentIndex == nil ? .stopped : .playing
        case .pause: activity = activity == .playing ? .paused : activity
        case .stop: stopEverything()
        case .next: step(by: 1)
        case .previous: step(by: -1)
        }
        return snapshot()
    }
}

// MARK: - The tiny transport

private extension FakeToolboxPlaybackController {
    func stopEverything() {
        activity = .stopped
        currentIndex = nil
        elapsedSeconds = 0
    }

    /// Consumes the manual queue ahead of the context queue on a forward step —
    /// the coordinator's own precedence rule, in miniature, so a test that queues
    /// then advances observes what the real player would do.
    func step(by offset: Int) {
        elapsedSeconds = 0
        if offset > 0, !manual.isEmpty {
            let next = manual.removeFirst()
            order.insert(next, at: (currentIndex.map { $0 + 1 }) ?? 0)
        }
        guard let index = currentIndex else {
            currentIndex = order.isEmpty ? nil : 0
            activity = order.isEmpty ? .stopped : .playing
            return
        }
        let candidate = index + offset
        guard order.indices.contains(candidate) else {
            stopEverything()
            return
        }
        currentIndex = candidate
        activity = .playing
    }

    /// With no current entry there is no position for anything to follow, so only
    /// the manual queue is "up next" — the context queue is a list nothing will
    /// advance into until something is activated in it.
    var upcomingIds: [Int64] {
        guard let index = currentIndex else { return manual }
        return manual + Array(order.dropFirst(index + 1))
    }

    func entry(_ id: Int64) -> ToolboxPlaybackEntry {
        known[id] ?? ToolboxPlaybackEntry(trackId: id, title: "Track \(id)")
    }

    func snapshot(upNextLimit: Int = ToolResultBudget.playbackQueuePreviewLimit) -> ToolboxPlaybackSnapshot {
        let upcoming = upcomingIds
        return ToolboxPlaybackSnapshot(
            activity: activity,
            current: currentIndex.map { entry(order[$0]) },
            elapsedSeconds: elapsedSeconds,
            durationSeconds: currentIndex.flatMap { entry(order[$0]).durationSeconds } ?? 0,
            isShuffling: isShuffling,
            repeatSetting: repeatSetting,
            upNext: upcoming.prefix(max(0, upNextLimit)).map { entry($0) },
            upNextTotal: upcoming.count
        )
    }
}
