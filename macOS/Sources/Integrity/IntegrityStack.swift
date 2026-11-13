// IntegrityStack — the two verification seams, built on first use.
//
// Deliberately takes no database and holds no view model. NOTHING the report
// produces is persisted: there is no GRDB table, no cache and no settings key
// behind it, so a report exists only for as long as its sheet is open. Re-running
// it decodes the files again, which is the honest cost of the answer.
//
// Built lazily by ``AppEnvironment`` for the same reason ``LoudnessStack`` is:
// verification is opt-in, and a launch that never right-clicks a track should not
// construct a decoder provider at all. Reaching this property still verifies
// nothing — only ``IntegrityReportViewModel/run()`` does, and only the report
// sheet calls it.
import Decoding
import Services

/// The FLAC checksum seam and the spectral heuristic seam, as one value.
@MainActor
struct IntegrityStack {
    let verifier: any FLACIntegrityVerifying
    let spectral: any SpectralIntegrityChecking

    static func live() -> IntegrityStack {
        // One provider for both passes: it is a stateless factory, and the two
        // passes open the same file back to back.
        let provider = SFBDecoderProvider()
        return IntegrityStack(
            verifier: IntegrityCheckService(decoderProvider: provider),
            spectral: SpectralIntegrityAnalyzer(decoderProvider: provider)
        )
    }
}
