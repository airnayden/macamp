---
title: MacAMP — Translation Review Tracker
description: Coverage checks and honest review status for the shipped String Catalogs.
---

# Translation Review Tracker

Every non-English translation is an AI draft pending native-speaker review. No
locale has human sign-off. English is the authored source; compiler and format
checks establish coverage, not linguistic quality.

## Catalog coverage

| Catalog | Entries | Scope |
|---|---:|---|
| `macOS/Sources/Localizable.xcstrings` | 1404 | macOS shell and compiled shared-core declarations |
| `iOS/Sources/Localizable.xcstrings` | 240 | iOS shell and compiled shared-core declarations |

Counts include explicit nontranslation entries. All translatable entries carry
`en`, `bg`, `de`, `es`, `fr`, `it`, and `ru`. Technical names, format-only
joiners, the `#` column heading, and the unused locale-registration key declare
`shouldTranslate: false`. `MacAMP`, `ReplayGain`, codec names, and provider brands
retain their spelling. Existing translations were preserved; new and repaired
non-English units use `needs_review`.

The November 2026 remediation added missing compiler-extracted declarations and
replaced English text copied into all six translation slots. Repeated English
is accepted only under an explicit nontranslation policy. Shared keys must have
the same English default in both catalogs. Short tag labels have separate keys
from the full Track Number and Disc Number editor labels.

## Review status

| Locale | Status | Native reviewer | Review date |
|---|---|---|---|
| `en` | Authored source; compiled defaults checked | — | — |
| `bg` | AI draft; native review pending | Unassigned | Pending |
| `de` | AI draft; native review pending | Unassigned | Pending |
| `es` | AI draft; native review pending | Unassigned | Pending |
| `fr` | AI draft; native review pending | Unassigned | Pending |
| `it` | AI draft; native review pending | Unassigned | Pending |
| `ru` | AI draft; native review pending | Unassigned | Pending |

Review every key in context, including failure messages, accessibility labels,
long Settings captions, and consent disclosures. Record the reviewer and date
here only after reviewing the complete locale. Xcode's older `translated` state
alone is not evidence of human review.

## Counts and grammar

The catalogs contain quantity strings. English uses inline inflection in some
of them. Target-language drafts use count-label wording where needed (for
example, “Tracks added: %lld”) rather than assuming English inflection handles
Bulgarian or Russian. Typed printf arguments and their positions must survive
translation. If a translation uses grammatical plural forms, add the appropriate
String Catalog variations and have a native reviewer check zero, one, two,
five, and larger counts. Compilation does not certify grammar.

## Automated verification

Build each app with `SWIFT_EMIT_LOC_STRINGS=YES`, then run:

```sh
swift scripts/check-localization.swift . macOS <macOS-derived-data>
swift scripts/check-localization.swift . iOS <iOS-derived-data>
bash scripts/tests/localization-coverage.sh
```

Both CI configurations run these checks after the app builds. The guard checks
actual `.stringsdata` declarations from app/shared-core source roots, missing
keys/locales, nonempty recursive variations, flat-entry argument types and
positions, conflicting defaults, and English stubs. Positional notation alone
(`%@` versus `%1$@`) is normalized. It fails when app extraction data is absent.
This is declaration coverage, not proof that every declaration is rendered.
Varied/substituted entries also require Apple's `xcstringstool` compilation;
the guard does not model all plural-branch argument flow.

## Runtime and clipping checks

Translations take effect after the catalog is compiled into the app and the app
restarts in that language. Use Xcode's Accented or Double-Length Pseudolanguage
for clipping checks. Inspect German and Cyrillic at minimum window sizes, with
particular attention to Settings sidebar labels, control captions, table
headers, consent sheets, iOS tabs, and compact playback controls. Structural
checks and English screenshots do not replace these checks or native review.
