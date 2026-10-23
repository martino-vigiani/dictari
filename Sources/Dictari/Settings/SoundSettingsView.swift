// SoundSettingsView.swift
// Dictari — Microphone & Sound: input device first, then the start/stop beep and automatic
// stop; silence tuning and the distant-voice guard sit under Advanced.

import AVFoundation
import SwiftUI

// MARK: - Audio device model (discovered off main thread, delivered to main)

@MainActor
@Observable
private final class AudioDeviceList {
    struct Device: Identifiable {
        let id: String   // unique UID
        let name: String
    }

    private(set) var devices: [Device] = []

    func refresh() {
        // AVCaptureDevice discovery is safe on any thread but we hop off main to avoid jank.
        Task.detached(priority: .userInitiated) {
            let session = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.microphone],
                mediaType: .audio,
                position: .unspecified
            )
            let found = session.devices.map { Device(id: $0.uniqueID, name: $0.localizedName) }
            await MainActor.run {
                self.devices = found
            }
        }
    }
}

// MARK: - View

struct SoundSettingsView: View {
    @Environment(AppCoordinator.self) private var app
    @State private var deviceList = AudioDeviceList()
    @State private var showsAdvanced = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The stored value is optional so that settings files written before the filter existed
    /// still decode. The effective default is `.off`: a gate that wrongly rejects the user's
    /// own voice destroys the product's only function, while letting a distant voice through
    /// merely produces text they can delete. Turn it on after checking the measured levels
    /// below against real dictations.
    private var proximityBinding: Binding<ProximityFilter> {
        Binding(
            get: { app.settings.data.proximityFilter ?? .off },
            set: { app.settings.data.proximityFilter = $0 }
        )
    }

    /// Activation is a separate switch so choosing a strength cannot be mistaken for turning
    /// the guard on. The old single picker mixed those two decisions together.
    private var proximityEnabledBinding: Binding<Bool> {
        Binding(
            get: { proximityBinding.wrappedValue != .off },
            set: { enabled in
                proximityBinding.wrappedValue = enabled ? .normal : .off
            }
        )
    }

    /// Keep the measurement useful after a restart. History already stores it locally for each
    /// session; the old UI only showed the in-memory value from the current app launch.
    private var mostRecentSpeechLevel: Float? {
        if app.lastSpeechLevel > 0 { return app.lastSpeechLevel }
        return app.history.entries.first(where: { ($0.speechLevel ?? 0) > 0 })?.speechLevel
    }

    private var proximityMeasurementDetail: String {
        guard let level = mostRecentSpeechLevel else {
            return String(localized: "Dictate once, then return to compare.")
        }
        let filter = proximityBinding.wrappedValue
        return level >= filter.minimumSpeechLevel
            ? String(localized: "Would be kept with \(filter.label)",
                     comment: "The last dictation's level would pass the guard at this strength (Gentle, Normal, Strict)")
            : String(localized: "Would be rejected with \(filter.label)",
                     comment: "The last dictation's level would be blocked at this strength (Gentle, Normal, Strict)")
    }

    /// Rows inside the Advanced disclosure; a search result for one opens it.
    private static let advancedAnchors: Set<String> = [
        "sound.advanced", "sound.distantVoice",
    ]

