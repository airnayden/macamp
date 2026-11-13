import AppKit
import SwiftUI

extension MainWindowView {
    /// Space toggles playback from the library, but must yield to a focused text
    /// control (profile editor, search field, rename/tag sheets) so the user can
    /// type a space. Returning `.ignored` lets the field editor insert it.
    func handleSpaceKey() -> KeyPress.Result {
        guard !isEditingText else { return .ignored }
        if environment.player.currentTrack == nil {
            playIntent.requestIdlePlay()
        } else {
            environment.player.togglePlayPause()
        }
        return .handled
    }

    /// Bare ↑/↓ nudges the volume by ±5% — the same step the ⌘-arrows take.
    ///
    /// Volume is always adjustable, so this branch does not care whether a track is
    /// loaded; only a modified press or a focused text/list control makes the key
    /// somebody else's.
    func handleBareArrowVolume(_ modifiers: EventModifiers, up increasing: Bool) -> KeyPress.Result {
        guard modifiers.isEmpty, !shouldYieldArrowKeys else { return .ignored }
        let player = environment.player
        player.setVolume(ArrowKeyTransport.adjustedVolume(current: player.volume, up: increasing))
        return .handled
    }

    /// Bare ←/→ nudges the playhead by ±5 s, clamped to the track's own bounds.
    ///
    /// Yields when nothing is loaded: with no duration there is no position to move,
    /// so consuming the key would swallow it for no effect.
    func handleBareArrowSeek(_ modifiers: EventModifiers, forward: Bool) -> KeyPress.Result {
        guard modifiers.isEmpty, !shouldYieldArrowKeys else { return .ignored }
        let player = environment.player
        guard let target = ArrowKeyTransport.adjustedSeek(
            elapsed: player.elapsed,
            duration: player.duration,
            forward: forward
        ) else { return .ignored }
        player.seek(to: target)
        return .handled
    }

    /// Whether a text-editing control owns the key window's first responder — the
    /// user is typing. AppKit backs SwiftUI text controls with an `NSText` field
    /// editor, so a text first responder means Space should insert a character.
    private var isEditingText: Bool {
        let responder = NSApp.keyWindow?.firstResponder
        return responder is NSText || responder is NSTextField
    }

    private var shouldYieldArrowKeys: Bool {
        ArrowKeyTransport.shouldYieldArrowKeys(responder: NSApp.keyWindow?.firstResponder)
    }
}

/// The arithmetic and the focus guard behind the bare arrow keys.
///
/// Free-standing statics rather than view members so `macampMacTests` can drive
/// them without a window, a key event, or a running player.
enum ArrowKeyTransport {
    /// Volume step for one bare ↑/↓ press — matched to the ⌘-arrow step so the two
    /// gestures never disagree about how far one press moves the slider.
    static let volumeStep: Float = 0.05

    static let seekStep: TimeInterval = 5

    /// Hop cap for the responder walk — deep enough to clear a nested list cell,
    /// shallow enough that a cyclic chain cannot spin.
    static let responderHopLimit = 10

    /// The volume after one step, clamped to the 0…1 range the engine accepts.
    static func adjustedVolume(current: Float, up increasing: Bool) -> Float {
        let stepped = increasing ? current + volumeStep : current - volumeStep
        return min(max(stepped, 0), 1)
    }

    /// The playhead after one step, clamped to `0...duration`.
    ///
    /// `nil` when nothing is loaded (`duration <= 0`): there is no position to move,
    /// and seeking a zero-length track would be a no-op that still ate the key.
    static func adjustedSeek(elapsed: TimeInterval, duration: TimeInterval, forward: Bool) -> TimeInterval? {
        guard duration > 0 else { return nil }
        let stepped = forward ? elapsed + seekStep : elapsed - seekStep
        return min(max(stepped, 0), duration)
    }

    /// Whether an arrow key belongs to the focused control rather than to the window.
    ///
    /// Text controls consume arrows to move the caret and tables/outlines consume
    /// them to move the selection; stealing the key would break either. The focused
    /// leaf inside a SwiftUI `List`/`Table` is often a nested view whose *ancestor*
    /// is the `NSTableView`, so the whole responder chain is walked rather than only
    /// its first link.
    @MainActor
    static func shouldYieldArrowKeys(responder: NSResponder?) -> Bool {
        var candidate = responder
        for _ in 0 ..< responderHopLimit {
            guard let current = candidate else { return false }
            if current is NSText || current is NSTextField { return true }
            if current is NSTableView || current is NSOutlineView { return true }
            candidate = current.nextResponder
        }
        return false
    }
}
