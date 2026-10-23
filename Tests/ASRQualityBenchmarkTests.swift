// ASRQualityBenchmarkTests.swift
// Opt-in accuracy/latency benchmark for the transcription backends and their decoding knobs.
//
// Skipped unless DICTARI_ASR_BENCH=1 (pass it to xcodebuild as TEST_RUNNER_DICTARI_ASR_BENCH=1).
// It exists to justify decoding settings with numbers instead of folklore; the method and the
// results live in docs/research/2026-09-24-asr-quality-benchmark.md.
//
// Safety, because this runs on the developer's working Mac:
// - It never goes through `ParakeetEngine.warmUp` / `WhisperKitEngine.warmUp`: those verify
//   and (re)download into ~/Library/Application Support/Dictari/Models and write integrity
//   stamps there. Instead it loads *copies* of the models from DICTARI_ASR_BENCH_DIR
//   (default /tmp/dictari-asr-bench/models), so the user's real model folders are only ever
//   read by the `cp` that made the copies, never by this test.
// - Speech comes from `/usr/bin/say -o <file>` via AudioFixture: rendered to disk, never played.
// - No pasteboard, no key events, no microphone, no network.
//
// Output: one JSONL row per (configuration, clip) in the format scripts/benchmarks/score_asr.py
// reads, written to <DICTARI_ASR_BENCH_DIR>/results.jsonl. Score with:
//   python3 scripts/benchmarks/score_asr.py /tmp/dictari-asr-bench/results.jsonl --markdown

import CoreML
import FluidAudio
import Foundation
import Hub
import Tokenizers
import WhisperKit
import XCTest

final class ASRQualityBenchmarkTests: XCTestCase {

    func testBenchmarkBackendsAndDecodingOptions() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipIf(environment["DICTARI_ASR_BENCH"] != "1",
                      "Set DICTARI_ASR_BENCH=1 to run the ASR quality benchmark")

        let root = URL(fileURLWithPath: environment["DICTARI_ASR_BENCH_DIR"] ?? "/tmp/dictari-asr-bench",
                       isDirectory: true)
        // Optional comma-separated substrings; only configurations whose id contains one run.
        let only = environment["DICTARI_ASR_BENCH_ONLY"]?
            .split(separator: ",").map(String.init) ?? []
        func selected(_ id: String) -> Bool { only.isEmpty || only.contains { id.contains($0) } }

        let clips = try ASRBenchCorpus.clips(cacheDirectory: root.appendingPathComponent("audio"))
        print("ASR_BENCH clips=\(clips.count)")

        var rows: [[String: Any]] = []

        // MARK: Parakeet TDT v3

        let parakeetFolder = root.appendingPathComponent("models/parakeet-tdt-0.6b-v3")
        if FileManager.default.fileExists(atPath: parakeetFolder.path),
           selected("parakeet") {
            let runner = try await ParakeetBenchRunner(directory: parakeetFolder)
            let configurations: [(id: String, hint: (String) -> Language?)] = [
                ("parakeet-v3/auto", { _ in ParakeetEngine.languageHint(for: "auto") }),
                ("parakeet-v3/pinned", { ParakeetEngine.languageHint(for: $0) }),
            ].filter { selected($0.id) }
            // Parakeet decodes are ~100 ms, so run-order and machine-load drift swamp the
            // difference between configurations when they run one after the other. Interleave
            // them per clip, alternate which goes first, and keep the median of 3 repetitions.
            _ = try await runner.transcribe(clips[0].samples, language: nil)
            var timings = [[Duration]](repeating: [], count: configurations.count * clips.count)
            var texts = [String](repeating: "", count: configurations.count * clips.count)
            for (clipIndex, clip) in clips.enumerated() {
                for repetition in 0..<3 {
                    var order = Array(configurations.indices)
                    if (clipIndex + repetition) % 2 == 1 { order.reverse() }
                    for index in order {
                        let start = ContinuousClock.now
                        let text = try await runner.transcribe(
                            clip.samples, language: configurations[index].hint(clip.language))
                        timings[index * clips.count + clipIndex].append(ContinuousClock.now - start)
                        texts[index * clips.count + clipIndex] = text
                    }
                }
            }
            for (index, configuration) in configurations.enumerated() {
                for (clipIndex, clip) in clips.enumerated() {
                    let slot = index * clips.count + clipIndex
                    rows.append(clip.row(model: configuration.id, hypothesis: texts[slot],
                                         elapsed: timings[slot].sorted()[1], detected: nil))
                }
                print("ASR_BENCH done \(configuration.id)")
            }
        } else {
            print("ASR_BENCH skipping Parakeet: no copy at \(parakeetFolder.path)")
        }

