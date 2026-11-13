#!/usr/bin/env swift
import Foundation

/// Validate declarations emitted by the Swift compiler, rather than guessing
/// render reachability from a source regex. Run after a build with
/// SWIFT_EMIT_LOC_STRINGS=YES and a fresh platform-specific DerivedData directory.
struct Catalog: Decodable {
    let sourceLanguage: String
    let strings: [String: Entry]
}

struct Entry: Decodable {
    let shouldTranslate: Bool?
    let localizations: [String: Localization]?
}

struct Localization: Decodable {
    struct Unit: Decodable { let value: String }
    let stringUnit: Unit?
    let variations: [String: [String: Localization]]?
    let substitutions: [String: Localization]?

    func values(at path: String, issues: inout [String]) -> [String] {
        var result: [String] = []
        if let stringUnit {
            if stringUnit.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append("EMPTY \(path)")
            }
            result.append(stringUnit.value)
        }
        for (axis, variants) in variations ?? [:] {
            if variants.isEmpty { issues.append("EMPTY variations \(path).\(axis)") }
            if axis == "plural", variants["other"] == nil { issues.append("MISSING other plural \(path)") }
            for (variant, child) in variants {
                result += child.values(at: "\(path).\(axis).\(variant)", issues: &issues)
            }
        }
        for (name, child) in substitutions ?? [:] {
            result += child.values(at: "\(path).\(name)", issues: &issues)
        }
        if result.isEmpty { issues.append("EMPTY localization \(path)") }
        return result
    }
}

struct SourceLocation: Decodable { let startingLine: Int? }

struct Extraction: Decodable {
    struct Declaration: Decodable {
        let key: String
        let value: String?
        let location: SourceLocation?
    }

    let source: String
    let tables: [String: [Declaration]]
}

struct LocatedDeclaration {
    let key: String
    let value: String?
    let site: String
}

enum CheckError: Error, CustomStringConvertible {
    case usage, invalidPlatform(String), noExtraction
    var description: String {
        switch self {
        case .usage: "Usage: swift scripts/check-localization.swift <repo-root> <macOS|iOS> <derived-data> [catalog]"
        case let .invalidPlatform(value): "Invalid platform: \(value)"
        case .noExtraction: "No app .stringsdata declarations found; build with SWIFT_EMIT_LOC_STRINGS=YES first."
        }
    }
}

let formatPattern = #"%%|%(?:([1-9][0-9]*)\$)?[-+#0 ']*([0-9]+|\*(?:([1-9][0-9]*)\$)?)?(?:\.([0-9]+|\*(?:([1-9][0-9]*)\$)?))?(hh|ll|[hljztL])?([@diuoxXfFeEgGaAcCsSp])"#
let formatRegex = try NSRegularExpression(pattern: formatPattern)
let positionRegex = try NSRegularExpression(pattern: #"%[1-9][0-9]*\$"#)

func signature(_ value: String) -> [String] {
    let utf16 = value as NSString
    var next = 1
    var result: [String] = []
    for match in formatRegex.matches(in: value, range: NSRange(location: 0, length: utf16.length)) {
        if utf16.substring(with: match.range) == "%%" { continue }
        func argument(_ group: Int, type: String) -> String {
            if match.range(at: group).location != NSNotFound {
                return "\(utf16.substring(with: match.range(at: group))):\(type)"
            }
            defer { next += 1 }
            return "\(next):\(type)"
        }
        for (valueGroup, positionGroup) in [(2, 3), (4, 5)] {
            if match.range(at: valueGroup).location != NSNotFound,
               utf16.substring(with: match.range(at: valueGroup)).hasPrefix("*")
            {
                result.append(argument(positionGroup, type: "d"))
            }
        }
        let length = match.range(at: 6).location == NSNotFound ? "" : utf16.substring(with: match.range(at: 6))
        result.append(argument(1, type: length + utf16.substring(with: match.range(at: 7))))
    }
    return result.sorted()
}

func normalizedDefault(_ value: String) -> String {
    positionRegex.stringByReplacingMatches(
        in: value, range: NSRange(value.startIndex..., in: value), withTemplate: "%"
    )
}

let locales = ["en", "bg", "de", "es", "fr", "it", "ru"]

func validateFlatFormats(key: String, entry: Entry, issues: inout [String]) {
    // Flat entries have an exact typed argument contract. Varied/substituted
    // entries are checked recursively for text and must also compile with
    // xcstringstool; their branches may intentionally omit a singular count.
    if let source = entry.localizations?["en"]?.stringUnit?.value,
       entry.localizations?["en"]?.substitutions == nil
    {
        for locale in locales.dropFirst() {
            guard let unit = entry.localizations?[locale], unit.variations == nil,
                  unit.substitutions == nil, let text = unit.stringUnit?.value else { continue }
            if signature(source) !=
                signature(text)
            {
                issues.append("FORMAT \(key) [\(locale)]: \(signature(text)) expected \(signature(source))")
            }
        }
    }
}

func validateEntry(key: String, entry: Entry, issues: inout [String]) {
    var values: [String: [String]] = [:]
    for locale in locales {
        guard let localization = entry.localizations?[locale] else {
            issues.append("MISSING locale \(key) [\(locale)]")
            continue
        }
        values[locale] = localization.values(at: "\(key)[\(locale)]", issues: &issues)
    }
    if let english = entry.localizations?["en"]?.stringUnit?.value,
       locales.dropFirst().allSatisfy({ locale in
           guard let texts = values[locale], texts.count == 1 else { return false }
           return normalizedDefault(texts[0]) == normalizedDefault(english)
       })
    {
        issues
            .append(
                "UNTRANSLATED \(key): every target locale repeats English; translate it or declare shouldTranslate:false for a technical token"
            )
    }
    validateFlatFormats(key: key, entry: entry, issues: &issues)
}

func loadDeclarations(root: URL, platform: String, derived: URL) throws -> [LocatedDeclaration] {
    let prefixes = ["PlayerCore/Sources/", "\(platform)/Sources/"] +
        (platform == "macOS" ? ["macOS/ExternalOAuth/"] : [])
    var declarations: [LocatedDeclaration] = []
    var hasPlatformSource = false
    var enumerationError: Error?
    guard let enumerator = FileManager.default.enumerator(
        at: derived, includingPropertiesForKeys: nil,
        errorHandler: { _, error in enumerationError = error; return false }
    ) else { throw CheckError.noExtraction }
    for case let file as URL in enumerator where file.pathExtension == "stringsdata" {
        let extraction = try JSONDecoder().decode(Extraction.self, from: Data(contentsOf: file))
        let source = URL(fileURLWithPath: extraction.source).standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: source) else { continue }
        guard prefixes.contains(where: { source.hasPrefix(root.appendingPathComponent($0).path + "/") })
        else { continue }
        if source.hasPrefix(root.appendingPathComponent("\(platform)/Sources").path + "/") {
            hasPlatformSource = true
        }
        for item in extraction.tables["Localizable"] ?? [] where !item.key.isEmpty {
            declarations.append(LocatedDeclaration(
                key: item.key,
                value: item.value,
                site: "\(source):\(item.location?.startingLine ?? 1)"
            ))
        }
    }
    if let enumerationError { throw enumerationError }
    guard !declarations.isEmpty, hasPlatformSource else { throw CheckError.noExtraction }
    return declarations
}

