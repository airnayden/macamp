// IntegrityStrings — copy for the library selection's "Verify Files…" action and
// the report sheet it opens.
//
// Two registers are deliberately different here, and mixing them would be a bug:
//
//   * CHECKSUM copy may be definite. A FLAC stream MD5 either reproduces or it
//     does not, and "Verified" means exactly that. Note that "No checksum stored"
//     is NOT a clean bill of health — it says there was nothing to check against.
//
//   * SPECTRUM copy may NEVER be definite. `FakeLosslessVerdict` is a heuristic:
//     a band-limited spectrum is evidence a stream PASSED THROUGH a lossy stage,
//     never proof that it did, and legitimate lossless material is band-limited
//     all the time. So the wording stops at "looks like" and the sheet carries a
//     standing caveat. No string here may say fake, confirmed, or proven.
import Foundation

/// Catalog-resolved copy for the file-integrity report.
enum IntegrityStrings {
    // MARK: Context menu

    static let menuVerify = LocalizedStringResource(
        "app.integrity.menu.verify",
        defaultValue: "Verify Files…",
        comment: "Context-menu action that checks the selected files for damage or re-encoding"
    )
    static let menuVerifyHelp = LocalizedStringResource(
        "app.integrity.menu.verifyHelp",
        defaultValue: "Decode the selected files and report what each one's checksum and spectrum show.",
        comment: "Tooltip explaining what the Verify Files action does"
    )

    // MARK: Sheet chrome

    static let sheetTitle = LocalizedStringResource(
        "app.integrity.sheet.title",
        defaultValue: "Verify files",
        comment: "Title of the file-integrity report sheet"
    )
    static let caveat = LocalizedStringResource(
        "app.integrity.sheet.caveat",
        defaultValue: """
        A checksum result is exact. A spectrum reading is not — band-limited audio \
        is evidence a file may have passed through a lossy encoder, never proof, \
        and plenty of genuine lossless music is band-limited.
        """,
        comment: "Standing note distinguishing the exact checksum result from the spectral heuristic"
    )
    static let stop = LocalizedStringResource(
        "app.integrity.sheet.stop",
        defaultValue: "Stop",
        comment: "Button that halts a running verification, keeping the rows already produced"
    )
    static let stopHelp = LocalizedStringResource(
        "app.integrity.sheet.stopHelp",
        defaultValue: "Stop after the file being checked. Results so far are kept.",
        comment: "Tooltip for the Stop button of the verification sheet"
    )
    static let done = LocalizedStringResource(
        "app.integrity.sheet.done",
        defaultValue: "Done",
        comment: "Button that closes the file-integrity report"
    )

    // MARK: Progress and summary

