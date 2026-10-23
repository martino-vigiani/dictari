// DictationSettingsView.swift
// Dictari — the Dictation page: shortcut and mode, languages, and how text reaches the app.
//
// This page gathers what used to be split between "Shortcuts" and the catch-all "General":
// everything that decides what happens between pressing the key and seeing the words. The
// controls most people never touch (delivery method, clipboard restore, live typing) sit
// behind an "Advanced" disclosure so the page opens on the few choices that matter.

import SwiftUI

struct DictationSettingsView: View {
    @Environment(AppCoordinator.self) private var app
    @State private var shortcutError: String?
    @State private var showsAdvanced = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The default-language picker. "Auto-detect" chooses among the languages the user
    /// speaks (see `SpokenLanguages`); picking one of Russian/Ukrainian allows Cyrillic, while
    /// "Auto-detect" stays Latin-only (ParakeetEngine).
    /// Shared with the Profiles page. Computed, so the label follows the interface language;
    /// the "auto" code is what settings store and is never translated.
    static var languages: [(code: String, name: String)] {
        [("auto", String(localized: "Auto-detect",
                         comment: "Language picker option: let the app detect the spoken language"))]
            + SpokenLanguages.supported
    }

    /// Rows that live inside the Advanced disclosure; a search result for one opens it.
    private static let advancedAnchors: Set<String> = [
        "dictation.advanced", "dictation.pasteIntoFocus", "dictation.deliveryMethod", "dictation.liveTyping",
    ]

