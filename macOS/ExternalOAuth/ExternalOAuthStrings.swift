// ExternalOAuthStrings — user-facing copy for the subscription sign-in surface.
//
// Same conventions as `PreferencesStrings` and its siblings: every string is a
// `LocalizedStringResource` with an English `defaultValue` and a dotted
// `app.externalOAuth.*` key, which is the single handoff list for translation.
//
// TWO GUARD NOTES, because this folder is easy to get wrong:
//
//   1. `scripts/check-hardcoded-strings.sh` scans `macOS/Sources`, `iOS/Sources`
//      and `AIConnectorKit/Sources` — it does NOT scan `macOS/ExternalOAuth`.
//      Nothing here is machine-checked, so the zero-hardcoded-text rule is
//      enforced by review alone. Route every new label through this file.
//   2. The keys are NOT yet in `macOS/Sources/Localizable.xcstrings`. The
//      `defaultValue` renders real English immediately, and Xcode extracts the
//      keys into the catalog on build; the translated entries land with the rest
//      of the connector copy.
//
// The "Claude" and "Anthropic" brand names are product names and stay as written.
// The "MacAMP" brand deliberately does not appear in any sentence here — it is
// never localized, and splicing a verbatim token into translated prose would
// break every translation's word order.
import Foundation

/// Copy for the Claude subscription sign-in flow.
enum ExternalOAuthStrings {
    // MARK: Section

    static let claudeTitle = LocalizedStringResource(
        "app.externalOAuth.claude.title",
        defaultValue: "Claude Subscription",
        comment: "Title of the section where the user signs in with a Claude Pro or Max account"
    )
    static let claudeCaption = LocalizedStringResource(
        "app.externalOAuth.claude.caption",
        defaultValue: "Use your Claude Pro or Max plan instead of an API key. The session is stored in your Keychain; your password is never seen or saved.",
        comment: "Explains what signing in with a Claude subscription does and where the session is stored"
    )

    // MARK: Actions

    static let claudeSignIn = LocalizedStringResource(
        "app.externalOAuth.claude.signIn",
        defaultValue: "Sign in with Claude",
        comment: "Button that opens the browser to approve access to a Claude subscription"
    )
    static let claudeSignInHelp = LocalizedStringResource(
        "app.externalOAuth.claude.signIn.help",
        defaultValue: "Opens Claude in your browser to approve access for this Mac",
        comment: "Tooltip for the sign-in button"
    )
    static let claudeReopen = LocalizedStringResource(
        "app.externalOAuth.claude.reopen",
        defaultValue: "Open Approval Page Again",
        comment: "Button that re-opens the browser approval page for the sign-in already in progress"
    )
    static let claudeReopenHelp = LocalizedStringResource(
        "app.externalOAuth.claude.reopen.help",
        defaultValue: "Re-opens the same approval page — the code you already have stays valid",
        comment: "Tooltip for the button that re-opens the approval page"
    )
    static let claudeComplete = LocalizedStringResource(
        "app.externalOAuth.claude.complete",
        defaultValue: "Complete Sign In",
        comment: "Button that exchanges the pasted code for a session"
    )
    static let claudeCompleteHelp = LocalizedStringResource(
        "app.externalOAuth.claude.complete.help",
        defaultValue: "Exchanges the pasted code for a session",
        comment: "Tooltip for the button that finishes sign-in"
    )
    static let claudeCancel = LocalizedStringResource(
        "app.externalOAuth.claude.cancel",
        defaultValue: "Cancel",
        comment: "Button that abandons a sign-in attempt in progress"
    )
    static let claudeCancelHelp = LocalizedStringResource(
        "app.externalOAuth.claude.cancel.help",
        defaultValue: "Abandons this sign-in attempt and discards the code",
        comment: "Tooltip for the button that abandons a sign-in attempt"
    )
    static let claudeSignOut = LocalizedStringResource(
        "app.externalOAuth.claude.signOut",
        defaultValue: "Sign Out",
        comment: "Button that forgets the stored Claude subscription session"
    )
    static let claudeSignOutHelp = LocalizedStringResource(
        "app.externalOAuth.claude.signOut.help",
        defaultValue: "Removes the stored session from your Keychain",
        comment: "Tooltip for the sign-out button"
    )
    static let claudeStopUsingCLI = LocalizedStringResource(
        "app.externalOAuth.claude.stopUsingCLI",
        defaultValue: "Stop Using CLI Session",
        comment: "Button that stops the app reusing the Claude command-line tool's session, without signing that tool out"
    )
    static let claudeStopUsingCLIHelp = LocalizedStringResource(
        "app.externalOAuth.claude.stopUsingCLI.help",
        defaultValue: "Stops using the session until the next launch. The Claude command-line tool stays signed in — its login is never deleted.",
        comment: "Tooltip explaining that stopping reuse does not sign the Claude command-line tool out"
    )

