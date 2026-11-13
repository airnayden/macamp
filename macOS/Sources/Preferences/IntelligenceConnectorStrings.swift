// IntelligenceConnectorStrings — the shell half of the connector contract: TOKEN → SENTENCE.
//
// `AIConnectorKit` ships zero user-visible strings by design. `ConnectorStatus`
// carries machine tokens (`upstream-flow-unavailable`), `ConnectorFailure` carries
// a diagnostic vocabulary (`connection-refused`), and NEITHER may ever reach a
// label. This file is the single place those become sentences, so a new token has
// exactly one mapping to add and the pane has none.
//
// Split out of `IntelligencePreferencesStrings` (itself split out of
// `PreferencesStrings`) for the usual mechanical reason — `file_length` is capped
// at 400 under `swiftlint --strict` — and declared as an extension so every call
// site still reads `PreferencesStrings.<name>`.
//
// ── THE MAPPING FUNCTIONS ARE EXHAUSTIVE, WITH NO `default:` ───────────────────
//
// `ConnectorStatus` and `ConnectorFailure` are both written as TOTAL taxonomies
// precisely so a consumer that adds a case breaks the build here instead of
// rendering a blank row. `connectorStatusMessage(_:)` and `connectorFailureMessage(_:)`
// honour that: neither carries a `default:`. The ONE fallback in this file is the
// `disabled(reason:)` token mapping, which cannot be exhaustive — the payload is a
// `String` — and therefore degrades to generic copy rather than leaking the token.
//
// Provider and model names are NOT localized: `Ollama`, `Anthropic`, `gpt-4o` and
// `llama3.2:latest` are brands and provider-assigned identifiers, in the same class
// as the MacAMP brand. The pane renders those with `Text(verbatim:)`.
import AIConnectorKit
import Foundation

extension PreferencesStrings {
    // MARK: Provider section chrome

    static let intelligenceProviderSection = LocalizedStringResource(
        "app.preferences.intelligence.provider",
        defaultValue: "Provider",
        comment: "Header of the section choosing which AI provider answers requests"
    )
    static let intelligenceProviderCaption = LocalizedStringResource(
        "app.preferences.intelligence.provider.caption",
        defaultValue: "Apple Intelligence answers on this Mac. Any other provider receives your request over the network.",
        comment: "Explains that only the default provider keeps requests on-device"
    )
    static let intelligenceProviderLabel = LocalizedStringResource(
        "app.preferences.intelligence.provider.label",
        defaultValue: "Answered by",
        comment: "Label of the picker choosing which AI provider answers requests"
    )
    /// The `nil` selection: the shipped default, on-device, zero network.
    /// The picker's no-provider entry once Apple Intelligence is retired.
    static let intelligenceProviderNone = LocalizedStringResource(
        "app.preferences.intelligence.provider.none",
        defaultValue: "None (built-in matcher)",
        comment: "Provider picker entry meaning no AI provider: requests are matched on this Mac without a language model"
    )
    static let intelligenceProviderCaptionRetired = LocalizedStringResource(
        "app.preferences.intelligence.provider.caption.retired",
        defaultValue: "A local Ollama server keeps everything on this Mac. Other providers receive your request over the network.",
        comment: "Explains which providers keep requests on-device, after Apple Intelligence was retired"
    )
    static let intelligenceAppleIntelligenceRetired = LocalizedStringResource(
        "app.preferences.intelligence.provider.appleIntelligenceRetired",
        defaultValue: "Apple Intelligence is no longer available as a provider and will be removed in a future update.",
        comment: "Footnote under the provider picker announcing that the Apple Intelligence option was retired"
    )
    /// DEPRECATED: only shown while Apple Intelligence is still a selectable provider.
    static let intelligenceProviderDefault = LocalizedStringResource(
        "app.preferences.intelligence.provider.default",
        defaultValue: "Apple Intelligence",
        comment: "The default entry of the provider picker: the on-device model, no network"
    )
    static let intelligenceModelLabel = LocalizedStringResource(
        "app.preferences.intelligence.provider.model",
        defaultValue: "Model",
        comment: "Label of the picker choosing which of a provider's models to use"
    )
    /// The `nil` model selection — the connector picks its own default.
    static let intelligenceModelAutomatic = LocalizedStringResource(
        "app.preferences.intelligence.provider.model.automatic",
        defaultValue: "Automatic",
        comment: "Model picker entry meaning the provider chooses its own default model"
    )
    static let intelligenceModelsUnknown = LocalizedStringResource(
        "app.preferences.intelligence.provider.model.unknown",
        defaultValue: "Refresh to load this provider’s model list.",
        comment: "Shown when no probe has enumerated the provider's models yet"
    )
    static let intelligenceModelsEmpty = LocalizedStringResource(
        "app.preferences.intelligence.provider.model.empty",
        defaultValue: "This provider listed no models.",
        comment: "Shown when the provider answered with an empty model list"
    )
    static let intelligenceConnectorRefresh = LocalizedStringResource(
        "app.preferences.intelligence.provider.refresh",
        defaultValue: "Refresh",
        comment: "Button that re-checks the selected provider and reloads its model list"
    )
    static let intelligenceConnectorRefreshHelp = LocalizedStringResource(
        "app.preferences.intelligence.provider.refresh.help",
        defaultValue: "Check this provider again and reload its list of models.",
        comment: "Tooltip of the provider refresh button"
    )
    /// The sibling of ``intelligenceConnectorConfigure`` for a provider with nothing
    /// to type: a subscription is configured by signing in, so the affordance beside
    /// its status row opens a login rather than a credential sheet.
    static let intelligenceConnectorSignIn = LocalizedStringResource(
        "app.preferences.intelligence.provider.signIn",
        defaultValue: "Sign In…",
        comment: "Button beside the provider picker that opens the selected provider's sign-in flow"
    )
    static let intelligenceConnectorSignInHelp = LocalizedStringResource(
        "app.preferences.intelligence.provider.signIn.help",
        defaultValue: "Sign in to your subscription to use this provider.",
        comment: "Tooltip of the button opening the selected provider's sign-in flow"
    )
    /// The sign-in sheet's only way out. The flow's own buttons all drive the login;
    /// none of them dismisses, so the host supplies this one.
    static let intelligenceConnectorSignInDone = LocalizedStringResource(
        "app.preferences.intelligence.provider.signIn.done",
        defaultValue: "Done",
        comment: "Button dismissing the provider sign-in sheet"
    )
    static let intelligenceConnectorStatusLabel = LocalizedStringResource(
        "app.preferences.intelligence.provider.status",
        defaultValue: "Provider status",
        comment: "Label of the row reporting the selected provider's state"
    )
    static let intelligenceConnectorChecking = LocalizedStringResource(
        "app.preferences.intelligence.provider.checking",
        defaultValue: "Checking…",
        comment: "Status shown while the selected provider is being probed"
    )