    var body: some View {
        @Bindable var settings = app.settings
        SettingsScrollPane(title: SettingsSection.dictation.label,
                           subtitle: "The keys that start dictation, the languages you speak, and how the text reaches your apps.") {
            // --- Shortcut ---
            // The card and its notices share one block, so a clash shows up right under the
            // shortcuts that caused it and the page below slides down with it.
            VStack(alignment: .leading, spacing: Metrics.cardLabelGap) {
                SettingsCard(title: "Shortcut", footer: Self.shortcutFootnote) {
                    SettingsRow("Start and Stop Dictation") {
                        KeyRecorderView(shortcut: editableShortcut(cancel: false))
                    }
                    .onChange(of: settings.data.dictationShortcut) { app.applySettings() }
                    .settingsSearchAnchor("dictation.shortcut")

                    SettingsCardDivider()

                    // Two choices: a segmented control shows both at once, where a pop-up hid the
                    // alternative. The sublabel spells out the selected one.
                    SettingsRow("Mode", sublabel: Self.modeDetail(settings.data.interactionMode)) {
                        MonoSegmented(
                            selection: $settings.data.interactionMode,
                            options: InteractionMode.allCases.map { ($0, Self.modeLabel($0)) }
                        )
                        // Each segment at its own text width: a fixed 230 pt cut "Press to
                        // Start/Stop" short even in English, and German runs ~40% longer. The
                        // row's label and sublabel wrap to make room instead.
                        .fixedSize()
                        .accessibilityLabel(Text("Mode", comment: "Row title: press vs hold to dictate"))
                    }
                    .monoAnimation(Motion.swap, value: settings.data.interactionMode)
                    .onChange(of: settings.data.interactionMode) { app.applySettings() }
                    .settingsSearchAnchor("dictation.mode")

                    SettingsCardDivider()

                    SettingsRow("Conversation Mode",
                                sublabel: "Keeps listening: each pause pastes what you said. Press again to stop.") {
                        HStack(spacing: 6) {
                            if settings.data.conversationShortcut != nil {
                                KeyRecorderView(shortcut: conversationShortcutBinding)
                                    .transition(.opacity)
                                Button {
                                    shortcutError = nil
                                    app.settings.data.conversationShortcut = nil
                                } label: {
                                    Image(systemName: "xmark.circle")
                                }
                                .buttonStyle(MonoGlyphButtonStyle())
                                .accessibilityLabel("Turn Off Conversation Mode")
                                .help("Turn off Conversation Mode")
                                .transition(.opacity)
                            } else {
                                Button("Turn On") {
                                    shortcutError = nil
                                    app.settings.data.conversationShortcut =
                                        app.settings.data.conversationShortcutChoice ?? .defaultConversation
                                }
                                .buttonStyle(MonoActionButtonStyle(.secondary, size: .small))
                                .transition(.opacity)
                            }
                        }
                        .monoAnimation(Motion.swap, value: settings.data.conversationShortcut == nil)
                    }
                    .onChange(of: settings.data.conversationShortcut) { app.applySettings() }
                    .settingsSearchAnchor("dictation.conversation")

                    SettingsCardDivider()

                    SettingsRow("Cancel Dictation",
                                sublabel: "Throws away the recording without writing anything") {
                        KeyRecorderView(shortcut: editableShortcut(cancel: true))
                    }
                    .onChange(of: settings.data.cancelShortcut) { app.applySettings() }
                    .settingsSearchAnchor("dictation.cancel")

                    if let hotkeyIssue = app.hotkeyIssue {
                        SettingsNotice(hotkeyIssue, systemImage: "exclamationmark.triangle")
                            .padding(.horizontal, Metrics.cardPadding)
                            .padding(.bottom, Metrics.cardPadding)
                            .transition(.monoReveal(reduceMotion: reduceMotion))
                    }
                }
                .monoAnimation(Motion.reveal, value: app.hotkeyIssue)

                ForEach(shortcutNotices, id: \.self) { notice in
                    SettingsNotice(notice, systemImage: "exclamationmark.triangle")
                        .transition(.monoReveal(reduceMotion: reduceMotion))
                }
            }
            .monoAnimation(Motion.reveal, value: shortcutNotices)

            // --- Language ---
            SettingsCard(title: "Language") {
                SpokenLanguagesControl()
                    .settingsSearchAnchor("dictation.spokenLanguages")

                SettingsCardDivider()

                // Precedence, in words: an app rule beats the profile, which beats this.
                SettingsRow("Language",
                            sublabel: "Profiles and apps can choose their own") {
                    Picker("", selection: $settings.data.defaultLanguage) {
                        ForEach(Self.languages, id: \.code) { lang in
                            Text(lang.name).tag(lang.code)
                        }
                    }
                    .labelsHidden()
                    // Sized by its longest item, so a translated "Auto-detect" is never cut.
                    .fixedSize()
                    .accessibilityLabel("Language")
                }
                .settingsSearchAnchor("dictation.language")

                SettingsCardDivider()

                SettingsRow("Spoken Punctuation",
                            sublabel: "Say \u{201C}comma\u{201D}, \u{201C}period\u{201D}, \u{201C}new line\u{201D} in any of your languages") {
                    Toggle("", isOn: $settings.data.spokenCommandsEnabled)
                        .labelsHidden()
                        .toggleStyle(MonoToggleStyle())
                        .accessibilityLabel("Spoken Punctuation")
                }
                .settingsSearchAnchor("dictation.spokenPunctuation")
            }

            // --- Text ---
            SettingsCard(title: "Text") {
                SettingsRow("Start each dictation with a capital letter") {
                    Toggle("", isOn: $settings.data.autoCapitalize)
                        .labelsHidden()
                        .toggleStyle(MonoToggleStyle())
                        .accessibilityLabel("Start each dictation with a capital letter")
                }
                .onChange(of: settings.data.autoCapitalize) { app.applySettings() }
                .settingsSearchAnchor("dictation.autoCapitalise")

                SettingsCardDivider()

                SettingsRow("Add a space after each dictation") {
                    Toggle("", isOn: $settings.data.trailingSpace)
                        .labelsHidden()
                        .toggleStyle(MonoToggleStyle())
                        .accessibilityLabel("Add a space after each dictation")
                }
                .onChange(of: settings.data.trailingSpace) { app.applySettings() }
                .settingsSearchAnchor("dictation.trailingSpace")
            }
            .monoAnimation(Motion.reveal, value: app.permissions.accessibility)
            .settingsSearchAnchor("dictation.text")

            // --- Advanced ---
            SettingsAdvancedDisclosure(isExpanded: $showsAdvanced) {
                SettingsCard(title: "How text is inserted") {
                    SettingsRow("Type the text where my cursor is",
                                sublabel: "When off, the text waits in the recording indicator for you to copy") {
                        Toggle("", isOn: $settings.data.autoPasteIntoFocus)
                            .labelsHidden()
                            .toggleStyle(MonoToggleStyle())
                            .accessibilityLabel("Type the text where my cursor is")
                    }
                    .settingsSearchAnchor("dictation.pasteIntoFocus")

                    SettingsCardDivider()

                    SettingsRow("How text is inserted",
                                sublabel: "Change only if an app refuses the text") {
                        MonoSegmented(
                            selection: $settings.data.injectionMethod,
                            options: InjectionMethod.allCases.map { ($0, $0.label) }
                        )
                        .fixedSize()
                        .accessibilityLabel("How text is inserted")
                    }
                    .onChange(of: settings.data.injectionMethod) { app.applySettings() }
                    .settingsSearchAnchor("dictation.deliveryMethod")

                    if settings.data.injectionMethod == .paste {
                        VStack(spacing: 0) {
                            SettingsCardDivider()

                            SettingsRow("Keep what I had copied",
                                        sublabel: "Puts your clipboard back after pasting") {
                                Toggle("", isOn: $settings.data.restoreClipboard)
                                    .labelsHidden()
                                    .toggleStyle(MonoToggleStyle())
                                    .accessibilityLabel("Keep what I had copied")
                            }
                            .onChange(of: settings.data.restoreClipboard) { app.applySettings() }
                        }
                        .transition(.monoReveal(reduceMotion: reduceMotion))
                    }

                    SettingsCardDivider()

                    // Applies from the next dictation; the coordinator reads it at start.
                    SettingsRow("Live Typing",
                                sublabel: settings.data.autoPasteIntoFocus
                                    ? "Types words as you speak, then corrects them. Stops if you type or click. Parakeet models only."
                                    : "Needs \u{201C}Type the text where my cursor is\u{201D} turned on.") {
                        Toggle("", isOn: $settings.data.liveTypingEnabled)
                            .labelsHidden()
                            .toggleStyle(MonoToggleStyle())
                            .accessibilityLabel("Live Typing")
                    }
                    .disabled(!settings.data.autoPasteIntoFocus)
                    .settingsSearchAnchor("dictation.liveTyping")
                }
                .monoAnimation(Motion.reveal, value: settings.data.injectionMethod)
                .monoAnimation(Motion.swap, value: settings.data.autoPasteIntoFocus)
            }
            .settingsSearchAnchor("dictation.advanced")
        }
        .onSettingsSearchReveal(Self.advancedAnchors) { _ in showsAdvanced = true }
    }

