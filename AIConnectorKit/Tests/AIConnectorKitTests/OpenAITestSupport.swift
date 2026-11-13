// OpenAITestSupport — committed-fixture plumbing for the OpenAI suites.
//
// Fixtures are read from the SOURCE TREE via `#filePath`, the repo's established
// pattern (`PlayerCore/Tests/LyricsTests/LyricsTestSupport.swift`,
// `PersistenceTests/MigrationTests.swift`). Nothing goes through `Bundle.module`,
// so the package manifest needs no resource declaration for them.
//
// Every symbol here is `openAI`-prefixed on purpose: the sibling connector suites
// land in this same test target, and an unprefixed `fixtureURL` would collide.
import AIConnectorKit
import Foundation

/// A path under `AIConnectorKitTests/Fixtures/`.
func openAIFixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)
        .appendingPathComponent(name)
}

func openAIFixtureData(_ name: String) throws -> Data {
    try Data(contentsOf: openAIFixtureURL(name))
}

/// A scripted transport answer carrying a committed fixture body.
func openAIFixtureResponse(
    _ name: String,
    statusCode: Int = 200,
    headers: [String: String] = [:]
) throws -> HTTPResponse {
    let body = try openAIFixtureData(name)
    return HTTPResponse(statusCode: statusCode, headers: headers, body: body)
}

/// Collects refusal text handed to the connector's synchronous `@Sendable` sink.
///
/// A lock-guarded class rather than an `actor`: the sink is NOT async, so an actor
/// would force a detached `Task` and make the assertion race the test.
final class OpenAIRefusalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func record(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(message)
    }

    var messages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// The JSON body a `FakeHTTPTransport` recorded, parsed for structural assertions.
func openAIRecordedJSONBody(_ request: URLRequest) throws -> [String: Any] {
    guard let body = request.httpBody,
          let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
    else {
        struct MissingBody: Error {}
        throw MissingBody()
    }
    return object
}
