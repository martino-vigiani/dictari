import Foundation
import NaturalLanguage

/// Deterministic spoken punctuation and formatting commands ("virgola", "a capo", "new
/// paragraph", "Klammer auf", …) plus removal of standalone hesitation fillers.
///
/// Pure and synchronous on purpose: it runs on the stop→inject path, so it must stay far
/// below the latency budget (a single linear pass over a token array, no regex, no model).
///
/// Design choices worth knowing before changing it:
/// - Text that is not part of a command or filler is copied through verbatim, token by token,
///   so the function never rewrites spacing, casing or punctuation it was not asked to touch.
/// - Commands that are also ordinary nouns ("punto", "virgola", "due punti", "period", "colon",
///   "Punkt", "Komma") only fire when they stand alone between pauses (punctuation, newline,
///   start of text, another command) or close the dictation. "il punto è che" and "the period
///   of time" stay prose.
/// - Any command preceded by an article/determiner ("il punto", "a comma", "der Punkt",
///   "i due punti") is treated as prose: a spoken command is never introduced by an article.
/// - The ASR model often surrounds a spoken command with its own pause punctuation
///   ("Ciao, virgola, come stai"); that punctuation is dropped so the command wins and no
///   ",," or ". ." appears. Punctuation emitted by an earlier command is never stripped.
/// - "auto" is the setting most people use, so it must not mean "no punctuation commands".
///   The transcript's own language is recognised on-device (`NLLanguageRecognizer`, well
///   under a millisecond, and only when the text contains a possible command) and that
///   language's full rules apply. Only when the text is too short or mixed to tell does it
///   fall back to the commands that are safe in every language: multi-word phrases and a few
///   words that exist in no other supported language ("acapo", "newline").
/// - Words of a phrase may be joined by a hyphen as well as a space: the model writes
///   "a-capo" and "point-virgule" as often as "a capo".
enum SpokenFormatting {
    static func apply(_ text: String, language: String) -> String {
        guard !text.isEmpty else { return text }
        let tokens = tokenize(text)
        var rules = Rules.for(language)
        if Rules.isAuto(language) {
            // Pay for language recognition only when some language could have a command here.
            guard hasTrigger(tokens, Rules.everything) else { return text }
            if let detected = detectedLanguage(of: text) { rules = Rules.for(detected) }
        }
        // Fast path: nothing that could trigger a rewrite → return the input untouched.
        guard hasTrigger(tokens, rules) else { return text }
        var renderer = Renderer(tokens: tokens, rules: rules)
        return renderer.run()
    }

    private static func hasTrigger(_ tokens: [Token], _ rules: Rules) -> Bool {
        tokens.contains { token in
            token.kind == .word
                && (rules.byFirstWord[token.key] != nil || fillers.contains(token.text.lowercased()))
        }
    }

    /// The transcript's language among the ones that have commands, or nil when the text does
    /// not say clearly enough (a few words, or a real mix) — then only the safe subset applies.
    static func detectedLanguage(of text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [
            .italian, .english, .german, .spanish, .french, .portuguese, .russian, .ukrainian,
        ]
        recognizer.processString(text)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              confidence >= 0.7 else { return nil }
        return language.rawValue
    }

    // MARK: - Tokens

    fileprivate enum Kind: Equatable { case word, space, punct }

    fileprivate struct Token {
        let kind: Kind
        let text: String
        /// Case- and diacritic-folded text for words; raw text otherwise.
        let key: String
        let hasNewline: Bool
    }

    fileprivate static func fold(_ s: String) -> String {
        // The model writes both apostrophes ("d'interrogation" / "d’interrogation").
        s.replacingOccurrences(of: "’", with: "'")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        tokens.reserveCapacity(text.count / 3)
        var current = ""
        var currentKind: Kind?

        func flush() {
            guard let kind = currentKind, !current.isEmpty else { return }
            tokens.append(Token(
                kind: kind,
                text: current,
                key: kind == .word ? fold(current) : current,
                hasNewline: kind == .space && current.contains(where: \.isNewline)
            ))
            current = ""
            currentKind = nil
        }

        for ch in text {
            let kind: Kind
            if ch.isWhitespace {
                kind = .space
            } else if ch.isLetter || ch.isNumber {
                kind = .word
            } else if (ch == "'" || ch == "’") && currentKind == .word {
                // Apostrophes stay inside words ("l'altro", "don't"), but not as leading quotes.
                kind = .word
            } else {
                kind = .punct
            }
            if kind == .punct {
                flush()
                let s = String(ch)
                tokens.append(Token(kind: .punct, text: s, key: s, hasNewline: false))
                continue
            }
            if kind != currentKind { flush(); currentKind = kind }
            current.append(ch)
        }
        flush()
        return tokens
    }