    private static func modeLabel(_ mode: InteractionMode) -> String {
        switch mode {
        case .toggle:     return String(localized: "Press to Start/Stop",
                                            comment: "Segment: dictation mode where one press starts and the next stops")
        case .pushToTalk: return String(localized: "Hold to Talk",
                                            comment: "Segment: dictation mode active only while the keys are held")
        }
    }

    private static func modeDetail(_ mode: InteractionMode) -> String {
        switch mode {
        case .toggle:     return String(localized: "Press once to start, press again to stop")
        case .pushToTalk: return String(localized: "Hold the keys while you speak, let go to finish")
        }
    }

    /// Replaces the old "Shortcuts work system-wide" tip card at the bottom of the page: the
    /// advice belongs under the shortcuts it is about.
    private static var shortcutFootnote: String {
        String(localized: "Shortcuts work in every app and need Accessibility access. Avoid combinations macOS or another app already uses.")
    }

    /// Everything that is wrong with the shortcuts right now, in display order. Derived from
    /// the same conditions the page always checked; only the presentation is shared.
    private var shortcutNotices: [String] {
        let data = app.settings.data
        var notices: [String] = []
        if let shortcutError { notices.append(shortcutError) }
        if data.dictationShortcut == .revisionDictation || data.cancelShortcut == .revisionDictation {
            notices.append(String(localized: "Command Option Shift Space is reserved for Dictate and Fix Mistakes. Choose another shortcut.",
                                  comment: "Key names spelled out; Dictate and Fix Mistakes is a feature name"))
        }
        if let stored = data.conversationShortcut,
           ConversationPolicy.effectiveShortcut(stored, dictation: data.dictationShortcut,
                                                cancel: data.cancelShortcut) == nil {
            notices.append(String(localized: "Conversation Mode is inactive: its shortcut is already used by another action. Record a different one."))
        }
        return notices
    }

    private func editableShortcut(cancel: Bool) -> Binding<Shortcut> {
        Binding(
            get: { cancel ? app.settings.data.cancelShortcut : app.settings.data.dictationShortcut },
            set: { shortcut in
                let other = cancel ? app.settings.data.dictationShortcut : app.settings.data.cancelShortcut
                guard shortcut != .finderSearch else {
                    shortcutError = String(localized: "Option Command Space belongs to Finder Search. Choose another shortcut.")
                    return
                }
                guard shortcut != .revisionDictation, shortcut != other,
                      shortcut != app.settings.data.conversationShortcut else {
                    shortcutError = String(localized: "Choose a different shortcut. This combination already has an action.")
                    return
                }
                shortcutError = nil
                if cancel { app.settings.data.cancelShortcut = shortcut }
                else { app.settings.data.dictationShortcut = shortcut }
            }
        )
    }

    /// Only reachable while the mode is on (the recorder is hidden otherwise).
    private var conversationShortcutBinding: Binding<Shortcut> {
        Binding(
            get: { app.settings.data.conversationShortcut ?? .defaultConversation },
            set: { shortcut in
                switch ConversationPolicy.validate(shortcut,
                                                   dictation: app.settings.data.dictationShortcut,
                                                   cancel: app.settings.data.cancelShortcut) {
                case .systemOwned:
                    shortcutError = String(localized: "Option Command Space belongs to Finder Search. Choose another shortcut.")
                case .unsafe:
                    shortcutError = String(localized: "Conversation Mode needs a modifier (Command, Option, Control or Shift) or a function key.")
                case .duplicate:
                    shortcutError = String(localized: "Choose a different shortcut. This combination already has an action.")
                case nil:
                    shortcutError = nil
                    app.settings.data.conversationShortcut = shortcut
                }
            }
        )
    }
}

