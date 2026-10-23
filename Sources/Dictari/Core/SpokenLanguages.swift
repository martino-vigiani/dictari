// SpokenLanguages.swift
// Dictari — "Languages I speak": what "Auto-detect" is allowed to choose between.
//
// Why this exists: Parakeet, the default model, has no language identification at all — it
// decodes whatever it hears, so "Auto" and "Italian" produce identical transcripts. Measured on
// the developer's own history (535 dictations, Jun–Sep 2026) long dictations were fine
// (1,484 of 1,499 sentences Italian), but very short ones drifted to English or Portuguese:
// "Yeah." for "Sì", "Chao"/"Tchau" for "Ciao", "Why?" for "Perché?". Whisper does detect the
// language, but among all 99 it knows. Knowing which languages the user actually speaks lets
// us (1) pin the language when there is only one, (2) restrict Whisper's detection to the set,
// and (3) repair the short-utterance drift for people who do not speak English.

import Foundation
import NaturalLanguage
import Synchronization

enum SpokenLanguages {
    /// The user's current set, published by the coordinator's `configureComponents()` and read
    /// by `WhisperKitEngine` off-actor at transcription time. A process-wide value rather than
    /// an engine property because engines are rebuilt on every model switch, and the set is a
    /// user preference, not per-engine state. `Mutex` makes the cross-isolation read sound.
    static let current = Mutex<[String]>([])

    /// Languages Dictari can dictate, in the order the pickers show them, with their names in
    /// the interface language. The codes are what settings store; `name` is display only.
    static let supported: [(code: String, name: String)] = supportedCodesInOrder.map { ($0, displayName(for: $0)) }

    static let supportedCodesInOrder = ["en", "it", "es", "fr", "de", "pt", "ru", "uk"]

    static let supportedCodes: Set<String> = Set(supportedCodesInOrder)

    /// English names, used when the system has no name for a code in the display language.
    private static let englishNames: [String: String] = [
        "en": "English", "it": "Italian", "es": "Spanish", "fr": "French",
        "de": "German", "pt": "Portuguese", "ru": "Russian", "uk": "Ukrainian",
    ]

    /// A language's name in the language the interface is shown in ("Italian" in English,
    /// "Italiano" in Italian, "Italienisch" in German), capitalised for a list or a picker.
    ///
    /// The locale is the app's own localization, not `Locale.current`: a Mac set to Dutch shows
    /// Dictari in English (no Dutch translation), and the names must match the window around them.
    static func displayName(for code: String, in locale: Locale = interfaceLocale) -> String {
        guard let name = locale.localizedString(forLanguageCode: code), !name.isEmpty else {
            return englishNames[code] ?? code
        }
        // Several languages write language names in lower case mid-sentence ("italiano",
        // "anglais"); as a standalone label they take a capital, like English.
        return name.prefix(1).uppercased(with: locale) + name.dropFirst()
    }

    /// The localization the app's strings are being shown in.
    static var interfaceLocale: Locale {
        Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
    }

    /// The default set when the user never chose: the Mac's own preferred languages that
    /// Dictari supports, in the Mac's order. A Mac set to English and Italian gets both.
    static func defaults(preferred: [String] = Locale.preferredLanguages) -> [String] {
        var result: [String] = []
        for identifier in preferred {
            let code = baseCode(identifier)
            if supportedCodes.contains(code), !result.contains(code) { result.append(code) }
        }
        return result.isEmpty ? ["en"] : result
    }

    /// Keeps only supported, de-duplicated codes; never returns an empty set.
    static func sanitized(_ codes: [String]?, preferred: [String] = Locale.preferredLanguages) -> [String] {
        var result: [String] = []
        for code in codes ?? [] where supportedCodes.contains(code) && !result.contains(code) {
            result.append(code)
        }
        return result.isEmpty ? defaults(preferred: preferred) : result
    }

    /// The language actually sent to the engine. "Auto" with a single spoken language is that
    /// language: for Whisper that skips the detection pass and lowers WER (−1 to −3 pt on
    /// Italian in docs/research/2026-09-24-asr-quality-benchmark.md), for Parakeet it is free.
    static func resolve(_ language: String, spoken: [String]) -> String {
        guard isAuto(language), spoken.count == 1, let only = spoken.first else { return language }
        return only
    }

