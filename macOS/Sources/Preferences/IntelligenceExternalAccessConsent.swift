// IntelligenceExternalAccessConsent — the THIRD disclosure, and why it is a third.
//
// ── WHAT CHANGED, AGAIN ──────────────────────────────────────────────────────
//
// The connect-time sheet describes a payload computed before the request leaves.
// The browsing sheet describes a named PROVIDER that may ask for more while it
// answers a question the listener asked, inside MacAMP, in a conversation the
// listener can see.
//
// This one has neither of those bounds. The principal is an unnamed program on
// this Mac with a lifetime of its own; it asks when it likes, for as long as the
// switch is on, and MacAMP is told nothing about who it is. Reusing either earlier
// record for it would silently widen a promise made about a named vendor into a
// promise about "whatever else is running", which is the one thing a consent record
// must never do. `LibraryChatConsentTests`' independence argument, one step out.
//
// ── EVERY NUMBER IS READ FROM ITS ENFORCEMENT ────────────────────────────────
//
// ``ToolProfile/external`` bounds one lookup, exactly as the browsing sheet reads
// ``ToolProfile/cloud``. The port is the listener's own setting, so the sheet can
// state the reach of the socket it is about to open.
import Foundation
import Services

/// Records whether external access has been disclosed and accepted.
///
/// A protocol for the reason the other two consent stores are protocols: the claim
/// under test is that an undisclosed server NEVER binds, and a negative claim about
/// a side effect cannot be checked from the end state alone.
@MainActor
protocol ExternalAccessConsentStoring: AnyObject {
    var hasExternalAccessConsent: Bool { get }
    func recordExternalAccessConsent()
}

extension AppSettings: ExternalAccessConsentStoring {
    var hasExternalAccessConsent: Bool {
        externalAccessConsented
    }

    func recordExternalAccessConsent() {
        externalAccessConsented = true
    }
}

/// What an external program can see, how much of it at a time, and how far the
/// socket reaches.
///
/// `Identifiable` on the port so `.sheet(item:)` re-presents when the port changes —
/// the sheet states the port, so a stale one would be a false statement.
struct ExternalAccessDisclosure: Identifiable, Equatable {
    let port: Int

    var id: Int {
        port
    }

    /// Rows one lookup may return. ``ToolProfile/rowLimit`` for the external tier.
    var rowsPerLookup: Int {
        ToolProfile.external.rowLimit
    }

    /// Characters one lookup may occupy — a HARD bound: rows are dropped from the
    /// tail until the whole result fits (W1 note 4).
    var charactersPerLookup: Int {
        ToolProfile.external.characterLimit
    }
}
