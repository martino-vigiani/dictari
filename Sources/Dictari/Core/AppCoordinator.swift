// AppCoordinator.swift
// Dictari — the brain. Owns every component and orchestrates the dictation
// lifecycle: hotkey → pill → capture → transcribe → inject → history/stats.
// This is the integration hub; leaf components implement the exact APIs called here.

import Accelerate
import AppKit
import Observation
import os
import SwiftUI
import ScreenCaptureKit

@MainActor
@Observable
final class AppCoordinator {

    // MARK: Observable UI state
    private(set) var state: DictationState = .idle
    /// Rolling normalized waveform levels (0...1). Deliberately not an observed property —
    /// see LevelBuffer for why fifty invalidations a second were pure waste.
    @ObservationIgnored let levels = LevelBuffer()
    private(set) var modelState: ModelState = .idle
    /// Live permission snapshot. Drives the warning banner and the menu-bar icon, so a
    /// missing permission is visible instead of the app silently doing nothing.
    private(set) var permissions = PermissionStatus.current()
    /// True once the global hotkey is actually armed.
    private(set) var hotkeyArmed = false
    /// Registration failures are actionable configuration errors, not permission failures.
    private(set) var hotkeyIssue: String?
    /// Loudness of the most recent dictation, shown in Settings so the proximity filter can
    /// be tuned against a real measurement rather than guessed.
    private(set) var lastSpeechLevel: Float = 0
    /// Bearer token AI-agent clients must send. Nil until access is first enabled: the token file
    /// is only created once the user actually opts in.
    private(set) var localMCPToken: String?
    /// True while the loopback MCP listener is meant to be up. Settings shows it so an agent that
    /// cannot connect has an explanation.
    private(set) var localMCPListening = false

    // MARK: Stores
    let mediaLibrary = MediaLibrary()
    let textRefinement = TextRefinement(refiner: AppleTextRefiner())
    let pillRefinement = TextRefinement(refiner: AppCoordinator.makePillRefiner())
    private(set) var isRevising = false
    private(set) var pillWritingVisible = false
    private(set) var pillWritingExpanded = false
    private(set) var pillWritingAction: WritingAction = .correct
    private(set) var pillWritingStatus = ""

    private static func makePillRefiner() -> any TextRefiner {
        #if DEBUG
        if ProcessInfo.processInfo.environment["DICTARI_WRITING_UI_PREVIEW"] != nil { return WritingPreviewRefiner() }
        #endif
        return AppleTextRefiner()
    }

