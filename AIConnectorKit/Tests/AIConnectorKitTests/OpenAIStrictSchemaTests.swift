// OpenAIStrictSchemaTests — the acceptance proof for `strict: true`.
//
// Two claims, both asserted on the RECORDED REQUEST BODY rather than on a schema
// value in isolation, because what OpenAI 400s is the bytes that arrive:
//
//   1. the envelope is `{"type": "json_schema", "json_schema": {"name":
//      "playlist_query", "schema": …, "strict": true}}` — the `name` field is
//      required and its absence is a 400 on an otherwise valid schema;
//   2. the SERIALIZED schema satisfies strict mode all the way down — every
//      object carries `additionalProperties: false`, every object's `required`
//      lists every one of its declared properties, and each optional field is a
//      nullable type union rather than an omission from `required`.
//
// Claim 2 is really a proof about `JSONSchemaObject`'s DEFAULTS (todo 2), which is
// exactly why it is worth pinning here: `OpenAIConnector` does not post-process the
// schema it is handed, so if those defaults ever drift, this connector silently
// starts sending 400-bait. `relaxedSchemaIsReportedAsViolating` is the negative
// control that keeps the walker from passing vacuously.
//
// https://platform.openai.com/docs/guides/structured-outputs
import AIConnectorKit
import Foundation
import Testing

@Suite("OpenAIStrictSchemaTests")
struct OpenAIStrictSchemaTests {
    /// Mirrors `FMQuerySpecDTO`'s field set: three arrays plus six optionals. The
    /// optionals are the whole point — a naive mirror of Swift optionals (drop the
    /// name from `required`) is what strict mode rejects.
    private static var dtoShapedSchema: JSONSchemaObject {
        JSONSchemaObject(properties: [
            .init(name: "genres", schema: .array(of: .string())),
            .init(name: "seedArtists", schema: .array(of: .string())),
            .init(name: "moodTags", schema: .array(of: .string(allowedValues: ["calm", "energetic", "melancholy"]))),
            .init(name: "yearLowerBound", schema: .integer(isNullable: true)),
            .init(name: "yearUpperBound", schema: .integer(isNullable: true)),
            .init(name: "tempoLowerBPM", schema: .number(isNullable: true)),
            .init(name: "tempoUpperBPM", schema: .number(isNullable: true)),
            .init(name: "recency", schema: .string(allowedValues: ["recent", "classic"], isNullable: true)),
            .init(name: "targetCount", schema: .integer(isNullable: true)),
        ])
    }

    private static let optionalFieldNames = [
        "yearLowerBound", "yearUpperBound", "tempoLowerBPM", "tempoUpperBPM", "recency", "targetCount",
    ]

    /// Sends `schema` through a real `structuredCompletion` and hands back the
    /// request the transport recorded.
    private func recordedStructuredRequest(for schema: JSONSchemaObject) async throws -> URLRequest {
        let response = try openAIFixtureResponse("openai-chat-structured.json")
        let transport = FakeHTTPTransport(scripts: [.success(response)])
        let connector = OpenAIConnector(apiKey: { "sk-test-macamp" }, transport: transport)

        _ = try await connector.structuredCompletion(
            schema: schema,
            instructions: "Return JSON matching the schema.",
            prompt: "dreamy shoegaze from the nineties",
            model: "gpt-4o"
        )

        return try #require(await transport.recordedRequests.first)
    }

    private func recordedSchema(from request: URLRequest) throws -> [String: Any] {
        let body = try openAIRecordedJSONBody(request)
        let responseFormat = try #require(body["response_format"] as? [String: Any])
        let envelope = try #require(responseFormat["json_schema"] as? [String: Any])
        return try #require(envelope["schema"] as? [String: Any])
    }

    // MARK: - The envelope

    @Test("The request carries the json_schema envelope with its required name and strict: true")
    func theEnvelopeIsStrictAndNamed() async throws {
        let request = try await recordedStructuredRequest(for: Self.dtoShapedSchema)

        let body = try openAIRecordedJSONBody(request)
        let responseFormat = try #require(body["response_format"] as? [String: Any])
        #expect(responseFormat["type"] as? String == "json_schema")

        let envelope = try #require(responseFormat["json_schema"] as? [String: Any])
        #expect(envelope["name"] as? String == "playlist_query")
        #expect(envelope["strict"] as? Bool == true)
        #expect(envelope["schema"] != nil)
    }