    // MARK: - Commands

    fileprivate enum Action: Sendable {
        case newline(Int)
        case mark(Character, terminal: Bool)
        case open(Character)
        case close(Character)
        /// German "Anführungszeichen": opens if no command-opened quote is pending, else closes.
        case toggleQuote
    }

    fileprivate enum Lang: Sendable { case it, en, de, es, fr, pt, ru, uk }

    fileprivate struct Command: Sendable {
        let words: [String]
        let actions: [Action]
        let ambiguous: Bool
        /// Safe to apply when the language is unknown: a single word that is a command in its
        /// language and means nothing in the others ("acapo", "newline").
        let autoSafe: Bool
        /// "3 virgola 5" is a decimal read aloud, not a comma: prose between two numbers.
        let notBetweenNumbers: Bool
        let lang: Lang
        /// Preceding words that turn the phrase into prose (beyond the language determiners).
        let blockedAfter: Set<String>
        /// Following words that turn the phrase into prose ("a capo del progetto").
        let blockedBefore: Set<String>
    }

    /// Spelled-out digits, folded, so "zero virgola cinque" and "Null Komma fünf" stay decimals.
    fileprivate static let numberWords: Set<String> = Set([
        "zero", "uno", "due", "tre", "quattro", "cinque", "sei", "sette", "otto", "nove", "dieci",
        "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "null", "eins", "zwei", "drei", "vier", "fünf", "sechs", "sieben", "acht", "neun", "zehn",
        "cero", "dos", "tres", "cuatro", "cinco", "seis", "siete", "ocho", "nueve", "diez",
        "zéro", "un", "deux", "trois", "quatre", "cinq", "six", "sept", "huit", "neuf", "dix",
        "um", "dois", "três", "quatro", "cinco", "sete", "oito", "dez",
        "ноль", "один", "два", "три", "четыре", "пять", "шесть", "семь", "восемь", "девять", "десять",
        "нуль", "чотири", "п'ять", "шість", "сім", "вісім", "дев'ять",
    ].map(fold))

    fileprivate static let pause: Set<Character> = [",", ".", ";", ":", "?", "!", "…"]
    fileprivate static let fillers: Set<String> = ["ehm", "ehmm", "uhm", "umm", "äh", "ähm"]

    private static let determiners: [Lang: Set<String>] = [
        .it: [
            "il", "lo", "la", "i", "gli", "le", "un", "uno", "una", "del", "dello", "della", "dei",
            "degli", "delle", "al", "allo", "alla", "ai", "agli", "alle", "nel", "nello", "nella",
            "nei", "negli", "nelle", "sul", "sullo", "sulla", "sui", "sugli", "sulle", "col",
            "questo", "questa", "questi", "queste", "quel", "quello", "quella", "quei", "quegli",
            "quelle", "ogni", "che", "quale", "quali", "qualche", "certo", "nessun", "nessuno",
            "buon", "mio", "tuo", "suo", "nostro", "vostro", "loro", "stesso",
        ],
        .en: [
            "the", "a", "an", "this", "that", "these", "those", "each", "every", "any", "no",
            "my", "your", "his", "her", "its", "our", "their", "same", "of", "whole",
        ],
        .de: [
            "der", "die", "das", "den", "dem", "des", "ein", "eine", "einen", "einem", "einer",
            "eines", "kein", "keine", "keinen", "keinem", "dieser", "diese", "diesen", "diesem",
            "jeder", "jeden", "jedem", "welcher", "welchen", "zum", "am", "im", "vom", "beim",
        ],
        .es: [
            "el", "la", "los", "las", "un", "una", "unos", "unas", "del", "al", "este", "esta",
            "estos", "estas", "ese", "esa", "esos", "esas", "aquel", "aquella", "cada", "mi",
            "tu", "su", "nuestro", "nuestra", "vuestro", "que", "cual", "ningun", "ninguna", "en",
        ],
        .fr: [
            "le", "la", "les", "l", "un", "une", "des", "du", "au", "aux", "ce", "cet", "cette",
            "ces", "mon", "ma", "ton", "ta", "son", "sa", "notre", "votre", "leur", "chaque",
            "quel", "quelle", "aucun", "aucune", "premier", "dernier",
        ],
        .pt: [
            "o", "a", "os", "as", "um", "uma", "uns", "umas", "do", "da", "dos", "das", "no",
            "na", "nos", "nas", "ao", "aos", "este", "esta", "esse", "essa", "aquele", "aquela",
            "cada", "meu", "minha", "seu", "sua", "nosso", "nossa", "que", "qual", "nenhum",
        ],
        // Russian and Ukrainian have no articles; the demonstratives cover "эта точка".
        .ru: ["эта", "эту", "этой", "та", "ту", "каждая", "каждую", "одна", "одну", "эти", "та"],
        .uk: ["ця", "цю", "цієї", "та", "ту", "кожна", "кожну", "одна", "одну", "ці"],
    ]

