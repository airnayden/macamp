// PlaybackQueue — the PURE, engine-free queue + play-order model.
//
// All the "what plays next" logic lives here as a value type with no audio
// dependency: the ordered queue, the stable shuffle permutation, availability
// skipping and history derivation. ``PlaybackCoordinator`` owns one of these and
// translates its decisions into engine `load`/`enqueue`/`play` calls — keeping
// the orchestration (this struct) cleanly separable from the rendering (engine).
//
// Three fields are the source of truth; everything else is derived:
//   • `entries` — the user-ordered queue.
//   • `order`   — the play order as a list of ids (identity-mapped when shuffle
//                 is off; a stable Fisher–Yates permutation when on).
//   • `currentID` — which entry is current.
//
// This file imports only Foundation; it MUST NOT import AppKit or UIKit
// (PlayerCore portability invariant).
import Foundation

/// The pure queue/play-order state machine behind ``PlaybackCoordinator``.
struct PlaybackQueue {
    /// Direction of travel through the play order.
    enum Direction {
        case forward
        case backward
    }

    /// The user-ordered queue (what add/remove/move edit).
    private(set) var entries: [TrackRef] = []
    /// The play order as a stable sequence of ``TrackRef/id`` values.
    private(set) var order: [UUID] = []
    /// The current entry's id, if any.
    var currentID: UUID?
    /// Whether `order` is a shuffled permutation rather than identity order.
    private(set) var shuffle = false

    private var byID: [UUID: TrackRef] = [:]

    /// The current track, resolved from ``currentID``.
    var current: TrackRef? {
        currentID.flatMap { byID[$0] }
    }

    /// Looks up a queued ref by id.
    func track(_ id: UUID) -> TrackRef? {
        byID[id]
    }

    /// Tracks already played earlier in the current play-order cycle.
    var history: [TrackRef] {
        guard let current = currentID, let position = order.firstIndex(of: current), position > 0 else {
            return []
        }
        return order[0 ..< position].compactMap { byID[$0] }
    }

    // MARK: Mutation

    /// Replaces the queue, clearing `current` and rebuilding the play order.
    mutating func setEntries(_ tracks: [TrackRef], using generator: inout any RandomNumberGenerator) {
        entries = tracks
        currentID = nil
        rebuildOrder(pinnedFirst: nil, using: &generator)
    }

    mutating func append(_ track: TrackRef) {
        entries.append(track)
        reconcile()
    }

    mutating func append(contentsOf tracks: [TrackRef]) {
        entries.append(contentsOf: tracks)
        reconcile()
    }

    mutating func insert(_ track: TrackRef, at index: Int) {
        let clamped = min(max(index, 0), entries.count)
        entries.insert(track, at: clamped)
        reconcile()
    }

    /// Removes the entry at `index`, returning its id (or `nil` if out of range).
    @discardableResult
    mutating func remove(at index: Int) -> UUID? {
        guard entries.indices.contains(index) else { return nil }
        let removed = entries[index].id
        entries.remove(at: index)
        reconcile()
        return removed
    }

    mutating func move(from source: Int, to destination: Int) {
        guard entries.indices.contains(source) else { return }
        let clamped = min(max(destination, 0), entries.count - 1)
        let moved = entries.remove(at: source)
        entries.insert(moved, at: clamped)
        reconcile()
    }

    /// Replaces `entries` with `newEntries` (same track set, new order), reusing
    /// each existing entry's identity where the track matches so `currentID` and
    /// the stable shuffle order survive a reorder without interrupting playback.
    mutating func reorder(to newEntries: [TrackRef], using _: inout any RandomNumberGenerator) {
        var existingByKey: [String: TrackRef] = [:]
        for entry in entries {
            existingByKey[Self.stableKey(entry)] = entry
        }
        entries = newEntries.map { existingByKey[Self.stableKey($0)] ?? $0 }
        reconcile()
    }

    private static func stableKey(_ ref: TrackRef) -> String {
        if let trackID = ref.trackID { return "id:\(trackID)" }
        return "path:\(ref.filePath)"
    }

    mutating func removeAll() {
        entries.removeAll()
        order.removeAll()
        byID.removeAll()
        currentID = nil
    }

    /// Engages/disengages shuffle, rebuilding the play order (pinning the current
    /// track to the front when turning shuffle ON so playback continues from it).
    mutating func setShuffle(_ enabled: Bool, using generator: inout any RandomNumberGenerator) {
        guard enabled != shuffle else { return }
        shuffle = enabled
        rebuildOrder(pinnedFirst: currentID, using: &generator)
    }

    /// Restores the model verbatim from a snapshot (no re-randomisation).
    mutating func restore(entries: [TrackRef], order: [UUID], currentID: UUID?, shuffle: Bool) {
        self.entries = entries
        byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        self.order = order.filter { byID[$0] != nil }
        self.shuffle = shuffle
        self.currentID = currentID.flatMap { byID[$0] != nil ? $0 : nil }
    }

    // MARK: Navigation queries

    /// Walks `order` from `origin` in `direction`, skipping unavailable refs and
    /// wrapping only under ``RepeatMode/all``. Returns `nil` at an edge.
    func nextPlayableID(from origin: UUID?, direction: Direction, repeatMode: RepeatMode) -> UUID? {
        guard !order.isEmpty else { return nil }
        let count = order.count
        let start = origin.flatMap { order.firstIndex(of: $0) } ?? -1
        let step = direction == .forward ? 1 : -1
        for offset in 1 ... count {
            var idx = start + step * offset
            if repeatMode == .all {
                idx = ((idx % count) + count) % count
            } else if idx < 0 || idx >= count {
                return nil
            }
            let candidate = order[idx]
            if byID[candidate]?.isPlayable == true {
                return candidate
            }
        }
        return nil
    }

    /// The first playable id at or after `requestedID` (wrapping once), used to
    /// honour an explicit play request even when the chosen entry is unavailable.
    func firstPlayableID(preferring requestedID: UUID?) -> UUID? {
        guard !order.isEmpty else { return nil }
        let count = order.count
        let start = requestedID.flatMap { order.firstIndex(of: $0) } ?? 0
        for offset in 0 ..< count {
            let candidate = order[(start + offset) % count]
            if byID[candidate]?.isPlayable == true {
                return candidate
            }
        }
        return nil
    }

    // MARK: Order maintenance

    /// Rebuilds `order` wholesale: a fresh stable shuffle (pinning `pinnedFirst`)
    /// when shuffle is on, else identity order.
    private mutating func rebuildOrder(pinnedFirst: UUID?, using generator: inout any RandomNumberGenerator) {
        byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        if shuffle {
            order = ShuffleOrder.make(entries.map(\.id), pinnedFirst: pinnedFirst, using: &generator)
        } else {
            order = entries.map(\.id)
        }
    }

    /// Incrementally reconciles `order` with `entries` after an edit: drops absent
    /// ids and appends new ones, PRESERVING the stable shuffle for untouched ids.
    private mutating func reconcile() {
        byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        if shuffle {
            let valid = Set(byID.keys)
            order.removeAll { !valid.contains($0) }
            let present = Set(order)
            for entry in entries where !present.contains(entry.id) {
                order.append(entry.id)
            }
        } else {
            order = entries.map(\.id)
        }
        if let current = currentID, byID[current] == nil {
            currentID = nil
        }
    }
}