    // MARK: Reused CLI session

    static let claudeCLICaption = LocalizedStringResource(
        "app.externalOAuth.claude.cli.caption",
        defaultValue: "This session comes from the Claude command-line tool already signed in on this Mac. Nothing was stored here, and signing out below never deletes that tool’s login.",
        comment: "Caption shown when the app is reusing a session belonging to the Claude command-line tool"
    )
    static let claudeStatusSignedInViaCLI = LocalizedStringResource(
        "app.externalOAuth.claude.status.signedInViaCLI",
        defaultValue: "Signed in via Claude CLI.",
        comment: "Status shown when the session in use was reused from the Claude command-line tool and the plan tier is unknown"
    )

    /// "Signed in via Claude CLI — max plan." The tier is a provider token
    /// (`max`, `pro`) interpolated rather than translated, matching
    /// ``claudeStatusSignedIn(tier:)``.
    static func claudeStatusSignedInViaCLI(tier: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.externalOAuth.claude.status.signedInViaCLI.tier",
            defaultValue: "Signed in via Claude CLI — \(tier) plan.",
            comment: "Status shown when the reused Claude command-line session names a subscription tier"
        )
    }

    // MARK: Code entry

    static let claudeCodeInstructions = LocalizedStringResource(
        "app.externalOAuth.claude.code.instructions",
        defaultValue: "Approve access in your browser. Claude then shows a single line of text — copy all of it and paste it below.",
        comment: "Instructions telling the user to copy the code Claude displays on its callback page and paste it back"
    )
    static let claudeCodeLabel = LocalizedStringResource(
        "app.externalOAuth.claude.code.label",
        defaultValue: "Authorization code",
        comment: "Label of the field the user pastes the Claude authorization code into"
    )
    static let claudeCodePrompt = LocalizedStringResource(
        "app.externalOAuth.claude.code.prompt",
        defaultValue: "Paste the line Claude showed you",
        comment: "Placeholder inside the authorization-code field"
    )

    // MARK: Status

    static let claudeStatusLabel = LocalizedStringResource(
        "app.externalOAuth.claude.status.label",
        defaultValue: "Status",
        comment: "Label of the row reporting the state of the Claude sign-in"
    )
    static let claudeStatusSignedOut = LocalizedStringResource(
        "app.externalOAuth.claude.status.signedOut",
        defaultValue: "Not signed in.",
        comment: "Status shown before any Claude sign-in has happened"
    )
    static let claudeStatusAwaitingCode = LocalizedStringResource(
        "app.externalOAuth.claude.status.awaitingCode",
        defaultValue: "Waiting for the code from your browser.",
        comment: "Status shown while the user is approving access in the browser"
    )
    static let claudeStatusExchanging = LocalizedStringResource(
        "app.externalOAuth.claude.status.exchanging",
        defaultValue: "Finishing sign-in…",
        comment: "Status shown while the pasted code is being exchanged for a session"
    )
    static let claudeStatusSignedIn = LocalizedStringResource(
        "app.externalOAuth.claude.status.signedIn",
        defaultValue: "Signed in.",
        comment: "Status shown when a Claude session is stored and the plan tier is unknown"
    )

    /// "Signed in — max plan." The tier is a provider token (`max`, `pro`) that is
    /// interpolated rather than translated, because it is the value Anthropic
    /// itself returns.
    static func claudeStatusSignedIn(tier: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.externalOAuth.claude.status.signedIn.tier",
            defaultValue: "Signed in — \(tier) plan.",
            comment: "Status shown when a Claude session is stored, naming the subscription tier"
        )
    }

    // MARK: Failures

    static let claudeFailureMalformedCode = LocalizedStringResource(
        "app.externalOAuth.claude.failure.malformedCode",
        defaultValue: "That is not the whole line Claude showed. Copy all of it, including everything after the “#”.",
        comment: "Error shown when the pasted authorization code is not in the expected code#state form"
    )
    static let claudeFailureStaleAttempt = LocalizedStringResource(
        "app.externalOAuth.claude.failure.staleAttempt",
        defaultValue: "That code belongs to a different sign-in attempt. Start again.",
        comment: "Error shown when the pasted code's state does not match the attempt in progress"
    )
    static let claudeFailureRejected = LocalizedStringResource(
        "app.externalOAuth.claude.failure.rejected",
        defaultValue: "Claude turned down the sign-in. Start again.",
        comment: "Error shown when the provider refuses the code exchange"
    )
    static let claudeFailureUnreachable = LocalizedStringResource(
        "app.externalOAuth.claude.failure.unreachable",
        defaultValue: "Could not reach Claude. Check your connection and try again.",
        comment: "Error shown when the token endpoint could not be reached at all"
    )
    static let claudeFailureThrottled = LocalizedStringResource(
        "app.externalOAuth.claude.failure.throttled",
        defaultValue: "Too many attempts. Wait a moment and try again.",
        comment: "Error shown when the provider rate-limits the sign-in"
    )
    static let claudeFailureUnknown = LocalizedStringResource(
        "app.externalOAuth.claude.failure.unknown",
        defaultValue: "Sign-in did not finish. Start again.",
        comment: "Error shown when sign-in fails for a reason with no more specific explanation"
    )
}

