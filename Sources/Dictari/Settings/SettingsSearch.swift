// SettingsSearch.swift
// Dictari — the index and matcher behind the settings sidebar search.
//
// Pure Foundation on purpose: the host-less test bundle compiles it directly, and nothing here
// may touch SwiftUI or AppKit. The catalog of entries lives in `SettingsSearchCatalog.swift`.
//
// Performance model: every string in the index is folded (case, diacritics, width) and split
// into byte tokens ONCE, when the static index is first touched. A keystroke then folds only
// the query and compares small byte arrays — a few thousand comparisons over ~120 entries,
// which runs in microseconds. Typo tolerance uses a bounded Damerau-Levenshtein on stack
// memory and is attempted only for terms that did not already match exactly or by prefix.
//
// Languages: titles, cards, descriptions and keywords are localized by the catalog, so a user
// searches in the language the window is shown in. When that is not English, the English
// source wording is indexed too (`SettingsSearchEntry.english`): a German Mac still finds
// "shortcut", and the English and Italian keywords stay searchable everywhere.

import Foundation

// MARK: - Entries & results

/// One searchable thing in Settings: a section, a card or a single row/control.
struct SettingsSearchEntry: Identifiable, Hashable, Sendable {
    /// Stable identifier (never shown). Unique across the catalog.
    let id: String
    /// The exact label the user sees on screen, in the display language.
    let title: String
    let section: SettingsSection
    /// The card the row sits in, if any — shown in the breadcrumb.
    let card: String?
    /// Short plain-language description; searched with lower weight.
    let detail: String
    /// Synonyms and plain-language paraphrases in the display language (the English source
    /// carries English and Italian ones).
    let keywords: [String]
    /// The `.settingsSearchAnchor` id the UI scrolls to. Rows that only appear in some states
    /// (a toggle turned on, a download finished) point at their always-present parent instead,
    /// so a result can never lead to a spot that is not on screen. `nil` = the section itself.
    let anchor: String?
    /// How many leading `keywords` are direct translations or closest synonyms of the title
    /// ("microfono" for Microphone). They rank above incidental keywords.
    var primaryKeywordCount: Int = 1
    /// The English source wording, set only when the interface runs in another language, so
    /// English terms keep finding the row. `nil` in English: nothing is indexed twice.
    var english: EnglishTerms? = nil

    struct EnglishTerms: Hashable, Sendable {
        /// Indexed like a primary keyword, and whole-title matches earn the title bonus.
        var title: String
        /// Section label and card, indexed as context.
        var context: [String]
        var detail: String
        /// The source keywords (English and Italian), indexed as secondary keywords.
        var keywords: [String]
    }

    var isSection: Bool { anchor == nil }

    /// "Section › Card" — where the row lives, in words the sidebar already uses.
    var breadcrumb: String {
        guard let card, card != title, card != section.label else { return section.label }
        return "\(section.label) › \(card)"
    }
}

struct SettingsSearchResult: Identifiable, Hashable, Sendable {
    let entry: SettingsSearchEntry
    /// Higher is better. Only meaningful relative to other results of the same query.
    let score: Int
    var id: String { entry.id }
}

// MARK: - Index

struct SettingsSearchIndex: Sendable {
    let entries: [SettingsSearchEntry]
    private let prepared: [PreparedEntry]

    /// The index for the running build.
    static let shared = SettingsSearchIndex(entries: SettingsSearchCatalog.entries())

    init(entries: [SettingsSearchEntry]) {
        self.entries = entries
        prepared = entries.map(PreparedEntry.init)
    }

    /// Ranked matches for `query`. Empty or whitespace-only queries return nothing.
    ///
    /// Every meaningful query term must match somewhere in an entry (title, keywords, card,
    /// section, description, or within a small edit distance). Filler words ("how", "the",
    /// "come", "per") never exclude and score only as whole words, so a question typed in plain
    /// language still finds its row.
    ///
    /// Typo tolerance is a fallback: when at least one entry matches every term exactly or by
    /// prefix, entries that needed a fuzzy match are dropped. Otherwise "tema" would drag in
    /// everything containing "tempo", and the list a non-technical user scans would be noise.
    func search(_ query: String, limit: Int = 40) -> [SettingsSearchResult] {
        let parsed = SettingsSearchQuery(query)
        guard parsed.terms.contains(where: { !$0.isOptional }) else { return [] }

        var scored: [(index: Int, score: Int, fuzzy: Bool)] = []
        scored.reserveCapacity(16)
        var anyExact = false
        for index in prepared.indices {
            if let match = prepared[index].score(parsed) {
                scored.append((index, match.score, match.fuzzy))
                anyExact = anyExact || !match.fuzzy
            }
        }
        if anyExact { scored.removeAll { $0.fuzzy } }
        // Stable: equal scores keep catalog order, which follows the sidebar top to bottom.
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
        return scored.prefix(limit).map { SettingsSearchResult(entry: entries[$0.index], score: $0.score) }
    }
}

