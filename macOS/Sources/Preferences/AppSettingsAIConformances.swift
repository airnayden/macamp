// AppSettingsAIConformances — the two AI settings protocols `AppSettings` witnesses.
//
// A sibling file, not more lines in `AppSettings.swift`: that file sits at
// `swiftlint --strict`'s 400-line ceiling, and an extension is the one thing that
// can leave. Every call site is unchanged — a conformance has no spelling.
//
// Do NOT merge these back. The next stored property added to `AppSettings` needs
// the room.
import AIConnectorBridge
import Services

// MARK: - AISettingsProviding

/// `AppSettings`' stored feature switches already satisfy every requirement, and
/// the protocol is `@MainActor` exactly so this type can witness them.
extension AppSettings: AISettingsProviding {}

// MARK: - AIConnectorSettingsProviding

/// A SECOND protocol rather than three more members on `AISettingsProviding`:
/// PlayerCore reads the feature gates and must stay ignorant of connectors, and the
/// iOS shell has no connector surface at all so it conforms only to the first.
extension AppSettings: AIConnectorSettingsProviding {}