        // MARK: Whisper (only variants already on disk; this test never downloads)

        for variant in ["openai_whisper-base", "openai_whisper-large-v3-v20240930_turbo"] {
            let folder = root.appendingPathComponent("models/\(variant)")
            let tokenizerFolder = root.appendingPathComponent(
                variant == "openai_whisper-base" ? "models/tokenizer-whisper-base"
                                                 : "models/tokenizer-whisper-large-v3")
            let short = variant == "openai_whisper-base" ? "whisper-base" : "whisper-turbo"
            guard FileManager.default.fileExists(atPath: folder.path),
                  WhisperBenchConfiguration.all.contains(where: { selected("\(short)/\($0.id)") }) else {
                print("ASR_BENCH skipping \(variant): no copy at \(folder.path)")
                continue
            }
            let runner = try await WhisperBenchRunner(modelFolder: folder, tokenizerFolder: tokenizerFolder)
            for configuration in WhisperBenchConfiguration.all where selected("\(short)/\(configuration.id)") {
                let id = "\(short)/\(configuration.id)"
                let tokens = runner.tokens
                _ = try await runner.transcribe(clips[0].samples,
                                                options: configuration.options(clips[0].language, tokens))
                for clip in clips {
                    let start = ContinuousClock.now
                    let (text, detected) = try await runner.transcribe(
                        clip.samples, options: configuration.options(clip.language, tokens))
                    let elapsed = ContinuousClock.now - start
                    rows.append(clip.row(model: id, hypothesis: text, elapsed: elapsed, detected: detected))
                }
                print("ASR_BENCH done \(id)")
            }
        }

        let output = root.appendingPathComponent(environment["DICTARI_ASR_BENCH_OUT"] ?? "results.jsonl")
        let lines = try rows.map { row -> String in
            let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            return String(decoding: data, as: UTF8.self)
        }
        try (lines.joined(separator: "\n") + "\n").write(to: output, atomically: true, encoding: .utf8)
        print("ASR_BENCH wrote \(rows.count) rows to \(output.path)")
        XCTAssertFalse(rows.isEmpty, "No backend ran: copy models into \(root.path)/models first")
    }
}

// MARK: - Whisper decoding configurations under test

/// Suppression lists resolved against the loaded tokenizer / model folder.
struct WhisperBenchTokens: Sendable {
    /// Only the pieces that open annotations like "[BLANK_AUDIO]", "[Musica]", "(applausi)",
    /// "♪" — not the upstream list's `@ : / " # - '`, which dictation needs.
    let nonSpeech: [Int]

    static let nonSpeechPieces = [
        "[", "Ġ[", "Ġ-[", "(", "Ġ(", "Ġ((", "Ġ(\"", "Ġ('", "Ġ-(",
        "âĻ", "ĠâĻ", "âĻª", "ĠâĻª", "âĻªâĻª", "ĠâĻªâĻª", "ĠâĻªâĻªâĻª",
        "âĻ«", "ĠâĻ«", "âĻ¬", "ĠâĻ¬", "ĠâĻ©",
    ]
    /// OpenAI's full default `suppress_tokens` from the model's generation_config.json.
    let upstream: [Int]
}

