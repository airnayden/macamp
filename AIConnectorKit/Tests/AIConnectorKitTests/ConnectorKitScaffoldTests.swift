import AIConnectorKit
import Foundation
import Testing

/// Scaffold coverage for the reusable connector core.
///
/// The real contract suites (transport deadlines, `withDeadline`, the
/// `ConnectorFailure` taxonomy, `JSONSchemaObject` encoding) land in the
/// following todos. This suite only proves the target builds, links and runs
/// under the test runner.
@Suite("ConnectorKitScaffoldTests")
struct ConnectorKitScaffoldTests {
    @Test("The Keychain service prefix is the reverse-DNS connector namespace")
    func keychainServicePrefixIsNamespaced() {
        #expect(ConnectorKitInfo.keychainServicePrefix == "com.macamp.aiconnectors")
    }
}