    var body: some View {
        @Bindable var settings = app.settings
        SettingsScrollPane(title: SettingsSection.sound.label,
                           subtitle: "Which microphone Dictari listens to, and when a recording ends.") {
            // --- Microphone --- first: "which microphone" is the question people come here with.
            SettingsCard(title: "Microphone") {
                SettingsRow("Microphone") {
                    Picker("", selection: $settings.data.inputDeviceUID) {
                        Text("System Default", comment: "Microphone choice: the Mac's default input").tag(String?.none)
                        ForEach(deviceList.devices) { device in
                            Text(device.name).tag(Optional(device.id))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                    .accessibilityLabel("Microphone")
                }
                .onChange(of: settings.data.inputDeviceUID) { app.applySettings() }
                .settingsSearchAnchor("sound.inputDevice")
            }
            .task { deviceList.refresh() }
            .settingsSearchAnchor("sound.microphone")

            // --- Sounds and automatic stop ---
            SettingsCard(title: "While recording") {
                SettingsRow("Beep when recording starts and stops") {
                    Toggle("", isOn: $settings.data.soundCues)
                        .labelsHidden()
                        .toggleStyle(MonoToggleStyle())
                        .accessibilityLabel("Beep when recording starts and stops")
                }
                .onChange(of: settings.data.soundCues) { app.applySettings() }
                .settingsSearchAnchor("sound.cues")

                SettingsCardDivider()

                SettingsRow("Stop by itself when I stop talking",
                            sublabel: "Ends the recording after a pause") {
                    Toggle("", isOn: $settings.data.vadEnabled)
                        .labelsHidden()
                        .toggleStyle(MonoToggleStyle())
                        .accessibilityLabel("Stop by itself when I stop talking")
                }
                .onChange(of: settings.data.vadEnabled) { app.applySettings() }
                .settingsSearchAnchor("sound.stopAfterSilence")

                if settings.data.vadEnabled {
                    VStack(spacing: 0) {
                        SettingsCardDivider()

                        SettingsRow("Quiet For",
                                    sublabel: "Longer allows more time to pause and think") {
                            HStack(spacing: 8) {
                                MonoSlider(
                                    value: $settings.data.vadSilenceSeconds,
                                    range: 0.5...5.0,
                                    step: 0.5
                                )
                                .frame(width: 140)
                                .accessibilityLabel("Silence Duration")
                                .accessibilityValue(Text("\(Self.seconds(settings.data.vadSilenceSeconds)) seconds",
                                                         comment: "Pause length; the number has one decimal (e.g. 1.5)"))
                                // Steps of 0.5 s: the figure rolls a handful of times per drag.
                                Text("\(Self.seconds(settings.data.vadSilenceSeconds)) s",
                                     comment: "Pause length in seconds, abbreviated (e.g. 1.5 s)")
                                    .font(Typo.mono)
                                    .monospacedDigit()
                                    .foregroundStyle(Mono.secondaryText)
                                    .contentTransition(.numericText(value: settings.data.vadSilenceSeconds))
                                    .monoAnimation(Motion.snap, value: settings.data.vadSilenceSeconds)
                                    // A floor, not a fixed width: steady while the digits roll,
                                    // yet room for a longer unit in another language.
                                    .frame(minWidth: 38, alignment: .trailing)
                            }
                        }
                        .onChange(of: settings.data.vadSilenceSeconds) { app.applySettings() }
                    }
                    .transition(.monoReveal(reduceMotion: reduceMotion))
                }
            }
            .monoAnimation(Motion.reveal, value: settings.data.vadEnabled)
            .settingsSearchAnchor("sound.whileRecording")

            // --- Advanced ---
            SettingsAdvancedDisclosure(isExpanded: $showsAdvanced) {
                if settings.data.vadEnabled {
                    SettingsCard(title: "Automatic stop",
                                 footer: "Sensitivity sets the silence level. It doesn't clean audio or identify speakers.") {
                        VADSensitivityRow(
                            value: $settings.data.vadSensitivity,
                            onChanged: { app.applySettings() }
                        )
                    }
                    .transition(.monoReveal(reduceMotion: reduceMotion))
                }

                SettingsCard(title: "Other voices",
                             footer: proximityEnabledBinding.wrappedValue
                                ? "Uses overall volume. It may reject a quiet dictation, but it can't isolate speakers."
                                : nil) {
                    SettingsRow("Ignore voices far from the microphone",
                                sublabel: "Skips dictations that are too quiet overall") {
                        Toggle("", isOn: proximityEnabledBinding)
                            .labelsHidden()
                            .toggleStyle(MonoToggleStyle())
                            .accessibilityLabel("Ignore voices far from the microphone")
                    }
                    .settingsSearchAnchor("sound.distantVoice")

                    if proximityEnabledBinding.wrappedValue {
                        VStack(spacing: 0) {
                            SettingsCardDivider()

                            // Three strengths: all visible at once; the sublabel gives the
                            // threshold of the selected one.
                            SettingsRow("Strength",
                                        sublabel: proximityBinding.wrappedValue.detail) {
                                MonoSegmented(
                                    selection: proximityBinding,
                                    options: [ProximityFilter.gentle, .normal, .strict].map { ($0, $0.label) }
                                )
                                .fixedSize()
                                .accessibilityLabel("Distant Voice Guard Strength")
                            }
                            .monoAnimation(Motion.swap, value: proximityBinding.wrappedValue)

                            SettingsCardDivider()

                            SettingsRow("Last Voice Level",
                                        sublabel: proximityMeasurementDetail) {
                                Text(mostRecentSpeechLevel.map { String(format: "%.2f", $0) } ?? "—")
                                    .font(Typo.mono)
                                    .foregroundStyle(Mono.secondaryText)
                                    .monospacedDigit()
                                    .textSelection(.enabled)
                            }
                        }
                        .transition(.monoReveal(reduceMotion: reduceMotion))
                    }
                }
                .monoAnimation(Motion.reveal, value: proximityEnabledBinding.wrappedValue)
            }
            .monoAnimation(Motion.reveal, value: settings.data.vadEnabled)
            .settingsSearchAnchor("sound.advanced")
        }
        .onSettingsSearchReveal(Self.advancedAnchors) { _ in showsAdvanced = true }
    }

    /// One decimal in the interface locale ("1.5" in English, "1,5" in Italian).
    private static func seconds(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)).locale(SpokenLanguages.interfaceLocale))
    }
}

// MARK: - VAD sensitivity

/// Descriptive choices make the trade-off explicit. A bare 1–5 slider hid the important part:
/// higher values stop more readily in room noise, but can mistake a soft voice for silence.
private struct VADSensitivityRow: View {
    @Binding var value: Int
    let onChanged: () -> Void

    var body: some View {
        SettingsRow("What Counts as Silence",
                    sublabel: detail) {
            Picker("", selection: $value) {
                ForEach(1...5, id: \.self) { option in
                    Text(label(for: option)).tag(option)
                }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Silence Sensitivity")
            .accessibilityValue(label(for: value))
        }
        .onChange(of: value) { onChanged() }
    }

    private var detail: String {
        switch value {
        case 1: return String(localized: "Keeps listening through very soft speech and room noise")
        case 2: return String(localized: "Tolerant of soft speech")
        case 3: return String(localized: "Balanced for most rooms")
        case 4: return String(localized: "Stops sooner in steady background noise")
        default: return String(localized: "Stops fastest; may cut off quiet speech")
        }
    }

    private func label(for option: Int) -> String {
        switch option {
        case 1: return String(localized: "1 — Very Tolerant", comment: "Silence sensitivity level 1 of 5")
        case 2: return String(localized: "2 — Tolerant", comment: "Silence sensitivity level 2 of 5")
        case 3: return String(localized: "3 — Balanced", comment: "Silence sensitivity level 3 of 5")
        case 4: return String(localized: "4 — Firm", comment: "Silence sensitivity level 4 of 5")
        default: return String(localized: "5 — Strict", comment: "Silence sensitivity level 5 of 5")
        }
    }
}

#Preview {
    SoundSettingsView()
        .environment(AppCoordinator())
        .frame(width: 600, height: 500)
}