struct WhisperBenchConfiguration: Sendable {
    let id: String
    let options: @Sendable (_ language: String, _ tokens: WhisperBenchTokens) -> DecodingOptions

    /// Every knob variant starts from the shipping options so a row differs from "shipping"
    /// in exactly the knob its name says.
    static let all: [WhisperBenchConfiguration] = [
        .init(id: "shipping-auto") { _, _ in WhisperKitEngine.decodingOptions(for: "auto") },
        .init(id: "shipping-pinned") { language, _ in WhisperKitEngine.decodingOptions(for: language) },
        .init(id: "annotsuppress-auto") { _, tokens in
            var o = WhisperKitEngine.decodingOptions(for: "auto"); o.supressTokens = tokens.nonSpeech; return o
        },
        .init(id: "annotsuppress-pinned") { language, tokens in
            var o = WhisperKitEngine.decodingOptions(for: language); o.supressTokens = tokens.nonSpeech; return o
        },
        .init(id: "upstreamsuppress-pinned") { language, tokens in
            var o = WhisperKitEngine.decodingOptions(for: language); o.supressTokens = tokens.upstream; return o
        },
        .init(id: "fallback2-auto") { _, _ in
            var o = WhisperKitEngine.decodingOptions(for: "auto"); o.temperatureFallbackCount = 2; return o
        },
        .init(id: "fallback1-auto") { _, _ in
            var o = WhisperKitEngine.decodingOptions(for: "auto"); o.temperatureFallbackCount = 1; return o
        },
        .init(id: "fallback0-auto") { _, _ in
            var o = WhisperKitEngine.decodingOptions(for: "auto"); o.temperatureFallbackCount = 0; return o
        },
        .init(id: "suppressblank-auto") { _, _ in
            var o = WhisperKitEngine.decodingOptions(for: "auto"); o.suppressBlank = true; return o
        },
        .init(id: "nothresholds-auto") { _, _ in
            var o = WhisperKitEngine.decodingOptions(for: "auto")
            o.compressionRatioThreshold = nil
            o.logProbThreshold = nil
            o.firstTokenLogProbThreshold = nil
            return o
        },
        .init(id: "noprefill-auto") { _, _ in
            var o = WhisperKitEngine.decodingOptions(for: "auto"); o.usePrefillPrompt = false; return o
        },
        .init(id: "withtimestamps-auto") { _, _ in
            var o = WhisperKitEngine.decodingOptions(for: "auto"); o.withoutTimestamps = false; return o
        },
        .init(id: "fallback1-pinned") { language, _ in
            var o = WhisperKitEngine.decodingOptions(for: language); o.temperatureFallbackCount = 1; return o
        },
    ]
}

// MARK: - Runners (load model copies directly; never the engines' warm-up)

final class ParakeetBenchRunner: @unchecked Sendable {
    // @unchecked: written once in init, then only used sequentially by the single test.
    private let manager: AsrManager

    init(directory: URL) async throws {
        let configuration = AsrModels.defaultConfiguration()
        func open(_ name: String, computeUnits: MLComputeUnits) throws -> MLModel {
            let modelConfig = MLModelConfiguration()
            modelConfig.computeUnits = computeUnits
            modelConfig.allowLowPrecisionAccumulationOnGPU = true
            return try MLModel(contentsOf: directory.appendingPathComponent(name), configuration: modelConfig)
        }
        // Same four bundles, compute units and vocabulary parsing as ParakeetEngine.
        let names = ModelNames.ASR.self
        let data = try Data(contentsOf: directory.appendingPathComponent(names.vocabularyFile))
        let words = try JSONSerialization.jsonObject(with: data) as? [String: String] ?? [:]
        var vocabulary: [Int: String] = [:]
        for (key, value) in words { if let id = Int(key) { vocabulary[id] = value } }
        let models = AsrModels(
            encoder: try open(names.encoderFile, computeUnits: configuration.computeUnits),
            preprocessor: try open(names.preprocessorFile, computeUnits: .cpuOnly),
            decoder: try open(names.decoderFile, computeUnits: configuration.computeUnits),
            joint: try open(names.jointV3File, computeUnits: configuration.computeUnits),
            configuration: configuration, vocabulary: vocabulary, version: .v3
        )
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
    }

