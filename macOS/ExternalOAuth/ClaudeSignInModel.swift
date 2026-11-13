// ClaudeSignInModel — the two-phase Claude subscription login, as UI state.
//
// ── WHY A PASTE FIELD AND NOT A LOOPBACK LISTENER ─────────────────────────────
//
// The plan left the delivery mechanism to follow whatever redirect the endpoint
// research landed on. It landed on a HOSTED callback page:
// `OAuthEndpointConfiguration.claudeSubscription.redirectURI` is
// `https://platform.claude.com/oauth/code/callback`, and the authorize URL carries
// `code=true`, which is precisely the parameter that makes that page RENDER a
// pasteable `code#state` line instead of redirecting anywhere. There is no
// `http://127.0.0.1:<port>` in the shipped configuration, so a loopback listener
// would have nothing to listen for — it would bind a socket the provider never
// connects to, and every login would hang until it timed out. The manual paste
// field is therefore not a fallback here; it is the only mechanism the researched
// redirect supports. (Should the redirect ever move to loopback, the switch is one
// configuration field plus `ClaudeOAuthFlow.exchange(code:state:request:)` — the
// flow itself is unchanged either way.)
//
// ── THE ONE STATE THAT MUST SURVIVE THE BROWSER TRIP ──────────────────────────
//
// ``ClaudeOAuthFlow/AuthorizeRequest`` is retained WHOLE between the two phases,
// not reduced to its URL. It carries the PKCE verifier (without which the token
// endpoint refuses the exchange) AND the CSRF state (against which the pasted
// value is checked before anything touches the network). Dropping either turns a
// completable login into a permanent failure.
//
// ── SECRECY ───────────────────────────────────────────────────────────────────
//
// Nothing here logs. The pasted authorization code is cleared on success and on
// abandonment; the tokens it becomes are handed straight to
// ``OAuthCredentialEngine/seed(_:)`` and never held by this model. Failure copy is
// mapped from the error CASE only — ``OAuthFlowError`` carries no token material
// by construction, and this model never renders `localizedDescription`.
import AIConnectorKit
import AIConnectorKitOAuth
import AppKit
import Foundation
import Observation

/// Drives the "Sign in with Claude" flow and reports it as one displayable phase.
@MainActor
@Observable
final class ClaudeSignInModel {
    /// Where the login has got to. The view renders this and nothing else.
    enum Phase: Equatable {
        case signedOut
        /// The browser is open; the listener has not pasted the code yet.
        case awaitingCode
        /// The code is being traded for tokens.
        case exchanging
        /// A credential is in force. `tier` is the provider's own token (`max`,
        /// `pro`) when it disclosed one.
        ///
        /// `viaCLI` distinguishes a session MacAMP owns from one BORROWED off a
        /// Claude Code CLI login on this Mac. The two are not interchangeable in
        /// the UI: signing out of a borrowed session cannot — and must not —
        /// delete another application's credential, so the copy has to say so
        /// rather than promise a removal that will not happen.
        case signedIn(tier: String?, viaCLI: Bool)
        case failed(ClaudeSignInFailure)
    }

    /// What the listener pasted back. Bound to the text field, cleared the moment
    /// it has been spent.
    var pastedValue = ""

    private(set) var phase: Phase = .signedOut

    private let flow: ClaudeOAuthFlow
    private let engine: OAuthCredentialEngine
    private let openURL: @MainActor (URL) -> Void

    /// The attempt in progress. `nil` outside a login.
    private var pending: ClaudeOAuthFlow.AuthorizeRequest?

    /// - Parameters:
    ///   - flow: Mints the authorize URL and performs the exchange.
    ///   - engine: Receives the resulting credential. The model never persists
    ///     anything itself.
    ///   - openURL: Injectable so previews and tests drive the flow without
    ///     launching a browser.
    init(
        flow: ClaudeOAuthFlow,
        engine: OAuthCredentialEngine,
        openURL: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.flow = flow
        self.engine = engine
        self.openURL = openURL
    }