    private static func cmd(
        _ phrase: String, _ lang: Lang, _ actions: [Action], ambiguous: Bool = false,
        autoSafe: Bool = false, notBetweenNumbers: Bool = false,
        blockedAfter: Set<String> = [], blockedBefore: Set<String> = [], articles: Bool = true
    ) -> Command {
        Command(
            words: phrase.split(separator: " ").map { fold(String($0)) },
            actions: actions, ambiguous: ambiguous, autoSafe: autoSafe,
            notBetweenNumbers: notBetweenNumbers, lang: lang,
            blockedAfter: Set(blockedAfter.map(fold)).union(articles ? determiners[lang] ?? [] : []),
            blockedBefore: Set(blockedBefore.map(fold))
        )
    }

    private static let italian: [Command] = {
        let di: Set<String> = ["di", "del", "dell", "dello", "della", "dei", "degli", "delle"]
        return [
            // "a capo" opens with a preposition, so an article before it ("uno a capo") says nothing.
            cmd("a capo", .it, [.newline(1)], blockedBefore: di, articles: false),
            // The model also writes it as one word ("acapo", "accapo", "Accapo").
            cmd("acapo", .it, [.newline(1)], autoSafe: true, blockedBefore: di, articles: false),
            cmd("accapo", .it, [.newline(1)], autoSafe: true, blockedBefore: di, articles: false),
            cmd("vai a capo", .it, [.newline(1)], articles: false),
            cmd("vai acapo", .it, [.newline(1)], articles: false),
            cmd("vai accapo", .it, [.newline(1)], articles: false),
            cmd("nuova riga", .it, [.newline(1)]),
            cmd("nuova linea", .it, [.newline(1)]),
            cmd("punto a capo", .it, [.mark(".", terminal: true), .newline(1)]),
            cmd("punto acapo", .it, [.mark(".", terminal: true), .newline(1)]),
            cmd("punto accapo", .it, [.mark(".", terminal: true), .newline(1)]),
            cmd("punto e a capo", .it, [.mark(".", terminal: true), .newline(1)]),
            cmd("nuovo paragrafo", .it, [.newline(2)]),
            cmd("nuovo capoverso", .it, [.newline(2)]),
            // Not ambiguous: a comma is almost never a noun in dictation, the article rule catches
            // "la virgola", and the model seldom brackets the command with pauses for us.
            cmd("virgola", .it, [.mark(",", terminal: false)], notBetweenNumbers: true),
            cmd("punto e virgola", .it, [.mark(";", terminal: false)]),
            // "ho due punti da discutere" is everyday prose: treat the phrase like a lone noun.
            cmd("due punti", .it, [.mark(":", terminal: false)], ambiguous: true),
            cmd("punto interrogativo", .it, [.mark("?", terminal: true)]),
            cmd("punto esclamativo", .it, [.mark("!", terminal: true)]),
            cmd("punto", .it, [.mark(".", terminal: true)], ambiguous: true),
            cmd("apri parentesi", .it, [.open("(")]),
            cmd("aperta parentesi", .it, [.open("(")]),
            cmd("chiudi parentesi", .it, [.close(")")]),
            cmd("chiusa parentesi", .it, [.close(")")]),
            cmd("apri virgolette", .it, [.open("\"")]),
            cmd("aperte virgolette", .it, [.open("\"")]),
            cmd("chiudi virgolette", .it, [.close("\"")]),
            cmd("chiuse virgolette", .it, [.close("\"")]),
        ]
    }()

