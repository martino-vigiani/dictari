// AppearanceSettingsView.swift
// Dictari — how the app looks and starts: launch at login, light/dark, and the recording
// indicator (internally "the pill"; the word means nothing to someone who never read the code).

import ServiceManagement
import SwiftUI

struct AppearanceSettingsView: View {
    @Environment(AppCoordinator.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        SettingsScrollPane(title: SettingsSection.appearance.label,
                           subtitle: "How Dictari starts, its light or dark look, and the indicator you see while dictating.") {
            // --- App ---
            SettingsCard(title: "App") {
                SettingsRow("Launch at Login") {
                    Toggle("", isOn: $settings.data.launchAtLogin)
                        .labelsHidden()
                        .toggleStyle(MonoToggleStyle())
                        .accessibilityLabel("Launch at Login")
                }
                .onChange(of: settings.data.launchAtLogin, applyLaunchAtLogin)
                .onAppear {
                    settings.data.launchAtLogin = SMAppService.mainApp.status == .enabled
                }
                .settingsSearchAnchor("appearance.launchAtLogin")

                SettingsCardDivider()

                SettingsRow("Appearance") {
                    AppearancePicker(selection: $settings.data.appearance)
                }
                .onChange(of: settings.data.appearance) {
                    app.applySettings()
                }
                .settingsSearchAnchor("appearance.appearance")
            }
            .settingsSearchAnchor("appearance.app")

            // --- Recording indicator (the pill) ---
            SettingsCard(title: "Recording indicator") {
                // Three styles: a segmented control shows them all; the sublabel describes the
                // selected one and cross-fades as the thumb moves.
                SettingsRow("Style", sublabel: settings.data.pillStyle.detail) {
                    MonoSegmented(
                        selection: $settings.data.pillStyle,
                        options: PillStyle.allCases.map { ($0, $0.label) }
                    )
                    // Sized by its labels, not a fixed 230 pt that clips longer translations.
                    .fixedSize()
                    .accessibilityLabel("Recording indicator style")
                }
                .monoAnimation(Motion.swap, value: settings.data.pillStyle)
                .onChange(of: settings.data.pillStyle) { app.applySettings() }
                .settingsSearchAnchor("appearance.indicatorStyle")

                SettingsCardDivider()

                SettingsRow("Position") {
                    Picker("", selection: $settings.data.pillPosition) {
                        ForEach(PillPosition.allCases) { p in
                            Text(p.label).tag(p)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("Recording indicator position")
                }
                .onChange(of: settings.data.pillPosition) {
                    // A preset position should override a previous manual drag.
                    settings.data.pillCustomOrigin = nil
                    app.applySettings()
                }
                .settingsSearchAnchor("appearance.indicatorPosition")

                SettingsCardDivider()

                SettingsRow("Always show",
                            sublabel: "Keeps the indicator on screen even when you are not dictating") {
                    Toggle("", isOn: $settings.data.alwaysShowPill)
                        .labelsHidden()
                        .toggleStyle(MonoToggleStyle())
                        .accessibilityLabel("Always show recording indicator")
                }
                .onChange(of: settings.data.alwaysShowPill) { app.applySettings() }
                .settingsSearchAnchor("appearance.alwaysShowIndicator")
            }
            .settingsSearchAnchor("appearance.indicator")
        }
    }

    private func applyLaunchAtLogin() {
        do {
            if app.settings.data.launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Reflect the OS truth if registration is refused or requires another action.
            app.settings.data.launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

#Preview {
    AppearanceSettingsView()
        .environment(AppCoordinator())
        .frame(width: 600, height: 500)
}
