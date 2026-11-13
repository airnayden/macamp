#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/macamp-localization.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/repo/macOS/Sources" "$SCRATCH/derived"
cat > "$SCRATCH/fixture.swift" <<'SWIFT'
import Foundation
let base = URL(fileURLWithPath: CommandLine.arguments[1])
let scenario = CommandLine.arguments[2]
let locales = ["en", "bg", "de", "es", "fr", "it", "ru"]
var units: [String: Any] = [:]
for locale in locales {
    let value = locale == "en" ? "%@ has %lld tracks" : "%2$lld titles by %1$@"
    units[locale] = ["stringUnit": ["state": "translated", "value": value]]
}
if scenario == "missing-locale" { units.removeValue(forKey: "bg") }
if scenario == "bad-format" { units["de"] = ["stringUnit": ["value": "%@ has %@ tracks"]] }
if scenario == "empty-variation" { units["ru"] = ["variations": ["plural": ["one": ["stringUnit": ["value": ""]]]]] }
if scenario == "untranslated-stub" {
    for locale in locales { units[locale] = ["stringUnit": ["value": "%@ has %lld tracks"]] }
}
if scenario == "positional-stub" {
    for locale in locales.dropFirst() { units[locale] = ["stringUnit": ["value": "%1$@ has %2$lld tracks"]] }
}
if scenario == "star-format" || scenario == "missing-star" {
    for locale in locales {
        let value = locale == "en" ? "Value %*.*f" : (scenario == "missing-star" ? "Wert %3$f" : "Wert %3$*1$.*2$f")
        units[locale] = ["stringUnit": ["value": value]]
    }
}
if scenario == "bad-source-position" {
    units["en"] = ["stringUnit": ["value": "%2$@ has %1$lld tracks"]]
}
var entry: [String: Any] = ["localizations": units]
if scenario == "not-translatable" { entry = ["shouldTranslate": false] }
let catalog: [String: Any] = ["sourceLanguage": "en", "strings": scenario == "missing-key" ? [:] : ["app.fixture": entry]]
try JSONSerialization.data(withJSONObject: catalog).write(to: base.appendingPathComponent("catalog.json"))
var declarations: [[String: Any]] = [["key": "app.fixture", "value": "%@ has %lld tracks", "location": ["startingLine": 7]]]
if scenario == "star-format" || scenario == "missing-star" { declarations[0]["value"] = "Value %*.*f" }
if scenario == "conflict" { declarations.append(["key": "app.fixture", "value": "Different default"]) }
if scenario == "normalized-default" { declarations.append(["key": "app.fixture", "value": "%1$@ has %2$lld tracks"]) }
let source = base.appendingPathComponent(scenario == "no-extraction" ? "repo/Dependency/External.swift" : "repo/macOS/Sources/Fixture.swift").path
try "// Fixture source".write(toFile: base.appendingPathComponent("repo/macOS/Sources/Fixture.swift").path, atomically: true, encoding: .utf8)
let extraction: [String: Any] = ["source": source, "tables": ["Localizable": declarations]]
try JSONSerialization.data(withJSONObject: extraction).write(to: base.appendingPathComponent("derived/Fixture.stringsdata"))
SWIFT
# Compile once so every negative case runs the actual guard without repeated JIT work.
swiftc "$ROOT/scripts/check-localization.swift" -o "$SCRATCH/check"
swiftc "$SCRATCH/fixture.swift" -o "$SCRATCH/fixture"
for scenario in valid normalized-default not-translatable star-format missing-star missing-locale missing-key bad-format bad-source-position untranslated-stub positional-stub empty-variation conflict no-extraction; do
    "$SCRATCH/fixture" "$SCRATCH" "$scenario"
    expected=1
    case "$scenario" in valid|normalized-default|not-translatable|star-format) expected=0 ;; no-extraction) expected=2 ;; esac
    actual=0
    "$SCRATCH/check" "$SCRATCH/repo" macOS "$SCRATCH/derived" "$SCRATCH/catalog.json" > "$SCRATCH/result.log" 2>&1 || actual=$?
    if [[ "$actual" -ne "$expected" ]]; then
        cat "$SCRATCH/result.log"
        echo "FAIL $scenario: exit $actual, expected $expected" >&2
        exit 1
    fi
    echo "PASS $scenario: exit $actual"
done
