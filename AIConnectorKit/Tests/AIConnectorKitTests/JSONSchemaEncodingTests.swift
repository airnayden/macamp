// JSONSchemaEncodingTests — byte-level proof of the schema encoding contract.
//
// Assertions compare the ENCODED STRING, not a re-parsed structure, because the
// three providers reject documents on shape: OpenAI strict mode 400s a schema that
// omits `additionalProperties: false`, or that leaves an optional field out of
// `required` instead of giving it a nullable type union. Round-tripping through
// `JSONSerialization` would hide exactly those mistakes behind Foundation's
// tolerance.
//
// `.sortedKeys` makes the output deterministic — key order inside a keyed
// container is otherwise an encoder implementation detail. Array order (`enum`,
// `required`) is always declaration order and is asserted as such.
import AIConnectorKit
import Foundation
import Testing

@Suite("JSONSchemaEncodingTests")
struct JSONSchemaEncodingTests {
    private func encoded(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        let text = String(data: data, encoding: .utf8)
        return try #require(text)
    }

    @Test("The specified object serializes exactly: enum string, nullable integer, strict mode")
    func specifiedObjectSerializesExactly() throws {
        let schema = JSONSchemaObject(properties: [
            .init(name: "mood", schema: .string(allowedValues: ["calm", "energetic"])),
            .init(name: "yearLowerBound", schema: .integer(isNullable: true)),
        ])

        let json = try encoded(schema)

        #expect(json == """
        {"additionalProperties":false,\
        "properties":{"mood":{"enum":["calm","energetic"],"type":"string"},\
        "yearLowerBound":{"type":["integer","null"]}},\
        "required":["mood","yearLowerBound"],\
        "type":"object"}
        """)
    }

    @Test("required lists ALL properties in declaration order by default")
    func requiredListsAllPropertiesInDeclarationOrder() throws {
        let schema = JSONSchemaObject(properties: [
            .init(name: "zulu", schema: .boolean()),
            .init(name: "alpha", schema: .boolean()),
            .init(name: "mike", schema: .boolean()),
        ])

        #expect(schema.requiredPropertyNames == ["zulu", "alpha", "mike"])
        let json = try encoded(schema)
        #expect(json.contains(#""required":["zulu","alpha","mike"]"#))
    }

    @Test("An explicit required policy overrides the all-properties default")
    func explicitRequiredPolicyIsHonoured() throws {
        let schema = JSONSchemaObject(
            properties: [
                .init(name: "genres", schema: .array(of: .string())),
                .init(name: "targetCount", schema: .integer(isNullable: true)),
            ],
            requiredPolicy: .explicit(["genres"])
        )

        #expect(schema.requiredPropertyNames == ["genres"])
        let json = try encoded(schema)
        #expect(json.contains(#""required":["genres"]"#))
    }

    @Test("additionalProperties is always emitted and defaults to false")
    func additionalPropertiesIsAlwaysEmitted() throws {
        let strict = JSONSchemaObject(properties: [])
        #expect(try encoded(strict).contains(#""additionalProperties":false"#))

        let relaxed = JSONSchemaObject(properties: [], allowsAdditionalProperties: true)
        #expect(try encoded(relaxed).contains(#""additionalProperties":true"#))
    }

    @Test("A nullable enum string carries null in BOTH the type union and the enum list")
    func nullableEnumCarriesNullInTheVocabulary() throws {
        let node = JSONSchemaNode.string(allowedValues: ["chill", "hype"], isNullable: true)

        let json = try encoded(node)

        #expect(json == #"{"enum":["chill","hype",null],"type":["string","null"]}"#)
    }

    @Test("An unconstrained string emits no enum key at all")
    func unconstrainedStringEmitsNoEnum() throws {
        #expect(try encoded(JSONSchemaNode.string()) == #"{"type":"string"}"#)
    }

    @Test("Every scalar kind emits its JSON Schema type name")
    func scalarKindsEmitTheirTypeNames() throws {
        #expect(try encoded(JSONSchemaNode.integer()) == #"{"type":"integer"}"#)
        #expect(try encoded(JSONSchemaNode.number()) == #"{"type":"number"}"#)
        #expect(try encoded(JSONSchemaNode.boolean()) == #"{"type":"boolean"}"#)
        #expect(try encoded(JSONSchemaNode.number(isNullable: true)) == #"{"type":["number","null"]}"#)
    }

    @Test("An array node nests its element schema under items")
    func arrayNodeNestsItsElementSchema() throws {
        let node = JSONSchemaNode.array(of: .string(allowedValues: ["rock", "jazz"]))

        #expect(try encoded(node) == #"{"items":{"enum":["rock","jazz"],"type":"string"},"type":"array"}"#)
    }

    @Test("A nested object keeps strict mode all the way down")
    func nestedObjectKeepsStrictModeAllTheWayDown() throws {
        let inner = JSONSchemaObject(properties: [
            .init(name: "count", schema: .integer()),
        ])
        let outer = JSONSchemaObject(properties: [
            .init(name: "window", schema: .object(inner)),
        ])

        let json = try encoded(outer)

        #expect(json == """
        {"additionalProperties":false,\
        "properties":{"window":{"additionalProperties":false,\
        "properties":{"count":{"type":"integer"}},\
        "required":["count"],\
        "type":"object"}},\
        "required":["window"],\
        "type":"object"}
        """)
    }

    @Test("A nullable object node unions its type and still emits its body")
    func nullableObjectNodeUnionsItsType() throws {
        let node = JSONSchemaNode.object(
            JSONSchemaObject(properties: [.init(name: "count", schema: .integer())]),
            isNullable: true
        )

        #expect(try encoded(node) == """
        {"additionalProperties":false,\
        "properties":{"count":{"type":"integer"}},\
        "required":["count"],\
        "type":["object","null"]}
        """)
    }

    @Test("Descriptions ride along for the model to read")
    func descriptionsRideAlong() throws {
        let node = JSONSchemaNode.integer(isNullable: true, description: "Earliest release year, or null")

        #expect(try encoded(node) == """
        {"description":"Earliest release year, or null","type":["integer","null"]}
        """)
    }

    @Test("An object with no properties still encodes a valid strict schema")
    func emptyObjectStillEncodesValidly() throws {
        #expect(try encoded(JSONSchemaObject(properties: [])) == """
        {"additionalProperties":false,"properties":{},"required":[],"type":"object"}
        """)
    }

    @Test("property(named:) finds a declared property and nothing else")
    func propertyLookupFindsDeclaredPropertiesOnly() {
        let schema = JSONSchemaObject(properties: [
            .init(name: "genres", schema: .array(of: .string())),
        ])

        #expect(schema.property(named: "genres") == .array(of: .string()))
        #expect(schema.property(named: "moods") == nil)
    }
}