    private static let english: [Command] = [
        cmd("new line", .en, [.newline(1)], blockedBefore: ["of"]),
        cmd("newline", .en, [.newline(1)], autoSafe: true, blockedBefore: ["of"]),
        cmd("next line", .en, [.newline(1)], blockedBefore: ["of"]),
        cmd("new paragraph", .en, [.newline(2)]),
        cmd("comma", .en, [.mark(",", terminal: false)], notBetweenNumbers: true),
        cmd("semicolon", .en, [.mark(";", terminal: false)]),
        cmd("colon", .en, [.mark(":", terminal: false)], ambiguous: true),
        cmd("question mark", .en, [.mark("?", terminal: true)]),
        cmd("exclamation mark", .en, [.mark("!", terminal: true)]),
        cmd("exclamation point", .en, [.mark("!", terminal: true)]),
        cmd("full stop", .en, [.mark(".", terminal: true)]),
        // "period" closes plenty of ordinary sentences ("a long period"): block common modifiers.
        cmd("period", .en, [.mark(".", terminal: true)], ambiguous: true, blockedAfter: [
            "long", "short", "trial", "grace", "time", "waiting", "transition", "cooling",
            "notice", "reporting", "billing", "study", "rest", "initial", "final", "given",
            "certain", "extended", "limited", "holiday", "historical", "early", "late",
        ]),
        cmd("open parenthesis", .en, [.open("(")]),
        cmd("close parenthesis", .en, [.close(")")]),
        cmd("open quote", .en, [.open("\"")]),
        cmd("open quotes", .en, [.open("\"")]),
        cmd("close quote", .en, [.close("\"")]),
        cmd("close quotes", .en, [.close("\"")]),
        cmd("end quote", .en, [.close("\"")]),
    ]

    private static let german: [Command] = [
        cmd("neue zeile", .de, [.newline(1)]),
        cmd("nächste zeile", .de, [.newline(1)]),
        cmd("neuer absatz", .de, [.newline(2)]),
        cmd("komma", .de, [.mark(",", terminal: false)], notBetweenNumbers: true),
        cmd("semikolon", .de, [.mark(";", terminal: false)]),
        cmd("doppelpunkt", .de, [.mark(":", terminal: false)]),
        cmd("fragezeichen", .de, [.mark("?", terminal: true)]),
        cmd("ausrufezeichen", .de, [.mark("!", terminal: true)]),
        cmd("punkt", .de, [.mark(".", terminal: true)], ambiguous: true),
        cmd("klammer auf", .de, [.open("(")]),
        cmd("klammer zu", .de, [.close(")")]),
        cmd("anführungszeichen", .de, [.toggleQuote]),
        cmd("anführungszeichen unten", .de, [.open("\"")]),
        cmd("anführungszeichen auf", .de, [.open("\"")]),
        cmd("anführungszeichen oben", .de, [.close("\"")]),
        cmd("anführungszeichen zu", .de, [.close("\"")]),
    ]

    private static let spanish: [Command] = [
        cmd("nueva linea", .es, [.newline(1)]),
        cmd("salto de linea", .es, [.newline(1)]),
        cmd("nuevo parrafo", .es, [.newline(2)]),
        cmd("punto y aparte", .es, [.mark(".", terminal: true), .newline(1)]),
        cmd("punto y seguido", .es, [.mark(".", terminal: true)]),
        cmd("punto y coma", .es, [.mark(";", terminal: false)]),
        cmd("coma", .es, [.mark(",", terminal: false)], ambiguous: true),
        cmd("dos puntos", .es, [.mark(":", terminal: false)], ambiguous: true),
        cmd("signo de interrogacion", .es, [.mark("?", terminal: true)]),
        cmd("signo de exclamacion", .es, [.mark("!", terminal: true)]),
        cmd("punto final", .es, [.mark(".", terminal: true)]),
        cmd("punto", .es, [.mark(".", terminal: true)], ambiguous: true),
        cmd("abrir parentesis", .es, [.open("(")]),
        cmd("abre parentesis", .es, [.open("(")]),
        cmd("cerrar parentesis", .es, [.close(")")]),
        cmd("cierra parentesis", .es, [.close(")")]),
        cmd("abrir comillas", .es, [.open("\"")]),
        cmd("abre comillas", .es, [.open("\"")]),
        cmd("cerrar comillas", .es, [.close("\"")]),
        cmd("cierra comillas", .es, [.close("\"")]),
    ]

