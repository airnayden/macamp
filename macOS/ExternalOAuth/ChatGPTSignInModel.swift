// ChatGPTSignInModel — the ChatGPT subscription login, as UI state.
//
// ── WHY A LOOPBACK LISTENER AND NOT A PASTE FIELD ─────────────────────────────
//
// The mirror image of ``ClaudeSignInModel``'s note. Claude's researched redirect
// is a HOSTED page that displays a pasteable `code#state`, so a listener there
// would bind a socket the provider never connects to. ChatGPT's `redirect_uri` is
// `http://localhost:1455/auth/callback`, registered server-side — there is no page
// to copy anything off, and the ONLY way to receive the code is to be bound to
// that port when the browser follows the redirect. Hence
// ``LoopbackCallbackListener``, and hence the port being decided BEFORE the
// browser opens: the authorize URL must name the port that is actually listening.
//
// ── THE TWO THINGS THAT MUST SURVIVE THE BROWSER TRIP ─────────────────────────
//
//   1. ``ChatGPTOAuthFlow/AuthorizeRequest`` — WHOLE, not reduced to its URL. It
//      carries the PKCE verifier (without which the exchange is refused) and the
//      CSRF state (against which the callback is checked before any network call).
//   2. The listener itself. Dropping it closes the socket, and the redirect then
//      lands on a connection error with the code already spent.
//
// ── EVERY EXIT PATH CLOSES THE SOCKET ─────────────────────────────────────────
//
// Success, failure, cancellation, and `deinit`-by-way-of-sheet-dismissal all run
// through ``finish()``. A leaked listening socket would keep port 1455 bound for
// the life of the app and make the NEXT attempt fall back to 1457 — or fail.
//
// ── SECRECY ───────────────────────────────────────────────────────────────────
//
// Nothing here logs. The callback URL — which carries the authorization code — is
// held only as a local, handed straight to the flow, and never rendered. Failure
// copy is mapped from the error CASE alone; ``OAuthFlowError`` and
// ``ConnectorFailure`` carry no token material by construction, and this model
// never renders `localizedDescription`.
import AIConnectorKit
import AIConnectorKitOAuth
import AppKit
import Foundation
import Observation

/// Drives "Sign in with ChatGPT" and reports it as one displayable phase.
@MainActor
@Observable
final class ChatGPTSignInModel {
    /// Where the login has got to. The view renders this and nothing else.
    enum Phase: Equatable {
        case signedOut
        /// The browser is open and a loopback socket is waiting for the redirect.
        case awaitingBrowser
        /// The returned code is being traded for tokens.
        case exchanging
        /// A credential is stored. `tier` is the provider's own plan token
        /// (`plus`, `pro`, `team`) when the id_token disclosed one.
        case signedIn(tier: String?)
        case failed(ChatGPTSignInFailure)
    }

    private(set) var phase: Phase = .signedOut

    private let flow: ChatGPTOAuthFlow
    private let engine: OAuthCredentialEngine
    private let openURL: @MainActor (URL) -> Void
    private let ports: [Int]

    /// The attempt in progress: the PKCE material, the socket, and the task
    /// awaiting the redirect. All three are `nil` outside a login.
    private var pending: ChatGPTOAuthFlow.AuthorizeRequest?
    private var listener: LoopbackCallbackListener?
    private var waiting: Task<Void, Never>?

    /// - Parameters:
    ///   - flow: Mints the authorize URL and performs the exchange.
    ///   - engine: Receives the resulting credential. The model never persists
    ///     anything itself.
    ///   - ports: Loopback ports to try, in order. Only values registered against
    ///     the provider's `redirect_uri` can work — see
    ///     ``OAuthEndpointConfiguration/chatGPTFallbackCallbackPort``.
    ///   - openURL: Injectable so previews and tests drive the flow without
    ///     launching a browser.
    init(
        flow: ChatGPTOAuthFlow,
        engine: OAuthCredentialEngine,
        ports: [Int] = [
            OAuthEndpointConfiguration.chatGPTPrimaryCallbackPort,
            OAuthEndpointConfiguration.chatGPTFallbackCallbackPort,
        ],
        openURL: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.flow = flow
        self.engine = engine
        self.ports = ports
        self.openURL = openURL
    }

    /// Whether an attempt is under way, which is when Cancel and Re-open apply.
    var isAwaitingBrowser: Bool {
        pending != nil
    }

