// Shared doubles for the three bridge conformers.
//
// The fake is a real ``AIProviderConnector`` rather than a stub of the conformer, so
// every test drives the SHIPPING path — prompt build, transport call, decode,
// validation — and only the provider's answer is scripted. It records what each call
// carried, which is what lets a test assert the schema and the budgeted prompt that
// actually left rather than the ones the conformer intended to send.
import AIConnectorBridge
import AIConnectorKit
import Foundation
import Services

/// One scripted provider answer.
enum FakeConnectorAnswer {
    /// Raw structured-output bytes.
    case data(Data)
    /// Plain prose, for the naming and narration tiers.
    case text(String)
    /// A taxonomy failure raised instead of answering.
    case failure(ConnectorFailure)
    /// Sleeps far past any test deadline. Cooperative, so `withDeadline` can cancel it.
    case slow
}

/// What one provider call carried.
struct RecordedConnectorCall: Equatable {
    var instructions: String
    var prompt: String
    var model: String
    /// The schema as it was encoded, or `nil` for a plain completion.
    var schema: Data?
}

/// Append-only log of everything a fake connector was asked to do.
actor ConnectorCallLog {
    private(set) var calls: [RecordedConnectorCall] = []

    var callCount: Int {
        calls.count
    }

    var first: RecordedConnectorCall? {
        calls.first
    }

    func record(_ call: RecordedConnectorCall) {
        calls.append(call)
    }
}

/// A connector whose every answer is scripted.
struct FakeProviderConnector: AIProviderConnector {
    /// How long ``FakeConnectorAnswer/slow`` parks for. Far beyond any test deadline,
    /// so a passing deadline assertion cannot be luck.
    static let slowSeconds: Double = 30

    let id = "fake"
    let displayName = "Fake"
    let authDescriptor = AuthDescriptor.apiKey(header: "x-fake-key")

    let answer: FakeConnectorAnswer
    let log: ConnectorCallLog

    init(_ answer: FakeConnectorAnswer, log: ConnectorCallLog = ConnectorCallLog()) {
        self.answer = answer
        self.log = log
    }

    func listModels() async throws -> [ModelInfo] {
        [ModelInfo(id: "fake-model")]
    }

    func structuredCompletion(
        schema: JSONSchemaObject,
        instructions: String,
        prompt: String,
        model: String
    ) async throws -> Data {
        let encoded = try? PlaylistQuerySchema.canonicalEncoder().encode(schema)
        await log.record(
            RecordedConnectorCall(
                instructions: instructions,
                prompt: prompt,
                model: model,
                schema: encoded
            )
        )
        switch answer {
        case let .data(data):
            return data
        case let .text(text):
            return Data(text.utf8)
        case let .failure(failure):
            throw failure
        case .slow:
            try await Task.sleep(for: .seconds(Self.slowSeconds))
            throw ConnectorFailure.malformedResponse
        }
    }

    func completion(instructions: String, prompt: String, model: String) async throws -> String {
        await log.record(
            RecordedConnectorCall(
                instructions: instructions,
                prompt: prompt,
                model: model,
                schema: nil
            )
        )
        switch answer {
        case let .data(data):
            return String(bytes: data, encoding: .utf8) ?? ""
        case let .text(text):
            return text
        case let .failure(failure):
            throw failure
        case .slow:
            try await Task.sleep(for: .seconds(Self.slowSeconds))
            throw ConnectorFailure.malformedResponse
        }
    }
}

// MARK: - Fixtures

/// The values every conformer suite builds on.
enum ConnectorConformerFixture {
    /// A deadline short enough that a `slow` answer cannot beat it, long enough that
    /// a scripted one always does.
    static let shortDeadline: TimeInterval = 0.1

    static let locale = Locale(identifier: "en_US")

    static let library = ["Rock", "Jazz", "Ambient"]

    /// A model provider that parks past any test deadline, for proving the deadline
    /// covers credential resolution and not only the transport call.
    ///
    /// Cancellation-COOPERATIVE, as ``AIProviderConnector``'s deadline contract
    /// requires of everything `withDeadline` guards: a cancelled credential read
    /// reports nothing rather than resuming and spending a request the caller has
    /// already stopped waiting for. Swallowing the cancellation instead would still
    /// surface `.timeout` — but the provider call would go out anyway.
    static let slowModel: @Sendable () async -> String? = {
        try? await Task.sleep(for: .seconds(FakeProviderConnector.slowSeconds))
        return Task.isCancelled ? nil : "fake-model"
    }

    /// One structured answer, written the way a provider would.
    static func answer(
        genres: String = "[]",
        yearLowerBound: String = "null",
        yearUpperBound: String = "null",
        moodTags: String = "[]",
        recency: String = "\"none\"",
        seedArtists: String = "[]",
        targetCount: String = "null"
    ) -> Data {
        let json = """
        {"genres":\(genres),"yearLowerBound":\(yearLowerBound),"yearUpperBound":\(yearUpperBound),
         "moodTags":\(moodTags),"tempoLowerBPM":null,"tempoUpperBPM":null,"recency":\(recency),
         "seedArtists":\(seedArtists),"targetCount":\(targetCount)}
        """
        return Data(json.utf8)
    }

    /// A parser over one scripted answer, with the fixture library as its vocabulary.
    static func parser(
        _ answer: FakeConnectorAnswer,
        log: ConnectorCallLog = ConnectorCallLog(),
        model: String? = "fake-model",
        deadlineSeconds: TimeInterval = 5
    ) -> ConnectorQueryParser {
        ConnectorQueryParser(
            connector: FakeProviderConnector(answer, log: log),
            model: { model },
            contextProvider: {
                ConnectorPromptContext(
                    requestText: "REPLACED BY THE PARSER",
                    genreNames: library,
                    artistNames: ["Radiohead"],
                    summary: "In the last month this listener played mostly: Rock."
                )
            },
            deadlineSeconds: deadlineSeconds
        )
    }
}
