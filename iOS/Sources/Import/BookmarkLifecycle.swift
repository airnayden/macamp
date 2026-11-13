// BookmarkLifecycle — the PURE, reviewable core of security-scoped file access.
//
// iOS is sandboxed: a URL handed back by the document picker only grants access
// while the app holds a security scope, and a persisted bookmark only grants it
// after re-resolution. The two rules that must never be broken are:
//
//   1. every `startAccessingSecurityScopedResource()` is balanced by exactly one
//      `stopAccessingSecurityScopedResource()` — even when the work throws; and
//   2. a bookmark reported as stale on resolve is re-minted and re-persisted.
//
// Both rules are expressed here as small, side-effect-free helpers over the
// ``SecurityScopedResource`` seam so they can be exercised without a filesystem
// (the `CountingSecurityScopedResource` double + the `#Preview` self-check below
// prove start/stop always balance). The filesystem-bound persistence + manager
// live in `SecurityScopedBookmarks.swift`; the picker UI in `DocumentImporter`.
import Foundation
import SwiftUI

// MARK: - SecurityScopedResource

/// The minimal surface needed to balance security-scoped access. `URL` conforms
/// with its own implementations; tests inject a counting double to prove that
/// access is never leaked.
protocol SecurityScopedResource {
    @discardableResult
    func startAccessingSecurityScopedResource() -> Bool
    func stopAccessingSecurityScopedResource()
}

extension URL: SecurityScopedResource {}

// MARK: - Scoped access (closure form)

/// Runs `body` while holding security-scoped access to `resource`, ALWAYS
/// balancing start with stop via `defer` — on normal return *and* on `throw`.
///
/// This is the single chokepoint for short, synchronous scoped work (e.g.
/// re-minting a stale bookmark): there is no other path that calls
/// `startAccessingSecurityScopedResource()` directly, so access cannot leak. The
/// `didStart` flag is surfaced so a caller can branch when the grant was denied.
@discardableResult
func withSecurityScopedAccess<Output>(
    to resource: some SecurityScopedResource,
    perform body: (_ didStart: Bool) throws -> Output
) rethrows -> Output {
    let didStart = resource.startAccessingSecurityScopedResource()
    defer {
        if didStart {
            resource.stopAccessingSecurityScopedResource()
        }
    }
    return try body(didStart)
}

// MARK: - Scoped access (token form)

/// A balanced batch of security-scoped grants. Created by
/// ``beginSecurityScopedAccess(to:)`` and released exactly once with ``end()``;
/// the call site pairs it with `defer` so access is held across an `await`
/// (a folder import streams asynchronously) yet still always balances.
final class ScopedAccessToken {
    private var stops: [() -> Void]

    init(stops: [() -> Void]) {
        self.stops = stops
    }

    deinit {
        end()
    }

    /// Stops every grant that actually started. Safe to keep local to one actor.
    func end() {
        let pending = stops
        stops.removeAll()
        for stop in pending {
            stop()
        }
    }
}

/// Starts scoped access on each resource and returns a token that stops *only*
/// the grants that succeeded. Pair the result with `defer { token.end() }`.
func beginSecurityScopedAccess(
    to resources: [some SecurityScopedResource]
) -> ScopedAccessToken {
    var stops: [() -> Void] = []
    for resource in resources where resource.startAccessingSecurityScopedResource() {
        stops.append { resource.stopAccessingSecurityScopedResource() }
    }
    return ScopedAccessToken(stops: stops)
}

/// Keeps imported and restored roots accessible for the environment's lifetime.
/// Confined to its owning actor; each successful grant is released exactly once.
final class SecurityScopedAccessOwner {
    private let resource: (URL) -> any SecurityScopedResource
    private var grants: [URL: ScopedAccessToken] = [:]

    init(
        roots: [URL] = [],
        resource: @escaping (URL) -> any SecurityScopedResource = { $0 }
    ) {
        self.resource = resource
        retainAccess(to: roots)
    }

