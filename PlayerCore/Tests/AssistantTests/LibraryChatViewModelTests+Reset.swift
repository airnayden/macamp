// The `onReset` seam: the announcement that lets state kept OUTSIDE this view model on
// behalf of a conversation be discarded with it.
//
// The macOS shell's only consumer drops the chat-initiated download registrations —
// those name proposals from a transcript that no longer exists, so leaving them would
// park appends nothing can ever resolve.
//
// Two properties are pinned, and only the second is obvious from the signature:
//
//   1. it fires at all, once per `reset()`; and
//   2. it fires LAST — after every field is already cleared — so a handler that reads
//      this view model sees the post-reset state rather than the one being torn down.
import Foundation
import Testing
import ViewModels

@Suite("LibraryChatViewModel reset seam")
@MainActor
struct LibraryChatViewModelResetTests {
    @Test("reset announces itself exactly once per call")
    func resetAnnouncesItselfOncePerCall() {
        let model = LibraryChatViewModel(makeEngine: { .failure(.answerFailed) })
        var calls = 0
        model.onReset = { calls += 1 }

        model.reset()
        model.reset()

        #expect(calls == 2)
    }

    /// The ordering claim, stated as something a handler can observe: by the time it
    /// runs, the transcript is already empty.
    @Test("the announcement lands AFTER the transcript has been cleared")
    func theAnnouncementLandsAfterTheClear() async {
        let model = LibraryChatViewModel(makeEngine: { .failure(.answerFailed) })
        await model.send("hello")
        #expect(!model.messages.isEmpty)
        var observedMessageCount = -1
        model.onReset = { observedMessageCount = model.messages.count }

        model.reset()

        #expect(observedMessageCount == 0)
    }

    /// Default `nil`: a view model nobody wired must reset exactly as it always did.
    @Test("an unwired reset is the reset it always was")
    func anUnwiredResetIsUnchanged() async {
        let model = LibraryChatViewModel(makeEngine: { .failure(.answerFailed) })
        await model.send("hello")

        model.reset()

        #expect(model.messages.isEmpty)
        #expect(!model.isResponding)
    }
}
