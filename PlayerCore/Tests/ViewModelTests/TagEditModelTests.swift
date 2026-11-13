// Tests for the shared tag-edit model (moved from the macOS/iOS shells into
// PlayerCore `ViewModels` — Task 9). These lock the two behaviours that must be
// correct regardless of platform: dirty-only patch construction and
// fill-missing-only auto-fill. Written against the MOVED public API.
import Foundation
import Metadata
import Persistence
import Testing
@testable import ViewModels

struct TagEditModelTests {
    // MARK: - Helpers

    private static func track(
        title: String? = nil,
        album: String? = nil
    ) -> TrackRecord {
        TrackRecord(filePath: "/music/\(UUID().uuidString).flac", title: title, albumTitle: album)
    }

    // MARK: - Batch collapse

    @Test func batchShowsSharedValue() {
        let records = [Self.track(album: "Reign In Blood"), Self.track(album: "Reign In Blood")]
        let form = TagFormModel.batch(records: records)
        let album = form.fields[.album]
        #expect(album?.isMixed == false)
        #expect(album?.text == "Reign In Blood")
    }

    @Test func batchFlagsMixedValues() {
        let records = [Self.track(album: "One"), Self.track(album: "Two")]
        let form = TagFormModel.batch(records: records)
        let album = form.fields[.album]
        #expect(album?.isMixed == true)
        #expect(album?.text.isEmpty == true)
    }

    @Test func collapseTreatsNilAndEmptyAsAbsent() {
        // nil and "" are the same "absent" value → not mixed.
        #expect(TagFormModel.collapse([nil, ""]).isMixed == false)
        #expect(TagFormModel.collapse(["A", "B"]).isMixed == true)
    }

    // MARK: - Dirty-field detection

    @Test func freshFormHasNoChanges() {
        let form = TagFormModel.single(record: Self.track(title: "Angel of Death"), fileMetadata: nil)
        #expect(form.hasChanges == false)
    }

    @Test func editingAFieldMarksItDirtyAndChanged() {
        var form = TagFormModel.single(record: Self.track(title: "Old"), fileMetadata: nil)
        #expect(form.hasChanges == false)
        form.setField(.title, to: "New")
        #expect(form.hasChanges == true)
        #expect(form.fields[.title]?.isDirty == true)
    }

    @Test func settingArtworkAloneMarksChanged() {
        var form = TagFormModel.single(record: Self.track(), fileMetadata: nil)
        form.setArtwork(.remove)
        #expect(form.hasChanges == true)
    }

    // MARK: - Patch construction (dirty-only)

    @Test func untouchedFormProducesEmptyPatch() {
        let form = TagFormModel.single(record: Self.track(title: "Angel of Death"), fileMetadata: nil)
        #expect(form.makePatch().isEmpty)
    }

    @Test func onlyEditedFieldIsWritten() {
        var form = TagFormModel.single(record: Self.track(title: "Old", album: "Album"), fileMetadata: nil)
        form.setField(.title, to: "New")
        let patch = form.makePatch()
        #expect(patch.title == "New")
        #expect(patch.artist == nil)
        #expect(patch.album == nil)
    }

    @Test func numericParsedAndBlankSkipped() {
        var form = TagFormModel.single(record: Self.track(), fileMetadata: nil)
        form.setField(.year, to: "1986")
        form.setField(.trackNumber, to: "")
        let patch = form.makePatch()
        #expect(patch.year == 1986)
        #expect(patch.trackNumber == nil)
    }

    @Test func artworkRemoveClearsAll() {
        var form = TagFormModel.single(record: Self.track(), fileMetadata: nil)
        form.setArtwork(.remove)
        #expect(form.makePatch().artwork == [])
    }

    @Test func artworkReplaceCarriesData() {
        var form = TagFormModel.single(record: Self.track(), fileMetadata: nil)
        let bytes = Data([0xFF, 0xD8, 0xFF])
        form.setArtwork(.replace(data: bytes, mimeType: "image/jpeg"))
        let patch = form.makePatch()
        #expect(patch.artwork?.first?.data == bytes)
        #expect(patch.artwork?.first?.type == .frontCover)
    }