    #if DEBUG
    /// Explicit UI harness: no capture, input injection, clipboard write or generation.
    func previewWritingPill() {
        if ProcessInfo.processInfo.environment["DICTARI_WRITING_UI_PREVIEW"] == "listening" {
            setState(.listening)
            pill.show()
            return
        }
        if ProcessInfo.processInfo.environment["DICTARI_WRITING_UI_PREVIEW"] == "processing" {
            isRevising = true
            setState(.transcribing)
            pillWritingVisible = false
            pillWritingExpanded = false
            pill.show()
            return
        }
        lastTranscript = "Ciao, possiamo spostare la riunione a domani alle 10?"
        setState(.success(.inserted))
        pillWritingStatus = Self.writingStatusInserted
        pillWritingAction = .correct
        pillWritingVisible = true
        pillWritingExpanded = false
        pill.show()
        if ProcessInfo.processInfo.environment["DICTARI_WRITING_UI_PREVIEW"] == "motion" {
            // Bounded presentation replay, with the preview refiner: no audio or input events.
            Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .seconds(1))
                self.beginPillRevision(.correct)
                try? await Task.sleep(for: .seconds(1.5))
                self.dismissPillWriting()
                try? await Task.sleep(for: .seconds(1))
                self.togglePillMenu()
                try? await Task.sleep(for: .seconds(1))
                self.collapsePillMenu()
                try? await Task.sleep(for: .seconds(1))
                self.setState(.success(.inserted))
                self.pillWritingVisible = true
                self.pillWritingExpanded = false
                self.pill.show()
            }
        }
    }
    #endif

    private static var writingStatusInserted: String {
        String(localized: "Inserted · Apple Intelligence",
               comment: "Pill writing card status; keep the brand name Apple Intelligence")
    }

    func openPillWriting() {
        guard state == .success(.copiedToClipboard), !lastTranscript.isEmpty else { return }
        pillRefinement.clear()
        pillRefinement.refreshAvailability()
        pillWritingStatus = String(localized: "Copied · Apple Intelligence", comment: "Pill writing card status; keep the brand name Apple Intelligence")
        pillWritingVisible = true
        pillWritingExpanded = true
        hideTask?.cancel()
    }

    func beginPillRevision(_ action: WritingAction) {
        guard pillWritingVisible, !state.isActive, !pillRefinement.isBusy, !textRefinement.isBusy else { return }
        pillWritingExpanded = true
        pillWritingAction = action
        hideTask?.cancel()
        pillRefinement.start(lastTranscript, action: action)
    }

    func copyPillRevision() {
        guard pillWritingVisible, let result = pillRefinement.result, !pillRefinement.isBusy else { return }
        guard writeClipboard(result) else {
            pillWritingStatus = String(localized: "Copy failed", comment: "Pill writing card status")
            return
        }
    }

    func dismissPillWriting() {
        // Retain the visible preview until the shell has contracted or finished leaving.
        // Clearing it here replaced the card with a success badge for one frame on Close.
        pillRefinement.cancel()
        scheduleHide(after: 0)
    }

    private func offerPillWriting(_ rule: AppWritingRule?, recordedApp: String?, kind: DictationState.SuccessKind) {
        guard let rule, rule.mode == .ask,
              rule.shouldOffer(after: kind, recordedApp: recordedApp,
                               currentApp: NSWorkspace.shared.frontmostApplication?.bundleIdentifier) else { return }
        pillRefinement.clear()
        pillRefinement.refreshAvailability()
        pillWritingAction = rule.writingAction
        pillWritingStatus = kind == .inserted
            ? Self.writingStatusInserted
            : String(localized: "Paste requested · Apple Intelligence",
                     comment: "Pill writing card status; keep the brand name Apple Intelligence")
        pillWritingVisible = true
        pillWritingExpanded = false
        scheduleHide(after: 15)
    }

    func improveText(_ text: String, action: WritingAction) {
        guard !state.isActive, !mediaLibrary.isBusy, !pillRefinement.isBusy else { return }
        textRefinement.start(text, action: action)
    }
    let settings: SettingsStore
    let history: HistoryStore
    /// Apple crash, hang and performance payloads. The archive is local-only and bounded; the
    /// only export path is an explicit Save action in Settings.
    let diagnostics: LocalDiagnosticsStore
    /// Durable captures retained while transcription/delivery needs attention. Confirmed normal
    /// delivery removes PCM; file I/O stays off-main and this array contains metadata only.
    private(set) var recoveries: [DictationRecovery] = []
    private(set) var recoveryLoadWarning: String?
    private(set) var retryingRecoveryID: UUID?
    /// Invalidates asynchronous filesystem snapshots when a newer refresh wins. Keep this
    /// separate from the UI revision: starting a read does not change visible content, while
    /// finishing one must invalidate History even when the request began before the view opened.
    private var recoveryLoadGeneration: UInt = 0
    /// Advances only when the in-memory recovery snapshot changes.
    private var recoveriesRevision: UInt = 0
    /// Lets the virtualized History table reload when recovery metadata changes without comparing
    /// or retaining a second copy of every row.
    var recoveryContentRevision: UInt { recoveriesRevision }
    /// Names, jargon and product names the model reliably gets wrong. Applied to every
    /// transcript before it is shown, inserted or recorded.
    let vocabulary: VocabularyStore
    /// Sparkle. Owned here so a settings row can reach it like any other component.
    let updater: UpdaterController

    // MARK: Components
    private let audio = AudioCaptureEngine()
    private let cues = SoundCues()
    private let injector = TextInjector()
    /// Posts live-typing edits. Mechanical; every decision is in the Live typing section below.
    private let liveTyper = LiveTyper()
    private let hotkey = HotkeyManager()
    @ObservationIgnored private let metricKitMonitor: MetricKitMonitor
    private var transcriber: any TranscriptionEngine
    @ObservationIgnored private lazy var pill = PillController(coordinator: self)
    @ObservationIgnored private lazy var menuBar = MenuBarController(coordinator: self)

    /// Set by the AppDelegate to present the settings window.
    var presentSettings: (() -> Void)?
    /// Set by the AppDelegate to apply the Appearance preference to `NSApp` live.
    var applyAppearance: (() -> Void)?

    /// Last successful transcript — shown in the pill when `showTranscriptPreview` is on.
    private(set) var lastTranscript = ""
    /// Unsure words of `lastTranscript` for the copied pill. Keyed by the text they index, so a
    /// stale value is ignored rather than painted onto a different transcript.
    private(set) var lastTranscriptUncertainty: UncertainTranscript?
    /// True when the idle pill is expanded into its Dynamic-Island menu (Play / Quit).
    private(set) var pillExpanded = false
    /// Independent expansion state for a long clipboard-fallback transcript. Keeping this
    /// separate prevents a result interaction from participating in the idle menu lifecycle.
    private(set) var transcriptExpanded = false
    /// Drives the pill's own enter/exit animation. The window fade alone left the content
    /// cutting out abruptly underneath it — the black bar of an error state, or the transcript
    /// box, simply vanished. PillController flips this and orders the window out only once the
    /// content has finished animating away.
    private(set) var pillVisible = false
    /// Per-model preparation state for Settings and onboarding. Candidate work is separate
    /// from `modelState`, so a failed switch never makes the working active model unavailable.
    private(set) var modelDownloadState: ModelDownloadState = .idle
    /// True from the start of a conversation until its last segment has been delivered.
    private(set) var conversationActive = false
    /// A conversation's words that could not be pasted, in speaking order. It fills the
    /// listening pill's transcript card and is exactly what that card's Copy button copies.
    private(set) var conversationCopiedTranscript = ""
    /// How the listening pill is drawn during a conversation (see `ConversationPolicy`).
    var conversationPillLayout: ConversationPillLayout {
        ConversationPolicy.pillLayout(state: state, conversationActive: conversationActive,
                                      copiedTranscript: conversationCopiedTranscript)
    }

    // MARK: Session bookkeeping
    private var sessionApp: (name: String?, bundleID: String?, processIdentifier: pid_t?) = (nil, nil, nil)
    /// The transcription configuration belongs to the audio already being captured. Settings
    /// changes build the next engine, but must not turn a valid recording into "model loading".
    private struct RecordingTranscriptionContext {
        let engine: any TranscriptionEngine
        var applicationBundleID: String? = nil
        var writingRule: AppWritingRule? = nil
        var revisionAction: WritingAction? = nil
        var correctionShortcut = false
        var preferences: DictationPreferences
        var language: String { preferences.language }
        let modelID: String
        let modelWasReadyAtStart: Bool
        let autoPasteIntoFocus: Bool
        /// Chosen before capture starts and immutable for the lifetime of this recording.
        let transcriptionMode: RecordingTranscriptionMode
    }
    private var recordingContext: RecordingTranscriptionContext?
    private var sessionStart = ContinuousClock.now
    /// One Conversation mode session: capture stays open across pauses; each pause hands its
    /// segment to `chain`, which delivers segments strictly in speaking order.
    private struct ConversationSession {
        let id = UUID()
        let chain = OrderedSegmentChain()
        var nextSegmentIndex = 0
        /// Start of the segment being captured now (the previous cut, or the session start).
        var segmentStart: ContinuousClock.Instant
        var outcome = ConversationOutcome()
        /// Set once a timeout/readiness failure retired the engine: later segments fail fast.
        var engineRetired = false
    }
    @ObservationIgnored private var conversation: ConversationSession?
    private var hideTask: Task<Void, Never>?
    /// True while the pointer rests on the copied pill and has cancelled its auto-hide.
    @ObservationIgnored private var copiedPillHoverPaused = false
    /// Invalidates a delayed terminal-state hide whenever a newer lifecycle state wins. Task
    /// cancellation is still used to avoid work; this generation check is the correctness guard.
    private var scheduledTransitionGate = ScheduledTransitionGate()
    private var transcriptionTask: Task<Void, Never>?
    @ObservationIgnored private var activeStageTiming: DictationStageTiming?
    private struct ActiveInference {
        let engine: any TranscriptionEngine
        let generation: UInt
    }
    private struct ActiveStreamingSession {
        let previewGeneration: UInt
        let stream: any TranscriptionStream
    }
    /// A deadline can return before a backend stops. Never hand that engine another utterance:
    /// its orphaned inference may still own mutable decoder state.
    private var activeInference: ActiveInference?
    private var nextInferenceGeneration: UInt = 0
    private var finalizedInferenceGeneration: UInt = 0
    /// At most one native inference may outlive its deadline. Until it actually returns, no new
    /// engine work starts; this bounds retained model + PCM memory instead of accumulating orphans.
    private var quarantinedInferenceGeneration: UInt?
    /// Rebuilding an engine after quarantine is separate from a user-requested model preparation,
    /// but the two must never warm concurrently. Its completion is a model-lifecycle edge.
    @ObservationIgnored private var quarantineRebuildTask: Task<Void, Never>?
    private var quarantineReplacementGate = QuarantineModelReplacementGate()
    private var finishedInferenceOperations: Set<UInt> = []
    /// Created as soon as a valid capture ends. It remains separate from inference so Escape can
    /// discard a capture while its atomic safety copy is committing off-main.
    private var pendingRecoveryTask: Task<UUID?, Never>?
    /// Generation-owned Return reservation for the current stop-to-delivery window. Keeping the
    /// token here lets Escape close it, while stale asynchronous cleanup cannot affect a new one.
    private var deferredSubmitToken: DeferredSubmitToken?
    /// Identifies the session whose deferred AX receipt may still promote the brief UI from
    /// "posted" to "confirmed". Starting another recording clears it, so a late receipt cannot
    /// repaint a newer session.
    private var activeDeliveryRecoveryID: UUID?
    /// Owns one inference lease from recording start through finalization/cancellation.
    private var backgroundSession: BackgroundTranscriptionSession?
    /// Mutually exclusive with `backgroundSession`; its partials may drive pill preview and the
    /// reversible focused-field session, but never have final-delivery authority.
    private var streamingSession: ActiveStreamingSession?
    private var livePartialTask: Task<Void, Never>?
    private var liveTranscriptionFence = LiveTranscriptionFence()
    /// One recording's live-typing state: what has been typed, and whether it was stopped.
    private struct LiveTypingSession {
        /// The streaming preview generation it belongs to; stale partials cannot write.
        let generation: UInt
        /// The app that was frontmost at start. Any other app in front aborts the session.
        let processIdentifier: pid_t
        /// User key/click counters at start. Any change aborts the session.
        let inputBaseline: UserInputMonitor.Snapshot
        let capitalize: Bool
        /// nil until the one-shot focus probe answers; writes are held until then.
        var focus: LiveTypingFocus?
        var planner = LiveTypingPlanner()
        var abortReason: LiveTypingAbortReason?
    }
    private enum LiveTypingDelivery {
        /// The final transcript is in the field; the normal paste must not run.
        case typed
        /// Live text is in the field but could not be finished safely; show the copy pill.
        case interrupted
    }
    @ObservationIgnored private var liveTyping: LiveTypingSession?
    @ObservationIgnored private var liveTypingProbeTask: Task<Void, Never>?
    private static let liveTypingLog = Logger(subsystem: "com.dictari.app", category: "live-typing")
    private var idleHideTask: Task<Void, Never>?
    private var collapseTask: Task<Void, Never>?
    /// The coordinator owns the task so the explicit Cancel control reaches the actual warm-up.
    /// Engines propagate that cancellation into their dependency download task.
    @ObservationIgnored private var modelPreparationTask: Task<Void, Never>?
    private var modelPreparationLease = ModelPreparationLease()
    @ObservationIgnored private var modelPreparationID: UUID?
    @ObservationIgnored private var modelPreparationCancellationRequested = false
    /// Last model selected while recording, media inference, or another preparation owns the
    /// engine. The persisted active ID changes only after this candidate has warmed successfully.
    private var pendingModel: ModelDescriptor?
    private var modelActivationLifecycle = PreparedModelActivationLifecycle()
    /// A fully warmed activation candidate can finish while a recording still owns the current
    /// engine. Retain it in memory and commit it at the next idle boundary instead of making the
    /// just-recorded audio fail the same-engine readiness check at stop.
    private struct PreparedModelActivation {
        let descriptor: ModelDescriptor
        let engine: any TranscriptionEngine
    }
    private var preparedModelActivation: PreparedModelActivation?
    /// Prevents permission polling or availability callbacks from resurrecting the global tap
    /// after AppKit has begun its asynchronous save-before-quit phase.
    private var isTerminating = false

    /// Debug builds never install updates from the public feed (see `init`).
    private static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    init() {
        let s = SettingsStore()
        self.settings = s
        self.history = HistoryStore(retentionMinutes: s.data.effectiveRetention.minutes)
        let diagnostics = LocalDiagnosticsStore()
        self.diagnostics = diagnostics
        self.metricKitMonitor = MetricKitMonitor(store: diagnostics)
        self.vocabulary = VocabularyStore()
        // AppCoordinator is constructed before AppDelegate reaches its XCTest/self-test gates.
        // Keep Sparkle inert in those modes so a configured feed cannot add launch or network
        // side effects to the deliberately isolated harnesses. It is also disabled in Debug:
        // otherwise Sparkle could replace a local development build with the public Release
        // artifact from the feed.
        self.updater = UpdaterController(
            enabled: !AppDelegate.isRunningTests
                && !SelfTest.isRequested
                && !Self.isDebugBuild
        )
        self.transcriber = Self.makeEngine(for: s.activeModel)
        configureComponents()
        wireHotkey()
        mediaLibrary.onFinished = { [weak self] in self?.modelLifecycleDidChange() }
    }

    // MARK: - Lifecycle

    /// Called once at launch: install UI surfaces, register the hotkey, warm the model.
    func startServices() async {
        metricKitMonitor.start()
        // Materialize both pill panels before the hotkey can fire. `pill` stays lazy because its
        // controller needs this fully initialized coordinator, but the first dictation must not
        // pay for NSPanel/NSHostingView construction before its first visible frame.
        _ = pill
        menuBar.install()
        refreshRecoveries()
        // The global hotkey (CGEventTap) and text injection both need Accessibility —
        // prompt up front so ⌥Space actually works instead of failing silently.
        // Only once onboarding is behind us. On a first run, onboarding explains what
        // Accessibility is for before asking — a system dialog that appears with no
        // explanation is the one most people deny.
        if OnboardingController.hasCompleted,
           !TextInjector.hasAccessibilityPermission() {
            TextInjector.requestAccessibilityPermission()
        }
        ensureHotkey()
        if PillPresentationPolicy.shouldShow(
            alwaysShowPill: settings.data.alwaysShowPill,
            dictationIsActive: state.isActive
        ) {
            pill.show()
            armIdleHide()
        } else {
            pill.hide(force: true)
        }
        // Pay the audio graph's setup cost now, while nobody is waiting for it.
        audio.prearm()
        await warmModel()
        recordOperationalDiagnostic(.servicesStarted)
    }

    /// Arm the global hotkey. If Accessibility isn't granted yet, poll until the user
    /// grants it and then arm — no app restart required.
    private func ensureHotkey() {
        guard !isTerminating else { return }
        do {
            try hotkey.start()
            hotkeyArmed = true
            hotkeyIssue = nil
        } catch {
            hotkeyArmed = false
            hotkeyIssue = error.localizedDescription
            Task { @MainActor [weak self] in
                while let self, !TextInjector.hasAccessibilityPermission() {
                    try? await Task.sleep(for: .seconds(1.5))
                    self.refreshPermissions()
                }
                guard let self, !self.isTerminating else { return }
                do {
                    try self.hotkey.start()
                    self.hotkeyArmed = true
                    self.hotkeyIssue = nil
                } catch {
                    self.hotkeyArmed = false
                    self.hotkeyIssue = error.localizedDescription
                }
                self.refreshPermissions()
            }
        }
    }

    /// Re-read the system permission state. Called on launch, while waiting for the user to
    /// grant Accessibility, and whenever the settings window comes forward — granting a
    /// permission happens in another app, so nothing else would tell us it changed.
    func refreshPermissions() {
        let now = PermissionStatus.current()
        if now != permissions { permissions = now }
    }

    private func warmModel(_ engine: (any TranscriptionEngine)? = nil) async {
        guard let engine else {
            await prepareModel(settings.activeModel, activateOnSuccess: true)
            return
        }
        let engineID = Self.engineID(engine)
        guard Self.engineID(transcriber) == engineID else { return }
        modelState = .loading(nil)
        do {
            try await engine.warmUp { [weak self] p in
                Task { @MainActor in
                    guard let self, Self.engineID(self.transcriber) == engineID else { return }
                    self.modelState = .loading(p)
                }
            }
            guard Self.engineID(transcriber) == engineID else { return }
            modelState = .ready
        } catch {
            guard Self.engineID(transcriber) == engineID else { return }
            modelState = .failed(error.localizedDescription)
        }
    }

    // MARK: - Configuration

    private func configureComponents() {
        let d = settings.data
        injector.method = d.injectionMethod
        injector.restoreClipboard = d.restoreClipboard
        injector.autoCapitalize = d.autoCapitalize
        injector.trailingSpace = d.trailingSpace
        cues.enabled = d.soundCues
        SpokenLanguages.current.withLock { $0 = d.effectiveSpokenLanguages }
        hotkey.mode = d.interactionMode
        var shortcutIssues: [String] = []
        // If the conversation shortcut is about to change, disarm it first so a dictation or
        // cancel change onto its old combination is not rejected as a duplicate of a shortcut
        // that is being replaced. Unchanged, it stays armed (no Carbon re-registration churn).
        if ConversationPolicy.effectiveShortcut(d.conversationShortcut, dictation: d.dictationShortcut,
                                                cancel: d.cancelShortcut) != hotkey.conversationShortcut {
            try? hotkey.setConversationShortcut(nil)
        }
        do {
            try hotkey.setDictationShortcut(d.dictationShortcut)
        } catch {
            shortcutIssues.append(error.localizedDescription)
            settings.data.dictationShortcut = hotkey.dictationShortcut
        }
        do {
            try hotkey.setCancelShortcut(d.cancelShortcut)
        } catch {
            shortcutIssues.append(error.localizedDescription)
            settings.data.cancelShortcut = hotkey.cancelShortcut
        }
        do {
            // A colliding stored value leaves the mode unarmed rather than stealing a key
            // another action owns; Settings shows why.
            try hotkey.setConversationShortcut(ConversationPolicy.effectiveShortcut(
                d.conversationShortcut, dictation: hotkey.dictationShortcut,
                cancel: hotkey.cancelShortcut))
        } catch {
            shortcutIssues.append(error.localizedDescription)
        }
        if !shortcutIssues.isEmpty {
            hotkeyIssue = shortcutIssues.joined(separator: " ")
        } else if hotkeyArmed {
            hotkeyIssue = nil
        }
        hotkey.setDeferredSubmitOnStopEnabled(
            d.autoPasteIntoFocus && state == .listening && conversation == nil)
        audio.configure(vadEnabled: d.vadEnabled, silenceSeconds: d.vadSilenceSeconds,
                        sensitivity: d.vadSensitivity, inputDeviceUID: d.inputDeviceUID)
        syncLocalMCPServer()
    }

    // MARK: - Local MCP

    @ObservationIgnored private let localMCPServer = LocalMCPServer()
    /// False until AppDelegate has passed its XCTest/self-test gates. `configureComponents` already
    /// runs from `init`, which is too early to open a socket in those harnesses.
    @ObservationIgnored private var localMCPPermitted = false

    /// Called by AppDelegate once normal startup is certain.
    func permitLocalMCPServer() {
        localMCPPermitted = true
        syncLocalMCPServer()
    }

    /// The listener follows the AI-agent switches: up only while they grant some access, and
    /// never while quitting. Idempotent, so every settings push may call it.
    private func syncLocalMCPServer() {
        let wanted = localMCPPermitted && !isTerminating && LocalMCPServer.shouldListen(settings.data)
        guard wanted else {
            if localMCPListening { localMCPServer.stop() }
            localMCPListening = false
            return
        }
        if localMCPToken == nil {
            do {
                localMCPToken = try LocalMCPToken.loadOrCreate()
            } catch {
                // Without a token the listener could only reject everything; stay closed.
                Logger(subsystem: "com.dictari.app", category: "mcp")
                    .error("could not create MCP token: \(error.localizedDescription, privacy: .public)")
                localMCPListening = false
                return
            }
        }
        guard let token = localMCPToken, !localMCPListening else { return }
        localMCPServer.start(token: token)
        localMCPListening = true
    }

    /// Re-push settings into components (call after the user edits preferences).
    func applySettings() {
        configureComponents()
        applyAppearance?()
        pill.refresh()   // live-apply pill position / visibility / style
    }

    /// Reload the persisted active model without discarding the current engine until the
    /// replacement is ready. This is also the first-run download path.
    func reloadModel() async {
        guard !mediaLibrary.isBusy, !state.isActive, quarantinedInferenceGeneration == nil,
              quarantineRebuildTask == nil, !modelPreparationLease.isActive else { return }
        await prepareModel(settings.activeModel, activateOnSuccess: true)
    }

    /// Build the backend a descriptor asks for. Parakeet runs through FluidAudio,
    /// everything else through WhisperKit.
    static func makeEngine(for desc: ModelDescriptor) -> any TranscriptionEngine {
        switch desc.backend {
        case .parakeet:
            return ParakeetEngine(displayName: desc.displayName, variant: desc.parakeetVariant ?? .v3)
        case .whisperKit: return WhisperKitEngine(modelName: desc.whisperKitName)
        }
    }

    /// Make a (downloaded or to-be-downloaded) model active only after its fresh engine is
    /// completely ready. A failed or cancelled candidate leaves both the setting and the live
    /// transcriber untouched.
    func setActiveModel(_ desc: ModelDescriptor) async {
        if settings.data.activeModelID == desc.id, modelState == .ready {
            // Selecting the still-active model is also how the user can retract a queued switch.
            // Preserve that intent while another candidate is still warming so its later callback
            // cannot silently reinstate the obsolete selection.
            if modelPreparationTask != nil || modelPreparationLease.isActive
                || pendingModel != nil || preparedModelActivation != nil {
                stagePendingModel(desc)
                if preparedModelActivation?.descriptor.id != desc.id {
                    preparedModelActivation = nil
                }
            } else {
                clearPendingModel()
            }
            return
        }
        guard !mediaLibrary.isBusy, !state.isActive, activeInference == nil,
              quarantinedInferenceGeneration == nil, quarantineRebuildTask == nil,
              modelPreparationTask == nil, !modelPreparationLease.isActive else {
            stagePendingModel(desc)
            if preparedModelActivation?.descriptor.id != desc.id {
                preparedModelActivation = nil
            }
            return
        }
        if let prepared = preparedModelActivation, prepared.descriptor.id == desc.id {
            preparedModelActivation = nil
            clearPendingModel()
            commitPreparedModel(prepared)
            return
        }
        preparedModelActivation = nil
        clearPendingModel()
        await prepareModel(desc, activateOnSuccess: true)
    }

    /// Applies the last model selected during a recording after that recording has released its
    /// engine. Multiple taps collapse to the final ID and never warm competing engines.
    @discardableResult
    private func modelLifecycleDidChange() -> ModelActivationDrainResult {
        // A descriptor may be queued while another candidate is still warming. Let that operation
        // finish first; its completion is another lifecycle edge and cannot lose the pending bit.
        let drainResult: ModelActivationDrainResult
        if modelPreparationTask != nil || modelPreparationLease.isActive
            || quarantineRebuildTask != nil {
            drainResult = .blocked
        } else if !modelActivationLifecycle.hasPending {
            drainResult = .noPending
        } else if modelActivationLifecycle.lifecycleChanged(
            dictationState: state,
            mediaIsBusy: mediaLibrary.isBusy,
            hasActiveInference: activeInference != nil,
            hasQuarantinedInference: quarantinedInferenceGeneration != nil
        ) == .drainExactlyOnce {
            activatePendingModelIfNeeded()
            drainResult = .drained
        } else {
            drainResult = .blocked
        }

        performQuarantineReplacement(quarantineReplacementGate.command(after: drainResult))
        return drainResult
    }

    /// Called only after `modelActivationLifecycle` consumed the edge. This function performs one
    /// commit or schedules one preparation; completion callbacks deliver any later edge.
    private func activatePendingModelIfNeeded() {
        guard let descriptor = pendingModel else { return }

        if let prepared = preparedModelActivation, prepared.descriptor.id == descriptor.id {
            clearPendingModel()
            preparedModelActivation = nil
            commitPreparedModel(prepared)
            return
        }

        preparedModelActivation = nil
        clearPendingModel()
        if settings.data.activeModelID == descriptor.id, modelState == .ready,
           !quarantineReplacementGate.replacementRequired { return }
        guard modelPreparationLease.reserveDispatch() else {
            stagePendingModel(descriptor)
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let started = await self.prepareModel(
                descriptor,
                activateOnSuccess: true,
                ownsPreparationDispatch: true
            )
            if !started {
                self.modelPreparationLease.cancelDispatch()
                self.modelLifecycleDidChange()
            }
        }
    }

    private func stagePendingModel(_ descriptor: ModelDescriptor) {
        pendingModel = descriptor
        modelActivationLifecycle.stage()
    }

    private func clearPendingModel() {
        pendingModel = nil
        modelActivationLifecycle.clear()
    }

    /// Download + warm a model WITHOUT changing the active one. Drives per-row progress.
    func downloadModel(_ desc: ModelDescriptor) async {
        await prepareModel(desc, activateOnSuccess: false)
    }

    /// Cancel the one in-flight model operation. The row stays in a short "Cancelling" state
    /// until the engine has unwound, then partial files are removed before another retry starts.
    func cancelModelDownload() {
        guard let task = modelPreparationTask,
              modelPreparationID != nil,
              let modelID = modelDownloadState.modelID,
              let purpose = modelDownloadState.purpose,
              modelDownloadState.isInProgress
        else { return }

        modelPreparationCancellationRequested = true
        modelDownloadState = .cancelling(modelID: modelID, purpose: purpose)
        task.cancel()
    }

    /// One transactional path for initial load, model switching and library downloads.
    /// `activateOnSuccess` is the commit point: until then, the existing active engine and
    /// persisted id remain exactly as they were.
    @discardableResult
    private func prepareModel(
        _ desc: ModelDescriptor,
        activateOnSuccess: Bool,
        ownsPreparationDispatch: Bool = false
    ) async -> Bool {
        guard modelPreparationTask == nil, quarantineRebuildTask == nil else { return false }
        guard modelPreparationLease.beginPreparation(
            ownsReservedDispatch: ownsPreparationDispatch
        ) else { return false }

        let operationID = UUID()
        let previousModelState = modelState
        let wasDownloaded = ModelFiles.cachedStatus(desc).downloaded
        let wasActive = settings.data.activeModelID == desc.id

        // An interrupted WhisperKit download can leave an apparently present but unusable
        // `.mlmodelc` directory. Clear only known-incomplete files before the retry; a complete
        // active model is never touched here.
        if !wasDownloaded, ModelFiles.hasIncompleteFiles(desc) {
            ModelFiles.delete(desc)
            ModelFiles.invalidateStatusCache()
        }

        let candidate = Self.makeEngine(for: desc)
        let purpose: ModelPreparationPurpose = activateOnSuccess ? .activate : .download
        modelPreparationID = operationID
        modelPreparationCancellationRequested = false
        modelDownloadState = .downloading(
            modelID: desc.id,
            progress: wasDownloaded ? nil : 0,
            purpose: purpose
        )
        if wasActive { modelState = .loading(wasDownloaded ? nil : 0) }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runModelPreparation(
                desc,
                candidate: candidate,
                activateOnSuccess: activateOnSuccess,
                wasDownloaded: wasDownloaded,
                wasActive: wasActive,
                previousModelState: previousModelState,
                purpose: purpose,
                operationID: operationID
            )
        }
        modelPreparationTask = task
        await task.value
        return true
    }

    private func runModelPreparation(
        _ desc: ModelDescriptor,
        candidate: any TranscriptionEngine,
        activateOnSuccess: Bool,
        wasDownloaded: Bool,
        wasActive: Bool,
        previousModelState: ModelState,
        purpose: ModelPreparationPurpose,
        operationID: UUID
    ) async {
        do {
            try await candidate.warmUp { [weak self] progress in
                Task { @MainActor in
                    self?.reportModelProgress(progress, for: desc.id, operationID: operationID,
                                              updatesActiveState: wasActive)
                }
            }
            // Some dependency loaders finish successfully even after their caller is cancelled.
            // Cancellation is still authoritative: never commit that candidate afterward.
            try Task.checkCancellation()

            guard modelPreparationID == operationID else { return }
            ModelFiles.invalidateStatusCache()
            if activateOnSuccess {
                // A newer tap wins over the operation that just completed. Otherwise commit only
                // when no recording/inference can still be tied to the existing engine.
                if let pendingModel, pendingModel.id != desc.id {
                    preparedModelActivation = nil
                } else {
                    let prepared = PreparedModelActivation(descriptor: desc, engine: candidate)
                    switch PreparedModelActivationPolicy.resolve(
                        dictationState: state,
                        mediaIsBusy: mediaLibrary.isBusy,
                        hasActiveInference: activeInference != nil,
                        hasQuarantinedInference: quarantinedInferenceGeneration != nil
                    ) {
                    case .activateNow:
                        clearPendingModel()
                        preparedModelActivation = nil
                        commitPreparedModel(prepared)
                    case .deferUntilIdle:
                        if pendingModel == nil { stagePendingModel(desc) }
                        if pendingModel?.id == desc.id { preparedModelActivation = prepared }
                    }
                }
            } else if wasActive {
                modelState = previousModelState
            }
            finishModelPreparation(operationID: operationID, state: .idle)
        } catch {
            guard modelPreparationID == operationID else { return }
            let cancelled = modelPreparationCancellationRequested
                || Task.isCancelled
                || ModelDownloadFailure.isCancellation(error)
            let failure = ModelDownloadFailure(model: desc, purpose: purpose, error: error)

            // A new/partial download never survives failure or cancellation. A complete model
            // is preserved unless the failure positively identifies corrupt files, in which
            // case keeping it would make every Retry fail at the same point.
            if !wasDownloaded || (!cancelled && failure.kind == .corruptFiles) {
                ModelFiles.delete(desc)
            }
            ModelFiles.invalidateStatusCache()

            if wasActive {
                if cancelled || previousModelState == .ready {
                    modelState = previousModelState
                } else {
                    modelState = .failed(failure.message)
                }
            }

            // A failed activation candidate is not automatically retried from its own pending
            // intent. Once the task releases its warm-up lease, a quarantined active engine gets
            // its one required rebuild instead; a later user action can retry the candidate.
            if activateOnSuccess, pendingModel?.id == desc.id {
                clearPendingModel()
            }

            if cancelled {
                finishModelPreparation(operationID: operationID, state: .idle)
            } else {
                NSLog("Dictari model preparation failed for %@: %@",
                      desc.id, error.localizedDescription)
                finishModelPreparation(operationID: operationID, state: .failed(failure))
            }
        }
    }

    private func reportModelProgress(
        _ progress: Double,
        for modelID: String,
        operationID: UUID,
        updatesActiveState: Bool
    ) {
        guard modelPreparationID == operationID,
              case .downloading(let activeID, _, let purpose) = modelDownloadState,
              activeID == modelID
        else { return }

        let clamped = min(max(progress, 0), 1)
        modelDownloadState = .downloading(
            modelID: modelID,
            progress: clamped,
            purpose: purpose
        )
        if updatesActiveState { modelState = .loading(clamped) }
    }

    private func finishModelPreparation(operationID: UUID, state: ModelDownloadState) {
        guard modelPreparationID == operationID else { return }
        modelDownloadState = state
        modelPreparationTask = nil
        modelPreparationLease.finishPreparation()
        modelPreparationID = nil
        modelPreparationCancellationRequested = false
        modelLifecycleDidChange()
    }

    private func commitPreparedModel(_ prepared: PreparedModelActivation) {
        transcriber = prepared.engine
        settings.data.activeModelID = prepared.descriptor.id
        modelState = .ready
        quarantineReplacementGate.freshEngineCommitted()
    }

    /// Delete a downloaded model's files (never the active one).
    func deleteModel(_ desc: ModelDescriptor) {
        guard desc.id != settings.data.activeModelID else { return }
        if pendingModel?.id == desc.id { clearPendingModel() }
        if preparedModelActivation?.descriptor.id == desc.id { preparedModelActivation = nil }
        ModelFiles.delete(desc)
        ModelFiles.invalidateStatusCache()
    }

    private func wireHotkey() {
        hotkey.onAvailabilityChanged = { [weak self] available in
            guard let self else { return }
            self.hotkeyArmed = available
            guard !self.isTerminating else { return }
            if PillPresentationPolicy.shouldShow(
                alwaysShowPill: self.settings.data.alwaysShowPill,
                dictationIsActive: self.state.isActive
            ) {
                self.pill.show()
            } else {
                if !self.pillExpanded { self.pill.hide(force: true) }
            }
        }
        hotkey.onRevisionActivate = { [weak self] in self?.handleActivate(revise: true) }
        hotkey.onActivate = { [weak self] in self?.handleActivate() }
        hotkey.onConversationActivate = { [weak self] in self?.handleConversationShortcut() }
        hotkey.onDeactivate = { [weak self] in self?.handleDeactivate() }
        hotkey.onCancel = { [weak self] in self?.handleCancelShortcut() }

        audio.onLevel = { [weak self] level in self?.appendLevel(level) }
        audio.onAutoStop = { [weak self] in self?.handleAutoStop() }
        audio.onSamples = { [weak self] samples, offset in
            guard let self else { return }
            if let streamingSession = self.streamingSession {
                streamingSession.stream.append(samples)
            } else {
                self.backgroundSession?.append(samples, at: offset)
            }
        }
    }

    // MARK: - Hotkey handlers

    private func handleActivate(revise: Bool = false) {
        // While a conversation runs, the dictation and correction shortcuts mean "stop" too.
        switch ConversationPolicy.activation(
            revise ? .revisionShortcut : .dictationShortcut,
            state: state, conversationActive: conversation != nil
        ) {
        case .endConversation: endConversation(); return
        case .ignore: return
        case .ordinary, .startConversation, .stopDictation: break
        }
        let activationAt = DictationStageTiming.enabled ? ContinuousClock.now : nil
        if !revise, case .listening = state, recordingContext?.correctionShortcut == true,
           DictationRevisionPolicy.isConstituentModifier(settings.data.dictationShortcut) {
            return
        }
        // A constituent modifier may already have started ordinary dictation while
        // the user was assembling the correction chord. Upgrade that same capture.
        if revise, case .listening = state, recordingContext?.correctionShortcut == false,
           DictationRevisionPolicy.isConstituentModifier(settings.data.dictationShortcut) {
            // The tap provisionally treats a second chord as a toggle stop. This
            // prefix upgrade keeps recording, so retire its Return reservation now.
            if let provisional = hotkey.claimDeferredSubmitWindow(openIfMissing: false) {
                hotkey.closeDeferredSubmitWindow(provisional)
            }
            recordingContext?.revisionAction = .correct
            recordingContext?.correctionShortcut = true
            return
        }

        switch settings.data.interactionMode {
        case .toggle:
            switch ToggleHotkeyAction.resolve(for: state) {
            case .start: startDictation(revise: revise, activationAt: activationAt)
            case .stop: stopDictation()
            case .ignore: break
            }
        case .pushToTalk:
            if !state.isActive { startDictation(revise: revise, activationAt: activationAt) }
        }
    }

    private func handleDeactivate() {
        // Push-to-talk key release ends the session. A conversation is always a toggle: a
        // release (of the dictation key that just stopped it, say) must not act on it.
        if settings.data.interactionMode == .pushToTalk, case .listening = state, conversation == nil {
            stopDictation()
        }
    }

    var canStartMedia: Bool {
        !mediaLibrary.isBusy && !state.isActive && retryingRecoveryID == nil && activeInference == nil
            && quarantinedInferenceGeneration == nil && modelState == .ready
            && !pillRefinement.isBusy && !textRefinement.isBusy
    }

    func transcribeMediaFile(_ url: URL) {
        guard canStartMedia else { return }
        mediaLibrary.startFile(url, engine: transcriber, language: settings.data.defaultLanguage, corrector: vocabulary.corrector)
    }

    @available(macOS 15.0, *)
    func recordMeeting(application: SCRunningApplication, microphone: Bool) {
        guard canStartMedia else { return }
        mediaLibrary.startMeeting(application: application, microphone: microphone, engine: transcriber,
                                  language: settings.data.defaultLanguage, corrector: vocabulary.corrector)
    }

    func analyzeMeetingSpeakers(_ document: MediaDocument) {
        guard canStartMedia else { return }
        mediaLibrary.analyzeSpeakers(document)
    }

    func resumeMedia(_ document: MediaDocument) {
        guard canStartMedia else { return }
        mediaLibrary.resume(document, engine: transcriber, corrector: vocabulary.corrector)
    }

    // MARK: - Dictation lifecycle

    func startDictation(revise: Bool = false, activationAt: ContinuousClock.Instant? = nil,
                        conversation conversationMode: Bool = false) {
        guard !state.isActive, !mediaLibrary.isBusy, !pillRefinement.isBusy,
              !textRefinement.isBusy, conversation == nil else { return }
        hideTask?.cancel()
        idleHideTask?.cancel()
        collapseTask?.cancel()
        activeDeliveryRecoveryID = nil
        pillExpanded = false
        // Permission is re-checked every time — the user may have revoked it in System
        // Settings — but the granted case checks synchronously and starts inline. Wrapping the
        // whole start in a Task queued it behind whatever the main actor was already doing
        // (a settings pane mid-layout, a stats recompute), and that wait clips the first
        // syllable. Only the never-asked case still takes the async prompt path.
        if audio.permissionGranted {
            beginAuthorizedDictation(revise: revise, activationAt: activationAt,
                                     conversation: conversationMode)
        } else {
            Task {
                guard await audio.requestPermission() else {
                    setState(.error(String(localized: "Microphone access needed",
                                           comment: "Permission status: Microphone is not granted")))
                    pill.show()
                    scheduleHide(after: FeedbackTiming.errorHoldSeconds)
                    return
                }
                beginAuthorizedDictation(revise: revise, activationAt: activationAt,
                                         conversation: conversationMode)
            }
        }
    }

    private func beginAuthorizedDictation(revise: Bool, activationAt: ContinuousClock.Instant?,
                                          conversation conversationMode: Bool = false) {
        // The permission prompt path is asynchronous: never open a second conversation over
        // something that started meanwhile.
        if conversationMode, state.isActive || conversation != nil { return }
        activeStageTiming = DictationStageTiming.enabled
            ? DictationStageTiming(activationAt: activationAt, startAt: ContinuousClock.now)
            : nil
        levels.reset()
        let modelWasReadyAtStart = modelState == .ready
        // Hypotheses are only worth their compute when live typing will consume them. The
        // legacy `realtimeTranscriptionEnabled` flag fed an Accessibility preview that no longer
        // exists, so it no longer opens a stream on its own.
        //
        // A conversation is always batch. Each segment is transcribed once, at its pause, by a
        // job that waits for the previous segment's job; an incremental session would hold an
        // inference lease from the moment capture resumes and so overlap the previous segment's
        // final decode on the same engine. Batch also rules out live typing (it needs a stream),
        // which could not coexist with pastes landing between turns.
        let transcriptionMode = conversationMode ? .batch : RecordingTranscriptionMode.select(
            realtimeEnabled: settings.data.liveTypingEnabled
                && settings.data.autoPasteIntoFocus,
            modelReady: modelWasReadyAtStart,
            supportsStreaming: transcriber.supportsStreaming,
            supportsBackground: transcriber.supportsBackgroundTranscription
        )
        var context = RecordingTranscriptionContext(
            engine: transcriber,
            preferences: settings.data.dictationPreferences(for: nil),
            modelID: settings.activeModel.id,
            modelWasReadyAtStart: modelWasReadyAtStart,
            autoPasteIntoFocus: settings.data.autoPasteIntoFocus,
            transcriptionMode: transcriptionMode
        )
        // Decided before the engine starts: the incremental feed is configured once per
        // session, so this cannot be turned on halfway through.
        audio.streamsSamples = context.transcriptionMode.streamsSamples
        if conversationMode {
            // Before `.listening`: `setState` reads it to keep the Return reservation off.
            conversation = ConversationSession(segmentStart: ContinuousClock.now)
            conversationActive = true
            conversationCopiedTranscript = ""
        }
        // Make capture visible before the engine can open the device. The UI may lead the
        // microphone by a moment; the microphone must never lead the privacy indicator.
        setState(.listening)
        pill.show()
        activeStageTiming?.pillShowReturnedAt = ContinuousClock.now
        do {
            if conversationMode {
                try audio.start(autoStopAfterSilence: ConversationPolicy.silenceSeconds(
                    vadEnabled: settings.data.vadEnabled,
                    configuredSeconds: settings.data.vadSilenceSeconds))
            } else {
                try audio.start()
            }
            // Resolve once after capture starts: no workspace lookup on the mic-start path.
            // Switching apps or profiles later must not change audio already being recorded.
            sessionApp = injector.frontAppInfo()
            context.preferences = settings.data.dictationPreferences(for: sessionApp.bundleID)
            context.writingRule = settings.data.writingRule(for: sessionApp.bundleID)
            context.correctionShortcut = revise
            // No generative rewrite per segment: it would put a model round trip between each
            // pause and its paste, and a conversation's turns are delivered as spoken.
            context.revisionAction = conversationMode ? nil : DictationRevisionPolicy.action(
                explicitCorrection: revise, rule: context.writingRule
            )
            context.applicationBundleID = sessionApp.bundleID
            recordingContext = context
            if context.autoPasteIntoFocus {
                injector.prepareForDictation()
            }
            openIncrementalSession(
                mode: context.transcriptionMode,
                engine: context.engine,
                language: context.language
            )
            beginLiveTypingIfEligible(context: context)
            sessionStart = ContinuousClock.now
            conversation?.segmentStart = sessionStart
            playStartSound()
        } catch {
            activeStageTiming = nil
            closeIncrementalSession()
            clearConversation()
            setState(.error(String(localized: "Couldn't start recording", comment: "Pill error")))
            pill.show()
            scheduleHide(after: FeedbackTiming.errorHoldSeconds)
        }
    }

    func stopDictation() {
        // A conversation owns every stop request while it listens: the pill's finish button,
        // a shortcut press and the termination path all end it the same way.
        if conversation != nil {
            if state == .listening { endConversation() }
            return
        }
        let context = recordingContext ?? RecordingTranscriptionContext(
            engine: transcriber,
            preferences: settings.data.dictationPreferences(for: sessionApp.bundleID),
            modelID: settings.activeModel.id,
            modelWasReadyAtStart: modelState == .ready,
            autoPasteIntoFocus: settings.data.autoPasteIntoFocus,
            transcriptionMode: .batch
        )
        // Without Accessibility the injector copies to the clipboard on its own.
        // Quitting mid-dictation keeps the words (History + clipboard) but never pastes into
        // whatever happens to be focused while the app is going away.
        let shouldAutoPaste = context.autoPasteIntoFocus && !isTerminating
        let claimedSubmitToken = hotkey.claimDeferredSubmitWindow(
            openIfMissing: shouldAutoPaste
        )
        guard case .listening = state else {
            discardDeferredSubmit(claimedSubmitToken)
            return
        }
        let submitToken = shouldAutoPaste ? claimedSubmitToken : nil
        if !shouldAutoPaste { discardDeferredSubmit(claimedSubmitToken) }
        deferredSubmitToken = submitToken
        recordingContext = nil
        let stopTime = ContinuousClock.now
        var stageTiming = activeStageTiming
        activeStageTiming = nil
        stageTiming?.stopAt = stopTime
        let samples = audio.stop()
        stageTiming?.audioStoppedAt = ContinuousClock.now
        audio.streamsSamples = false
        retireLivePartialPresentation()
        var willFinalizeIncrementalSession = false
        // Every early exit releases the recording's inference lease, even a mis-tap or
        // proximity rejection. A native call that ignores cancellation remains quarantined.
        defer {
            if !willFinalizeIncrementalSession {
                closeIncrementalSession()
            }
        }
        // Read the measured loudness before any early return, so every recorded entry
        // carries it — including the ones rejected as too far or silent, which are exactly
        // the entries you need the number for.
        lastSpeechLevel = audio.lastSpeechLevel
        // Rebuild the graph so the next dictation starts instantly — but on a later main-actor
        // turn, not inline: `prearm()` costs 1–20 ms and an inline defer would pay it before
        // the transcription task below is even scheduled, straight out of the stop→inject budget.
        defer { Task { self.rearmAudio() } }
        var maxAmp: Float = 0
        if !samples.isEmpty {
            vDSP_maxmgv(samples, 1, &maxAmp, vDSP_Length(samples.count))
        }
        // A system clock adjustment must not change the minimum-duration decision or
        // saved duration. Keep the interval even when a failed capture returns no samples.
        let recorded = sessionStart.duration(to: stopTime).components
        let duration = Double(recorded.seconds) + Double(recorded.attoseconds) / 1e18

        // Discard accidental taps silently. Recording them produced runs of blank
        // zero-second history entries that told the user nothing, and a quick open-and-close
        // flashed a "too far" / "no audio" rejection for something that was never a dictation.
        let filter = settings.data.proximityFilter ?? .off
        guard !AccidentalSession.isAccidental(
            duration: duration, peak: maxAmp, speechLevel: lastSpeechLevel,
            minimumSpeechLevel: filter.minimumSpeechLevel
        ) else {
            discardDeferredSubmit(submitToken)
            setState(.idle)
            scheduleHide(after: 0.0)
            return
        }

        // From this point on the recording is valuable, even if a signal/proximity heuristic
        // rejects it incorrectly. Start exactly one atomic safety copy before any such branch;
        // every outcome below reuses this task instead of creating a second competing record.
        setState(.transcribing)
        let recoveryTask = saveRecovery(
            samples: samples,
            duration: duration,
            language: context.language,
            modelID: context.modelID
        )
        pendingRecoveryTask = recoveryTask

        // Guard against silent capture (mic muted / wrong input device / no signal):
        // feeding Whisper digital silence makes it hallucinate ("Thank you", "Grazie").
        // Surface a clear hint instead, while keeping the original capture recoverable in case
        // the fixed threshold classified a quiet but valid long dictation incorrectly.
        guard !samples.isEmpty, maxAmp >= AccidentalSession.silencePeak else {
            discardDeferredSubmit(submitToken)
            record(text: "", duration: duration, latency: 0, tag: "no audio", language: context.language)
            finishWithSavedRecovery(recoveryTask, message: "No audio from the mic")
            return
        }

        // Coarse whole-session loudness guard. It intentionally does not claim to identify a
        // speaker: a close quiet voice and a distant loud voice can measure the same. Settings
        // explains the limitation and exposes the exact 0...1 measurement used here.
        if lastSpeechLevel < filter.minimumSpeechLevel {
            discardDeferredSubmit(submitToken)
            record(text: "", duration: duration, latency: 0, tag: "too far", language: context.language)
            finishWithSavedRecovery(recoveryTask, message: "Too far from the mic")
            return
        }

        // Only transcribe once the model is ready. This also enforces the happens-before
        // invariant that makes WhisperKitEngine's nonisolated(unsafe) pipe access sound:
        // transcribe never overlaps the engine's single warm-up write.
        let sameEngineIsReadyAtStop = modelState == .ready
            && Self.engineID(transcriber) == Self.engineID(context.engine)
        guard RecordingReadiness.isReady(
            wasReadyAtStart: context.modelWasReadyAtStart,
            sameEngineIsReadyAtStop: sameEngineIsReadyAtStop
        ) else {
            discardDeferredSubmit(submitToken)
            record(text: "", duration: duration, latency: 0, tag: "failed", language: context.language)
            finishWithSavedRecovery(recoveryTask, message: "Model still loading")
            return
        }
        // Freeze this session's engine and language. A settings change while the safety copy is
        // committing applies to the next dictation, never halfway through this one.
        let sessionEngine = context.engine
        let sessionLanguage = context.language
        let backgroundSession = self.backgroundSession
        let streamingSession = self.streamingSession
        // Only an incremental session opened a lease at recording start. Reading the slot
        // unconditionally was equivalent while nothing could overlap a recording's stop; in a
        // conversation the previous segment's batch inference may still own it.
        let recordingInference = backgroundSession != nil || streamingSession != nil
            ? activeInference : nil
        willFinalizeIncrementalSession = true
        playStopSound()

        let job = DeliveryJob(
            role: .dictation, context: context, samples: samples, duration: duration,
            stopTime: stopTime, shouldAutoPaste: shouldAutoPaste, submitToken: submitToken,
            recoveryTask: recoveryTask, backgroundSession: backgroundSession,
            streamingSession: streamingSession, recordingInference: recordingInference,
            stageTiming: stageTiming
        )
        transcriptionTask = Task { [weak self] in await self?.deliverTranscription(job) }
    }

    /// Everything one captured recording needs from stop to History. An ordinary dictation and
    /// every conversation segment go through the same `deliverTranscription`, so inference
    /// leases, vocabulary, spoken formatting, injection and recovery behave identically; `role`
    /// only decides who owns the pill and the dictation state.
    private struct DeliveryJob {
        let role: DeliveryRole
        let context: RecordingTranscriptionContext
        let samples: [Float]
        let duration: Double
        let stopTime: ContinuousClock.Instant
        let shouldAutoPaste: Bool
        let submitToken: DeferredSubmitToken?
        let recoveryTask: Task<UUID?, Never>
        let backgroundSession: BackgroundTranscriptionSession?
        let streamingSession: ActiveStreamingSession?
        let recordingInference: ActiveInference?
        let stageTiming: DictationStageTiming?
    }

    private enum DeliveryRole: Equatable {
        /// Owns the dictation state and the pill for its outcome, as it always has.
        case dictation
        /// Leaves the state `.listening` (the conversation keeps capturing) and reports its
        /// outcome to the conversation instead.
        case conversationSegment(conversationID: UUID, index: Int)

        var segment: (conversationID: UUID, index: Int)? {
            if case .conversationSegment(let id, let index) = self { return (id, index) }
            return nil
        }
    }

    private func deliverTranscription(_ job: DeliveryJob) async {
        let context = job.context
        let samples = job.samples
        let duration = job.duration
        let stopTime = job.stopTime
        let submitToken = job.submitToken
        let recoveryTask = job.recoveryTask
        let sessionEngine = context.engine
        let sessionLanguage = context.language
        let backgroundSession = job.backgroundSession
        let streamingSession = job.streamingSession
        let recordingInference = job.recordingInference
        let segment = job.role.segment
        // Quitting while earlier turns wait in the chain: never paste into whatever happens to
        // be focused while the app is going away (the same rule `stopDictation` applies).
        let shouldAutoPaste = job.shouldAutoPaste && !(segment != nil && isTerminating)
        do {
            var stageTiming = job.stageTiming
            var timingOutcome: DictationStageTiming.Outcome = .interrupted
            defer { stageTiming?.emitDelivery(mode: context.transcriptionMode, outcome: timingOutcome) }
            defer { self.discardDeferredSubmit(submitToken) }
            // Persistence and inference deliberately race. Any failed/interrupted path joins the
            // atomic commit before reporting recovery, while confirmed delivery deletes only an
            // already-committed record. Thus a normal disk delay cannot sit on stop→inference.
            guard !Task.isCancelled else { return }
            if let segment {
                // A segment waited behind earlier ones; the engine it was captured for must still
                // be the healthy, idle, current engine. After a timeout or cancellation it is
                // quarantined and must never be handed another utterance.
                guard self.conversationEngineIsUsable(for: context, conversationID: segment.conversationID) else {
                    self.record(text: "", duration: duration, latency: 0, tag: "failed",
                                language: sessionLanguage)
                    self.conversationSegmentFailed(segment, recoveryTask: recoveryTask,
                                                   message: "Model not ready", endsConversation: true)
                    return
                }
            }
            stageTiming?.inferenceTaskStartedAt = ContinuousClock.now
            let activeInference = recordingInference ?? self.beginInference(engine: sessionEngine)
            let engine = activeInference.engine
            do {
                let generation = activeInference.generation
                stageTiming?.inferenceAwaitStartedAt = ContinuousClock.now
                let output = try await TranscriptionDeadline.run(
                    for: .seconds(30),
                    onOperationFinished: { [weak self] in
                        // Incremental sessions own their lifecycle callback from recording
                        // start, including cancellation before the user stops.
                        guard backgroundSession == nil, streamingSession == nil else { return }
                        Task { @MainActor [weak self] in
                            self?.inferenceOperationDidFinish(generation)
                        }
                    }
                ) {
                    // The detailed variants return the exact text the plain calls did, plus
                    // per-word confidence for the corrector and History.
                    if let streamingSession {
                        return try await streamingSession.stream.finishDetailed(samples: samples)
                    }
                    if let backgroundSession {
                        return try await backgroundSession.finishDetailed(samples: samples)
                    }
                    return try await engine.transcribeDetailed(samples: samples, language: sessionLanguage)
                }
                stageTiming?.transcriptReadyAt = ContinuousClock.now
                // The user may have cancelled while transcription was in flight.
                guard !Task.isCancelled, self.finishInference(activeInference) else {
                    self.pendingRecoveryTask = nil
                    return
                }
                self.backgroundSession = nil
                self.streamingSession = nil
                self.retireLivePartialPresentation()
                // Vocabulary correction belongs to the transcript. Optional generative revision
                // only changes delivery; history retains this original for comparison/recovery.
                // Confident words get exactly the strict rules; only words the engine itself
                // was unsure of may take the looser, sound-alike vocabulary match.
                let confidenceCorrection = self.vocabulary.corrector.correct(output)
                // Before spoken formatting, so "Yeah." becomes "Sì." rather than being formatted
                // as English. Narrow by design; see `ShortUtteranceFix`.
                var corrected = ShortUtteranceFix.apply(
                    confidenceCorrection.text, spoken: self.settings.data.effectiveSpokenLanguages
                )
                // Spoken commands ("virgola", "a capo") are opt-in: converting words to
                // punctuation silently rewrites prose for anyone who didn't ask for it.
                if self.settings.data.spokenCommandsEnabled {
                    corrected = SpokenFormatting.apply(corrected, language: sessionLanguage)
                }
                let trimmed = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
                if let segment, ConversationPolicy.discardsTranscript(trimmed) {
                    // A gap the model heard nothing in (a cough, a breath): not a failure in a
                    // conversation, and not worth a History row or a retained recording.
                    self.deleteSavedRecovery(recoveryTask)
                    self.conversationSegmentFinished(segment, result: .discarded)
                    return
                }
                if AccidentalSession.isAccidental(duration: duration, transcriptIsEmpty: trimmed.isEmpty) {
                    // Nothing said in a brief open-and-close: close as quietly as a mis-tap.
                    self.pendingRecoveryTask = nil
                    self.deleteSavedRecovery(recoveryTask)
                    self.setState(.idle)
                    self.scheduleHide(after: 0.0)
                    return
                }
                if trimmed.isEmpty {
                    self.record(text: "", duration: duration, latency: 0, tag: "no speech",
                                language: sessionLanguage)
                    self.finishWithSavedRecovery(recoveryTask, message: "No speech detected")
                    return
                }
                let originalText = context.preferences.format(trimmed)
                // Located in the final History text, after formatting, so offsets index exactly
                // what History stores. nil when the engine gave no scores at all. Evaluated at
                // record time, which on the success path is after the paste has landed.
                let uncertainSpans = { () -> [UncertainSpan]? in
                    output.hasConfidence
                        ? UncertainSpan.locate(confidenceCorrection.uncertainWords, in: originalText)
                        : nil
                }
                var deliveryText = originalText
                if let action = context.revisionAction {
                    self.isRevising = true
                    do {
                        // A separately opened settings preview must finish before another model request.
                        guard !self.textRefinement.isBusy else {
                            throw WritingError.unavailable(String(localized: "A revision is still finishing. Try again shortly.",
                                                                          comment: "Error when a text revision is already running"))
                        }
                        let revised = try await self.pillRefinement.reviseBeforeInsertion(trimmed, action: action)
                        try Task.checkCancellation()
                        deliveryText = context.preferences.format(revised)
                    } catch {
                        self.isRevising = false
                        guard !Task.isCancelled else { return }
                        self.lastTranscript = originalText
                        self.record(text: originalText, duration: duration, latency: 0,
                                    tag: "revision failed", language: sessionLanguage,
                                    uncertainSpans: uncertainSpans())
                        self.markRecoveryOutcome(recoveryTask, description: error.localizedDescription,
                                                 transcript: originalText)
                        self.pendingRecoveryTask = nil
                        self.setState(.error(error.localizedDescription))
                        self.scheduleHide(after: FeedbackTiming.errorHoldSeconds)
                        return
                    }
                    self.isRevising = false
                }
                self.lastTranscript = deliveryText
                var kind: DictationState.SuccessKind
                // Persisted in English: `HistoryTimeline` matches recovery descriptions by text.
                // Screens translate them through `DictationRecovery.displayFailureDescription`.
                var recoveryDescription: String
                var delivery: InjectionDelivery?
                var submitWasPosted = false
                // Live typing owns delivery only when it already wrote text; otherwise (nil)
                // the ordinary paste below runs exactly as without the feature.
                let liveDelivery = await self.finishLiveTyping(finalText: deliveryText)
                if Task.isCancelled {
                    self.pendingRecoveryTask = nil
                    return
                }
                if let liveDelivery {
                    stageTiming?.deliveryReturnedAt = ContinuousClock.now
                    switch liveDelivery {
                    case .typed:
                        kind = .inserted
                        recoveryDescription = "Typed live into the focused field"
                        let submitCompletion = self.completeDeferredSubmit(submitToken, inputWasPosted: true)
                        submitWasPosted = submitCompletion == .posted
                        if submitCompletion == .replayFailed {
                            kind = .submitFailed
                            recoveryDescription = "Typed live; check the text before pressing Return"
                        }
                    case .interrupted:
                        // Never finish into a field whose caret may have moved: the partial text
                        // stays as it is, and the pill offers the whole final transcript.
                        _ = self.completeDeferredSubmit(submitToken, inputWasPosted: false)
                        kind = .copiedToClipboard
                        recoveryDescription = self.writeClipboard(deliveryText)
                            ? "Live typing interrupted; transcript copied"
                            : "Live typing interrupted; copy failed"
                    }
                } else if shouldAutoPaste {
                    // The field focused at delivery time is the target; see TextInjector.
                    do {
                        let resolvedDelivery = await self.injector.injectDelivery(
                            deliveryText,
                            textIsPreprocessed: true
                        )
                        stageTiming?.deliveryReturnedAt = ContinuousClock.now
                        delivery = resolvedDelivery
                        if Task.isCancelled {
                            self.pendingRecoveryTask = nil
                            return
                        }
                        if resolvedDelivery.initialResult == .cancelled {
                            self.pendingRecoveryTask = nil
                            return
                        }
                        switch resolvedDelivery.initialResult {
                        case .pasteUnverified:
                            kind = .pastedUnverified
                            recoveryDescription = "Paste could not be verified"
                            let submitCompletion = self.completeDeferredSubmit(submitToken, inputWasPosted: true)
                            submitWasPosted = submitCompletion == .posted
                            if submitCompletion == .replayFailed {
                                kind = .submitFailed
                                recoveryDescription = "Paste unverified; check the text before pressing Return"
                            }
                        case .copiedToClipboard:
                            kind = .copiedToClipboard
                            recoveryDescription = "Could not insert; transcript copied"
                            _ = self.completeDeferredSubmit(submitToken, inputWasPosted: false)
                        case .secureFieldBlocked:
                            kind = .copiedToClipboard
                            recoveryDescription = "Secure field blocked insertion; transcript copied"
                            _ = self.completeDeferredSubmit(submitToken, inputWasPosted: false)
                        case .clipboardWriteFailed:
                            _ = self.completeDeferredSubmit(submitToken, inputWasPosted: false)
                            let elapsed = stopTime.duration(to: .now).components
                            let latency = Int(elapsed.seconds * 1_000
                                + elapsed.attoseconds / 1_000_000_000_000_000)
                            self.record(text: originalText, duration: duration, latency: latency,
                                        tag: "clipboard failed", language: sessionLanguage,
                                        uncertainSpans: uncertainSpans())
                            self.markRecoveryOutcome(
                                recoveryTask,
                                description: "Clipboard write failed",
                                transcript: originalText
                            )
                            if let segment {
                                self.conversationSegmentFinished(
                                    segment, result: .failed(String(localized: "Copy failed — transcript saved in History", comment: "Pill error")))
                                return
                            }
                            self.pendingRecoveryTask = nil
                            self.setState(.error(String(localized: "Copy failed — transcript saved in History", comment: "Pill error")))
                            self.scheduleHide(after: FeedbackTiming.errorHoldSeconds)
                            return
                        case .cancelled:
                            return
                        }
                    }
                } else {
                    guard self.writeClipboard(deliveryText) else {
                        let elapsed = stopTime.duration(to: .now).components
                        let latency = Int(elapsed.seconds * 1_000
                            + elapsed.attoseconds / 1_000_000_000_000_000)
                        self.record(text: originalText, duration: duration, latency: latency,
                                    tag: "clipboard failed", language: sessionLanguage,
                                    uncertainSpans: uncertainSpans())
                        self.markRecoveryOutcome(
                            recoveryTask,
                            description: "Clipboard write failed",
                            transcript: originalText
                        )
                        if let segment {
                            self.conversationSegmentFinished(
                                segment, result: .failed(String(localized: "Copy failed — transcript saved in History", comment: "Pill error")))
                            return
                        }
                        self.pendingRecoveryTask = nil
                        self.setState(.error(String(localized: "Copy failed — transcript saved in History", comment: "Pill error")))
                        self.scheduleHide(after: FeedbackTiming.errorHoldSeconds)
                        return
                    }
                    kind = .copiedToClipboard
                    stageTiming?.deliveryReturnedAt = ContinuousClock.now
                    recoveryDescription = "Transcribed and copied"
                }
                let elapsed = stopTime.duration(to: .now).components
                let latency = Int(elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000)
                // Success UI first, bookkeeping after: the history encode has no business
                // sitting between the paste landing and the pill confirming it.
                // Linger on the transcript box so it's readable; the paste confirmation is brief.
                // Only the transcript box needs reading time; the two confirmations don't.
                if let segment {
                    // The pill keeps listening; only text with nowhere to go changes it.
                    self.conversationSegmentFinished(segment, result: .delivered(kind, text: deliveryText))
                } else {
                    self.showSuccess(kind)
                }
                stageTiming?.feedbackReturnedAt = ContinuousClock.now
                timingOutcome = switch kind {
                case .inserted: .liveInserted
                case .pastedUnverified: .pasteCallReturned
                case .submitFailed: .submitFailed
                case .copiedToClipboard: .clipboard
                }
                if segment == nil, context.revisionAction == nil {
                    self.offerPillWriting(context.writingRule, recordedApp: context.applicationBundleID, kind: kind)
                }
                let spans = uncertainSpans()
                self.lastTranscriptUncertainty = spans.map { UncertainTranscript(text: originalText, spans: $0) }
                self.record(text: originalText, duration: duration, latency: latency,
                            tag: context.revisionAction == nil ? nil : "revised",
                            language: sessionLanguage, uncertainSpans: spans)
                self.pendingRecoveryTask = nil
                if shouldAutoPaste {
                    let deliveryToken = UUID()
                    // A segment must not take the dictation-level promotion slot; its own
                    // late verification is routed to the conversation below.
                    if segment == nil { self.activeDeliveryRecoveryID = deliveryToken }
                    let initialPersistence = self.markRecoveryOutcome(
                        recoveryTask,
                        description: recoveryDescription,
                        transcript: deliveryText
                    )
                    let mayPromoteDelivery = kind != .submitFailed
                    if let delivery, delivery.hasDeferredVerification, mayPromoteDelivery {
                        let verificationTiming = stageTiming
                        Task { @MainActor [weak self] in
                            // The failure-safe state must reach disk before confirmed delivery
                            // removes the PCM; that ordering cannot turn a failed paste into a
                            // missing recovery.
                            guard await initialPersistence.value != nil,
                                  let outcome = await delivery.verificationOutcome(),
                                  let self else { return }
                            verificationTiming?.emitReceiptObserved(
                                at: ContinuousClock.now,
                                outcome: outcome
                            )
                            if outcome == .confirmed { self.deleteSavedRecovery(recoveryTask) }
                            if let segment {
                                // The conversation pill is still listening; a paste that did not
                                // land joins the conversation's transcript card instead.
                                if AppFeedbackPresentation.successAfterPostedInputVerification(
                                    outcome, submitWasPosted: submitWasPosted
                                ) == .copiedToClipboard {
                                    self.conversationSegmentDidNotLand(segment, text: deliveryText)
                                }
                                return
                            }
                            guard self.activeDeliveryRecoveryID == deliveryToken,
                                  let refinedKind = AppFeedbackPresentation.successAfterPostedInputVerification(
                                      outcome, submitWasPosted: submitWasPosted
                                  )
                            else { return }
                            // The brief "pasted" pill may already have hidden; a failed paste still
                            // reopens it with Copy. Anything else (a new dictation) wins.
                            switch self.state {
                            case .success(.pastedUnverified): break
                            case .idle where refinedKind == .copiedToClipboard: break
                            default: return
                            }
                            // This refinement invalidates the original unverified-paste hide token;
                            // route it through the shared helper so the confirmed checkmark cannot
                            // remain on screen indefinitely.
                            self.showSuccess(refinedKind)
                        }
                    }
                } else {
                    // A deliberate clipboard-only dictation has reached its requested endpoint;
                    // it should not leave a recovery duplicate behind.
                    self.deleteSavedRecovery(recoveryTask)
                }
            } catch {
                timingOutcome = Self.isTimeout(error) ? .inferenceTimeout : .failed
                if Task.isCancelled {
                    self.pendingRecoveryTask = nil
                    return
                }
                self.streamingSession?.stream.cancel()
                self.streamingSession = nil
                self.retireLivePartialPresentation()
                self.backgroundSession?.cancel()
                self.backgroundSession = nil
                if Self.isTimeout(error) {
                    guard self.replaceTimedOutInference(activeInference) else {
                        self.pendingRecoveryTask = nil
                        return
                    }
                } else if !self.finishInference(activeInference) {
                    self.pendingRecoveryTask = nil
                    return
                }
                self.record(text: "", duration: duration, latency: 0, tag: "failed",
                            language: sessionLanguage)
                if let segment {
                    // A timed-out engine is quarantined above; every later segment would fail the
                    // same way, so the conversation ends rather than keep capturing into errors.
                    self.conversationSegmentFailed(segment, recoveryTask: recoveryTask,
                                                   message: error.localizedDescription,
                                                   endsConversation: Self.isTimeout(error))
                    return
                }
                self.finishWithSavedRecovery(recoveryTask, message: error.localizedDescription)
            }
        }
    }

    /// Select one incremental owner for the frozen recording mode. Realtime is best-effort:
    /// a cold/unsupported stream silently falls back to the completed-phrase optimization,
    /// then to the unchanged batch path. Two sessions are never opened for one recording.
    private func openIncrementalSession(
        mode: RecordingTranscriptionMode,
        engine: any TranscriptionEngine,
        language: String
    ) {
        guard audio.streamsSamples else { return }
        switch mode {
        case .realtime:
            if openStreamingSession(
                engine: engine,
                language: language
            ) { return }
            if RecordingTranscriptionMode.fallbackAfterStreamingFailure(
                supportsBackground: engine.supportsBackgroundTranscription
            ) == .background {
                openBackgroundSession(engine: engine, language: language)
            } else {
                audio.streamsSamples = false
            }
        case .background:
            openBackgroundSession(engine: engine, language: language)
        case .batch:
            audio.streamsSamples = false
        }
    }

    @discardableResult
    private func openStreamingSession(
        engine: any TranscriptionEngine,
        language: String
    ) -> Bool {
        guard streamingSession == nil, backgroundSession == nil else { return false }
        let stream: any TranscriptionStream
        do {
            stream = try engine.startStream(language: language)
        } catch {
            return false
        }

        let inference = beginInference(engine: engine)
        let inferenceGeneration = inference.generation
        let previewGeneration = liveTranscriptionFence.begin()
        stream.installTerminationHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.inferenceOperationDidFinish(inferenceGeneration)
            }
        }
        streamingSession = ActiveStreamingSession(
            previewGeneration: previewGeneration,
            stream: stream
        )
        livePartialTask?.cancel()
        livePartialTask = Task { [weak self, stream] in
            for await update in stream.updates {
                guard !Task.isCancelled, let self else { return }
                guard self.liveTranscriptionFence.accepts(
                    update,
                    generation: previewGeneration,
                    isListening: self.state == .listening
                ) else { continue }
                self.liveTypingDidReceive(update.text, generation: previewGeneration)
            }
        }
        return true
    }

    /// Background decoding is independent of pill visibility. The session's engine and
    /// language are frozen before the first audio is forwarded, just like batch dictation.
    private func openBackgroundSession(engine: any TranscriptionEngine, language: String) {
        guard audio.streamsSamples, streamingSession == nil, backgroundSession == nil else { return }
        let inference = beginInference(engine: engine)
        let generation = inference.generation
        backgroundSession = BackgroundTranscriptionSession(
            engine: engine, language: language,
            onFinished: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.inferenceOperationDidFinish(generation)
                }
            }
        )
    }

    private func retireLivePartialPresentation() {
        liveTranscriptionFence.invalidate()
        livePartialTask?.cancel()
        livePartialTask = nil
    }

    private func closeIncrementalSession() {
        retireLivePartialPresentation()
        endLiveTyping()
        audio.streamsSamples = false
        if let session = streamingSession {
            streamingSession = nil
            if session.stream.cancelAndReportInference() {
                replaceActiveInferenceAfterCancellation()
            } else if let inference = activeInference {
                // No native operation owns this engine, so no reload is necessary.
                finishInference(inference)
            }
            return
        }
        guard let session = backgroundSession else { return }
        backgroundSession = nil
        if session.cancel() {
            replaceActiveInferenceAfterCancellation()
        } else if let inference = activeInference {
            // No native operation owns this engine, so no reload is necessary.
            finishInference(inference)
        }
    }

    // MARK: - Live typing
    //
    // Opt-in (Settings → Text Injection → Live Typing). While the user speaks, stable words
    // are typed into the focused field as Backspace + Unicode key events; at stop the
    // authoritative final transcript is reconciled with one minimal edit, and the normal paste
    // does not run. Safety policy (`LiveTypingPolicy`): the session stops writing for good the
    // moment the user presses a key or clicks, another app comes to the front, Secure Event
    // Input turns on, or the start-time focus probe says "password field" / "not a text box".
    // Writes wait while a modifier is held. An interrupted session leaves what it typed and
    // shows the copy pill with the full final transcript; a session that never typed anything
    // falls back to the ordinary paste. Backspace can only ever remove this session's own text
    // (`LiveTypingPlanner` invariant).

    private func beginLiveTypingIfEligible(context: RecordingTranscriptionContext) {
        endLiveTyping()
        guard settings.data.liveTypingEnabled,
              context.autoPasteIntoFocus,
              // A revision rewrites the transcript after stop; typing the raw words first
              // would only flash text that is about to be replaced.
              context.revisionAction == nil,
              let stream = streamingSession,
              let processIdentifier = sessionApp.processIdentifier,
              liveTyper.isAvailable,
              !liveTyper.secureInputEnabled()
        else { return }
        let generation = stream.previewGeneration
        liveTyping = LiveTypingSession(
            generation: generation,
            processIdentifier: processIdentifier,
            inputBaseline: UserInputMonitor.shared.snapshot,
            capitalize: context.preferences.capitalize
        )
        // One Accessibility probe per session, off the main actor; nothing is typed until it
        // answers. The paste path's own delivery-time probe is untouched.
        liveTypingProbeTask = Task { [weak self, liveTyper] in
            let focus = await liveTyper.focusClass(processIdentifier: processIdentifier)
            guard let self, !Task.isCancelled, self.liveTyping?.generation == generation else { return }
            self.liveTyping?.focus = focus
        }
    }

    private func liveTypingDidReceive(_ hypothesis: String, generation: UInt) {
        guard var session = liveTyping, session.generation == generation,
              session.abortReason == nil else { return }
        // The same transcript transforms the final path applies first, so a stable word is
        // typed in its final spelling and the stop-time edit stays small.
        var display = vocabulary.corrector.correct(hypothesis)
        if session.capitalize, let first = display.firstIndex(where: { !$0.isWhitespace }) {
            display.replaceSubrange(first...first, with: String(display[first]).uppercased())
        }
        let proposal = session.planner.propose(partial: display)
        switch LiveTypingPolicy.decide(liveTypingConditions(for: session)) {
        case .abort(let reason):
            session.abortReason = reason
            Self.liveTypingLog.notice("live typing stopped: \(reason.rawValue, privacy: .public)")
        case .hold:
            break
        case .write:
            if let proposal {
                if liveTyper.post(proposal) {
                    session.planner.commit(proposal)
                } else {
                    session.abortReason = .postFailed
                    Self.liveTypingLog.notice("live typing stopped: could not create key events")
                }
            }
        }
        liveTyping = session
    }

    /// Reconciles the field with the authoritative transcript. Nil means live typing wrote
    /// nothing (or removed its own text), so the ordinary delivery path owns this transcript.
    private func finishLiveTyping(finalText: String) async -> LiveTypingDelivery? {
        guard let session = liveTyping else { return nil }
        liveTypingProbeTask?.cancel()
        liveTypingProbeTask = nil
        guard !session.planner.typed.isEmpty else {
            liveTyping = nil
            return nil
        }
        guard session.abortReason == nil else {
            liveTyping = nil
            return .interrupted
        }
        // The stop shortcut usually has a modifier (⌥Space); a Backspace with ⌥ down would
        // delete a word. Normally free: the final decode outlasts the key release.
        _ = await liveTyper.awaitModifierRelease(budget: .milliseconds(600))
        guard !Task.isCancelled else {
            // Escape during finalization: `cancelDictation` could not see this session.
            revertLiveTypingIfSafe()
            liveTyping = nil
            return .interrupted
        }
        liveTyping = nil
        let decision = LiveTypingPolicy.decide(liveTypingConditions(for: session))
        guard decision == .write else {
            Self.liveTypingLog.notice("live typing not finalized: \(String(describing: decision), privacy: .public)")
            return .interrupted
        }
        guard let edit = session.planner.finalEdit(for: finalText) else {
            // The final contains a line break (spoken "new line", the Notes profile). As a key
            // event that is Return, which sends chat messages. Remove the live text and let the
            // ordinary paste deliver the whole transcript instead.
            return liveTyper.post(session.planner.revertEdit) ? nil : .interrupted
        }
        return liveTyper.post(edit) ? .typed : .interrupted
    }

    /// Escape: remove what this session typed, but only while it is provably still ours.
    private func revertLiveTypingIfSafe() {
        guard let session = liveTyping, session.abortReason == nil,
              !session.planner.typed.isEmpty,
              LiveTypingPolicy.decide(liveTypingConditions(for: session)) == .write
        else { return }
        _ = liveTyper.post(session.planner.revertEdit)
        liveTyping?.planner.commit(session.planner.revertEdit)
    }

    private func endLiveTyping() {
        liveTypingProbeTask?.cancel()
        liveTypingProbeTask = nil
        liveTyping = nil
    }

    /// Local calls only (no Accessibility IPC): cheap enough for every hypothesis.
    private func liveTypingConditions(for session: LiveTypingSession) -> LiveTypingConditions {
        LiveTypingConditions(
            userInputSinceStart: UserInputMonitor.shared.snapshot != session.inputBaseline,
            frontmostAppUnchanged: liveTyper.frontmostProcessIdentifier() == session.processIdentifier,
            secureInputEnabled: liveTyper.secureInputEnabled(),
            focus: session.focus,
            modifiersHeld: liveTyper.modifiersHeld()
        )
    }

    func toggleDictation() { handleActivate() }

    func cancelDictation() {
        guard state.isActive else { return }
        switch ConversationPolicy.cancel(
            conversationActive: conversation != nil, state: state,
            pendingSegments: conversation?.chain.pendingCount ?? 0
        ) {
        case .discardCurrentAndFinishPending:
            discardConversationSegmentAndFinish()
            return
        case .cancelNow, .ordinary:
            break
        }
        // Everything still queued in a conversation is abandoned with the rest; the running
        // inference (if any) is quarantined below exactly as for an ordinary dictation.
        conversation?.chain.cancelAll()
        clearConversation()
        let recoveryTaskToDiscard = pendingRecoveryTask
        discardDeferredSubmit(deferredSubmitToken)
        transcriptionTask?.cancel()
        isRevising = false
        revertLiveTypingIfSafe()
        closeIncrementalSession()
        replaceActiveInferenceAfterCancellation()
        pendingRecoveryTask = nil
        audio.cancel()
        recordingContext = nil
        rearmAudio()
        setState(.cancelled)
        discardRecoveryAfterExplicitCancellation(recoveryTaskToDiscard)
        scheduleHide(after: 0.0)
    }

    /// Toggle the idle pill's Dynamic-Island menu (Play / Quit). Only meaningful when idle.
    func togglePillMenu() {
        guard case .idle = state else { return }
        pillExpanded.toggle()
        syncCancelClaim()
        if pillExpanded {
            idleHideTask?.cancel()
            pill.show()
            collapseTask?.cancel()
            collapseTask = Task { [weak self] in
                // No Record/Quit tap within 2.5s → animate back to the normal pill.
                try? await Task.sleep(for: .seconds(2.5))
                guard let self, !Task.isCancelled else { return }
                self.collapsePillMenu()
            }
        } else {
            collapseTask?.cancel()
            armIdleHide()
        }
    }

    func collapsePillMenu() {
        collapseTask?.cancel()
        pillExpanded = false
        syncCancelClaim()
        armIdleHide()
    }

    /// Point at where the app lives. Called when onboarding finishes.
    func revealInMenuBar() {
        menuBar.revealMenu()
    }

    func setSettingsForeground(_ active: Bool) { pill.setSettingsForeground(active) }

    func openSettings() {
        collapsePillMenu()
        NSApp.activate(ignoringOtherApps: true)
        presentSettings?()
    }

    func quit() { NSApp.terminate(nil) }

    /// AppKit can keep the process alive while settings/history flush. Remove the active event tap
    /// before that wait so quitting can never leave an invisible Dictari in the keyboard path.
    func beginTermination() {
        guard !isTerminating else { return }
        isTerminating = true
        hideTask?.cancel()
        idleHideTask?.cancel()
        collapseTask?.cancel()
        hotkey.stop()
        hotkeyArmed = false
        pill.hide(force: true)
        syncLocalMCPServer()
    }

    /// Quitting while listening used to drop the recording on the floor (25 Sep 2026: a long
    /// dictation lost to a quit). Stop it normally so it is transcribed, recorded in History
    /// and copied, then let termination continue. Bounded so a stuck model cannot block quit.
    func finishDictationForTermination() async {
        if case .listening = state { stopDictation() }
        guard let task = transcriptionTask else { return }
        _ = await withTaskGroup(of: Void.self) { group in
            group.addTask { await task.value }
            group.addTask { try? await Task.sleep(for: .seconds(20)) }
            await group.next()
            group.cancelAll()
        }
    }

    /// A failed persistence flush keeps the app open; restore services only after the user elects
    /// to stay, never during the termination attempt itself.
    func cancelTermination() {
        guard isTerminating else { return }
        isTerminating = false
        ensureHotkey()
        pill.refresh()
        syncLocalMCPServer()
    }

    // MARK: - Helpers

    /// The pasteboard writer is infallible at this boundary. Callers still branch on the result
    /// (and keep recovery data when it is false) so a rejected write is never shown as success.
    private func writeClipboard(_ text: String) -> Bool {
        injector.copyToClipboard(text)
        return true
    }

    /// Close one generation-owned Return window without submitting. Calling this from a stale
    /// task is harmless: both the hotkey gate and the local token comparison reject it.
    private func discardDeferredSubmit(_ token: DeferredSubmitToken?) {
        guard let token else { return }
        hotkey.closeDeferredSubmitWindow(token)
        if deferredSubmitToken == token { deferredSubmitToken = nil }
    }

    /// Consume at most one Return pressed while transcription was pending. Synthetic input is
    /// emitted only after paste/type events were posted; clipboard-only fallbacks discard it.
    @discardableResult
    private func completeDeferredSubmit(
        _ token: DeferredSubmitToken?,
        inputWasPosted: Bool
    ) -> DeferredSubmitCompletion {
        guard let token else { return .noRequest }
        let completion = hotkey.completeDeferredSubmitWindow(
            token,
            inputWasPosted: inputWasPosted,
            replay: { [injector] keyCode in injector.synthesizeSubmitKey(keyCode) }
        )
        if deferredSubmitToken == token { deferredSubmitToken = nil }
        return completion
    }

    private func appendLevel(_ level: Float) {
        levels.append(level)
    }

    /// A bounded support snapshot with no transcript, clipboard or focused-app data.
    func diagnosticsSnapshot() -> LocalDiagnosticsSnapshot {
        LocalDiagnosticsSnapshot(
            distributionChannel: "Direct",
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                ?? "unknown",
            buildNumber: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
                ?? "unknown",
            automaticInsertionSupported: true,
            automaticInsertionEnabled: settings.data.autoPasteIntoFocus,
            accessibilityGranted: permissions.accessibility,
            microphoneGranted: permissions.microphone,
            hotkeyArmed: hotkeyArmed,
            modelState: diagnosticModelState,
            modelIdentifier: settings.activeModel.id,
            injectionMethod: permissions.accessibility
                ? settings.data.injectionMethod.rawValue
                : "clipboard",
            realtimeTranscriptionEnabled: settings.data.realtimeTranscriptionEnabled ?? false
        )
    }

    private var diagnosticModelState: String {
        switch modelState {
        case .idle: "idle"
        case .loading: "loading"
        case .ready: "ready"
        case .failed: "failed"
        }
    }

    private func recordOperationalDiagnostic(_ diagnosticState: LocalOperationalDiagnosticState) {
        let event = LocalOperationalDiagnosticEvent(
            recordedAt: Date(),
            state: diagnosticState,
            snapshot: diagnosticsSnapshot()
        )
        let diagnostics = diagnostics
        Task.detached(priority: .utility) {
            _ = try? await diagnostics.record(event)
        }
    }

    private func operationalDiagnosticState(
        for state: DictationState
    ) -> LocalOperationalDiagnosticState {
        switch state {
        case .idle: .idle
        case .listening: .listening
        case .transcribing: .transcribing
        case .success(.inserted): .inserted
        case .success(.pastedUnverified): .pastedUnverified
        case .success(.submitFailed): .submitFailed
        case .success(.copiedToClipboard): .copiedToClipboard
        case .error: .error
        case .cancelled: .cancelled
        }
    }

    private func setState(_ new: DictationState) {
        scheduledTransitionGate.invalidate()
        if new != .success(.copiedToClipboard) { copiedPillHoverPaused = false }
        if new != state || new != .success(.copiedToClipboard) {
            transcriptExpanded = false
        }
        if case .success = new { } else {
            pillWritingVisible = false
            pillWritingExpanded = false
            pillRefinement.clear()
        }
        let previous = state
        state = new
        if new != previous {
            recordOperationalDiagnostic(operationalDiagnosticState(for: new))
        }
        // A conversation's stop press delivers no transcript of its own to submit after, and
        // each pause is not a stop the user made: no Return reservation while one runs.
        hotkey.setDeferredSubmitOnStopEnabled(
            settings.data.autoPasteIntoFocus && new == .listening && conversation == nil
        )
        syncCancelClaim()
        modelLifecycleDidChange()
    }

    private func showSuccess(_ kind: DictationState.SuccessKind) {
        setState(.success(kind))
        if pillWritingVisible {
            if kind == .inserted { pillWritingStatus = Self.writingStatusInserted }
        } else {
            scheduleHide(after: SuccessFeedbackTiming.hideDelay(for: kind))
        }
    }

    /// Escape means "stop what the pill is doing": cancel a dictation, dismiss the copied
    /// transcript, or fold the idle menu. The tap only claims it while one of these applies.
    private func handleCancelShortcut() {
        switch CancelShortcutPolicy.target(state: state, idleMenuExpanded: pillExpanded) {
        case .cancelDictation: cancelDictation()
        case .dismissCopiedPill: dismissCopiedPill()
        case .collapseIdleMenu: collapsePillMenu()
        case .none: break
        }
    }

    /// The copied pill's ✕ and Escape. Hides immediately through the normal exit path.
    func dismissCopiedPill() {
        guard state == .success(.copiedToClipboard) else { return }
        copiedPillHoverPaused = false
        pillRefinement.cancel()
        scheduleHide(after: 0)
    }

    /// Reported by PillController when the pointer crosses the drawn pill's edge. Hovering the
    /// copied pill pauses its auto-hide so Copy/Expand/Close stay reachable; leaving re-arms it.
    func pillPointerDidChange(inside: Bool) {
        switch TranscriptPillPolicy.hoverAction(
            isCopiedState: state == .success(.copiedToClipboard),
            writingVisible: pillWritingVisible,
            pointerInside: inside,
            pausedByHover: copiedPillHoverPaused
        ) {
        case .pause:
            copiedPillHoverPaused = true
            hideTask?.cancel()
        case .resume:
            copiedPillHoverPaused = false
            scheduleHide(after: TranscriptPillPolicy.holdSeconds(
                transcriptExpanded: transcriptExpanded
            ))
        case .none:
            break
        }
    }

    /// The tap only claims the cancel shortcut while there is something to cancel — it
    /// defaults to a bare Escape, and holding that claim permanently would remove Escape
    /// from every other application on the machine. See `HotkeyManager.setDictating`.
    private func syncCancelClaim() {
        do {
            try hotkey.setDictating(CancelShortcutPolicy.claimsShortcut(
                state: state, idleMenuExpanded: pillExpanded
            ))
            if hotkeyArmed { hotkeyIssue = nil }
        } catch {
            hotkeyIssue = error.localizedDescription
        }
    }

    /// Called by PillController so the content and the window animate as one.
    func setPillVisible(_ visible: Bool) {
        guard pillVisible != visible else { return }
        pillVisible = visible
    }

    /// Available independently of pill visibility and history retention. This reuses only the
    /// transcript already kept in memory; copying never synthesizes input or changes focus.
    func copyLastTranscription() {
        guard !lastTranscript.isEmpty else { return }
        guard writeClipboard(lastTranscript) else {
            setState(.error(String(localized: "Copy failed — transcript remains in History", comment: "Pill error")))
            pill.show()
            // Every other error path retires itself; this one used to stay up indefinitely.
            scheduleHide(after: FeedbackTiming.errorHoldSeconds)
            return
        }
    }

    func clearTranscriptionHistory() {
        history.clear()
        lastTranscript = ""
        lastTranscriptUncertainty = nil
        // An explicit clear also retires the transient copy. Do not cancel an active recording
        // or transcription; its new result can populate the next entry when it finishes.
        if case .success = state {
            setState(.idle)
            scheduleHide(after: 0)
        }
    }

    /// The fallback already owns a clipboard copy, but an explicit repeat action gives the user
    /// visible certainty and also recovers from another app replacing the pasteboard meanwhile.
    func copyLastTranscriptFromPill() {
        guard state == .success(.copiedToClipboard), !lastTranscript.isEmpty else { return }
        guard writeClipboard(lastTranscript) else {
            setState(.error(String(localized: "Copy failed — transcript remains in History", comment: "Pill error")))
            pill.show()
            scheduleHide(after: FeedbackTiming.errorHoldSeconds)
            return
        }
        // The click itself happens under the pointer; keep the hover pause rather than
        // starting a countdown the user is still inside.
        guard !copiedPillHoverPaused else { return }
        scheduleHide(after: TranscriptPillPolicy.holdSeconds(transcriptExpanded: transcriptExpanded))
    }

    /// The conversation card's Copy: the whole conversation's unpasted text, not one segment.
    func copyConversationTranscript() {
        guard conversationActive, !conversationCopiedTranscript.isEmpty else { return }
        _ = writeClipboard(conversationCopiedTranscript)
    }

    func toggleTranscriptExpansion() {
        guard state == .success(.copiedToClipboard),
              TranscriptPillPolicy.canExpand(lastTranscript) else { return }
        transcriptExpanded.toggle()
        guard !copiedPillHoverPaused else { return }
        scheduleHide(after: TranscriptPillPolicy.holdSeconds(transcriptExpanded: transcriptExpanded))
    }

    private func scheduleHide(after delay: Double) {
        hideTask?.cancel()
        let transitionToken = scheduledTransitionGate.token
        hideTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard let self, !Task.isCancelled,
                  self.scheduledTransitionGate.isCurrent(transitionToken) else { return }
            if self.settings.data.alwaysShowPill {
                self.setState(.idle)
                self.armIdleHide()
            } else {
                // Fade the current presentation, then retire its state. Removing the card
                // first left an empty host, making the window's exit animation invisible.
                self.pill.hide()
                do { try await Task.sleep(for: .milliseconds(Int(Motion.pillExitMilliseconds))) }
                catch { return }
                guard !Task.isCancelled,
                      self.scheduledTransitionGate.isCurrent(transitionToken) else { return }
                self.setState(.idle)
            }
        }
    }

    /// Auto-hide the (idle) pill after 10s of inactivity so it never lingers.
    private func armIdleHide() {
        idleHideTask?.cancel()
        guard hotkeyArmed else { return }
        idleHideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, !Task.isCancelled, case .idle = self.state else { return }
            self.pill.hide(force: true)
        }
    }

    /// Rebuild the audio graph after a session so the next start is as cheap as the first.
    private func rearmAudio() {
        audio.prearm()
    }

    private func record(text: String, duration: Double, latency: Int, tag: String?, language: String? = nil,
                        uncertainSpans: [UncertainSpan]? = nil) {
        let words = text.split(whereSeparator: \.isWhitespace).count
        var language = language ?? settings.data.defaultLanguage
        // Record what was actually spoken, not the literal "auto": without it, drift towards
        // the wrong language could not even be measured from History.
        if SpokenLanguages.isAuto(language), !text.isEmpty,
           let detected = SpokenLanguages.detected(in: text, among: settings.data.effectiveSpokenLanguages) {
            language = detected
        }
        let entry = HistoryEntry(date: Date(), text: text, durationSeconds: duration,
                                 wordCount: words, latencyMs: latency,
                                 appName: sessionApp.name, appBundleID: sessionApp.bundleID,
                                 language: language, tag: tag,
                                 speechLevel: lastSpeechLevel, uncertainSpans: uncertainSpans)
        history.add(entry)
    }

    // MARK: - Conversation mode
    //
    // One shortcut press starts capture with auto-stop on silence forced on. Each pause hands the
    // finished segment to `deliverTranscription` (the same path as an ordinary stop: vocabulary,
    // spoken formatting, paste, History, recovery) and capture simply continues — the audio
    // engine is never stopped between turns, so nothing said right after a pause is lost and the
    // next turn costs no start-up time. Segments are delivered strictly in speaking order through
    // `OrderedSegmentChain`. The state stays `.listening` for the whole conversation; the next
    // press of any Dictari shortcut (or the pill's finish button) ends it, Escape discards the
    // turn in progress. Decisions are in `ConversationPolicy`.

    private func handleConversationShortcut() {
        switch ConversationPolicy.activation(.conversationShortcut, state: state,
                                             conversationActive: conversation != nil) {
        case .startConversation: startDictation(conversation: true)
        case .endConversation: endConversation()
        case .stopDictation: stopDictation()
        case .ordinary, .ignore: break
        }
    }

    private func handleAutoStop() {
        switch ConversationPolicy.autoStop(conversationActive: conversation != nil, state: state,
                                           captureContinues: audio.canCutSegment) {
        case .ordinary: stopDictation()
        case .deliverSegmentAndContinue: cutConversationSegment()
        case .endConversation: endConversation()
        }
    }

    /// A pause: hand over what was said and keep listening. Deliberately does no work beyond
    /// the cut itself and scheduling the segment, so capture of the next turn is never delayed.
    private func cutConversationSegment() {
        guard var session = conversation, state == .listening, let context = recordingContext else { return }
        let cutTime = ContinuousClock.now
        let samples = audio.cutSegment()
        lastSpeechLevel = audio.lastSpeechLevel
        let segmentStart = session.segmentStart
        let index = session.nextSegmentIndex
        session.segmentStart = cutTime
        session.nextSegmentIndex += 1
        conversation = session
        enqueueConversationSegment(samples: samples, from: segmentStart, to: cutTime,
                                   index: index, context: context, session: session)
        // The user may have moved to another app between turns. Ask a Chromium/Electron app for
        // its accessibility tree now, as recording start does, so the next turn's delivery-time
        // focus check sees a real text box. After the enqueue: it never delays this cut.
        if context.autoPasteIntoFocus { injector.prepareForDictation() }
    }

    /// The next shortcut press (or the finish button): deliver the turn in progress, play the
    /// stop cue once, and present the conversation's outcome after its last segment.
    private func endConversation() {
        guard var session = conversation, state == .listening else { return }
        let context = recordingContext
        recordingContext = nil
        // A tap-armed Return window cannot belong to any delivery here (see `setState`).
        if let stale = hotkey.claimDeferredSubmitWindow(openIfMissing: false) {
            hotkey.closeDeferredSubmitWindow(stale)
        }
        let stopTime = ContinuousClock.now
        let samples = audio.stop()
        lastSpeechLevel = audio.lastSpeechLevel
        closeIncrementalSession()
        // As in `stopDictation`: rebuild the graph on a later turn, off the stop→inject path.
        Task { self.rearmAudio() }
        playStopSound()
        let index = session.nextSegmentIndex
        session.nextSegmentIndex += 1
        conversation = session
        if let context {
            enqueueConversationSegment(samples: samples, from: session.segmentStart, to: stopTime,
                                       index: index, context: context, session: session)
        }
        finishConversationAfterPendingSegments(session)
    }

    /// Escape while a conversation listens: the turn in progress is discarded; turns that already
    /// reached their pause are the user's finished words and still land.
    private func discardConversationSegmentAndFinish() {
        guard let session = conversation else { return }
        recordingContext = nil
        if let stale = hotkey.claimDeferredSubmitWindow(openIfMissing: false) {
            hotkey.closeDeferredSubmitWindow(stale)
        }
        audio.cancel()
        closeIncrementalSession()
        rearmAudio()
        finishConversationAfterPendingSegments(session)
    }

    private func finishConversationAfterPendingSegments(_ session: ConversationSession) {
        guard session.chain.pendingCount > 0 else {
            presentConversationEnd(session.id)
            return
        }
        // Capture is over; the pill shows the remaining turns being delivered, and the busy
        // state keeps a new dictation from overlapping them on the engine.
        setState(.transcribing)
        let id = session.id
        transcriptionTask = session.chain.enqueue { [weak self] in
            guard !Task.isCancelled else { return }
            self?.presentConversationEnd(id)
        }
    }

    private func enqueueConversationSegment(
        samples: [Float],
        from start: ContinuousClock.Instant,
        to stop: ContinuousClock.Instant,
        index: Int,
        context: RecordingTranscriptionContext,
        session: ConversationSession
    ) {
        let recorded = start.duration(to: stop).components
        let duration = Double(recorded.seconds) + Double(recorded.attoseconds) / 1e18
        var maxAmp: Float = 0
        if !samples.isEmpty {
            vDSP_maxmgv(samples, 1, &maxAmp, vDSP_Length(samples.count))
        }
        let filter = settings.data.proximityFilter ?? .off
        guard ConversationPolicy.segmentDisposition(
            duration: duration, peak: maxAmp, speechLevel: lastSpeechLevel,
            minimumSpeechLevel: filter.minimumSpeechLevel
        ) == .transcribe else { return }

        // Same safety copy as an ordinary stop, started now so it overlaps the wait for
        // earlier segments rather than the inference.
        let recoveryTask = saveRecovery(samples: samples, duration: duration,
                                        language: context.language, modelID: context.modelID)
        let job = DeliveryJob(
            role: .conversationSegment(conversationID: session.id, index: index),
            context: context, samples: samples, duration: duration, stopTime: stop,
            shouldAutoPaste: context.autoPasteIntoFocus && !isTerminating,
            submitToken: nil, recoveryTask: recoveryTask,
            backgroundSession: nil, streamingSession: nil, recordingInference: nil,
            stageTiming: nil
        )
        transcriptionTask = session.chain.enqueue { [weak self] in
            await self?.deliverTranscription(job)
        }
    }

    /// Checked by each segment when its turn in the chain comes, not when it was captured:
    /// an earlier segment may have timed out and quarantined the engine meanwhile.
    private func conversationEngineIsUsable(for context: RecordingTranscriptionContext,
                                            conversationID: UUID) -> Bool {
        guard let session = conversation, session.id == conversationID, !session.engineRetired else {
            return false
        }
        let sameEngineIsReady = modelState == .ready
            && Self.engineID(transcriber) == Self.engineID(context.engine)
        return activeInference == nil
            && quarantinedInferenceGeneration == nil
            && Self.engineID(transcriber) == Self.engineID(context.engine)
            && RecordingReadiness.isReady(wasReadyAtStart: context.modelWasReadyAtStart,
                                          sameEngineIsReadyAtStop: sameEngineIsReady)
    }

    private func conversationSegmentFinished(_ segment: (conversationID: UUID, index: Int),
                                             result: ConversationSegmentResult) {
        guard var session = conversation, session.id == segment.conversationID else { return }
        session.outcome.record(result, index: segment.index)
        conversation = session
        if case .delivered(.copiedToClipboard, _) = result { publishConversationTranscript() }
    }

    /// A posted paste that AX later proved did not land.
    private func conversationSegmentDidNotLand(_ segment: (conversationID: UUID, index: Int),
                                               text: String) {
        guard var session = conversation, session.id == segment.conversationID else {
            // The conversation already ended and presented: behave like an ordinary late failed
            // paste, reopening the pill with Copy unless something newer owns it.
            switch state {
            case .success(.pastedUnverified), .success(.inserted), .idle: break
            default: return
            }
            lastTranscript = text
            lastTranscriptUncertainty = nil
            _ = writeClipboard(text)
            pill.show()
            showSuccess(.copiedToClipboard)
            return
        }
        session.outcome.recordFailedLanding(text, index: segment.index)
        conversation = session
        publishConversationTranscript()
    }

    /// Keeps the clipboard holding the whole unpasted conversation, not only its latest turn,
    /// and grows the pill card with it.
    private func publishConversationTranscript() {
        guard let session = conversation else { return }
        let text = session.outcome.copiedTranscript.text
        guard text != conversationCopiedTranscript else { return }
        conversationCopiedTranscript = text
        lastTranscript = text
        lastTranscriptUncertainty = nil
        _ = writeClipboard(text)
    }

    private func conversationSegmentFailed(_ segment: (conversationID: UUID, index: Int),
                                           recoveryTask: Task<UUID?, Never>,
                                           message: String, endsConversation: Bool) {
        // The retryable copy is kept and labelled, as `finishWithSavedRecovery` does, but the
        // listening state is left alone: the conversation reports failures once, at its end.
        Task { @MainActor [weak self] in
            guard let id = await recoveryTask.value else { return }
            let recovery = await Self.updateRecovery(
                id, state: .transcriptionFailed, description: message, transcript: nil
            )
            guard let self else { return }
            if let recovery { self.upsertRecovery(recovery) } else { self.refreshRecoveries() }
        }
        guard var session = conversation, session.id == segment.conversationID else { return }
        session.outcome.record(.failed(DictationRecovery.localizedFailureDescription(message)), index: segment.index)
        if endsConversation { session.engineRetired = true }
        conversation = session
        if endsConversation, state == .listening { endConversation() }
    }

    private func presentConversationEnd(_ id: UUID) {
        guard let session = conversation, session.id == id else { return }
        clearConversation()
        switch ConversationPolicy.endPresentation(session.outcome) {
        case .copied(let text):
            lastTranscript = text
            lastTranscriptUncertainty = nil
            showSuccess(.copiedToClipboard)
            // Open where the conversation card left off: a long transcript stays expanded,
            // with the expanded hold, instead of collapsing to its first line.
            if TranscriptPillPolicy.canExpand(text) {
                transcriptExpanded = true
                scheduleHide(after: TranscriptPillPolicy.holdSeconds(transcriptExpanded: true))
            }
        case .success(let kind):
            showSuccess(kind)
        case .error(let message):
            setState(.error(message))
            scheduleHide(after: FeedbackTiming.errorHoldSeconds)
        case .quiet:
            setState(.idle)
            scheduleHide(after: 0)
        }
    }

    private func clearConversation() {
        conversation = nil
        conversationActive = false
        conversationCopiedTranscript = ""
    }

    // MARK: - Inference isolation

    private static func engineID(_ engine: any TranscriptionEngine) -> ObjectIdentifier {
        ObjectIdentifier(engine)
    }

    private func beginInference(engine: (any TranscriptionEngine)? = nil) -> ActiveInference {
        nextInferenceGeneration &+= 1
        let active = ActiveInference(engine: engine ?? transcriber,
                                     generation: nextInferenceGeneration)
        activeInference = active
        return active
    }

    /// Returns false for an orphaned callback after cancellation, timeout or model replacement.
    @discardableResult
    private func finishInference(_ inference: ActiveInference) -> Bool {
        guard let activeInference,
              activeInference.generation == inference.generation,
              Self.engineID(activeInference.engine) == Self.engineID(inference.engine)
        else { return false }
        self.activeInference = nil
        finalizedInferenceGeneration = max(finalizedInferenceGeneration, inference.generation)
        finishedInferenceOperations.remove(inference.generation)
        modelLifecycleDidChange()
        return true
    }

    private func replaceActiveInferenceAfterCancellation() {
        guard let activeInference else { return }
        quarantineInference(activeInference)
    }

    @discardableResult
    private func replaceTimedOutInference(_ inference: ActiveInference) -> Bool {
        guard let activeInference,
              activeInference.generation == inference.generation,
              Self.engineID(activeInference.engine) == Self.engineID(inference.engine)
        else { return false }
        quarantineInference(inference)
        return true
    }

    /// A native backend can ignore Swift cancellation. Keep at most one such call alive and do
    /// not allocate/warm another model until the operation's detached task really returns.
    private func quarantineInference(_ inference: ActiveInference) {
        activeInference = nil
        if finishedInferenceOperations.remove(inference.generation) != nil {
            finalizedInferenceGeneration = max(finalizedInferenceGeneration, inference.generation)
            rebuildEngineAfterQuarantine()
            return
        }
        quarantinedInferenceGeneration = inference.generation
        modelState = .failed(String(localized: "Transcription engine is finishing cancelled work",
                                    comment: "Status while a cancelled transcription is still running"))
    }

    /// Called by the detached native-operation task, not by the deadline race. A callback may
    /// arrive just before the timeout handler, so remember that ordering and let quarantine
    /// consume it synchronously instead of getting stuck in a false busy state.
    private func inferenceOperationDidFinish(_ generation: UInt) {
        guard generation > finalizedInferenceGeneration else { return }
        if quarantinedInferenceGeneration == generation {
            quarantinedInferenceGeneration = nil
            finalizedInferenceGeneration = generation
            rebuildEngineAfterQuarantine()
        } else {
            finishedInferenceOperations.insert(generation)
        }
    }

    private func rebuildEngineAfterQuarantine() {
        // Arm the obligation before draining: a synchronous candidate commit clears it, while an
        // in-flight preparation keeps it latched without starting a competing warm-up.
        _ = quarantineReplacementGate.quarantineReleased()
        modelLifecycleDidChange()
    }

    private func performQuarantineReplacement(_ command: QuarantineModelReplacementGate.Command) {
        guard command == .rebuildActive else { return }
        // Never reuse an engine after cancellation/timeout: a native decoder may have left
        // mutable state half-finished. Rebuild only now, after its operation released PCM/model.
        let descriptor = settings.activeModel
        let replacement = Self.makeEngine(for: descriptor)
        transcriber = replacement
        quarantineRebuildTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.warmModel(replacement)
            self.quarantineRebuildTask = nil
            self.modelLifecycleDidChange()
        }
    }

    private static func isTimeout(_ error: Error) -> Bool {
        guard let error = error as? TranscriptionError else { return false }
        if case .timedOut = error { return true }
        return false
    }

    // MARK: - Recovery

    /// Start saving the original PCM before inference so a model failure still leaves a retryable
    /// capture. Disk work stays off the main actor and overlaps inference; every terminal outcome
    /// joins the atomic commit before it claims whether the safety copy exists.
    private func saveRecovery(samples: [Float], duration: Double, language: String,
                              modelID: String) -> Task<UUID?, Never> {
        let app = sessionApp
        return Task.detached(priority: .userInitiated) {
            guard let recovery = try? DictationRecoveryStore(rootURL: AppPaths.recoveries).save(
                samples: samples,
                durationSeconds: duration,
                language: language,
                modelID: modelID,
                appName: app.name,
                appBundleID: app.bundleID,
                state: .transcriptionFailed,
                failureDescription: "Transcription did not finish"
            ) else { return nil }
            return recovery.id
        }
    }

    /// Error paths wait for persistence because their user-facing outcome must accurately say
    /// whether a retryable copy was saved. The task is often already complete on inference errors.
    /// The pill only has room for a few words, so a saved copy is implied (it is the normal case,
    /// visible in History) and only a failed save gets its own message.
    private func finishWithSavedRecovery(_ task: Task<UUID?, Never>, message: String) {
        transcriptionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.pendingRecoveryTask = nil
            }
            guard let id = await task.value, !Task.isCancelled else {
                if !Task.isCancelled {
                    self.setState(.error(String(localized: "Recording couldn't be saved", comment: "Pill error")))
                    self.scheduleHide(after: 2.5)
                }
                return
            }
            let recovery = await Self.updateRecovery(
                id, state: .transcriptionFailed, description: message, transcript: nil
            )
            guard !Task.isCancelled else { return }
            if let recovery { self.upsertRecovery(recovery) } else { self.refreshRecoveries() }
            // `message` is persisted in English (see `DictationRecovery.displayFailureDescription`).
            self.setState(.error(DictationRecovery.localizedFailureDescription(message)))
            self.scheduleHide(after: FeedbackTiming.errorHoldSeconds)
        }
    }

    /// Persist an unverified/blocked delivery after the success UI. The original PCM remains
    /// until a confirmed delivery explicitly removes it.
    @discardableResult
    private func markRecoveryOutcome(
        _ task: Task<UUID?, Never>,
        description: String,
        transcript: String
    ) -> Task<UUID?, Never> {
        Task { @MainActor [weak self] in
            guard let self, let id = await task.value else { return nil }
            let recovery = await Self.updateRecovery(
                id,
                state: .injectionFailed,
                description: description,
                transcript: transcript
            )
            guard let recovery else {
                // The original PCM is already durable. If this metadata transition fails, leave
                // it in the recovery list instead of claiming the safety copy was lost.
                self.refreshRecoveries()
                return id
            }
            // The upsert already reflects the only record this transition changed; a full
            // re-list here decoded every metadata file on each unverified delivery.
            self.upsertRecovery(recovery)
            return id
        }
    }

    /// A confirmed normal delivery is the only automatic removal. Interrupted sessions never
    /// call this, so their initial `.transcriptionFailed` record remains recoverable.
    private func deleteSavedRecovery(_ task: Task<UUID?, Never>?) {
        guard let task else { return }
        Task { @MainActor [weak self] in
            guard let self, let id = await task.value else { return }
            if await Self.deleteRecovery(id) {
                self.removeRecoveryFromSnapshot(id)
            } else {
                self.refreshRecoveries()
            }
        }
    }

    /// Escape is an explicit discard command in the product contract. The safety write may already
    /// be committing off-main, so join it and remove the finished record rather than merely dropping
    /// our task reference and leaving hidden PCM until the next launch.
    private func discardRecoveryAfterExplicitCancellation(_ task: Task<UUID?, Never>?) {
        guard let task else { return }
        Task { @MainActor [weak self] in
            guard let self, let id = await task.value else { return }
            if await Self.deleteRecovery(id) {
                self.removeRecoveryFromSnapshot(id)
            } else {
                // If deletion fails, surface the still-durable capture instead of hiding it.
                self.refreshRecoveries()
            }
        }
    }

    /// Reloaded on launch and after a failed filesystem operation. Metadata only; PCM stays on
    /// disk until the user retries a specific recovery. The same off-main scan applies the
    /// retention policy, so launch trims transcribed recordings without a second directory pass.
    private func refreshRecoveries() {
        recoveryLoadGeneration &+= 1
        let generation = recoveryLoadGeneration
        let protected = Set([retryingRecoveryID].compactMap { $0 })
        Task { @MainActor [weak self] in
            let listing = await Self.loadRecoveries(protecting: protected)
            guard let self, self.recoveryLoadGeneration == generation else { return }
            self.recoveries = listing.recoveries
            self.recoveryLoadWarning = listing.warning
            self.recoveriesRevision &+= 1
        }
    }

    private func upsertRecovery(_ recovery: DictationRecovery) {
        recoveriesRevision &+= 1
        recoveries.removeAll { $0.id == recovery.id }
        recoveries.insert(recovery, at: 0)
        recoveries.sort { $0.createdAt > $1.createdAt }
        pruneRecoveriesAfterUpsert(keeping: recovery.id)
    }

    /// Unverified deliveries (Terminal, Electron) add a recording per dictation. Decide from the
    /// in-memory snapshot — it mirrors disk since launch — and delete off-main; rows leave the
    /// snapshot only once their directory is actually gone. The record just written and one being
    /// retried are protected so an action on an old recording never deletes it underneath the user.
    private func pruneRecoveriesAfterUpsert(keeping id: UUID) {
        let protected = Set([id, retryingRecoveryID].compactMap { $0 })
        let prune = DictationRecoveryRetentionPolicy.idsToPrune(recoveries, now: Date(), protecting: protected)
        guard !prune.isEmpty else { return }
        Task { @MainActor [weak self] in
            let removed = await Self.deleteRecoveries(prune)
            guard let self, !removed.isEmpty else { return }
            let removedSet = Set(removed)
            self.recoveriesRevision &+= 1
            self.recoveries.removeAll { removedSet.contains($0.id) }
        }
    }

    private func removeRecoveryFromSnapshot(_ id: UUID) {
        recoveriesRevision &+= 1
        recoveries.removeAll { $0.id == id }
    }

    func deleteRecovery(_ recovery: DictationRecovery) {
        Task { @MainActor [weak self] in
            guard await Self.deleteRecovery(recovery.id) else { return }
            self?.removeRecoveryFromSnapshot(recovery.id)
        }
    }

    func retryRecovery(_ recovery: DictationRecovery) {
        guard !mediaLibrary.isBusy, recovery.state != .metadataDamaged,
              retryingRecoveryID == nil,
              case .idle = state,
              activeInference == nil,
              quarantinedInferenceGeneration == nil,
              case .ready = modelState else { return }
        let retryStart = ContinuousClock.now
        hideTask?.cancel()
        idleHideTask?.cancel()
        collapseTask?.cancel()
        activeDeliveryRecoveryID = nil
        pillExpanded = false
        retryingRecoveryID = recovery.id
        setState(.transcribing)
        pill.show()
        transcriptionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.retryingRecoveryID = nil
                self.transcriptionTask = nil
            }
            guard let payload = await Self.loadRecovery(recovery.id) else {
                self.refreshRecoveries()
                if !Task.isCancelled {
                    self.setState(.error(String(localized: "Saved recording unavailable", comment: "Pill error")))
                    self.scheduleHide(after: FeedbackTiming.errorHoldSeconds)
                }
                return
            }
            guard !Task.isCancelled else { return }
            let activeInference = self.beginInference()
            let engine = activeInference.engine
            do {
                let generation = activeInference.generation
                let output = try await TranscriptionDeadline.run(
                    for: .seconds(30),
                    onOperationFinished: { [weak self] in
                        Task { @MainActor [weak self] in
                            self?.inferenceOperationDidFinish(generation)
                        }
                    }
                ) {
                    try await engine.transcribeDetailed(
                        samples: payload.samples, language: payload.recovery.language
                    )
                }
                guard !Task.isCancelled, self.finishInference(activeInference) else { return }
                let confidenceCorrection = self.vocabulary.corrector.correct(output)
                let trimmed = confidenceCorrection.text
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    let updated = await Self.updateRecovery(
                        recovery.id, state: .transcriptionFailed,
                        description: "No speech detected", transcript: payload.recovery.transcript
                    )
                    guard !Task.isCancelled else { return }
                    if let updated {
                        self.upsertRecovery(updated)
                    }
                    self.setState(.error(String(localized: "No speech detected", comment: "Dictation failure: nothing was said")))
                    self.scheduleHide(after: FeedbackTiming.errorHoldSeconds)
                    return
                }
                guard let updated = await Self.markTranscribed(recovery.id, transcript: trimmed) else {
                    self.setState(.error(String(localized: "Couldn't save recovered text", comment: "Pill error")))
                    self.scheduleHide(after: FeedbackTiming.errorHoldSeconds)
                    return
                }
                guard !Task.isCancelled else { return }
                self.upsertRecovery(updated)
                let elapsed = retryStart.duration(to: .now).components
                let retryLatency = Int(elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000)
                let recoveredSpans = output.hasConfidence
                    ? UncertainSpan.locate(confidenceCorrection.uncertainWords, in: trimmed)
                    : nil
                self.recordRecoveredText(
                    trimmed, from: payload.recovery, latency: retryLatency,
                    uncertainSpans: recoveredSpans
                )
                guard self.writeClipboard(trimmed) else {
                    let failed = await Self.updateRecovery(
                        recovery.id,
                        state: .injectionFailed,
                        description: "Clipboard write failed",
                        transcript: trimmed
                    )
                    guard !Task.isCancelled else { return }
                    if let failed { self.upsertRecovery(failed) }
                    self.setState(.error(String(localized: "Copy failed — transcript saved in History", comment: "Pill error")))
                    self.scheduleHide(after: FeedbackTiming.errorHoldSeconds)
                    return
                }
                self.lastTranscript = trimmed
                self.lastTranscriptUncertainty = recoveredSpans.map { UncertainTranscript(text: trimmed, spans: $0) }
                self.showSuccess(.copiedToClipboard)
                // The failed dictation is now represented by durable text in History and on the
                // clipboard. Keep PCM only if deletion itself fails; it no longer needs to be a
                // permanent duplicate after a successful recovery.
                if await Self.deleteRecovery(recovery.id) {
                    self.removeRecoveryFromSnapshot(recovery.id)
                }
            } catch {
                guard !Task.isCancelled else { return }
                if Self.isTimeout(error) {
                    guard self.replaceTimedOutInference(activeInference) else { return }
                } else if !self.finishInference(activeInference) {
                    return
                }
                let updated = await Self.updateRecovery(
                    recovery.id, state: .transcriptionFailed,
                    description: error.localizedDescription, transcript: payload.recovery.transcript
                )
                guard !Task.isCancelled else { return }
                if let updated {
                    self.upsertRecovery(updated)
                }
                self.setState(.error(error.localizedDescription))
                self.scheduleHide(after: FeedbackTiming.errorHoldSeconds)
            }
        }
    }

    private func recordRecoveredText(
        _ text: String,
        from recovery: DictationRecovery,
        latency: Int,
        uncertainSpans: [UncertainSpan]? = nil
    ) {
        let entry = HistoryEntry(
            date: recovery.createdAt, text: text, durationSeconds: recovery.durationSeconds,
            wordCount: text.split(whereSeparator: \.isWhitespace).count, latencyMs: latency,
            appName: recovery.appName, appBundleID: recovery.appBundleID,
            language: recovery.language, tag: nil, speechLevel: nil,
            uncertainSpans: uncertainSpans
        )
        history.add(entry)
    }

    private nonisolated static func loadRecoveries(protecting protected: Set<UUID>) async -> DictationRecoveryListing {
        await Task.detached(priority: .utility) {
            do {
                let recoveries = try DictationRecoveryStore(rootURL: AppPaths.recoveries)
                    .applyRetention(protecting: protected).remaining
                return DictationRecoveryListing(recoveries: recoveries, warning: nil)
            } catch {
                return DictationRecoveryListing(
                    recoveries: [],
                    warning: String(localized: "Recovery recordings could not be read. No saved audio was deleted.",
                                    comment: "Load warning")
                )
            }
        }.value
    }

    private nonisolated static func loadRecovery(_ id: UUID) async -> DictationRecoveryPayload? {
        await Task.detached(priority: .utility) {
            try? DictationRecoveryStore(rootURL: AppPaths.recoveries).load(id)
        }.value
    }

    private nonisolated static func updateRecovery(
        _ id: UUID,
        state: DictationRecoveryState,
        description: String,
        transcript: String?
    ) async -> DictationRecovery? {
        await Task.detached(priority: .utility) {
            try? DictationRecoveryStore(rootURL: AppPaths.recoveries).update(
                id, state: state, failureDescription: description, transcript: transcript
            )
        }.value
    }

    private nonisolated static func markTranscribed(
        _ id: UUID,
        transcript: String
    ) async -> DictationRecovery? {
        await Task.detached(priority: .utility) {
            try? DictationRecoveryStore(rootURL: AppPaths.recoveries)
                .markTranscribed(id, transcript: transcript)
        }.value
    }

    private nonisolated static func deleteRecoveries(_ ids: [UUID]) async -> [UUID] {
        await Task.detached(priority: .utility) {
            guard let store = try? DictationRecoveryStore(rootURL: AppPaths.recoveries) else { return [] }
            return store.delete(ids)
        }.value
    }

    private nonisolated static func deleteRecovery(_ id: UUID) async -> Bool {
        await Task.detached(priority: .utility) {
            guard let store = try? DictationRecoveryStore(rootURL: AppPaths.recoveries) else { return false }
            do {
                try store.delete(id)
                return true
            } catch {
                return false
            }
        }.value
    }

    // Pre-loaded, pooled earcons. See SoundCues for why this is not `NSSound(named:)?.play()`:
    // that hands back one shared instance, so back-to-back dictations silently lost their cue.
    private func playStartSound() { cues.playStart() }
    private func playStopSound() { cues.playStop() }
}

