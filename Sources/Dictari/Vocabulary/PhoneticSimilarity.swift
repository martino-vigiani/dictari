// PhoneticSimilarity.swift
// Dictari — "does this saved phrase *sound* like a vocabulary term?", for history suggestions.
//
// The speech model does not misspell a name, it mishears it: "Dictari" comes back as
// "dettari", "Deepseek" as "Dipsick", "Sense Calibrator" as "Asense calibrator". Letter edit
// distance sees three or four unrelated letters there; a listener hears one small slip. This
// layer reads a folded spelling as sounds (the `.extended` rules of the shared `SoundClasses`
// table) and compares two sound sequences with an edit distance in which related sounds are
// cheap to swap and vowels are cheap to change.
//
// Scope, deliberately narrow: only `VocabularySuggestions` uses this, when the user asks
// Vocabulary for suggestions (a utility task off the main actor). It never runs on the
// dictation path and never rewrites text — the scan only *proposes* spellings that really
// occur in history, and the user approves each one. The dictation-time loose pass keeps its
// stricter `.base` classes and one-edit rule, because there a false positive silently
// rewrites a correct word; here it costs one "Dismiss".

import Foundation

enum PhoneticSimilarity {

    /// Normalised distance at or below which two sequences "sound alike" for the scan.
    /// Calibrated on real mishearings from Dictari history (`PhoneticVocabularyScanTests`,
    /// which prints every score): the loosest true one, "savagene" for "Subagent", scores
    /// 0.254; the closest ordinary-word traps score 0.29 ("martedì" / Martino), 0.32 ("code" /
    /// Codex) and 0.33 ("the code" / Claude Code). Short phrases get a stricter bar on top
    /// (`VocabularySuggestions.soundThreshold`).
    static let acceptThreshold = 0.28

    /// Stricter bar used when the first sound differs ("Asense" / "Sense", "Science" /
    /// "Sense"). Names are heard most reliably at their onset, so a different onset needs
    /// the rest of the phrase to be nearly identical.
    static let differentOnsetThreshold = 0.15

    // MARK: - Encoding

    /// Sound sequence of a folded (lowercase, accent-free) phrase. Spaces and hyphens are not
    /// sounds, so "sub agent" and "subagent" encode alike. Runs of the same sound collapse,
    /// because doubling is spelling ("dettari" / "detari"), not sound.
    static func encode(_ normalized: String) -> [Character] {
        let compact = String(normalized.filter { !$0.isWhitespace && $0 != "-" })
        var out: [Character] = []
        for symbol in SoundClasses.sounds(compact, rules: .extended) where out.last != symbol {
            out.append(symbol)
        }
        return out
    }

    // MARK: - Distance

    /// Weighted edit distance between two sound sequences.
    ///
    /// Costs, and why:
    /// - vowel inserted/deleted 0.4, vowel swapped 0.3: unstressed vowels are what the model
    ///   gets wrong most ("dictare", "sabagent") and what carries least identity;
    /// - consonant inserted/deleted 0.8: a missing consonant is a real slip ("di Tari"), but
    ///   one a listener still recovers from;
    /// - consonant swapped within a sound family (`pairCost`) 0.25–0.5, otherwise 1.0;
    /// - vowel ↔ consonant 1.0, except the glides i/j and u/v.
    static func distance(_ a: [Character], _ b: [Character]) -> Double {
        if a == b { return 0 }
        var previous = [Double](repeating: 0, count: b.count + 1)
        for j in b.indices { previous[j + 1] = previous[j] + indelCost(b[j]) }
        var current = previous
        for i in a.indices {
            current[0] = previous[0] + indelCost(a[i])
            for j in b.indices {
                current[j + 1] = min(previous[j + 1] + indelCost(a[i]),
                                     current[j] + indelCost(b[j]),
                                     previous[j] + substitutionCost(a[i], b[j]))
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// How much identity a sequence carries: consonants 1, vowels 0.5. Turns an absolute
    /// distance into a ratio, so "Codex" and "Sense Calibrator" share one threshold.
    static func weight(_ sounds: [Character]) -> Double {
        sounds.reduce(0) { $0 + indelCost($1) } / 0.8
    }

    /// Distance divided by the heavier side's weight: 0 is identical, about 0.1 is "vowel
    /// noise", about 0.25 is "one consonant slip plus vowel noise", above 0.4 is another word.
    static func normalizedDistance(_ a: [Character], _ b: [Character]) -> Double {
        let denominator = max(weight(a), weight(b))
        guard denominator > 0 else { return a == b ? 0 : 1 }
        return distance(a, b) / denominator
    }

    /// Whether two onsets are the same sound or the same family (`k`/`g`, `s`/`ʃ`), which the
    /// scan treats as "same first sound". Vowel onsets all count as one.
    static func sameOnset(_ a: [Character], _ b: [Character]) -> Bool {
        guard let x = a.first, let y = b.first else { return false }
        if x == y { return true }
        if vowelSounds.contains(x) && vowelSounds.contains(y) { return true }
        return (pairCost[pairKey(x, y)] ?? 1) <= 0.35
    }

    // MARK: - Cost table

    private static let vowelSounds: Set<Character> = ["a", "e", "i", "o", "u"]

    private static func indelCost(_ c: Character) -> Double {
        if vowelSounds.contains(c) { return 0.4 }
        if c == "j" { return 0.5 }
        return 0.8
    }

    private static func substitutionCost(_ a: Character, _ b: Character) -> Double {
        if a == b { return 0 }
        if vowelSounds.contains(a) && vowelSounds.contains(b) { return 0.3 }
        return pairCost[pairKey(a, b)] ?? 1.0
    }

    private static func pairKey(_ a: Character, _ b: Character) -> String {
        a < b ? String([a, b]) : String([b, a])
    }

    /// Sound families: voicing pairs, sibilants, nasals, liquids, and the letters the three
    /// languages read differently (soft c as s or tʃ, soft g as g or dʒ, th as t, d or f).
    /// Kept here, not in `SoundClasses`, because only the scan grades similarity; the
    /// corrector's loose pass matches classes exactly.
    private static let pairCost: [String: Double] = {
        let pairs: [(Character, Character, Double)] = [
            // voicing
            ("p", "b", 0.3), ("t", "d", 0.3), ("k", "g", 0.35), ("f", "v", 0.3), ("s", "z", 0.3),
            ("ç", "ʤ", 0.3),
            // sibilants and affricates
            ("s", "ʃ", 0.3), ("s", "ç", 0.35), ("ʃ", "ç", 0.3), ("z", "ç", 0.4), ("z", "ʃ", 0.4),
            ("z", "ʤ", 0.4), ("ʃ", "ʤ", 0.45),
            // soft/hard readings of c and g
            ("k", "ç", 0.5), ("g", "ʤ", 0.5), ("j", "ʤ", 0.4),
            // th
            ("θ", "t", 0.25), ("θ", "d", 0.3), ("θ", "f", 0.4), ("θ", "s", 0.4),
            // labials: b/v merge in fast Italian and Spanish-accented speech ("savagene")
            ("b", "v", 0.35), ("p", "f", 0.5), ("v", "u", 0.5),
            // nasals and liquids
            ("m", "n", 0.35), ("n", "ɲ", 0.3), ("l", "ʎ", 0.3), ("ʎ", "j", 0.4), ("l", "r", 0.5),
            // glide
            ("j", "i", 0.3),
        ]
        var table: [String: Double] = [:]
        for (a, b, cost) in pairs { table[pairKey(a, b)] = cost }
        return table
    }()
}