    // MARK: - Auto-fill (fill-missing-only)

    @Test func autoFillFillsOnlyEmptyFields() {
        var form = TagFormModel.single(record: Self.track(title: "Keep Me", album: ""), fileMetadata: nil)
        var lookup = MetadataLookupResult()
        lookup.title = "Override"
        lookup.album = "Filled In"
        lookup.year = 1991
        form.fillMissing(from: lookup)
        // Existing title is preserved and NOT dirtied.
        #expect(form.fields[.title]?.text == "Keep Me")
        #expect(form.fields[.title]?.isDirty != true)
        // Empty album is filled and dirtied.
        #expect(form.fields[.album]?.text == "Filled In")
        #expect(form.fields[.album]?.isDirty == true)
        // Empty year is filled from the Int lookup value.
        #expect(form.fields[.year]?.text == "1991")
    }

    @Test func autoFillNeverOverwritesAMixedBatchThatWasEdited() {
        // A batch "mixed" placeholder counts as empty → gets filled.
        var form = TagFormModel.batch(records: [Self.track(album: "One"), Self.track(album: "Two")])
        #expect(form.fields[.album]?.isMixed == true)
        var lookup = MetadataLookupResult()
        lookup.album = "Chosen"
        form.fillMissing(from: lookup)
        #expect(form.fields[.album]?.text == "Chosen")
        #expect(form.fields[.album]?.isDirty == true)
    }

    @Test func autoFillLeavesAManualEditUntouched() {
        var form = TagFormModel.single(record: Self.track(title: ""), fileMetadata: nil)
        form.setField(.artist, to: "My Band")
        var lookup = MetadataLookupResult()
        lookup.artist = "Some Other Band"
        form.fillMissing(from: lookup)
        #expect(form.fields[.artist]?.text == "My Band")
    }

    // MARK: - Validation edges (not covered above)

    @Test func clearingTitleToEmptyWritesAnEmptyString() {
        var form = TagFormModel.single(record: Self.track(title: "Had A Title"), fileMetadata: nil)
        form.setField(.title, to: "")
        #expect(form.hasChanges == true)
        let patch = form.makePatch()
        #expect(patch.title == "")
        #expect(patch.isEmpty == false)
    }

    @Test func editedValueIsWhitespaceTrimmedInPatch() {
        var form = TagFormModel.single(record: Self.track(), fileMetadata: nil)
        form.setField(.album, to: "  Reign In Blood  ")
        #expect(form.makePatch().album == "Reign In Blood")
    }

    @Test func nonNumericYearIsSkippedAndYieldsEmptyPatch() {
        var form = TagFormModel.single(record: Self.track(), fileMetadata: nil)
        form.setField(.year, to: "not a year")
        #expect(form.hasChanges == true)
        let patch = form.makePatch()
        #expect(patch.year == nil)
        #expect(patch.isEmpty == true)
    }

    @Test func discNumberParsesInPatch() {
        var form = TagFormModel.single(record: Self.track(), fileMetadata: nil)
        form.setField(.discNumber, to: "2")
        #expect(form.makePatch().discNumber == 2)
    }

    @Test func fileMetadataWinsOverRecordInSingleForm() {
        let record = Self.track(title: "DB Title", album: "DB Album")
        let meta = TrackMetadata(title: "File Title", album: "File Album", albumArtist: "File AA", year: 2001)
        let form = TagFormModel.single(record: record, fileMetadata: meta)
        #expect(form.fields[.title]?.text == "File Title")
        #expect(form.fields[.album]?.text == "File Album")
        #expect(form.fields[.albumArtist]?.text == "File AA")
        #expect(form.fields[.year]?.text == "2001")
    }

    @Test func multipleEditedFieldsAllAppearInPatch() {
        var form = TagFormModel.single(record: Self.track(), fileMetadata: nil)
        form.setField(.title, to: "T")
        form.setField(.artist, to: "A")
        form.setField(.genre, to: "Thrash Metal")
        let patch = form.makePatch()
        #expect(patch.title == "T")
        #expect(patch.artist == "A")
        #expect(patch.genre == "Thrash Metal")
        #expect(patch.album == nil)
    }
}
