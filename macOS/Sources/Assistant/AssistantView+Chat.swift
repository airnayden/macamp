// AssistantView+Chat — the conversation half of the pane.
//
// A sibling extension rather than more of `AssistantView.swift`, which is already
// near SwiftLint's 400-line `file_length` ceiling. Do not fold it back in.
//
// ── ONE FIELD, TWO KINDS OF REQUEST, NO MODE SWITCH ──────────────────────────
//
// ``submitRouted()`` is the whole of the product decision: if a conversation is
// possible it starts one, and if it is not it runs the UNCHANGED single-shot ladder.
// A listener never chooses between them, and a Mac with no chat-capable tier behaves
// exactly as it did before this wave — which is the non-regression this file exists
// to guarantee.
//
// ── THE DISCLOSURE COMES BEFORE THE FIRST TURN, NOT BEFORE THE FIRST KEYSTROKE ─
//
// A cloud provider's library-browsing sheet is presented on SEND, with the typed
// text preserved, and accepting re-enters `submitRouted()` — which now resolves to
// `.ready` and sends. Declining records the provider for the life of this pane, so
// the sheet is not re-offered on every send, and the request still gets answered by
// the one-shot path the original connector consent already covers.
//
// ── PROBING IS CACHED, NOT DONE IN `body` ────────────────────────────────────
//
// ``chatAvailability`` reads `AssistantView.appleIntelligence`, refreshed by a
// `.task(id:)`, because `AssistantAvailabilityProbe.current` crosses into the
// system's language-model service. `AppEnvironment.chatAvailability` — which DOES
// probe — is for the composition root, where it runs once per conversation.
import DesignSystem
import Persistence
import Services
import SwiftUI
import ViewModels

extension AssistantView {
    var chat: LibraryChatViewModel? {
        environment.intelligence?.chat
    }

    var chatMessages: [LibraryChatMessage] {
        chat?.messages ?? []
    }

    var isChatEmpty: Bool {
        chatMessages.isEmpty
    }

    var isChatResponding: Bool {
        chat?.isResponding ?? false
    }

    /// Whether a conversation can start, and why not when it cannot.
    var chatAvailability: LibraryChatAvailability {
        #if DEBUG
            // The SURFACE half of the scripted-chat seam, and it is not optional: with
            // no connector selected this resolves entirely on the host's Apple
            // Intelligence probe, which has no override point — so a UI-test Mac
            // without it would never reach `startChatTurn()` and the scripted engine
            // would be dead code. See ``ScriptedChatUITestSeam``.
            if ScriptedChatUITestSeam.script != nil { return .ready(.appleIntelligence) }
        #endif
        guard let registry = environment.intelligence?.connectors else { return .intelligenceOff }
        let selection = AppEnvironment.chatConnectorSelection(settings: settings, registry: registry)
        return LibraryChatRouting.availability(
            intelligenceEnabled: settings.intelligenceEnabled,
            selection: selection,
            hasBrowsingConsent: selection.map { settings.hasLibraryBrowsingConsent(forConnectorID: $0.id) } ?? false,
            isConsentDeclined: selection.map { $0.id == chatDeclinedProviderID } ?? false,
            appleIntelligence: appleIntelligence
        )
    }

    /// The proposal a chat turn filed, while there is still something to review.
    ///
    /// Pending first, then the discarded shadow — so a card the listener discarded stays
    /// on the turn that produced it and can be reopened. `nil` once it has been APPLIED,
    /// which correctly makes the card disappear: that playlist now exists.
    func chatProposal(_ id: UUID) -> AIProposal? {
        environment.intelligence?.proposals.proposal(id: id)
            ?? environment.discardedProposals.proposal(id: id)
    }

    /// Opens a chat turn's proposal, re-filing it first when it was discarded —
    /// `AssistantViewModel.apply` refuses a handle the pending store does not hold.
    func openChatProposal(_ proposal: AIProposal) {
        environment.restoreDiscardedProposal(proposal)
        presented = .proposal(proposal)
    }

    /// Warms the tier because the listener started typing. Idempotent per conversation.
    func prewarmChat() {
        guard chatAvailability.isReady else { return }
        chat?.prewarm()
    }

    /// Why an on-device conversation shows no web links, when that is the state.
    ///
    /// Gated on ``chatAvailability``'s route rather than on the probe directly, so
    /// the row and the tier that will actually answer can never disagree — the same
    /// reason `AppEnvironment.suggestionEnricher` asks the routing function too.
    @ViewBuilder
    var webPointerRow: some View {
        if webPointer.isVisible(route: chatAvailability.route, settings: settings) {
            LibraryChatWebPointerBanner(dismiss: { webPointer.dismiss() })
        }
    }
}

// MARK: - Sending

extension AssistantView {
    /// A conversation when one is possible; the single-shot ladder when it is not.
    func submitRouted() {
        switch chatAvailability {
        case .ready:
            startChatTurn()
        case let .consentRequired(id, displayName):
            // The text is deliberately NOT cleared: declining must leave the request
            // exactly as typed so the listener can send it the ordinary way.
            presented = .browsingConsent(LibraryBrowsingDisclosure(id: id, displayName: displayName))
        case .intelligenceOff, .appleIntelligenceUnavailable, .providerCannotChat,
             .providerNeedsModel, .consentDeclined:
            hasAttemptedChat = true
            submitOneShot()
        }
    }

    private func startChatTurn() {
        guard let chat else { return }
        let request = requestText
        hasAttemptedChat = true
        requestText = ""
        Task { @MainActor in await chat.send(request) }
    }

    /// Clears the conversation AND the tier's own history. See ``LibraryChatViewModel/reset()``.
    var resetButton: some View {
        Button(action: resetChat) {
            Image(systemName: "arrow.counterclockwise")
                .font(tokens.typography.callout.font)
                .foregroundStyle(tokens.colors.accent.resolve(scheme))
                .padding(tokens.spacing.xSmall)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help(LibraryChatStrings.resetHelp)
        .accessibilityLabel(Text(LibraryChatStrings.resetTitle))
        .accessibilityIdentifier("assistant.chat.reset")
    }

    private func resetChat() {
        chat?.reset()
        hasAttemptedChat = false
    }
}

// MARK: - Consent

extension AssistantView {
    /// The library-browsing disclosure. Accepting records consent and sends the turn
    /// the listener already typed; the engine factory re-checks the record for itself
    /// at the single commit point.
    func browsingConsentSheet(_ disclosure: LibraryBrowsingDisclosure) -> some View {
        IntelligenceLibraryBrowsingConsentSheet(
            disclosure: disclosure,
            onAccept: {
                settings.recordLibraryBrowsingConsent(forConnectorID: disclosure.id)
                chatDeclinedProviderID = nil
                presented = nil
                submitRouted()
            },
            onDecline: {
                chatDeclinedProviderID = disclosure.id
                hasAttemptedChat = true
            }
        )
    }
}
