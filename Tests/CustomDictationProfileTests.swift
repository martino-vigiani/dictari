import XCTest

final class CustomDictationProfileTests: XCTestCase {
    // Fixed valid custom identifiers keep fixtures reproducible and distinguish ID/name collisions.
    private let personalID = "custom:00000000-0000-0000-0000-000000000001"
    private let teamID = "custom:00000000-0000-0000-0000-000000000002"

    private func makeProfile(
        id: String = "custom:00000000-0000-0000-0000-000000000001",
        name: String = "Research",
        language: String? = "it",
        capitalize: Bool = true,
        ending: ProfileEnding = .newline,
        writingBehavior: ProfileWritingBehavior = .appRules,
        writingAction: String = "correct"
    ) -> CustomDictationProfile {
        CustomDictationProfile(id: id, name: name, language: language, capitalize: capitalize,
                               ending: ending, writingBehavior: writingBehavior, writingAction: writingAction)
    }

    private func makeSettings(selecting profile: CustomDictationProfile) -> SettingsData {
        var settings = SettingsData()
        settings.customDictationProfiles = [profile]
        settings.selectedDictationProfile = profile.id
        settings.defaultLanguage = "de"
        return settings
    }

    func testCustomProfilesAndSelectionSurviveSettingsJSONRoundTrip() throws {
        let settings = makeSettings(selecting: makeProfile(writingBehavior: .automatic, writingAction: "email"))

        let decoded = try JSONDecoder().decode(SettingsData.self, from: JSONEncoder().encode(settings))

        XCTAssertEqual(decoded, settings)
        XCTAssertEqual(decoded.activeDictationProfileID, personalID)
        XCTAssertEqual(decoded.activeDictationProfileName, "Research")
        XCTAssertEqual(decoded.selectedCustomDictationProfile, settings.customDictationProfiles?.first)
    }

    func testLegacySettingsWithoutCustomProfilesPreserveLanguageAndBuiltInSelection() throws {
        // Regression: a newly required Codable key would discard existing user settings on load.
        var settings = SettingsData()
        settings.defaultLanguage = "it"
        settings.selectedDictationProfile = "code"
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        json.removeValue(forKey: "customDictationProfiles")

        let decoded = try JSONDecoder().decode(SettingsData.self, from: JSONSerialization.data(withJSONObject: json))

        XCTAssertNil(decoded.customDictationProfiles)
        XCTAssertEqual(decoded.defaultLanguage, "it")
        XCTAssertEqual(decoded.activeDictationProfileID, "code")
        XCTAssertEqual(decoded.dictationPreferences(for: nil).format("myAPI()"), "myAPI()")
    }

    func testSavingNewProfileAddsItWithoutChangingExistingProfile() throws {
        let existing = makeProfile()
        var settings = makeSettings(selecting: existing)
        let added = makeProfile(id: teamID, name: "Letters", language: "fr")

        try settings.saveCustomProfile(added)

        XCTAssertEqual(settings.customDictationProfiles, [existing, added])
    }

    func testRenamingSelectedProfileKeepsItsStableIDAndSelection() throws {
        var settings = makeSettings(selecting: makeProfile())
        var renamed = makeProfile()
        renamed.name = "Field notes"

        try settings.saveCustomProfile(renamed)

        XCTAssertEqual(settings.customDictationProfiles, [renamed])
        XCTAssertEqual(settings.activeDictationProfileID, personalID)
        XCTAssertEqual(settings.activeDictationProfileName, "Field notes")
    }

    func testSavingUnchangedProfileDoesNotDuplicateIt() throws {
        let profile = makeProfile()
        var settings = makeSettings(selecting: profile)

        try settings.saveCustomProfile(profile)

        XCTAssertEqual(settings.customDictationProfiles, [profile])
    }

    func testDeletingSelectedProfileFallsBackToDefaultAndKeepsOtherProfiles() {
        let remaining = makeProfile(id: teamID, name: "Letters")
        var settings = makeSettings(selecting: makeProfile())
        settings.customDictationProfiles?.append(remaining)
        settings.autoCapitalize = false
        settings.trailingSpace = false

        settings.removeCustomProfile(id: personalID)

        XCTAssertEqual(settings.customDictationProfiles, [remaining])
        XCTAssertEqual(settings.activeDictationProfileID, "standard")
        XCTAssertNil(settings.selectedCustomDictationProfile)
        XCTAssertEqual(settings.dictationPreferences(for: nil).format("keepCase"), "keepCase")
    }

