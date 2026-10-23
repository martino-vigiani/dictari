import XCTest

final class SpokenLanguagesTests: XCTestCase {
    func testDefaultsFollowTheMacsSupportedLanguagesInOrder() {
        XCTAssertEqual(SpokenLanguages.defaults(preferred: ["en-US", "it-IT", "en-IT", "de-IT"]), ["en", "it", "de"])
        XCTAssertEqual(SpokenLanguages.defaults(preferred: ["ja-JP"]), ["en"])
    }

    func testSanitizedDropsUnknownAndNeverReturnsEmpty() {
        XCTAssertEqual(SpokenLanguages.sanitized(["it", "xx", "it", "de"], preferred: []), ["it", "de"])
        XCTAssertEqual(SpokenLanguages.sanitized([], preferred: ["fr-FR"]), ["fr"])
    }

    func testAutoWithOneSpokenLanguageIsPinned() {
        XCTAssertEqual(SpokenLanguages.resolve("auto", spoken: ["it"]), "it")
        XCTAssertEqual(SpokenLanguages.resolve("auto", spoken: ["it", "en"]), "auto")
        XCTAssertEqual(SpokenLanguages.resolve("de", spoken: ["it"]), "de")
    }

    func testWhisperDetectionIsNarrowedToTheSpokenSet() {
        let probabilities: [String: Float] = ["es": -0.2, "it": -0.9, "en": -1.5]
        XCTAssertEqual(SpokenLanguages.best(of: probabilities, among: ["it", "en"]), "it")
        XCTAssertNil(SpokenLanguages.best(of: probabilities, among: ["de"]))
    }

    func testDetectedLanguageOfATranscript() {
        XCTAssertEqual(SpokenLanguages.detected(
            in: "Domani mattina passo in ufficio a prendere i documenti che mi hai lasciato",
            among: ["en", "it"]), "it")
        XCTAssertEqual(SpokenLanguages.detected(in: "Anything", among: ["de"]), "de")
    }

    func testSettingsResolveAutoThroughTheSpokenSet() {
        var settings = SettingsData()
        settings.defaultLanguage = "auto"
        settings.spokenLanguages = ["it"]
        XCTAssertEqual(settings.dictationPreferences(for: nil).language, "it")
        settings.spokenLanguages = ["it", "en"]
        XCTAssertEqual(settings.dictationPreferences(for: nil).language, "auto")
    }

    // Regression: short Italian dictations came out as "Yeah.", "Chao", "Why?".
    func testShortEnglishDriftIsRepairedForNonEnglishSpeakers() {
        XCTAssertEqual(ShortUtteranceFix.apply("Yeah.", spoken: ["it"]), "Sì.")
        XCTAssertEqual(ShortUtteranceFix.apply("Why?", spoken: ["it", "de"]), "Perché?")
        XCTAssertEqual(ShortUtteranceFix.apply("Chao", spoken: ["it"]), "Ciao")
        XCTAssertEqual(ShortUtteranceFix.apply("Cha Chao.", spoken: ["it"]), "Ciao.")
        XCTAssertEqual(ShortUtteranceFix.apply("Thank you!", spoken: ["de"]), "Danke!")
    }

    func testShortUtteranceFixLeavesEverythingElseAlone() {
        XCTAssertEqual(ShortUtteranceFix.apply("Yeah.", spoken: ["it", "en"]), "Yeah.")
        XCTAssertEqual(ShortUtteranceFix.apply("Yeah I think so too.", spoken: ["it"]), "Yeah I think so too.")
        XCTAssertEqual(ShortUtteranceFix.apply("No.", spoken: ["it"]), "No.")
        XCTAssertEqual(ShortUtteranceFix.apply("Ciao a tutti", spoken: ["it"]), "Ciao a tutti")
        XCTAssertEqual(ShortUtteranceFix.apply("Yeah.", spoken: ["ru"]), "Yeah.")
    }
}
