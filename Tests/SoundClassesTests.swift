import XCTest

/// The dictation-time loose pass must not change when the sound classes move into the shared
/// `SoundClasses` table. `legacyPhonetic` is a verbatim copy of `VocabularyCorrector.phonetic`
/// as of 2687e95, kept here as the oracle: if `.base` ever drifts, these tests say so before
/// a dictated word gets rewritten differently.
final class SoundClassesTests: XCTestCase {

    // MARK: - Frozen oracle (do not edit)

    private static let legacyVowels: Set<Character> = ["a", "e", "i", "o", "u", "y"]

    private static func legacyPhonetic(_ normalized: String) -> (key: String, vowels: String) {
        let letters = Array(normalized)
        var key = ""
        var vowels = ""
        var i = 0

        func emit(_ symbol: Character) {
            if key.last != symbol { key.append(symbol) }
        }
        func at(_ offset: Int) -> Character? {
            i + offset < letters.count ? letters[i + offset] : nil
        }

        while i < letters.count {
            let ch = letters[i]
            var consumed = 1
            switch ch {
            case _ where legacyVowels.contains(ch):
                vowels.append(ch)
            case "c":
                emit("k")
                if at(1) == "h" || at(1) == "k" { consumed = 2 }
            case "k", "q":
                emit("k")
            case "s":
                if at(1) == "h" {
                    emit("ʃ"); consumed = 2
                } else if at(1) == "c", at(2) == "h" {
                    emit("ʃ"); consumed = 3
                } else if at(1) == "c", let v = at(2), v == "e" || v == "i" {
                    emit("ʃ"); consumed = 2
                } else {
                    emit("s")
                }
            case "g":
                if at(1) == "h" {
                    emit("g"); consumed = 2
                } else if at(1) == "n" {
                    emit("ɲ"); consumed = 2
                } else {
                    emit("g")
                }
            case "n":
                if at(1) == "y", let v = at(2), legacyVowels.contains(v), v != "y" {
                    emit("ɲ"); consumed = 2
                } else {
                    emit("n")
                }
            case "t":
                if at(1) == "s" || at(1) == "z" {
                    emit("z"); consumed = 2
                } else {
                    emit("t")
                }
            case "z":
                emit("z")
            case "v", "w":
                emit("v")
            case "p":
                if at(1) == "h" {
                    emit("f"); consumed = 2
                } else {
                    emit("p")
                }
            case "x":
                emit("k"); emit("s")
            case "ß":
                emit("s")
            case "h":
                break
            default:
                emit(ch)
            }
            i += consumed
        }
        return (key, vowels)
    }

    // MARK: - Byte identity of the corrector's pass

    private static let corpus: [String] = [
        "chubernetis", "kubernetes", "bologna", "bolonya", "pizza", "pitsa", "scena", "shena",
        "scala", "shala", "schule", "science", "scienza", "sciopero", "cia", "ciao", "gioco",
        "gli", "figlio", "aglio", "the", "thanks", "tschuss", "deutsch", "cqua", "acqua",
        "ghiaccio", "gnocchi", "nyah", "canyon", "yoga", "york", "system", "dictari", "dettari",
        "deepseek", "dipsick", "claude", "cloud", "clode", "codex", "codeks", "subagent",
        "savagene", "subagence", "dualsense", "martino", "martina", "strasse", "straße", "phase",
        "whisper", "parakeet", "xylophone", "quattro", "zucchero", "tz", "ts", "h", "", "y",
        "yy", "sch", "sc", "scy", "gh", "ph", "x", "c", "cc", "kk", "a1b2", "über", "eeaa",
        "aieou", "sciaeui", "glia", "gnyo", "thth", "tsch", "ckq", "chk",
    ]

    func testBaseRulesReproduceTheOriginalCorrectorKeyExactly() {
        for word in Self.corpus {
            let now = VocabularyCorrector.phonetic(word)
            let then = Self.legacyPhonetic(word)
            XCTAssertEqual(now.key, then.key, word)
            XCTAssertEqual(now.vowels, then.vowels, word)
        }
    }

    /// Exhaustive over every string of up to four letters drawn from the letters the rules
    /// branch on, plus a deterministic random sample of longer strings: the rewrite changed
    /// structure (a shared table, collapsing moved to the caller), so equality on hand-picked
    /// words is not enough.
    func testBaseRulesMatchTheOracleExhaustivelyAndOnRandomStrings() {
        let alphabet: [Character] = ["a", "e", "i", "y", "c", "h", "k", "q", "s", "g", "n", "t", "z",
                                     "p", "x", "w", "v", "l", "ß"]
        var strings: [String] = [""]
        var frontier: [String] = [""]
        for _ in 1...4 {
            frontier = frontier.flatMap { prefix in alphabet.map { prefix + String($0) } }
            strings += frontier
        }
        var generator = SplitMix64(seed: 0xD1C7A21)
        for _ in 0..<20_000 {
            let length = Int(generator.next() % 14) + 5
            strings.append(String((0..<length).map { _ in alphabet[Int(generator.next() % UInt64(alphabet.count))] }))
        }
        var mismatches = 0
        for word in strings {
            let now = VocabularyCorrector.phonetic(word)
            let then = Self.legacyPhonetic(word)
            if now.key != then.key || now.vowels != then.vowels {
                mismatches += 1
                if mismatches <= 5 { XCTFail("\(word): \(now) != \(then)") }
            }
        }
        XCTAssertEqual(mismatches, 0, "checked \(strings.count) strings")
    }