    func testDeletingUnselectedProfilePreservesActiveProfile() {
        let selected = makeProfile()
        var settings = makeSettings(selecting: selected)
        settings.customDictationProfiles?.append(makeProfile(id: teamID, name: "Letters"))

        settings.removeCustomProfile(id: teamID)

        XCTAssertEqual(settings.customDictationProfiles, [selected])
        XCTAssertEqual(settings.activeDictationProfileID, personalID)
    }

    func testUnknownCustomSelectionUsesDefaultFormatting() {
        var settings = SettingsData()
        settings.selectedDictationProfile = personalID
        settings.autoCapitalize = false
        settings.trailingSpace = false

        let preferences = settings.dictationPreferences(for: nil)

        XCTAssertEqual(settings.activeDictationProfileID, "standard")
        XCTAssertEqual(preferences.format("keepCase"), "keepCase")
    }

    func testApplicationLanguageOverridesCustomProfileLanguageIncludingAutoDetection() {
        var settings = makeSettings(selecting: makeProfile(language: "it"))
        settings.applicationLanguages = ["editor": "auto"]

        let preferences = settings.dictationPreferences(for: "editor")

        XCTAssertEqual(preferences.language, "auto")
    }

    func testCustomProfileLanguageOverridesGlobalAndBuiltInLanguage() {
        var settings = makeSettings(selecting: makeProfile(language: "it"))
        settings.profileLanguages = ["standard": "fr"]

        let preferences = settings.dictationPreferences(for: "unlisted")

        XCTAssertEqual(preferences.language, "it")
    }

    func testCustomProfileWithoutLanguageInheritsGlobalLanguage() {
        let settings = makeSettings(selecting: makeProfile(language: nil))

        let preferences = settings.dictationPreferences(for: nil)

        XCTAssertEqual(preferences.language, "de")
    }

    func testCustomProfileWithNoEndingPreservesCaseAndPunctuation() {
        let settings = makeSettings(selecting: makeProfile(capitalize: false, ending: .none))

        let result = settings.dictationPreferences(for: nil).format("myAPI(foo.bar) != nil;")

        XCTAssertEqual(result, "myAPI(foo.bar) != nil;")
    }

    func testCustomProfileCapitalizesFirstTextCharacterAndAddsSpaceAfterPunctuation() {
        let settings = makeSettings(selecting: makeProfile(capitalize: true, ending: .space))

        let result = settings.dictationPreferences(for: nil).format("  caffè, grazie!")

        XCTAssertEqual(result, "  Caffè, grazie! ")
    }

    func testCustomProfileAddsNewlineWithoutRewritingPunctuation() {
        let settings = makeSettings(selecting: makeProfile(capitalize: false, ending: .newline))

        let result = settings.dictationPreferences(for: nil).format("note: keepCase...")

        XCTAssertEqual(result, "note: keepCase...\n")
    }

    func testCustomProfilePreservesBlankInputForEveryEnding() {
        for ending: ProfileEnding in [.none, .space, .newline] {
            let preferences = makeSettings(selecting: makeProfile(ending: ending)).dictationPreferences(for: nil)

            let results = ["", " \n", "\t\u{00A0}"].map(preferences.format)

            XCTAssertEqual(results, ["", " \n", "\t\u{00A0}"], "Blank input must remain unchanged for \(ending)")
        }
    }

    func testRecordingPreferencesRemainFrozenAfterSelectedProfileIsEdited() throws {
        var settings = makeSettings(selecting: makeProfile())
        let recording = settings.dictationPreferences(for: nil)
        var edited = makeProfile(language: "fr", capitalize: false, ending: .none)
        edited.name = "Edited"

        try settings.saveCustomProfile(edited)

        XCTAssertEqual(recording.language, "it")
        XCTAssertEqual(recording.format("ciao!"), "Ciao!\n")
        XCTAssertEqual(settings.dictationPreferences(for: nil).language, "fr")
        XCTAssertEqual(settings.dictationPreferences(for: nil).format("ciao!"), "ciao!")
    }

