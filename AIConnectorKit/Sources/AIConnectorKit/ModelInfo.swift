// ModelInfo — one model a connector reported from its live model list.
//
// Deliberately thin. A provider's `/models` payload carries pricing, context
// windows, deprecation dates and training cut-offs; none of that drives a
// selector, and mirroring it would couple the kit to three unstable schemas.
import Foundation

/// What a model can be asked to do.
///
/// A capability is asserted only when the connector KNOWS it — most providers do
/// not advertise structured-output support per model, so an empty set means
/// "unstated", never "incapable". Callers must therefore treat the set as a hint
/// for ordering and filtering, not as a precondition.
public enum ModelCapability: String, Sendable, Codable, Hashable, CaseIterable {
    /// Multi-turn text completion — the floor every listed model meets.
    case chat
    /// Provider-enforced JSON output constrained by a schema.
    case structuredOutput
    /// Tool / function calling, which Anthropic's structured path rides on.
    case toolUse
    /// Image inputs. Unused today; listed so a provider's flag has somewhere to go.
    case vision
}

/// One model offered by a connector.
public struct ModelInfo: Sendable, Equatable, Hashable, Identifiable, Codable {
    /// The identifier sent back to the provider — `llama3.2:latest`, `gpt-4o`,
    /// `claude-sonnet-4-20250514`. This is the value persisted in settings.
    public var id: String

    /// What the selector shows. Falls back to ``id`` when the provider offers no
    /// friendlier name, which is the common case.
    ///
    /// NOT localized: these are provider-assigned identifiers and brand names, in
    /// the same class as the MacAMP brand itself. Shells render them
    /// `Text(verbatim:)`.
    public var displayName: String

    /// What the connector knows this model can do. Empty means "unstated".
    public var capabilities: Set<ModelCapability>

    public init(id: String, displayName: String? = nil, capabilities: Set<ModelCapability> = []) {
        self.id = id
        let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            self.displayName = trimmed
        } else {
            self.displayName = id
        }
        self.capabilities = capabilities
    }
}
