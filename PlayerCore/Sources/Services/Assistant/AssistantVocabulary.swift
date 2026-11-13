// AssistantVocabulary — the tier-2 parser's localized keyword tables.
//
// This is PARSER DATA, not user-visible copy. Every string here is matched
// AGAINST what the listener typed and is never rendered back to them, so String
// Catalogs are explicitly NOT the mechanism (PlayerCore ships no catalog anyway).
// A translator must never see these; a `LocalizedStringResource` would be exactly
// the wrong type, because a "translation" that reads well but drops the word the
// user actually types would silently break the parser.
//
// ── WHY A HAND-WRITTEN TABLE AND NOT AN EMBEDDING ─────────────────────────────
//
// `NLEmbedding.wordEmbedding(for:)` and `.sentenceEmbedding(for:)` both return
// `nil` for Bulgarian and Russian — 2 of MacAMP's 7 shipped locales — on a fully
// provisioned macOS 26 host (measured, see the todo-15 evidence file). An
// embedding may therefore only ENHANCE this table, never carry it, which is why
// the keywords are data in the source tree rather than a model lookup.
//
// ── HOW ENTRIES ARE MATCHED (this is what makes the entries look truncated) ────
//
// ``HeuristicQueryParser`` folds both the entry and the token
// (case/diacritic/width-insensitive, fixed `en_US_POSIX`) and then accepts a
// token when it EQUALS the entry, or when the entry is at least
// ``HeuristicQueryParser/stemMinimumLength`` characters and the token STARTS WITH
// it. So entries for inflected languages are written as STEMS: `спокойн` covers
// спокойна / спокойно / спокойни, `energiegeladen` covers energiegeladene, and
// `90er` covers 90ern. Entries shorter than the stem minimum match exactly only,
// which is why short words appear in several inflected spellings instead.
//
// Diacritic folding is not cosmetic here: it maps Cyrillic `ё → е` AND `й → и`,
// so `быстрый` folds to `быстрыи`. Because BOTH sides are folded with the same
// options the stems still match, but a stem must never be hand-folded in this
// file — write the natural spelling and let the parser fold it.
//
// ── ACCEPTED AMBIGUITY: BARE DECADE NUMERALS ──────────────────────────────────
//
// French, Spanish and Italian write a decade as a bare numeral ("des années 90",
// "de los 90", "degli anni 90"), so those three locales list `90`/`80`/`70`/`60`
// as decade tokens. A request like "90 canciones" is therefore read as "the 90s".
// This is a deliberate trade: the parser does NOT parse track counts at all (see
// ``HeuristicQueryParser``), so a bare numeral has no competing meaning inside
// this tier, and the failure mode is an extra year filter on a proposal the user
// previews before applying — not a crash and not silent data loss. English,
// German, Bulgarian and Russian all have a self-describing decade form (`90s`,
// `90er`, `90-те`, `90-х`), so none of them lists a bare numeral.
import Foundation
import Persistence

/// A coarse tempo bucket a keyword can name.
///
/// The bounds are deliberately half-open, which is precisely why
/// ``PlaylistQuerySpec`` carries `SmartPlaylistRange` rather than `ClosedRange`:
/// "fast" means "at least this", not "between these two".
public enum TempoHint: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    /// Everything at or below ``slowUpperBPM``.
    case slow
    /// Everything at or above ``fastLowerBPM``.
    case fast

    /// Upper bound of the "slow" bucket, in BPM.
    public static let slowUpperBPM: Double = 90
    /// Lower bound of the "fast" bucket, in BPM.
    public static let fastLowerBPM: Double = 120

    /// The bucket as a rule-engine range.
    ///
    /// Note that the compiled predicate is `bpm IS NULL OR bpm BETWEEN …`, so a
    /// tempo request over an unanalysed library widens rather than empties — the
    /// caller surfaces `requiresAnalysis` for that, it is not this type's job.
    public var range: SmartPlaylistRange<Double> {
        switch self {
        case .slow: SmartPlaylistRange(upper: Self.slowUpperBPM)
        case .fast: SmartPlaylistRange(lower: Self.fastLowerBPM)
        }
    }
}