/// Optional per-dictation timing. Only monotonic instants and closed outcomes are retained;
/// formatting/logging happens in one utility task after the delivery path has returned.
/// Set DICTARI_STAGE_TIMING=1 before launch to collect these local, content-free records.
private struct DictationStageTiming: Sendable {
    enum Outcome: String, Sendable {
        case interrupted, liveInserted, pasteCallReturned, submitFailed, clipboard
        case inferenceTimeout, failed
    }

    static let enabled = ProcessInfo.processInfo.environment["DICTARI_STAGE_TIMING"] == "1"
    private static let log = Logger(subsystem: "com.dictari.app", category: "dictation-stage-timing")

    let activationAt: ContinuousClock.Instant?
    let startAt: ContinuousClock.Instant
    var pillShowReturnedAt: ContinuousClock.Instant?
    var stopAt: ContinuousClock.Instant?
    var stopTargetSnapshotReturnedAt: ContinuousClock.Instant?
    var audioStoppedAt: ContinuousClock.Instant?
    var inferenceTaskStartedAt: ContinuousClock.Instant?
    var inferenceAwaitStartedAt: ContinuousClock.Instant?
    var transcriptReadyAt: ContinuousClock.Instant?
    var stopTargetWaitStartedAt: ContinuousClock.Instant?
    var stopTargetReadyAt: ContinuousClock.Instant?
    var deliveryReturnedAt: ContinuousClock.Instant?
    var feedbackReturnedAt: ContinuousClock.Instant?

