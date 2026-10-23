// SettingsSearchCatalog.swift
// Dictari — every searchable section, card and row of the settings window.
//
// Titles are the exact labels on screen, so a result reads like the row it leads to. Keywords
// carry what people actually type: plain words ("mic", "beep"), and Italian, because most of
// Dictari's users think in Italian even when the interface is English. `anchor` names the
// `.settingsSearchAnchor(...)` the row carries in its view; `SettingsSearchTests` checks that
// every anchor below exists in the sources, so renaming one in a view fails a test instead of
// silently breaking a result.
//
// When you add a row to a settings view: add an entry here, in sidebar order, and anchor it.
//
// Localization: title, card, detail and keywords are `LocalizedStringResource`s, extracted into
// Localizable.xcstrings. A title or card must be the SAME English literal the view shows, so
// both share one catalog key and one translation (the result then reads exactly like the row).
// Keywords are translated as a list of search terms, not as prose; the English source list is
// indexed as well whenever the display language differs (see `SettingsSearchEntry.english`).
// Ids and anchors are never localized.

import Foundation

enum SettingsSearchCatalog {
    static func entries() -> [SettingsSearchEntry] {
        var list: [SettingsSearchEntry] = []

        /// "a, b; c, d" → primary synonyms a and b, secondary c and d. Without a ";" only the
        /// first phrase is primary.
        func parse(_ keywords: String) -> (all: [String], primary: Int) {
            func phrases(_ text: Substring) -> [String] {
                text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
            let parts = keywords.split(separator: ";", maxSplits: 1)
            guard parts.count == 2 else { return (phrases(keywords[...]), 1) }
            let primary = phrases(parts[0])
            return (primary + phrases(parts[1]), primary.count)
        }

        /// Resolves the resources in the display language and, when that is not the English
        /// source, keeps the English wording too so it stays searchable.
        func entry(
            id: String, title: LocalizedStringResource, section: SettingsSection,
            card: LocalizedStringResource?, detail: LocalizedStringResource,
            keywords: LocalizedStringResource, anchor: String?
        ) -> SettingsSearchEntry {
            let shown = (title: String(localized: title), card: card.map { String(localized: $0) },
                         section: section.label, detail: String(localized: detail),
                         keywords: String(localized: keywords))
            let parsed = parse(shown.keywords)
            var result = SettingsSearchEntry(
                id: id, title: shown.title, section: section, card: shown.card, detail: shown.detail,
                keywords: parsed.all, anchor: anchor, primaryKeywordCount: parsed.primary
            )
            // `key` is the English literal written in this file.
            let translated = shown.title != title.key || shown.card != card?.key
                || shown.section != section.labelResource.key || shown.detail != detail.key
                || shown.keywords != keywords.key
            if translated {
                result.english = SettingsSearchEntry.EnglishTerms(
                    title: title.key,
                    context: [section.labelResource.key] + (card.map { [$0.key] } ?? []),
                    detail: detail.key,
                    keywords: parse(keywords.key).all
                )
            }
            return result
        }

        func add(
            _ id: String, _ title: LocalizedStringResource, _ section: SettingsSection,
            card: LocalizedStringResource? = nil,
            _ detail: LocalizedStringResource, _ keywords: LocalizedStringResource, anchor: String? = nil
        ) {
            list.append(entry(id: id, title: title, section: section, card: card, detail: detail,
                              keywords: keywords, anchor: anchor ?? id))
        }

        func section(_ section: SettingsSection, _ detail: LocalizedStringResource, _ keywords: LocalizedStringResource) {
            list.append(entry(id: "section.\(section.rawValue)", title: section.labelResource, section: section,
                              card: nil, detail: detail, keywords: keywords, anchor: nil))
        }

        // MARK: Home
        section(.home, "Time saved, activity, your setup and permissions at a glance.",
                .init("inizio, panoramica, riepilogo, dashboard, statistiche, stats, overview", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("home.permissions", "Permissions", .home,
            "Accessibility and microphone access. Shown on Home when something is missing.",
            .init("permessi, accessibilità; accessibility, microfono, microphone, autorizzazioni, privacy, consenti, allow, tcc, sicurezza", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("home.timeSaved", "Time Saved", .home,
            "Time saved compared with typing. Set your usual typing speed.",
            .init("tempo risparmiato, typing speed, wpm, words per minute, velocità di battitura, parole al minuto, digitazione", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("home.setup", "Your setup", .home, card: "Your setup",
            "Your microphone, shortcut and languages, each one click from its page.",
            .init("configurazione, impostazioni attuali, riepilogo impostazioni, setup, current settings, il mio microfono, la mia scorciatoia, le mie lingue", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("home.activity", "Activity", .home,
            "Words dictated, sessions, latency, most used app and streak.",
            .init("attività, statistiche, stats, words dictated, parole dettate, sessioni, sessions, latenza, latency, streak, serie, app più usata, most used app", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("home.wordsOverTime", "Words over Time", .home,
            "Chart of words dictated per day, week or month.",
            .init("grafico, chart, usage, utilizzo, andamento, parole nel tempo, storico", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))

        // MARK: Dictation
        section(.dictation, "Shortcut, languages and how text is written into your apps.",
                .init("dettatura, dettare, dictate; generale, general, scorciatoie, shortcuts, impostazioni generali, preferenze, preferences, opzioni, trascrizione, transcription", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("dictation.shortcut", "Start and Stop Dictation", .dictation, card: "Shortcut",
            "The key combination that starts and stops dictation.",
            .init("scorciatoia, tasto, tasti, hotkey; keyboard shortcut, start / stop dictation, combinazione tasti, avvia dettatura, ferma dettatura, start, stop, shortcut, tasto rapido, fn, globe, attiva dettatura, tastiera", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("dictation.mode", "Mode", .dictation, card: "Shortcut",
            "Press to start and press again to stop, or hold while speaking.",
            .init("toggle, push to talk, push-to-talk, tieni premuto, premi per parlare, modalità, interazione, interaction, walkie talkie, hold, premi e rilascia, premi una volta, hold while speaking, press to start", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("dictation.conversation", "Conversation Mode", .dictation, card: "Shortcut",
            "Keeps listening: each pause pastes what you said.",
            .init("conversazione, modalità conversazione; conversation, ascolto continuo, continuous, sempre in ascolto, keep listening, chat, pausa, dettatura continua, scorciatoia", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("dictation.cancel", "Cancel Dictation", .dictation, card: "Shortcut",
            "Throws away the recording without writing anything.",
            .init("annulla, annulla dettatura, scarta, esc, escape, cancel, interrompi, scorciatoia, tasto", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("dictation.spokenLanguages", "Languages I speak", .dictation, card: "Language",
            "Auto-detect chooses only among these. The first is your main language.",
            .init("lingue, lingue che parlo, parlo, lingua principale; languages i speak, main language, spoken languages, bilingue, multilingue, più lingue, rilevamento automatico, auto-detect, italiano, inglese, english, italian", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("dictation.language", "Language", .dictation, card: "Language",
            "The language Dictari listens for. Profiles and apps can choose their own.",
            .init("lingua, lingua predefinita, default language; language, idioma, italiano, italian, inglese, english, spagnolo, spanish, francese, french, tedesco, german, portoghese, portuguese, russo, russian, ucraino, ukrainian, auto-detect, rilevamento automatico", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("dictation.spokenPunctuation", "Spoken Punctuation", .dictation, card: "Language",
            "Say “virgola”, “punto”, “a capo” to format",
            .init("punteggiatura, virgola, a capo; punto, comandi vocali, punctuation, comma, period, full stop, new line, nuova riga, formattazione, voice commands, punto e virgola, due punti", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("dictation.text", "Text", .dictation, card: "Text",
            "Capital letter and space after each dictation.",
            .init("testo, formattazione, formatting", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("dictation.autoCapitalise", "Start each dictation with a capital letter", .dictation, card: "Text",
            "Capitalises the first letter of what you dictate.",
            .init("maiuscola, maiuscole, lettera maiuscola; auto-capitalise, autocapitalise, auto-capitalize, capitalize, capitalise, capital letter, prima lettera, iniziale", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("dictation.trailingSpace", "Add a space after each dictation", .dictation, card: "Text",
            "So the next dictation does not stick to this one.",
            .init("spazio finale, spazio dopo; trailing space, space after, spazio, spazi", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("dictation.advanced", "Advanced", .dictation, card: "How text is inserted",
            "How dictated text reaches the app you are using.",
            .init("avanzate, avanzato, text injection, inserimento testo, inserisci, consegna, testo", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("dictation.pasteIntoFocus", "Type the text where my cursor is", .dictation, card: "How text is inserted",
            "When off, the text waits in the recording indicator for you to copy.",
            .init("incolla, incolla automaticamente, cursore; paste into focused field, paste, auto paste, campo attivo, campo di testo, inserisci testo, pillola, cursor", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("dictation.deliveryMethod", "How text is inserted", .dictation, card: "How text is inserted",
            "Change only if an app refuses the text. Paste is fastest; Type sends keystrokes.",
            .init("metodo, metodo di inserimento, delivery method, paste, type, digita, digitazione, tastiera, keystrokes, incolla, cmd v, battitura", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("dictation.liveTyping", "Live Typing", .dictation, card: "How text is inserted",
            "Types words as you speak, then corrects them. Parakeet models only.",
            .init("digitazione dal vivo, scrittura in tempo reale, live, mentre parli, streaming, real time, tempo reale, scrivi mentre parlo", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        // Visible only while the method is Paste, so it leads to the picker that shows it.
        add("dictation.restoreClipboard", "Keep what I had copied", .dictation, card: "How text is inserted",
            "Puts your clipboard back after pasting.",
            .init("appunti, ripristina appunti; restore clipboard, clipboard, pasteboard, copia, copy, incolla", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."),
            anchor: "dictation.deliveryMethod")

        // MARK: Microphone & Sound
        section(.sound, "Microphone, beeps and automatic stop.",
                .init("microfono, suono, suoni; audio, microphone, mic, sound, sounds", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("sound.inputDevice", "Microphone", .sound, card: "Microphone",
            "Choose the microphone: built-in, headset, AirPods or USB.",
            .init("microfono, mic, ingresso, dispositivo di ingresso; input device, input, audio in, dispositivo, cuffie, headset, airpods, auricolari, usb, sorgente audio", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("sound.cues", "Beep when recording starts and stops", .sound, card: "While recording",
            "A short sound when dictation starts and ends.",
            .init("suono, suoni, beep, bip, segnale acustico; sound cues, audio feedback, avviso sonoro, silenzioso, mute, muto, sound, feedback", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("sound.stopAfterSilence", "Stop by itself when I stop talking", .sound, card: "While recording",
            "Ends the recording after a pause.",
            .init("silenzio, stop automatico, ferma da solo; stop after silence, vad, fermata automatica, pausa, auto stop, voice activity, automatic stop, smetto di parlare", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        // Visible only while automatic stop is on.
        add("sound.quietFor", "Quiet For", .sound, card: "While recording",
            "Longer allows more time to pause and think",
            .init("durata silenzio, secondi, pausa, tempo di attesa, silence duration, attesa", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."),
            anchor: "sound.stopAfterSilence")
        // Inside Advanced, and only while automatic stop is on: lead to the disclosure.
        add("sound.silenceSensitivity", "What Counts as Silence", .sound, card: "Automatic stop",
            "Sensitivity sets the silence level.",
            .init("sensibilità, sensitivity, soglia, threshold, rumore, silenzio", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."),
            anchor: "sound.advanced")
        add("sound.distantVoice", "Ignore voices far from the microphone", .sound, card: "Other voices",
            "Skips dictations that are too quiet overall.",
            .init("voce lontana, voci lontane, ignora voci; distant voice guard, rumore, filtro, prossimità, proximity, altre persone, tv, televisione, sottofondo, background voices", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        // Both rows appear only while the guard is on, so they lead to its switch.
        add("sound.strength", "Strength", .sound, card: "Other voices",
            "How strict the distant voice filter is.",
            .init("intensità, forza, gentle, balanced, strict, delicato, bilanciato, rigido, livello filtro, voce lontana", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."),
            anchor: "sound.distantVoice")
        add("sound.lastVoiceLevel", "Last Voice Level", .sound, card: "Other voices",
            "Your most recent speaking level, to compare with the filter.",
            .init("livello voce, volume, misura, voice meter, livello", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."),
            anchor: "sound.distantVoice")

        // MARK: Profiles
        section(.profiles, "How Dictari formats your next dictation.",
                .init("profili, profilo, modalità, preset, formattazione", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("profiles.active", "Active profile", .profiles, card: "Active profile",
            "The profile used for your next dictation.",
            .init("profilo attivo, profilo corrente", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("profiles.profile", "Profile", .profiles, card: "Active profile",
            "Changes apply to your next dictation",
            .init("profilo, profilo attivo, scegli profilo, seleziona profilo, modalità dettatura, preset", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        // Only shown for built-in profiles, so it points at the card.
        add("profiles.language", "Language", .profiles, card: "Active profile",
            "Saved for this built-in profile",
            .init("lingua, lingua del profilo, profile language", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."),
            anchor: "profiles.active")
        add("profiles.create", "Create a profile", .profiles, card: "Your profiles",
            "Set its language, formatting and writing behaviour.",
            .init("nuovo profilo, new profile, crea profilo, custom, personalizzato, personalizza, customize, modifica profilo, edit, duplica, duplicate, elimina profilo, delete profile, cancella profilo", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("profiles.builtin", "Built-in profiles", .profiles, card: "Built-in profiles",
            "Default, Code, Email and Notes.",
            .init("profili predefiniti, profili integrati, built in", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("profiles.builtin.standard", "Default", .profiles, card: "Built-in profiles",
            "Uses the capitalisation and spacing set in Dictation.",
            .init("predefinito, standard, normale, default", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("profiles.builtin.code", "Code", .profiles, card: "Built-in profiles",
            "Keeps case and punctuation; adds no trailing space.",
            .init("codice, programmazione, programming, developer, sviluppatore, terminale", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("profiles.builtin.email", "Email", .profiles, card: "Built-in profiles",
            "Capitalises the first letter and adds a trailing space.",
            .init("e-mail, posta, mail, lettera, messaggio", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("profiles.builtin.notes", "Notes", .profiles, card: "Built-in profiles",
            "Capitalises the first letter and ends each dictation with a new line.",
            .init("note, appunti, a capo, new line, promemoria", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("profiles.appLanguage", "Language per Application", .profiles, card: "Language per Application",
            "App language overrides the profile and default language.",
            .init("lingua per app, lingua per applicazione, lingua per programma, app language, browser, safari, chrome, add application, aggiungi applicazione, lingua", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))

        // MARK: Vocabulary
        section(.vocabulary, "Names, products or jargon for Dictari to correct.",
                .init("vocabolario, parole, dizionario, glossario, termini, words, dictionary", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("vocabulary.words", "Words", .vocabulary, card: "Words",
            "Add a word or phrase Dictari often gets wrong.",
            .init("parole, vocabolario, dizionario; nomi, termini, jargon, gergo, aggiungi parola, add word, nomi propri, custom words, parole personalizzate, correzione, elimina parola, cancella parola", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("vocabulary.import", "Import…", .vocabulary, card: "Words",
            "Import vocabulary from a file.",
            .init("importa, importa vocabolario, import words, carica", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("vocabulary.export", "Export…", .vocabulary, card: "Words",
            "Export your vocabulary to a file.",
            .init("esporta, esporta vocabolario, export words, salva, backup", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("vocabulary.scan", "Scan history…", .vocabulary, card: "Words",
            "Find phrases in your history that sound like your words",
            .init("scansiona, scansiona cronologia, trova parole, cerca errori, suggerimenti, suggestions, scan", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("vocabulary.tryIt", "Try it", .vocabulary, card: "Try it",
            "Type a sentence to see the corrections.",
            .init("prova, test, verifica, anteprima, preview, correzione", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))

        // MARK: Writing
        section(.writing, "Fix mistakes and revise text with Apple Intelligence, on this Mac.",
                .init("correggi errori, correzioni, scrittura; fix mistakes, writing, apple intelligence, grammatica, correzione, correggi, riscrivi, revisione, writing tools", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("writing.fixMistakes", "Dictate and Fix Mistakes", .writing, card: "Dictate & fix",
            "Fixes spelling, grammar and punctuation before inserting.",
            .init("correggi errori, grammatica, ortografia, revisione, fix, spelling, grammar, correzione", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("writing.appRules", "With your usual dictation shortcut", .writing,
            "Add an app to fix text automatically or offer a revision.",
            .init("regole per app, regole app, add app, aggiungi app, correzione automatica, riscrivi, revisione, per applicazione, automatic, ask after pasting, app rules", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("writing.editor", "Edit existing text", .writing,
            "Revise text you paste in, on this Mac.",
            .init("modifica testo, riscrivi, migliora testo, correggi testo, rewrite, rephrase, riformula, tono, testo esistente, revise", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))

        // MARK: History
        section(.history, "Every dictation, searchable, with storage options.",
                .init("cronologia, storico, dettature passate, trascrizioni, history, registro", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("history.search", "Search history…", .history,
            "Find a past dictation by its words.",
            .init("cerca, cerca cronologia, trova, trova dettatura, search, dettature passate", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("history.storage", "History storage…", .history,
            "How long history is kept, recovery audio and clearing.",
            .init("archiviazione, spazio, storage, conservazione, memoria", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        // The next three live in the storage popover; the History view opens it on arrival.
        add("history.keep", "Keep History", .history, card: "History storage",
            "Older transcriptions are deleted automatically",
            .init("conserva cronologia, durata, retention, elimina automaticamente, cancella automaticamente, giorni, per sempre, forever, quanto tempo", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."),
            anchor: "history.storage")
        add("history.recoveryAudio", "Recovery Audio", .history, card: "History storage",
            "Saved when a dictation needs attention.",
            .init("audio di recupero, registrazioni salvate, recupero, recovery", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."),
            anchor: "history.storage")
        add("history.clearAll", "Clear All Transcriptions", .history, card: "History storage",
            "Deletes dictation history and the last transcript in memory.",
            .init("cancella, elimina, svuota, cancella cronologia; elimina cronologia, elimina tutto, delete, delete all, erase, clear history, rimuovi, reset", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."),
            anchor: "history.storage")

        // MARK: Files & Meetings
        section(.library, "Transcribe meetings and audio or video files.",
                .init("file, riunioni, riunione, meeting, registrazioni, trascrizioni, archivio, media, library", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("library.meeting", "Transcribe a meeting", .library, card: "New meeting",
            "Choose the call app. Recording starts when you press Start meeting.",
            .init("riunione, meeting, chiamata; zoom, teams, google meet, facetime, chiamata, call, registra, registra riunione, record, videochiamata, start meeting, inizia riunione", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("library.microphone", "Include my microphone", .library, card: "New meeting",
            "Adds your voice alongside the app’s audio",
            .init("microfono, mia voce, includi microfono, mic", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("library.import", "Transcribe audio or video", .library, card: "Import a recording",
            "Choose an audio or video file. Dictari transcribes its audio.",
            .init("importa, file audio, video, mp3, m4a, wav, mp4, registrazione, trascrivi file, podcast, choose file, scegli file, vocale", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("library.saved", "Saved transcripts", .library,
            "Read, export or delete transcripts on this Mac.",
            .init("trascrizioni salvate, archivio, esporta testo, leggi trascrizione, file salvati, elimina trascrizione, cancella", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))

        // MARK: Appearance
        section(.appearance, "Launch at login, light or dark, and the recording indicator.",
                .init("aspetto, tema; appearance, look, avvio, indicatore, pillola, generale, general", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("appearance.app", "App", .appearance, card: "App",
            "Launch at login and appearance.", .init("applicazione, avvio, aspetto", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("appearance.launchAtLogin", "Launch at Login", .appearance, card: "App",
            "Open Dictari automatically when you log in.",
            .init("avvio automatico, apri all'avvio; avvia al login, all'accensione, accensione, startup, start at login, login items, elementi login, autostart, avvio", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("appearance.appearance", "Appearance", .appearance, card: "App",
            "System, light or dark.",
            .init("tema, scuro, chiaro, dark mode, modalità scura; theme, light mode, modalità chiara, aspetto, colori, dark, light, notte, sistema", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("appearance.indicator", "Recording indicator", .appearance, card: "Recording indicator",
            "The small indicator shown while you dictate.",
            .init("pillola, indicatore; pill, overlay, finestrella, capsula, onda, waveform, indicatore di registrazione", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("appearance.indicatorStyle", "Style", .appearance, card: "Recording indicator",
            "Compact, Expanded or Orb.",
            .init("stile, stile pillola, pill style, compact, expanded, orb, compatta, espansa, sfera, cerchio, pillola, indicatore", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("appearance.indicatorPosition", "Position", .appearance, card: "Recording indicator",
            "Where the indicator appears on screen.",
            .init("posizione, dove, bottom, top, near cursor, cursore, in basso, in alto, sinistra, destra, centro, pill position, pillola, indicatore", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("appearance.alwaysShowIndicator", "Always show", .appearance, card: "Recording indicator",
            "Keeps the indicator on screen even when you are not dictating.",
            .init("mostra sempre, sempre visibile, nascondi pillola; always show pill, hide pill, pillola, indicatore", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))

        // MARK: Models
        section(.models, "Download, choose or delete the transcription model.",
                .init("motore vocale, speech engine, models, modelli, modello, model, trascrizione, motore, engine, download, scarica, spazio su disco, disk space", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("models.transcriptionModel", "Transcription Model", .models, card: "Transcription Model",
            "Runs on this Mac. Download, use or delete a model.",
            .init("modello, modello di trascrizione, elimina modello; motore, engine, download, scarica, elimina modello, delete model, cancella, whisper, parakeet", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("models.parakeet-v3", "Fast", .models, card: "Transcription Model",
            "Parakeet v3 · 25 European languages · recommended",
            .init("parakeet, veloce, predefinito, consigliato, recommended, modello, lingue europee, default", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("models.parakeet-ultra", "Accurate", .models, card: "Transcription Model",
            "Parakeet Ultra · 25 European languages · slightly more accurate, larger download",
            .init("parakeet ultra, ultra, accurato, preciso, precisione, più preciso, qualità, accurate, modello, lingue europee", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("models.base", "Light", .models, card: "Transcription Model",
            "Whisper Base · smaller download, lower accuracy",
            .init("whisper base, leggero, piccolo, small, modello", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("models.large-v3-turbo", "Maximum coverage", .models, card: "Transcription Model",
            "Whisper Large v3 Turbo · only for languages outside Europe · much slower",
            .init("whisper large, turbo, massima copertura, più lingue, lento, modello, altre lingue, lingue extraeuropee", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))

        // MARK: AI Agents
        section(.agents, "Let connected AI agents search selected Dictari data.",
                .init("agenti, agenti ia, intelligenza artificiale, ai, mcp, integrazioni, claude, chatgpt, codex", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("agents.allow", "Allow AI agent access", .agents, card: "Data access",
            "Allow access to the categories selected below.",
            .init("agenti ia, intelligenza artificiale, mcp, claude, chatgpt, codex, cursor, accesso, ai, consenti, permessi", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("agents.history", "Dictation history", .agents, card: "Data access",
            "Text, date, language, duration, latency and app.",
            .init("accesso cronologia; cronologia, dettature", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("agents.statistics", "Statistics", .agents, card: "Data access",
            "Words, sessions, apps and average latency.",
            .init("statistiche, stats", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("agents.media", "Files & meetings", .agents, card: "Data access",
            "File and meeting transcripts.",
            .init("file, riunioni, trascrizioni", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("agents.vocabulary", "Vocabulary", .agents, card: "Data access",
            "Read your custom words and known alternatives.",
            .init("vocabolario, parole", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("agents.proposals", "Vocabulary proposals", .agents, card: "Data access",
            "Agents can propose changes. You approve them here.",
            .init("proposte, suggerimenti vocabolario, proposte vocabolario", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("agents.privacy", "Privacy", .agents, card: "Privacy",
            "Returned text is shared with the connected AI service.",
            .init("privacy, riservatezza, dati condivisi, sicurezza", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("agents.pending", "Agent proposals", .agents, card: "Agent proposals",
            "Approve or reject changes suggested by agents.",
            .init("proposte agenti, approva, rifiuta, approve, reject, in attesa, pending", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("agents.connect", "Connect a client", .agents, card: "Connect a client",
            "Local MCP address, access token and setup for each client.",
            .init("collega, connetti, token, access token, claude code, claude desktop, codex, cursor, vs code, gemini, opencode, configurazione, mcp server, indirizzo", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))

        // MARK: Shared Settings
        section(.team, "Export or import vocabulary, profiles and language settings.",
                .init("impostazioni condivise, condividi, condivisione, team, squadra, colleghi", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("team.share", "Share a settings file", .team, card: "Share a settings file",
            "Includes vocabulary, custom profiles and language rules.",
            .init("condividi, esporta impostazioni, importa impostazioni, backup, altro mac, trasferisci, export, import, file impostazioni, colleghi, sincronizza", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))

        // MARK: Diagnostics
        section(.diagnostics, "Local diagnostics and export for support.",
                .init("diagnostica, log, logs, problemi, errori, supporto, support", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("diagnostics.local", "Local Diagnostics", .diagnostics, card: "Diagnostics",
            "App state, delivery results, crashes and performance",
            .init("diagnostica, crash, arresti anomali, prestazioni, performance, errori, log", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("diagnostics.export", "Export for Support", .diagnostics, card: "Diagnostics",
            "No audio or dictated text",
            .init("esporta, supporto, assistenza, aiuto, help, bug, segnala problema, report, invia log, export", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))

        // MARK: Updates
        section(.updates, "Installed version and update checks.",
                .init("aggiornamenti, aggiorna; update, updates, nuova versione", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("updates.updates", "Updates", .updates, card: "Updates",
            "Installed version and update checks.",
            .init("aggiornamenti, aggiorna; update, updates, nuova versione", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."))
        add("updates.version", "Installed Version", .updates, card: "Updates",
            "The version of Dictari on this Mac.",
            .init("versione, version, numero di versione, about, informazioni", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."),
            anchor: "updates.updates")
        add("updates.checkAutomatically", "Check automatically", .updates, card: "Updates",
            "Look for updates in the background.",
            .init("aggiornamenti automatici, auto update, controlla automaticamente, automatic updates", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."),
            anchor: "updates.updates")
        add("updates.checkNow", "Check for Updates…", .updates, card: "Updates",
            "Look for a new version now.",
            .init("cerca aggiornamenti, aggiorna, update now, controlla aggiornamenti, check now, aggiornamenti", comment: "Hidden search synonyms, comma-separated (text before ; ranks higher). Use words people type in your language."),
            anchor: "updates.updates")

        return list
    }
}