    /// Mirrors ParakeetEngine.transcribe: fresh decoder state per utterance, trimmed text.
    func transcribe(_ samples: [Float], language: Language?) async throws -> String {
        var state = try TdtDecoderState()
        let result = try await manager.transcribe(samples, decoderState: &state, language: language)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

final actor WhisperBenchRunner {
    // Same invariant as WhisperKitEngine.pipe: written once in init, read sequentially after.
    private nonisolated(unsafe) var kit: WhisperKit?
    nonisolated let tokens: WhisperBenchTokens

    init(modelFolder: URL, tokenizerFolder: URL) async throws {
        let configBytes = try Data(contentsOf: tokenizerFolder.appendingPathComponent("tokenizer_config.json"))
        let tokenizerBytes = try Data(contentsOf: tokenizerFolder.appendingPathComponent("tokenizer.json"))
        let config = try JSONDecoder().decode(Config.self, from: configBytes)
        let data = try JSONDecoder().decode(Config.self, from: tokenizerBytes)
        let tokenizer = VerifiedWhisperTokenizer(
            tokenizer: try PreTrainedTokenizer(tokenizerConfig: config, tokenizerData: data))
        let generation = try JSONSerialization.jsonObject(
            with: Data(contentsOf: modelFolder.appendingPathComponent("generation_config.json"))) as? [String: Any]
        tokens = WhisperBenchTokens(
            nonSpeech: WhisperBenchTokens.nonSpeechPieces.compactMap { tokenizer.convertTokenToId($0) }
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin },
            upstream: (generation?["suppress_tokens"] as? [Int] ?? [])
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin })
        print("ASR_BENCH suppress nonSpeech=\(tokens.nonSpeech) upstream=\(tokens.upstream.count)")

        let kit = try await WhisperKit(WhisperKitConfig(
            model: modelFolder.lastPathComponent,
            downloadBase: modelFolder.deletingLastPathComponent(),
            modelFolder: modelFolder.path,
            verbose: false, logLevel: .error, prewarm: false, load: false, download: false
        ))
        kit.tokenizer = tokenizer
        kit.textDecoder.isModelMultilingual = true
        try await kit.loadModels()
        _ = try await kit.transcribe(audioArray: [Float](repeating: 0, count: 8_000),
                                     decodeOptions: DecodingOptions(language: "en"))
        self.kit = kit
    }

    /// Returns the joined text (same joining/cleanup as WhisperKitEngine) and the language
    /// WhisperKit decoded with — the detected one when options leave it to auto-detection.
    nonisolated func transcribe(_ samples: [Float], options: DecodingOptions) async throws -> (String, String?) {
        guard let kit else { throw TranscriptionError.notReady }
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        let text = results.map(\.text).joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return (text, results.first?.language)
    }
}

// MARK: - Corpus

struct ASRBenchClip: Sendable {
    let id: String
    let language: String
    let scenario: String
    let voice: String
    let reference: String
    let samples: [Float]

    func row(model: String, hypothesis: String, elapsed: Duration, detected: String?) -> [String: Any] {
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        var row: [String: Any] = [
            "model_id": model, "clip_id": id, "language": language, "scenario": scenario,
            "reference": reference, "hypothesis": hypothesis, "voice": voice,
            "audio_duration_ms": Double(samples.count) / 16.0,
            "inference_ms": max(seconds * 1000, 0.001),
        ]
        if let detected { row["detected_language"] = detected }
        return row
    }
}

enum ASRBenchCorpus {

