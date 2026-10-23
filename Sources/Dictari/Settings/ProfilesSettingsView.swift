import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ProfilesSettingsView: View {
    @Environment(AppCoordinator.self) private var app
    @State private var applicationError: String?
    @State private var editing: CustomDictationProfile?
    @State private var deleting: CustomDictationProfile?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Same list as the Dictation page: names in the interface language, codes unchanged.
    fileprivate static var languages: [(code: String, name: String)] { DictationSettingsView.languages }

    var body: some View {
        SettingsScrollPane(title: "Profiles",
                           subtitle: "Choose how Dictari formats your next dictation. Create or customise profiles.") {
            profilesCard
            customProfilesCard
            SettingsCard(title: "Built-in profiles") {
                ForEach(DictationProfile.allCases) { profile in
                    if profile != DictationProfile.allCases.first { SettingsCardDivider() }
                    SettingsRow(verbatim: profile.label, sublabel: profile.detail) {
                        Button("Customize…") { editing = app.settings.data.customProfileDraft(copying: profile.rawValue) }
                            .buttonStyle(MonoActionButtonStyle(.secondary, size: .small))
                            .help("Create an editable copy of \(profile.label)")
                    }
                    .settingsSearchAnchor("profiles.builtin.\(profile.rawValue)")
                }
            }
            .settingsSearchAnchor("profiles.builtin")
            applicationLanguagesCard
        }
        .sheet(item: $editing) { draft in
            let isNew = !(app.settings.data.customDictationProfiles ?? []).contains { $0.id == draft.id }
            CustomProfileEditor(profile: draft, isNew: isNew) { profile in
                try withAnimation(Motion.reduced(Motion.reveal, reduceMotion: reduceMotion)) {
                    try app.settings.data.saveCustomProfile(profile)
                    if isNew { app.settings.data.selectedDictationProfile = profile.id }
                }
            }
        }
        .alert("Delete profile?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete", role: .destructive) {
                if let deleting {
                    withAnimation(Motion.reduced(Motion.reveal, reduceMotion: reduceMotion)) {
                        app.settings.data.removeCustomProfile(id: deleting.id)
                    }
                }
                deleting = nil
            }
        } message: {
            if let name = deleting?.name {
                Text("\(name) will be deleted. If active, Default is used next. Saved transcripts remain.",
                     comment: "Delete-profile alert; %@ is the profile name, Default the built-in profile")
            } else {
                Text("This profile will be deleted. If active, Default is used next. Saved transcripts remain.",
                     comment: "Delete-profile alert; Default is the built-in profile")
            }
        }
    }

    private var profilesCard: some View {
        SettingsCard(title: "Active profile") {
            SettingsRow("Profile", sublabel: "Changes apply to your next dictation") {
                Picker("Profile", selection: Binding(
                    get: { app.settings.data.activeDictationProfileID },
                    set: { app.settings.data.selectedDictationProfile = $0 }
                )) {
                    ForEach(DictationProfile.allCases) { Text($0.label).tag($0.rawValue) }
                    if !(app.settings.data.customDictationProfiles ?? []).isEmpty { Divider() }
                    ForEach(app.settings.data.customDictationProfiles ?? []) { Text($0.name).tag($0.id) }
                }
                .labelsHidden().frame(width: 150)
            }
            .settingsSearchAnchor("profiles.profile")
            if app.settings.data.selectedCustomDictationProfile == nil {
                VStack(spacing: 0) {
                    SettingsCardDivider()
                    SettingsRow("Language", sublabel: "Saved for this built-in profile") {
                        Picker("Profile language", selection: Binding(
                            get: { app.settings.data.profileLanguages?[app.settings.data.dictationProfile.rawValue] ?? "default" },
                            set: { language in
                                var values = app.settings.data.profileLanguages ?? [:]
                                let key = app.settings.data.dictationProfile.rawValue
                                if language == "default" { values.removeValue(forKey: key) } else { values[key] = language }
                                app.settings.data.profileLanguages = values
                            }
                        )) {
                            Text("Use default").tag("default")
                            ForEach(Self.languages, id: \.code) { Text($0.name).tag($0.code) }
                        }
                        .labelsHidden().fixedSize()
                    }
                }
                .transition(.monoReveal(reduceMotion: reduceMotion))
            }
        }
        .monoAnimation(Motion.reveal, value: app.settings.data.selectedCustomDictationProfile == nil)
        .settingsSearchAnchor("profiles.active")
    }

    private var customProfilesCard: some View {
        let profiles = app.settings.data.customDictationProfiles ?? []
        let activeID = app.settings.data.activeDictationProfileID
        return SettingsCard(title: "Your profiles") {
            SettingsRow("Create a profile", sublabel: "Set its language, formatting and writing behaviour.") {
                Button("New Profile…") { editing = app.settings.data.customProfileDraft(copying: nil) }
                    .buttonStyle(MonoActionButtonStyle(profiles.isEmpty ? .primary : .secondary, size: .small))
            }
            .settingsSearchAnchor("profiles.create")
            ForEach(profiles) { profile in
                VStack(spacing: 0) {
                    SettingsCardDivider()
                    HStack(spacing: 12) {
                        Button { editing = profile } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(profile.name).font(Typo.body.weight(.medium)).lineLimit(1)
                                    .foregroundStyle(Mono.primaryText)
                                Text(profileSummary(profile)).font(Typo.secondary).foregroundStyle(Mono.secondaryText)
                                    .lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }
                        .buttonStyle(MonoPlainButtonStyle(scales: false))
                        .accessibilityLabel("Edit profile \(profile.name)")
                        Group {
                            if activeID == profile.id {
                                Label("Active", systemImage: "checkmark")
                                    .symbolRenderingMode(.monochrome)
                                    .font(Typo.secondary.weight(.medium))
                                    .foregroundStyle(Mono.primaryText)
                                    .frame(minHeight: Metrics.controlHeightSmall)
                                    .transition(.opacity)
                            } else {
                                Button(String(localized: "Use", comment: "Button: make this profile the active one")) {
                                    app.settings.data.selectedDictationProfile = profile.id
                                }
                                    .buttonStyle(MonoActionButtonStyle(.secondary, size: .small))
                                    .accessibilityLabel("Use profile \(profile.name)")
                                    .transition(.opacity)
                            }
                        }
                        Menu {
                            Button("Edit…") { editing = profile }
                            Button("Duplicate…") { editing = app.settings.data.customProfileDraft(copying: profile.id) }
                            Divider()
                            Button("Delete…", role: .destructive) { deleting = profile }
                        } label: {
                            Image(systemName: "ellipsis")
                                .foregroundStyle(Mono.secondaryText)
                                .frame(width: 26, height: 26)
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .accessibilityLabel("Actions for profile \(profile.name)")
                        .help("Edit, duplicate or delete")
                    }.padding(Metrics.cardPadding)
                }
                .transition(.monoReveal(reduceMotion: reduceMotion))
            }
        }
        .monoAnimation(Motion.snap, value: activeID)
    }

    private func profileSummary(_ profile: CustomDictationProfile) -> String {
        let language = Self.languages.first { $0.code == profile.language }?.name
            ?? String(localized: "Default language", comment: "Profile summary: the profile has no language of its own")
        return "\(language) · \(profile.ending.label) · \(profile.writingBehavior.label)"
    }

    private var applicationLanguagesCard: some View {
        let ids = (app.settings.data.applicationLanguages ?? [:]).keys.sorted()
        return SettingsCard(title: "Language per Application",
                            footer: "Browser rules apply to every tab.") {
            SettingsRow("Add an app", sublabel: "App language overrides the profile and default language.") {
                Button("Add Application…", action: addApplicationLanguage)
                    .buttonStyle(MonoActionButtonStyle(.secondary, size: .small))
            }
            if let applicationError {
                SettingsNotice(applicationError, systemImage: "exclamationmark.triangle")
                    .padding([.horizontal, .bottom], Metrics.cardPadding)
                    .transition(.monoReveal(reduceMotion: reduceMotion))
            }
            ForEach(ids, id: \.self) { id in
                VStack(spacing: 0) {
                    SettingsCardDivider()
                    HStack(spacing: 10) {
                        ProfilesAppIcon(bundleID: id)
                        Text(app.settings.data.applicationNames?[id] ?? id)
                            .font(Typo.body)
                            .foregroundStyle(Mono.primaryText)
                            .lineLimit(1)
                        Spacer(minLength: 16)
                        Picker("Language", selection: Binding(
                            get: { app.settings.data.applicationLanguages?[id] ?? "auto" },
                            set: { language in
                                var values = app.settings.data.applicationLanguages ?? [:]
                                values[id] = language
                                app.settings.data.applicationLanguages = values
                            }
                        )) {
                            ForEach(Self.languages, id: \.code) { Text($0.name).tag($0.code) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Button {
                            app.settings.data.applicationLanguages?.removeValue(forKey: id)
                            app.settings.data.applicationNames?.removeValue(forKey: id)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(MonoGlyphButtonStyle())
                        .help("Use profile language for this app")
                        .accessibilityLabel("Remove language rule for \(app.settings.data.applicationNames?[id] ?? id)")
                    }
                    .padding(.horizontal, Metrics.cardPadding)
                    .padding(.vertical, 10)
                }
                .transition(.monoReveal(reduceMotion: reduceMotion))
            }
        }
        .monoAnimation(Motion.reveal, value: ids)
        .monoAnimation(Motion.reveal, value: applicationError)
        .settingsSearchAnchor("profiles.appLanguage")
    }

    private func addApplicationLanguage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, !id.isEmpty else {
                applicationError = String(localized: "Choose a macOS application with a bundle identifier.")
                return
            }
            applicationError = nil
            var languages = app.settings.data.applicationLanguages ?? [:]
            // Re-selecting an existing application preserves its rule.
            if languages[id] == nil { languages[id] = app.settings.data.dictationPreferences(for: nil).language }
            var names = app.settings.data.applicationNames ?? [:]
            names[id] = FileManager.default.displayName(atPath: url.path)
            app.settings.data.applicationLanguages = languages
            app.settings.data.applicationNames = names
        }
    }

}

