//
//  IntegrityReportTestSupport.swift
//  MacAMP PlayerCore — ViewModelTests
//
//  Test doubles for the two integrity seams.
//
//  These live HERE rather than in `PlayerCoreTestSupport` on purpose: todo 27
//  shipped no `SpectralIntegrityChecking` fake, and nothing outside this suite has
//  asked for one yet. A shared fake is a public contract other targets then depend
//  on, so it is worth adding only once a second consumer exists — until then a
//  file-local stub keeps the surface honest and the shared module unchanged.
//

import DSP
import Foundation
import Persistence
import Services
import ViewModels

// MARK: - Call recording

/// Records which files a stub was actually asked about.
///
/// An `actor` because both stubs are `Sendable` and are called from the detached
/// context the real services use.
actor IntegrityCallRecorder {
    private(set) var paths: [String] = []

    func record(_ path: String) {
        paths.append(path)
    }
}

/// A throw that is NOT a ``FLACIntegrityError`` — drives the `unexpected` row.
struct IntegrityStubError: Error {}

// MARK: - FLAC verifier stub

/// A ``FLACIntegrityVerifying`` whose answer per path is fixed up front.
///
/// An unlisted path throws ``FLACIntegrityError/notFLAC``, which is exactly what
/// the real service does for every stream that publishes no FLAC checksum — so a
/// test that does not mention a file gets the ordinary non-FLAC behaviour for free.
struct StubFLACVerifier: FLACIntegrityVerifying {
    var outcomes: [String: Result<FLACIntegrityResult, FLACIntegrityError>] = [:]
    var unexpectedThrows: Set<String> = []
    var recorder: IntegrityCallRecorder?

    func verifyFLAC(url: URL) async throws -> FLACIntegrityResult {
        await recorder?.record(url.path)
        if unexpectedThrows.contains(url.path) { throw IntegrityStubError() }
        guard let outcome = outcomes[url.path] else { throw FLACIntegrityError.notFLAC(url: url) }
        return try outcome.get()
    }
}

// MARK: - Spectral checker stub

/// A ``SpectralIntegrityChecking`` whose verdict per path is fixed up front.
///
/// `onInspect` runs before the verdict is returned, which is how a test drives
/// ``IntegrityReportViewModel/cancel()`` from inside the loop deterministically
/// instead of racing a timer against it.
struct StubSpectralChecker: SpectralIntegrityChecking {
    var verdicts: [String: FakeLosslessVerdict] = [:]
    var failing: Set<String> = []
    var recorder: IntegrityCallRecorder?
    var onInspect: (@Sendable (URL) async -> Void)?

    func inspect(_ url: URL) async throws -> FakeLosslessVerdict {
        await recorder?.record(url.path)
        await onInspect?(url)
        if failing.contains(url.path) { throw SpectralIntegrityError.analysisSetupFailed(url: url) }
        return verdicts[url.path] ?? .consistent(cutoffHz: 22050)
    }
}

// MARK: - Cancellation hook

/// Lets a stub reach back into the model under test from a nonisolated context.
@MainActor
final class IntegrityCancelHook {
    var model: IntegrityReportViewModel?

    func cancelNow() {
        model?.cancel()
    }
}

// MARK: - Target helpers

enum IntegrityFixture {
    static func target(
        id: Int64,
        path: String,
        availability: Availability = .present
    ) -> IntegrityCheckTarget {
        IntegrityCheckTarget(
            id: id,
            title: "Track \(id)",
            filePath: path,
            availability: availability
        )
    }

    /// A `mismatch` whose two digests differ, as the real service reports it.
    static let mismatch = FLACIntegrityResult.mismatch(
        stored: Data(repeating: 0xAA, count: 16),
        computed: Data(repeating: 0xBB, count: 16)
    )

    /// A `noStoredMD5` carrying the digest the full decode still produced.
    static let noStoredMD5 = FLACIntegrityResult.noStoredMD5(
        computed: Data(repeating: 0xCC, count: 16)
    )
}
