import XCTest

final class AppWritingRuleTests: XCTestCase {
    func testDefaultAndUnlistedAppsNeverOptIn() {
        var settings = SettingsData()
        XCTAssertNil(settings.writingRule(for: "com.apple.mail"))
        settings.applicationWritingRules = ["com.apple.mail": AppWritingRule(name: "Mail")]
        XCTAssertEqual(settings.writingRule(for: "com.apple.mail")?.mode, .ask)
        XCTAssertNil(settings.writingRule(for: "com.openai.chat"))
        XCTAssertNil(settings.writingRule(for: nil))
    }
    func testCodeAndNeverRulesAreExcluded() {
        var settings = SettingsData()
        settings.applicationWritingRules = ["mail": AppWritingRule(name: "Mail")]
        settings.selectedDictationProfile = "code"
        XCTAssertNil(settings.writingRule(for: "mail"))
        settings.selectedDictationProfile = "email"
        settings.applicationWritingRules?["mail"]?.trigger = "never"
        XCTAssertNil(settings.writingRule(for: "mail"))
    }
    func testRuleSnapshotSurvivesSubsequentSettingsChange() {
        var settings = SettingsData()
        settings.applicationWritingRules = ["mail": AppWritingRule(name: "Mail")]
        let snapshot = settings.writingRule(for: "mail")
        settings.applicationWritingRules?["mail"]?.trigger = "automatic"
        XCTAssertEqual(snapshot?.mode, .ask)
        XCTAssertEqual(settings.writingRule(for: "mail")?.mode, .automatic)
    }
    func testOnlyPostedDeliveryToSameApplicationCanOffer() {
        let rule = AppWritingRule(name: "Mail")
        XCTAssertTrue(rule.shouldOffer(after: .inserted, recordedApp: "mail", currentApp: "mail"))
        XCTAssertTrue(rule.shouldOffer(after: .pastedUnverified, recordedApp: "mail", currentApp: "mail"))
        XCTAssertFalse(rule.shouldOffer(after: .copiedToClipboard, recordedApp: "mail", currentApp: "mail"))
        XCTAssertFalse(rule.shouldOffer(after: .submitFailed, recordedApp: "mail", currentApp: "mail"))
        XCTAssertFalse(rule.shouldOffer(after: .inserted, recordedApp: "mail", currentApp: "chat"))
        XCTAssertFalse(rule.shouldOffer(after: .inserted, recordedApp: nil, currentApp: nil))
    }
    func testSettingsRoundTripAndLegacyAbsence() throws {
        var settings = SettingsData()
        settings.applicationWritingRules = ["mail": AppWritingRule(name: "Mail", trigger: "automatic", action: "email")]
        let decoded = try JSONDecoder().decode(SettingsData.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.applicationWritingRules, settings.applicationWritingRules)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        legacy.removeValue(forKey: "applicationWritingRules")
        let old = try JSONDecoder().decode(SettingsData.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(old.applicationWritingRules)
        XCTAssertEqual(old.defaultLanguage, settings.defaultLanguage)
    }
    func testFutureTriggerFailsClosed() throws {
        let rule = try JSONDecoder().decode(AppWritingRule.self, from: Data(#"{"name":"Mail","trigger":"future-mode","action":"future-action"}"#.utf8))
        XCTAssertEqual(rule.mode, .never)
        XCTAssertEqual(rule.writingAction, .correct)
        XCTAssertFalse(rule.shouldOffer(after: .inserted, recordedApp: "mail", currentApp: "mail"))
    }
}