    static func isAuto(_ language: String) -> Bool {
        let code = baseCode(language)
        return code == "auto" || code.isEmpty
    }

    static func baseCode(_ identifier: String) -> String {
        identifier.lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
    }

    /// Whisper's language log-probabilities narrowed to the spoken set. Nil when none of the
    /// spoken languages scored, so the caller keeps Whisper's own choice.
    static func best(of probabilities: [String: Float], among spoken: [String]) -> String? {
        spoken
            .compactMap { code in probabilities[code].map { (code, $0) } }
            .max { $0.1 < $1.1 }?.0
    }

    /// The language a finished transcript is written in, among the spoken ones — recorded in
    /// History instead of the literal "auto", so drift can finally be measured. Nil when the
    /// text is too short or mixed to tell.
    static func detected(in text: String, among spoken: [String]) -> String? {
        let map: [String: NLLanguage] = [
            "en": .english, "it": .italian, "es": .spanish, "fr": .french,
            "de": .german, "pt": .portuguese, "ru": .russian, "uk": .ukrainian,
        ]
        let constraints = spoken.compactMap { map[$0] }
        guard constraints.count > 1 else { return spoken.first }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = constraints
        recognizer.processString(text)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              confidence >= 0.7 else { return nil }
        return language.rawValue
    }
}

// MARK: - Short-utterance drift

/// Repairs the one failure pattern the history shows: a dictation of a word or two that the
/// model wrote in English or Portuguese although the user speaks neither ("Yeah." for "Sì").
///
/// Deliberately narrow, because it rewrites what the model heard:
/// - only when English is NOT among the spoken languages (someone who speaks English may well
///   have said "yeah");
/// - only for whole utterances of at most three words;
/// - only exact, known drift forms, mapped into the user's main language (the first in the
///   set). Anything else is left alone.
enum ShortUtteranceFix {
    static let maximumWords = 3

    static func apply(_ text: String, spoken: [String]) -> String {
        guard !spoken.contains("en"), let main = spoken.first,
              let table = replacements[main] else { return text }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty, words.count <= maximumWords else { return text }

        // Split off the closing punctuation so "Yeah." and "Yeah" share one table entry.
        var body = trimmed
        var ending = ""
        while let last = body.last, ".!?…,".contains(last) {
            ending = String(last) + ending
            body.removeLast()
        }
        let key = body.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        guard let replacement = table[key] else { return text }
        return replacement + ending
    }

    /// Keys are folded (lowercase, no accents). Sources: English/Portuguese forms observed in
    /// the developer's history, plus their obvious siblings.
    private static let replacements: [String: [String: String]] = [
        "it": [
            "yeah": "Sì", "yes": "Sì", "yep": "Sì", "why": "Perché",
            "chao": "Ciao", "tchau": "Ciao", "cha chao": "Ciao", "chau": "Ciao",
            "thank you": "Grazie", "thanks": "Grazie", "thank": "Grazie",
        ],
        "de": [
            "yeah": "Ja", "yes": "Ja", "yep": "Ja", "why": "Warum",
            "thank you": "Danke", "thanks": "Danke", "thank": "Danke",
        ],
        "es": [
            "yeah": "Sí", "yes": "Sí", "yep": "Sí", "why": "Por qué",
            "chao": "Chao", "tchau": "Chao",
            "thank you": "Gracias", "thanks": "Gracias", "thank": "Gracias",
        ],
        "fr": [
            "yeah": "Oui", "yes": "Oui", "yep": "Oui", "why": "Pourquoi",
            "thank you": "Merci", "thanks": "Merci", "thank": "Merci",
        ],
        "pt": [
            "yeah": "Sim", "yes": "Sim", "yep": "Sim", "why": "Por quê",
            "chao": "Tchau", "thank you": "Obrigado", "thanks": "Obrigado", "thank": "Obrigado",
        ],
    ]
}
