import AppKit

/// Restores the standard text-editing key equivalents — ⌘A (Select All), ⌘X (Cut),
/// ⌘C (Copy), ⌘V (Paste), ⌘Z (Undo), ⇧⌘Z (Redo) — app-wide for every `TextField` /
/// `SecureField` (library search, karaoke ready-list search, playlist filter, tag
/// editor, profile/rename sheets, …).
///
/// MacAMP deliberately strips the top-level **Edit** menu (see ``MenuPruningDelegate``).
/// On macOS those Command shortcuts are dispatched as **menu key equivalents**, so with
/// no Edit menu `NSMenu.performKeyEquivalent` finds nothing and the Cocoa text system's
/// default key bindings do not cover ⌘A/⌘C/⌘V/⌘X/⌘Z — the combos become dead in every
/// text field. This local key monitor re-supplies them *without* re-introducing the
/// menu: it maps each combo to the matching responder action and forwards it down the
/// responder chain via `NSApp.sendAction(_:to:from:)`.
///
/// The forward is **conditional** — `sendAction` returns `true` only when a responder
/// (a focused field editor) actually handles it, in which case the event is swallowed.
/// When nothing handles it (no text field focused) the original event is returned
/// unchanged, so the transport shortcuts (Space, ⌘←/⌘→/⌘↑/⌘↓ in ``MainWindowView``) and
/// every other key path are left completely untouched. Because the Edit menu is absent,
/// no menu item competes for these combos, so the monitor reliably receives them.
@MainActor
final class TextEditingKeyMonitor {
    static let shared = TextEditingKeyMonitor()
    private var monitor: Any?

    /// Installs the local key monitor once. Safe to call repeatedly.
    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            Self.forwardEditingAction(for: event) ? nil : event
        }
    }

    /// Maps a Command-modified key event to its standard editing selector and forwards
    /// it to the first responder. Returns `true` iff a responder handled the action
    /// (event consumed); `false` leaves the event to propagate normally.
    private static func forwardEditingAction(for event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command),
              let key = event.charactersIgnoringModifiers?.lowercased()
        else { return false }

        let action: Selector? = switch key {
        case "a" where flags == .command: #selector(NSText.selectAll(_:))
        case "x" where flags == .command: #selector(NSText.cut(_:))
        case "c" where flags == .command: #selector(NSText.copy(_:))
        case "v" where flags == .command: #selector(NSText.paste(_:))
        case "z" where flags == .command: Selector(("undo:"))
        case "z" where flags == [.command, .shift]: Selector(("redo:"))
        default: nil
        }
        guard let action else { return false }
        return NSApp.sendAction(action, to: nil, from: nil)
    }
}