    /// Whether ``completeSignIn()`` would do anything.
    var canComplete: Bool {
        phase == .awaitingCode && pastedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    /// Whether a login is under way, which is when the code field is shown.
    var isAwaitingCode: Bool {
        pending != nil
    }

    var isSignedIn: Bool {
        if case .signedIn = phase { return true }
        return false
    }

    /// Whether the session in force was borrowed from the Claude Code CLI.
    var isUsingCLISession: Bool {
        if case let .signedIn(_, viaCLI) = phase { return viaCLI }
        return false
    }

    /// Reads the stored credential and reports it, without refreshing anything.
    ///
    /// A blob that exists but will not decode is reported as SIGNED OUT rather
    /// than as an error: the only remedy is a fresh login, so offering one is more
    /// useful than explaining a corruption the listener cannot act on.
    func refreshStatus() async {
        guard pending == nil else { return }
        do {
            guard let reading = try await engine.storedCredentialReading() else {
                phase = .signedOut
                return
            }
            phase = .signedIn(tier: reading.credentials.subscriptionType, viaCLI: reading.origin.isExternal)
        } catch {
            phase = .signedOut
        }
    }

    /// Phase 1: mint the PKCE material and open the approval page.
    func beginSignIn() {
        do {
            let request = try flow.authorizeRequest()
            pending = request
            pastedValue = ""
            phase = .awaitingCode
            openURL(request.url)
        } catch {
            pending = nil
            phase = .failed(ClaudeSignInFailure(error))
        }
    }

    /// Re-opens the SAME approval page, for a listener who closed the tab.
    ///
    /// Deliberately not a new ``beginSignIn()``: minting a fresh attempt would
    /// invalidate the state the already-displayed code was issued against, so a
    /// listener who then pasted that code would be told it belongs to a different
    /// attempt — which it would, because we made it so.
    func reopenApprovalPage() {
        guard let pending else { return }
        openURL(pending.url)
    }

    /// Phase 2: validate and exchange the pasted value, then seed the engine.
    func completeSignIn() async {
        guard let request = pending else {
            phase = .failed(.unknown)
            return
        }
        let value = pastedValue
        phase = .exchanging
        do {
            let credentials = try await flow.exchange(pastedValue: value, request: request)
            try await engine.seed(credentials)
            pending = nil
            pastedValue = ""
            phase = .signedIn(tier: credentials.subscriptionType, viaCLI: false)
        } catch {
            // The field keeps its contents: the most common failure by far is a
            // partial copy, and clearing it would make the listener fetch the code
            // again for no reason. The code is single-use and already spent if the
            // provider saw it.
            phase = .failed(ClaudeSignInFailure(error))
        }
    }

    /// Abandons an attempt in progress and discards the code.
    func cancel() {
        pending = nil
        pastedValue = ""
        phase = .signedOut
    }

    /// Forgets the stored credential. Idempotent, matching the engine.
    ///
    /// For a BORROWED session this stops MacAMP consulting the Claude Code CLI's
    /// credential; it does not delete it. A relaunch finds the CLI still signed in
    /// and reuses it again — which is the honest consequence of never having owned
    /// it, and why the button that calls this is worded differently in that case.
    func signOut() async {
        try? await engine.signOut()
        pending = nil
        pastedValue = ""
        phase = .signedOut
    }
}

// MARK: - Failure

/// Why a sign-in did not finish, in terms a listener can act on.
///
/// Mapped from the error CASE alone. The underlying errors deliberately carry no
/// token material, and none of their descriptions reaches a screen.
enum ClaudeSignInFailure: Equatable {
    /// The pasted value was not the `code#state` line the callback page shows.
    case malformedCode
    /// The value belongs to a different attempt — its `state` did not match.
    case staleAttempt
    /// The provider answered and refused.
    case rejected
    /// The provider was never reached.
    case unreachable
    /// The provider rate-limited the attempt.
    case throttled
    case unknown

    init(_ error: Error) {
        if let flowError = error as? OAuthFlowError {
            self = Self.mapping(flowError)
        } else if let failure = error as? ConnectorFailure {
            self = Self.mapping(failure)
        } else {
            self = .unknown
        }
    }

    var message: LocalizedStringResource {
        switch self {
        case .malformedCode: ExternalOAuthStrings.claudeFailureMalformedCode
        case .staleAttempt: ExternalOAuthStrings.claudeFailureStaleAttempt
        case .rejected: ExternalOAuthStrings.claudeFailureRejected
        case .unreachable: ExternalOAuthStrings.claudeFailureUnreachable
        case .throttled: ExternalOAuthStrings.claudeFailureThrottled
        case .unknown: ExternalOAuthStrings.claudeFailureUnknown
        }
    }

    private static func mapping(_ error: OAuthFlowError) -> ClaudeSignInFailure {
        switch error {
        case .malformedCallbackValue: .malformedCode
        case .stateMismatch: .staleAttempt
        case .tokenEndpointRejected, .tokenResponseUnreadable, .tokenResponseMissingAccessToken,
             .tokenResponseMissingRefreshToken, .partialCredentialSeedRejected: .rejected
        case .authorizeRequestUnbuildable: .unknown
        }
    }

    /// Exhaustive on purpose — a new ``ConnectorFailure`` case must be given copy
    /// rather than silently inheriting "Sign-in did not finish".
    private static func mapping(_ failure: ConnectorFailure) -> ClaudeSignInFailure {
        switch failure {
        case .unreachable, .timeout: .unreachable
        case .rateLimited: .throttled
        // A token exchange has no output ceiling to hit, so `.truncated` is
        // unreachable here and joins the other unusable-answer cases.
        case .httpStatus, .authExpired, .malformedResponse, .truncated: .rejected
        case .unconfigured, .cancelled: .unknown
        }
    }
}
