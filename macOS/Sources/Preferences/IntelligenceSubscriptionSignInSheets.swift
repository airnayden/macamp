// IntelligenceSubscriptionSignInSheets — the two modals that host a subscription
// login, split out of `IntelligenceProviderSection.swift`.
//
// Split for one mechanical reason: `.swiftlint.yml` does not override
// `file_length`, so the 400-line ceiling applies under `--strict`, and adding a
// second sheet pushed the provider section past it.
//
// The FILENAME still starts with `Intelligence`, and that is load-bearing:
// `scripts/check-ai-network-boundary.sh` globs
// `macOS/Sources/Preferences/Intelligence*`, so a pane or sheet named anything
// else silently escapes the guard that keeps `URLSession` out of the panes.
//
// ── ONE PROCESS-WIDE STACK PER PROVIDER ───────────────────────────────────────
//
// Both sheets build their model over ``ExternalOAuthStacks``, the SAME stacks the
// registry's connectors read. A stack constructed here instead would sign in to an
// engine nothing else consults: the login would report success and the assistant
// would still be unconfigured — and two `OAuthCredentialEngine`s over one Keychain
// slot each memoise their own in-flight refresh, defeating the single-flighting
// that stops a single-use refresh token being spent twice.
//
// ── WHY `multilineTextAlignment` IS RESET ─────────────────────────────────────
//
// The presenter is a button inside a `Form`'s `LabeledContent`, whose trailing
// content centres wrapped text — and a sheet inherits the environment of whatever
// presents it. Without the reset, every caption in these flows arrives centred.
#if MACAMP_EXTERNAL_OAUTH
    import DesignSystem
    import SwiftUI

    /// Hosts ``ClaudeSignInView`` as a modal.
    ///
    /// That view is deliberately chrome-free so it composes inside a `Form` as well
    /// as a sheet, which leaves the frame, the padding, and — the part that matters
    /// — the way OUT to whoever presents it: its own buttons all drive the login,
    /// and none of them dismisses anything.
    struct ClaudeSignInSheet: View {
        @Environment(\.designTokens) private var tokens
        @Environment(\.colorScheme) private var scheme

        @State private var model: ClaudeSignInModel

        @MainActor
        init() {
            _model = State(initialValue: ExternalOAuthComposition.makeSignInModel(ExternalOAuthStacks.claude))
        }

        var body: some View {
            SubscriptionSignInSheetFrame(tokens: tokens, scheme: scheme) {
                ClaudeSignInView(model: model)
            }
        }
    }

    /// Hosts ``ChatGPTSignInView`` as a modal.
    ///
    /// Dismissing this sheet does NOT cancel an attempt in progress — the model
    /// owns the loopback socket and tears it down on its own exit paths, so a
    /// listener who closes the window mid-approval loses nothing but the view.
    struct ChatGPTSignInSheet: View {
        @Environment(\.designTokens) private var tokens
        @Environment(\.colorScheme) private var scheme

        @State private var model: ChatGPTSignInModel

        @MainActor
        init() {
            _model = State(initialValue: ExternalOAuthComposition.makeSignInModel(ExternalOAuthStacks.chatGPT))
        }

        var body: some View {
            SubscriptionSignInSheetFrame(tokens: tokens, scheme: scheme) {
                ChatGPTSignInView(model: model)
            }
        }
    }

    /// The chrome both sheets share: padding, width, canvas, and the ONE control
    /// that dismisses — the flows themselves never do.
    private struct SubscriptionSignInSheetFrame<Content: View>: View {
        let tokens: DesignTokens
        let scheme: ColorScheme
        @ViewBuilder let content: () -> Content

        @Environment(\.dismiss) private var dismiss

        var body: some View {
            VStack(alignment: .leading, spacing: tokens.spacing.large) {
                content()
                HStack {
                    Spacer()
                    Button(role: .cancel) { dismiss() } label: {
                        Text(PreferencesStrings.intelligenceConnectorSignInDone)
                    }
                    .keyboardShortcut(.cancelAction)
                    .pointingHandCursor()
                    .accessibilityIdentifier("intelligence.connectorSignIn.doneButton")
                }
            }
            .multilineTextAlignment(.leading)
            .padding(tokens.spacing.large)
            .frame(width: 460)
            .background(tokens.colors.canvas.resolve(scheme))
        }
    }
#endif
