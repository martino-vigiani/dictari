import Combine
import Sparkle
import SwiftUI

/// Thin `@MainActor` wrapper around `SPUUpdater` so the rest of the app
/// (a settings row, the main menu) can bind to update state without touching Sparkle types
/// directly. Sparkle is Objective-C/KVO-based; `canCheckForUpdates` is bridged through Combine
/// into an `@Observable` property so SwiftUI invalidates correctly.
///
/// Dictari is not sandboxed, so no `SUEnableInstallerLauncherService` / XPC entitlements are
/// needed — see `scripts/appcast.md` for what a non-sandboxed hardened-runtime app requires.
///
/// Sparkle needs both a real EdDSA public key and an HTTPS appcast. Development builds made from
/// an incomplete checkout stay inert instead of presenting an app-modal startup failure that
/// would hide onboarding.
@MainActor
@Observable
final class UpdaterController {

    /// The literal shipped in Info.plist before a real key exists. Anything containing this
    /// marker means "not configured yet".
    private static let placeholderMarker = "REPLACE_WITH"

    private let updater: SPUUpdater?
    private var cancellable: AnyCancellable?
    @ObservationIgnored private var automaticChecksCancellable: AnyCancellable?
    private var automaticChecksEnabled = false

    /// False until both trust material and the feed URL are real. Drives the settings copy.
    let isConfigured: Bool
    /// False for the local Debug build and for isolated test/self-test processes.
    /// A developer copy must never update itself into the public Release build.
    let isEnabled: Bool

    private(set) var canCheckForUpdates: Bool = false

    /// SwiftUI observes the stored mirror; Sparkle's Objective-C getter alone does not
    /// register an Observation dependency. Read back what Sparkle accepted after each write.
    var automaticallyChecksForUpdates: Bool {
        get { automaticChecksEnabled }
        set {
            guard let updater else { return }
            updater.automaticallyChecksForUpdates = newValue
            automaticChecksEnabled = updater.automaticallyChecksForUpdates
        }
    }

    init(enabled: Bool = true) {
        isEnabled = enabled
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        isConfigured = !key.isEmpty
            && !key.contains(Self.placeholderMarker)
            && feed.hasPrefix("https://")
            && !feed.contains(Self.placeholderMarker)

        guard enabled, isConfigured else {
            updater = nil
            return
        }

        let driver = DictariUpdateUserDriver(hostBundle: .main, delegate: nil)
        let updater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: driver,
            delegate: nil
        )
        self.updater = updater
        automaticChecksEnabled = updater.automaticallyChecksForUpdates
        automaticChecksCancellable = updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                // Sparkle can change this from its own UI. Read its current value so an
                // older queued KVO notification cannot undo a more recent toggle click.
                self.automaticChecksEnabled = self.updater?.automaticallyChecksForUpdates ?? false
            }
        cancellable = updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.canCheckForUpdates = value
            }

        do {
            try updater.start()
        } catch {
            // Keep startup failures visible, with the same delay as Sparkle's adapter.
            let message = error.localizedDescription
            NSLog("Dictari updater failed to start: %@", message)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let alert = NSAlert()
                alert.messageText = "Unable to Check for Updates"
                alert.informativeText = message
                alert.runModal()
            }
        }
    }

    /// Triggers Sparkle's normal UI-driven update flow (progress window, permission prompts).
    func checkForUpdates() {
        updater?.checkForUpdates()
    }
}

/// Keep Sparkle's native update UI and acknowledgement lifecycle, changing only the
/// misleading "newest version" wording when a local build is ahead of its update channel.
@MainActor
private final class DictariUpdateUserDriver: SPUStandardUserDriver {
    override func showUpdateNotFoundWithError(
        _ error: Error,
        acknowledgement: @escaping () -> Void
    ) {
        let original = error as NSError
        guard let reason = original.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber,
              reason.intValue == SPUNoUpdateFoundReason.onNewerThanLatestVersion.rawValue else {
            super.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement)
            return
        }

        let installedName = DictariVersion.displayName
        var info = original.userInfo
        info[NSLocalizedDescriptionKey] = "You're running a newer version"
        info[NSLocalizedRecoverySuggestionErrorKey] =
            "\(installedName) is newer than the release available on this update channel. No update is needed."
        let presentation = NSError(domain: original.domain, code: original.code, userInfo: info)
        super.showUpdateNotFoundWithError(presentation, acknowledgement: acknowledgement)
    }
}

/// Human-readable version plus the machine-readable build Sparkle actually compares.
/// Keeping both visible prevents two builds with the same marketing version from looking
/// identical in Settings and in the "newer than channel" acknowledgement.
private enum DictariVersion {
    static var displayName: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String
        let build = info["CFBundleVersion"] as? String

        switch (version, build) {
        case let (.some(version), .some(build)): return "Dictari \(version) (\(build))"
        case let (.some(version), .none): return "Dictari \(version)"
        case let (.none, .some(build)): return "Dictari build \(build)"
        case (.none, .none): return "Dictari"
        }
    }
}

/// Minimal, self-contained settings row for update preferences.
struct UpdaterSettingsRow: View {
    @Bindable var updater: UpdaterController

    var body: some View {
        SettingsRow("Installed Version") {
            Text(DictariVersion.displayName.replacingOccurrences(of: "Dictari ", with: ""))
                .font(Typo.mono)
                .foregroundStyle(Mono.secondaryText)
                .monospacedDigit()
        }

        SettingsCardDivider()

        if !updater.isEnabled {
            SettingsRow(
                "Automatic updates",
                sublabel: "Disabled for the local development build so it cannot be replaced by a Release build"
            ) {
                Text("Off")
                    .font(Typo.secondary)
                    .foregroundStyle(Mono.secondaryText)
            }
        } else if updater.isConfigured {
            SettingsRow("Check automatically") {
                Toggle("", isOn: $updater.automaticallyChecksForUpdates)
                    .labelsHidden()
                    .toggleStyle(MonoToggleStyle())
                    .accessibilityLabel("Check for updates automatically")
            }

            SettingsCardDivider()

            SettingsRow("Check now") {
                Button("Check for Updates…") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
            }
        } else {
            SettingsRow("Check for Updates",
                        sublabel: "Needs a signed appcast before remote updates can be checked") {
                Text("Not configured")
                    .font(Typo.secondary)
                    .foregroundStyle(Mono.secondaryText)
            }
        }
    }
}