/// Copy for the ChatGPT subscription sign-in flow.
///
/// A separate enum from ``ExternalOAuthStrings`` only because that one is already
/// near SwiftLint's `type_body_length` ceiling; the key namespace continues
/// unchanged (`app.externalOAuth.chatGPT.*`).
enum ChatGPTOAuthStrings {
    // MARK: Section

    static let title = LocalizedStringResource(
        "app.externalOAuth.chatGPT.title",
        defaultValue: "ChatGPT Subscription",
        comment: "Title of the section where the user signs in with a ChatGPT Plus, Pro or Team account"
    )
    static let caption = LocalizedStringResource(
        "app.externalOAuth.chatGPT.caption",
        defaultValue: "Use your ChatGPT plan instead of an API key. Approval happens in your browser and comes back to this Mac automatically; the session is stored in your Keychain and your password is never seen or saved.",
        comment: "Explains what signing in with a ChatGPT subscription does and where the session is stored"
    )

    // MARK: Actions

    static let signIn = LocalizedStringResource(
        "app.externalOAuth.chatGPT.signIn",
        defaultValue: "Sign in with ChatGPT",
        comment: "Button that opens the browser to approve access to a ChatGPT subscription"
    )
    static let signInHelp = LocalizedStringResource(
        "app.externalOAuth.chatGPT.signIn.help",
        defaultValue: "Opens ChatGPT in your browser to approve access for this Mac",
        comment: "Tooltip for the ChatGPT sign-in button"
    )
    static let reopen = LocalizedStringResource(
        "app.externalOAuth.chatGPT.reopen",
        defaultValue: "Open Approval Page Again",
        comment: "Button that re-opens the browser approval page for the ChatGPT sign-in already in progress"
    )
    static let reopenHelp = LocalizedStringResource(
        "app.externalOAuth.chatGPT.reopen.help",
        defaultValue: "Re-opens the same approval page — this Mac is still waiting for it",
        comment: "Tooltip for the button that re-opens the ChatGPT approval page"
    )
    static let cancel = LocalizedStringResource(
        "app.externalOAuth.chatGPT.cancel",
        defaultValue: "Cancel",
        comment: "Button that abandons a ChatGPT sign-in attempt in progress"
    )
    static let cancelHelp = LocalizedStringResource(
        "app.externalOAuth.chatGPT.cancel.help",
        defaultValue: "Abandons this sign-in attempt and stops listening for the browser",
        comment: "Tooltip for the button that abandons a ChatGPT sign-in attempt"
    )
    static let signOut = LocalizedStringResource(
        "app.externalOAuth.chatGPT.signOut",
        defaultValue: "Sign Out",
        comment: "Button that forgets the stored ChatGPT subscription session"
    )
    static let signOutHelp = LocalizedStringResource(
        "app.externalOAuth.chatGPT.signOut.help",
        defaultValue: "Removes the stored session from your Keychain",
        comment: "Tooltip for the ChatGPT sign-out button"
    )

    // MARK: Status