// MARK: - Scoring tiers

/// Score tiers, spaced so a better kind of match always outranks a weaker one for the same
/// term. Per-term scores are summed across terms; whole-title matches add a bonus that no sum
/// of word matches can reach.
enum SettingsSearchScore {
    static let exactTitle = 100_000
    static let titlePrefix = 50_000
    static let titleWordExact = 1_000
    static let titleWordPrefix = 800
    static let keywordExact = 600
    static let keywordPrefix = 500
    static let contextExact = 400      // card or section name
    static let contextPrefix = 350
    static let detailExact = 250
    static let detailPrefix = 200
    static let fuzzyTitle = 120
    static let fuzzyKeyword = 110
    static let fuzzyContext = 100
    /// Per edit. Larger than the gap between fuzzy fields, so one slip anywhere beats two.
    static let fuzzyPenalty = 30
    /// Primary keywords are an entry's direct translations or closest synonyms ("microfono"
    /// for Microphone). Matching one beats matching an incidental keyword, but never a better
    /// tier.
    static let primaryKeywordBonus = 40
    static let primaryFuzzyBonus = 5
    /// A filler word that happens to be a whole keyword or title word.
    static let fillerExact = 100
}

// MARK: - Query

struct SettingsSearchQuery {
    struct Term {
        let bytes: [UInt8]
        /// Which letters/digits occur, for the cheap typo lower bound.
        let mask: UInt64
        /// Filler words never exclude an entry; they add a little only as whole words.
        let isOptional: Bool
        /// Allowed edit distance for typo tolerance.
        let maxEdits: Int
    }

    let terms: [Term]
    /// The folded query with single spaces, for whole-title comparisons.
    let full: [UInt8]

    init(_ raw: String) {
        let tokens = SettingsSearchText.tokens(of: raw)
        var seen = Set<[UInt8]>()
        let unique = tokens.filter { seen.insert($0).inserted }
        // A query made only of filler ("a", "on") is still searched literally.
        let allFiller = unique.allSatisfy { SettingsSearchText.fillerWords.contains($0) }
        terms = unique.map { token in
            Term(
                bytes: token,
                mask: SettingsSearchText.letterMask(token),
                isOptional: !allFiller && SettingsSearchText.fillerWords.contains(token),
                maxEdits: token.count >= 8 ? 2 : (token.count >= 4 ? 1 : 0)
            )
        }
        full = SettingsSearchText.joined(tokens)
    }
}

// MARK: - Prepared entry

/// A folded word plus the set of letters in it. The mask gives a free lower bound on edit
/// distance: every distinct letter of the query word missing from the whole token costs at
/// least one edit, so most tokens are rejected without running the distance at all.
private struct SearchToken: Sendable {
    let bytes: [UInt8]
    let mask: UInt64

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
        mask = SettingsSearchText.letterMask(bytes)
    }
}

private struct PreparedEntry: Sendable {
    let titleFull: [UInt8]
    /// The English title, folded, when the display language is another one.
    let englishTitleFull: [UInt8]?
    let title: [SearchToken]
    let primary: [SearchToken]
    let keywords: [SearchToken]
    let context: [SearchToken]
    let detail: [SearchToken]

