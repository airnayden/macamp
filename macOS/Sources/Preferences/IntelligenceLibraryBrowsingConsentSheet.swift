// IntelligenceLibraryBrowsingConsentSheet — the last screen before a provider may
// read the library.
//
// Shaped deliberately like ``IntelligenceConsentSheet``: same header/payload/notes/
// actions spine, same identifier scheme, same "it discloses, it does not decide"
// split. A listener who saw the connect-time sheet recognises this one, and the two
// are read side by side when the second is the one that mattered.
//
// IT DISCLOSES; IT DOES NOT DECIDE. Accepting calls back into the pane, which records
// consent and starts the turn; ``AppEnvironment/makeChatEngine`` re-checks the record
// for itself at the single commit point, so a second entry point added later inherits
// the gate instead of bypassing it.
//
// Every number on screen is forwarded from ``ToolProfile`` and ``ToolLoopEngine``
// through ``LibraryBrowsingDisclosure``; the provider's name is a BRAND and arrives
// as an interpolation, never as a `Text(verbatim:)` fragment glued to a sentence.
import DesignSystem
import SwiftUI

/// The library-browsing disclosure a cloud provider must clear before its first turn.
struct IntelligenceLibraryBrowsingConsentSheet: View {
    let disclosure: LibraryBrowsingDisclosure
    /// Runs on acceptance. Records consent and starts the conversation.
    let onAccept: @MainActor () -> Void
    /// Runs on refusal. The surface remembers it so the sheet is not re-offered on
    /// every send, and the one-shot request path is left untouched.
    let onDecline: @MainActor () -> Void

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.large) {
            header
            payload
            notes
            actions
        }
        .padding(tokens.spacing.large)
        .frame(width: 480)
        .background(tokens.colors.canvas.resolve(scheme))
    }
}

// MARK: - Header

private extension IntelligenceLibraryBrowsingConsentSheet {
    /// `intelligence.browsingConsent.<id>.<element>` — built from the connector id, so
    /// two providers' sheets never collide in the accessibility hierarchy.
    func identifier(_ element: String) -> String {
        "intelligence.browsingConsent.\(disclosure.id).\(element)"
    }

    var header: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.xxSmall) {
            HStack(alignment: .firstTextBaseline, spacing: tokens.spacing.xSmall) {
                Image(systemName: "books.vertical")
                    .foregroundStyle(tokens.colors.warning.resolve(scheme))
                    .accessibilityHidden(true)
                Text(PreferencesStrings.browsingConsentTitle)
                    .font(tokens.typography.headline.font)
                    .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                    .accessibilityIdentifier(identifier("sheet"))
            }
            Text(PreferencesStrings.browsingConsentLead(provider: disclosure.displayName))
                .font(tokens.typography.callout.font)
                .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Disclosure

private extension IntelligenceLibraryBrowsingConsentSheet {
    /// Three "what it can see" items, then two "how much" items.
    var payload: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.xSmall) {
            Text(PreferencesStrings.browsingConsentPayloadHeading)
                .font(tokens.typography.callout.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                .fixedSize(horizontal: false, vertical: true)
            payloadRow(PreferencesStrings.browsingConsentNamesItem)
            payloadRow(PreferencesStrings.browsingConsentFacetsItem)
            payloadRow(PreferencesStrings.browsingConsentStatsItem)
            payloadRow(PreferencesStrings.browsingConsentSizeItem(
                rows: disclosure.rowsPerLookup,
                characters: disclosure.charactersPerLookup
            ))
            payloadRow(PreferencesStrings.browsingConsentRoundsItem(lookups: disclosure.lookupsPerQuestion))
        }
        .padding(tokens.spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: tokens.radii.medium, style: .continuous)
                .fill(tokens.colors.surface.resolve(scheme))
        )
        .accessibilityIdentifier(identifier("payload"))
    }

    func payloadRow(_ text: LocalizedStringResource) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: tokens.spacing.xSmall) {
            Image(systemName: "arrow.up.right")
                .font(tokens.typography.caption.font)
                .foregroundStyle(tokens.colors.accent.resolve(scheme))
                .accessibilityHidden(true)
            Text(text)
                .font(tokens.typography.body.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    var notes: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.xxSmall) {
            PreferenceCaption(text: PreferencesStrings.browsingConsentExclusions)
            PreferenceCaption(text: PreferencesStrings.browsingConsentDefault)
            PreferenceCaption(text: PreferencesStrings.browsingConsentReversible)
        }
    }
}

// MARK: - Actions

private extension IntelligenceLibraryBrowsingConsentSheet {
    var actions: some View {
        HStack(spacing: tokens.spacing.small) {
            Spacer()
            cancelButton
            acceptButton
        }
    }

    /// Declining writes nothing anywhere — not even the consent record.
    var cancelButton: some View {
        Button(role: .cancel) {
            onDecline()
            dismiss()
        } label: {
            Text(PreferencesStrings.browsingConsentCancel)
        }
        .keyboardShortcut(.cancelAction)
        .help(PreferencesStrings.browsingConsentCancelHelp)
        .pointingHandCursor()
        .accessibilityIdentifier(identifier("cancelButton"))
    }

    var acceptButton: some View {
        Button { onAccept() } label: {
            Text(PreferencesStrings.browsingConsentAccept)
        }
        .keyboardShortcut(.defaultAction)
        .help(PreferencesStrings.browsingConsentAcceptHelp)
        .pointingHandCursor()
        .accessibilityIdentifier(identifier("acceptButton"))
    }
}

#Preview {
    IntelligenceLibraryBrowsingConsentSheet(
        disclosure: LibraryBrowsingDisclosure(id: "ollama", displayName: "Ollama"),
        onAccept: {},
        onDecline: {}
    )
    .designTokens(.standard)
}
