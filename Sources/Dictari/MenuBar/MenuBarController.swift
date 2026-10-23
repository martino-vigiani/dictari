// MenuBarController.swift
// Dictari — a system-managed NSStatusItem menu, with no custom presentation window.
// Observation: uses withObservationTracking to react to coordinator.state
// without a timer or polling loop. Idle cost is effectively zero.

import AppKit
import Observation

// MARK: - Controller

@MainActor
final class MenuBarController {

    // MARK: Dependencies

    private let coordinator: AppCoordinator

    // MARK: AppKit objects

    private var statusItem: NSStatusItem?
    private lazy var content = MenuBarMenu(presentation: menuPresentation)

    /// Drives the slow breathing cue while the model loads. Only alive during `.loading` —
    /// created on entry, invalidated the moment the state changes, so idle cost stays zero.
    private var breatheTimer: Timer?
    private var breatheDim = false

    // MARK: Init

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    // MARK: - Public API

    /// Create the status bar item and register the observation loop.
    /// Call once from `AppCoordinator.startServices()`.
    func install() {
        guard statusItem == nil else { return }
        content.onAction = { [weak self] action in self?.perform(action) }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Assigning the menu lets AppKit own material, tracking, keyboard navigation,
        // positioning and dismissal. No custom window, backdrop or event monitors.
        item.menu = content.menu
        item.button?.setAccessibilityLabel("Dictari")
        statusItem = item
        applyState()
    }

    /// Onboarding uses the same native status-item action as a user click.
    func revealMenu() {
        statusItem?.button?.performClick(nil)
    }

    // MARK: - Observation loop (timer-free)

    /// Registers one round of withObservationTracking; re-registers after each change.
    /// The closure is always delivered on the @MainActor because both the coordinator
    /// and this class are @MainActor-isolated.
    private func observeState() {
        withObservationTracking {
            // Access every property the icon depends on so any of them re-triggers this.
            _ = coordinator.state
            _ = coordinator.modelState
            _ = coordinator.permissions
            _ = coordinator.hotkeyArmed
            _ = coordinator.settings.data
            _ = coordinator.lastTranscript
            _ = coordinator.history.entries
            _ = coordinator.mediaLibrary.isBusy
            _ = coordinator.updater.isConfigured
            _ = coordinator.updater.canCheckForUpdates
        } onChange: { [weak self] in
            // onChange fires on an unspecified thread — hop to main before touching UI.
            Task { @MainActor [weak self] in
                self?.applyState()
            }
        }
    }

    private func applyState() {
        updateBreatheTimer()
        render()
        content.update(menuPresentation)
        // Re-register for the next change.
        observeState()
    }

    private func render() {
        let image = stateImage(for: currentIconState)
        image?.isTemplate = true
        statusItem?.button?.image = image
        statusItem?.button?.toolTip = String(localized: "Dictari — \(feedbackPresentation.statusLabel)",
                                              comment: "Menu bar icon tooltip; the argument is the current status")
    }

    // MARK: - Icon mapping (strict B&W; isTemplate handled above)

    /// What the icon should actually show, collapsing four independent signals
    /// (dictation state, model state, permissions, hotkey) into one glyph.
    /// Order matters: an in-flight or just-finished dictation is the user's immediate truth;
    /// background loading and permission attention are consulted only while idle.
    private enum IconState {
        case loading
        case attention          // failed model, missing permission, or hotkey not armed
        case listening
        case transcribing
        case success
        case error
        case ready
    }

    private var feedbackPresentation: AppFeedbackPresentation {
        AppFeedbackPresentation.resolve(
            dictation: coordinator.state,
            model: coordinator.modelState,
            attentionReason: attentionReason
        )
    }

    private var attentionReason: String? {
        AppAttentionReason.resolve(
            model: coordinator.modelState,
            hasAccessibility: coordinator.permissions.accessibility,
            hasMicrophone: coordinator.permissions.microphone,
            hotkeyArmed: coordinator.hotkeyArmed
        )
    }

    private var currentIconState: IconState {
        switch feedbackPresentation {
        case .loading: return .loading
        case .attention: return .attention
        case .listening: return .listening
        case .transcribing: return .transcribing
        case .success: return .success
        case .error: return .error
        case .ready, .cancelled: return .ready
        }
    }

