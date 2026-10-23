// DictariApp.swift
// Dictari — app entry. Menu-bar (accessory) app: no Dock icon, no main window.
// The AppDelegate owns the coordinator and lazily presents the settings window.

import AppKit
import SwiftUI

@main
struct DictariApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // No primary window: the app lives in the menu bar. This empty Settings
        // scene only satisfies the `App` protocol; the real settings window is an
        // AppKit window managed by the AppDelegate.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let coordinator = AppCoordinator()
    private var settingsWindow: NSWindow?
    private let workspaceNotificationCenter = NSWorkspace.shared.notificationCenter

    deinit {
        workspaceNotificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }
    /// Held for the lifetime of the app: both own an NSWindow that must outlive the call
    /// that presented it.
    private var onboarding: OnboardingController?
    private var isFlushingForTermination = false
    #if DEBUG
    private var settingsPerfProbe: SettingsPerfProbe?
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()
        applyAppearance()
        workspaceNotificationCenter.addObserver(self, selector: #selector(workspaceApplicationActivated),
                                                name: NSWorkspace.didActivateApplicationNotification, object: nil)

        coordinator.presentSettings = { [weak self] in self?.showSettings() }
        coordinator.applyAppearance = { [weak self] in self?.applyAppearance() }

        // Under XCTest the app is only loaded to host the test bundle. Starting services
        // would install a system-wide event tap, open the microphone and download a model —
        // side effects a test run must never have.
        guard !Self.isRunningTests else { return }

        // Self-test is a development harness: it replaces normal startup and exits.
        if SelfTest.isRequested {
            Task { try? await SelfTest.run(coordinator: coordinator) }
            return
        }
        #if DEBUG
        // Settings smoothness/snapshot harness: starts no services, measures or renders, exits.
        if SettingsPerfProbe.isRequested {
            let probe = SettingsPerfProbe(coordinator: coordinator)
            settingsPerfProbe = probe
            probe.run()
            return
        }
        #endif

        // Past the harness gates the coordinator may open the local MCP listener — and only does
        // while the AI-agent switches grant access, so a default install opens no socket.
        coordinator.permitLocalMCPServer()

        #if DEBUG
        if ProcessInfo.processInfo.environment["DICTARI_WRITING_UI_PREVIEW"] != nil {
            coordinator.previewWritingPill()
            if let section = ProcessInfo.processInfo.environment["DICTARI_OPEN_SETTINGS"] {
                showSettings(section: SettingsSection(launchValue: section) ?? .home)
            }
            return
        }
        #endif
        Task { [coordinator] in
            await coordinator.startServices()
        }

        // First run: explain the app, walk through the permissions, download a model and land
        // on a first successful dictation.
        if !OnboardingController.hasCompleted { showOnboarding() }

        // Development affordance: the app has no Dock icon and no window, so there is no
        // way to reach settings except the menu-bar icon.
        //   DICTARI_OPEN_SETTINGS=1 open -a Dictari
        if let section = ProcessInfo.processInfo.environment["DICTARI_OPEN_SETTINGS"] {
            showSettings(section: SettingsSection(launchValue: section) ?? .home)
        }
    }

    /// True when the process was launched by XCTest.
    static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil
    }

    /// Give the app a minimal main menu.
    ///
    /// An `.accessory` app has no menu bar of its own, so there was nowhere for macOS to route
    /// ⌘, — the settings window could only be reached by clicking through the popover. Less
    /// obviously, there was no Edit menu either, which is what actually carries ⌘C / ⌘V / ⌘A:
    /// the history search field silently ignored them.
    ///
    /// The menu is only visible while Dictari is the active application, which for a menu-bar
    /// app means while one of its windows is frontmost. ⌘, cannot work from inside another
    /// app — that shortcut belongs to whatever is in front.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: String(localized: "Settings…", comment: "Menu item: open the settings window"), action: #selector(openSettingsFromMenu),
                        keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Quit Dictari", comment: "Menu item"),
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: String(localized: "Edit", comment: "Main menu title"))
        editMenu.addItem(withTitle: String(localized: "Undo", comment: "Main menu item"), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: String(localized: "Redo", comment: "Main menu item"), action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: String(localized: "Cut", comment: "Main menu item"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: String(localized: "Copy", comment: "Edit menu item: copy the selection"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: String(localized: "Paste", comment: "Edit menu item: paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: String(localized: "Select All", comment: "Main menu item"), action: #selector(NSText.selectAll(_:)),
                         keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func openSettingsFromMenu() {
        showSettings()
    }

    private func showOnboarding() {
        let controller = OnboardingController(coordinator: coordinator)
        controller.onFinish = { [weak self] in
            self?.onboarding = nil
            // Whatever the user granted during onboarding, act on it now rather than at the
            // next launch: the hotkey should work the moment the window closes.
            self?.coordinator.refreshPermissions()
            // Then show where the app went. Closing the last window of a menu-bar app looks
            // exactly like quitting it, and a first-run flow that ends in apparent nothing
            // is how an install becomes an uninstall.
            self?.coordinator.revealInMenuBar()
        }
        onboarding = controller
        controller.present()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isFlushingForTermination else { return .terminateLater }
        isFlushingForTermination = true
        // Stop intercepting keyboard events before the async flush. Waiting until process
        // destruction made a slow/failed save look like Dictari had quit while its tap remained.
        coordinator.beginTermination()
        Task { [coordinator] in
            // Transcribe and record an in-flight dictation before the history flush below.
            await coordinator.finishDictationForTermination()
            do {
                try await flushUserDataUntilStable(
                    settings: coordinator.settings,
                    history: coordinator.history
                )
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                isFlushingForTermination = false
                coordinator.cancelTermination()
                let alert = NSAlert()
                alert.alertStyle = .critical
                alert.messageText = String(localized: "Dictari couldn't save changes", comment: "Alert title when quitting fails to save")
                alert.informativeText = String(localized: "Settings or history weren't saved. Check disk space and folder permissions, then try again.\n\n\(error.localizedDescription)",
                                               comment: "Alert message; the argument is the system error")
                alert.addButton(withTitle: String(localized: "Keep Dictari Open", comment: "Alert button"))
                alert.runModal()
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }

    private func applyAppearance() {
        switch coordinator.settings.data.appearance {
        case .system: NSApp.appearance = nil
        case .light:  NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:   NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// `NSApp.isActive` is this process's own activation state and flips before the
    /// did-become/did-resign callbacks. `NSWorkspace.frontmostApplication` is updated
    /// asynchronously and lagged behind both, which left Settings misclassified right after
    /// an explicit open (and, via the level policy below, parked below normal while in use).
    private func updatePillPresentation() {
        let foreground = NSApp.isActive && settingsWindow?.isVisible == true
            && settingsWindow?.isMiniaturized == false
        coordinator.setSettingsForeground(foreground)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        setSettingsWindowLevel(backgrounded: false)
        updatePillPresentation()
    }
    func applicationDidResignActive(_ notification: Notification) {
        coordinator.setSettingsForeground(false)
        setSettingsWindowLevel(backgrounded: true)
    }

    @objc private func workspaceApplicationActivated(_ notification: Notification) {
        updatePillPresentation()
    }

    /// Accessory windows can remain ahead of the newly active application's windows even
    /// at the normal level. Give background Settings a level below normal rather than race
    /// AppKit's application-group ordering with orderBack. It stays visible and clickable;
    /// activation restores the normal level. The status-level pill is independent.
    ///
    /// Driven only by this app's own resign/become-active callbacks and by an explicit open.
    /// It used to be recomputed from `NSWorkspace.frontmostApplication` on every update; that
    /// value lags activation, so opening Settings immediately re-lowered it to normal-1 and
    /// the window sat inactive under other windows — popups then spent their click activating.
    private func setSettingsWindowLevel(backgrounded: Bool) {
        guard let window = settingsWindow else { return }
        let level: NSWindow.Level = backgrounded
            ? NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1) : .normal
        if window.level != level { window.level = level }
    }

    func windowDidBecomeKey(_ notification: Notification) { updatePillPresentation() }
    func windowDidMiniaturize(_ notification: Notification) { updatePillPresentation() }
    func windowDidDeminiaturize(_ notification: Notification) { updatePillPresentation() }
    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === settingsWindow else { return }
        coordinator.setSettingsForeground(false)
    }

    private func showSettings(section: SettingsSection = .home) {
        if let window = settingsWindow {
            presentSettingsWindow(window)
            return
        }
        // No fixed frame on the root: the window is resizable, so the content follows it.
        let root = SettingsRootView(initialSection: section)
            .environment(coordinator)

        let hosting = NSHostingController(rootView: root)
        // User-resized Settings geometry must not follow a History section's intrinsic height.
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.title = "Dictari"
        // Settings is the app's independent primary window. The pill alone can join other
        // applications. Background Settings has its own explicit level policy, independent
        // from the overlay and AppKit application-group ordering.
        window.level = .normal
        window.collectionBehavior = [.managed, .primary]
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        // Unified top: let the window content (sidebar / detail background) show through the
        // title bar, like Apple apps — instead of an opaque white title bar.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // The transparent title bar reveals the window background — match it to the content
        // grey (adaptive light/dark) so the whole top is one uniform colour like Apple apps.
        window.backgroundColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.96, alpha: 1)
        }
        window.setContentSize(Metrics.settingsWindow)
        window.center()
        window.isReleasedWhenClosed = false
        // A floor that keeps the sidebar and one column of content legible, not the opening
        // size — pinning minSize to the default size is what made the window unresizable.
        window.minSize = Metrics.settingsWindowMinimum
        window.setFrameAutosaveName("SettingsWindow")
        settingsWindow = window
        window.delegate = self
        presentSettingsWindow(window)
    }

    /// Called only by an explicit Settings request. Activation/Space notifications update
    /// pill visibility above; they never call this or bring the Settings window forward.
    private func presentSettingsWindow(_ window: NSWindow) {
        // Apply on reuse too: this window remains independent from the status-level NSPanel.
        window.level = .normal
        window.collectionBehavior = [.managed, .primary]
        // The user asked for this window, so activate unconditionally. The old
        // `activate(ignoringOtherApps: false)` is a polite request macOS 14+ may decline,
        // leaving Settings frontmost-looking but inactive: the first click on any popup
        // only activated the app and never opened the menu.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        updatePillPresentation()
    }
}
