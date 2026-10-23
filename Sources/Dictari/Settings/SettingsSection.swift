// SettingsSection.swift
// Dictari — the settings sidebar sections.
//
// Kept free of SwiftUI so the host-less test bundle can compile it alongside the settings
// search index, which files every entry under one of these sections.
//
// Order and grouping follow how often a section is needed, not how the code is organised:
// everyday pages first, developer-facing ones under "Advanced" at the bottom. The previous
// layout (13 flat pages, a catch-all "General") left a non-technical user unable to find the
// microphone or the language.

import Foundation

enum SettingsSection: String, CaseIterable, Identifiable {
    case home
    case dictation
    case sound
    case profiles
    case vocabulary
    case writing
    case history
    case library
    case appearance
    case models
    case agents
    case team
    case diagnostics
    case updates

    var id: String { rawValue }

    /// Resolves a raw value, including names of sections that no longer exist.
    /// `DICTARI_OPEN_SETTINGS` (documented in AGENTS.md) and older scripts or notes may still
    /// say "general" or "shortcuts"; they land on the page that now holds those rows.
    init?(launchValue: String) {
        let value = launchValue.trimmingCharacters(in: .whitespaces).lowercased()
        if let section = SettingsSection(rawValue: value) {
            self = section
            return
        }
        switch value {
        case "general", "shortcuts": self = .dictation
        case "microphone": self = .sound
        // The page used to hold the licence too; the update controls are all that remain.
        case "license": self = .updates
        default: return nil
        }
    }

    /// The page name in the sidebar, the page title and search breadcrumbs, in the display
    /// language. Display only: code that needs a stable name uses `rawValue`.
    var label: String { String(localized: labelResource) }

    /// The localizable page name. Kept as a resource so the settings search can index both
    /// the translated name and the English one (`key`).
    var labelResource: LocalizedStringResource {
        switch self {
        case .home:        return LocalizedStringResource("Home", comment: "Settings page name (sidebar and page title)")
        case .dictation:   return LocalizedStringResource("Dictation", comment: "Settings page name (sidebar and page title)")
        case .sound:       return LocalizedStringResource("Microphone & Sound", comment: "Settings page name (sidebar and page title)")
        case .profiles:    return LocalizedStringResource("Profiles", comment: "Settings page name (sidebar and page title)")
        case .vocabulary:  return LocalizedStringResource("Vocabulary", comment: "Settings page name (sidebar and page title)")
        case .writing:     return LocalizedStringResource("Fix Mistakes", comment: "Settings page name: correcting dictated text with Apple Intelligence")
        case .history:     return LocalizedStringResource("History", comment: "Settings page name: past dictations")
        case .library:     return LocalizedStringResource("Files & Meetings", comment: "Settings page name: transcribing audio files and meetings")
        case .appearance:  return LocalizedStringResource("Appearance", comment: "Settings page name (sidebar and page title)")
        case .models:      return LocalizedStringResource("Speech Engine", comment: "Settings page name: the on-device transcription model")
        case .agents:      return LocalizedStringResource("AI Agents", comment: "Settings page name: access for external AI assistants")
        case .team:        return LocalizedStringResource("Shared Settings", comment: "Settings page name: export/import settings to share with others")
        case .diagnostics: return LocalizedStringResource("Diagnostics", comment: "Settings page name (sidebar and page title)")
        case .updates:     return LocalizedStringResource("Updates", comment: "Settings page name: app updates")
        }
    }

    var systemImage: String {
        switch self {
        case .home:        return "house"
        case .dictation:   return "keyboard"
        case .sound:       return "mic"
        case .profiles:    return "slider.horizontal.3"
        case .vocabulary:  return "character.book.closed"
        case .writing:     return "text.badge.checkmark"
        case .history:     return "clock"
        case .library:     return "doc.text"
        case .appearance:  return "paintbrush"
        case .models:      return "cpu"
        case .agents:      return "point.3.connected.trianglepath.dotted"
        case .team:        return "square.and.arrow.up"
        case .diagnostics: return "stethoscope"
        case .updates:     return "arrow.triangle.2.circlepath"
        }
    }

    /// Sidebar groups, in order. Every case appears exactly once. Titles are display text in
    /// the current language; identify a group by its `sections`, never by its title.
    static let groups: [(title: String, sections: [SettingsSection])] = [
        (String(localized: "Overview", comment: "Settings sidebar group title"), [.home]),
        (String(localized: "Dictation", comment: "Settings sidebar group title"), [.dictation, .sound, .profiles]),
        (String(localized: "Words & Corrections", comment: "Settings sidebar group title"), [.vocabulary, .writing]),
        (String(localized: "History & Files", comment: "Settings sidebar group title"), [.history, .library]),
        (String(localized: "App", comment: "Settings sidebar group title: settings about the app itself"), [.appearance]),
        (String(localized: "Advanced", comment: "Settings sidebar group title / disclosure for rarely needed options"),
         [.models, .agents, .team, .diagnostics, .updates]),
    ]
}