    // MARK: ConnectorStatus

    /// The sentence for one connector state. EXHAUSTIVE — see the file header.
    static func connectorStatusMessage(_ status: ConnectorStatus) -> LocalizedStringResource {
        switch status {
        case .unconfigured: connectorUnconfigured
        case let .ready(models): connectorReadyMessage(models)
        case let .unreachable(failure): connectorFailureMessage(failure)
        case .authExpired: connectorAuthExpired
        case let .disabled(reason): connectorDisabledMessage(reason)
        }
    }

    /// `nil` and `[]` are different answers: "reachable, not enumerated" versus
    /// "the provider listed nothing". Both are ready; only one has a model to pick.
    static func connectorReadyMessage(_ models: [ModelInfo]?) -> LocalizedStringResource {
        guard let models else { return connectorReady }
        guard !models.isEmpty else { return connectorReadyNoModels }
        return connectorReadyModels(count: models.count)
    }

    static let connectorUnconfigured = LocalizedStringResource(
        "app.preferences.intelligence.provider.status.unconfigured",
        defaultValue: "Not set up yet — add a key or sign in to use this provider.",
        comment: "Provider status: no credential has been supplied yet"
    )
    static let connectorReady = LocalizedStringResource(
        "app.preferences.intelligence.provider.status.ready",
        defaultValue: "Ready.",
        comment: "Provider status: reachable, though this check did not list models"
    )
    static let connectorReadyNoModels = LocalizedStringResource(
        "app.preferences.intelligence.provider.status.ready.none",
        defaultValue: "Reachable, but no models are installed there yet.",
        comment: "Provider status: the provider answered with an empty model list"
    )
    static let connectorAuthExpired = LocalizedStringResource(
        "app.preferences.intelligence.provider.status.authExpired",
        defaultValue: "Sign in again — this provider rejected the saved credential.",
        comment: "Provider status: the credential was rejected or has expired"
    )
    static let connectorDisabled = LocalizedStringResource(
        "app.preferences.intelligence.provider.status.disabled",
        defaultValue: "This provider is unavailable.",
        comment: "Provider status: registered but deliberately not usable, reason unrecognised"
    )
    static let connectorDisabledUpstream = LocalizedStringResource(
        "app.preferences.intelligence.provider.status.disabled.upstream",
        defaultValue: "Unavailable — this provider changed its sign-in and it can no longer be driven.",
        comment: "Provider status for the upstream-flow-unavailable disabled token"
    )
    static let connectorDisabledNotLinked = LocalizedStringResource(
        "app.preferences.intelligence.provider.status.disabled.notLinked",
        defaultValue: "Not included in this build.",
        comment: "Provider status for the not-linked-in-this-build disabled token"
    )