/// Every keyword table the heuristic parser needs for one language.
public struct LocaleVocabulary: Sendable, Equatable, Hashable {
    /// Decade token → the first year of that decade (`"90s" → 1990`).
    public var decadeTokens: [String: Int]
    /// Mood bucket → the words that name it.
    ///
    /// A word may appear under TWO buckets on purpose. "happy" is not a dimension
    /// this app measures (``PlaylistMoodTag`` is energy + brightness, never
    /// valence), so happiness-adjacent words contribute BOTH `.energetic` and
    /// `.bright` — the two honest components of what the listener meant — rather
    /// than being force-fitted into one.
    public var moodKeywords: [PlaylistMoodTag: Set<String>]
    /// Word → tempo bucket.
    public var tempoKeywords: [String: TempoHint]
    /// History preference → the words that name it.
    public var recencyKeywords: [PlaylistRecencyPreference: Set<String>]

    public init(
        decadeTokens: [String: Int] = [:],
        moodKeywords: [PlaylistMoodTag: Set<String>] = [:],
        tempoKeywords: [String: TempoHint] = [:],
        recencyKeywords: [PlaylistRecencyPreference: Set<String>] = [:]
    ) {
        self.decadeTokens = decadeTokens
        self.moodKeywords = moodKeywords
        self.tempoKeywords = tempoKeywords
        self.recencyKeywords = recencyKeywords
    }
}

/// The shipped keyword tables, keyed by ISO 639-1 language code.
public enum AssistantVocabulary {
    /// The language used when a locale has no table of its own.
    public static let fallbackLanguageCode = "en"

    /// One table per shipped locale — `en`, `bg`, `de`, `es`, `ru`, `fr`, `it`.
    ///
    /// These are exactly MacAMP's 7 shipped locales. A locale outside the set
    /// resolves to ``fallbackLanguageCode`` rather than to an empty table, so an
    /// unlisted language still parses the English words a listener is likely to
    /// borrow ("chill", "workout") instead of degrading straight to tier 3.
    public static let byLanguage: [String: LocaleVocabulary] = [
        "en": .english,
        "bg": .bulgarian,
        "de": .german,
        "es": .spanish,
        "ru": .russian,
        "fr": .french,
        "it": .italian,
    ]

    /// The table for `locale`'s language, falling back to English.
    public static func vocabulary(for locale: Locale) -> LocaleVocabulary {
        byLanguage[languageCode(for: locale)] ?? .english
    }

    /// `locale`'s lowercased ISO 639-1 code, or ``fallbackLanguageCode`` when it
    /// has none (`Locale(identifier: "")` is a real thing a caller can pass).
    public static func languageCode(for locale: Locale) -> String {
        guard let code = locale.language.languageCode?.identifier.lowercased(),
              !code.isEmpty
        else { return fallbackLanguageCode }
        return code
    }
}

// MARK: - Tables

//
// Held in an extension so the tables stay readable at their natural length
// without pushing `AssistantVocabulary`'s own body past the type-length budget.

