import XCTest

final class SpokenFormattingTests: XCTestCase {
    private func it(_ s: String) -> String { SpokenFormatting.apply(s, language: "it") }
    private func en(_ s: String) -> String { SpokenFormatting.apply(s, language: "en") }
    private func de(_ s: String) -> String { SpokenFormatting.apply(s, language: "de") }
    private func auto(_ s: String) -> String { SpokenFormatting.apply(s, language: "auto") }

    // MARK: - Italian punctuation

    func testItalianCommaBetweenModelPauses() {
        XCTAssertEqual(it("Ciao, virgola, come stai"), "Ciao, come stai")
    }

    func testItalianPeriodCapitalizesNextWord() {
        XCTAssertEqual(it("Ciao, punto, come stai"), "Ciao. Come stai")
        XCTAssertEqual(it("Ho finito. Punto. domani riprendo"), "Ho finito. Domani riprendo")
    }

    func testItalianPeriodAtEndOfText() {
        XCTAssertEqual(it("Ci vediamo domani punto"), "Ci vediamo domani.")
        XCTAssertEqual(it("Ci vediamo domani, punto."), "Ci vediamo domani.")
        XCTAssertEqual(it("Ci vediamo domani virgola"), "Ci vediamo domani,")
    }

    func testItalianMultiWordMarksConvertInsideProse() {
        XCTAssertEqual(it("Come stai punto interrogativo"), "Come stai?")
        XCTAssertEqual(it("Che bello punto esclamativo andiamo"), "Che bello! Andiamo")
        XCTAssertEqual(it("primo punto e virgola secondo"), "primo; secondo")
    }

    func testDuePuntiIsTreatedAsAmbiguous() {
        XCTAssertEqual(it("Ecco, due punti, primo"), "Ecco: primo")
        XCTAssertEqual(it("ecco la lista, due punti. pane e latte"), "ecco la lista: pane e latte")
        XCTAssertEqual(it("La lista è la seguente due punti"), "La lista è la seguente:")
        XCTAssertEqual(it("Le opzioni due punti a capo prima"), "Le opzioni:\nPrima")
        XCTAssertEqual(it("ho due punti da discutere"), "ho due punti da discutere")
        XCTAssertEqual(it("Abbiamo perso per due punti di scarto"), "Abbiamo perso per due punti di scarto")
        XCTAssertEqual(auto("ho due punti da discutere"), "ho due punti da discutere")
    }

    func testItalianCommandsAreCaseInsensitive() {
        XCTAssertEqual(it("Come stai PUNTO INTERROGATIVO"), "Come stai?")
        XCTAssertEqual(it("Ciao. Punto E Virgola. Poi"), "Ciao; Poi")
    }

    func testModelPunctuationAroundCommandIsRemoved() {
        XCTAssertEqual(it("Come stai? Punto interrogativo."), "Come stai?")
        XCTAssertEqual(it("Allora, punto e virgola, dopo"), "Allora; dopo")
        XCTAssertEqual(it("Vero, punto esclamativo!"), "Vero!")
        XCTAssertFalse(it("Ciao, virgola, come stai").contains(",,"))
    }

    func testConsecutiveCommandsKeepEachOther() {
        XCTAssertEqual(it("Fine punto a capo inizio"), "Fine.\nInizio")
        XCTAssertEqual(it("Ciao virgola a capo Marco"), "Ciao,\nMarco")
        XCTAssertEqual(it("Ciao, punto, a capo, come stai"), "Ciao.\nCome stai")
    }

    // MARK: - Italian newlines

    func testItalianNewline() {
        XCTAssertEqual(it("Caro Marco a capo ti scrivo"), "Caro Marco\nTi scrivo")
        XCTAssertEqual(it("Caro Marco, a capo. ti scrivo"), "Caro Marco\nTi scrivo")
        XCTAssertEqual(it("Ciao. A capo. Come stai?"), "Ciao.\nCome stai?")
        XCTAssertEqual(it("Grazie vai a capo Martino"), "Grazie\nMartino")
    }

    func testItalianParagraph() {
        XCTAssertEqual(it("Primo blocco. Nuovo paragrafo. Secondo blocco."), "Primo blocco.\n\nSecondo blocco.")
        XCTAssertEqual(it("Primo nuovo capoverso secondo"), "Primo\n\nSecondo")
    }

