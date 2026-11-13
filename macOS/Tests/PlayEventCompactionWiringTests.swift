// PlayEventCompactionWiringTests — the launch hook is really attached.
//
// `PlayEventCompactionTriggerTests` (PlayerCore) proves that `start()` reaches a
// compactor. What it cannot prove is that the composition root ever CALLS it — and a
// never-called trigger fails silently: listening history simply grows forever, which
// nobody notices for two years. This suite closes that gap from the shell side, and
// lives in the app test target because `AppEnvironment` is not part of the package.
import Foundation
@testable import MacAMP
import Testing

@Suite("Play-event compaction wiring")
@MainActor
struct PlayEventCompactionWiringTests {
    @Test("building the environment starts the compaction trigger")
    func launchWiringStartsTheTrigger() {
        let environment = AppEnvironment.preview()

        #expect(environment.playEventCompactionTrigger.hasStarted)

        // Nothing should still be pending when the test host tears down.
        environment.playEventCompactionTrigger.cancel()
    }
}