    @Test("The serialized envelope is byte-stable under sorted keys")
    func theEnvelopeSerializesDeterministically() async throws {
        let request = try await recordedStructuredRequest(for: JSONSchemaObject(properties: [
            .init(name: "genres", schema: .array(of: .string())),
        ]))

        let data = try #require(request.httpBody)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("""
        "response_format":{"json_schema":{"name":"playlist_query",\
        "schema":{"additionalProperties":false,\
        "properties":{"genres":{"items":{"type":"string"},"type":"array"}},\
        "required":["genres"],"type":"object"},\
        "strict":true},"type":"json_schema"}
        """))
    }

    // MARK: - Strict-mode rules on the wire

    @Test("Every object in the serialized schema satisfies strict mode")
    func theSerializedSchemaSatisfiesStrictMode() async throws {
        let request = try await recordedStructuredRequest(for: Self.dtoShapedSchema)
        let schema = try recordedSchema(from: request)

        let violations = strictModeViolations(in: schema, at: "schema")
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test("required lists ALL nine properties — optionality is never an omission")
    func requiredListsEveryProperty() async throws {
        let request = try await recordedStructuredRequest(for: Self.dtoShapedSchema)
        let schema = try recordedSchema(from: request)

        let required = try #require(schema["required"] as? [String])
        let properties = try #require(schema["properties"] as? [String: Any])
        #expect(required.count == 9)
        #expect(required.sorted() == properties.keys.sorted())
        for name in Self.optionalFieldNames {
            #expect(required.contains(name), "optional field \(name) must still be required")
        }
    }

    @Test("Each optional DTO field is a nullable type union, not a dropped requirement")
    func optionalFieldsAreNullableUnions() async throws {
        let request = try await recordedStructuredRequest(for: Self.dtoShapedSchema)
        let schema = try recordedSchema(from: request)
        let properties = try #require(schema["properties"] as? [String: Any])

        let expectedUnions = [
            "yearLowerBound": ["integer", "null"],
            "yearUpperBound": ["integer", "null"],
            "tempoLowerBPM": ["number", "null"],
            "tempoUpperBPM": ["number", "null"],
            "targetCount": ["integer", "null"],
            "recency": ["string", "null"],
        ]
        for (name, union) in expectedUnions {
            let node = try #require(properties[name] as? [String: Any])
            #expect(node["type"] as? [String] == union, "\(name) is not a nullable union")
        }
    }

    @Test("A nullable enum carries null in BOTH the type union and the enum vocabulary")
    func nullableEnumCarriesNullInTheVocabulary() async throws {
        let request = try await recordedStructuredRequest(for: Self.dtoShapedSchema)
        let schema = try recordedSchema(from: request)
        let properties = try #require(schema["properties"] as? [String: Any])

        let recency = try #require(properties["recency"] as? [String: Any])
        let vocabulary = try #require(recency["enum"] as? [Any])
        #expect(vocabulary.count == 3)
        #expect(vocabulary.prefix(2).compactMap { $0 as? String } == ["recent", "classic"])
        #expect(vocabulary.last is NSNull)

        // A NON-nullable enum must not grow a stray null.
        let moods = try #require(properties["moodTags"] as? [String: Any])
        let items = try #require(moods["items"] as? [String: Any])
        #expect(items["enum"] as? [String] == ["calm", "energetic", "melancholy"])
    }

    @Test("Strict mode holds all the way down a nested schema")
    func strictModeHoldsAtDepth() async throws {
        let window = JSONSchemaObject(properties: [
            .init(name: "from", schema: .integer(isNullable: true)),
            .init(name: "to", schema: .integer(isNullable: true)),
        ])
        let clause = JSONSchemaObject(properties: [
            .init(name: "field", schema: .string()),
            .init(name: "weight", schema: .number(isNullable: true)),
        ])
        let nested = JSONSchemaObject(properties: [
            .init(name: "window", schema: .object(window)),
            .init(name: "optionalWindow", schema: .object(window, isNullable: true)),
            .init(name: "clauses", schema: .array(of: .object(clause))),
        ])

        let request = try await recordedStructuredRequest(for: nested)
        let schema = try recordedSchema(from: request)

        let violations = strictModeViolations(in: schema, at: "schema")
        #expect(violations.isEmpty, "\(violations)")
    }

    // MARK: - Negative control

    @Test("The walker really detects violations — a deliberately relaxed schema is reported")
    func relaxedSchemaIsReportedAsViolating() async throws {
        // The connector does NOT silently repair a relaxed schema; per
        // `JSONSchemaObject`'s contract, relaxing is opt-in and stays opted in.
        let relaxed = JSONSchemaObject(
            properties: [
                .init(name: "genres", schema: .array(of: .string())),
                .init(name: "targetCount", schema: .integer(isNullable: true)),
            ],
            requiredPolicy: .explicit(["genres"]),
            allowsAdditionalProperties: true
        )

        let request = try await recordedStructuredRequest(for: relaxed)
        let schema = try recordedSchema(from: request)

        let violations = strictModeViolations(in: schema, at: "schema")
        #expect(violations.count == 2)
        #expect(violations.contains { $0.contains("additionalProperties") })
        #expect(violations.contains { $0.contains("required") })
    }
}

/// Walks a SERIALIZED JSON Schema and reports every OpenAI strict-mode breach.
///
/// The two rules, applied to every node that declares `properties`:
/// `additionalProperties` must be exactly `false`, and `required` must name every
/// declared property. Recurses through `properties` values and `items` so nested
/// objects and arrays-of-objects are covered too.
private func strictModeViolations(in node: Any, at path: String) -> [String] {
    guard let object = node as? [String: Any] else { return [] }
    var violations: [String] = []

    if let properties = object["properties"] as? [String: Any] {
        if object["additionalProperties"] as? Bool != false {
            violations.append("\(path): additionalProperties is not false")
        }
        let required = (object["required"] as? [String] ?? []).sorted()
        let declared = properties.keys.sorted()
        if required != declared {
            violations.append("\(path): required \(required) does not match properties \(declared)")
        }
        for name in declared {
            guard let child = properties[name] else { continue }
            violations += strictModeViolations(in: child, at: "\(path).\(name)")
        }
    }

    if let items = object["items"] {
        violations += strictModeViolations(in: items, at: "\(path)[]")
    }

    return violations
}