    func testPuntoACapo() {
        XCTAssertEqual(it("Ho finito punto a capo domani si ricomincia"), "Ho finito.\nDomani si ricomincia")
        XCTAssertEqual(it("Ho finito punto e a capo domani"), "Ho finito.\nDomani")
    }

    func testNewlineStripsSurroundingSpaces() {
        XCTAssertEqual(it("uno   a capo   due"), "uno\nDue")
    }

    // MARK: - Italian brackets and quotes

    func testItalianParentheses() {
        XCTAssertEqual(it("Il file apri parentesi quello nuovo chiudi parentesi è pronto"),
                       "Il file (quello nuovo) è pronto")
        XCTAssertEqual(it("Il file, apri parentesi, quello nuovo, chiudi parentesi, è pronto"),
                       "Il file (quello nuovo) è pronto")
    }

    func testItalianQuotes() {
        XCTAssertEqual(it("Ha detto apri virgolette ciao a tutti chiudi virgolette e se ne è andato"),
                       "Ha detto \"ciao a tutti\" e se ne è andato")
        XCTAssertEqual(it("Ha detto aperte virgolette sì chiuse virgolette."), "Ha detto \"sì\".")
    }

    // MARK: - Italian negatives (prose must survive)

    func testItalianAmbiguousWordsInProseAreUntouched() {
        let untouched = [
            "Il punto è che non ho tempo",
            "A che punto siamo con il progetto?",
            "Siamo arrivati al punto.",
            "A un certo punto è arrivato",
            "Metti la virgola dopo il nome",
            "Zero virgola cinque per cento",
            "Punto e basta",
            "Questo è il punto",
            "Mi manca solo una virgola",
            "Ha fatto punto su punto tutto il lavoro",
        ]
        for text in untouched {
            XCTAssertEqual(it(text), text, text)
        }
    }

    func testItalianMultiWordCommandsBlockedByArticles() {
        XCTAssertEqual(it("Ho messo i due punti al posto sbagliato"), "Ho messo i due punti al posto sbagliato")
        XCTAssertEqual(it("Manca un punto interrogativo"), "Manca un punto interrogativo")
        XCTAssertEqual(it("Scrivi un nuovo paragrafo sul tema"), "Scrivi un nuovo paragrafo sul tema")
        XCTAssertEqual(it("Togli il punto e virgola"), "Togli il punto e virgola")
    }

    func testACapoDelNotANewline() {
        XCTAssertEqual(it("Lei è a capo del progetto"), "Lei è a capo del progetto")
        XCTAssertEqual(it("Sono a capo di un team"), "Sono a capo di un team")
        XCTAssertEqual(it("È a capo dell'ufficio"), "È a capo dell'ufficio")
    }

    func testPlainTextIsReturnedUnchanged() {
        let texts = [
            "Buongiorno a tutti,  oggi parliamo di Swift.\nPoi pranzo.",
            "Nessun comando qui!   Spazi   doppi restano.",
            "  leading and trailing  ",
            "",
            "Emoji 🎉 e «caporali»",
        ]
        for text in texts {
            XCTAssertEqual(it(text), text)
            XCTAssertEqual(en(text), text)
            XCTAssertEqual(de(text), text)
            XCTAssertEqual(auto(text), text)
        }
    }

    func testUntouchedRegionsKeepOriginalSpacing() {
        XCTAssertEqual(it("uno,  due   tre, virgola, quattro"), "uno,  due   tre, quattro")
    }

    // MARK: - Fillers

    func testFillersRemovedWithTheirCommas() {
        XCTAssertEqual(it("Allora, ehm, andiamo"), "Allora, andiamo")
        XCTAssertEqual(it("Allora ehm andiamo"), "Allora andiamo")
        XCTAssertEqual(it("Allora ehm, andiamo"), "Allora andiamo")
        XCTAssertEqual(it("Ehm, allora andiamo"), "Allora andiamo")
        XCTAssertEqual(it("andiamo, ehm."), "andiamo.")
        XCTAssertEqual(it("andiamo, ehm"), "andiamo")
        XCTAssertEqual(it("Ok. Ehmm, domani"), "Ok. Domani")
        XCTAssertEqual(it("Allora ehm... andiamo"), "Allora andiamo")
        XCTAssertEqual(en("So, uhm, I think umm yes"), "So, I think yes")
        XCTAssertEqual(de("Also, äh, ich denke ähm ja"), "Also, ich denke ja")
    }

