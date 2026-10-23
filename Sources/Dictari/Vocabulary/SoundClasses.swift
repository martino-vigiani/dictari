// SoundClasses.swift
// Dictari — the one table of Italian/English/German spelling-to-sound classes.
//
// Two features need to know that "ch", "ck", "k" and "q" are one sound, that "ph" is "f" and
// that "gn" and "ny" are the same nasal:
//
// - the dictation-time loose pass in `VocabularyCorrector` (`phonetic`), which may rewrite a
//   word the engine was unsure of, so its rules are deliberately few (`.base`);
// - the history scan in `VocabularySuggestions` (via `PhoneticSimilarity`), which only
//   proposes spellings for the user to approve, so it adds more readings (`.extended`).
//
// Both read this table so a new rule cannot drift between them. Anything `.extended` adds is
// strictly additive and gated on the flag: with `.base` the output is exactly what the
// corrector has always produced, which `SoundClassesTests` pins against a frozen copy of the
// original encoder. Change `.base` only with a test that proves the corrector gets safer.

import Foundation

enum SoundClasses {

    enum Rules: Sendable {
        /// The corrector's classes: c k q ch ck → k, gh → g, z ts tz → z, v w → v,
        /// f ph → f, sh sch sc(e/i) → ʃ, gn ny → ɲ, x → ks, ß → s, silent h.
        /// Vowels (a e i o u y) pass through as letters.
        case base
        /// `.base` plus readings only the history scan uses: soft c (`ç`) and soft g (`ʤ`)
        /// before e/i/y, `gli` → ʎ, `th` → θ, `tsch` → ç, the i that only softens
        /// ("cia", "gio", "scia"), y as i or an initial glide `j`, and vowel digraphs
        /// (ee ea ie → i, oo → u, au ou → o, ei → ai, eu → oi).
        case extended
    }

    /// Vowel letters under `.base`. `.extended` never emits `y`; it becomes `i` or `j`.
    static let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y"]

    /// The raw sound sequence of a folded (lowercase, accent-free) word: one `Character` per
    /// sound, vowels included, **no** collapsing. Each consumer collapses in its own way —
    /// the corrector keys on consonants only, the scan on the whole sequence.
    static func sounds(_ normalized: String, rules: Rules) -> [Character] {
        let letters = Array(normalized)
        let extended = rules == .extended
        var out: [Character] = []
        out.reserveCapacity(letters.count + 2)
        var i = 0

        func at(_ offset: Int) -> Character? {
            i + offset < letters.count ? letters[i + offset] : nil
        }
        func isVowel(_ c: Character?) -> Bool { c.map { vowels.contains($0) } ?? false }
        /// `.base` softens sc only before e/i; `.extended` also before y ("Scylla").
        func isFront(_ c: Character?) -> Bool {
            c == "e" || c == "i" || (extended && c == "y")
        }

        while i < letters.count {
            let ch = letters[i]
            var consumed = 1
            switch ch {
            case _ where vowels.contains(ch):
                guard extended else { out.append(ch); break }
                switch (ch, at(1)) {
                case ("e", "e"), ("e", "a"), ("i", "e"):
                    out.append("i"); consumed = 2
                case ("o", "o"):
                    out.append("u"); consumed = 2
                case ("a", "u"), ("o", "u"):
                    out.append("o"); consumed = 2
                case ("e", "i"):
                    out.append("a"); out.append("i"); consumed = 2
                case ("e", "u"):
                    out.append("o"); out.append("i"); consumed = 2
                case ("y", _):
                    // Initial y before a vowel is a glide ("yes"); elsewhere it spells i.
                    out.append(i == 0 && isVowel(at(1)) ? "j" : "i")
                default:
                    out.append(ch)
                }
            case "c":
                if at(1) == "h" || at(1) == "k" {
                    out.append("k"); consumed = 2
                } else if extended, at(1) == "q" {
                    out.append("k"); consumed = 2
                } else if extended, isFront(at(1)) {
                    out.append("ç")
                    if at(1) == "i", isVowel(at(2)) { consumed = 2 }
                } else {
                    out.append("k")
                }
            case "k", "q":
                out.append("k")
            case "s":
                if at(1) == "h" {
                    out.append("ʃ"); consumed = 2
                } else if at(1) == "c", at(2) == "h" {
                    out.append("ʃ"); consumed = 3
                } else if at(1) == "c", isFront(at(2)) {
                    out.append("ʃ"); consumed = 2
                    if extended, at(2) == "i", isVowel(at(3)) { consumed = 3 }
                } else {
                    out.append("s")
                }
            case "g":
                if at(1) == "h" {
                    out.append("g"); consumed = 2
                } else if at(1) == "n" {
                    out.append("ɲ"); consumed = 2
                } else if extended, at(1) == "l", at(2) == "i" {
                    out.append("ʎ")
                    consumed = isVowel(at(3)) ? 3 : 2
                } else if extended, isFront(at(1)) {
                    out.append("ʤ")
                    if at(1) == "i", isVowel(at(2)) { consumed = 2 }
                } else {
                    out.append("g")
                }
            case "n":
                if at(1) == "y", let v = at(2), vowels.contains(v), v != "y" {
                    out.append("ɲ"); consumed = 2
                } else {
                    out.append("n")
                }
            case "t":
                if extended, at(1) == "h" {
                    out.append("θ"); consumed = 2
                } else if extended, at(1) == "s", at(2) == "c", at(3) == "h" {
                    out.append("ç"); consumed = 4
                } else if at(1) == "s" || at(1) == "z" {
                    out.append("z"); consumed = 2
                } else {
                    out.append("t")
                }
            case "z":
                out.append("z")
            case "v", "w":
                out.append("v")
            case "p":
                if at(1) == "h" { out.append("f"); consumed = 2 } else { out.append("p") }
            case "x":
                out.append("k"); out.append("s")
            case "ß":
                out.append("s")
            case "h":
                break
            default:
                out.append(ch)
            }
            i += consumed
        }
        return out
    }
}