    private static func milliseconds(
        from start: ContinuousClock.Instant?,
        to end: ContinuousClock.Instant?
    ) -> Int {
        guard let start, let end else { return -1 }
        let components = start.duration(to: end).components
        return Int(components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000)
    }

    func emitDelivery(mode: RecordingTranscriptionMode, outcome: Outcome) {
        let modeName: String = switch mode {
        case .batch: "batch"
        case .background: "background-finalization"
        case .realtime: "realtime-finalization"
        }
        let outcomeName = outcome.rawValue
        let handlerToPillShowReturn = Self.milliseconds(from: activationAt, to: pillShowReturnedAt)
        let startToPillShowReturn = Self.milliseconds(from: startAt, to: pillShowReturnedAt)
        let stopToSnapshotReturn = Self.milliseconds(from: stopAt, to: stopTargetSnapshotReturnedAt)
        let stopToAudioStopped = Self.milliseconds(from: stopAt, to: audioStoppedAt)
        let audioStoppedToInferenceTask = Self.milliseconds(from: audioStoppedAt, to: inferenceTaskStartedAt)
        let stopToInferenceAwait = Self.milliseconds(from: stopAt, to: inferenceAwaitStartedAt)
        let inferenceAwait = Self.milliseconds(from: inferenceAwaitStartedAt, to: transcriptReadyAt)
        let afterASRTargetWait = Self.milliseconds(from: stopTargetWaitStartedAt, to: stopTargetReadyAt)
        let transcriptReadyToDeliveryReturn = Self.milliseconds(from: transcriptReadyAt, to: deliveryReturnedAt)
        let stopToDeliveryReturn = Self.milliseconds(from: stopAt, to: deliveryReturnedAt)
        let stopToFeedbackReturn = Self.milliseconds(from: stopAt, to: feedbackReturnedAt)

        Task.detached(priority: .utility) {
            Self.log.notice(
                "mode=\(modeName, privacy: .public) outcome=\(outcomeName, privacy: .public) handlerToPillShowReturnMs=\(handlerToPillShowReturn, privacy: .public) startToPillShowReturnMs=\(startToPillShowReturn, privacy: .public) stopToSnapshotReturnMs=\(stopToSnapshotReturn, privacy: .public) stopToAudioStoppedMs=\(stopToAudioStopped, privacy: .public) audioStoppedToInferenceTaskMs=\(audioStoppedToInferenceTask, privacy: .public) stopToInferenceAwaitMs=\(stopToInferenceAwait, privacy: .public) inferenceOrFinalizationAwaitMs=\(inferenceAwait, privacy: .public) afterASRTargetWaitMs=\(afterASRTargetWait, privacy: .public) transcriptReadyToDeliveryReturnMs=\(transcriptReadyToDeliveryReturn, privacy: .public) stopToDeliveryReturnMs=\(stopToDeliveryReturn, privacy: .public) stopToFeedbackReturnMs=\(stopToFeedbackReturn, privacy: .public)"
            )
        }
    }

    /// The coordinator observes this only after its recovery write; it is not the exact time
    /// at which the target app consumed the paste or the AX verification itself completed.
    func emitReceiptObserved(at observedAt: ContinuousClock.Instant, outcome: InjectionVerificationOutcome) {
        let outcomeName: String = switch outcome {
        case .confirmed: "confirmed"
        case .unobservable: "unobservable"
        case .failed: "failed"
        }
        let deliveryReturnToReceiptObserved = Self.milliseconds(from: deliveryReturnedAt, to: observedAt)
        let stopToReceiptObserved = Self.milliseconds(from: stopAt, to: observedAt)
        Task.detached(priority: .utility) {
            Self.log.notice(
                "receiptOutcome=\(outcomeName, privacy: .public) deliveryReturnToReceiptObservedAfterPersistenceMs=\(deliveryReturnToReceiptObserved, privacy: .public) stopToReceiptObservedAfterPersistenceMs=\(stopToReceiptObserved, privacy: .public)"
            )
        }
    }
}