    // MARK: - Extended rules (history scan only)

    private func encoded(_ word: String) -> String {
        String(PhoneticSimilarity.encode(word))
    }

    func testExtendedRulesReadEachLanguagesSpellingOfTheSameSound() {
        XCTAssertEqual(encoded("codex"), encoded("codeks"))
        XCTAssertEqual(encoded("deepseek"), encoded("dipsick"))
        XCTAssertEqual(encoded("deepsick"), encoded("dipsick"))
        XCTAssertEqual(encoded("claude"), encoded("clode"))
        XCTAssertEqual(encoded("philosophy"), encoded("filosofi"))
        XCTAssertEqual(encoded("scena"), encoded("shena"))
        XCTAssertEqual(encoded("sciopero"), encoded("shopero"))
        XCTAssertEqual(encoded("ciao"), encoded("çao"))
        XCTAssertEqual(encoded("figlio"), "fiʎo")
        XCTAssertEqual(encoded("gnocchi"), "ɲoki")
        XCTAssertEqual(encoded("thanks"), "θanks")
        XCTAssertEqual(encoded("pizza"), encoded("pitsa"))
        XCTAssertEqual(encoded("dettari"), encoded("detari"), "doubling is spelling, not sound")
        XCTAssertEqual(encoded("york"), "jork")
        XCTAssertEqual(encoded("system"), "sistem")
        XCTAssertEqual(encoded("sub agent"), encoded("subagent"), "spaces and hyphens are not sounds")
        XCTAssertEqual(encoded("dual-sense"), encoded("dualsense"))
    }

    func testExtendedRulesKeepDistinctSoundsDistinct() {
        XCTAssertNotEqual(encoded("scala"), encoded("shala"))
        XCTAssertNotEqual(encoded("codice"), encoded("codex"))
        XCTAssertNotEqual(encoded("martedi"), encoded("martino"))
    }

    // MARK: - Weighted distance

    func testSimilarSoundsCostLessThanUnrelatedOnes() {
        func d(_ a: String, _ b: String) -> Double {
            PhoneticSimilarity.distance(PhoneticSimilarity.encode(a), PhoneticSimilarity.encode(b))
        }
        XCTAssertEqual(d("martino", "martino"), 0)
        XCTAssertLessThan(d("martino", "martina"), d("martino", "martilo"), "a vowel swap is cheaper than a consonant swap")
        XCTAssertLessThan(d("bada", "pada"), d("bada", "mada"), "voicing pairs are cheap")
        XCTAssertLessThan(d("sabagent", "savagent"), d("sabagent", "sakagent"), "b/v merge")
        XCTAssertLessThan(d("sensa", "shensa"), d("sensa", "rensa"), "sibilants are one family")
        XCTAssertLessThan(d("cloth", "clod"), d("cloth", "clom"), "th sits between t, d and f")
        XCTAssertLessThan(d("dictari", "dicktari"), 0.01)
        // Symmetric, and zero only for identical sequences.
        for (a, b) in [("subagent", "savagene"), ("claudecode", "cloudcode"), ("deepseek", "dipsi")] {
            XCTAssertEqual(d(a, b), d(b, a), accuracy: 1e-9)
            XCTAssertGreaterThan(d(a, b), 0)
        }
    }

    func testNormalizedDistanceSeparatesMishearingsFromOtherWords() {
        func n(_ a: String, _ b: String) -> Double {
            let value = PhoneticSimilarity.normalizedDistance(PhoneticSimilarity.encode(a), PhoneticSimilarity.encode(b))
            print(String(format: "[phonetic-scan]   %@ ~ %@: %.3f", a, b, value))
            return value
        }
        // Mishearings from real history.
        for (heard, term) in [("codeks", "codex"), ("dipsick", "deepseek"), ("dettari", "dictari"),
                              ("asensecalibrator", "sensecalibrator"), ("clothcode", "claudecode"),
                              ("savagene", "subagent")] {
            XCTAssertLessThanOrEqual(n(heard, term), PhoneticSimilarity.acceptThreshold, "\(heard) → \(term)")
        }
        // Ordinary words that share letters but not sound.
        for (word, term) in [("codice", "codex"), ("code", "codex"), ("martedi", "martino"),
                             ("thecode", "claudecode"), ("cloud", "claudecode"), ("sabato", "subagent")] {
            XCTAssertGreaterThan(n(word, term), PhoneticSimilarity.acceptThreshold, "\(word) → \(term)")
        }
    }
}

/// Deterministic PRNG so the random sample is the same on every run.
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