    private static let french: [Command] = [
        cmd("a la ligne", .fr, [.newline(1)], articles: false),
        cmd("retour a la ligne", .fr, [.newline(1)]),
        cmd("nouvelle ligne", .fr, [.newline(1)]),
        cmd("nouveau paragraphe", .fr, [.newline(2)]),
        cmd("point a la ligne", .fr, [.mark(".", terminal: true), .newline(1)]),
        cmd("virgule", .fr, [.mark(",", terminal: false)], notBetweenNumbers: true),
        cmd("point virgule", .fr, [.mark(";", terminal: false)]),
        cmd("deux points", .fr, [.mark(":", terminal: false)], ambiguous: true),
        cmd("point d'interrogation", .fr, [.mark("?", terminal: true)]),
        cmd("point d'exclamation", .fr, [.mark("!", terminal: true)]),
        cmd("point final", .fr, [.mark(".", terminal: true)]),
        cmd("point", .fr, [.mark(".", terminal: true)], ambiguous: true),
        cmd("ouvrir la parenthese", .fr, [.open("(")]),
        cmd("ouvrez la parenthese", .fr, [.open("(")]),
        cmd("ouvrir parenthese", .fr, [.open("(")]),
        cmd("fermer la parenthese", .fr, [.close(")")]),
        cmd("fermez la parenthese", .fr, [.close(")")]),
        cmd("fermer parenthese", .fr, [.close(")")]),
        cmd("ouvrir les guillemets", .fr, [.open("\"")]),
        cmd("ouvrez les guillemets", .fr, [.open("\"")]),
        cmd("fermer les guillemets", .fr, [.close("\"")]),
        cmd("fermez les guillemets", .fr, [.close("\"")]),
    ]

    private static let portuguese: [Command] = [
        cmd("nova linha", .pt, [.newline(1)]),
        cmd("proxima linha", .pt, [.newline(1)]),
        cmd("novo paragrafo", .pt, [.newline(2)]),
        cmd("ponto e virgula", .pt, [.mark(";", terminal: false)]),
        cmd("virgula", .pt, [.mark(",", terminal: false)], notBetweenNumbers: true),
        cmd("dois pontos", .pt, [.mark(":", terminal: false)], ambiguous: true),
        cmd("ponto de interrogacao", .pt, [.mark("?", terminal: true)]),
        cmd("ponto de exclamacao", .pt, [.mark("!", terminal: true)]),
        cmd("ponto final", .pt, [.mark(".", terminal: true)]),
        cmd("ponto", .pt, [.mark(".", terminal: true)], ambiguous: true),
        cmd("abre parenteses", .pt, [.open("(")]),
        cmd("abrir parenteses", .pt, [.open("(")]),
        cmd("fecha parenteses", .pt, [.close(")")]),
        cmd("fechar parenteses", .pt, [.close(")")]),
        cmd("abre aspas", .pt, [.open("\"")]),
        cmd("abrir aspas", .pt, [.open("\"")]),
        cmd("fecha aspas", .pt, [.close("\"")]),
        cmd("fechar aspas", .pt, [.close("\"")]),
    ]

    private static let russian: [Command] = [
        cmd("новая строка", .ru, [.newline(1)]),
        cmd("с новой строки", .ru, [.newline(1)]),
        cmd("новый абзац", .ru, [.newline(2)]),
        cmd("запятая", .ru, [.mark(",", terminal: false)], notBetweenNumbers: true),
        cmd("точка с запятой", .ru, [.mark(";", terminal: false)]),
        cmd("двоеточие", .ru, [.mark(":", terminal: false)], ambiguous: true),
        cmd("вопросительный знак", .ru, [.mark("?", terminal: true)]),
        cmd("восклицательный знак", .ru, [.mark("!", terminal: true)]),
        cmd("точка", .ru, [.mark(".", terminal: true)], ambiguous: true),
        cmd("открыть скобку", .ru, [.open("(")]),
        cmd("закрыть скобку", .ru, [.close(")")]),
        cmd("открыть кавычки", .ru, [.open("\"")]),
        cmd("закрыть кавычки", .ru, [.close("\"")]),
    ]

