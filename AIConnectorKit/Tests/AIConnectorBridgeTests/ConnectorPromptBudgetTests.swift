import AIConnectorBridge
import AIConnectorKit
import Foundation
import Services
import Testing

/// The payload budget is a privacy promise the consent sheet quotes verbatim, so it
/// is pinned here as numbers AND as behaviour: the caps themselves, the ordering rule
/// that decides what survives them, and the guarantee that going over budget truncates
/// rather than failing.
@Suite("ConnectorPromptBudgetBridgeTests")
struct ConnectorPromptBudgetTests {
    private static let english = Locale(identifier: "en_US")

    // MARK: The numbers

    @Test("The budget constants are the ADR's four numbers, from one source")
    func budgetConstantsMatchTheADR() {
        #expect(ConnectorPayloadBudget.maxRequestCharacters == 600)
        #expect(ConnectorPayloadBudget.maxGenres == 64)
        #expect(ConnectorPayloadBudget.maxArtists == 50)
        #expect(ConnectorPayloadBudget.maxSerializedBodyBytes == 16 * 1024)
        // Derived from the on-device tier rather than copied, so the two cannot drift.
        #expect(ConnectorPayloadBudget.maxNameLength == AssistantLibraryContext.maxNameLength)
        #expect(ConnectorPayloadBudget.maxSummaryCharacters == AssistantLibraryContext.maxSummaryLength)
    }

    // MARK: The 5000-genre fixture

    @Test("A 5000-genre library sends exactly 64 genres in a body under 16 KiB")
    func fiveThousandGenresTruncateToTheCap() {
        let built = ConnectorPromptBuilder.build(Self.hugeLibrary(), locale: Self.english)
        #expect(built.genres.count == ConnectorPayloadBudget.maxGenres)
        #expect(built.serializedByteCount < ConnectorPayloadBudget.maxSerializedBodyBytes)
        #expect(built.truncation.droppedGenres == 5000 - 64)
        #expect(built.truncation.didTruncate)
        #expect(built.truncation.isOverBudget == false)
        #expect(built.prompt == "something for a long drive")
    }

    @Test("The 64 kept genres are the 64 most frequent, most frequent first")
    func truncationKeepsTheMostFrequentEntries() {
        let built = ConnectorPromptBuilder.build(Self.hugeLibrary(), locale: Self.english)
        // Counts ascend with the index, so the tail of the input is the head of the
        // ranking — proving the selection is by frequency and not by arrival order.
        let expected = (4936 ..< 5000).reversed().map { Self.name("Genre", $0) }
        #expect(built.genres == expected)
    }

    @Test("The same library selects the same 64 whatever order it arrives in")
    func truncationIsDeterministic() {
        let forwards = ConnectorPromptBuilder.build(Self.hugeLibrary(), locale: Self.english)
        let again = ConnectorPromptBuilder.build(Self.hugeLibrary(), locale: Self.english)
        var reversedContext = Self.hugeLibrary()
        reversedContext.genres.reverse()
        let backwards = ConnectorPromptBuilder.build(reversedContext, locale: Self.english)

        #expect(forwards == again)
        #expect(backwards.genres == forwards.genres)
        #expect(backwards.serializedByteCount == forwards.serializedByteCount)
    }

    @Test("With no frequency signal the caller's own order is the ranking")
    func equalCountsPreserveInputOrder() {
        let context = ConnectorPromptContext(requestText: "hi", genreNames: Self.names("Genre", 100))
        let built = ConnectorPromptBuilder.build(context, locale: Self.english)
        #expect(built.genres == Self.names("Genre", 64))
    }

    // MARK: The other three caps

    @Test("A long request is clipped to 600 characters, never refused")
    func requestTextIsCappedAtSixHundredCharacters() {
        let context = ConnectorPromptContext(requestText: String(repeating: "a", count: 2000))
        let built = ConnectorPromptBuilder.build(context, locale: Self.english)
        #expect(built.prompt.count == ConnectorPayloadBudget.maxRequestCharacters)
        #expect(built.truncation.droppedRequestCharacters == 1400)
    }