    private func stateImage(for icon: IconState) -> NSImage? {
        switch icon {
        case .loading:
            // Slow breathing dim/bright cue — the only long-running animation in the icon,
            // and it stops the instant the model finishes (see `updateBreatheTimer`).
            return dimmedWaveform(fraction: breatheDim ? 0.20 : 0.55, description: String(localized: "Loading model", comment: "Menu bar icon accessibility description"))
        case .attention:
            // Same glyph family as every other state, struck through. A yellow-alert
            // triangle is the system's vocabulary for "something broke"; here nothing is
            // broken — dictation is simply switched off until a grant arrives.
            return NSImage(systemSymbolName: "waveform.slash",
                           accessibilityDescription: String(localized: "Needs attention", comment: "Menu bar icon accessibility description"))
        case .listening:
            return NSImage(systemSymbolName: "waveform", accessibilityDescription: String(localized: "Listening", comment: "Menu bar icon accessibility description"))
        case .transcribing:
            return NSImage(systemSymbolName: "ellipsis", accessibilityDescription: String(localized: "Transcribing", comment: "Menu bar icon accessibility description"))
        case .success:
            return NSImage(systemSymbolName: "checkmark", accessibilityDescription: String(localized: "Dictation complete", comment: "Menu bar icon accessibility description"))
        case .error:
            return NSImage(systemSymbolName: "waveform.slash", accessibilityDescription: String(localized: "Dictation failed", comment: "Menu bar icon accessibility description"))
        case .ready:
            // Full-strength template tint stays legible: white on a dark menu bar,
            // black on a light one. Ready must not look disabled.
            return NSImage(systemSymbolName: "waveform", accessibilityDescription: String(localized: "Ready", comment: "Menu bar status: ready to dictate"))
        }
    }

    /// Returns "waveform" at reduced alpha. We achieve "dimmed" via NSImage configuration
    /// rather than color: template images respect the button's `appearsDisabled`; a simple
    /// opacity tweak keeps it monochrome.
    private func dimmedWaveform(fraction: CGFloat, description: String) -> NSImage? {
        guard let base = NSImage(systemSymbolName: "waveform", accessibilityDescription: description) else { return nil }
        let size = base.size
        let dimmed = NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect, from: .zero, operation: .sourceOver, fraction: fraction)
            return true
        }
        dimmed.isTemplate = base.isTemplate
        return dimmed
    }

    /// Starts or stops the breathing timer to match whether we're currently showing
    /// `.loading`. A first-run model download can take minutes; without *some* motion
    /// the icon looks frozen and indistinguishable from a hang. The cycle is slow
    /// (1.6s per half-beat) and bounded to this one state — it is never left running.
    private func updateBreatheTimer() {
        let isLoading = { if case .loading = feedbackPresentation { return true } else { return false } }()
        guard isLoading else {
            breatheTimer?.invalidate()
            breatheTimer = nil
            return
        }
        guard breatheTimer == nil else { return }
        breatheDim = false
        breatheTimer = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.breatheDim.toggle()
                self.render()
            }
        }
    }

    // MARK: - Native menu snapshot and action routing

    private var menuPresentation: MenuBarPresentation {
        let app = coordinator
        let action = PrimaryDictationAction.resolve(for: app.state)
        let profiles = DictationProfile.allCases.map {
            MenuBarPresentation.ProfileInput(id: $0.rawValue, name: $0.label)
        } + (app.settings.data.customDictationProfiles ?? []).map {
            MenuBarPresentation.ProfileInput(id: $0.id, name: $0.name)
        }
        return MenuBarPresentation.resolve(.init(
            dictationState: app.state,
            feedback: feedbackPresentation,
            isMediaBusy: app.mediaLibrary.isBusy,
            shortcut: action == .start ? app.settings.data.dictationShortcut.displayString : nil,
            profiles: profiles,
            builtInProfileCount: DictationProfile.allCases.count,
            activeProfileID: app.settings.data.activeDictationProfileID,
            activeProfileName: app.settings.data.activeDictationProfileName,
            transcript: latestTranscript,
            updatesVisible: app.updater.isConfigured && app.updater.isEnabled,
            updatesEnabled: app.updater.canCheckForUpdates
        ))
    }

    private var latestTranscript: String {
        if coordinator.lastTranscript.contains(where: { !$0.isWhitespace }) { return coordinator.lastTranscript }
        return coordinator.history.entries.first {
            !$0.isFailure && $0.text.contains(where: { !$0.isWhitespace })
        }?.displayText ?? ""
    }

    private func perform(_ action: MenuBarMenu.Action) {
        switch action {
        case .dictation:
            guard !coordinator.mediaLibrary.isBusy else { return }
            // Re-resolve at activation: a hotkey can change state while the menu is open.
            switch PrimaryDictationAction.resolve(for: coordinator.state) {
            case .start: coordinator.startDictation()
            case .stop: coordinator.stopDictation()
            case .cancel: coordinator.cancelDictation()
            }
        case .profile(let id):
            guard DictationProfile.allCases.contains(where: { $0.rawValue == id })
                    || (coordinator.settings.data.customDictationProfiles ?? []).contains(where: { $0.id == id })
            else { return }
            coordinator.settings.data.selectedDictationProfile = id
        case .copy(let text):
            guard !text.isEmpty else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        case .settings: coordinator.openSettings()
        case .updates: coordinator.updater.checkForUpdates()
        case .quit: coordinator.quit()
        }
    }
}
