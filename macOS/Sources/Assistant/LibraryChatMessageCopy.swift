// LibraryChatMessageCopy — taking a message out of the conversation.
//
// ── THE STRING IS THE MESSAGE, NOT WHAT THE ROW DREW ─────────────────────────
//
// A bubble renders `message.text` through `Text(verbatim:)` and speaks a DIFFERENT
// string: `spoken(_:_:)` prefixes the role ("You: …"), which is chrome for VoiceOver
// and must never reach the pasteboard. `copyText(for:)` therefore reads the model, not
// the view — the same reason `LibraryChatSuggestionList.copyText(for:)` returns the
// row's URL rather than the display name beside it.
//
// Nothing here trims, collapses, normalizes or truncates. What a listener typed and
// what an assistant answered are copied character for character, so a multi-line
// answer pastes as the lines it had and a decomposed Hangul stays decomposed.
//
// ── SPLIT FROM THE WRITE SO THE CONTRACT IS ASSERTABLE ───────────────────────
//
// `copy(_:)` is the only line that touches `NSPasteboard`, and it holds no decision.
// Everything worth pinning is in the pure half above it, which
// `LibraryChatMessageCopyTests` drives without clobbering the developer's clipboard.
// This is the shape `LibraryChatSuggestionList` established for "Copy Link".
//
// ── WHICH ROWS GET THE ACTION, AND WHERE THAT IS ENFORCED ───────────────────
//
// Only the two message BUBBLES, and the gate is structural rather than a second
// runtime branch: `assistantBubble` is built only inside the row's own
// `if !message.text.isEmpty`, and a `.listener` row is minted from a trimmed, non-empty
// send. A failed turn draws a banner and a pure-tool-calling turn draws only its
// activity rows — neither builds a bubble, so neither can offer a menu item that would
// put an empty string on the pasteboard. `canCopy(_:)` NAMES that rule so it is
// assertable, which is what keeps a future row from being given the affordance blindly.
//
// The context-menu `Button` takes no `.help` and no `.pointingHandCursor()` — an
// `NSMenu` row never receives `.onHover`, and its visible label already names the
// action. That is the same exemption the "Copy Link" item takes.
//
// ── THE THIRD AFFORDANCE: A BUTTON THE POINTER REVEALS ──────────────────────
//
// Selection and the menu each cost something to discover — a drag, or a right-click
// on a surface that gives no sign it has a menu. The hover button is the one-click
// path, and it reads the SAME `canCopy(_:)`, so the three affordances cannot
// disagree about which rows are copyable.
//
// Two shapes here are load-bearing rather than stylistic:
//
// 1. It is attached ABOVE the bubble's `.accessibilityElement(children: .combine)`.
//    Combined children are gone, so a button added underneath that modifier would be
//    folded into the bubble's label instead of staying its own element.
// 2. It is revealed by a plain opacity toggle, never by insertion — the
//    `ScrubberHeatCaption` shape — so the bubble cannot reflow under the pointer and
//    there is no motion to suppress. Hit-testing follows the same flag, because an
//    invisible-but-live button would swallow the text selection at that corner.
//
// This one DOES take `.help` and `.pointingHandCursor()`: it is icon-only, and it
// does receive `.onHover`.
import AppKit
import DesignSystem
import SwiftUI
import ViewModels

// MARK: - What lands on the pasteboard

extension LibraryChatMessageRow {
    /// Exactly what "Copy" writes: the message's own text, character for character.
    static func copyText(for message: LibraryChatMessage) -> String {
        message.text
    }

    /// Whether this row has words worth a Copy action. See this file's header.
    static func canCopy(_ message: LibraryChatMessage) -> Bool {
        !message.text.isEmpty
    }

    static func copy(_ message: LibraryChatMessage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(copyText(for: message), forType: .string)
    }
}

// MARK: - Identifiers

extension LibraryChatMessageRow {
    /// The bubble's own identifier, keyed off the role's wire name so the two sides of
    /// the transcript stay `assistant.chat.listener.<n>` and `assistant.chat.assistant.<n>`.
    static func bubbleIdentifier(role: LibraryChatMessage.Role, index: Int) -> String {
        "assistant.chat.\(role.rawValue).\(index)"
    }

    /// The Copy item's identifier, DERIVED from the bubble's rather than spelled again,
    /// so a renamed bubble can never leave the menu item pointing at nothing.
    static func copyIdentifier(role: LibraryChatMessage.Role, index: Int) -> String {
        "\(bubbleIdentifier(role: role, index: index)).copy"
    }

    /// The hover button's identifier, derived the same way and for the same reason.
    static func copyButtonIdentifier(role: LibraryChatMessage.Role, index: Int) -> String {
        "\(bubbleIdentifier(role: role, index: index)).copyButton"
    }
}