    init(_ entry: SettingsSearchEntry) {
        func prepare(_ tokens: [[UInt8]]) -> [SearchToken] {
            SettingsSearchText.deduplicated(tokens).map(SearchToken.init)
        }
        let titleTokens = SettingsSearchText.tokens(of: entry.title)
        titleFull = SettingsSearchText.joined(titleTokens)
        title = prepare(titleTokens + SettingsSearchText.compounds(of: titleTokens))

        func expand(_ phrase: String) -> [[UInt8]] {
            let tokens = SettingsSearchText.tokens(of: phrase)
            // "dark mode" should also answer "darkmode", "push to talk" → "pushtotalk".
            return tokens + SettingsSearchText.compounds(of: tokens)
        }
        let split = min(max(entry.primaryKeywordCount, 0), entry.keywords.count)
        let english = entry.english
        // The English title is the closest synonym of a translated one; its source keywords
        // and description only add reach, after the display language's own words.
        primary = prepare(entry.keywords.prefix(split).flatMap(expand) + (english.map { expand($0.title) } ?? []))
        keywords = prepare(entry.keywords.dropFirst(split).flatMap(expand)
                           + (english?.keywords.flatMap(expand) ?? []))

        var contextTokens = SettingsSearchText.tokens(of: entry.section.label)
        if let card = entry.card { contextTokens += SettingsSearchText.tokens(of: card) }
        contextTokens += english?.context.flatMap(SettingsSearchText.tokens(of:)) ?? []
        context = prepare(contextTokens)
        detail = prepare(SettingsSearchText.tokens(of: entry.detail)
                         + (english.map { SettingsSearchText.tokens(of: $0.detail) } ?? []))
        englishTitleFull = english.map { SettingsSearchText.joined(SettingsSearchText.tokens(of: $0.title)) }
    }

    /// `nil` when a required term matches nothing; `fuzzy` when any term needed typo tolerance.
    func score(_ query: SettingsSearchQuery) -> (score: Int, fuzzy: Bool)? {
        var total = 0
        var fuzzy = false
        for term in query.terms {
            if term.isOptional {
                // Only a whole-word hit counts: "cancella cronologia" should lift "Clear All Transcriptions",
                // but "la" must not score as the start of "Language".
                if Self.contains(term.bytes, in: title) || Self.contains(term.bytes, in: primary)
                    || Self.contains(term.bytes, in: keywords) {
                    total += SettingsSearchScore.fillerExact
                }
                continue
            }
            guard let match = score(term) else { return nil }
            total += match.score
            fuzzy = fuzzy || match.fuzzy
        }
        if query.full == titleFull || query.full == englishTitleFull {
            total += SettingsSearchScore.exactTitle
        } else if titleFull.starts(with: query.full) || englishTitleFull?.starts(with: query.full) == true {
            total += SettingsSearchScore.titlePrefix
        }
        return (total, fuzzy)
    }

    private func score(_ term: SettingsSearchQuery.Term) -> (score: Int, fuzzy: Bool)? {
        let t = term.bytes
        typealias S = SettingsSearchScore
        let bonus = S.primaryKeywordBonus
        if let s = Self.best(t, in: title, exact: S.titleWordExact, prefix: S.titleWordPrefix) { return (s, false) }
        if let s = Self.best(t, in: primary, exact: S.keywordExact + bonus, prefix: S.keywordPrefix + bonus) { return (s, false) }
        if let s = Self.best(t, in: keywords, exact: S.keywordExact, prefix: S.keywordPrefix) { return (s, false) }
        if let s = Self.best(t, in: context, exact: S.contextExact, prefix: S.contextPrefix) { return (s, false) }
        // A one- or two-letter prefix of a description word is noise ("a" would match all).
        if let s = Self.best(t, in: detail, exact: S.detailExact, prefix: t.count >= 3 ? S.detailPrefix : nil) { return (s, false) }

        guard term.maxEdits > 0 else { return nil }
        var best: Int?
        func consider(_ tokens: [SearchToken], _ base: Int) {
            guard let d = Self.closest(term, in: tokens) else { return }
            best = max(best ?? .min, base - d * S.fuzzyPenalty)
        }
        consider(title, S.fuzzyTitle)
        consider(primary, S.fuzzyKeyword + S.primaryFuzzyBonus)
        consider(keywords, S.fuzzyKeyword)
        consider(context, S.fuzzyContext)
        return best.map { ($0, true) }
    }

    private static func contains(_ term: [UInt8], in tokens: [SearchToken]) -> Bool {
        tokens.contains { $0.bytes == term }
    }

    private static func best(_ term: [UInt8], in tokens: [SearchToken], exact: Int, prefix: Int?) -> Int? {
        var result: Int?
        for token in tokens {
            let bytes = token.bytes
            if bytes == term { return exact }
            if let prefix, result == nil, bytes.count > term.count, bytes.starts(with: term) {
                result = prefix
            }
        }
        return result
    }

    /// Smallest edit distance from the term to a token or to the start of one (so a typo in a
    /// word still being typed — "micorf" for "microfono" — is forgiven too).
    private static func closest(_ term: SettingsSearchQuery.Term, in tokens: [SearchToken]) -> Int? {
        var best: Int?
        let n = term.bytes.count
        for token in tokens {
            let limit = best.map { $0 - 1 } ?? term.maxEdits
            guard limit >= 0 else { break }
            guard token.bytes.count >= n - limit,
                  (term.mask & ~token.mask).nonzeroBitCount <= limit,
                  let d = SettingsSearchText.editDistance(term.bytes, token.bytes[...], limit: limit, allowingPrefix: true)
            else { continue }
            best = d
        }
        return best
    }
}

