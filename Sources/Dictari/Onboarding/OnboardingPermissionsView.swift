// OnboardingPermissionsView.swift
// Dictari — step two: the two system permissions, asked for honestly.
//
// Accessibility is the one that frightens people, and it deserves the plainest sentence in the
// app: it is what lets a global shortcut be heard while another app is frontmost, and what
// lets the finished text be typed there. Saying that once, in the row itself, is worth more
// than any amount of reassurance elsewhere.
//
// Granting happens in System Settings, which means the app is in the background when the state
// changes — so the rows poll `refreshPermissions()` rather than waiting for a relaunch.

import AVFoundation
import SwiftUI

struct OnboardingPermissionsView: View {
    @Environment(AppCoordinator.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var onContinue: () -> Void

    /// False until the first poll lands, so the rows can say "checking" instead of flashing
    /// "needed" for a frame on a Mac where both are already granted.
    @State private var hasChecked = false
    /// Set once the user has been shown the system prompt; after that the only way forward is
    /// System Settings, so the button changes to say so.
    @State private var micRequested = false
    @State private var accessibilityRequested = false

    private var micGranted: Bool { app.permissions.microphone }
    private var accessibilityGranted: Bool { app.permissions.accessibility }

    var body: some View {
        OnboardingScaffold(
            eyebrow: Strings.eyebrow,
            title: Strings.title,
            subtitle: Strings.subtitle
        ) {
            VStack(spacing: 0) {
                MonoCard {
                    VStack(spacing: 0) {
                        micRow
                        Divider().opacity(0.35).padding(.vertical, 4)
                        accessibilityRow
                    }
                }
                .staged(3)

                if micGranted && !accessibilityGranted {
                    Text(Strings.accessibilityLater)
                        .font(Typo.secondary)
                        .foregroundStyle(Mono.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 480, alignment: .leading)
                        .padding(.top, 12)
                        .transition(.opacity)
                }
            }
            .padding(.top, 22)
            .animation(Motion.reduced(Motion.appear, reduceMotion: reduceMotion), value: micGranted)
            .animation(Motion.reduced(Motion.appear, reduceMotion: reduceMotion), value: accessibilityGranted)
        } actions: {
            OnboardingButton(title: Strings.action, isEnabled: micGranted, action: onContinue)
        }
        // The user grants in another app; nothing would tell us otherwise.
        .task {
            while !Task.isCancelled {
                app.refreshPermissions()
                hasChecked = true
                try? await Task.sleep(for: .milliseconds(800))
            }
        }
    }

    // MARK: - Rows

    private var micRow: some View {
        PermissionRow(
            icon: "mic",
            title: Strings.micTitle,
            reason: Strings.micReason,
            state: state(granted: micGranted),
            actionTitle: micRequested ? Strings.openSettings : Strings.allow
        ) {
            if micRequested {
                PermissionIssue.microphone.openSystemSettings()
            } else {
                micRequested = true
                Task {
                    // The real prompt. Returns immediately without one if the user has
                    // already denied it — hence the fallback to System Settings above.
                    _ = await AVCaptureDevice.requestAccess(for: .audio)
                    app.refreshPermissions()
                }
            }
        }
    }

    private var accessibilityRow: some View {
        PermissionRow(
            icon: "keyboard",
            title: Strings.accessibilityTitle,
            reason: Strings.accessibilityReason,
            state: state(granted: accessibilityGranted),
            actionTitle: accessibilityRequested ? Strings.openSettings : Strings.allow
        ) {
            if accessibilityRequested {
                PermissionIssue.accessibility.openSystemSettings()
            } else {
                accessibilityRequested = true
                _ = TextInjector.requestAccessibilityPermission()
            }
        }
    }

    private func state(granted: Bool) -> PermissionRow.State {
        if granted { return .granted }
        return hasChecked ? .needed : .checking
    }

    // MARK: - Strings

    private enum Strings {
        static let eyebrow = String(localized: "Permissions", comment: "Onboarding, permissions step")
        static let title = String(localized: "Allow microphone and Accessibility", comment: "Onboarding, permissions step")
        static let subtitle: String? = nil
        static let micTitle = String(localized: "Microphone", comment: "Onboarding, permissions step")
        static let micReason = String(localized: "Record your dictation.", comment: "Onboarding, permissions step")
        static let accessibilityTitle = String(localized: "Accessibility", comment: "Onboarding, permissions step")
        static let accessibilityReason = String(localized: "Use shortcuts and insert text into selected fields in other apps.", comment: "Onboarding, permissions step")
        static let accessibilityLater = String(localized: "You can allow Accessibility later. Until then, the shortcut won't work and Dictari will copy text instead.",
                                               comment: "Onboarding, permissions step")
        static let allow = String(localized: "Allow", comment: "Onboarding, permissions step")
        static let openSettings = String(localized: "Open Settings", comment: "Onboarding, permissions step")
        static let action = String(localized: "Continue", comment: "Onboarding, permissions step")
    }
}

// MARK: - Row

private struct PermissionRow: View {
    enum State { case checking, needed, granted }

    let icon: String
    let title: String
    let reason: String
    let state: State
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(Mono.primaryText)
                .frame(width: 20, height: 20)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Typo.cardTitle)
                    .foregroundStyle(Mono.primaryText)
                Text(reason)
                    .font(Typo.secondary)
                    .foregroundStyle(Mono.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            trailing
                .frame(minWidth: 96, alignment: .trailing)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var trailing: some View {
        switch state {
        case .checking:
            Text(Strings.checking)
                .font(Typo.secondary)
                .foregroundStyle(Mono.tertiaryText)
                .transition(.opacity)
        case .needed:
            OnboardingButton(title: actionTitle, kind: .secondary, action: action)
                .transition(.opacity)
        case .granted:
            HStack(spacing: 5) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                Text(Strings.granted)
                    .font(Typo.secondary)
            }
            .foregroundStyle(Mono.primaryText)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
    }

    private enum Strings {
        static let checking = String(localized: "Checking…", comment: "Onboarding, permissions step")
        static let granted = String(localized: "Granted", comment: "Onboarding, permissions step")
    }
}
