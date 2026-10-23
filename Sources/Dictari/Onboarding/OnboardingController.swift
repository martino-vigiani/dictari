// OnboardingController.swift
// Dictari — the AppKit host for the first-run flow.
//
// Same pattern as the settings window: a plain NSWindow owned by an object the AppDelegate
// keeps alive, hosting a SwiftUI tree that reads the coordinator from the environment. The
// window is fixed-size and chromeless-looking (transparent title bar, no title, no zoom) so
// the flow reads as one designed object rather than as a document window.

import AppKit
import SwiftUI

@MainActor
final class OnboardingController: NSObject, NSWindowDelegate {

    /// Set by the AppDelegate; called when the user completes or leaves the flow.
    var onFinish: (() -> Void)?

    private let coordinator: AppCoordinator
    private var window: NSWindow?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        super.init()
    }

    // MARK: - Completion flag

    /// Versioned on purpose: a materially different onboarding can be shown again to existing
    /// users by bumping the key, without a migration.
    private static let completedKey = "Dictari.onboarding.completed.v1"

    /// True once the user has been through (or dismissed) the first-run flow.
    static var hasCompleted: Bool {
        UserDefaults.standard.bool(forKey: completedKey)
    }

    /// Record that the flow is done. Called when the window closes for any reason — a user who
    /// dismissed onboarding deliberately should not be handed it again at every launch.
    static func markCompleted() {
        UserDefaults.standard.set(true, forKey: completedKey)
    }

    /// Development aid: show the flow again on next launch.
    static func resetCompletion() {
        UserDefaults.standard.removeObject(forKey: completedKey)
    }

    // MARK: - Presentation

    func present() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let root = OnboardingView(onFinish: { [weak self] in self?.finish() })
            .environment(coordinator)

        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = String(localized: "Welcome to Dictari", comment: "Onboarding window title")
        // Nothing here resizes: the layout is composed for one size.
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        // The transparent title bar shows the window's own background — match it to the
        // content so the top edge is uniform instead of an opaque strip.
        window.backgroundColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.96, alpha: 1)
        }
        window.isMovableByWindowBackground = true
        window.setContentSize(OnboardingLayout.window)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Reached the end of the flow (or chose to leave it).
    private func finish() {
        Self.markCompleted()
        window?.close()          // windowWillClose delivers `onFinish`
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        Self.markCompleted()
        onFinish?()
    }
}