// MARK: - Text folding

enum SettingsSearchText {
    /// Words that carry no meaning on their own in questions such as "how do I change the
    /// language" / "come cambio la lingua" / "wie ändere ich die Sprache", in English, Italian
    /// and the other interface languages. Only articles, pronouns, prepositions and the verbs of
    /// a question ("change", "find"): words that never name a setting, so making them optional
    /// cannot hide a row. Folded like every other token, so accents and case do not matter.
    static let fillerWords: Set<[UInt8]> = Set(([
        "a", "an", "the", "to", "of", "for", "in", "on", "at", "and", "or", "is", "do", "i", "my",
        "me", "how", "where", "what", "can", "change", "set", "turn", "make", "want",
        "il", "lo", "la", "le", "gli", "un", "una", "uno", "di", "da", "del", "della", "dei",
        "delle", "per", "con", "su", "e", "o", "come", "dove", "cosa", "che", "mio", "mia",
        "miei", "voglio", "cambia", "cambiare", "cambio", "imposta", "impostare", "si", "non",
        "are", "does", "find", "use", "using", "with", "it", "this", "off", "enable", "disable",
        "trova", "trovo", "trovare", "sono", "ho", "posso", "vorrei", "fare", "faccio", "usare",
        "questo", "quella", "quello", "attiva", "attivare", "disattiva", "disattivare", "abilita",
        "disabilita", "togli", "metti", "mettere", "nel", "nella", "sul", "sulla", "al", "alla",
        // German
        "der", "die", "das", "den", "dem", "des", "ein", "eine", "einen", "und", "oder", "ist",
        "wie", "wo", "was", "ich", "mein", "meine", "meinen", "zu", "von", "mit", "für", "auf",
        "im", "kann", "möchte", "ändern", "ändere", "einstellen", "aktivieren", "deaktivieren",
        "einschalten", "ausschalten", "finde", "finden", "nicht",
        // French
        "les", "une", "des", "du", "et", "ou", "où", "est", "comment", "je", "mon", "ma", "mes",
        "pour", "avec", "sur", "dans", "changer", "modifier", "activer", "désactiver", "trouver",
        "veux", "ne", "pas",
        // Spanish and Portuguese
        "el", "los", "las", "unos", "y", "cómo", "dónde", "qué", "mi", "mis", "para", "en",
        "cambiar", "quiero", "puedo", "activar", "desactivar", "encontrar", "os", "as", "um",
        "do", "dos", "das", "em", "onde", "meu", "minha", "mudar", "alterar", "quero", "ativar",
        "desativar",
        // Russian and Ukrainian
        "как", "где", "что", "мой", "моя", "мои", "в", "на", "и", "или", "для", "с", "не", "я",
        "хочу", "изменить", "поменять", "включить", "выключить", "найти", "як", "де", "що",
        "мій", "мої", "у", "і", "й", "або", "з", "змінити", "увімкнути", "вимкнути", "знайти",
    ] as [String]).map { Array(SettingsSearchText.fold($0).utf8) })

