import AIConnectorBridge
import Foundation
import Services
import Testing

/// Scaffold coverage for the PlayerCore-facing bridge target.
///
/// The canonical schema and prompt-budget suites land in the following todos.
/// This suite proves the cross-package edge actually links: the bridge's seam
/// alias and PlayerCore's own protocol have to be the same type.
@Suite("ConnectorBridgeScaffoldTests")
struct ConnectorBridgeScaffoldTests {
    @Test("The bridge seam alias resolves to PlayerCore's parsing protocol")
    func seamAliasMatchesPlayerCoreProtocol() {
        #expect(ConnectorBridgeInfo.QueryParsingSeam.self == (any NaturalLanguageQueryParsing).self)
    }
}
