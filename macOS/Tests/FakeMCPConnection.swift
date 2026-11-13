// FakeMCPConnection — one external MCP server's connection, answered from memory.
//
// A FILE of its own, and internal rather than `private`, for the mechanical reason
// `AppSettings+Accessors.swift` records about its own split: `LibraryChatMCPWiringTests.swift`
// sits at `swiftlint --strict`'s `file_length` ceiling of 400, so a new assertion
// cannot be added to that suite without freeing space first. Nothing about this
// fake changed in the move.
import AIConnectorKit
import AIConnectorMCP
import Foundation
@testable import MacAMP

/// One external server's connection, answered from memory.
///
/// An `actor` because ``MCPToolProviding`` is how ``MCPClientManager`` — itself an
/// actor — is reached, and because holding it is the retention contract the supply
/// exists to honour: a fake that the supply failed to retain would be deallocated
/// and its recorded counts would go with it.
actor FakeMCPConnection: MCPToolProviding {
    private(set) var listCount = 0
    private(set) var didDisconnect = false
    private let published: [AITool]

    init(publishing published: [AITool]) {
        self.published = published
    }

    func projectedTools() async throws -> [AITool] {
        listCount += 1
        return published
    }

    func disconnect() async {
        didDisconnect = true
    }
}
