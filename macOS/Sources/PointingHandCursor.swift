// PointingHandCursor — the shell-wide "this is clickable" cursor modifier.
//
// `.pointingHandCursor()` shows `NSCursor.pointingHand` while the pointer is over
// a view and restores the previous cursor when it leaves. The whole point of this
// modifier is a GUARANTEED-BALANCED push/pop stack: `NSCursor.push()`/`pop()`
// mutate a process-global stack, so a single missed pop (an enter with no matching
// exit before the view is torn down mid-hover — rapid scrolling, a row leaving the
// list while the pointer is still over it) leaves the whole app stuck on the hand
// cursor. The balancing is factored into `HoverCursorState`, a pure value-type
// state machine that emits exactly one side effect per transition, so pushes and
// pops stay 1:1 no matter how the hover / disappear events interleave.
//
// Lives in `macOS/Sources` (never PlayerCore): `NSCursor` is AppKit, and PlayerCore
// is portability-guarded against AppKit/UIKit. Apply it at the macOS call sites of
// shared PlayerCore components — never inside a component itself.
import AppKit
import SwiftUI

/// Pure decision core for a balanced `NSCursor` push/pop pair.
///
/// Holds a single bit — whether THIS view currently owns a pushed cursor on the
/// global `NSCursor` stack — and returns the one side effect each transition must
/// perform. The guards make double-push and unmatched-pop structurally impossible:
/// `enter()` only pushes when not already pushed, and `exit()`/`disappear()` only
/// pop when a push is outstanding. That invariant is what keeps the global stack
/// balanced across any interleaving of events.
struct HoverCursorState {
    /// The side effect the caller must apply to `NSCursor` after a transition.
    enum Effect: Equatable {
        case push
        case pop
        case none
    }

    /// `true` while this view owns an un-popped cursor on the global stack.
    private(set) var isPushed = false

    /// The pointer entered the view. Push only if we do not already own a cursor,
    /// so a duplicate enter (no exit in between) is a no-op instead of a leak.
    mutating func enter() -> Effect {
        guard !isPushed else { return .none }
        isPushed = true
        return .push
    }

    /// The pointer left the view. Pop only if we currently own a cursor, so a
    /// duplicate/spurious exit can never pop a cursor we do not own.
    mutating func exit() -> Effect {
        guard isPushed else { return .none }
        isPushed = false
        return .pop
    }

    /// The view is being torn down. Pop iff a push is still outstanding — this is
    /// the safety net for an enter whose matching exit never fires because the
    /// view left the hierarchy while the pointer was still over it.
    mutating func disappear() -> Effect {
        guard isPushed else { return .none }
        isPushed = false
        return .pop
    }
}

/// Drives `HoverCursorState` from SwiftUI's `.onHover` / `.onDisappear` and applies
/// the resulting effect to the global `NSCursor` stack.
private struct PointingHandCursorModifier: ViewModifier {
    @State private var state = HoverCursorState()

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                apply(hovering ? state.enter() : state.exit())
            }
            .onDisappear {
                apply(state.disappear())
            }
    }

    private func apply(_ effect: HoverCursorState.Effect) {
        switch effect {
        case .push: NSCursor.pointingHand.push()
        case .pop: NSCursor.pop()
        case .none: break
        }
    }
}

extension View {
    /// Shows the pointing-hand cursor while hovered, with a guaranteed-balanced
    /// `NSCursor` push/pop stack (including a pop on disappear if the view is torn
    /// down mid-hover). Use on every clickable macOS control.
    func pointingHandCursor() -> some View {
        modifier(PointingHandCursorModifier())
    }
}