/// The app's own icon, so a list of rules reads at a glance. Falls back to a quiet glyph
/// when the app is no longer installed.
private struct ProfilesAppIcon: View {
    let bundleID: String
    @State private var icon: NSImage?

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: "app").symbolRenderingMode(.monochrome)
                    .foregroundStyle(Mono.tertiaryText)
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
        .task(id: bundleID) {
            // Launch Services lookup and icon decode off the main actor: a page of rules
            // otherwise resolved every icon in the first frames of its page transition.
            if let loaded = await AppIconLoader.icon(forBundleID: bundleID) {
                icon = loaded
            }
        }
    }
}

private struct CustomProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State var profile: CustomDictationProfile
    let isNew: Bool
    let onSave: (CustomDictationProfile) throws -> Void
    @State private var error: String?

    private var showsAction: Bool { profile.writingBehavior == .ask || profile.writingBehavior == .automatic }

    var body: some View {
        SettingsSheet(isNew ? "New Profile" : "Edit Profile", width: 520, height: 590) {
            VStack(alignment: .leading, spacing: 12) {
                ScrollView {
                    VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                        SettingsCard(title: "Name") {
                            TextField("For example, Work notes", text: $profile.name)
                                .textFieldStyle(.plain)
                                .font(Typo.body)
                                .foregroundStyle(Mono.primaryText)
                                .padding(Metrics.cardPadding)
                                .accessibilityLabel("Profile name")
                        }
                        SettingsCard(title: "Language & formatting") {
                            SettingsRow("Language") {
                                Picker("Language", selection: Binding(get: { profile.language ?? "default" }, set: { profile.language = $0 == "default" ? nil : $0 })) {
                                    Text("Use default").tag("default")
                                    ForEach(ProfilesSettingsView.languages, id: \.code) { Text($0.name).tag($0.code) }
                                }.labelsHidden().fixedSize()
                            }
                            SettingsCardDivider()
                            SettingsRow("Capitalize first letter") {
                                Toggle("Capitalize first letter", isOn: $profile.capitalize).labelsHidden().toggleStyle(MonoToggleStyle())
                            }
                            SettingsCardDivider()
                            SettingsRow("After each dictation") {
                                Picker("After each dictation", selection: $profile.ending) {
                                    ForEach(ProfileEnding.allCases, id: \.self) { Text($0.label).tag($0) }
                                }.labelsHidden().fixedSize()
                            }
                        }
                        SettingsCard(title: "Writing", footer: writingDescription) {
                            SettingsRow("Text editing") {
                                Picker("Text editing", selection: $profile.writingBehavior) {
                                    ForEach(ProfileWritingBehavior.allCases, id: \.self) { Text($0.label).tag($0) }
                                }.labelsHidden().fixedSize()
                            }
                            if showsAction {
                                VStack(spacing: 0) {
                                    SettingsCardDivider()
                                    SettingsRow("Action") {
                                        Picker("Writing action", selection: $profile.writingAction) {
                                            ForEach(WritingAction.allCases) { Text($0.label).tag($0.rawValue) }
                                        }.labelsHidden().fixedSize()
                                    }
                                }
                                .transition(.monoReveal(reduceMotion: reduceMotion))
                            }
                        }
                        .monoAnimation(Motion.reveal, value: showsAction)
                        SettingsFootnote("App language rules take priority. Fix Mistakes works with every profile.")
                    }.padding(2)
                }
                if let error {
                    SettingsNotice(error, systemImage: "exclamationmark.triangle")
                        .transition(.monoReveal(reduceMotion: reduceMotion))
                }
            }
            .monoAnimation(Motion.reveal, value: error)
        } actions: {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(MonoActionButtonStyle(.secondary))
            Button(isNew ? "Create Profile" : "Save Changes") {
                do { try onSave(profile); dismiss() }
                catch { self.error = error.localizedDescription }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(MonoActionButtonStyle(.primary))
            .disabled(profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var writingDescription: String {
        switch profile.writingBehavior {
        case .appRules: String(localized: "Uses rules from Writing.", comment: "Writing is the name of a settings page")
        case .off: String(localized: "Inserts your original words.")
        case .ask: String(localized: "Inserts your words, then offers a revision.")
        case .automatic: String(localized: "Revises before inserting. No preview. Requires Apple Intelligence.")
        }
    }
}

/// Resolves an app's Finder icon away from the main actor. `NSWorkspace` lookups are
/// thread-safe; the image only crosses back once it exists.
enum AppIconLoader {
    static func icon(forBundleID bundleID: String) async -> NSImage? {
        await Task.detached(priority: .utility) { () -> NSImage? in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
            return NSWorkspace.shared.icon(forFile: url.path)
        }.value
    }
}