func validateDeclarations(_ declarations: [LocatedDeclaration], catalog: Catalog, issues: inout [String]) {
    var defaults: [String: LocatedDeclaration] = [:]
    for declaration in declarations {
        guard let entry = catalog.strings[declaration.key] else {
            issues.append("MISSING key \(declaration.key) (\(declaration.site))")
            continue
        }
        guard entry.shouldTranslate != false, let value = declaration.value else { continue }
        if let earlier = defaults[declaration.key], let earlierValue = earlier.value,
           normalizedDefault(earlierValue) != normalizedDefault(value) || signature(earlierValue) != signature(value)
        {
            issues.append("CONFLICT \(declaration.key): \(earlier.site) and \(declaration.site)")
        }
        defaults[declaration.key] = declaration
        if let english = entry.localizations?["en"]?.stringUnit?.value,
           normalizedDefault(english) != normalizedDefault(value) || signature(english) != signature(value)
        {
            issues.append("SOURCE \(declaration.key) differs from English catalog (\(declaration.site))")
        }
    }
}

func run() throws -> Int32 {
    let args = Array(CommandLine.arguments.dropFirst())
    guard (3 ... 4).contains(args.count) else { throw CheckError.usage }
    let root = URL(fileURLWithPath: args[0], isDirectory: true).standardizedFileURL
    let platform = args[1]
    guard ["macOS", "iOS"].contains(platform) else { throw CheckError.invalidPlatform(platform) }
    let derived = URL(fileURLWithPath: args[2], isDirectory: true)
    let catalogURL = args.count == 4 ? URL(fileURLWithPath: args[3]) : root
        .appendingPathComponent("\(platform)/Sources/Localizable.xcstrings")
    let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: catalogURL))
    var issues: [String] = []
    if catalog.sourceLanguage != "en" { issues.append("Source language must be en") }
    for (key, entry) in catalog.strings where entry.shouldTranslate != false && !key.isEmpty {
        validateEntry(key: key, entry: entry, issues: &issues)
    }
    let declarations = try loadDeclarations(root: root, platform: platform, derived: derived)
    validateDeclarations(declarations, catalog: catalog, issues: &issues)
    let unique = Set(issues).sorted()
    unique.forEach { print($0) }
    print(
        "\(unique.isEmpty ? "PASS" : "FAIL"): \(platform), \(Set(declarations.map(\.key)).count) compiled keys, \(catalog.strings.count) catalog entries, \(unique.count) issues"
    )
    return unique.isEmpty ? 0 : 1
}

do { try exit(run()) }
catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(2) }