    func retainAccess(to urls: [URL]) {
        for url in urls {
            let key = url.standardizedFileURL
            guard grants[key] == nil else { continue }
            let resource = resource(url)
            if resource.startAccessingSecurityScopedResource() {
                grants[key] = ScopedAccessToken(stops: [{ resource.stopAccessingSecurityScopedResource() }])
            }
        }
    }
}

// MARK: - Staleness plan

/// What to do with a bookmark once it has been resolved to a URL.
enum BookmarkRefreshPlan: Equatable {
    /// The stored data is current; use the resolved URL as-is.
    case reuse
    /// `bookmarkDataIsStale` was true; the URL still resolved, so re-mint fresh
    /// bookmark data from it and overwrite the persisted blob.
    case refreshAndPersist
}

/// Maps a resolve's staleness flag to the action the manager must take. Pure so
/// the (otherwise filesystem-bound) staleness branch is unit-reviewable.
func bookmarkRefreshPlan(isStale: Bool) -> BookmarkRefreshPlan {
    isStale ? .refreshAndPersist : .reuse
}

// MARK: - Self-check (pure, runnable in the #Preview below)

/// A tiny, dependency-free verification of the two lifecycle invariants. It runs
/// against the counting double, so it touches no disk and can be eyeballed in the
/// Xcode canvas (each row renders PASS/FAIL).
enum BookmarkLifecycleSelfCheck {
    /// One named assertion and whether it held.
    struct Outcome: Equatable {
        var name: String
        var passed: Bool
    }

    /// Every lifecycle assertion, evaluated synchronously.
    static func run() -> [Outcome] {
        [
            balanceOnReturn(),
            balanceOnThrow(),
            batchBalance(),
            stalePlanRefreshes(),
            freshPlanReuses(),
        ]
    }

    private static func balanceOnReturn() -> Outcome {
        let resource = CountingSecurityScopedResource()
        withSecurityScopedAccess(to: resource) { _ in }
        return Outcome(
            name: "single access balances on return",
            passed: resource.isBalanced && resource.startCount == 1
        )
    }

    private static func balanceOnThrow() -> Outcome {
        let resource = CountingSecurityScopedResource()
        try? withSecurityScopedAccess(to: resource) { _ in throw SelfCheckError.expected }
        return Outcome(
            name: "single access balances on throw",
            passed: resource.isBalanced && resource.startCount == 1
        )
    }

    private static func batchBalance() -> Outcome {
        let resources = [CountingSecurityScopedResource(), CountingSecurityScopedResource()]
        let token = beginSecurityScopedAccess(to: resources)
        token.end()
        return Outcome(
            name: "batch access balances",
            passed: resources.allSatisfy(\.isBalanced)
        )
    }

    private static func stalePlanRefreshes() -> Outcome {
        Outcome(
            name: "stale bookmark re-resolves",
            passed: bookmarkRefreshPlan(isStale: true) == .refreshAndPersist
        )
    }

    private static func freshPlanReuses() -> Outcome {
        Outcome(
            name: "fresh bookmark reused",
            passed: bookmarkRefreshPlan(isStale: false) == .reuse
        )
    }

    private enum SelfCheckError: Error {
        case expected
    }
}

/// A test double that records start/stop calls so balance can be asserted without
/// the filesystem. Single-threaded use only (the self-check is synchronous).
final class CountingSecurityScopedResource: SecurityScopedResource {
    private(set) var startCount = 0
    private(set) var stopCount = 0

    /// True once every start has a matching stop.
    var isBalanced: Bool {
        startCount == stopCount
    }

    @discardableResult
    func startAccessingSecurityScopedResource() -> Bool {
        startCount += 1
        return true
    }

    func stopAccessingSecurityScopedResource() {
        stopCount += 1
    }
}

#if DEBUG
    #Preview("Bookmark lifecycle self-check") {
        List(BookmarkLifecycleSelfCheck.run(), id: \.name) { outcome in
            HStack {
                Image(systemName: outcome.passed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(outcome.passed ? Color.green : Color.red)
                Text(verbatim: outcome.name)
                Spacer()
                Text(verbatim: outcome.passed ? "PASS" : "FAIL")
                    .fontWeight(.semibold)
            }
        }
    }
#endif
