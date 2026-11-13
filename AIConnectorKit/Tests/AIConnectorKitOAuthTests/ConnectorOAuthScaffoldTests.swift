import AIConnectorKit
import AIConnectorKitOAuth
import Foundation
import Testing

/// Scaffold coverage for the link-gated subscription-credential target.
///
/// The PKCE engines and their hermetic fixture suites land in the following
/// todos. This suite proves the target builds and that it shares the core's
/// Keychain namespace rather than inventing a second one.
@Suite("ConnectorOAuthScaffoldTests")
struct ConnectorOAuthScaffoldTests {
    @Test("Subscription credentials sit under the shared connector namespace")
    func keychainServiceExtendsTheCoreNamespace() {
        #expect(ConnectorOAuthInfo.keychainService.hasPrefix(ConnectorKitInfo.keychainServicePrefix))
        #expect(ConnectorOAuthInfo.keychainService != ConnectorKitInfo.keychainServicePrefix)
    }
}
