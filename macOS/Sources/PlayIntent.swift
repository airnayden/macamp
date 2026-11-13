import Observation

/// Bridges the transport's idle play button/Space key to whatever track list is
/// visible: incrementing `idlePlayToken` asks the visible list to play its
/// current selection (or its first row). Only the on-screen list observes it, so
/// exactly one list reacts, using its own live selection.
@MainActor
@Observable
final class PlayIntent {
    private(set) var idlePlayToken = 0
    func requestIdlePlay() {
        idlePlayToken &+= 1
    }
}
