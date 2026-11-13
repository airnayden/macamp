// WebSearchTool — the one BUILT-IN tool this kit publishes, over Tavily's search
// endpoint.
//
// ── WHY A BUILT-IN TOOL LIVES IN THE KIT AND NOT IN THE SHELL ────────────────
//
// It performs an HTTP round-trip, and `URLSession` exists in exactly one
// directory in this repository — this one (see `HTTPTransport.swift`'s header and
// `scripts/check-ai-network-boundary.sh`). A web-search tool written in the shell
// would either duplicate the transport outside the boundary or reach back through
// it; both are the thing that guard exists to forbid. So the tool is built here,
// against the same ``HTTPTransport`` seam every connector uses, and the shell only
// decides WHETHER to publish it.
//
// It is NOT an MCP tool and must never be merged into that list: `mcp__` is a
// namespace that marks "somebody else's code" (see `MCPToolProjection`'s header),
// and this is MacAMP's own code calling a documented HTTP API. The name is the
// bare `web_search`.
//
// ── KEYLESS BY DEFAULT, KEYED WHEN A KEY EXISTS ──────────────────────────────
//
// Tavily publishes a keyless access mode (`X-Tavily-Access-Mode: keyless`,
// docs.tavily.com/documentation/keyless) alongside ordinary bearer auth. Keyless
// is the DEFAULT here because the feature must work for a listener who never
// pasted a key; a key, when one is stored, simply upgrades the same request. The
// credential arrives through an `async` PROVIDER rather than as a stored string —
// the same discipline as ``AnthropicAuth`` — so it is read at call time and never
// sits in a value type that could be logged. Unlike that type the provider is
// OPTIONAL and non-throwing: "there is no key" is the expected state, not a
// failure, and the honest answer to it is a keyless request.
//
// NOTHING on this path is logged. Not the query, not a title, not a URL, and
// least of all the key.
//
// ── EVERY FAILURE IS A SENTENCE, INCLUDING THE ONES WE HAVE NOT SEEN ─────────
//
// ``AITool/execute`` cannot throw (see its header: "A tool result is
// CONVERSATION, not control flow"), so a provider error is only ever observable to
// the model as text. Tavily documents four statuses worth distinguishing — 401 bad
// or missing key, 429 rate limit, 432 plan limit, 433 pay-as-you-go limit — and
// each gets its own model-actionable sentence.
//
// The CATCH-ALL is load-bearing rather than defensive boilerplate: scripted tests
// cannot falsify a provider's real wire shapes, so any other non-2xx status, and
// any body that will not parse, must land somewhere that says so out loud instead
// of being mistaken for one of the four. An error `code` in the body, when the
// provider sends one, is appended verbatim — flattened and clamped, because it is
// still provider-controlled text.
//
// ── UNTRUSTED TEXT, TREATED AS TEXT ──────────────────────────────────────────
//
// Titles and snippets are attacker-controlled: anyone can publish a page. They are
// never interpolated into anything executable — the answer is a plain list of
// rows — and every field is FLATTENED (whitespace and control characters collapsed
// to single spaces) before rendering, so a snippet carrying newlines cannot forge
// extra rows and pass its own content off as search results. Snippets are cut at
// ``snippetCharacterLimit`` and the whole answer at ``resultCharacterLimit``, the
// same 8 KB cloud figure `MCPToolProjection.resultCharacterLimit` mirrors, spelled
// here as a KIT-LOCAL constant because this kit must not import PlayerCore.
import Foundation

/// The built-in `web_search` tool: a bounded web lookup rendered as text rows.
public struct WebSearchTool: Sendable {
    /// The frozen wire name. See the file header for why it carries no prefix.
    public static let toolName = "web_search"

    /// One short sentence, stating what the tool RETURNS — billed on every
    /// provider round, exactly like every other ``AITool/description``.
    public static let toolDescription =
        "Returns current web search results as rows of title, URL and a short snippet."