    /// Rotated per sentence so every language is heard in several voices (and both sexes).
    static let voices: [String: [String]] = [
        "it": ["Alice", "Eddy (Italian (Italy))", "Flo (Italian (Italy))", "Reed (Italian (Italy))"],
        "de": ["Anna", "Eddy (German (Germany))", "Flo (German (Germany))", "Reed (German (Germany))"],
        "en": ["Samantha", "Daniel", "Karen", "Moira"],
    ]

    /// Fast variants use `say -r 260`: well above conversational pace (~150–180 wpm).
    static let fastRate = 260
    /// Noise is mixed at this signal-to-noise ratio (dB), roughly a laptop mic in a quiet café.
    static let noiseSNR: Double = 15

    static func clips(cacheDirectory: URL) throws -> [ASRBenchClip] {
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        var clips: [ASRBenchClip] = []
        for language in ["it", "de", "en"] {
            let sentences = ASRBenchSentences.all[language]!
            let voices = voices[language]!
            for (index, sentence) in sentences.enumerated() {
                let voice = voices[index % voices.count]
                let number = String(format: "%02d", index + 1)
                let clean = try speech(sentence, voice: voice, rate: nil, cache: cacheDirectory)
                clips.append(.init(id: "\(language)-\(number)-clean", language: language, scenario: "clean",
                                   voice: voice, reference: sentence, samples: padded(clean)))
                // First ten also as noisy, next ten also as fast: 50 clips per language.
                if index < 10 {
                    clips.append(.init(id: "\(language)-\(number)-noisy", language: language, scenario: "noisy",
                                       voice: voice, reference: sentence,
                                       samples: withNoise(padded(clean), snr: noiseSNR, seed: UInt64(index + 1))))
                } else if index < 20 {
                    let fast = try speech(sentence, voice: voice, rate: fastRate, cache: cacheDirectory)
                    clips.append(.init(id: "\(language)-\(number)-fast", language: language, scenario: "fast",
                                       voice: voice, reference: sentence, samples: padded(fast)))
                }
            }
        }
        // Non-speech: what an accidental hotkey tap records. Any text here is a hallucination.
        clips.append(.init(id: "none-01-roomtone", language: "it", scenario: "nonspeech", voice: "-",
                           reference: "", samples: noise(count: 32_000, amplitude: 0.002, seed: 99)))
        clips.append(.init(id: "none-02-noise", language: "it", scenario: "nonspeech", voice: "-",
                           reference: "", samples: noise(count: 48_000, amplitude: 0.02, seed: 7)))
        return clips
    }

    /// `say` output cached as raw Float32 so reruns skip synthesis.
    private static func speech(_ text: String, voice: String, rate: Int?, cache: URL) throws -> [Float] {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in "\(voice)|\(rate ?? 0)|\(text)".utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        let file = cache.appendingPathComponent(String(hash, radix: 16) + ".f32")
        if let data = try? Data(contentsOf: file), !data.isEmpty {
            return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        let samples = try AudioFixture.samples(text: text, voice: voice, rate: rate)
        try samples.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: file)
        return samples
    }

    /// Real dictation has a beat of room before and after speech (key press / release).
    private static func padded(_ samples: [Float]) -> [Float] {
        [Float](repeating: 0, count: 4_000) + samples + [Float](repeating: 0, count: 6_400)
    }

    private static func withNoise(_ samples: [Float], snr: Double, seed: UInt64) -> [Float] {
        let speechPower = samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(max(samples.count, 1))
        let raw = noise(count: samples.count, amplitude: 1, seed: seed)
        let noisePower = raw.reduce(0.0) { $0 + Double($1 * $1) } / Double(max(raw.count, 1))
        let gain = Float((speechPower / pow(10, snr / 10) / noisePower).squareRoot())
        return zip(samples, raw).map { $0 + $1 * gain }
    }

