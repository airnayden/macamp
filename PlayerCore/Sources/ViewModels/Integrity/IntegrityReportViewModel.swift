//
//  IntegrityReportViewModel.swift
//  MacAMP PlayerCore — ViewModels
//
//  The @Observable projection behind the "Verify Files…" report.
//
//  NOTHING HERE STARTS ON ITS OWN. `init` resolves the targets and touches no
//  file; a pass runs only from ``run()``, which is reachable from one explicit
//  library context-menu action. A scan, an import, or a download must never reach
//  this type — verification decodes every selected file end to end.
//
//  IT NEVER BLOCKS THE MAIN ACTOR. Both seams are `async` and both already move
//  their work to `Task.detached(priority: .utility)` internally, so the awaits
//  below leave the main actor free to draw the progress the pass is reporting.
//
//  The mapping from service results onto row states is `static` and pure, so the
//  four FLAC states (and the difference between a returned result and a thrown
//  error) are assertable without a decoder.
//
//  PlayerCore portability: DSP + Foundation + Observation + Services.
//

import DSP
import Foundation
import Observation
import Services

/// Observable state for one run of the file-integrity report.
@MainActor
@Observable
public final class IntegrityReportViewModel {
    /// Completed rows, in the order the listener selected them.
    ///
    /// Appended as each file finishes, so the report fills in live rather than
    /// appearing all at once at the end.
    public private(set) var rows: [IntegrityReportRow] = []

    /// `true` between ``run()`` starting and the pass finishing or stopping.
    public private(set) var isRunning = false

    /// Files verified so far in this run.
    public private(set) var completedCount = 0

    /// Title of the file being verified, if any.
    public private(set) var currentTitle: String?

    /// Files this run will verify. Fixed at construction.
    public let totalCount: Int

    @ObservationIgnored private let targets: [IntegrityCheckTarget]
    @ObservationIgnored private let verifier: any FLACIntegrityVerifying
    @ObservationIgnored private let spectral: any SpectralIntegrityChecking
    @ObservationIgnored private var isStopRequested = false

    /// - Parameters:
    ///   - targets: The files to verify, in display order.
    ///   - verifier: The FLAC stream-MD5 seam.
    ///   - spectral: The band-limiting heuristic seam.
    public init(
        targets: [IntegrityCheckTarget],
        verifier: any FLACIntegrityVerifying,
        spectral: any SpectralIntegrityChecking
    ) {
        self.targets = targets
        self.verifier = verifier
        self.spectral = spectral
        totalCount = targets.count
    }
}

// MARK: - Derived state

public extension IntegrityReportViewModel {
    /// Verified over total, in `0...1`. `1` for an empty selection, which has
    /// nothing left to do.
    var progressFraction: Double {
        guard totalCount > 0 else { return 1 }
        return min(1, max(0, Double(completedCount) / Double(totalCount)))
    }

    /// `true` once the pass has stopped and every target produced a row.
    var isComplete: Bool {
        !isRunning && completedCount == totalCount
    }

    /// Rows worth a listener's attention — a checksum mismatch, a band-limited
    /// spectrum, or a check that could not complete.
    var concernCount: Int {
        rows.filter(\.needsAttention).count
    }
}

// MARK: - Control surface

public extension IntegrityReportViewModel {
    /// Verifies every target in order, publishing each row as it lands.
    ///
    /// Re-entrant calls are refused rather than queued: a second pass over the
    /// same selection would only repeat the decode. Cancelling the calling task
    /// (which is what dismissing the sheet does) stops the loop at the next file
    /// boundary and keeps every row already produced.
    func run() async {
        guard !isRunning else { return }
        isRunning = true
        isStopRequested = false
        rows = []
        completedCount = 0

        for target in targets {
            if isStopRequested || Task.isCancelled { break }
            currentTitle = target.title
            let row = await Self.verify(target, verifier: verifier, spectral: spectral)
            rows.append(row)
            completedCount += 1
        }

        currentTitle = nil
        isRunning = false
    }

    /// Stops the pass at the next file boundary, keeping the rows already
    /// produced.
    func cancel() {
        isStopRequested = true
    }
}

// MARK: - Verification (one file)

extension IntegrityReportViewModel {
    /// Both readings for one file.
    ///
    /// A throw from either seam becomes a row STATE, never an escape: one
    /// unreadable file must not abort the report for the files after it.
    static func verify(
        _ target: IntegrityCheckTarget,
        verifier: any FLACIntegrityVerifying,
        spectral: any SpectralIntegrityChecking
    ) async -> IntegrityReportRow {
        guard target.availability == .present else {
            return IntegrityReportRow(target: target, checksum: .notAttempted, spectral: .notAttempted)
        }
        let url = target.url
        // The checksum pass runs for EVERY file, not only those named `.flac`:
        // a container's extension is not evidence of its stream, and the seam
        // answers "this carries no FLAC checksum" as `notFLAC` — which is exactly
        // the `.notApplicable` row state. Trusting the extension instead would
        // mis-report a mis-named file both ways.
        let checksum = await checksumOutcome(for: url, verifier: verifier)
        let reading = await spectralOutcome(for: url, checker: spectral)
        return IntegrityReportRow(target: target, checksum: checksum, spectral: reading)
    }

    static func checksumOutcome(
        for url: URL,
        verifier: any FLACIntegrityVerifying
    ) async -> IntegrityChecksumOutcome {
        do {
            let result = try await verifier.verifyFLAC(url: url)
            return outcome(for: result)
        } catch let error as FLACIntegrityError {
            return outcome(for: error)
        } catch is CancellationError {
            return .notAttempted
        } catch {
            return .failed(.unexpected)
        }
    }

    static func spectralOutcome(
        for url: URL,
        checker: any SpectralIntegrityChecking
    ) async -> IntegritySpectralOutcome {
        do {
            let verdict = try await checker.inspect(url)
            return outcome(for: verdict)
        } catch is CancellationError {
            return .notAttempted
        } catch {
            return .failed
        }
    }
}

// MARK: - Result mapping (pure)

public extension IntegrityReportViewModel {
    /// A reached verdict. Three cases in, three of the row's six states out —
    /// the other three describe conditions no ``FLACIntegrityResult`` can carry.
    static func outcome(for result: FLACIntegrityResult) -> IntegrityChecksumOutcome {
        switch result {
        case .match: .match
        case .mismatch: .mismatch
        case .noStoredMD5: .noStoredMD5
        }
    }

    /// A refusal to reach a verdict.
    ///
    /// ``FLACIntegrityError/notFLAC`` is the ONE case that is not a failure: it
    /// means the stream carries no FLAC checksum, which is the ordinary state of
    /// every MP3, AAC and WAV in a library.
    static func outcome(for error: FLACIntegrityError) -> IntegrityChecksumOutcome {
        switch error {
        case .notFLAC: .notApplicable
        case .unsupportedLayout: .failed(.unsupportedLayout)
        case .decodeFailed: .failed(.decodeFailed)
        case .unreadable: .failed(.unreadable)
        }
    }

    static func outcome(for verdict: FakeLosslessVerdict) -> IntegritySpectralOutcome {
        switch verdict {
        case let .consistent(cutoffHz): .consistent(cutoffHz: cutoffHz)
        case let .suspectTranscode(cutoffHz): .suspectTranscode(cutoffHz: cutoffHz)
        case let .indeterminate(reason): .indeterminate(reason)
        }
    }
}
