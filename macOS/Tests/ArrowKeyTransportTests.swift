import AppKit
import Foundation
@testable import MacAMP
import Testing

/// Bare arrow keys move volume and the playhead, but only when the window is the
/// one that should hear them. Both halves are pinned here: the step arithmetic
/// (which must clamp rather than overshoot) and the focus guard (which must hand
/// the key back to a text field or a list that owns it).
@MainActor
@Suite("ArrowKeyTransportTests")
struct ArrowKeyTransportTests {
    // MARK: adjustedVolume — a step that can never leave 0…1

    @Test("stepping up near the ceiling clamps to full volume")
    func volumeUpClampsToMaximum() {
        #expect(ArrowKeyTransport.adjustedVolume(current: 0.98, up: true) == 1.0)
    }

    @Test("stepping down near the floor clamps to silence")
    func volumeDownClampsToMinimum() {
        #expect(ArrowKeyTransport.adjustedVolume(current: 0.02, up: false) == 0.0)
    }

    // MARK: adjustedSeek — a step that can never leave 0…duration

    @Test("stepping forward mid-track advances by the seek step")
    func seekForwardAdvancesByStep() {
        #expect(ArrowKeyTransport.adjustedSeek(elapsed: 10, duration: 200, forward: true) == 15)
    }

    @Test("stepping back near the start clamps to the beginning")
    func seekBackwardClampsToStart() {
        #expect(ArrowKeyTransport.adjustedSeek(elapsed: 2, duration: 200, forward: false) == 0)
    }

    /// With nothing loaded there is no position to move, so the caller must be told
    /// to leave the key alone rather than seek a zero-length track.
    @Test("no loaded track yields no seek target")
    func seekWithoutDurationIsNil() {
        #expect(ArrowKeyTransport.adjustedSeek(elapsed: 0, duration: 0, forward: true) == nil)
        #expect(ArrowKeyTransport.adjustedSeek(elapsed: 10, duration: 0, forward: false) == nil)
    }

    // MARK: shouldYieldArrowKeys — whose key is it

    @Test("a focused text field owns its arrow keys")
    func textFieldYields() {
        #expect(ArrowKeyTransport.shouldYieldArrowKeys(responder: NSTextField()))
    }

    @Test("a focused table owns its arrow keys")
    func tableViewYields() {
        #expect(ArrowKeyTransport.shouldYieldArrowKeys(responder: NSTableView()))
    }

    /// The case the chain walk exists for: SwiftUI focuses a nested leaf inside a
    /// `List`/`Table`, so the `NSTableView` is an ancestor rather than the responder
    /// itself. Checking only the first link would steal the selection keys.
    @Test("a nested leaf inside a table yields through its ancestors")
    func nestedLeafInsideTableYields() {
        let table = NSTableView()
        let container = NSView()
        let leaf = NSView()
        table.addSubview(container)
        container.addSubview(leaf)

        #expect(leaf.nextResponder === container)
        #expect(ArrowKeyTransport.shouldYieldArrowKeys(responder: leaf))
    }

    @Test("no first responder means the window may act")
    func nilResponderDoesNotYield() {
        #expect(ArrowKeyTransport.shouldYieldArrowKeys(responder: nil) == false)
    }

    @Test("a plain view with no text or list ancestor does not yield")
    func plainViewDoesNotYield() {
        #expect(ArrowKeyTransport.shouldYieldArrowKeys(responder: NSView()) == false)
    }

    /// A responder chain is walked, not trusted: a cyclic one must terminate on the
    /// hop cap instead of spinning the main thread forever.
    @Test("a cyclic responder chain terminates on the hop cap")
    func cyclicChainTerminates() {
        let first = NSResponder()
        let second = NSResponder()
        first.nextResponder = second
        second.nextResponder = first

        #expect(ArrowKeyTransport.shouldYieldArrowKeys(responder: first) == false)
    }
}