    /// Deterministic low-passed noise (a one-pole filter over white): closer to fan/room noise
    /// than hiss, and reproducible across runs.
    private static func noise(count: Int, amplitude: Float, seed: UInt64) -> [Float] {
        var state = seed &* 6364136223846793005 &+ 1442695040888963407
        var previous: Float = 0
        var output = [Float](repeating: 0, count: count)
        for index in 0..<count {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let white = Float(Int64(bitPattern: state >> 11) & 0xFFFFF) / Float(0xFFFFF) * 2 - 1
            previous = 0.7 * previous + 0.3 * white
            output[index] = previous * amplitude * 2
        }
        return output
    }
}

// MARK: - Sentences
// Realistic dictation: emails, chat messages, dev jargon, names, places, numbers, punctuation.
// References are written the way the user would want the text typed (digits stay digits), so
// "245" read aloud and transcribed as words counts as an error — for every configuration alike.

enum ASRBenchSentences {
    static let all: [String: [String]] = ["it": italian, "de": german, "en": english]

    static let italian = [
        "Ciao Marco, ti confermo la riunione di domani alle dieci in sala conferenze.",
        "Gentile dottoressa Bianchi, le invio in allegato il preventivo aggiornato.",
        "Ho appena fatto il push del branch con la correzione del bug sul login.",
        "Ricordami di chiamare l'idraulico lunedì mattina per la perdita in cucina.",
        "Il deploy in produzione è fallito perché mancava una variabile d'ambiente.",
        "Possiamo spostare la call con il cliente di Milano a giovedì pomeriggio?",
        "La fattura numero 245 scade il 30 settembre, per favore controlla il pagamento.",
        "Buongiorno a tutti, oggi parliamo della nuova interfaccia dell'applicazione.",
        "Ho aggiornato il database e adesso le query sono molto più veloci.",
        "Grazie mille per l'aiuto, senza di te non avrei finito in tempo.",
        "Il treno per Firenze parte alle otto e un quarto dal binario sette.",
        "Per favore, manda il contratto firmato all'avvocato entro venerdì.",
        "Abbiamo ricevuto tre ordini nuovi dal negozio di Torino questa settimana.",
        "La build su Xcode si blocca durante la firma del codice.",
        "Mi piacerebbe prenotare un tavolo per quattro persone sabato sera.",
        "Il costo totale del progetto è di circa dodicimila euro più IVA.",
        "Stasera non riesco a venire, ho la febbre e resto a casa.",
        "Ti mando il link del documento condiviso su Google Drive.",
        "Nel prossimo sprint dobbiamo rifare la schermata delle impostazioni.",
        "L'appuntamento dal dentista è stato spostato a mercoledì prossimo.",
        "Il server risponde con un errore cinquecento quando carico un file grande.",
        "Caro Giovanni, auguri di buon compleanno e a presto!",
        "Ho letto la tua proposta e mi sembra un'ottima idea, procediamo.",
        "Il modello di trascrizione gira in locale sul Mac, senza connessione.",
        "Domani piove, quindi la partita di calcetto è rimandata.",
        "Mandami il numero di telefono del commercialista, per favore.",
        "La riunione con il team di design è alle quindici e trenta.",
        "Ho comprato il latte, il pane e due chili di mele.",
        "Il nuovo iPhone ha una batteria che dura tutto il giorno.",
        "Scusa il ritardo nella risposta, sono stata in ferie fino a ieri.",
    ]