    static func connectorReadyModels(count: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.preferences.intelligence.provider.status.ready.models",
            defaultValue: "Ready — \(count.formatted()) models available.",
            comment: "Provider status: reachable, with the number of models it listed"
        )
    }

    /// A ``ConnectorStatus/DisabledReason`` token turned into copy. The token is
    /// NEVER rendered: an unrecognised one degrades to ``connectorDisabled``.
    static func connectorDisabledMessage(_ reason: String) -> LocalizedStringResource {
        switch reason {
        case ConnectorStatus.DisabledReason.upstreamFlowUnavailable: connectorDisabledUpstream
        case ConnectorStatus.DisabledReason.notLinkedInThisBuild: connectorDisabledNotLinked
        default: connectorDisabled
        }
    }
}

// MARK: - Failure copy

extension PreferencesStrings {
    /// One failure turned into a sentence. EXHAUSTIVE — a tenth `ConnectorFailure`
    /// case is a compile error here, which is the whole point of that taxonomy
    /// shipping without a catch-all.
    static func connectorFailureMessage(_ failure: ConnectorFailure) -> LocalizedStringResource {
        switch failure {
        case .unconfigured: connectorUnconfigured
        case .authExpired: connectorAuthExpired
        case let .unreachable(underlying): connectorUnreachableMessage(underlying)
        case .timeout: connectorTimeout
        case let .httpStatus(code, _, _): connectorHTTPStatus(code: code)
        case .rateLimited: connectorRateLimited
        // A probe asks for a model LIST, which no ceiling can cut short, so
        // truncation is unreachable here and shares the malformed sentence
        // rather than earning a status string no listener can ever see.
        case .malformedResponse, .truncated: connectorMalformed
        case .cancelled: connectorCancelled
        }
    }

    static let connectorTimeout = LocalizedStringResource(
        "app.preferences.intelligence.provider.status.timeout",
        defaultValue: "This provider did not answer in time.",
        comment: "Provider status: a deadline elapsed before the provider replied"
    )
    static let connectorRateLimited = LocalizedStringResource(
        "app.preferences.intelligence.provider.status.rateLimited",
        defaultValue: "This provider is limiting requests right now. Try again shortly.",
        comment: "Provider status: the provider is throttling"
    )
    static let connectorMalformed = LocalizedStringResource(
        "app.preferences.intelligence.provider.status.malformed",
        defaultValue: "This provider’s answer could not be understood.",
        comment: "Provider status: the reply did not match the expected shape"
    )
    static let connectorCancelled = LocalizedStringResource(
        "app.preferences.intelligence.provider.status.cancelled",
        defaultValue: "The check was stopped before it finished.",
        comment: "Provider status: the probe was cancelled cooperatively"
    )
    static let connectorUnreachable = LocalizedStringResource(
        "app.preferences.intelligence.provider.status.unreachable",
        defaultValue: "This provider could not be reached.",
        comment: "Provider status: the endpoint was unreachable, reason unrecognised"
    )
    static let connectorConnectionRefused = LocalizedStringResource(
        "app.preferences.intelligence.provider.status.refused",
        defaultValue: "Nothing answered at that address — check the provider is running.",
        comment: "Provider status for the connection-refused diagnostic token"
    )
    static let connectorHostNotFound = LocalizedStringResource(
        "app.preferences.intelligence.provider.status.hostNotFound",
        defaultValue: "That address could not be found.",
        comment: "Provider status for the host-not-found diagnostic token"
    )
    static let connectorNetworkUnavailable = LocalizedStringResource(
        "app.preferences.intelligence.provider.status.offline",
        defaultValue: "No network connection is available.",
        comment: "Provider status for the network-unavailable diagnostic token"
    )
    static let connectorSecureConnectionFailed = LocalizedStringResource(
        "app.preferences.intelligence.provider.status.tls",
        defaultValue: "The secure connection to this provider failed.",
        comment: "Provider status for the secure-connection-failed diagnostic token"
    )

    static func connectorHTTPStatus(code: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.preferences.intelligence.provider.status.http",
            defaultValue: "This provider answered with an error (\(code.formatted(.number.grouping(.never)))).",
            comment: "Provider status: an unusable HTTP status, with the numeric code"
        )
    }

    /// A ``ConnectorFailure/DiagnosticToken`` turned into copy. Same rule as the
    /// disabled tokens: never rendered raw, unknown degrades to generic.
    static func connectorUnreachableMessage(_ token: String) -> LocalizedStringResource {
        switch token {
        case ConnectorFailure.DiagnosticToken.connectionRefused: connectorConnectionRefused
        case ConnectorFailure.DiagnosticToken.hostNotFound: connectorHostNotFound
        case ConnectorFailure.DiagnosticToken.networkUnavailable: connectorNetworkUnavailable
        case ConnectorFailure.DiagnosticToken.secureConnectionFailed: connectorSecureConnectionFailed
        default: connectorUnreachable
        }
    }
}
