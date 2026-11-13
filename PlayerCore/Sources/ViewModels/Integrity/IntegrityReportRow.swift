//
//  IntegrityReportRow.swift
//  MacAMP PlayerCore — ViewModels
//
//  The value types behind the "Verify Files…" report: which files the listener
//  asked to have checked, and what each check concluded about one of them.
//
//  Both outcome enums are deliberately WIDER than the service results they
//  summarise, because a report row has to say something for every file it lists:
//
//    * ``FLACIntegrityResult`` has three cases and every one of them is a real
//      ANSWER. A thrown ``FLACIntegrityError`` is a DIFFERENT outcome — "could not
//      check" — and collapsing it into one of the three would let a listener read
//      an unreadable file as a clean one. Hence FOUR states for a FLAC stream
//      (match / mismatch / no stored checksum / failed), plus ``notApplicable``
//      for a stream that carries no FLAC checksum at all and ``notAttempted``
//      for a file that is not on disk right now.
//
//    * ``FakeLosslessVerdict`` is a HEURISTIC and nothing it produces is proof.
//      The vocabulary here keeps that register: the only negative case is
//      ``IntegritySpectralOutcome/suspectTranscode``, and there is no case named
//      `fake`, `confirmed` or `proven`.
//
//  PlayerCore portability: DSP + Foundation + Persistence.
//

import DSP
import Foundation
import Persistence

// MARK: - IntegrityCheckTarget

/// One file the report will verify, resolved before any decoding starts.
///
/// A flat value rather than a `TrackRecord` so the verification loop — and its
/// tests — never need a database row.
public struct IntegrityCheckTarget: Identifiable, Sendable, Equatable {
    /// The library track id. Doubles as the report row's identity.
    public let id: Int64

    /// What the row shows. Never a path fragment unless the track has no title.
    public let title: String

    public let filePath: String

    /// Availability at the moment the report was requested. Anything other than
    /// ``Availability/present`` means nothing is decoded for this row.
    public let availability: Availability

    public init(id: Int64, title: String, filePath: String, availability: Availability) {
        self.id = id
        self.title = title
        self.filePath = filePath
        self.availability = availability
    }

    public var url: URL {
        URL(fileURLWithPath: filePath)
    }

    /// The selected records as verification targets, in the order given.
    ///
    /// Rows with no id (or the non-positive "not a library track" sentinel) are
    /// dropped: they cannot identify a report row.
    public static func targets(from records: [TrackRecord]) -> [IntegrityCheckTarget] {
        records.compactMap { record in
            guard let trackId = record.id, trackId > 0 else { return nil }
            return IntegrityCheckTarget(
                id: trackId,
                title: displayTitle(for: record),
                filePath: record.filePath,
                availability: record.availability
            )
        }
    }

    private static func displayTitle(for record: TrackRecord) -> String {
        if let title = record.title, !title.isEmpty { return title }
        return URL(fileURLWithPath: record.filePath).lastPathComponent
    }
}

// MARK: - IntegrityChecksumOutcome

/// What the FLAC stream-MD5 verification concluded about one file.
public enum IntegrityChecksumOutcome: Sendable, Equatable {
    /// The decoded samples reproduce the stored checksum exactly.
    case match

    /// The stored checksum and the decoded samples disagree. Either the audio
    /// data or the checksum has changed since the file was written.
    case mismatch

    /// The checksum field is the all-zero "none was recorded" sentinel, so there
    /// was nothing to verify against. NOT a failure, and NOT a clean result.
    case noStoredMD5

    /// No verdict could be reached. Distinct from every case above by design.
    case failed(IntegrityChecksumFailure)

    /// The stream publishes no FLAC checksum — i.e. it is not a FLAC file. The
    /// spectral reading on the same row still applies.
    case notApplicable

    /// Nothing was attempted: the file is not reachable, or the run was stopped.
    case notAttempted

    /// Whether the row is worth a listener's attention.
    ///
    /// ``noStoredMD5`` is NOT included: a stream with no recorded checksum has
    /// nothing wrong with it, it simply cannot be verified this way.
    public var isConcerning: Bool {
        switch self {
        case .mismatch, .failed: true
        case .match, .noStoredMD5, .notApplicable, .notAttempted: false
        }
    }
}

/// Why a FLAC checksum verification could not reach a verdict.
///
/// The service's diagnostic `reason` strings are deliberately dropped: they are
/// machine detail, not copy, and every case here maps to its own catalog entry in
/// the shell.
public enum IntegrityChecksumFailure: String, Sendable, Equatable, CaseIterable {
    /// The PCM layout cannot be reduced to FLAC's canonical sample bytes.
    case unsupportedLayout

    /// The decoder failed part-way through the stream.
    case decodeFailed

    /// The decoder could not be opened at all.
    case unreadable

    /// Something outside ``FLACIntegrityError`` was thrown.
    case unexpected
}

// MARK: - IntegritySpectralOutcome

/// What the spectral heuristic observed about one file. Never proof — see
/// ``FakeLosslessVerdict``.
public enum IntegritySpectralOutcome: Sendable, Equatable {
    /// Content runs as high as the sample rate allows. This is NOT "verified
    /// lossless"; the heuristic cannot establish that.
    case consistent(cutoffHz: Double)

    /// Content stops early enough to look like a lossy encoder's lowpass.
    /// Grounds for a closer look by a human, never a conclusion.
    case suspectTranscode(cutoffHz: Double)

    /// Nothing could be measured. NOT a clean result.
    case indeterminate(SpectralIndeterminateReason)

    /// The inspection itself failed before any measurement was possible.
    case failed

    /// Nothing was attempted: the file is not reachable, or the run was stopped.
    case notAttempted

    public var cutoffHz: Double? {
        switch self {
        case let .consistent(cutoffHz), let .suspectTranscode(cutoffHz): cutoffHz
        case .indeterminate, .failed, .notAttempted: nil
        }
    }

    /// Whether the row is worth a listener's attention.
    public var isConcerning: Bool {
        switch self {
        case .suspectTranscode, .failed: true
        case .consistent, .indeterminate, .notAttempted: false
        }
    }
}

// MARK: - IntegrityReportRow

/// One file's line in the report.
public struct IntegrityReportRow: Identifiable, Sendable, Equatable {
    public let id: Int64
    public let title: String
    public let filePath: String
    public let availability: Availability
    public let checksum: IntegrityChecksumOutcome
    public let spectral: IntegritySpectralOutcome

    public init(
        target: IntegrityCheckTarget,
        checksum: IntegrityChecksumOutcome,
        spectral: IntegritySpectralOutcome
    ) {
        id = target.id
        title = target.title
        filePath = target.filePath
        availability = target.availability
        self.checksum = checksum
        self.spectral = spectral
    }

    /// `true` when either reading is worth a listener's attention.
    ///
    /// Availability is deliberately excluded: an offline file is already shown as
    /// such, and it is not evidence of damage.
    public var needsAttention: Bool {
        checksum.isConcerning || spectral.isConcerning
    }
}
