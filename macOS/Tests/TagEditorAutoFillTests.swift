import Foundation
@testable import MacAMP
import Metadata
import Persistence
import Testing
import ViewModels

@MainActor
@Suite("TagEditorAutoFillTests")
struct TagEditorAutoFillTests {
    @Test("blank fields query the filename-derived artist, title and the record's duration")
    func blankFieldsQueryTheFilenameGuess() async throws {
        let fetcher = MockMetadataFetcher(returning: MetadataLookupResult(album: "A Night at the Opera"))
        let model = try makeModel(
            filePath: "/Music/Queen - Bohemian Rhapsody.mp3",
            duration: 354,
            fetcher: fetcher
        )

        let didFill = await model.autoFill()

        #expect(didFill)
        #expect(fetcher.queries == [MockMetadataFetcher.Query(
            artist: "Queen",
            title: "Bohemian Rhapsody",
            album: nil,
            duration: 354
        )])
    }

    @Test("a typed artist wins over the filename guess for that field alone")
    func typedArtistWinsOverTheFilenameGuess() async throws {
        let fetcher = MockMetadataFetcher(returning: MetadataLookupResult(album: "Greatest Hits"))
        let model = try makeModel(
            filePath: "/Music/Queen - Bohemian Rhapsody.mp3",
            duration: 354,
            fetcher: fetcher
        )
        model.setField(.artist, to: "  Freddie Mercury  ")

        _ = await model.autoFill()

        #expect(fetcher.queries == [MockMetadataFetcher.Query(
            artist: "Freddie Mercury",
            title: "Bohemian Rhapsody",
            album: nil,
            duration: 354
        )])
    }

    @Test("both fields typed leave the filename guess entirely unused")
    func typedFieldsLeaveTheGuessUnused() async throws {
        let fetcher = MockMetadataFetcher(returning: MetadataLookupResult(genre: "Thrash Metal"))
        let model = try makeModel(
            filePath: "/Music/Queen - Bohemian Rhapsody.mp3",
            duration: 354,
            fetcher: fetcher
        )
        model.setField(.artist, to: "Slayer")
        model.setField(.title, to: "Angel of Death")

        _ = await model.autoFill()

        #expect(fetcher.queries == [MockMetadataFetcher.Query(
            artist: "Slayer",
            title: "Angel of Death",
            album: nil,
            duration: 354
        )])
    }

    @Test("an unguessable path with blank fields returns false without asking the network")
    func unguessablePathNeverReachesTheFetcher() async throws {
        let fetcher = MockMetadataFetcher(returning: MetadataLookupResult(title: "Never Used"))
        let model = try makeModel(filePath: "/Music/", duration: 354, fetcher: fetcher)

        let didFill = await model.autoFill()

        #expect(didFill == false)
        #expect(fetcher.lookupCount == 0)
        #expect(model.isAutoFilling == false)
    }

    @Test("a match fills only the fields that were still empty")
    func matchFillsOnlyTheEmptyFields() async throws {
        let fetcher = MockMetadataFetcher(returning: MetadataLookupResult(
            title: "Overwritten?",
            artist: "Resolved Artist",
            album: "A Night at the Opera",
            year: 1975
        ))
        let model = try makeModel(
            filePath: "/Music/Queen - Bohemian Rhapsody.mp3",
            duration: 354,
            fetcher: fetcher
        )
        model.setField(.title, to: "Bohemian Rhapsody")

        let didFill = await model.autoFill()

        #expect(didFill)
        #expect(model.form.fields[.title]?.text == "Bohemian Rhapsody")
        #expect(model.form.fields[.artist]?.text == "Resolved Artist")
        #expect(model.form.fields[.album]?.text == "A Night at the Opera")
        #expect(model.form.fields[.year]?.text == "1975")
    }

    @Test("a delimiter-less filename queries a title with no artist")
    func delimiterlessFilenameQueriesTitleOnly() async throws {
        let fetcher = MockMetadataFetcher(returning: MetadataLookupResult(artist: "Nena"))
        let model = try makeModel(filePath: "/Music/99 Luftballons.m4a", duration: 232, fetcher: fetcher)

        _ = await model.autoFill()

        #expect(fetcher.queries == [MockMetadataFetcher.Query(
            artist: nil,
            title: "99 Luftballons",
            album: nil,
            duration: 232
        )])
    }

    private func makeModel(
        filePath: String,
        duration: Double,
        fetcher: MockMetadataFetcher
    ) throws -> TagEditorViewModel {
        let database = try AppDatabase.makeEmpty()
        return TagEditorViewModel(
            records: [TrackRecord(filePath: filePath, duration: duration)],
            database: database,
            metadataFetcher: fetcher
        )
    }
}
