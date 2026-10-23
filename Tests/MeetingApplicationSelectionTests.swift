import XCTest

final class MeetingApplicationSelectionTests: XCTestCase {
    func testMeetingPreferencesRoundTripThroughSettingsJSON() throws {
        var settings = SettingsData()
        settings.meetingApplicationBundleID = "us.zoom.xos"
        settings.meetingApplicationName = "Zoom"
        settings.meetingIncludeMicrophone = false
        settings.realtimeTranscriptionEnabled = true

        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(SettingsData.self, from: encoded)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        XCTAssertEqual(decoded.meetingApplicationBundleID, "us.zoom.xos")
        XCTAssertEqual(decoded.meetingApplicationName, "Zoom")
        XCTAssertEqual(decoded.meetingIncludeMicrophone, false)
        XCTAssertEqual(decoded.realtimeTranscriptionEnabled, true)
        XCTAssertNil(json["meetingApplicationProcessID"], "a process identifier must never be persisted")
    }

    func testLegacySettingsWithoutMeetingFieldsStillDecode() throws {
        var current = SettingsData()
        current.meetingApplicationBundleID = "us.zoom.xos"
        current.meetingApplicationName = "Zoom"
        current.meetingIncludeMicrophone = false
        current.realtimeTranscriptionEnabled = true

        let encoded = try JSONEncoder().encode(current)
        var legacy = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        legacy.removeValue(forKey: "meetingApplicationBundleID")
        legacy.removeValue(forKey: "meetingApplicationName")
        legacy.removeValue(forKey: "meetingIncludeMicrophone")
        legacy.removeValue(forKey: "realtimeTranscriptionEnabled")

        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        let decoded = try JSONDecoder().decode(SettingsData.self, from: legacyData)

        XCTAssertNil(decoded.meetingApplicationBundleID)
        XCTAssertNil(decoded.meetingApplicationName)
        XCTAssertNil(decoded.meetingIncludeMicrophone)
        XCTAssertTrue(decoded.meetingIncludeMicrophone ?? true, "legacy behavior includes the microphone")
        XCTAssertNil(decoded.realtimeTranscriptionEnabled)
    }

    func testSettingsMigrationPreservesMeetingSelection() {
        var stored = SettingsData()
        stored.activeModelID = "large-v3-turbo"
        stored.didMigrateToParakeetDefault = nil
        stored.meetingApplicationBundleID = "com.microsoft.teams2"
        stored.meetingApplicationName = "Microsoft Teams"
        stored.meetingIncludeMicrophone = false

        let migrated = SettingsStore.migrate(stored)

        XCTAssertEqual(migrated.meetingApplicationBundleID, "com.microsoft.teams2")
        XCTAssertEqual(migrated.meetingApplicationName, "Microsoft Teams")
        XCTAssertEqual(migrated.meetingIncludeMicrophone, false)
        XCTAssertEqual(migrated.activeModelID, "parakeet-v3")
    }

    func testSavedBundleIDResolvesFromCurrentApplicationsWithoutAPID() {
        let runningBundleIDs = ["com.apple.Safari", "us.zoom.xos", "com.tinyspeck.slackmacgap"]

        let resolved = MeetingApplicationSelection.resolve(
            savedBundleID: "us.zoom.xos",
            in: runningBundleIDs
        )

        XCTAssertEqual(resolved, "us.zoom.xos")
    }

    func testSavedButClosedApplicationStaysRememberedAndCannotStart() {
        var settings = SettingsData()
        settings.meetingApplicationBundleID = "us.zoom.xos"
        settings.meetingApplicationName = "Zoom"
        let original = settings

        let resolved = MeetingApplicationSelection.resolve(
            savedBundleID: settings.meetingApplicationBundleID,
            in: ["com.apple.Safari"]
        )

        XCTAssertNil(resolved)
        XCTAssertEqual(settings, original)
        XCTAssertEqual(settings.meetingApplicationName, "Zoom")
    }

    func testSavedApplicationResolvesWhenItBecomesAvailableWithoutChangingPreference() {
        var settings = SettingsData()
        settings.meetingApplicationBundleID = "us.zoom.xos"
        settings.meetingApplicationName = "Zoom"
        let original = settings

        XCTAssertNil(MeetingApplicationSelection.resolve(
            savedBundleID: settings.meetingApplicationBundleID,
            in: ["com.apple.Safari"]
        ))
        XCTAssertEqual(MeetingApplicationSelection.resolve(
            savedBundleID: settings.meetingApplicationBundleID,
            in: ["com.apple.Safari", "us.zoom.xos"]
        ), "us.zoom.xos")
        XCTAssertEqual(settings, original)
    }
}
