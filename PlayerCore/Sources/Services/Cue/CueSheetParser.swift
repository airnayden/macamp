// CueSheetParser — the public entry point for reading a `.cue` sheet.
//
// Two passes behind one call: `CueSheetDraft` accumulates what the sheet says, then
// `CueSheetResolver` normalizes it into playable segments.
//
// # Hard boundaries
// This parser NEVER decodes audio and NEVER enters the metadata-read path. A cue sheet is
// not an audio file; the only thing it does with the filesystem is ask
// ``CueAudioFileLocating`` whether a referenced file exists. Everything else is text.
import Foundation

/// Reads CUE sheets into ``CueSheet`` values.
public enum CueSheetParser {
    /// The `.cue` path extension, lower-cased — the one spelling the scanner matches on.
    public static let pathExtension = "cue"

    /// Parses sheet text that has already been read.
    ///
    /// - Parameters:
    ///   - contents: the sheet's text.
    ///   - sheetURL: where the sheet lives. Its directory is what `FILE` operands
    ///     resolve against, and its path becomes ``CueSheet/sheetPath``.
    ///   - locator: the filesystem seam. Injectable so the grammar is testable with no
    ///     audio on disk.
    public static func parse(
        contents: String,
        sheetURL: URL,
        locator: any CueAudioFileLocating = FileManagerCueAudioFileLocator()
    ) throws -> CueSheet {
        var draft = CueSheetDraft()
        for statement in CueLineScanner.statements(in: contents) {
            try draft.apply(statement)
        }
        return try CueSheetResolver.resolve(draft: draft, sheetURL: sheetURL, locator: locator)
    }

    /// Reads and parses a `.cue` file.
    public static func parse(
        sheetURL: URL,
        locator: any CueAudioFileLocating = FileManagerCueAudioFileLocator()
    ) throws -> CueSheet {
        try parse(contents: decodeText(at: sheetURL), sheetURL: sheetURL, locator: locator)
    }

    /// Decodes a sheet's bytes to text.
    ///
    /// Cue sheets predate UTF-8 as a default and are routinely written by Windows
    /// rippers in the system code page, so UTF-8 is tried first, then UTF-16 when a BOM
    /// says so, then Windows-1252, then Latin-1. The last candidate maps every byte, so
    /// a readable file always yields text — a sheet is never refused over its encoding.
    static func decodeText(at url: URL) throws -> String {
        guard let data = try? Data(contentsOf: url) else {
            throw CueParseError.unreadableSheet(path: url.path)
        }
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        if hasUTF16BOM(data), let text = String(data: data, encoding: .utf16) {
            return text
        }
        if let text = String(data: data, encoding: .windowsCP1252) {
            return text
        }
        guard let text = String(data: data, encoding: .isoLatin1) else {
            throw CueParseError.unreadableSheet(path: url.path)
        }
        return text
    }

    private static func hasUTF16BOM(_ data: Data) -> Bool {
        guard data.count >= 2 else {
            return false
        }
        let prefix = [UInt8](data.prefix(2))
        return prefix == [0xFF, 0xFE] || prefix == [0xFE, 0xFF]
    }
}