    @Test("Artists are capped at 50")
    func artistsAreCappedAtFifty() {
        let context = ConnectorPromptContext(
            requestText: "more like this",
            genreNames: [],
            artistNames: Self.names("Artist", 300)
        )
        let built = ConnectorPromptBuilder.build(context, locale: Self.english)
        #expect(built.artists.count == ConnectorPayloadBudget.maxArtists)
        #expect(built.truncation.droppedArtists == 250)
    }

    @Test("The summary is clipped to its own cap")
    func summaryIsCapped() {
        let context = ConnectorPromptContext(
            requestText: "hi",
            genreNames: [],
            artistNames: [],
            summary: String(repeating: "s", count: 900)
        )
        let built = ConnectorPromptBuilder.build(context, locale: Self.english)
        #expect(built.truncation.droppedSummaryCharacters == 900 - ConnectorPayloadBudget.maxSummaryCharacters)
    }

    // MARK: Name hygiene

    @Test("An over-long name is dropped, never truncated, and does not spend a slot")
    func overLongNamesAreDroppedNotTruncated() {
        let corrupt = String(repeating: "x", count: 5000)
        var genres = [AssistantNameCount(name: corrupt, count: 9_999_999)]
        genres += Self.names("Genre", 64).map { AssistantNameCount(name: $0, count: 1) }
        let built = ConnectorPromptBuilder.build(
            ConnectorPromptContext(requestText: "hi", genres: genres),
            locale: Self.english
        )
        // DROP FIRST, cap second: the corrupt tag never occupies one of the 64 slots,
        // and no truncated prefix of it reaches the vocabulary.
        #expect(built.genres.count == 64)
        #expect(built.genres == Self.names("Genre", 64))
        #expect(built.instructions.contains("xxxx") == false)
    }

    @Test("Blank and whitespace-only names are dropped")
    func blankNamesAreDropped() {
        let context = ConnectorPromptContext(requestText: "hi", genreNames: ["", "   ", " Rock ", "Jazz"])
        let built = ConnectorPromptBuilder.build(context, locale: Self.english)
        #expect(built.genres == ["Rock", "Jazz"])
        #expect(built.truncation.droppedGenres == 2)
    }

    // MARK: Under budget, and the backstop

    @Test("A small library passes through untouched")
    func underBudgetContextIsNotTruncated() {
        let context = ConnectorPromptContext(
            requestText: "90s rock",
            genreNames: ["Rock", "Jazz"],
            artistNames: ["Radiohead"],
            summary: "In the last month this listener played mostly: Rock."
        )
        let built = ConnectorPromptBuilder.build(context, locale: Self.english)
        #expect(built.truncation.didTruncate == false)
        #expect(built.truncation.isOverBudget == false)
        #expect(built.genres == ["Rock", "Jazz"])
        #expect(built.artists == ["Radiohead"])
    }

    @Test("The byte backstop drops the genre tail before it touches the artists")
    func byteBackstopShrinksGenresFirst() {
        let context = ConnectorPromptContext(
            requestText: "something long and specific",
            genreNames: Self.names("A rather long genre name", 64),
            artistNames: Self.names("Artist", 50)
        )
        let roomy = ConnectorPromptBuilder.build(context, locale: Self.english)
        #expect(roomy.genres.count == 64)

        // Inflate the fixed cost until the genre line no longer fits whole.
        let headroom = ConnectorPayloadBudget.maxSerializedBodyBytes - roomy.serializedByteCount
        let squeezed = ConnectorPromptBuilder.build(
            context,
            locale: Self.english,
            schemaByteCount: PlaylistQuerySchema.canonicalByteCount + headroom + 200
        )
        #expect(squeezed.genres.count < 64)
        #expect(squeezed.genres.isEmpty == false)
        #expect(squeezed.artists.count == 50, "artists outlive the genre surplus")
        #expect(squeezed.serializedByteCount <= ConnectorPayloadBudget.maxSerializedBodyBytes)
        #expect(squeezed.truncation.isOverBudget == false)
    }