    static func progress(completed: Int, total: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.integrity.progress",
            defaultValue: "Checking \(completed.formatted()) of \(total.formatted())…",
            comment: "Progress caption naming how many of the selected files have been checked"
        )
    }

    static func summaryClean(_ count: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.integrity.summary.clean",
            defaultValue: "Checked \(count.formatted()) files. Nothing stood out.",
            comment: "Summary shown when no checked file raised a concern"
        )
    }

    static func summaryConcerns(checked: Int, concerns: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.integrity.summary.concerns",
            defaultValue: "Checked \(checked.formatted()) files — \(concerns.formatted()) worth a look.",
            comment: "Summary naming how many checked files are worth the listener's attention"
        )
    }

    // MARK: Column headings

    static let columnChecksum = LocalizedStringResource(
        "app.integrity.column.checksum",
        defaultValue: "Checksum",
        comment: "Heading for the column showing the FLAC stream checksum result"
    )
    static let columnSpectrum = LocalizedStringResource(
        "app.integrity.column.spectrum",
        defaultValue: "Spectrum",
        comment: "Heading for the column showing the spectral band-limiting reading"
    )

    // MARK: Checksum outcomes

    static let checksumMatch = LocalizedStringResource(
        "app.integrity.checksum.match",
        defaultValue: "Verified",
        comment: "Checksum result: the decoded audio reproduces the stored checksum exactly"
    )
    static let checksumMismatch = LocalizedStringResource(
        "app.integrity.checksum.mismatch",
        defaultValue: "Checksum mismatch",
        comment: "Checksum result: the decoded audio does not reproduce the stored checksum"
    )
    static let checksumNone = LocalizedStringResource(
        "app.integrity.checksum.none",
        defaultValue: "No checksum stored",
        comment: "Checksum result: the file records no checksum, so there was nothing to verify"
    )
    static let checksumNotApplicable = LocalizedStringResource(
        "app.integrity.checksum.notApplicable",
        defaultValue: "Not a FLAC stream",
        comment: "Checksum result: this format carries no FLAC checksum to verify"
    )
    static let checksumNotAttempted = LocalizedStringResource(
        "app.integrity.checksum.notAttempted",
        defaultValue: "Not checked",
        comment: "Checksum result: nothing was attempted because the file was unavailable or the run stopped"
    )
    static let checksumUnsupportedLayout = LocalizedStringResource(
        "app.integrity.checksum.unsupportedLayout",
        defaultValue: "Unsupported audio layout",
        comment: "Checksum failure: the stream's sample layout cannot be reduced to FLAC's canonical bytes"
    )
    static let checksumDecodeFailed = LocalizedStringResource(
        "app.integrity.checksum.decodeFailed",
        defaultValue: "Decoding failed part-way",
        comment: "Checksum failure: the decoder stopped before the end of the stream"
    )
    static let checksumUnreadable = LocalizedStringResource(
        "app.integrity.checksum.unreadable",
        defaultValue: "Could not be opened",
        comment: "Checksum failure: the file could not be opened for decoding at all"
    )
    static let checksumUnexpected = LocalizedStringResource(
        "app.integrity.checksum.unexpected",
        defaultValue: "Check failed",
        comment: "Checksum failure: something unexpected stopped the verification"
    )

    // MARK: Spectrum outcomes

    static func spectrumConsistent(kilohertz: Double) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.integrity.spectrum.consistent",
            defaultValue: "Content up to \(formatted(kilohertz)) kHz",
            comment: "Spectrum reading: content runs as high as the sample rate allows"
        )
    }

    static func spectrumSuspect(kilohertz: Double) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.integrity.spectrum.suspect",
            defaultValue: "Stops near \(formatted(kilohertz)) kHz — looks re-encoded",
            comment: "Spectrum reading: the spectrum stops early enough to resemble a lossy encoder's lowpass"
        )
    }

    static let spectrumTooShort = LocalizedStringResource(
        "app.integrity.spectrum.tooShort",
        defaultValue: "Too short to measure",
        comment: "Spectrum reading: too few analysis windows to average"
    )
    static let spectrumTooQuiet = LocalizedStringResource(
        "app.integrity.spectrum.tooQuiet",
        defaultValue: "Too quiet to measure",
        comment: "Spectrum reading: the material sits at or below the analysis gate"
    )
    static let spectrumUnusableRate = LocalizedStringResource(
        "app.integrity.spectrum.unusableRate",
        defaultValue: "Sample rate too low to measure",
        comment: "Spectrum reading: Nyquist is below the band the estimator anchors against"
    )
    static let spectrumFailed = LocalizedStringResource(
        "app.integrity.spectrum.failed",
        defaultValue: "Could not be analysed",
        comment: "Spectrum reading: the analysis itself failed before anything was measured"
    )
    static let spectrumNotAttempted = LocalizedStringResource(
        "app.integrity.spectrum.notAttempted",
        defaultValue: "Not checked",
        comment: "Spectrum reading: nothing was attempted because the file was unavailable or the run stopped"
    )

    // MARK: Accessibility

    static let rowAttention = LocalizedStringResource(
        "app.integrity.row.attention",
        defaultValue: "Worth a look",
        comment: "Accessibility label for the marker on a report row that raised a concern"
    )

    /// One decimal place, locale-formatted. Kept here so every kHz figure in the
    /// report is rendered the same way.
    private static func formatted(_ kilohertz: Double) -> String {
        kilohertz.formatted(.number.precision(.fractionLength(1)))
    }
}
