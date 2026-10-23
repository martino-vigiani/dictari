// UpdatesSettingsView.swift
// Dictari — the Updates screen: installed version and Sparkle's update controls.

import SwiftUI

struct UpdatesSettingsView: View {
    @Environment(AppCoordinator.self) private var app

    var body: some View {
        SettingsScrollPane(
            title: SettingsSection.updates.label,
            subtitle: "Installed version and update checks."
        ) {
            SettingsCard(title: "Updates") {
                UpdaterSettingsRow(updater: app.updater)
            }
            .settingsSearchAnchor("updates.updates")
        }
    }
}