// MARK: - The hover button's own decisions

extension LibraryChatMessageRow {
    /// The glyph on the button and the icon on its toast, declared once so the
    /// confirmation cannot drift from the control that raised it.
    static let copyButtonSymbol = "doc.on.doc"

    /// Whether the button is on screen and clickable: the pointer is over the
    /// bubble, AND the bubble has words. The second half is `canCopy(_:)` itself,
    /// not a second rule, so no hover can reveal a button on a textless row.
    static func showsCopyButton(_ message: LibraryChatMessage, isHovering: Bool) -> Bool {
        isHovering && canCopy(message)
    }

    /// The confirmation the button raises once the text is on the pasteboard.
    ///
    /// Split from ``copy(_:)`` for the reason the whole file is split: what the
    /// listener is told is then assertable without writing to their clipboard.
    static func announceCopied(on toast: ToastManager) {
        toast.show(text: String(localized: LibraryChatStrings.copiedToast), icon: copyButtonSymbol)
    }
}

// MARK: - The affordances a bubble carries

extension View {
    /// Selection, a context-menu Copy, and a hover Copy button for one transcript
    /// message.
    ///
    /// Three, because they answer different listeners: `.textSelection(.enabled)` is
    /// the platform-native path (drag, then ⌘C, and part of a message rather than all
    /// of it), the menu is the discoverable one, and the button is the one-click one.
    /// None fights the row — a bubble carries no tap gesture and no other menu, and
    /// scrolling the transcript is a wheel event, not a drag.
    func chatMessageCopyAffordances(for message: LibraryChatMessage, index: Int) -> some View {
        modifier(ChatMessageCopyAffordances(message: message, index: index))
    }
}

private struct ChatMessageCopyAffordances: ViewModifier {
    let message: LibraryChatMessage
    let index: Int

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .textSelection(.enabled)
            .overlay(alignment: .topTrailing) { copyButton }
            .contextMenu { copyMenuItem }
            .onHover { isHovering = $0 }
    }
}

// MARK: - The two Copy controls

private extension ChatMessageCopyAffordances {
    var isRevealed: Bool {
        LibraryChatMessageRow.showsCopyButton(message, isHovering: isHovering)
    }

    var copyMenuItem: some View {
        Button {
            LibraryChatMessageRow.copy(message)
        } label: {
            Text(LibraryChatStrings.copyMessage)
        }
        .accessibilityIdentifier(
            LibraryChatMessageRow.copyIdentifier(role: message.role, index: index)
        )
    }

    @ViewBuilder
    var copyButton: some View {
        if LibraryChatMessageRow.canCopy(message) {
            Button {
                LibraryChatMessageRow.copy(message)
                LibraryChatMessageRow.announceCopied(on: environment.toast)
            } label: {
                Image(systemName: LibraryChatMessageRow.copyButtonSymbol)
                    .font(tokens.typography.caption.font)
                    .foregroundStyle(glyphColor)
                    .frame(width: tokens.spacing.large, height: tokens.spacing.large)
                    .background(chip)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help(Text(LibraryChatStrings.copyMessageHelp))
            .accessibilityLabel(Text(LibraryChatStrings.copyMessage))
            .accessibilityIdentifier(
                LibraryChatMessageRow.copyButtonIdentifier(role: message.role, index: index)
            )
            .padding(tokens.spacing.xxSmall)
            .opacity(isRevealed ? 1 : 0)
            .allowsHitTesting(isRevealed)
        }
    }
}

// MARK: - What the button is drawn on

private extension ChatMessageCopyAffordances {
    var chip: some View {
        Circle()
            .fill(chipFill)
            .overlay(
                Circle().strokeBorder(
                    tokens.colors.separator.resolve(scheme),
                    lineWidth: tokens.spacing.hairline
                )
            )
            .shadow(
                color: .black.opacity(tokens.elevation.low.colorOpacity),
                radius: tokens.elevation.low.radius,
                x: tokens.elevation.low.offsetX,
                y: tokens.elevation.low.offsetY
            )
    }

    /// The bubbles sit on different fills, so one chip colour cannot read on both.
    /// Exhaustive over the role rather than defaulted, so a third bubble kind has to
    /// answer where its button is legible before it can ship.
    var chipFill: Color {
        switch message.role {
        case .listener: tokens.colors.onAccent.resolve(scheme)
        case .assistant: tokens.colors.surface.resolve(scheme)
        }
    }

    var glyphColor: Color {
        switch message.role {
        case .listener: tokens.colors.accent.resolve(scheme)
        case .assistant: tokens.colors.textSecondary.resolve(scheme)
        }
    }
}
