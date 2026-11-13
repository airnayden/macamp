// FakeAssistantBackends — scripted conformers for the three assistant seams.
//
// No FoundationModels, no NaturalLanguage, no model assets: a consumer states what
// each backend returns and asserts on the requests it made. Every fake is a `struct`
// over a lock box rather than an `actor`, matching ``FakeSimilarityService`` — an
// actor's methods hop to its own executor, which would make "this ran off the main
// thread" true by construction and therefore worthless as an assertion.
//
// These compile on the macOS 14 / iOS 17 floor, which is the point: the seams they
// conform to are floor-available, so the fallback tiers can be exercised on hosts
// where the real model does not exist.
//
// Each fake takes an INJECTED `failure: (any Error)?` rather than a bool plus a
// private error case, so a later suite can arm the exact typed failure its own
// module defines — the FM backend's mapped error cases, for instance — without this
// file needing to know that type exists.
import Foundation
import os
import Services

/// Thrown by every fake in this file when a test arms a failure without supplying
/// one of its own.
public enum FakeAssistantError: Error, Sendable, Equatable {
    case forcedFailure
}

// MARK: - Query parsing

/// A scripted ``NaturalLanguageQueryParsing``.
public struct FakeAssistantQueryParser: NaturalLanguageQueryParsing {
    /// One recorded call.
    public struct Request: Sendable, Equatable {
        public var text: String
        public var locale: Locale

        public init(text: String, locale: Locale) {
            self.text = text
            self.locale = locale
        }
    }

    /// Everything the fake returns and observes, guarded as one unit.
    public struct Recording: Sendable {
        /// Returned by every successful ``parse(text:locale:)``.
        public var spec = PlaylistQuerySpec()
        /// Calls, in order.
        public var requests: [Request] = []
        /// When non-`nil`, every call throws it instead of returning ``spec``.
        public var failure: (any Error)?
    }

    private let state: OSAllocatedUnfairLock<Recording>

    public init(spec: PlaylistQuerySpec = PlaylistQuerySpec()) {
        var recording = Recording()
        recording.spec = spec
        state = OSAllocatedUnfairLock(initialState: recording)
    }

    /// A snapshot of everything recorded so far.
    public var recording: Recording {
        state.withLock { $0 }
    }

    public func setSpec(_ spec: PlaylistQuerySpec) {
        state.withLock { $0.spec = spec }
    }

    /// Arms a failure. Pass `nil` to disarm.
    public func setFailure(_ failure: (any Error)? = FakeAssistantError.forcedFailure) {
        state.withLock { $0.failure = failure }
    }

    public func parse(text: String, locale: Locale) async throws -> PlaylistQuerySpec {
        let request = Request(text: text, locale: locale)
        return try state.withLock { recording in
            recording.requests.append(request)
            if let failure = recording.failure { throw failure }
            return recording.spec
        }
    }
}

// MARK: - Naming

/// A scripted ``PlaylistNaming``.
public struct FakeAssistantNamer: PlaylistNaming {
    /// One recorded call.
    public struct Request: Sendable, Equatable {
        public var context: PlaylistNamingContext
        public var locale: Locale

        public init(context: PlaylistNamingContext, locale: Locale) {
            self.context = context
            self.locale = locale
        }
    }

    /// Everything the fake returns and observes, guarded as one unit.
    public struct Recording: Sendable {
        /// Returned by every successful ``suggestName(for:locale:)``.
        public var result = PlaylistNamingResult(name: "Fake Mix")
        /// Calls, in order.
        public var requests: [Request] = []
        /// When non-`nil`, every call throws it instead of returning ``result``.
        public var failure: (any Error)?
    }

    private let state: OSAllocatedUnfairLock<Recording>

    public init(result: PlaylistNamingResult = PlaylistNamingResult(name: "Fake Mix")) {
        var recording = Recording()
        recording.result = result
        state = OSAllocatedUnfairLock(initialState: recording)
    }

    /// A snapshot of everything recorded so far.
    public var recording: Recording {
        state.withLock { $0 }
    }

    public func setResult(_ result: PlaylistNamingResult) {
        state.withLock { $0.result = result }
    }

    /// Arms a failure. Pass `nil` to disarm.
    public func setFailure(_ failure: (any Error)? = FakeAssistantError.forcedFailure) {
        state.withLock { $0.failure = failure }
    }

    public func suggestName(
        for context: PlaylistNamingContext,
        locale: Locale
    ) async throws -> PlaylistNamingResult {
        let request = Request(context: context, locale: locale)
        return try state.withLock { recording in
            recording.requests.append(request)
            if let failure = recording.failure { throw failure }
            return recording.result
        }
    }
}

// MARK: - Narration

/// A scripted ``InsightNarrating``.
public struct FakeAssistantNarrator: InsightNarrating {
    /// One recorded call.
    public struct Request: Sendable, Equatable {
        public var context: InsightNarrationContext
        public var locale: Locale

        public init(context: InsightNarrationContext, locale: Locale) {
            self.context = context
            self.locale = locale
        }
    }

    /// Everything the fake returns and observes, guarded as one unit.
    public struct Recording: Sendable {
        /// Returned by every successful ``narrate(_:locale:)``.
        public var result = InsightNarrationResult(narrative: "Fake narrative.")
        /// Calls, in order.
        public var requests: [Request] = []
        /// When non-`nil`, every call throws it instead of returning ``result``.
        public var failure: (any Error)?
    }

    private let state: OSAllocatedUnfairLock<Recording>

    public init(result: InsightNarrationResult = InsightNarrationResult(narrative: "Fake narrative.")) {
        var recording = Recording()
        recording.result = result
        state = OSAllocatedUnfairLock(initialState: recording)
    }

    /// A snapshot of everything recorded so far.
    public var recording: Recording {
        state.withLock { $0 }
    }

    public func setResult(_ result: InsightNarrationResult) {
        state.withLock { $0.result = result }
    }

    /// Arms a failure. Pass `nil` to disarm.
    public func setFailure(_ failure: (any Error)? = FakeAssistantError.forcedFailure) {
        state.withLock { $0.failure = failure }
    }

    public func narrate(
        _ context: InsightNarrationContext,
        locale: Locale
    ) async throws -> InsightNarrationResult {
        let request = Request(context: context, locale: locale)
        return try state.withLock { recording in
            recording.requests.append(request)
            if let failure = recording.failure { throw failure }
            return recording.result
        }
    }
}