    /// The production endpoint.
    public static let endpointURL: URL = {
        guard let url = URL(string: "https://api.tavily.com/search") else {
            // A compile-time constant. A nil here is a typo in this file, not a
            // runtime condition any caller could recover from.
            preconditionFailure("The web search endpoint literal is malformed.")
        }
        return url
    }()

    /// The header that selects keyless access, and its only accepted value.
    public static let keylessHeaderField = "X-Tavily-Access-Mode"
    public static let keylessHeaderValue = "keyless"

    /// Characters one whole answer may occupy. See the file header.
    public static let resultCharacterLimit = 8 * 1024

    /// Characters one hit's snippet may occupy.
    public static let snippetCharacterLimit = 200

    /// Characters one hit's title may occupy — a title is a label, not a payload.
    public static let titleCharacterLimit = 160

    /// Characters a provider error code may occupy once appended to a sentence.
    public static let errorCodeCharacterLimit = 64

    /// How many hits are requested when the model does not say.
    public static let defaultMaxResults = 5

    /// The range the model may ask inside. Tavily documents 0–20 with a default of
    /// 10; this bounds tighter, because a chat turn pays for every row twice — once
    /// as tool output, once as context on the next round.
    public static let minimumMaxResults = 1
    public static let maximumMaxResults = 10

    /// Seconds one whole call — credential read and round-trip together — may take.
    /// The same budget `ConnectorProbe` uses, for the same reason.
    public static let defaultDeadlineSeconds: TimeInterval = 20

    /// Appended to text a size clamp had to cut.
    ///
    /// Read from the loop rather than restated so the clamps on this path can never
    /// disagree about what a truncated answer looks like.
    public static let truncationMarker = ToolLoopEngine.truncationMarker

    private let transport: any HTTPTransport
    private let deadlineSeconds: TimeInterval
    private let apiKeyProvider: @Sendable () async -> String?

    /// - Parameters:
    ///   - transport: Injectable so the whole contract is testable without a
    ///     socket; defaults to the shipped `URLSession` transport.
    ///   - deadlineSeconds: The budget for one call.
    ///   - apiKeyProvider: Answers the stored key, or `nil` for keyless access.
    ///     Non-throwing: a key that cannot be read is a key the listener does not
    ///     have, and the honest response is a keyless request rather than a
    ///     failure sentence.
    public init(
        transport: any HTTPTransport = URLSessionTransport(),
        deadlineSeconds: TimeInterval = WebSearchTool.defaultDeadlineSeconds,
        apiKeyProvider: @escaping @Sendable () async -> String? = { nil }
    ) {
        self.transport = transport
        self.deadlineSeconds = deadlineSeconds
        self.apiKeyProvider = apiKeyProvider
    }

    /// This search, as the tool a provider is handed.
    public var tool: AITool {
        AITool(
            name: Self.toolName,
            description: Self.toolDescription,
            parametersSchema: Self.parametersSchema
        ) { argumentsJSON in
            await run(argumentsJSON: argumentsJSON)
        }
    }

    /// Runs one search, turning every failure into a sentence.
    func run(argumentsJSON: String) async -> AIToolOutput {
        guard let arguments = Self.arguments(from: argumentsJSON) else {
            return AIToolOutput(text: Sentence.invalidArguments)
        }
        let apiKey = await Self.usableKey(apiKeyProvider())
        do {
            let request = try Self.urlRequest(for: arguments, apiKey: apiKey)
            let transport = transport
            let response = try await withDeadline(seconds: deadlineSeconds) {
                try await transport.send(request)
            }
            return Self.output(for: response)
        } catch let failure as ConnectorFailure {
            return AIToolOutput(text: Self.sentence(for: failure))
        } catch is CancellationError {
            return AIToolOutput(text: Sentence.cancelled)
        } catch {
            // Unreachable through the shipped transport, which throws only
            // `ConnectorFailure`. Mapped rather than trapped so a foreign conformer
            // degrades to prose instead of taking the turn down.
            return AIToolOutput(text: Sentence.unreachable)
        }
    }
}

// MARK: - Sentences