    private static let ukrainian: [Command] = [
        cmd("новий рядок", .uk, [.newline(1)]),
        cmd("з нового рядка", .uk, [.newline(1)]),
        cmd("новий абзац", .uk, [.newline(2)]),
        cmd("кома", .uk, [.mark(",", terminal: false)], notBetweenNumbers: true),
        cmd("крапка з комою", .uk, [.mark(";", terminal: false)]),
        cmd("двокрапка", .uk, [.mark(":", terminal: false)], ambiguous: true),
        cmd("знак питання", .uk, [.mark("?", terminal: true)]),
        cmd("знак оклику", .uk, [.mark("!", terminal: true)]),
        cmd("крапка", .uk, [.mark(".", terminal: true)], ambiguous: true),
        cmd("відкрити дужку", .uk, [.open("(")]),
        cmd("закрити дужку", .uk, [.close(")")]),
        cmd("відкрити лапки", .uk, [.open("\"")]),
        cmd("закрити лапки", .uk, [.close("\"")]),
    ]

    private static let allLanguages = italian + english + german + spanish + french
        + portuguese + russian + ukrainian

    fileprivate struct Rules: Sendable {
        /// Candidates per folded first word, longest phrase first.
        let byFirstWord: [String: [Command]]

        init(_ commands: [Command]) {
            var map: [String: [Command]] = [:]
            for command in commands { map[command.words[0], default: []].append(command) }
            byFirstWord = map.mapValues { $0.sorted { $0.words.count > $1.words.count } }
        }

        /// The auto-safe words ("acapo", "newline") belong to every language's rules: they
        /// mean nothing else anywhere, and a short dictation may be recognised as the wrong
        /// language ("Ok acapo" reads as Portuguese).
        private static let safe = allLanguages.filter(\.autoSafe)
        private static func with(_ commands: [Command]) -> Rules {
            Rules(commands + safe.filter { candidate in !commands.contains { $0.words == candidate.words } })
        }

        static let it = with(italian)
        static let en = with(english)
        static let de = with(german)
        static let es = with(spanish)
        static let fr = with(french)
        static let pt = with(portuguese)
        static let ru = with(russian)
        static let uk = with(ukrainian)
        /// Language unknown: multi-word phrases that are not ordinary nouns, plus the few
        /// single words that are commands in no-one's prose.
        static let auto = Rules(allLanguages.filter {
            $0.autoSafe || ($0.words.count > 1 && !$0.ambiguous)
        })
        /// Every command of every language: only to decide whether recognition is worth running.
        static let everything = Rules(allLanguages)
        static let none = Rules([])

        static func code(_ language: String) -> String {
            language.lowercased()
                .split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
        }

        static func isAuto(_ language: String) -> Bool {
            let c = code(language)
            return c == "auto" || c.isEmpty
        }

        static func `for`(_ language: String) -> Rules {
            switch code(language) {
            case "it": return it
            case "en": return en
            case "de": return de
            case "es": return es
            case "fr": return fr
            case "pt": return pt
            case "ru": return ru
            case "uk": return uk
            case "auto", "": return auto
            default: return none
            }
        }
    }

    // MARK: - Rendering

    private struct Renderer {
        let tokens: [Token]
        let rules: Rules
        var out: [Character] = []
        /// Characters up to this count were produced by a command and must never be stripped.
        var protectedCount = 0
        /// Separator owed before the next word (a space after ",", nothing after "(" / "\n").
        var pending: String?
        var capitalizeNext = false
        var quoteDepth = 0
        var lastCommandEnd = -1

        init(tokens: [Token], rules: Rules) {
            self.tokens = tokens
            self.rules = rules
            out.reserveCapacity(tokens.reduce(0) { $0 + $1.text.count })
        }

