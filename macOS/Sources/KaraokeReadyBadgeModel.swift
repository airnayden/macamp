import Observation
import Persistence
import ViewModels

@MainActor
@Observable
public final class KaraokeReadyBadgeModel {
    public private(set) var resolvedCount = 0

    @ObservationIgnored private let readyStore: KaraokeReadyStore
    @ObservationIgnored private let repository: TrackRepository
    @ObservationIgnored private var requestSequence = 0

    public init(readyStore: KaraokeReadyStore, repository: TrackRepository) {
        self.readyStore = readyStore
        self.repository = repository
    }

    public func recompute(profileId: Int64) async {
        requestSequence &+= 1
        let request = requestSequence
        let paths = Array(readyStore.readyPaths)
        let repository = repository
        let count = if paths.isEmpty {
            0
        } else {
            await Task.detached(priority: .utility) {
                do {
                    return try repository.countTracksByPaths(profileId: profileId, paths: paths)
                } catch {
                    return 0
                }
            }.value
        }
        guard request == requestSequence, !Task.isCancelled, count != resolvedCount else { return }
        resolvedCount = count
    }
}