    var isSignedIn: Bool {
        if case .signedIn = phase { return true }
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
            guard let credentials = try await engine.storedCredentials() else {
                phase = .signedOut
                return
            }
            phase = .signedIn(tier: credentials.subscriptionType)
        } catch {
            phase = .signedOut
        }
    }

    /// Binds the callback port, mints the PKCE material, and opens the browser —
    /// in that ORDER.
    ///
    /// The port has to be known before the authorize URL is built, because the URL
    /// names it and the provider's exact-match check on `redirect_uri` is
    /// byte-for-byte.
    func beginSignIn() async {
        finish()
        do {
            let socket = try LoopbackCallbackListener.bind(preferredPorts: ports)
            listener = socket
            let bound = flow.boundToLoopback(port: socket.port)
            let request = try bound.authorizeRequest()
            pending = request
            phase = .awaitingBrowser
            waiting = Task { [weak self] in await self?.awaitCallback(socket: socket, flow: bound, request: request) }
            openURL(request.url)
        } catch {
            finish()
            phase = .failed(ChatGPTSignInFailure(error))
        }
    }

    /// Re-opens the SAME approval page, for a listener who closed the tab.
    ///
    /// Deliberately not a fresh ``beginSignIn()``: a new attempt mints a new
    /// `state`, and the already-open page would then come back with one this
    /// process no longer recognises.
    func reopenApprovalPage() {
        guard let pending else { return }
        openURL(pending.url)
    }

    /// Abandons an attempt, closing the socket.
    func cancel() {
        finish()
        phase = .signedOut
    }

    /// Forgets the stored credential. Idempotent, matching the engine.
    func signOut() async {
        finish()
        try? await engine.signOut()
        phase = .signedOut
    }

    /// Waits for the redirect, exchanges it, and seeds the engine.
    private func awaitCallback(
        socket: LoopbackCallbackListener,
        flow: ChatGPTOAuthFlow,
        request: ChatGPTOAuthFlow.AuthorizeRequest
    ) async {
        do {
            let callbackURL = try await socket.waitForCallback()
            guard pending != nil else { return }
            phase = .exchanging
            let session = try await flow.exchange(callbackURL: callbackURL, request: request)
            try await engine.seed(session.credentials)
            finish()
            phase = .signedIn(tier: session.credentials.subscriptionType)
        } catch {
            guard pending != nil else { return }
            finish()
            phase = .failed(ChatGPTSignInFailure(error))
        }
    }

    /// Tears the attempt down. Safe to call from any exit path, and idempotent.
    private func finish() {
        let socket = listener
        listener = nil
        pending = nil
        waiting?.cancel()
        waiting = nil
        Task { await socket?.cancel() }
    }
}

// MARK: - Failure

/// Why a ChatGPT sign-in did not finish, in terms a listener can act on.
///
/// Mapped from the error CASE alone. The underlying errors deliberately carry no
/// token material, and none of their descriptions reaches a screen.
enum ChatGPTSignInFailure: Equatable {
    /// Neither registered loopback port could be bound.
    case portUnavailable
    /// The callback belongs to a different attempt — its `state` did not match.
    case staleAttempt
    /// The provider answered and refused.
    case rejected
    /// The provider was never reached.
    case unreachable
    /// The provider rate-limited the attempt.
    case throttled
    case unknown

    init(_ error: Error) {
        if let listenerError = error as? LoopbackCallbackListener.Failure {
            self = Self.mapping(listenerError)
        } else if let flowError = error as? OAuthFlowError {
            self = Self.mapping(flowError)
        } else if let failure = error as? ConnectorFailure {
            self = Self.mapping(failure)
        } else {
            self = .unknown
        }
    }

    var message: LocalizedStringResource {
        switch self {
        case .portUnavailable: ChatGPTOAuthStrings.failurePortUnavailable
        case .staleAttempt: ChatGPTOAuthStrings.failureStaleAttempt
        case .rejected: ChatGPTOAuthStrings.failureRejected
        case .unreachable: ChatGPTOAuthStrings.failureUnreachable
        case .throttled: ChatGPTOAuthStrings.failureThrottled
        case .unknown: ChatGPTOAuthStrings.failureUnknown
        }
    }

    private static func mapping(_ error: LoopbackCallbackListener.Failure) -> ChatGPTSignInFailure {
        switch error {
        case .noPortAvailable: .portUnavailable
        // A cancelled or unreadable callback is not something to explain in
        // detail — either way the attempt is over and the remedy is to start again.
        case .cancelled, .malformedRequest: .unknown
        }
    }

    private static func mapping(_ error: OAuthFlowError) -> ChatGPTSignInFailure {
        switch error {
        case .stateMismatch: .staleAttempt
        case .malformedCallbackValue, .tokenEndpointRejected, .tokenResponseUnreadable,
             .tokenResponseMissingAccessToken, .tokenResponseMissingRefreshToken,
             .partialCredentialSeedRejected: .rejected
        case .authorizeRequestUnbuildable: .unknown
        }
    }

    /// Exhaustive on purpose — a new ``ConnectorFailure`` case must be given copy
    /// rather than silently inheriting "Sign-in did not finish".
    private static func mapping(_ failure: ConnectorFailure) -> ChatGPTSignInFailure {
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
