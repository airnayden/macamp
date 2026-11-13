// AssistantView+ProviderLabel — the caption naming whatever will actually answer.
//
// A sibling extension rather than more of `AssistantView.swift`, which sits against
// SwiftLint's 400-line `file_length` ceiling. Same reason as `AssistantView+Chat.swift`.
//
// ── THE CAPTION FOLLOWS THE ROUTE, NOT THE ON-DEVICE PROBE ────────────────────
//
// It used to read `appleIntelligence.isAvailable` and say "Enhanced by Apple
// Intelligence" whenever the on-device model was reachable — so a Mac answering
// through Claude Subscription still credited Apple Intelligence, and a Mac with no
// on-device model showed nothing at all while a cloud provider answered every turn.
// Both are the same bug: the probe is not the tier. ``chatAvailability`` already
// resolves which one is, so the caption is derived from THAT and can no longer
// disagree with the tier that answers.
//
// ── A NON-READY ROUTE STILL SHOWS NOTHING ────────────────────────────────────
//
// `AssistantView.swift`'s header invariant: FM-dependent affordances are HIDDEN,
// never error-badged. `providerCaption` returns `nil` for every non-`.ready` state,
// which is the whole of that rule — the request field stays live because the
// heuristic tier still answers, and a caption claiming a broken feature would be a
// lie about one that works. `LibraryChatNoticeView` is the surface that explains a
// non-ready state, and only once a conversation has actually been asked for.
import DesignSystem
import Foundation
import SwiftUI

extension AssistantView {
    @ViewBuilder
    var providerLabel: some View {
        if let caption = Self.providerCaption(
            route: chatAvailability.route,
            models: settings.selectedConnectorModels
        ) {
            Text(caption)
                .font(tokens.typography.caption.font)
                .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
        }
    }

    /// `nonisolated` so the matrix is assertable without an `AppEnvironment`: a
    /// `View` is `@MainActor` by inference, which would otherwise drag a live
    /// composition root into a test of three pure cases.
    ///
    /// `models` is the fallback, never the authority. ``LibraryChatRoute/connector``
    /// carries the model it was BUILT with precisely so the route a surface shows and
    /// the route it starts are provably the same value (see its own doc comment);
    /// re-reading the settings dictionary first would reintroduce the drift that
    /// design exists to prevent. It is consulted only when the route carried none.
    nonisolated static func providerCaption(
        route: LibraryChatRoute?,
        models: [String: String]
    ) -> LocalizedStringResource? {
        switch route {
        case .appleIntelligence:
            AssistantPaneStrings.appleIntelligence
        case let .connector(id, displayName, model):
            connectorCaption(displayName: displayName, model: model.isEmpty ? models[id] : model)
        case nil:
            nil
        }
    }

    private nonisolated static func connectorCaption(
        displayName: String,
        model: String?
    ) -> LocalizedStringResource {
        guard let model, !model.isEmpty else {
            return AssistantPaneStrings.poweredBy(provider: displayName)
        }
        return AssistantPaneStrings.poweredBy(provider: displayName, model: model)
    }
}
