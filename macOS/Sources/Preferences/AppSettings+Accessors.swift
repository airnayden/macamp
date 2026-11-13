// AppSettings+Accessors — the `AppSettings` declarations that own no stored state.
//
// Moved out of `AppSettings.swift` verbatim, for the same mechanical reason
// `AppSettingsTypes.swift` and `AppSettings+DesignTokens.swift` were: that file
// sits at `swiftlint --strict`'s `file_length` ceiling of 400, so a new stored
// property cannot be added without freeing space first.
//
// Only declarations that own NO instance storage may move. `@Observable`
// transforms the primary class declaration alone, so every stored property — and
// therefore the whole class body — has to stay where it is.
import Foundation

public extension AppSettings {
    // MARK: Connector model selection

    /// The model `connectorID` last had selected, or `nil` when never chosen.
    func selectedModel(for connectorID: String) -> String? {
        selectedConnectorModels[connectorID]
    }

    /// Records `model` as `connectorID`'s selection; `nil` clears just that entry.
    func setSelectedModel(_ model: String?, for connectorID: String) {
        selectedConnectorModels[connectorID] = model
    }

    // MARK: Shipped constants

    /// The shipped loopback port. Restated rather than read from `MCPLibraryServer`
    /// so settings keep no dependency on the server; a test asserts they agree.
    static let defaultExternalAccessPort = 46114

    static var preview: AppSettings {
        AppSettings(defaults: UserDefaults(suiteName: AppSettingsKeys.previewSuite) ?? .standard)
    }
}

// MARK: - Hostile-plist hydration

/// Lifted out of `init` for the file-length reason above, and kept together because
/// they answer one question: what a stored value that is the WRONG SHAPE reads back
/// as. A hand-edited plist or an older build must degrade, never trap — the claim
/// `AIConnectorSettingsTests.garbagePersistedValuesDegrade` makes. `static` because
/// `init` calls them before `self` is fully initialized.
extension AppSettings {
    /// Each connector's stored model choice, dropping only the entries that are not
    /// strings.
    ///
    /// `compactMapValues`, not an `as? [String: String]` cast: the cast is
    /// all-or-nothing, so one foreign value would discard EVERY model selection.
    static func storedModelSelections(in defaults: UserDefaults) -> [String: String] {
        (defaults.dictionary(forKey: AppSettingsKeys.connectorSelectedModels) ?? [:])
            .compactMapValues { $0 as? String }
    }

    /// The id set stored at `key`, or an empty set.
    ///
    /// `stringArray(forKey:)` yields `nil` for a non-array or mixed-type value, so a
    /// hand-edited plist degrades to "nothing consented" — the safe end.
    static func storedIDSet(in defaults: UserDefaults, forKey key: String) -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }

    /// The stored loopback port, or the shipped default.
    ///
    /// A stored 0 (or a hand-edited nonsense value) reads back as the default rather
    /// than as a port the listener could never bind.
    static func storedExternalAccessPort(in defaults: UserDefaults) -> Int {
        let stored = defaults.object(forKey: AppSettingsKeys.externalAccessPort) as? Int
        return stored.flatMap { (1 ... 65535).contains($0) ? $0 : nil } ?? defaultExternalAccessPort
    }
}
