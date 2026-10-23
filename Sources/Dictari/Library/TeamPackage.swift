import Foundation

/// Portable team defaults, deliberately excluding transcripts, credentials and device settings.
struct TeamPackage: Codable, Sendable {
    let format: String
    let version: Int
    let vocabulary: [VocabularyTerm]
    let profileLanguages: [String: String]
    let applicationLanguages: [String: String]
    let applicationNames: [String: String]
    let customDictationProfiles: [CustomDictationProfile]?

    init(vocabulary: [VocabularyTerm], settings: SettingsData) {
        format = "dictari-team"
        version = 1
        self.vocabulary = vocabulary
        profileLanguages = settings.profileLanguages ?? [:]
        applicationLanguages = settings.applicationLanguages ?? [:]
        applicationNames = settings.applicationNames ?? [:]
        customDictationProfiles = settings.customDictationProfiles
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 2 * 1024 * 1024 else { throw TeamPackageError.invalid }
        let result = try JSONDecoder().decode(Self.self, from: data)
        let languages: Set<String> = ["auto", "en", "it", "es", "fr", "de", "pt", "ru", "uk"]
        guard result.format == "dictari-team", result.version == 1,
              result.vocabulary.count <= 5000,
              result.vocabulary.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              result.profileLanguages.allSatisfy({ DictationProfile(rawValue: $0.key) != nil && languages.contains($0.value) }),
              result.applicationLanguages.count <= 500,
              result.applicationLanguages.allSatisfy({ !$0.key.isEmpty && languages.contains($0.value) }) else {
            throw TeamPackageError.invalid
        }
        let customProfiles = result.customDictationProfiles ?? []
        guard customProfiles.count <= 100 else { throw TeamPackageError.invalid }
        var checked = SettingsData()
        var ids = Set<String>()
        for profile in customProfiles {
            guard ids.insert(profile.id).inserted else { throw TeamPackageError.invalid }
            do { try checked.saveCustomProfile(profile) }
            catch { throw TeamPackageError.invalid }
        }
        return result
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    func merging(into settings: SettingsData) -> SettingsData {
        var merged = settings
        // Team defaults fill gaps. They never silently override a colleague's own choices.
        merged.profileLanguages = profileLanguages.merging(settings.profileLanguages ?? [:]) { _, personal in personal }
        merged.applicationLanguages = applicationLanguages.merging(settings.applicationLanguages ?? [:]) { _, personal in personal }
        merged.applicationNames = applicationNames.merging(settings.applicationNames ?? [:]) { _, personal in personal }
        for profile in customDictationProfiles ?? [] {
            // Identity and human-readable names both belong to the recipient. A separately
            // created profile with the same name must not be silently replaced on import.
            guard !(merged.customDictationProfiles ?? []).contains(where: {
                $0.id == profile.id || $0.name.caseInsensitiveCompare(profile.name.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
            }) else { continue }
            try? merged.saveCustomProfile(profile)
        }
        return merged
    }
}

enum TeamPackageError: LocalizedError {
    case invalid
    var errorDescription: String? {
        String(localized: "Choose a valid Dictari settings package (version 1, up to 2 MB). Nothing was imported.")
    }
}