    /// Case-, diacritic- and width-insensitive form, lowercased.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
    }

    /// Folded words as UTF-8 byte arrays. ASCII letters and digits form words; any other
    /// ASCII byte separates them. Non-ASCII bytes (letters that have no folded ASCII form,
    /// e.g. Cyrillic) stay inside words so they can still be matched exactly.
    static func tokens(of text: String) -> [[UInt8]] {
        var result: [[UInt8]] = []
        var current: [UInt8] = []
        for byte in fold(text).utf8 {
            if isWordByte(byte) {
                current.append(byte)
            } else if !current.isEmpty {
                result.append(current)
                current.removeAll(keepingCapacity: true)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    static func joined(_ tokens: [[UInt8]]) -> [UInt8] {
        var out: [UInt8] = []
        for (i, token) in tokens.enumerated() {
            if i > 0 { out.append(0x20) }
            out += token
        }
        return out
    }

    /// Adjacent tokens glued together ("auto capitalise" → "autocapitalise"), for people who
    /// type hyphenated or two-word labels as one word.
    static func compounds(of tokens: [[UInt8]]) -> [[UInt8]] {
        guard tokens.count >= 2 else { return [] }
        var out: [[UInt8]] = []
        for i in 0..<(tokens.count - 1) { out.append(tokens[i] + tokens[i + 1]) }
        if tokens.count >= 3 { out.append(tokens.reduce([], +)) }
        return out
    }

    static func deduplicated(_ tokens: [[UInt8]]) -> [[UInt8]] {
        var seen = Set<[UInt8]>()
        return tokens.filter { seen.insert($0).inserted }
    }

    @inline(__always)
    static func isWordByte(_ byte: UInt8) -> Bool {
        (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39) || byte >= 0x80
    }

    /// One bit per ASCII letter and digit; every non-ASCII byte shares the top bit.
    static func letterMask(_ bytes: [UInt8]) -> UInt64 {
        var mask: UInt64 = 0
        for byte in bytes {
            switch byte {
            case 0x61...0x7A: mask |= 1 << UInt64(byte - 0x61)
            case 0x30...0x39: mask |= 1 << UInt64(26 + byte - 0x30)
            default: mask |= 1 << 63
            }
        }
        return mask
    }

    /// Optimal-string-alignment Damerau-Levenshtein distance (adjacent transpositions count
    /// as one edit), or `nil` once it provably exceeds `limit`. Rows live on the stack.
    ///
    /// With `allowingPrefix`, `a` may also match just the start of `b` — the smallest distance
    /// from `a` to any prefix of `b` — computed in the same single pass over the last row.
    static func editDistance(
        _ a: [UInt8], _ target: ArraySlice<UInt8>, limit: Int, allowingPrefix: Bool = false
    ) -> Int? {
        let n = a.count
        // A prefix longer than n + limit can never be within the limit; skip that tail.
        let b = allowingPrefix ? target.prefix(n + limit) : target
        let m = b.count
        if !allowingPrefix, abs(n - m) > limit { return nil }
        if m < n - limit { return nil }
        if n == 0 { return allowingPrefix ? 0 : m }
        if m == 0 { return n <= limit ? n : nil }
        let width = m + 1
        return withUnsafeTemporaryAllocation(of: Int.self, capacity: width * 3) { buffer -> Int? in
            // Three rolling rows: two back (for transpositions), previous, current.
            var older = buffer.baseAddress!
            var previous = older + width
            var current = previous + width
            for j in 0...m { previous[j] = j }
            let base = b.startIndex
            for i in 1...n {
                current[0] = i
                var rowMinimum = i
                let ai = a[i - 1]
                for j in 1...m {
                    let bj = b[base + j - 1]
                    let cost = ai == bj ? 0 : 1
                    var value = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                    if i > 1, j > 1, ai == b[base + j - 2], a[i - 2] == bj {
                        value = min(value, older[j - 2] + 1)
                    }
                    current[j] = value
                    rowMinimum = min(rowMinimum, value)
                }
                // Every later cell derives from this row plus a non-negative cost.
                if rowMinimum > limit { return nil }
                (older, previous, current) = (previous, current, older)
            }
            var distance = previous[m]
            if allowingPrefix {
                for j in max(0, n - limit)...m { distance = min(distance, previous[j]) }
            }
            return distance <= limit ? distance : nil
        }
    }
}

// MARK: - Emphasis

extension SettingsSearchText {
    /// Ranges of `title` to set in a heavier weight for `query`: the leading part of each
    /// title word that a query term is a prefix of. Works on Characters, so accented titles
    /// keep correct boundaries even though matching compared folded bytes.
    static func emphasisRanges(in title: String, query: String) -> [Range<String.Index>] {
        let terms = SettingsSearchQuery(query).terms
            .filter { !$0.isOptional }
            .compactMap { String(bytes: $0.bytes, encoding: .utf8) }
        guard !terms.isEmpty else { return [] }

        var ranges: [Range<String.Index>] = []
        var index = title.startIndex
        while index < title.endIndex {
            guard isWordCharacter(title[index]) else {
                index = title.index(after: index)
                continue
            }
            var end = index
            while end < title.endIndex, isWordCharacter(title[end]) { end = title.index(after: end) }
            let word = title[index..<end]
            let folded = fold(String(word))
            // Longest matching term wins, so "micro" and "microfono" do not fight.
            if let term = terms.filter({ folded.hasPrefix($0) }).max(by: { $0.count < $1.count }) {
                let length = min(term.count, word.count)
                ranges.append(index..<title.index(index, offsetBy: length))
            }
            index = end
        }
        return ranges
    }

    private static func isWordCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber
    }
}