public extension WebSearchTool {
    /// Every answer this tool can give that is not a list of results.
    ///
    /// English and never localized, for the same reason `MCPClientFailure`'s are:
    /// this text is read by a model, not by a listener, so it is not catalog copy.
    enum Sentence {
        /// The model's arguments did not carry a usable query.
        public static let invalidArguments =
            "The web search tool needs a non-empty query string in its arguments."
        /// The search ran and found nothing.
        public static let noResults =
            "The web search returned no results for that query."
        /// HTTP 401.
        public static let keyRejected =
            "The web search provider rejected the configured API key; "
                + "a valid key must be set, or the key removed to fall back to keyless search."
        /// HTTP 429.
        public static let rateLimited =
            "The web search provider is rate-limiting requests; wait a moment before searching again."
        /// HTTP 432.
        public static let planLimitReached =
            "The web search provider's plan limit has been reached, "
                + "so no more searches are available until the plan resets or is upgraded."
        /// HTTP 433.
        public static let payAsYouGoLimitReached =
            "The web search provider's pay-as-you-go spending limit has been reached, "
                + "so no more searches are available until that limit is raised."
        /// Any other non-2xx status, and any body that will not parse. See the file
        /// header for why this exists and is not a bug.
        public static let unrecognisedProviderError =
            "The web search provider returned an unrecognised error."
        /// The deadline elapsed.
        public static let timedOut =
            "The web search provider did not answer in time."
        /// The endpoint could not be reached at all.
        public static let unreachable =
            "The web search provider is not reachable."
        /// The caller stopped caring.
        public static let cancelled =
            "The web search was cancelled."
    }
}

// MARK: - Schema and arguments

public extension WebSearchTool {
    /// The arguments document, carried verbatim to every provider.
    ///
    /// Written as raw JSON rather than through ``JSONSchemaObject`` for the reason
    /// ``AIJSONValue``'s header gives: a schema builder cannot express the
    /// `minimum` / `maximum` bounds this tool documents, and dropping them would
    /// let the model ask for a hundred rows.
    static let parametersSchema = AIJSONValue.object([
        "type": .string("object"),
        "properties": .object([
            "query": .object([
                "type": .string("string"),
                "description": .string("What to search the web for."),
            ]),
            "max_results": .object([
                "type": .string("integer"),
                "minimum": .int(minimumMaxResults),
                "maximum": .int(maximumMaxResults),
                "description": .string("How many results to return. Defaults to \(defaultMaxResults)."),
            ]),
            "site": .object([
                "type": .string("string"),
                "description": .string("Restrict the search to one domain, for example wikipedia.org."),
            ]),
        ]),
        "required": .array([.string("query")]),
        "additionalProperties": .bool(false),
    ])
}

extension WebSearchTool {
    /// One validated call. Built only from arguments that survived every bound, so
    /// nothing downstream re-checks them.
    struct Arguments: Equatable {
        var query: String
        var maxResults: Int
        var site: String?
    }

    /// Reads the model's raw argument text, or `nil` when it carries no query.
    ///
    /// Tolerant on everything except the query: an out-of-range `max_results` is
    /// clamped and a non-string `site` is ignored, because refusing the whole call
    /// over a recoverable argument spends a round to teach the model nothing.
    static func arguments(from argumentsJSON: String) -> Arguments? {
        guard let object = AIJSONValue.parsed(argumentsJSON)?.objectValue else { return nil }
        let query = flattened(object["query"]?.stringValue ?? "")
        guard query.isEmpty == false else { return nil }
        let requested = object["max_results"]?.intValue ?? defaultMaxResults
        let site = flattened(object["site"]?.stringValue ?? "")
        return Arguments(
            query: query,
            maxResults: min(max(requested, minimumMaxResults), maximumMaxResults),
            site: site.isEmpty ? nil : site
        )
    }

    /// A key worth sending, or `nil`. A blank key is not a key: sending it spends a
    /// round-trip to be told 401, which reads as "your key expired" rather than
    /// "you never entered one".
    static func usableKey(_ candidate: String?) -> String? {
        guard let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false
        else { return nil }
        return trimmed
    }
}