// MARK: - Languages I speak

/// Multi-select of the languages the user speaks. Order is meaningful: the first is the main
/// language, which `ShortUtteranceFix` writes short drifted phrases into. The set is never
/// empty — "Auto-detect" needs at least one language to choose from.
struct SpokenLanguagesControl: View {
    @Environment(AppCoordinator.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Before the first edit this is the Mac's own preferred languages (`spokenLanguages`
        // is nil); the first tap stores the list explicitly.
        let selected = app.settings.data.effectiveSpokenLanguages
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Languages I speak")
                    .font(Typo.body)
                    .foregroundStyle(Mono.primaryText)
                Text("Auto-detect chooses only among these.")
                    .font(Typo.secondary)
                    .foregroundStyle(Mono.secondaryText)
            }

            FlowRow(spacing: 8) {
                ForEach(SpokenLanguages.supported, id: \.code) { language in
                    chip(language, selected: selected)
                }
            }

            if selected.count > 1 {
                HStack {
                    Text("Main language")
                        .font(Typo.body)
                        .foregroundStyle(Mono.primaryText)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { selected.first ?? "en" },
                        set: { makeMain($0) }
                    )) {
                        ForEach(selected, id: \.self) { code in
                            Text(Self.name(code)).tag(code)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("Main language")
                }
                .transition(.monoReveal(reduceMotion: reduceMotion))
            }

            if selected.contains("en") {
                Text("Short phrases are fixed into your main language only when English is not selected.")
                    .font(Typo.secondary)
                    .foregroundStyle(Mono.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.monoReveal(reduceMotion: reduceMotion))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Metrics.cardPadding)
        // One spring for the whole control: chips refill and reflow, and the "Main language"
        // row and the English note slide in or out with them.
        .monoAnimation(Motion.snap, value: selected)
    }

    private func chip(_ language: (code: String, name: String), selected: [String]) -> some View {
        let isSelected = selected.contains(language.code)
        let isMain = selected.first == language.code
        let isLast = isSelected && selected.count == 1
        return Button { toggle(language.code) } label: {
            LanguageChipLabel(name: language.name, isSelected: isSelected,
                              isMain: isMain && selected.count > 1)
        }
        .buttonStyle(MonoPlainButtonStyle(scales: true))
        .help(isLast ? Text("Keep at least one language") : Text(verbatim: ""))
        .accessibilityLabel(language.name)
        .accessibilityValue(isMain
            ? Text("Selected, main language", comment: "Accessibility value of a language chip")
            : (isSelected
                ? Text("Selected", comment: "Accessibility value of a language chip")
                : Text("Not selected", comment: "Accessibility value of a language chip")))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(isLast ? Text("At least one language must stay selected") : Text(verbatim: ""))
    }

    private func toggle(_ code: String) {
        var list = app.settings.data.effectiveSpokenLanguages
        if let index = list.firstIndex(of: code) {
            guard list.count > 1 else { return }
            list.remove(at: index)
        } else {
            list.append(code)
        }
        store(list)
    }

    private func makeMain(_ code: String) {
        var list = app.settings.data.effectiveSpokenLanguages
        list.removeAll { $0 == code }
        list.insert(code, at: 0)
        store(list)
    }

    private func store(_ list: [String]) {
        app.settings.data.spokenLanguages = list
        // `configureComponents()` publishes the set to `SpokenLanguages.current`, which the
        // Whisper engine reads off-actor at transcription time.
        app.applySettings()
    }

    static func name(_ code: String) -> String {
        SpokenLanguages.supported.first { $0.code == code }?.name ?? code
    }
}

/// A language chip: ink capsule when selected, field grey with a hover wash when not. The
/// checkmark and "main" tag fade in place while the chip widens around them.
private struct LanguageChipLabel: View {
    let name: String
    let isSelected: Bool
    let isMain: Bool
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 5) {
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .transition(.opacity)
            }
            Text(name)
                .font(Typo.secondary.weight(.medium))
            if isMain {
                Text("main", comment: "Tag on the language chip of the main spoken language; lower case")
                    .font(Typo.secondary)
                    .opacity(0.7)
                    .transition(.opacity)
            }
        }
        .foregroundStyle(isSelected ? Mono.selectionText : Mono.primaryText)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background {
            Capsule(style: .continuous).fill(isSelected ? Mono.selection : Mono.fieldFill)
            if !isSelected && hovered {
                Capsule(style: .continuous).fill(Mono.hover)
            }
        }
        .contentShape(Capsule(style: .continuous))
        .onHover { hovered = $0 }
        .monoAnimation(Motion.hover, value: hovered)
    }
}


#Preview {
    DictationSettingsView()
        .environment(AppCoordinator())
        .frame(width: 600, height: 700)
}