    func testCustomAppRulesBehaviorUsesMatchingApplicationRule() {
        var settings = makeSettings(selecting: makeProfile(writingBehavior: .appRules))
        let rule = AppWritingRule(name: "Editor", trigger: "automatic", action: "email")
        settings.applicationWritingRules = ["editor": rule]

        let resolved = settings.writingRule(for: "editor")

        XCTAssertEqual(resolved, rule)
    }

    func testCustomAppRulesBehaviorDoesNotOptUnlistedApplicationsIn() {
        var settings = makeSettings(selecting: makeProfile(writingBehavior: .appRules))
        settings.applicationWritingRules = ["editor": AppWritingRule(name: "Editor")]

        let resolved = settings.writingRule(for: "unlisted")

        XCTAssertNil(resolved)
    }

    func testCustomOffBehaviorSuppressesAutomaticApplicationRule() {
        var settings = makeSettings(selecting: makeProfile(writingBehavior: .off))
        settings.applicationWritingRules = ["editor": AppWritingRule(name: "Editor", trigger: "automatic")]

        let resolved = settings.writingRule(for: "editor")

        XCTAssertNil(resolved)
    }

    func testCustomAskBehaviorOffersConfiguredActionWithoutAutomaticRevision() throws {
        let settings = makeSettings(selecting: makeProfile(writingBehavior: .ask, writingAction: "email"))

        let rule = try XCTUnwrap(settings.writingRule(for: "unlisted"))

        XCTAssertEqual(rule.mode, .ask)
        XCTAssertEqual(rule.writingAction, .email)
        XCTAssertNil(DictationRevisionPolicy.action(explicitCorrection: false, rule: rule))
    }

    func testCustomAutomaticBehaviorRevisesWithConfiguredAction() throws {
        let settings = makeSettings(selecting: makeProfile(writingBehavior: .automatic, writingAction: "email"))

        let rule = try XCTUnwrap(settings.writingRule(for: "unlisted"))

        XCTAssertEqual(rule.mode, .automatic)
        XCTAssertEqual(DictationRevisionPolicy.action(explicitCorrection: false, rule: rule), .email)
    }

    func testExplicitCorrectionOverridesCustomProfileOffBehavior() {
        let settings = makeSettings(selecting: makeProfile(writingBehavior: .off))

        let action = DictationRevisionPolicy.action(explicitCorrection: true, rule: settings.writingRule(for: "editor"))

        XCTAssertEqual(action, .correct)
    }

    func testCodeProfileStillPreservesSourceAndSuppressesAutomaticWriting() {
        var settings = makeSettings(selecting: makeProfile(writingBehavior: .automatic))
        settings.selectedDictationProfile = "code"
        settings.applicationWritingRules = ["editor": AppWritingRule(name: "Editor", trigger: "automatic")]

        let preferences = settings.dictationPreferences(for: "editor")

        XCTAssertEqual(preferences.format("myAPI(foo.bar) != nil"), "myAPI(foo.bar) != nil")
        XCTAssertNil(settings.writingRule(for: "editor"))
    }

    func testTeamPackageExportsAndDecodesCustomProfiles() throws {
        let profile = makeProfile(writingBehavior: .ask, writingAction: "email")
        let package = TeamPackage(vocabulary: [], settings: makeSettings(selecting: profile))

        let decoded = try TeamPackage.decode(package.encoded())

        XCTAssertEqual(decoded.customDictationProfiles, [profile])
    }

