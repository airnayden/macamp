// GenreVocabularyMatcher — the one place a model-proposed genre is checked against
// the library's real vocabulary.
//
// Every tier that lets a MODEL name a genre needs the same guard, because a model
// returns text and text goes wrong in exactly two ways: it names a genre the
// library does not hold ("Vaporwave" over a library of Rock and Jazz), or it
// spells one the library does hold differently ("progressive metal" for
// "Progressive Metal"). Both fail SILENTLY downstream — `genre(equals:)` compares
// canonical text, so an unmatched proposal empties the result rather than
// reporting a mistake.
//
// ── WHY THIS IS A FREE-STANDING TYPE ──────────────────────────────────────────
//
// The logic began as a private helper on ``FMQuerySpecFields``, back when the
// FoundationModels backend was the only model-driven producer. The connector tier
// adds more of them and each must apply the SAME rewrite, so a second copy would
// be a second place for the vocabulary policy to drift. A stateless enum keeps one
// implementation, and makes it table-testable on its own with no DTO in the way.
//
// ── WHAT THIS DELIBERATELY DOES NOT DO ────────────────────────────────────────
//
// It does not DEDUPLICATE: ``PlaylistQuerySpec/init`` already collapses duplicate
// names order-preservingly, and doing it in both places would blur which layer
// owns the rule.
//
// It does not correct SPELLING beyond case and surrounding whitespace. A fuzzy
// match would invent a constraint the listener never asked for, which is the same
// thing the DROP-never-invent policy rejects everywhere else in this tier.
//
// It does not touch ARTISTS. No tier validates those: an artist the library lacks
// is a legitimately empty result rather than a hallucination to filter, and a
// name has far more valid spellings than a genre does.
//
// It does not apply to the HEURISTIC tier, which extracts genre names FROM the
// library list and so cannot structurally propose one that is not there.
import Foundation

/// Checks model-proposed genre names against the library's real vocabulary.
///
/// Pure and stateless: no I/O, no clock, no randomness, and no FoundationModels
/// reference. Floor-available, so every tier — including the ones that exist for
/// machines with no model at all — can apply the same guard.
public enum GenreVocabularyMatcher {
    /// Keeps only genres the library actually holds, rewritten to its spelling.
    ///
    /// A proposal survives only if it matches a vocabulary entry case-insensitively
    /// once surrounding whitespace is trimmed, and it is rewritten to the LIBRARY's
    /// spelling so the downstream `genre(equals:)` predicate compares canonical
    /// text.
    ///
    /// - Parameters:
    ///   - proposed: The genre names a model returned, in the order it returned
    ///     them. Every one is treated as a guess.
    ///   - valid: The library's real genres, normally
    ///     `TrackRepository.distinctGenres`. An EMPTY array means "no vocabulary
    ///     available", and every proposal passes through unvalidated — dropping
    ///     them all would silently convert "90s rock" into "90s anything", which
    ///     misstates the request more badly than an empty result does.
    /// - Returns: The surviving names in `proposed` order, each carrying the
    ///   library's spelling. Duplicates are NOT collapsed — ``PlaylistQuerySpec``
    ///   owns that rule.
    public static func validated(_ proposed: [String], against valid: [String]) -> [String] {
        guard !valid.isEmpty else { return proposed }
        var canonical: [String: String] = [:]
        for name in valid {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            // First spelling wins, so a library holding both "Rock" and "rock"
            // resolves deterministically rather than by dictionary order.
            let key = trimmed.lowercased()
            if canonical[key] == nil {
                canonical[key] = trimmed
            }
        }
        return proposed.compactMap { proposal in
            canonical[proposal.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
        }
    }
}