    static let german = [
        "Hallo Thomas, ich bestätige den Termin morgen um zehn Uhr im Besprechungsraum.",
        "Sehr geehrte Frau Schneider, anbei sende ich Ihnen das aktualisierte Angebot.",
        "Ich habe gerade den Branch mit dem Bugfix für den Login gepusht.",
        "Erinnere mich daran, am Montag den Klempner wegen der Küche anzurufen.",
        "Das Deployment ist fehlgeschlagen, weil eine Umgebungsvariable gefehlt hat.",
        "Können wir das Gespräch mit dem Kunden aus München auf Donnerstag verschieben?",
        "Die Rechnung Nummer 245 ist am 30. September fällig, bitte prüf die Zahlung.",
        "Guten Morgen zusammen, heute sprechen wir über die neue Benutzeroberfläche.",
        "Ich habe die Datenbank aktualisiert und die Abfragen sind jetzt viel schneller.",
        "Vielen Dank für deine Hilfe, ohne dich hätte ich es nicht rechtzeitig geschafft.",
        "Der Zug nach Hamburg fährt um Viertel nach acht von Gleis sieben ab.",
        "Bitte schick den unterschriebenen Vertrag bis Freitag an den Anwalt.",
        "Wir haben diese Woche drei neue Bestellungen aus dem Laden in Köln bekommen.",
        "Der Build in Xcode hängt beim Signieren des Codes.",
        "Ich möchte gerne einen Tisch für vier Personen am Samstagabend reservieren.",
        "Die Gesamtkosten des Projekts liegen bei ungefähr zwölftausend Euro plus Mehrwertsteuer.",
        "Heute Abend kann ich leider nicht kommen, ich habe Fieber und bleibe zu Hause.",
        "Ich schicke dir den Link zum geteilten Dokument in Google Drive.",
        "Im nächsten Sprint müssen wir den Einstellungsbildschirm neu bauen.",
        "Der Termin beim Zahnarzt wurde auf nächsten Mittwoch verschoben.",
        "Der Server antwortet mit einem Fehler fünfhundert, wenn ich eine große Datei hochlade.",
        "Lieber Johannes, alles Gute zum Geburtstag und bis bald!",
        "Ich habe deinen Vorschlag gelesen und finde ihn sehr gut, lass uns loslegen.",
        "Das Transkriptionsmodell läuft lokal auf dem Mac, ganz ohne Internetverbindung.",
        "Morgen soll es regnen, deshalb wird das Fußballspiel verschoben.",
        "Schick mir bitte die Telefonnummer von unserem Steuerberater.",
        "Das Meeting mit dem Designteam ist um halb vier.",
        "Ich habe Milch, Brot und zwei Kilo Äpfel gekauft.",
        "Das neue iPhone hat einen Akku, der den ganzen Tag hält.",
        "Entschuldige die späte Antwort, ich war bis gestern im Urlaub.",
    ]

    static let english = [
        "Hi Sarah, just confirming our meeting tomorrow at ten in the conference room.",
        "Dear Mr. Johnson, please find attached the updated quote for the project.",
        "I just pushed the branch with the fix for the login bug.",
        "Remind me to call the plumber on Monday morning about the kitchen leak.",
        "The production deploy failed because an environment variable was missing.",
        "Can we move the call with the client from Chicago to Thursday afternoon?",
        "Invoice number 245 is due on September 30, please check the payment.",
        "Good morning everyone, today we're going to talk about the new user interface.",
        "I updated the database and the queries are now much faster.",
        "Thanks so much for your help, I couldn't have finished on time without you.",
        "The train to Boston leaves at a quarter past eight from platform seven.",
        "Please send the signed contract to the lawyer by Friday.",
        "We received three new orders from the store in Seattle this week.",
        "The Xcode build hangs while code signing.",
        "I'd like to book a table for four people on Saturday evening.",
        "The total cost of the project is around twelve thousand dollars plus tax.",
        "I can't make it tonight, I have a fever and I'm staying home.",
        "I'll send you the link to the shared document on Google Drive.",
        "In the next sprint we need to rebuild the settings screen.",
        "The dentist appointment has been moved to next Wednesday.",
        "The server returns a five hundred error when I upload a large file.",
        "Dear Michael, happy birthday and see you soon!",
        "I read your proposal and I think it's a great idea, let's go ahead.",
        "The transcription model runs locally on the Mac without an internet connection.",
        "It's going to rain tomorrow, so the soccer game is postponed.",
        "Could you send me our accountant's phone number, please?",
        "The meeting with the design team is at three thirty.",
        "I bought milk, bread and two pounds of apples.",
        "The new iPhone has a battery that lasts all day.",
        "Sorry for the late reply, I was on vacation until yesterday.",
    ]
}
