//
//  IntegrityReportViewModelTests.swift
//  MacAMP PlayerCore — ViewModelTests
//
//  The report's contract: every selected file produces exactly one row, a thrown
//  check is a row STATE rather than an escape, and the four FLAC outcomes stay
//  four — a returned `FLACIntegrityResult` and a thrown `FLACIntegrityError` are
//  different answers and must never collapse into each other.
//

import DSP
import Foundation
import Persistence
import Services
import Testing
import ViewModels

@MainActor
@Suite("Integrity report view model")
struct IntegrityReportViewModelTests {
    // MARK: - The four FLAC states

    @Test("A FLAC selection renders all four checksum states, in selection order")
    func fourChecksumStates() async {
        let paths = ["/m/ok.flac", "/m/bad.flac", "/m/nomd5.flac", "/m/broken.flac"]
        let verifier = StubFLACVerifier(outcomes: [
            paths[0]: .success(.match),
            paths[1]: .success(IntegrityFixture.mismatch),
            paths[2]: .success(IntegrityFixture.noStoredMD5),
            paths[3]: .failure(.decodeFailed(url: URL(fileURLWithPath: paths[3]), reason: "truncated")),
        ])
        let model = IntegrityReportViewModel(
            targets: paths.enumerated().map { IntegrityFixture.target(id: Int64($0.offset + 1), path: $0.element) },
            verifier: verifier,
            spectral: StubSpectralChecker()
        )

        await model.run()

        #expect(model.rows.map(\.filePath) == paths)
        #expect(model.rows.map(\.checksum) == [
            .match,
            .mismatch,
            .noStoredMD5,
            .failed(.decodeFailed),
        ])
    }

    @Test("Every FLACIntegrityError maps to its own row state, and notFLAC is not a failure")
    func errorMapping() {
        let url = URL(fileURLWithPath: "/m/x.flac")
        let mapped = [
            FLACIntegrityError.notFLAC(url: url),
            .unsupportedLayout(url: url),
            .decodeFailed(url: url, reason: "boom"),
            .unreadable(url: url, reason: "gone"),
        ].map(IntegrityReportViewModel.outcome(for:))

        #expect(mapped == [
            .notApplicable,
            .failed(.unsupportedLayout),
            .failed(.decodeFailed),
            .failed(.unreadable),
        ])
        #expect(mapped[0].isConcerning == false)
    }

    @Test("A throw that is not a FLACIntegrityError lands as an unexpected failure")
    func unexpectedThrowIsAFailure() async {
        let path = "/m/weird.flac"
        let model = IntegrityReportViewModel(
            targets: [IntegrityFixture.target(id: 1, path: path)],
            verifier: StubFLACVerifier(unexpectedThrows: [path]),
            spectral: StubSpectralChecker()
        )

        await model.run()

        #expect(model.rows.first?.checksum == .failed(.unexpected))
    }

    // MARK: - Non-FLAC files

    @Test("A stream with no FLAC checksum reports no checksum and still reports its spectrum")
    func nonFLACIsSpectralOnly() async {
        let path = "/m/song.mp3"
        let model = IntegrityReportViewModel(
            targets: [IntegrityFixture.target(id: 1, path: path)],
            // No entry for the path, so the stub throws `notFLAC` exactly as the
            // real verifier does for a non-FLAC stream.
            verifier: StubFLACVerifier(),
            spectral: StubSpectralChecker(verdicts: [path: .suspectTranscode(cutoffHz: 16000)])
        )

        await model.run()

        let row = model.rows.first
        #expect(row?.checksum == .notApplicable)
        #expect(row?.spectral == .suspectTranscode(cutoffHz: 16000))
        #expect(row?.needsAttention == true)
    }

    // MARK: - Failure paths never abort the batch

    @Test("A failing checksum in the middle still leaves a row for every later file")
    func checksumFailureDoesNotAbortTheBatch() async {
        let paths = ["/m/1.flac", "/m/2.flac", "/m/3.flac"]
        let recorder = IntegrityCallRecorder()
        let verifier = StubFLACVerifier(
            outcomes: [
                paths[0]: .success(.match),
                paths[1]: .failure(.unreadable(url: URL(fileURLWithPath: paths[1]), reason: "EPERM")),
                paths[2]: .success(.match),
            ],
            recorder: recorder
        )
        let model = IntegrityReportViewModel(
            targets: paths.enumerated().map { IntegrityFixture.target(id: Int64($0.offset + 1), path: $0.element) },
            verifier: verifier,
            spectral: StubSpectralChecker()
        )

        await model.run()

        #expect(model.rows.count == 3)
        #expect(model.rows.map(\.checksum) == [.match, .failed(.unreadable), .match])
        #expect(await recorder.paths == paths)
        #expect(model.isComplete)
    }

    @Test("A failing spectral inspection is a reading, not an escape")
    func spectralFailureIsARow() async {
        let paths = ["/m/1.flac", "/m/2.flac"]
        let model = IntegrityReportViewModel(
            targets: paths.enumerated().map { IntegrityFixture.target(id: Int64($0.offset + 1), path: $0.element) },
            verifier: StubFLACVerifier(outcomes: [
                paths[0]: .success(.match),
                paths[1]: .success(.match),
            ]),
            spectral: StubSpectralChecker(
                verdicts: [paths[0]: .consistent(cutoffHz: 21000)],
                failing: [paths[1]]
            )
        )

        await model.run()

        #expect(model.rows.map(\.spectral) == [.consistent(cutoffHz: 21000), .failed])
        // The checksum on the failed row is untouched: one seam failing says
        // nothing about the other.
        #expect(model.rows.map(\.checksum) == [.match, .match])
    }

    // MARK: - Availability

    @Test("An unavailable file produces a row and is never decoded")
    func unavailableFileIsNotAttempted() async {
        let paths = ["/m/gone.flac", "/m/here.flac"]
        let recorder = IntegrityCallRecorder()
        let model = IntegrityReportViewModel(
            targets: [
                IntegrityFixture.target(id: 1, path: paths[0], availability: .missing),
                IntegrityFixture.target(id: 2, path: paths[1]),
            ],
            verifier: StubFLACVerifier(outcomes: [paths[1]: .success(.match)], recorder: recorder),
            spectral: StubSpectralChecker(recorder: recorder)
        )

        await model.run()

        #expect(model.rows.count == 2)
        #expect(model.rows[0].checksum == .notAttempted)
        #expect(model.rows[0].spectral == .notAttempted)
        #expect(model.rows[0].availability == .missing)
        #expect(model.rows[0].needsAttention == false)
        // Neither seam was asked about the file that is not on disk.
        #expect(await recorder.paths.allSatisfy { $0 == paths[1] })
    }

    @Test("An offline external file is treated the same as a missing one")
    func offlineFileIsNotAttempted() async {
        let model = IntegrityReportViewModel(
            targets: [IntegrityFixture.target(id: 1, path: "/Volumes/X/a.flac", availability: .externalOffline)],
            verifier: StubFLACVerifier(),
            spectral: StubSpectralChecker()
        )

        await model.run()

        #expect(model.rows.first?.checksum == .notAttempted)
        #expect(model.rows.first?.spectral == .notAttempted)
    }

    // MARK: - Progress and summary

    @Test("Progress starts at zero and reaches every target")
    func progressCompletes() async {
        let model = IntegrityReportViewModel(
            targets: (1 ... 4).map { IntegrityFixture.target(id: Int64($0), path: "/m/\($0).flac") },
            verifier: StubFLACVerifier(),
            spectral: StubSpectralChecker()
        )

        #expect(model.completedCount == 0)
        #expect(model.progressFraction == 0)
        #expect(model.isRunning == false)
        #expect(model.totalCount == 4)

        await model.run()

        #expect(model.completedCount == 4)
        #expect(model.progressFraction == 1)
        #expect(model.isRunning == false)
        #expect(model.currentTitle == nil)
        #expect(model.isComplete)
    }

    @Test("An empty selection completes without running anything")
    func emptySelectionIsComplete() async {
        let model = IntegrityReportViewModel(
            targets: [],
            verifier: StubFLACVerifier(),
            spectral: StubSpectralChecker()
        )

        await model.run()

        #expect(model.rows.isEmpty)
        #expect(model.progressFraction == 1)
        #expect(model.isComplete)
    }

    @Test("Only mismatches, suspect spectra and failures count as concerns")
    func concernCountIgnoresBenignStates() async {
        let paths = ["/m/ok.flac", "/m/nomd5.flac", "/m/quiet.flac", "/m/bad.flac", "/m/lossy.mp3"]
        let model = IntegrityReportViewModel(
            targets: paths.enumerated().map { IntegrityFixture.target(id: Int64($0.offset + 1), path: $0.element) },
            verifier: StubFLACVerifier(outcomes: [
                paths[0]: .success(.match),
                paths[1]: .success(IntegrityFixture.noStoredMD5),
                paths[2]: .success(.match),
                paths[3]: .success(IntegrityFixture.mismatch),
            ]),
            spectral: StubSpectralChecker(verdicts: [
                paths[2]: .indeterminate(.silentOrTooQuiet),
                paths[4]: .suspectTranscode(cutoffHz: 15800),
            ])
        )

        await model.run()

        // `match`, `noStoredMD5` and `indeterminate` are all benign: the last two
        // mean "nothing was established", which is not the same as a problem.
        #expect(model.concernCount == 2)
        #expect(model.rows.map(\.needsAttention) == [false, false, false, true, true])
    }

    // MARK: - Cancellation

    @Test("Cancelling mid-pass stops at the next file and keeps the rows already produced")
    func cancelStopsAtTheNextFile() async {
        let hook = IntegrityCancelHook()
        let model = IntegrityReportViewModel(
            targets: (1 ... 5).map { IntegrityFixture.target(id: Int64($0), path: "/m/\($0).flac") },
            verifier: StubFLACVerifier(),
            spectral: StubSpectralChecker(onInspect: { _ in await hook.cancelNow() })
        )
        hook.model = model

        await model.run()

        #expect(model.rows.count == 1)
        #expect(model.completedCount == 1)
        #expect(model.isRunning == false)
        #expect(model.isComplete == false)
    }

    // MARK: - Verdict mapping stays non-committal

    @Test("Spectral verdicts map across without gaining or losing certainty")
    func spectralVerdictMapping() {
        let mapped = [
            FakeLosslessVerdict.consistent(cutoffHz: 22050),
            .suspectTranscode(cutoffHz: 16000),
            .indeterminate(.insufficientAudio),
        ].map(IntegrityReportViewModel.outcome(for:))

        #expect(mapped == [
            .consistent(cutoffHz: 22050),
            .suspectTranscode(cutoffHz: 16000),
            .indeterminate(.insufficientAudio),
        ])
        #expect(mapped.map(\.cutoffHz) == [22050, 16000, nil])
        // A full-band reading is NOT "verified lossless" — it just is not a concern.
        #expect(mapped[0].isConcerning == false)
        #expect(mapped[2].isConcerning == false)
    }

    @Test("Results map onto exactly the three answered checksum states")
    func resultMapping() {
        let mapped = [
            FLACIntegrityResult.match,
            IntegrityFixture.mismatch,
            IntegrityFixture.noStoredMD5,
        ].map(IntegrityReportViewModel.outcome(for:))

        #expect(mapped == [.match, .mismatch, .noStoredMD5])
    }

    // MARK: - Target resolution

    @Test("Track records become targets, dropping rows that cannot identify one")
    func targetsFromRecords() {
        let targets = IntegrityCheckTarget.targets(from: [
            TrackRecord(id: 7, filePath: "/m/named.flac", title: "Named"),
            TrackRecord(id: nil, filePath: "/m/unsaved.flac", title: "Unsaved"),
            TrackRecord(id: 9, filePath: "/m/Untitled Song.flac", title: nil),
        ])

        #expect(targets.map(\.id) == [7, 9])
        #expect(targets.map(\.title) == ["Named", "Untitled Song.flac"])
        #expect(targets.first?.url == URL(fileURLWithPath: "/m/named.flac"))
    }
}