extension LocaleVocabulary {
    /// English (`en`) — the base locale and the fallback for unlisted languages.
    static let english = LocaleVocabulary(
        decadeTokens: [
            "50s": 1950, "1950s": 1950, "fifties": 1950,
            "60s": 1960, "1960s": 1960, "sixties": 1960,
            "70s": 1970, "1970s": 1970, "seventies": 1970,
            "80s": 1980, "1980s": 1980, "eighties": 1980,
            "90s": 1990, "1990s": 1990, "nineties": 1990,
            "00s": 2000, "2000s": 2000, "noughties": 2000,
            "2010s": 2010, "2020s": 2020,
        ],
        moodKeywords: [
            .calm: ["chill", "mellow", "relax", "calm", "quiet", "soothing", "laid-back"],
            .energetic: ["upbeat", "energetic", "hype", "workout", "intense", "party", "happy", "feel-good"],
            .dark: ["dark", "heavy", "moody", "brooding", "gloomy"],
            .bright: ["bright", "airy", "shimmering", "crisp", "sunny", "happy", "feel-good", "cheerful"],
        ],
        tempoKeywords: ["fast": .fast, "quick": .fast, "uptempo": .fast, "slow": .slow, "downtempo": .slow],
        recencyKeywords: [
            .freshlyAdded: ["new", "newly", "recent", "recently", "fresh"],
            .rediscovery: ["forgotten", "rediscover", "unplayed", "neglected"],
        ]
    )

    /// Bulgarian (`bg`) — no `NLEmbedding` exists for this language, so the table
    /// carries the whole tier on its own. Stems use the masculine/neuter root.
    static let bulgarian = LocaleVocabulary(
        decadeTokens: [
            "60-те": 1960, "60те": 1960, "шейсетте": 1960,
            "70-те": 1970, "70те": 1970, "седемдесетте": 1970,
            "80-те": 1980, "80те": 1980, "осемдесетте": 1980,
            "90-те": 1990, "90те": 1990, "деветдесетте": 1990,
            "2000-те": 2000, "2000те": 2000,
        ],
        moodKeywords: [
            .calm: ["спокойн", "релакс", "тиха", "тихо", "тихи", "нежн"],
            .energetic: ["енергичн", "динамичн", "мощн", "тренировка", "парти", "весел", "щастлив"],
            .dark: ["тъмн", "мрачн", "тежк"],
            .bright: ["светл", "ярк", "весел", "щастлив", "слънчев"],
        ],
        tempoKeywords: ["бърз": .fast, "бавн": .slow],
        recencyKeywords: [
            .freshlyAdded: ["нови", "нова", "ново", "новите", "скорошн"],
            .rediscovery: ["забравен", "забравени"],
        ]
    )

    /// German (`de`).
    static let german = LocaleVocabulary(
        decadeTokens: [
            "60er": 1960, "sechziger": 1960,
            "70er": 1970, "siebziger": 1970,
            "80er": 1980, "achtziger": 1980,
            "90er": 1990, "neunziger": 1990,
            "2000er": 2000, "nuller": 2000, "2010er": 2010,
        ],
        moodKeywords: [
            .calm: ["chillig", "entspannt", "entspannend", "ruhig", "sanft", "besinnlich"],
            .energetic: [
                "energiegeladen", "energisch", "schwungvoll", "mitreissend",
                "mitreißend", "treibend", "workout", "party", "fröhlich", "glücklich",
            ],
            .dark: ["dunkel", "dunkl", "düster", "schwer", "melancholisch"],
            .bright: ["hell", "strahlend", "luftig", "fröhlich", "glücklich", "sonnig"],
        ],
        tempoKeywords: ["schnell": .fast, "flott": .fast, "langsam": .slow],
        recencyKeywords: [
            .freshlyAdded: ["neue", "neuer", "neues", "kürzlich"],
            .rediscovery: ["vergessen", "vergessene"],
        ]
    )

    /// Spanish (`es`) — bare decade numerals, see the file header.
    static let spanish = LocaleVocabulary(
        decadeTokens: [
            "60": 1960, "sesenta": 1960,
            "70": 1970, "setenta": 1970,
            "80": 1980, "ochenta": 1980,
            "90": 1990, "90s": 1990, "noventa": 1990,
            "2000": 2000, "2000s": 2000,
        ],
        moodKeywords: [
            .calm: ["tranquil", "relajad", "relajant", "suave", "calmad", "chill"],
            .energetic: ["enérgic", "animad", "movid", "intens", "fiesta", "alegre", "feliz"],
            .dark: ["oscur", "sombrí", "pesad", "melancólic"],
            .bright: ["brillante", "luminos", "alegre", "feliz", "soleado"],
        ],
        tempoKeywords: ["rápid": .fast, "veloz": .fast, "lent": .slow],
        recencyKeywords: [
            .freshlyAdded: ["nueva", "nuevo", "nuevas", "nuevos", "reciente"],
            .rediscovery: ["olvidad"],
        ]
    )

