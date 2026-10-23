import XCTest

final class DictationProfileTests: XCTestCase {
    func testLanguagePrecedenceAndExplicitAutoDetection() {
        var settings = SettingsData()
        settings.defaultLanguage = "de"
        settings.selectedDictationProfile = "code"
        settings.profileLanguages = ["code": "en"]
        settings.applicationLanguages = ["com.example.editor": "it", "com.example.chat": "auto"]
        XCTAssertEqual(settings.dictationPreferences(for: "com.example.editor").language, "it")
        XCTAssertEqual(settings.dictationPreferences(for: "com.example.chat").language, "auto")
        XCTAssertEqual(settings.dictationPreferences(for: "unknown").language, "en")
        XCTAssertEqual(settings.dictationPreferences(for: nil).language, "en")
        settings.profileLanguages = nil
        XCTAssertEqual(settings.dictationPreferences(for: nil).language, "de")
    }

    func testSettingsAndProfilesAreSnapshotsForAnActiveSession() {
        var settings = SettingsData()
        settings.selectedDictationProfile = "notes"
        settings.applicationLanguages = ["editor": "it"]
        let recording = settings.dictationPreferences(for: "editor")
        settings.selectedDictationProfile = "code"
        settings.applicationLanguages = ["editor": "de"]
        XCTAssertEqual(recording.language, "it")
        XCTAssertEqual(recording.format("ciao"), "Ciao\n")
        XCTAssertEqual(settings.dictationPreferences(for: "editor").format("ciao"), "ciao")
    }

    func testProfilesPreserveCodeAndFormatProseWithoutRewriting() {
        var settings = SettingsData()
        settings.selectedDictationProfile = "code"
        XCTAssertEqual(settings.dictationPreferences(for: nil).format("myAPI(foo.bar) != nil"), "myAPI(foo.bar) != nil")
        settings.selectedDictationProfile = "email"
        XCTAssertEqual(settings.dictationPreferences(for: nil).format("ciao Martino, grazie."), "Ciao Martino, grazie. ")
        settings.selectedDictationProfile = "notes"
        XCTAssertEqual(settings.dictationPreferences(for: nil).format("caffè e tè"), "Caffè e tè\n")
        XCTAssertEqual(settings.dictationPreferences(for: nil).format(" \n"), " \n")
        XCTAssertEqual(settings.dictationPreferences(for: nil).format(""), "")
    }

    func testDefaultProfileRespectsExistingFormattingAndUnknownProfileFallsBack() {
        var settings = SettingsData()
        settings.autoCapitalize = false
        settings.trailingSpace = false
        settings.selectedDictationProfile = "future-profile"
        XCTAssertEqual(settings.dictationProfile, .standard)
        XCTAssertEqual(settings.dictationPreferences(for: nil).format("keepCase"), "keepCase")
        settings.autoCapitalize = true
        settings.trailingSpace = true
        XCTAssertEqual(settings.dictationPreferences(for: nil).format("keepCase"), "KeepCase ")
    }

    func testOldSettingsDecodeAndNewSettingsRoundTrip() throws {
        var settings = SettingsData()
        settings.defaultLanguage = "it"
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        for key in ["applicationLanguages", "applicationNames", "selectedDictationProfile", "profileLanguages"] { object.removeValue(forKey: key) }
        let old = try JSONDecoder().decode(SettingsData.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(old.defaultLanguage, "it")
        XCTAssertEqual(old.dictationProfile, .standard)
        XCTAssertNil(old.applicationLanguages)
        settings.selectedDictationProfile = "notes"
        settings.profileLanguages = ["notes": "en"]
        settings.applicationLanguages = ["editor": "de"]
        settings.applicationNames = ["editor": "Editor"]
        XCTAssertEqual(try JSONDecoder().decode(SettingsData.self, from: JSONEncoder().encode(settings)), settings)
    }
}

import AppKit

extension DictationProfileTests {
    @MainActor
    func testProfileDeliveryDoesNotApplyGlobalFormattingTwice() async {
        let board = NSPasteboard(name: .init("com.dictari.profile-tests.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let injector = TextInjector()
        injector.pasteboard = board
        injector.autoCapitalize = true
        injector.trailingSpace = true
        // Under XCTest the injector never posts input, so delivery lands on the private board.
        _ = await injector.injectDelivery("myAPI()", textIsPreprocessed: true)
        XCTAssertEqual(board.string(forType: .string), "myAPI()")
        _ = await injector.injectDelivery("Nota\n", textIsPreprocessed: true)
        XCTAssertEqual(board.string(forType: .string), "Nota\n")
        _ = await injector.injectDelivery("legacy")
        XCTAssertEqual(board.string(forType: .string), "Legacy ")
    }
}
