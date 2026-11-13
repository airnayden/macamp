import AudioEngine
import Foundation
import GRDB
import Persistence
import Services

/// Observes coordinator state and persists per-profile playback snapshots for restoration.
///
/// Current-track changes use a debounce, while every transition from playing to a
/// non-playing state saves immediately. ``flushNow(profileId:)`` synchronously
/// supersedes any pending asynchronous save so a profile switch persists the outgoing
/// profile's queue, source, and position before shared transport state is cleared.
///
/// Quit is handled by ``flushAtTermination()`` instead, awaited by
/// `MenuPruningDelegate`'s raced termination flush. This type deliberately observes
/// **no** `NSApplication.willTerminateNotification`: a synchronous write on that
/// notification runs after the delegate's timeout has already replied, so it could
/// stall a quit the timeout was supposed to bound.
@MainActor
public final class PlaybackStatePersister {
    private let coordinator: PlaybackCoordinator
    private let repository: any ProfilePlaybackStateRepositoryProviding
    private let databaseWriter: any DatabaseWriter
    private let profileId: @MainActor () -> Int64
    private let currentSource: @MainActor () -> PlaybackSource?
    private let debounceInterval: Duration

    private var lastCurrentID: UUID?
    private var lastPlayback: PlaybackState
    private var generation: UInt64 = 0
    private var pendingSave: Task<Void, Never>?
    private var lastEncoding: PlaybackStateEncoding?

    init(
        coordinator: PlaybackCoordinator,
        repository: any ProfilePlaybackStateRepositoryProviding,
        databaseWriter: any DatabaseWriter,
        profileId: @escaping @MainActor () -> Int64,
        currentSource: @escaping @MainActor () -> PlaybackSource?,
        debounceInterval: Duration = .seconds(1)
    ) {
        self.coordinator = coordinator
        self.repository = repository
        self.databaseWriter = databaseWriter
        self.profileId = profileId
        self.currentSource = currentSource
        self.debounceInterval = debounceInterval
        lastCurrentID = coordinator.state.current?.id
        lastPlayback = coordinator.state.playback
        observeCoordinator()
    }

    /// Cancels a queued debounce or immediate asynchronous save.
    public func cancelPending() {
        generation &+= 1
        pendingSave?.cancel()
        pendingSave = nil
    }

    /// Synchronously persists the live coordinator state for an explicit profile.
    public func flushNow(profileId: Int64) {
        cancelPending()
        guard let encoding = encodeLiveState(profileId: profileId) else { return }
        let record = encoding.record(profileId: profileId, savedAt: Date().timeIntervalSince1970)
        try? databaseWriter.write { db in try record.upsert(db) }
        lastEncoding = encoding
    }

    /// Persists the active profile's live playback position at quit, awaitably.
    ///
    /// The asynchronous counterpart of ``flushNow(profileId:)``: it suspends on the
    /// database write instead of blocking the main actor, so the termination
    /// handler can race it against a timeout and still reply.
    public func flushAtTermination() async {
        let activeProfileId = profileId()
        cancelPending()
        guard let encoding = encodeLiveState(profileId: activeProfileId) else { return }
        let record = encoding.record(profileId: activeProfileId, savedAt: Date().timeIntervalSince1970)
        try? await databaseWriter.write { db in try record.upsert(db) }
        lastEncoding = encoding
    }

    private func encodeLiveState(profileId: Int64) -> PlaybackStateEncoding? {
        try? terminationEncoding(for: makeCapture(profileId: profileId))
    }

    private func observeCoordinator() {
        let previous = coordinator.stateDidChange
        coordinator.stateDidChange = { [weak self] state in
            previous?(state)
            self?.handleStateChange(state)
        }
    }

    private func handleStateChange(_ state: CoordinatorState) {
        let currentID = state.current?.id
        let currentChanged = currentID != lastCurrentID
        let becameNonPlaying = lastPlayback == .playing && state.playback != .playing
        lastCurrentID = currentID
        lastPlayback = state.playback

        if becameNonPlaying {
            scheduleSave(after: nil)
        } else if currentChanged {
            scheduleSave(after: debounceInterval)
        }
    }