        mutating func run() -> String {
            var i = 0
            while i < tokens.count {
                let token = tokens[i]
                if token.kind == .word {
                    switch match(at: i, allowAmbiguous: true) {
                    case .command(let command, let end):
                        var last: Action = .newline(0)
                        for action in command.actions { last = perform(action) }
                        lastCommandEnd = end
                        i = skip(after: end + 1, following: last)
                        continue
                    case .prose(let end):
                        // A command phrase used as prose ("togli il punto e virgola") is copied
                        // verbatim as a whole, so its tail ("virgola") cannot fire on its own.
                        for k in i...end {
                            if tokens[k].kind == .word { emitWord(tokens[k].text) } else { emitOther(tokens[k]) }
                        }
                        i = end + 1
                        continue
                    case nil:
                        break
                    }
                    if SpokenFormatting.fillers.contains(token.text.lowercased()) {
                        i = removeFiller(at: i)
                        continue
                    }
                    emitWord(token.text)
                } else {
                    emitOther(token)
                }
                i += 1
            }
            return String(out)
        }

        // MARK: Matching

        enum Match {
            case command(Command, end: Int)
            case prose(end: Int)
        }

        /// Candidates are tried longest first. When the longest phrase that literally matches
        /// is ruled out by its context, the whole span is prose: no shorter command inside it
        /// gets a second chance.
        func match(at i: Int, allowAmbiguous: Bool) -> Match? {
            guard let candidates = rules.byFirstWord[tokens[i].key] else { return nil }
            for command in candidates {
                if command.ambiguous && !allowAmbiguous { continue }
                guard let end = matchWords(command.words, from: i) else { continue }
                let blockedBefore = previousWord(before: i).map(command.blockedAfter.contains) ?? false
                let blockedAfter = nextWord(after: end).map { next in
                    command.blockedBefore.contains(next)
                        || command.blockedBefore.contains(where: { next.hasPrefix($0 + "'") })
                } ?? false
                if blockedBefore || blockedAfter {
                    if command.words.count > 1 { return .prose(end: end) }
                    continue
                }
                if command.notBetweenNumbers, isNumber(previousWord(before: i)),
                   isNumber(nextWord(after: end)) {
                    return .prose(end: end)
                }
                if command.ambiguous && !isStandalone(start: i, end: end) { continue }
                return .command(command, end: end)
            }
            return nil
        }

        func matchWords(_ words: [String], from start: Int) -> Int? {
            var k = start
            for (index, word) in words.enumerated() {
                if index > 0 {
                    // A space or a hyphen between the words: "a capo" and "a-capo" alike.
                    guard k + 2 < tokens.count,
                          (tokens[k + 1].kind == .space && !tokens[k + 1].hasNewline)
                            || tokens[k + 1].text == "-",
                          tokens[k + 2].kind == .word else { return nil }
                    k += 2
                }
                guard tokens[k].key == word else { return nil }
            }
            return k
        }

        func isNumber(_ word: String?) -> Bool {
            guard let word, !word.isEmpty else { return false }
            return word.allSatisfy(\.isNumber) || SpokenFormatting.numberWords.contains(word)
        }

        func previousWord(before i: Int) -> String? {
            var p = i - 1
            if p >= 0, tokens[p].kind == .space, !tokens[p].hasNewline { p -= 1 }
            guard p >= 0, p > lastCommandEnd, tokens[p].kind == .word else { return nil }
            return tokens[p].key
        }

        func nextWord(after end: Int) -> String? {
            var q = end + 1
            if q < tokens.count, tokens[q].kind == .space, !tokens[q].hasNewline { q += 1 }
            guard q < tokens.count, tokens[q].kind == .word else { return nil }
            return tokens[q].key
        }

        func isPauseBoundary(_ token: Token) -> Bool {
            (token.kind == .space && token.hasNewline)
                || (token.kind == .punct && SpokenFormatting.pause.contains(Character(token.text)))
        }

        /// A noun-like single-word command fires only between pauses, right before another
        /// command, or at the very end of the dictation.
        func isStandalone(start: Int, end: Int) -> Bool {
            let atEnd = tokens[(end + 1)...].allSatisfy {
                $0.kind == .space || ($0.kind == .punct && SpokenFormatting.pause.contains(Character($0.text)))
            }
            if atEnd { return true }

            var p = start - 1
            if p >= 0, tokens[p].kind == .space, !tokens[p].hasNewline { p -= 1 }
            let prevOK = p < 0 || p == lastCommandEnd || isPauseBoundary(tokens[p])

            var q = end + 1
            if q < tokens.count, tokens[q].kind == .space, !tokens[q].hasNewline { q += 1 }
            // Directly followed by another command ("virgola a capo") counts like the end of
            // the dictation: the user is clearly chaining formatting commands.
            if q < tokens.count, tokens[q].kind == .word, case .command = match(at: q, allowAmbiguous: false) {
                return true
            }
            let nextOK = q >= tokens.count || isPauseBoundary(tokens[q])
            return prevOK && nextOK
        }

