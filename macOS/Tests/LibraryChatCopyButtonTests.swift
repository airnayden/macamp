// LibraryChatCopyButtonTests — the hover Copy button's three decisions: whether it
// is there, what it is called, and what it tells the listener afterwards.
//
// ── THE BUTTON IS DRIVEN THROUGH ITS PURE HALVES, NOT THROUGH A VIEW ─────────
//
// The control itself is a `ViewModifier` overlay, which a unit test cannot press.
// What is worth pinning is not the pressing: it is that a textless row can never
// grow the button, that its identifier stays derived from the bubble's, and that a
// press announces something a listener can actually read. Each of those is a
// function, so each is driven directly — the same split `LibraryChatMessageCopyTests`
// already relies on, and for the same reason: `copy(_:)` is the only line that
// touches `NSPasteboard`, so nothing here clobbers the developer's clipboard.
//
// `announceCopied(on:)` is asserted against a REAL `ToastManager` rather than a
// double. The type is a three-line `@Observable` box with no I/O and no seam worth
// faking, and `activeToast` is exactly the state the overlay renders — so the
// assertion is on the shipped path instead of on a stand-in that could drift.
import Foundation
@testable import MacAMP
import Testing
import ViewModels

@Suite("Library chat hover copy button")
@MainActor
struct LibraryChatCopyButtonTests {
    // MARK: - Whether the button exists at all

    @Test("the button needs both a hovering pointer and a message with words")
    func theButtonNeedsHoverAndText() {
        let spoken = LibraryChatMessage(role: .assistant, text: "Marrow, Cinder and Harrow.")

        #expect(LibraryChatMessageRow.showsCopyButton(spoken, isHovering: true))
        // Off the bubble it is not merely faded: hit-testing follows the same flag,
        // so an invisible button cannot swallow the selection at that corner.
        #expect(!LibraryChatMessageRow.showsCopyButton(spoken, isHovering: false))
    }

    @Test("a row with nothing said grows no button, hovered or not")
    func aTextlessRowGrowsNoButton() {
        // The failure banner and the pure-tool-calling turn are the two rows that
        // draw without a bubble. Hovering either must not produce a control that
        // would put an empty string on the pasteboard.
        let rows: [LibraryChatMessage] = [
            .assistant(failure: .answerFailed),
            LibraryChatMessage(role: .assistant, events: [.toolCall(name: "search_tracks")]),
            .listener(""),
        ]

        for row in rows {
            #expect(!LibraryChatMessageRow.showsCopyButton(row, isHovering: true))
            #expect(!LibraryChatMessageRow.showsCopyButton(row, isHovering: false))
        }
    }

    @Test("the button's gate is canCopy itself, not a second rule that could drift")
    func theGateIsCanCopy() {
        // Exhaustive over the enum, so a third bubble kind is decided in one place.
        for role in LibraryChatMessage.Role.allCases {
            let said = LibraryChatMessage(role: role, text: "Marrow")
            let silent = LibraryChatMessage(role: role, text: "")

            #expect(LibraryChatMessageRow.showsCopyButton(said, isHovering: true)
                == LibraryChatMessageRow.canCopy(said))
            #expect(LibraryChatMessageRow.showsCopyButton(silent, isHovering: true)
                == LibraryChatMessageRow.canCopy(silent))
        }
    }

    // MARK: - What a UI test finds it by

    @Test("the button's identifier hangs off the bubble's own, per role and per row")
    func buttonIdentifiersFollowTheBubble() {
        #expect(LibraryChatMessageRow.copyButtonIdentifier(role: .listener, index: 0)
            == "assistant.chat.listener.0.copyButton")
        #expect(LibraryChatMessageRow.copyButtonIdentifier(role: .assistant, index: 3)
            == "assistant.chat.assistant.3.copyButton")

        for role in LibraryChatMessage.Role.allCases {
            let bubble = LibraryChatMessageRow.bubbleIdentifier(role: role, index: 7)
            #expect(LibraryChatMessageRow.copyButtonIdentifier(role: role, index: 7) == "\(bubble).copyButton")
            // Distinct from the menu item's: the two are separate controls on the
            // same bubble, and a UI test that pressed one meaning the other would
            // pass while proving nothing.
            #expect(LibraryChatMessageRow.copyButtonIdentifier(role: role, index: 7)
                != LibraryChatMessageRow.copyIdentifier(role: role, index: 7))
        }
    }

    // MARK: - What the listener is told

    @Test("a press announces the copy through the toast, with the button's own glyph")
    func aPressAnnouncesTheCopy() {
        let toast = ToastManager()
        LibraryChatMessageRow.announceCopied(on: toast)

        #expect(toast.activeToast?.text == String(localized: LibraryChatStrings.copiedToast))
        // Same symbol as the control that raised it, so the confirmation cannot
        // drift into naming a different action than the one taken.
        #expect(toast.activeToast?.icon == LibraryChatMessageRow.copyButtonSymbol)
        #expect(LibraryChatMessageRow.copyButtonSymbol == "doc.on.doc")
    }

    @Test("the button copies the same verbatim string the menu item does")
    func theButtonCopiesTheSameStringAsTheMenu() {
        // Both controls call `copy(_:)`, so the pasteboard seam is one function and
        // this pins that the button did not acquire a formatting step of its own.
        let awkward = "Here are three:\n\t1. 마로우 — 앤빌 🎧\n\t2. Cinder — Quarry  "
        let message = LibraryChatMessage(role: .assistant, text: awkward)

        #expect(LibraryChatMessageRow.copyText(for: message) == awkward)
        #expect(Array(LibraryChatMessageRow.copyText(for: message).utf8) == Array(awkward.utf8))
    }

    // MARK: - The words on it

    @Test("the button's tooltip and its confirmation come from the catalog")
    func theButtonCopyIsLocalized() {
        #expect(LibraryChatStrings.copiedToast.key == "app.assistant.chat.copiedToast")
        #expect(LibraryChatStrings.copyMessageHelp.key == "app.assistant.chat.copyMessage.help")
        // The tooltip is a sentence and the menu item is a verb; they translate
        // apart, so they may not share a key.
        #expect(LibraryChatStrings.copyMessageHelp.key != LibraryChatStrings.copyMessage.key)
        #expect(LibraryChatStrings.copiedToast.key != LibraryChatStrings.copyMessage.key)
    }
}
