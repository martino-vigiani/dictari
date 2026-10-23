import XCTest

final class TeamPackageTests: XCTestCase {
    func testPackageExcludesHistoryAndMergesWithoutOverridingPersonalRules() throws {
        var team = SettingsData()
        team.profileLanguages = ["code": "en", "notes": "de"]
        team.applicationLanguages = ["app": "de", "new": "it"]
        let package = TeamPackage(vocabulary: [VocabularyTerm(text: "Company")], settings: team)
        let data = try package.encoded()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), Set(["format", "version", "vocabulary", "profileLanguages", "applicationLanguages", "applicationNames"]))
        var personal = SettingsData()
        personal.profileLanguages = ["code": "it"]
        personal.applicationLanguages = ["app": "auto"]
        personal.defaultLanguage = "fr"
        let result = try TeamPackage.decode(data).merging(into: personal)
        XCTAssertEqual(result.profileLanguages, ["code": "it", "notes": "de"])
        XCTAssertEqual(result.applicationLanguages, ["app": "auto", "new": "it"])
        XCTAssertEqual(result.defaultLanguage, "fr")
    }
    func testUnknownVersionAndInvalidLanguageRejected() throws {
        let package = TeamPackage(vocabulary: [], settings: SettingsData())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: package.encoded()) as? [String: Any])
        json["version"] = 2
        XCTAssertThrowsError(try TeamPackage.decode(JSONSerialization.data(withJSONObject: json)))
        json["version"] = 1
        json["profileLanguages"] = ["code": "invented"]
        XCTAssertThrowsError(try TeamPackage.decode(JSONSerialization.data(withJSONObject: json)))
    }
}