    /// Russian (`ru`) — no `NLEmbedding` exists for this language either. `90-х`
    /// (genitive) is the commonest written form and is listed alongside `90-е`.
    static let russian = LocaleVocabulary(
        decadeTokens: [
            "60-е": 1960, "60-х": 1960, "шестидесятые": 1960,
            "70-е": 1970, "70-х": 1970, "семидесятые": 1970,
            "80-е": 1980, "80-х": 1980, "восьмидесятые": 1980,
            "90-е": 1990, "90-х": 1990, "девяностые": 1990, "девяностых": 1990,
            "2000-е": 2000, "нулевые": 2000,
        ],
        moodKeywords: [
            .calm: ["спокойн", "расслаб", "умиротвор", "тихая", "тихие", "нежн"],
            .energetic: ["энергичн", "бодр", "драйв", "тренировк", "зажигательн", "весёл", "радостн"],
            .dark: ["тёмн", "мрачн", "тяжёл", "депрессивн"],
            .bright: ["светл", "ярк", "весёл", "радостн", "солнечн"],
        ],
        tempoKeywords: ["быстр": .fast, "медленн": .slow],
        recencyKeywords: [
            .freshlyAdded: ["новинки", "новые", "свежие", "недавн"],
            .rediscovery: ["забыт", "подзабыт"],
        ]
    )

    /// French (`fr`) — bare decade numerals, see the file header.
    static let french = LocaleVocabulary(
        decadeTokens: [
            "60": 1960, "soixante": 1960,
            "70": 1970, "septante": 1970,
            "80": 1980, "quatre-vingts": 1980,
            "90": 1990, "90s": 1990, "nineties": 1990,
            "2000": 2000, "2000s": 2000,
        ],
        moodKeywords: [
            .calm: ["calme", "tranquille", "douce", "relaxant", "apaisant", "chill"],
            .energetic: ["énergique", "entraînant", "dynamique", "festif", "intense", "joyeux", "heureux"],
            .dark: ["sombre", "lourd", "mélancolique", "obscur"],
            .bright: ["lumineux", "clair", "joyeux", "heureux", "aérien", "ensoleillé"],
        ],
        tempoKeywords: ["rapide": .fast, "lent": .slow],
        recencyKeywords: [
            .freshlyAdded: ["nouveau", "nouvelle", "nouveaux", "récent", "récemment"],
            .rediscovery: ["oublié", "oubliée", "oubliés"],
        ]
    )

    /// Italian (`it`) — bare decade numerals, see the file header.
    static let italian = LocaleVocabulary(
        decadeTokens: [
            "60": 1960, "sessanta": 1960,
            "70": 1970, "settanta": 1970,
            "80": 1980, "ottanta": 1980,
            "90": 1990, "90s": 1990, "novanta": 1990,
            "2000": 2000, "2000s": 2000,
        ],
        moodKeywords: [
            .calm: ["calmo", "calma", "tranquill", "rilassant", "dolce", "sereno"],
            .energetic: ["energic", "vivace", "travolgente", "intens", "allenamento", "festa", "allegr", "felice"],
            .dark: ["scuro", "scura", "cupo", "cupa", "pesante", "malinconic"],
            .bright: ["luminos", "brillante", "allegr", "felice", "solare"],
        ],
        tempoKeywords: ["veloce": .fast, "rapid": .fast, "lento": .slow, "lenta": .slow],
        recencyKeywords: [
            .freshlyAdded: ["nuovo", "nuova", "nuove", "recente"],
            .rediscovery: ["dimenticat"],
        ]
    )
}