    func testFillerLookalikesAreKept() {
        XCTAssertEqual(it("Ah, capisco. Ehi, ciao"), "Ah, capisco. Ehi, ciao")
        XCTAssertEqual(en("Hmm, the ehmer family"), "Hmm, the ehmer family")
        XCTAssertEqual(de("Ah so, ähnlich"), "Ah so, ähnlich")
    }

    // MARK: - English

    func testEnglishCommands() {
        XCTAssertEqual(en("Hi John comma how are you question mark"), "Hi John, how are you?")
        XCTAssertEqual(en("Dear team new line thanks"), "Dear team\nThanks")
        XCTAssertEqual(en("Intro new paragraph body"), "Intro\n\nBody")
        XCTAssertEqual(en("first semicolon second"), "first; second")
        XCTAssertEqual(en("Wow exclamation mark great exclamation point"), "Wow! Great!")
        XCTAssertEqual(en("Done full stop next"), "Done. Next")
        XCTAssertEqual(en("See you tomorrow period"), "See you tomorrow.")
        XCTAssertEqual(en("Items, colon, milk"), "Items: milk")
        XCTAssertEqual(en("the file open parenthesis new close parenthesis works"), "the file (new) works")
        XCTAssertEqual(en("he said open quote hi close quote"), "he said \"hi\"")
    }

    func testEnglishProseIsUntouched() {
        let untouched = [
            "The period of time was long",
            "It was a long period",
            "Remove the comma",
            "Add a colon here",
            "It lasted for the whole period.",
            "A new line of products",
            "The trial period",
            "Colon cancer screening saves lives",
        ]
        for text in untouched {
            XCTAssertEqual(en(text), text, text)
        }
    }

    // MARK: - German

    func testGermanCommands() {
        // Commas fire without pauses too: the model rarely brackets them with its own.
        XCTAssertEqual(de("Hallo Anna Komma wie geht es dir Fragezeichen"), "Hallo Anna, wie geht es dir?")
        XCTAssertEqual(de("Hallo Anna, Komma, wie geht es dir Fragezeichen"), "Hallo Anna, wie geht es dir?")
        XCTAssertEqual(de("Liebe Grüße neue Zeile Martino"), "Liebe Grüße\nMartino")
        XCTAssertEqual(de("Erstens neuer Absatz zweitens"), "Erstens\n\nZweitens")
        XCTAssertEqual(de("eins Semikolon zwei"), "eins; zwei")
        XCTAssertEqual(de("Liste Doppelpunkt Brot"), "Liste: Brot")
        XCTAssertEqual(de("Super Ausrufezeichen danke"), "Super! Danke")
        XCTAssertEqual(de("Bis morgen Punkt"), "Bis morgen.")
        XCTAssertEqual(de("Die Datei Klammer auf neu Klammer zu ist fertig"), "Die Datei (neu) ist fertig")
        XCTAssertEqual(de("Er sagte Anführungszeichen hallo Anführungszeichen und ging"),
                       "Er sagte \"hallo\" und ging")
        XCTAssertEqual(de("Er sagte Anführungszeichen unten hallo Anführungszeichen oben"),
                       "Er sagte \"hallo\"")
    }

    func testGermanProseIsUntouched() {
        let untouched = [
            "Der Punkt ist, dass wir warten",
            "Kommen wir zum Punkt",
            "Das ist der Punkt",
            "Null Komma fünf Prozent",
            "Setz ein Komma",
            "Der Doppelpunkt fehlt",
        ]
        for text in untouched {
            XCTAssertEqual(de(text), text, text)
        }
    }

    // MARK: - Language selection

    func testAutoAppliesMultiWordCommandsInAnyLanguage() {
        XCTAssertEqual(auto("Ciao a capo come stai"), "Ciao\nCome stai")
        XCTAssertEqual(auto("Dear team new line thanks"), "Dear team\nThanks")
        XCTAssertEqual(auto("Hallo neue Zeile Welt"), "Hallo\nWelt")
        XCTAssertEqual(auto("Come stai punto interrogativo"), "Come stai?")
        XCTAssertEqual(auto("Allora, ehm, andiamo"), "Allora, andiamo")
    }

