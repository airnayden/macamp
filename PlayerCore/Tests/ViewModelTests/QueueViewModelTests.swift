import Services
import Testing
@testable import ViewModels

@MainActor
struct QueueViewModelTests {
    private func makeRefs(_ count: Int) -> [TrackRef] {
        (0 ..< count).map { index in
            TrackRef(filePath: "/music/\(index).flac", title: "T\(index)", availability: .present)
        }
    }

    @Test func setQueuePopulatesEntries() {
        let coordinator = PlaybackCoordinator.fake()
        let model = QueueViewModel(coordinator: coordinator)
        let refs = makeRefs(3)
        model.setQueue(refs)
        #expect(model.entries.count == 3)
        #expect(model.entries.map(\.id) == refs.map(\.id))
    }

    @Test func appendInsertRemoveMove() {
        let coordinator = PlaybackCoordinator.fake()
        let model = QueueViewModel(coordinator: coordinator)
        let refs = makeRefs(3)
        model.setQueue(refs)

        let extra = TrackRef(filePath: "/music/extra.flac", title: "Extra")
        model.append(extra)
        #expect(model.entries.count == 4)
        #expect(model.entries.last?.id == extra.id)

        let inserted = TrackRef(filePath: "/music/ins.flac", title: "Ins")
        model.insert(inserted, at: 0)
        #expect(model.entries.first?.id == inserted.id)

        model.remove(at: 0)
        #expect(model.entries.first?.id == refs[0].id)

        let firstID = refs[0].id
        model.move(from: 0, to: 2)
        #expect(model.entries[2].id == firstID)
    }

    @Test func shuffleRepeatAndClear() {
        let coordinator = PlaybackCoordinator.fake()
        let model = QueueViewModel(coordinator: coordinator)
        model.setQueue(makeRefs(4))
        model.setShuffle(true)
        #expect(model.shuffle)
        model.setRepeatMode(.all)
        #expect(model.repeatMode == .all)
        model.removeAll()
        #expect(model.entries.isEmpty)
    }
}