    static let statusLabel = LocalizedStringResource(
        "app.externalOAuth.chatGPT.status.label",
        defaultValue: "Status",
        comment: "Label of the row reporting the state of the ChatGPT sign-in"
    )
    static let statusSignedOut = LocalizedStringResource(
        "app.externalOAuth.chatGPT.status.signedOut",
        defaultValue: "Not signed in.",
        comment: "Status shown before any ChatGPT sign-in has happened"
    )
    static let statusAwaitingBrowser = LocalizedStringResource(
        "app.externalOAuth.chatGPT.status.awaitingBrowser",
        defaultValue: "Waiting for you to approve access in your browser…",
        comment: "Status shown while the browser approval page is open and this Mac is listening for the redirect"
    )
    static let statusExchanging = LocalizedStringResource(
        "app.externalOAuth.chatGPT.status.exchanging",
        defaultValue: "Finishing sign-in…",
        comment: "Status shown while the returned code is being exchanged for a ChatGPT session"
    )
    static let statusSignedIn = LocalizedStringResource(
        "app.externalOAuth.chatGPT.status.signedIn",
        defaultValue: "Signed in.",
        comment: "Status shown when a ChatGPT session is stored and the plan tier is unknown"
    )

    /// "Signed in — pro plan." The tier is a provider token (`plus`, `pro`,
    /// `team`) interpolated rather than translated, because it is the value
    /// OpenAI itself returns.
    static func statusSignedIn(tier: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.externalOAuth.chatGPT.status.signedIn.tier",
            defaultValue: "Signed in — \(tier) plan.",
            comment: "Status shown when a ChatGPT session is stored, naming the subscription tier"
        )
    }

    // MARK: Failures

    static let failurePortUnavailable = LocalizedStringResource(
        "app.externalOAuth.chatGPT.failure.portUnavailable",
        defaultValue: "Another app is using the port ChatGPT sends approval back to. Quit any running Codex sign-in and try again.",
        comment: "Error shown when neither loopback port used by the ChatGPT sign-in redirect could be opened"
    )
    static let failureStaleAttempt = LocalizedStringResource(
        "app.externalOAuth.chatGPT.failure.staleAttempt",
        defaultValue: "That approval belongs to a different sign-in attempt. Start again.",
        comment: "Error shown when the browser callback's state value does not match the attempt in progress"
    )
    static let failureRejected = LocalizedStringResource(
        "app.externalOAuth.chatGPT.failure.rejected",
        defaultValue: "ChatGPT turned down the sign-in. Start again.",
        comment: "Error shown when the provider refuses the ChatGPT code exchange"
    )
    static let failureUnreachable = LocalizedStringResource(
        "app.externalOAuth.chatGPT.failure.unreachable",
        defaultValue: "Could not reach ChatGPT. Check your connection and try again.",
        comment: "Error shown when the ChatGPT token endpoint could not be reached at all"
    )
    static let failureThrottled = LocalizedStringResource(
        "app.externalOAuth.chatGPT.failure.throttled",
        defaultValue: "Too many attempts. Wait a moment and try again.",
        comment: "Error shown when the provider rate-limits the ChatGPT sign-in"
    )
    static let failureUnknown = LocalizedStringResource(
        "app.externalOAuth.chatGPT.failure.unknown",
        defaultValue: "Sign-in did not finish. Start again.",
        comment: "Error shown when the ChatGPT sign-in fails for a reason with no more specific explanation"
    )
}

extension ExternalOAuthStrings {
    // MARK: Browser callback page

    static let chatGPTCallbackSuccessTitle = LocalizedStringResource(
        "app.externalOAuth.chatGPT.callback.success.title",
        defaultValue: "You’re signed in",
        comment: "Heading of the local web page the browser lands on after approving ChatGPT access"
    )
    static let chatGPTCallbackSuccessBody = LocalizedStringResource(
        "app.externalOAuth.chatGPT.callback.success.body",
        defaultValue: "You can close this tab and go back to the app.",
        comment: "Body of the local web page shown after a successful ChatGPT approval"
    )
    static let chatGPTCallbackFailureTitle = LocalizedStringResource(
        "app.externalOAuth.chatGPT.callback.failure.title",
        defaultValue: "Something went wrong",
        comment: "Heading of the local web page shown when the ChatGPT approval redirect could not be read"
    )
    static let chatGPTCallbackFailureBody = LocalizedStringResource(
        "app.externalOAuth.chatGPT.callback.failure.body",
        defaultValue: "Close this tab and start the sign-in again from the app.",
        comment: "Body of the local web page shown when the ChatGPT approval redirect could not be read"
    )
}
