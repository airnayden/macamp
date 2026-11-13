// IntelligenceLibraryBrowsingConsent — the SECOND disclosure, and why there is one.
//
// ── WHAT CHANGED BETWEEN THE TWO ──────────────────────────────────────────────
//
// The connect-time disclosure (``IntelligenceConsentDisclosure``) describes a
// payload that is FIXED and computed before the request leaves: the listener's
// sentence, a genre vocabulary, an artist list. Sixty-four names, once, and the
// provider answers.
//
// A conversation is not that. The provider is handed TOOLS and decides for itself
// what to ask for, repeatedly, while it works — track titles, artists, albums,
// genres, years and listening statistics, on demand. Nobody can enumerate in advance
// which rows of a library will be read, because the model has not chosen them yet.
// That is a materially larger promise than the first sheet made, so it gets its own
// record and its own acceptance, and an existing acceptance is NOT read as covering
// it.
//
// ── EVERY NUMBER IS READ FROM ITS ENFORCEMENT, NEVER RESTATED ─────────────────
//
// Exactly the rule ``IntelligenceConsentDisclosure`` follows for
// ``ConnectorPayloadBudget``, applied to this tier's own single-source constants:
// ``ToolProfile/cloud`` bounds one lookup's size and
// ``ToolLoopEngine/defaultMaxToolRounds`` bounds how many lookups a question may
// cost. A literal here would drift from the enforcement, and the copy the listener
// read is the one that binds.
//
// ── APPLE INTELLIGENCE IS NOT COVERED BY THIS FILE, ON PURPOSE ────────────────
//
// The on-device tier reads the same library through the same tools and discloses
// NOTHING, because nothing leaves the Mac. The routing matrix reaches the consent
// branch only for a connector, so the exemption is structural rather than a check
// someone has to remember.
import AIConnectorKit
import Foundation
import Services

/// Records which connectors may browse the library during a conversation.
///
/// A protocol for the same reason ``IntelligenceConnectorConsentStoring`` is one: the
/// claim under test is that an unconsented conversation writes NOTHING and sends
/// NOTHING, and a negative claim about writes cannot be checked from the end state.
@MainActor
protocol LibraryBrowsingConsentStoring: AnyObject {
    func hasLibraryBrowsingConsent(forConnectorID connectorID: String) -> Bool
    func recordLibraryBrowsingConsent(forConnectorID connectorID: String)
}

extension AppSettings: LibraryBrowsingConsentStoring {
    func hasLibraryBrowsingConsent(forConnectorID connectorID: String) -> Bool {
        libraryBrowsingConsentedConnectorIDs.contains(connectorID)
    }

    func recordLibraryBrowsingConsent(forConnectorID connectorID: String) {
        libraryBrowsingConsentedConnectorIDs.insert(connectorID)
    }
}

/// One connector's library-browsing disclosure: who reads, what they can see, and
/// how much of it.
///
/// `Identifiable` on the connector id so `.sheet(item:)` drives presentation and the
/// accessibility identifiers are built from the same identity — the shape
/// ``IntelligenceConsentDisclosure`` established.
struct LibraryBrowsingDisclosure: Identifiable, Equatable {
    let id: String
    /// The provider's own name. A BRAND: rendered verbatim, never localized.
    let displayName: String

    /// Rows one lookup may return. ``ToolProfile/rowLimit`` for the cloud tier.
    var rowsPerLookup: Int {
        ToolProfile.cloud.rowLimit
    }

    /// Characters one lookup may occupy. ``ToolProfile/characterLimit``, and a HARD
    /// bound — W1 note 4: rows are dropped from the tail until the result fits.
    var charactersPerLookup: Int {
        ToolProfile.cloud.characterLimit
    }

    /// Lookups one question may cost, before the loop stops and answers with whatever
    /// it has. ``ToolLoopEngine/defaultMaxToolRounds``.
    var lookupsPerQuestion: Int {
        ToolLoopEngine.defaultMaxToolRounds
    }
}