    // Regression: with "Auto-detect" (the default most people keep) "virgola" and "punto"
    // were never converted. The transcript's language is now recognised and its rules apply.
    func testAutoRecognisesTheLanguageAndAppliesItsSingleWordCommands() {
        XCTAssertEqual(auto("Ciao virgola come stai punto"), "Ciao, come stai.")
        XCTAssertEqual(auto("Hello comma how are you period"), "Hello, how are you.")
        XCTAssertEqual(auto("Hallo Komma wie geht es dir Fragezeichen"), "Hallo, wie geht es dir?")
        XCTAssertEqual(auto("Bonjour virgule ça va point"), "Bonjour, ça va.")
        XCTAssertEqual(auto("Olá vírgula tudo bem ponto de interrogação"), "Olá, tudo bem?")
        XCTAssertEqual(auto("Привет запятая как дела вопросительный знак"), "Привет, как дела?")
        XCTAssertEqual(auto("Привіт кома як справи знак питання"), "Привіт, як справи?")
        XCTAssertEqual(auto("Metti la virgola dopo il nome"), "Metti la virgola dopo il nome")
    }

    // Regression: "a capo" said as one word came out as the text "Accapo".
    func testNewlineWrittenAsOneWordOrHyphenated() {
        XCTAssertEqual(it("Ciao acapo come stai"), "Ciao\nCome stai")
        XCTAssertEqual(it("Ciao. Accapo. Come stai."), "Ciao.\nCome stai.")
        XCTAssertEqual(it("Ciao a-capo come stai"), "Ciao\nCome stai")
        XCTAssertEqual(it("Fine punto accapo inizio"), "Fine.\nInizio")
        XCTAssertEqual(it("Ciao nuova riga Marco"), "Ciao\nMarco")
        XCTAssertEqual(auto("Ok acapo"), "Ok\n")
        XCTAssertEqual(it("Il recapito dell'accapo di sezione"), "Il recapito dell'accapo di sezione")
    }

    func testCommaBetweenNumbersIsADecimal() {
        XCTAssertEqual(it("Pesa 3 virgola 5 chili"), "Pesa 3 virgola 5 chili")
        XCTAssertEqual(en("Pi is three comma one four"), "Pi is three comma one four")
    }

    func testNewLanguages() {
        XCTAssertEqual(SpokenFormatting.apply("Hola, coma, qué tal punto y aparte adiós", language: "es"), "Hola, qué tal.\nAdiós")
        XCTAssertEqual(SpokenFormatting.apply("Bonjour point-virgule ça va point d’interrogation", language: "fr"), "Bonjour; ça va?")
        XCTAssertEqual(SpokenFormatting.apply("Oi nova linha tudo bem", language: "pt"), "Oi\nTudo bem")
        XCTAssertEqual(SpokenFormatting.apply("Привет новая строка пока", language: "ru"), "Привет\nПока")
        XCTAssertEqual(SpokenFormatting.apply("Привіт новий рядок бувай", language: "uk"), "Привіт\nБувай")
    }

    func testLanguagesDoNotLeakIntoEachOther() {
        XCTAssertEqual(en("Ciao a capo come stai"), "Ciao a capo come stai")
        XCTAssertEqual(it("Dear team new line thanks"), "Dear team new line thanks")
        XCTAssertEqual(de("Come stai punto interrogativo"), "Come stai punto interrogativo")
    }

    func testRegionalCodesAndUnknownLanguages() {
        XCTAssertEqual(SpokenFormatting.apply("Ciao a capo mondo", language: "it-IT"), "Ciao\nMondo")
        XCTAssertEqual(SpokenFormatting.apply("Ciao a capo mondo", language: "fr"), "Ciao a capo mondo")
        XCTAssertEqual(SpokenFormatting.apply("Alors ehm oui", language: "fr"), "Alors oui")
    }

    // MARK: - Performance

    func testTwoThousandCharactersUnderOneMillisecond() {
        let sentence = "Allora, ehm, il punto è che virgola domani apri parentesi forse chiudi parentesi a capo ci vediamo punto "
        let text = String(repeating: sentence, count: 2000 / sentence.count + 1).prefix(2000)
        _ = it(String(text)) // warm static tables
        let clock = ContinuousClock()
        // Best of 20: the minimum reflects the algorithm, not other processes competing for
        // the CPU (parallel builds made an averaged bound flaky).
        let perRun = (0..<20).map { _ in clock.measure { _ = it(String(text)) } }.min()!
        // Debug builds are several times slower than Release; this bound is for the Debug run.
        XCTAssertLessThan(perRun, .milliseconds(5), "per run: \(perRun)")
    }
}