        // MARK: Output

        mutating func perform(_ action: Action) -> Action {
            switch action {
            case .toggleQuote:
                return perform(quoteDepth > 0 ? .close("\"") : .open("\""))
            case .mark(let c, let terminal):
                strip(SpokenFormatting.pause)
                out.append(c)
                pending = " "
                capitalizeNext = terminal
            case .newline(let count):
                strip([","])
                out.append(contentsOf: repeatElement("\n", count: count))
                pending = nil
                capitalizeNext = true
            case .open(let c):
                strip([","])
                if let last = out.last, !last.isWhitespace, !"([\"“„«'".contains(last) {
                    out.append(" ")
                }
                out.append(c)
                pending = nil
                if c == "\"" { quoteDepth += 1 }
            case .close(let c):
                strip([","])
                out.append(c)
                pending = " "
                if c == "\"" { quoteDepth = max(0, quoteDepth - 1) }
            }
            protectedCount = out.count
            return action
        }

        /// Removes trailing horizontal whitespace and the given punctuation the ASR model put
        /// next to a spoken command, never reaching into command-produced output.
        mutating func strip(_ punctuation: Set<Character>) {
            while out.count > protectedCount, let last = out.last,
                  last == " " || last == "\t" || last == "\u{00A0}" || punctuation.contains(last) {
                out.removeLast()
            }
        }

        /// Skips the whitespace and model punctuation that trail a command.
        func skip(after start: Int, following action: Action) -> Int {
            var j = start
            while j < tokens.count {
                let token = tokens[j]
                switch (token.kind, action) {
                case (.space, .newline):
                    j += 1
                case (.space, _) where !token.hasNewline:
                    j += 1
                case (.punct, .close):
                    guard token.text == "," else { return j }
                    j += 1
                case (.punct, _) where SpokenFormatting.pause.contains(Character(token.text)):
                    j += 1
                default:
                    return j
                }
            }
            return j
        }

        mutating func emitWord(_ text: String) {
            if let separator = pending { out.append(contentsOf: separator); pending = nil }
            if capitalizeNext, let first = text.first, first.isLowercase {
                out.append(contentsOf: first.uppercased())
                out.append(contentsOf: text.dropFirst())
            } else {
                out.append(contentsOf: text)
            }
            capitalizeNext = false
        }

        mutating func emitOther(_ token: Token) {
            if let separator = pending {
                pending = nil
                let isPausePunct = token.kind == .punct
                    && SpokenFormatting.pause.contains(Character(token.text))
                if token.kind == .punct && !isPausePunct { out.append(contentsOf: separator) }
            }
            out.append(contentsOf: token.text)
        }

        mutating func removeFiller(at i: Int) -> Int {
            let wasCapitalized = tokens[i].text.first?.isUppercase ?? false
            var j = skipHorizontal(i + 1)
            // Hesitation ellipsis belongs to the filler: "ehm… allora", "ehm... allora".
            if j < tokens.count, tokens[j].text == "…" {
                j = skipHorizontal(j + 1)
            } else if j + 1 < tokens.count, tokens[j].text == ".", tokens[j + 1].text == "." {
                while j < tokens.count, tokens[j].text == "." { j += 1 }
                j = skipHorizontal(j)
            }
            if j < tokens.count, tokens[j].text == "," {
                // "Allora, ehm, andiamo" → keep the first comma, drop the filler's own.
                j = skipHorizontal(j + 1)
            } else if j < tokens.count, tokens[j].kind == .word {
                // "Allora ehm andiamo": the space before the filler already separates the words.
            } else {
                // Sentence end, newline or end of text: "andiamo, ehm." → "andiamo."
                strip([","])
            }
            if wasCapitalized {
                let trimmed = out.last(where: { $0 != " " && $0 != "\t" })
                if trimmed == nil || trimmed == "\n" || trimmed.map({ ".?!…".contains($0) }) == true {
                    capitalizeNext = true
                }
            }
            return j
        }

        func skipHorizontal(_ start: Int) -> Int {
            var j = start
            while j < tokens.count, tokens[j].kind == .space, !tokens[j].hasNewline { j += 1 }
            return j
        }
    }
}
