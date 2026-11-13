import Foundation
import Persistence
import Testing

@Suite("SmartPlaylistRulesTests")
struct SmartPlaylistRulesTests {
    @Test("A rule set survives an encode/decode round trip unchanged")
    func roundTripsThroughJSON() throws {
        let rules = SmartPlaylistRules(
            match: .any,
            predicates: [
                .metadata(.genre(equals: "Rock")),
                .metadata(.year(range: SmartPlaylistRange(lower: 1990, upper: 1999))),
                .metadata(.availability(equals: .present)),
                .profileStat(.isFavourite(equals: true)),
                .profileStat(.playCount(range: SmartPlaylistRange(lower: 5))),
                .recency(.notPlayedWithin(days: 90)),
                .audioFeature(.energy(range: SmartPlaylistRange(lower: 0.5, upper: 1.0))),
            ],
            sort: SmartPlaylistSort(field: .playCount, direction: .descending),
            limit: 50
        )

        let decoded = try SmartPlaylistRules.decode(json: rules.encodedJSON())

        #expect(decoded == rules)
    }

    @Test("Encoding is byte-stable, so identical rules produce identical payloads")
    func encodingIsDeterministic() throws {
        let rules = SmartPlaylistRules(predicates: [.metadata(.genre(equals: "Rock"))], limit: 50)

        let first = try rules.encodedJSON()
        let second = try rules.encodedJSON()

        #expect(first == second)
    }

    @Test("A payload from a newer schema is rejected with a typed error")
    func rejectsUnknownSchemaVersion() throws {
        let future = SmartPlaylistRules(
            predicates: [.metadata(.genre(equals: "Rock"))],
            schemaVersion: SmartPlaylistRules.currentSchemaVersion + 1
        )
        let json = try future.encodedJSON()

        #expect(throws: SmartPlaylistError.unsupportedRulesVersion(
            found: SmartPlaylistRules.currentSchemaVersion + 1,
            supported: SmartPlaylistRules.currentSchemaVersion
        )) {
            _ = try SmartPlaylistRules.decode(json: json)
        }
    }

    @Test("The rulesVersion column is gated before the payload is parsed at all")
    func rejectsUnknownDeclaredVersion() throws {
        let json = try SmartPlaylistRules().encodedJSON()

        #expect(throws: SmartPlaylistError.unsupportedRulesVersion(
            found: 99,
            supported: SmartPlaylistRules.currentSchemaVersion
        )) {
            _ = try SmartPlaylistRules.decode(json: json, declaredVersion: 99)
        }
    }

    @Test("A payload with no schemaVersion reads as v1, matching the column default")
    func absentVersionReadsAsLegacy() throws {
        let json = #"{"match":"all","predicates":[],"limit":25}"#

        let decoded = try SmartPlaylistRules.decode(json: json)

        #expect(decoded.schemaVersion == SmartPlaylistRules.legacySchemaVersion)
        #expect(decoded.limit == 25)
    }

    @Test("Unparseable JSON is a typed error, never a crash or a silent mis-parse")
    func rejectsMalformedPayload() throws {
        #expect(throws: SmartPlaylistError.self) {
            _ = try SmartPlaylistRules.decode(json: "{ not json at all")
        }
        #expect(throws: SmartPlaylistError.self) {
            _ = try SmartPlaylistRules.decode(json: #"{"schemaVersion":"one"}"#)
        }
        #expect(throws: SmartPlaylistError.self) {
            _ = try SmartPlaylistRules.decode(json: #"{"predicates":[{"nonsense":{}}]}"#)
        }
    }

    @Test("A rule set is bounded: the limit is clamped into 1...maximumLimit")
    func clampsLimit() {
        #expect(SmartPlaylistRules(limit: 50).effectiveLimit == 50)
        #expect(SmartPlaylistRules(limit: 10000).effectiveLimit == SmartPlaylistRules.maximumLimit)
        #expect(SmartPlaylistRules(limit: 0).effectiveLimit == 1)
        #expect(SmartPlaylistRules(limit: -7).effectiveLimit == 1)
        #expect(SmartPlaylistRules().limit == SmartPlaylistRules.defaultLimit)
    }
}
