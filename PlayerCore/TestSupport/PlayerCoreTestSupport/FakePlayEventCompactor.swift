import Foundation
import Services

/// A recording ``PlayEventCompacting`` for wiring tests.
///
/// Compacts nothing: it counts the calls, so a composition-level test can prove that
/// the shells' launch trigger really reaches a compactor rather than being wired to
/// a dead seam. An `actor` (not a lock-guarded class) because the protocol's only
/// requirement is already `async`, so isolation costs the conformance nothing.
public actor FakePlayEventCompactor: PlayEventCompacting {
    /// How many times ``compact()`` was entered.
    public private(set) var compactCallCount = 0
    /// What ``compact()`` returns when it does not throw.
    public var result: PlayEventCompactionResult
    /// When non-nil, ``compact()`` throws it — after counting the call.
    public private(set) var failure: (any Error)?

    public init(result: PlayEventCompactionResult = PlayEventCompactionResult()) {
        self.result = result
    }

    public func setResult(_ result: PlayEventCompactionResult) {
        self.result = result
    }

    public func setFailure(_ failure: (any Error)?) {
        self.failure = failure
    }

    @discardableResult
    public func compact() async throws -> PlayEventCompactionResult {
        compactCallCount += 1
        if let failure { throw failure }
        return result
    }
}
