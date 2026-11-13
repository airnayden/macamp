import Testing

/// Scaffold only: keeps the InsightTests target discoverable by `swift test
/// --filter` until the listening-insight suites land. Delete on first real test.
@Suite("InsightPlaceholderTests")
struct InsightPlaceholderTests {
    @Test("InsightTests target is wired and runnable")
    func targetIsWired() {
        #expect(Bool(true))
    }
}