    @Test("An impossible budget still returns a prompt carrying the listener's words")
    func impossibleBudgetTruncatesRatherThanFailing() {
        let context = ConnectorPromptContext(
            requestText: "moody piano for a rainy afternoon",
            genreNames: Self.names("Genre", 64),
            artistNames: Self.names("Artist", 50),
            summary: "In the last month this listener played mostly: Piano."
        )
        let built = ConnectorPromptBuilder.build(
            context,
            locale: Self.english,
            schemaByteCount: ConnectorPayloadBudget.maxSerializedBodyBytes
        )
        #expect(built.genres.isEmpty)
        #expect(built.artists.isEmpty)
        #expect(built.truncation.isOverBudget)
        // The one thing that is never sacrificed.
        #expect(built.prompt == "moody piano for a rainy afternoon")
        #expect(built.instructions.contains("Answer with JSON only"))
    }

    // MARK: Instructions

    @Test("Instructions carry the JSON-only rule, the locale and the bounded vocabulary")
    func instructionsCarryTheVocabulary() {
        let context = ConnectorPromptContext(
            requestText: "90s rock",
            genreNames: ["Rock", "Jazz"],
            artistNames: ["Radiohead"],
            summary: "In the last month this listener played mostly: Rock."
        )
        let built = ConnectorPromptBuilder.build(context, locale: Self.english)
        #expect(built.instructions.contains("Answer with JSON only"))
        #expect(built.instructions.contains("The request is written in en_US."))
        #expect(built.instructions.contains("Choose genres ONLY from this library's genres: Rock, Jazz."))
        #expect(built.instructions.contains("Artists in this library include: Radiohead."))
        #expect(built.instructions.contains("In the last month this listener played mostly: Rock."))
    }

    @Test("An empty context yields instructions with no dangling vocabulary lines")
    func emptyContextInstructionsAreClean() {
        let built = ConnectorPromptBuilder.build(
            ConnectorPromptContext(requestText: "anything"),
            locale: Self.english
        )
        #expect(built.instructions.contains("Choose genres") == false)
        #expect(built.instructions.contains("Artists in this library") == false)
        #expect(built.serializedByteCount < ConnectorPayloadBudget.maxSerializedBodyBytes)
    }

    @Test("The on-device context is already inside this budget, so routing it truncates nothing")
    func libraryContextConvenienceNeverTruncates() {
        let library = AssistantLibraryContext(
            genres: Self.names("Genre", 200),
            artists: Self.names("Artist", 200),
            summary: "In the last month this listener played mostly: Rock."
        )
        let built = ConnectorPromptBuilder.build(
            ConnectorPromptContext(requestText: "90s rock", library: library),
            locale: Self.english
        )
        #expect(built.genres.count == AssistantLibraryContext.maxGenres)
        #expect(built.artists.count == AssistantLibraryContext.maxArtists)
        #expect(built.truncation.didTruncate == false)
    }

    // MARK: Fixtures

    private static func name(_ stem: String, _ index: Int) -> String {
        "\(stem)-\(String(format: "%04d", index))"
    }

    private static func names(_ stem: String, _ count: Int) -> [String] {
        (0 ..< count).map { name(stem, $0) }
    }

    /// 5000 genres whose counts ascend with their index, so "most frequent" and "first
    /// in the input" point in opposite directions.
    private static func hugeLibrary() -> ConnectorPromptContext {
        ConnectorPromptContext(
            requestText: "something for a long drive",
            genres: (0 ..< 5000).map { AssistantNameCount(name: name("Genre", $0), count: $0) },
            artists: [],
            summary: ""
        )
    }
}