    private func scheduleSave(after delay: Duration?) {
        let capture = makeCapture(profileId: profileId())
        generation &+= 1
        let scheduledGeneration = generation
        pendingSave?.cancel()
        pendingSave = Task { @MainActor [weak self] in
            if let delay {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled, let self, generation == scheduledGeneration else { return }
            await persist(capture, generation: scheduledGeneration)
        }
    }

    private func persist(_ capture: PlaybackStateCapture, generation scheduledGeneration: UInt64) async {
        let encodingTask = Task.detached(priority: .utility) {
            try PlaybackStateCodec.encode(capture)
        }
        guard let encoding = try? await encodingTask.value,
              !Task.isCancelled,
              generation == scheduledGeneration
        else { return }
        lastEncoding = encoding
        let record = encoding.record(
            profileId: capture.profileId,
            savedAt: Date().timeIntervalSince1970
        )
        try? await repository.upsert(
            for: record.profileId,
            snapshotJson: record.snapshotJson,
            sourceJson: record.sourceJson,
            savedAt: record.savedAt
        )
        guard generation == scheduledGeneration else { return }
        pendingSave = nil
    }

    private func makeCapture(profileId: Int64) -> PlaybackStateCapture {
        PlaybackStateCapture(
            profileId: profileId,
            snapshot: coordinator.snapshot(),
            source: currentSource()
        )
    }

    private func terminationEncoding(for capture: PlaybackStateCapture) throws -> PlaybackStateEncoding {
        if let lastEncoding,
           PlaybackStateCodec.matchesExceptPosition(lastEncoding.snapshot, capture.snapshot),
           let snapshotJson = PlaybackStateCodec.patchPosition(
               in: lastEncoding.snapshotJson,
               position: capture.snapshot.position
           )
        {
            return try PlaybackStateEncoding(
                snapshot: capture.snapshot,
                snapshotJson: snapshotJson,
                sourceJson: PlaybackStateCodec.encodeSource(capture.source)
            )
        }

        let clock = ContinuousClock()
        let startedAt = clock.now
        let fullEncoding = try PlaybackStateCodec.encode(capture)
        guard startedAt.duration(to: clock.now) >= .seconds(1),
              capture.snapshot.entries.count > PlaybackStateCodec.terminationEntryLimit
        else { return fullEncoding }

        // A slow termination encode falls back to 20k entries centered on the
        // current item; restore rebuilds the omitted queue window after launch.
        return try PlaybackStateCodec.encodeTruncated(capture)
    }

    @objc private func applicationWillTerminate(_: Notification) {
        // Selector delivery is synchronous, so this completes on MainActor before
        // NotificationCenter returns and process teardown releases DatabasePool.
        flushNow(profileId: profileId())
    }
}

private struct PlaybackStateCapture {
    let profileId: Int64
    let snapshot: CoordinatorSnapshot
    let source: PlaybackSource?
}

private struct PlaybackStateEncoding {
    let snapshot: CoordinatorSnapshot
    let snapshotJson: String
    let sourceJson: String?

    func record(profileId: Int64, savedAt: TimeInterval) -> ProfilePlaybackStateRecord {
        ProfilePlaybackStateRecord(
            profileId: profileId,
            snapshotJson: snapshotJson,
            sourceJson: sourceJson,
            savedAt: savedAt
        )
    }
}

private enum PlaybackStateCodec {
    static let terminationEntryLimit = 20000

    static func encode(_ capture: PlaybackStateCapture) throws -> PlaybackStateEncoding {
        try PlaybackStateEncoding(
            snapshot: capture.snapshot,
            snapshotJson: json(capture.snapshot),
            sourceJson: encodeSource(capture.source)
        )
    }

    static func encodeTruncated(_ capture: PlaybackStateCapture) throws -> PlaybackStateEncoding {
        let truncated = centeredSnapshot(capture.snapshot)
        return try PlaybackStateEncoding(
            snapshot: capture.snapshot,
            snapshotJson: json(truncated),
            sourceJson: encodeSource(capture.source)
        )
    }

    static func encodeSource(_ source: PlaybackSource?) throws -> String? {
        guard let source else { return nil }
        return try json(source)
    }

    static func matchesExceptPosition(_ lhs: CoordinatorSnapshot, _ rhs: CoordinatorSnapshot) -> Bool {
        lhs.entries == rhs.entries &&
            lhs.order == rhs.order &&
            lhs.currentID == rhs.currentID &&
            lhs.shuffle == rhs.shuffle &&
            lhs.repeatMode == rhs.repeatMode &&
            lhs.karaokeActive == rhs.karaokeActive
    }

    static func patchPosition(in json: String, position: TimeInterval) -> String? {
        guard let keyRange = json.range(of: "\"position\":") else { return nil }
        let valueStart = keyRange.upperBound
        var valueEnd = valueStart
        while valueEnd < json.endIndex, json[valueEnd] != ",", json[valueEnd] != "}" {
            json.formIndex(after: &valueEnd)
        }
        let safePosition = position.isFinite ? max(0, position) : 0
        var patched = json
        patched.replaceSubrange(valueStart ..< valueEnd, with: String(safePosition))
        return patched
    }

    private static func centeredSnapshot(_ snapshot: CoordinatorSnapshot) -> CoordinatorSnapshot {
        let entries = snapshot.entries
        guard entries.count > terminationEntryLimit else { return snapshot }
        let currentIndex = snapshot.currentID.flatMap { currentID in
            entries.firstIndex { $0.id == currentID }
        } ?? entries.startIndex
        let maximumStart = entries.count - terminationEntryLimit
        let start = min(max(currentIndex - terminationEntryLimit / 2, 0), maximumStart)
        let window = Array(entries[start ..< start + terminationEntryLimit])
        let retainedIDs = Set(window.map(\.id))
        return CoordinatorSnapshot(
            entries: window,
            order: snapshot.order.filter(retainedIDs.contains),
            currentID: snapshot.currentID,
            shuffle: snapshot.shuffle,
            repeatMode: snapshot.repeatMode,
            position: snapshot.position,
            karaokeActive: snapshot.karaokeActive
        )
    }

    private static func json(_ value: some Encodable) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let string = String(bytes: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(
                value,
                EncodingError.Context(codingPath: [], debugDescription: "JSON encoder emitted invalid UTF-8")
            )
        }
        return string
    }
}
