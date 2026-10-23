// Permissions.swift
// Dictari — the two system permissions dictation cannot work without, and the ability
// to say so out loud.
//
// Both were previously handled by failing quietly: the hotkey silently retried forever when
// Accessibility was missing, and a denied microphone only showed up as a dictation that
// produced nothing. From the user's side the app simply did nothing when they pressed the
// shortcut, with no way to tell what was wrong.

import AVFoundation
import AppKit

/// A permission the app needs but does not have.
enum PermissionIssue: String, Identifiable, Sendable, CaseIterable {
    /// No global hotkey and no text injection: the app is inert.
    case accessibility
    /// Nothing to transcribe.
    case microphone

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accessibility:
            return String(localized: "Accessibility access needed", comment: "Permission status: Accessibility is not granted")
        case .microphone:
            return String(localized: "Microphone access needed", comment: "Permission status: Microphone is not granted")
        }
    }

    /// What the user loses, in their terms — not the API's.
    var detail: String {
        switch self {
        case .accessibility:
            return String(localized: "Without it the keyboard shortcut does nothing and dictated text cannot be inserted into other apps.",
                          comment: "Why Accessibility permission is needed")
        case .microphone:
            return String(localized: "Without it Dictari cannot hear you.", comment: "Why Microphone permission is needed")
        }
    }

    /// Deep link to the exact pane, so the fix is one click rather than a hunt.
    var settingsURL: URL? {
        switch self {
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        case .microphone:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        }
    }

    func openSystemSettings() {
        if let settingsURL { NSWorkspace.shared.open(settingsURL) }
    }
}

/// Snapshot of what the app is currently allowed to do.
struct PermissionStatus: Equatable, Sendable {
    var accessibility = false
    var microphone = false

    /// Everything missing, in the order it blocks the user.
    var issues: [PermissionIssue] {
        var out: [PermissionIssue] = []
        if !accessibility { out.append(.accessibility) }
        if !microphone { out.append(.microphone) }
        return out
    }

    var isReady: Bool { issues.isEmpty }

    /// Read the live system state. Cheap enough to call on every window activation.
    static func current() -> PermissionStatus {
        let accessibilityReady = AXIsProcessTrusted()
        return PermissionStatus(
            accessibility: accessibilityReady,
            // `.notDetermined` counts as missing: the app cannot record until it is asked,
            // and the prompt only appears on the first capture attempt.
            microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        )
    }
}