    func testLegacyTeamPackageWithoutCustomProfilesStillDecodes() throws {
        let package = TeamPackage(vocabulary: [], settings: SettingsData())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: package.encoded()) as? [String: Any])
        json.removeValue(forKey: "customDictationProfiles")

        let decoded = try TeamPackage.decode(JSONSerialization.data(withJSONObject: json))

        XCTAssertNil(decoded.customDictationProfiles)
        XCTAssertEqual(decoded.version, 1)
    }

    func testTeamMergePreservesPersonalProfileAndSelectionOnIDCollision() throws {
        let personal = makeProfile(name: "Personal", language: "it")
        let settings = makeSettings(selecting: personal)
        let colliding = makeProfile(name: "Team replacement", language: "de")
        let added = makeProfile(id: teamID, name: "Team notes", language: "fr")
        var teamSettings = SettingsData()
        teamSettings.customDictationProfiles = [colliding, added]
        let package = try TeamPackage.decode(TeamPackage(vocabulary: [], settings: teamSettings).encoded())

        let merged = package.merging(into: settings)

        XCTAssertEqual(merged.customDictationProfiles, [personal, added])
        XCTAssertEqual(merged.activeDictationProfileID, personalID)
        XCTAssertEqual(merged.defaultLanguage, "de")
    }

    func testBlankAndOverlongNamesAreRejectedWithoutChangingSettings() {
        for name in ["", " \t\n\u{00A0}", String(repeating: "a", count: 81)] {
            var settings = makeSettings(selecting: makeProfile())
            let original = settings
            let invalid = makeProfile(id: teamID, name: name)

            XCTAssertThrowsError(try settings.saveCustomProfile(invalid)) { error in
                guard case CustomProfileError.invalidName = error else {
                    return XCTFail("Expected invalidName, received \(error)")
                }
            }

            XCTAssertEqual(settings, original)
        }
    }

    func testDuplicateCustomOrBuiltInNameIsRejectedWithoutChangingSettings() {
        for name in [" research ", "CODE", "Default"] {
            var settings = makeSettings(selecting: makeProfile())
            let original = settings
            let duplicate = makeProfile(id: teamID, name: name)

            XCTAssertThrowsError(try settings.saveCustomProfile(duplicate)) { error in
                guard case CustomProfileError.duplicateName = error else {
                    return XCTFail("Expected duplicateName, received \(error)")
                }
            }

            XCTAssertEqual(settings, original)
        }
    }

    func testInvalidIdentifierIsRejectedWithoutChangingSettings() {
        for id in ["code", "custom:", "custom:" + String(repeating: "a", count: 122)] {
            var settings = makeSettings(selecting: makeProfile())
            let original = settings
            let invalid = makeProfile(id: id, name: "Another")

            XCTAssertThrowsError(try settings.saveCustomProfile(invalid)) { error in
                guard case CustomProfileError.invalidIdentifier = error else {
                    return XCTFail("Expected invalidIdentifier, received \(error)")
                }
            }

            XCTAssertEqual(settings, original)
        }
    }

    func testInvalidLanguageIsRejectedWithoutChangingSettings() {
        var settings = makeSettings(selecting: makeProfile())
        let original = settings
        let invalid = makeProfile(language: "invented")

        XCTAssertThrowsError(try settings.saveCustomProfile(invalid)) { error in
            guard case CustomProfileError.invalidLanguage = error else {
                return XCTFail("Expected invalidLanguage, received \(error)")
            }
        }

        XCTAssertEqual(settings, original)
    }

    func testInvalidWritingActionIsRejectedWithoutChangingSettings() {
        var settings = makeSettings(selecting: makeProfile())
        let original = settings
        let invalid = makeProfile(writingAction: "future-action")

        XCTAssertThrowsError(try settings.saveCustomProfile(invalid)) { error in
            guard case CustomProfileError.invalidWritingAction = error else {
                return XCTFail("Expected invalidWritingAction, received \(error)")
            }
        }

        XCTAssertEqual(settings, original)
    }

    private func makeSettingsAtProfileCapacity() -> SettingsData {
        var settings = SettingsData()
        settings.customDictationProfiles = (0..<100).map { index in
            makeProfile(id: "custom:capacity-\(index)", name: "Profile \(index)")
        }
        return settings
    }

    func testOneHundredAndFirstProfileIsRejectedWithoutChangingSettings() {
        var settings = makeSettingsAtProfileCapacity()
        let original = settings

        XCTAssertThrowsError(try settings.saveCustomProfile(makeProfile())) { error in
            guard case CustomProfileError.tooManyProfiles = error else {
                return XCTFail("Expected tooManyProfiles, received \(error)")
            }
        }

        XCTAssertEqual(settings, original)
    }

    func testExistingProfileCanBeEditedAtCapacity() throws {
        var settings = makeSettingsAtProfileCapacity()
        var edited = try XCTUnwrap(settings.customDictationProfiles?.first)
        edited.name = "Renamed at capacity"

        try settings.saveCustomProfile(edited)

        XCTAssertEqual(settings.customDictationProfiles?.count, 100)
        XCTAssertEqual(settings.customDictationProfiles?.first, edited)
    }

    func testNameAtMaximumLengthIsAcceptedAndTrimmed() throws {
        var settings = SettingsData()
        let maximumName = String(repeating: "a", count: 80)
        let profile = makeProfile(name: "  " + maximumName + " ")

        try settings.saveCustomProfile(profile)

        XCTAssertEqual(settings.customDictationProfiles?.first?.name, maximumName)
    }

    func testNewDraftInheritsGlobalFormattingWithoutPersistingIt() {
        var settings = SettingsData()
        settings.autoCapitalize = false
        settings.trailingSpace = false
        let original = settings

        let draft = settings.customProfileDraft()

        XCTAssertFalse(draft.capitalize)
        XCTAssertEqual(draft.ending, .none)
        XCTAssertNil(draft.language)
        XCTAssertEqual(draft.writingBehavior, .appRules)
        XCTAssertEqual(settings, original)
    }

    func testCopyingCodeCreatesIndependentDraftThatPreservesCodeBehavior() {
        var settings = SettingsData()
        settings.profileLanguages = ["code": "en"]

        let draft = settings.customProfileDraft(copying: "code")

        XCTAssertNotEqual(draft.id, "code")
        XCTAssertTrue(draft.id.hasPrefix("custom:"))
        XCTAssertFalse(draft.capitalize)
        XCTAssertEqual(draft.ending, .none)
        XCTAssertEqual(draft.language, "en")
        XCTAssertEqual(draft.writingBehavior, .off)
    }

    func testCopyingCustomProfilePreservesChoicesWithNewIdentityAndAvailableName() throws {
        let profile = makeProfile(writingBehavior: .automatic, writingAction: "email")
        var settings = makeSettings(selecting: profile)
        settings.customDictationProfiles?.append(makeProfile(id: teamID, name: "Research copy"))
        let original = settings

        let draft = settings.customProfileDraft(copying: personalID)

        XCTAssertNotEqual(draft.id, personalID)
        XCTAssertEqual(draft.name, "Research copy 2")
        XCTAssertEqual(draft.language, profile.language)
        XCTAssertEqual(draft.capitalize, profile.capitalize)
        XCTAssertEqual(draft.ending, profile.ending)
        XCTAssertEqual(draft.writingBehavior, profile.writingBehavior)
        XCTAssertEqual(draft.writingAction, profile.writingAction)
        XCTAssertEqual(settings, original)
    }

    func testWritingRuleSnapshotSurvivesProfileEdits() throws {
        var settings = makeSettings(selecting: makeProfile(writingBehavior: .automatic, writingAction: "email"))
        let frozen = try XCTUnwrap(settings.writingRule(for: "editor"))

        try settings.saveCustomProfile(makeProfile(writingBehavior: .off))

        XCTAssertEqual(frozen.mode, .automatic)
        XCTAssertEqual(frozen.writingAction, .email)
        XCTAssertNil(settings.writingRule(for: "editor"))
    }

    func testTeamMergePreservesPersonalProfileOnCaseInsensitiveNameCollision() throws {
        let personal = makeProfile()
        let settings = makeSettings(selecting: personal)
        var team = SettingsData()
        team.customDictationProfiles = [makeProfile(id: teamID, name: "RESEARCH", language: "fr")]
        let package = try TeamPackage.decode(TeamPackage(vocabulary: [], settings: team).encoded())

        let merged = package.merging(into: settings)

        XCTAssertEqual(merged.customDictationProfiles, [personal])
        XCTAssertEqual(merged.activeDictationProfileID, personalID)
    }

    func testTeamPackageRejectsDuplicateCustomIdentifiers() throws {
        var team = SettingsData()
        team.customDictationProfiles = [makeProfile(), makeProfile(name: "Another")]
        let encoded = try TeamPackage(vocabulary: [], settings: team).encoded()

        XCTAssertThrowsError(try TeamPackage.decode(encoded)) { error in
            guard case TeamPackageError.invalid = error else {
                return XCTFail("Expected invalid package, received \(error)")
            }
        }
    }

    func testTeamPackageRejectsInvalidCustomProfileInsteadOfPartiallyImporting() throws {
        var team = SettingsData()
        team.customDictationProfiles = [makeProfile(), makeProfile(id: teamID, name: "Another", language: "invented")]
        let encoded = try TeamPackage(vocabulary: [], settings: team).encoded()

        XCTAssertThrowsError(try TeamPackage.decode(encoded)) { error in
            guard case TeamPackageError.invalid = error else {
                return XCTFail("Expected invalid package, received \(error)")
            }
        }
    }
}
