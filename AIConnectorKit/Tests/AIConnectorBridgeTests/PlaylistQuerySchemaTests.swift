import AIConnectorBridge
import AIConnectorKit
import Foundation
import Services
import Testing

/// The canonical schema is a MIRROR, so every assertion here compares it against the
/// Swift type rather than against a second hand-written list — a hardcoded field list
/// would drift the moment `FMQuerySpecFields` gains a field, which is exactly the
/// event these tests exist to catch.
@Suite("PlaylistQuerySchemaBridgeTests")
struct PlaylistQuerySchemaTests {
    @Test("Every stored property of FMQuerySpecFields is a schema property, in declaration order")
    func mirrorsEveryRawSpecField() {
        let swiftFields = Mirror(reflecting: FMQuerySpecFields()).children.compactMap(\.label)
        #expect(swiftFields.count == 9)
        #expect(PlaylistQuerySchema.canonical.properties.map(\.name) == swiftFields)
    }

    @Test("Strict mode holds: every property required, no additional properties")
    func strictModeDefaultsHold() {
        #expect(PlaylistQuerySchema.canonical.allowsAdditionalProperties == false)
        #expect(
            PlaylistQuerySchema.canonical.requiredPropertyNames
                == PlaylistQuerySchema.canonical.properties.map(\.name)
        )
    }

    @Test("lowConfidence is derived client-side and is deliberately absent from the schema")
    func lowConfidenceIsNotASchemaField() {
        #expect(PlaylistQuerySchema.canonical.property(named: "lowConfidence") == nil)
        // The flag exists — on the RESOLVED spec, set from `isUnconstrained`. Asserting
        // both halves is what makes the absence above a decision rather than an oversight.
        #expect(Mirror(reflecting: PlaylistQuerySpec()).children.contains { $0.label == "lowConfidence" })
    }

    @Test("moodTags carries the closed mood vocabulary on its element")
    func moodTagsCarryTheClosedVocabulary() throws {
        let node = try #require(PlaylistQuerySchema.canonical.property(named: "moodTags"))
        let items = try #require(Self.arrayItems(of: node))
        #expect(Self.allowedValues(of: items) == FMQuerySpecFields.moodVocabulary)
        #expect(FMQuerySpecFields.moodVocabulary == ["calm", "energetic", "dark", "bright"])
        #expect(node.isNullable == false)
    }

    @Test("recency carries the closed recency vocabulary, none first, and accepts null")
    func recencyCarriesTheClosedVocabulary() throws {
        let node = try #require(PlaylistQuerySchema.canonical.property(named: "recency"))
        #expect(Self.allowedValues(of: node) == FMQuerySpecFields.recencyVocabulary)
        #expect(
            FMQuerySpecFields.recencyVocabulary
                == ["none", "freshlyAdded", "recentlyPlayed", "rediscovery"]
        )
        // `FMQuerySpecFields.recency` is `String?`, so the mirror is nullable. `"none"`
        // stays first in the vocabulary so a model has a non-null way to say the same
        // thing; `resolve` maps null, "" and "none" alike to no preference.
        #expect(node.isNullable)
    }

    @Test("Optional raw fields are nullable unions; list fields are not")
    func optionalityMatchesTheRawBag() throws {
        for name in ["yearLowerBound", "yearUpperBound", "tempoLowerBPM", "tempoUpperBPM", "targetCount"] {
            let node = try #require(PlaylistQuerySchema.canonical.property(named: name))
            #expect(node.isNullable, "\(name) mirrors an Optional and must be a nullable union")
        }
        for name in ["genres", "moodTags", "seedArtists"] {
            let node = try #require(PlaylistQuerySchema.canonical.property(named: name))
            #expect(node.isNullable == false, "\(name) mirrors a non-optional array")
        }
    }

    @Test("Encoded document carries strict-mode keys and a measurable size")
    func encodesForStrictMode() throws {
        let data = try PlaylistQuerySchema.canonicalEncoder().encode(PlaylistQuerySchema.canonical)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"additionalProperties\":false"))
        #expect(json.contains("\"required\":[\"genres\",\"yearLowerBound\""))
        #expect(json.contains("\"type\":[\"integer\",\"null\"]"))
        #expect(PlaylistQuerySchema.canonicalByteCount == data.count)
        #expect(PlaylistQuerySchema.canonicalByteCount < ConnectorPayloadBudget.maxSerializedBodyBytes)
    }

    // MARK: Round trip

    @Test("A valid provider answer decodes into the raw bag the validator accepts")
    func providerAnswerRoundTripsIntoAServableSpec() throws {
        let answer = """
        {"genres":["rock","Jazz"],"yearLowerBound":1990,"yearUpperBound":1999,
         "moodTags":["energetic"],"tempoLowerBPM":110,"tempoUpperBPM":140.5,
         "recency":"rediscovery","seedArtists":["Radiohead"],"targetCount":25}
        """
        let fields = try PlaylistQuerySchema.decodeFields(from: Data(answer.utf8))
        #expect(fields.genres == ["rock", "Jazz"])
        #expect(fields.yearLowerBound == 1990)
        #expect(fields.yearUpperBound == 1999)
        #expect(fields.moodTags == ["energetic"])
        #expect(fields.tempoLowerBPM == 110)
        #expect(fields.tempoUpperBPM == 140.5)
        #expect(fields.recency == "rediscovery")
        #expect(fields.seedArtists == ["Radiohead"])
        #expect(fields.targetCount == 25)

        // Todo 5's validator accepts it and rewrites to the library's own spelling.
        let spec = fields.resolve(validGenres: ["Rock", "Jazz", "Ambient"])
        #expect(spec.genres == ["Rock", "Jazz"])
        #expect(spec.yearRange?.lower == 1990)
        #expect(spec.yearRange?.upper == 1999)
        #expect(spec.moodTags == [.energetic])
        #expect(spec.tempoRange?.lower == 110)
        #expect(spec.recency == .rediscovery)
        #expect(spec.seedArtists == ["Radiohead"])
        #expect(spec.targetCount == 25)
        #expect(spec.lowConfidence == false)
    }

    @Test("Nulls everywhere decode to an empty bag that still resolves")
    func allNullAnswerResolvesToAnUnconstrainedSpec() throws {
        let answer = """
        {"genres":[],"yearLowerBound":null,"yearUpperBound":null,"moodTags":[],
         "tempoLowerBPM":null,"tempoUpperBPM":null,"recency":"none","seedArtists":[],
         "targetCount":null}
        """
        let fields = try PlaylistQuerySchema.decodeFields(from: Data(answer.utf8))
        #expect(fields == FMQuerySpecFields(recency: "none"))

        let spec = fields.resolve(validGenres: ["Rock"])
        #expect(spec.isUnconstrained)
        #expect(spec.lowConfidence, "an unconstrained spec is the low-confidence reading")
    }

    @Test("One loose scalar drops one field, never the whole answer")
    func wrongTypesDropOnlyTheirOwnField() throws {
        // A year written as a float and a tempo written as a string: both real provider
        // slips. DROP, NEVER FAIL — the seven well-formed fields still land.
        let answer = """
        {"genres":["Rock"],"yearLowerBound":1990.5,"yearUpperBound":1999,"moodTags":["calm"],
         "tempoLowerBPM":"120","tempoUpperBPM":null,"recency":null,"seedArtists":[],
         "targetCount":10}
        """
        let fields = try PlaylistQuerySchema.decodeFields(from: Data(answer.utf8))
        #expect(fields.yearLowerBound == nil)
        #expect(fields.tempoLowerBPM == nil)
        #expect(fields.yearUpperBound == 1999)
        #expect(fields.genres == ["Rock"])
        #expect(fields.moodTags == ["calm"])
        #expect(fields.targetCount == 10)
    }

    @Test("Missing keys decode to the empty bag rather than throwing")
    func absentKeysAreTolerated() throws {
        let fields = try PlaylistQuerySchema.decodeFields(from: Data("{}".utf8))
        #expect(fields == FMQuerySpecFields())
    }

    @Test("A non-object answer is a malformed response")
    func nonObjectAnswerThrowsMalformedResponse() {
        for payload in ["Sure! Here is your playlist:", "[1,2,3]", ""] {
            #expect(throws: ConnectorFailure.malformedResponse) {
                _ = try PlaylistQuerySchema.decodeFields(from: Data(payload.utf8))
            }
        }
    }

    // MARK: Helpers

    private static func arrayItems(of node: JSONSchemaNode) -> JSONSchemaNode? {
        guard case let .array(items) = node.kind else { return nil }
        return items
    }

    private static func allowedValues(of node: JSONSchemaNode) -> [String]? {
        guard case let .string(allowedValues) = node.kind else { return nil }
        return allowedValues
    }
}
