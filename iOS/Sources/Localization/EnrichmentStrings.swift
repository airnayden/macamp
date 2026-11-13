// EnrichmentStrings — localized copy for the iOS metadata-enrichment settings.
//
// Defined as an `extension MacAMPStrings` so the metadata/enrichment settings
// strings live under the same `ios.*` namespace as the rest of the shell. Views
// reference these constants — never a bare literal — so the surface stays
// localization-clean and passes `scripts/check-hardcoded-strings.sh`. The
// `defaultValue` renders real English until Task 44 syncs the keys into
// `iOS/Sources/Localizable.xcstrings`. The "MusicBrainz" name is a proper noun
// (the online database) and is intentionally part of the English copy.
import Foundation

extension MacAMPStrings {
    static let settingsMetadata = LocalizedStringResource(
        "ios.settings.section.metadata",
        defaultValue: "Metadata",
        comment: "Settings section grouping online metadata-enrichment options"
    )
    static let settingsAutoEnrich = LocalizedStringResource(
        "ios.settings.autoEnrich",
        defaultValue: "Auto-fill Tags on Import",
        comment: "Settings toggle that enriches imported tracks from the online metadata source"
    )
    static let settingsAutoEnrichFooter = LocalizedStringResource(
        "ios.settings.autoEnrich.footer",
        defaultValue: "Automatically look up missing details from MusicBrainz when you add music.",
        comment: "Explanatory footer under the metadata-enrichment toggle"
    )

    static let settingsEnriching = LocalizedStringResource(
        "ios.settings.enriching",
        defaultValue: "Enriching tracks…",
        comment: "Label on the row shown while imported tracks are being auto-enriched"
    )
}
