import AppKit
import Carbon.HIToolbox
import CoreGraphics
import os

/// Global hotkey monitor backed by a `CGEventTap`.
///
/// Installs a session-level event tap that observes `keyDown`, `keyUp`, and
/// `flagsChanged` events (plus mouse-button downs, observed only to tell a bare modifier tap
/// from a modifier-click), matches them against the configured dictation and
/// cancel shortcuts, and routes activation/deactivation/cancel callbacks onto
/// the `MainActor`. When an event matches a shortcut it is swallowed (the tap
/// callback returns `nil`) so the underlying keystroke (e.g. ⌥Space) does not
/// also reach the focused app.
///
/// A `CGEventTap` requires Accessibility permission; `start()` throws if the
/// tap cannot be created (permission missing, or the system refused the tap).
///
/// ## Concurrency
/// The C tap callback runs in a `nonisolated`, non-Swift-actor context and
/// cannot capture `self`. We bridge via the callback's `userInfo` pointer
/// (an `Unmanaged.passRetained` to a `RoutingBox`). The callback:
///  1. reads raw key code / flags from the `CGEvent` (thread-safe getters),
///  2. consults a lock-protected `ShortcutSnapshot` to decide *synchronously*
///     whether to swallow the event (returning `nil`),
///  3. hops to the `MainActor` to invoke the `onX` side-effect closures — but
///     only for the handful of events that actually match a shortcut.
///
/// The synchronous swallow decision touches only the `Sendable`, lock-guarded
/// snapshot — never the `MainActor`-isolated manager — so it is race-free.
///
/// ## Why this path must never block
/// This is an active tap in the input path of every keystroke on the machine:
/// the window server holds each event until the callback returns, and it
/// silently disables a tap that overruns its timeout. Three rules keep a
/// system-wide typing freeze structurally impossible, and all three are load
/// bearing — see the comments at each site before changing them:
///  - the callback never waits on anything the rest of the app can hold, and
///    for an unrelated keystroke does no allocation at all;
///  - the tap is serviced on its own `userInteractive` thread, so inference
///    cannot invert its priority, and the process holds an App Nap opt-out for
///    as long as the tap is installed;
///  - a disable notification is re-armed on the tap thread; the independent
///    watchdog can rebuild dead transport, but the callback never waits on `MainActor`.
@MainActor
final class HotkeyManager {

    private static let log = Logger(subsystem: "com.subralabs.Dictari", category: "hotkey")

    // MARK: Public API

    /// Interaction mode. In `.pushToTalk`, the dictation shortcut's keyUp fires
    /// `onDeactivate`. In `.toggle`, keyUp is ignored.
    var mode: InteractionMode = .toggle {
        didSet {
            guard mode != oldValue else { return }
            refreshSnapshot()
            // A half-finished modifier gesture or hold belongs to the old mode. Not done on
            // every snapshot refresh: `setDictating` refreshes mid-hold, and resetting there
            // would forget the push-to-talk hold that just started the session.
            currentRoutingBox?.modifierGesture.reset()
            endPushToTalkHold()
        }
    }

    /// Fired on dictation-shortcut keyDown (MainActor). A modifier-only shortcut fires on the
    /// release of a bare tap in toggle mode, and on the press in push-to-talk.
    var onActivate: (() -> Void)?
    var onRevisionActivate: (() -> Void)?
    private var revisionChordOwnsModifiers = false
    /// Fired on the conversation shortcut's keyDown (MainActor). Always a toggle: its release
    /// never routes, whatever the interaction mode. Holding a key for a whole conversation
    /// would defeat the mode.
    var onConversationActivate: (() -> Void)?

    /// Fired on dictation-shortcut keyUp, only in `.pushToTalk` mode (MainActor) — or when the
    /// physical-key poll finds the key already up because the tap never saw its release.
    var onDeactivate: (() -> Void)?

    /// Fired on cancel-shortcut keyDown (MainActor). Also fired when a modifier-only
    /// push-to-talk press that started a session turns out to be a chord (⌘C): that session
    /// must be discarded, not transcribed — exactly what cancel does.
    var onCancel: (() -> Void)?

    /// Reflects whether the shortcut can currently receive events. Secure Event Input is a
    /// legitimate unavailable state: Dictari reports it and waits rather than trying to bypass it.
    var onAvailabilityChanged: ((Bool) -> Void)?
    private(set) var isAvailable = false

    init() {
        self.dictationShortcut = .defaultDictation
        self.cancelShortcut = .escape
        refreshSnapshot()
    }

    deinit {
        // Tear down any leaked C handles. We only touch local C handles and the
        // retained routing box here — never MainActor-isolated Swift state —
        // which keeps this deinit valid under strict concurrency.
        watchdogTask?.cancel()
        diagnosticsTask?.cancel()
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let handoff = tapThread, let loop = handoff.runLoop {
            CFRunLoopRemoveSource(loop, handoff.source, .commonModes)
            CFRunLoopStop(loop)
            CFRunLoopWakeUp(loop)
            handoff.waitUntilStopped()
        }
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
        }
        if let boxPtr = routingBox {
            Unmanaged<RoutingBox>.fromOpaque(boxPtr).release()
        }
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
    }

    /// Updates the matched dictation combo live (no restart required).
    func setDictationShortcut(_ shortcut: Shortcut) throws {
        let changed = shortcut != dictationShortcut
        dictationShortcut = shortcut
        refreshSnapshot()
        if changed { currentRoutingBox?.modifierGesture.reset() }
    }

    /// Updates the matched cancel combo live (no restart required).
    func setCancelShortcut(_ shortcut: Shortcut) throws {
        cancelShortcut = shortcut
        refreshSnapshot()
    }

    /// Arms (or, with nil, disarms) Conversation mode's shortcut live. The coordinator passes
    /// only a shortcut `ConversationPolicy` accepted; the check is repeated here because this
    /// is the boundary where a key starts being swallowed system-wide.
    func setConversationShortcut(_ shortcut: Shortcut?) throws {
        if let shortcut,
           ConversationPolicy.validate(shortcut, dictation: dictationShortcut,
                                       cancel: cancelShortcut) != nil {
            throw HotkeyError.conversationShortcutUnavailable
        }
        let changed = shortcut != conversationShortcut
        conversationShortcut = shortcut
        refreshSnapshot()
        // A press taken under the old combination must not own a key the new one never took.
        if changed { currentRoutingBox?.conversationPress.set(false) }
    }

    /// Tells the tap whether there is a session to cancel.
    ///
    /// The cancel shortcut is a bare Escape by default. Matching it while nothing is running
    /// would take Escape away from every application on the machine, so the tap only claims
    /// it while dictation (or the pill menu) is actually open.
    func setDictating(_ active: Bool) throws {
        guard active != dictating else { return }
        dictating = active
        refreshSnapshot()
    }

    /// Arms the C tap to reserve a submit window at the next *real* stop edge.
    /// The coordinator enables this only while the current recording may later
    /// deliver through paste/type; setting it does not itself open a window.
    func setDeferredSubmitOnStopEnabled(_ enabled: Bool) {
        guard enabled != deferredSubmitOnStopEnabled else { return }
        deferredSubmitOnStopEnabled = enabled
        refreshSnapshot()
    }

    /// Opens the short window in which a bare Return means "submit the completed
    /// transcript" rather than reaching the frontmost app. The coordinator owns
    /// when this window exists: it is never implied by a pill state alone.
    ///
    /// The returned generation must accompany the close. A delayed cleanup from an
    /// older dictation cannot close a newer window or consume its Return press.
    func openDeferredSubmitWindow() -> DeferredSubmitToken {
        // This compatibility spelling is the non-hotkey fallback: a pill/VAD
        // stop needs a window even though no tap edge was available to arm one.
        claimDeferredSubmitWindow(openIfMissing: true)!
    }

    /// Adopts a window synchronously armed by the event tap at a hotkey stop
    /// edge. When `openIfMissing` is true, also creates the fallback window for
    /// a pill/VAD stop. Passing `false` still returns a stale armed window so
    /// the coordinator can close it if auto-paste was disabled meanwhile.
    func claimDeferredSubmitWindow(openIfMissing: Bool) -> DeferredSubmitToken? {
        deferredSubmitGate.claim(openIfMissing: openIfMissing)
    }

    /// Atomically closes `token`'s window and returns the exact Return key the
    /// user pressed while it was open. A stale token is a no-op and returns `nil`.
    func closeAndConsumeDeferredSubmitWindow(_ token: DeferredSubmitToken) -> DeferredSubmitRequest? {
        deferredSubmitGate.closeAndConsume(token)
    }

    /// Closes one window and makes replay failure observable to the coordinator. The physical
    /// Return has already been swallowed at this point, so treating a failed synthetic pair as
    /// success would lose the user's submit gesture without any feedback.
    func completeDeferredSubmitWindow(
        _ token: DeferredSubmitToken,
        inputWasPosted: Bool,
        replay: (UInt16) -> Bool
    ) -> DeferredSubmitCompletion {
        deferredSubmitGate.closeAndReplay(token, inputWasPosted: inputWasPosted, replay: replay)
    }

    /// Closes `token`'s window without acting on a pending Return, for cancellation
    /// and any non-insertion exit. A stale token deliberately cannot affect a new
    /// dictation's window.
    func closeDeferredSubmitWindow(_ token: DeferredSubmitToken) {
        deferredSubmitGate.close(token)
    }

    /// Creates and installs the event tap + run-loop source.
    /// - Throws: `HotkeyError.tapCreationFailed` if the tap cannot be created
    ///   (typically missing Accessibility permission).
    func start() throws {
        startWatchdog()
        if eventTap == nil, IsSecureEventInputEnabled() {
            wasSecureInputActive = true
            setAvailability(false)
            return
        }
        guard eventTap == nil else {
            evaluateTapHealth()
            return
        }

        do {
            try installTap()
            evaluateTapHealth()
        } catch {
            setAvailability(false)
            throw error
        }
    }

    /// Removes the tap + run-loop source and releases the routing box.
    func stop() {
        watchdogTask?.cancel()
        watchdogTask = nil
        diagnosticsTask?.cancel()
        diagnosticsTask = nil
        wasSecureInputActive = false
        endPushToTalkHold()
        tearDownTap(endActivity: true)
        setAvailability(false)
    }

    // MARK: Tap installation and watchdog

    /// Installs only the hotkey transport. Restarting this method never touches capture,
    /// transcription, the current dictation, or any user data.
    private func installTap() throws {
        guard eventTap == nil else { return }

        // RoutingBox carries an unowned back-reference to self plus the shared
        // snapshot store. Retained here, balanced by release in stop()/deinit.
        let box = RoutingBox(
            manager: self,
            snapshot: snapshotStore,
            deferredSubmitGate: deferredSubmitGate
        )
        let boxPtr = Unmanaged.passRetained(box).toOpaque()

        // Mouse-button downs are observed (never swallowed) only so a modifier-only shortcut
        // can tell a bare tap from ⌘-click / ⌥-drag. The callback leaves them after one
        // snapshot read unless a modifier-only gesture is actually in progress.
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyEventTapCallback,
            userInfo: boxPtr
        ) else {
            // Roll back the retained box on failure.
            Unmanaged<RoutingBox>.fromOpaque(boxPtr).release()
            throw HotkeyError.tapCreationFailed
        }

        // The callback re-arms the tap itself, on the tap thread, so it needs the handle.
        // Set before the tap is enabled, so the first disable notification can act on it.
        box.tap = tap

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CGEvent.tapEnable(tap: tap, enable: false)
            Unmanaged<RoutingBox>.fromOpaque(boxPtr).release()
            throw HotkeyError.tapCreationFailed
        }

        // The tap MUST NOT live on the main run loop.
        //
        // This is an active tap (`.defaultTap`): it can swallow events, so the window server
        // holds every keyboard event system-wide until our callback returns. Servicing it from
        // the main run loop means any main-thread stall — CoreML graph compilation on first
        // model load, a slow SwiftUI update — freezes typing in every application until the
        // tap hits its timeout. Give it a dedicated thread whose run loop does nothing else.
        let handoff = TapThreadHandoff(source: source, tap: tap)
        let ready = DispatchSemaphore(value: 0)

        let thread = Thread {
            guard let runLoop = CFRunLoopGetCurrent() else {
                handoff.markStopped()
                ready.signal()
                return
            }
            handoff.markRunning(on: runLoop)
            let heartbeat = CFRunLoopTimerCreateWithHandler(
                kCFAllocatorDefault,
                CFAbsoluteTimeGetCurrent(),
                TapThreadHandoff.heartbeatInterval,
                0,
                0
            ) { _ in
                handoff.recordHeartbeat()
            }
            CFRunLoopTimerSetTolerance(heartbeat, TapThreadHandoff.heartbeatInterval / 2)
            CFRunLoopAddSource(runLoop, handoff.source, .commonModes)
            CFRunLoopAddTimer(runLoop, heartbeat, .commonModes)
            CGEvent.tapEnable(tap: handoff.tap, enable: true)
            handoff.recordHeartbeat()
            if TapDiagnostics.enabled { TapDiagnostics.shared.installHeartbeat() }
            ready.signal()
            // Returns when `stop()` calls CFRunLoopStop, or unexpectedly if this run loop dies.
            CFRunLoopRun()
            CFRunLoopRemoveTimer(runLoop, heartbeat, .commonModes)
            handoff.markStopped()
        }
        thread.name = "com.subralabs.Dictari.eventtap"
        // Above default so a busy system cannot starve the tap and stall input everywhere.
        thread.qualityOfService = QualityOfService.userInteractive
        thread.start()
        ready.wait()

        // Opt the process out of App Nap for as long as the tap is installed.
        //
        // Dictari is an `LSUIElement` app with no window: after a stretch of inactivity it is
        // exactly the kind of process App Nap targets, and a napped process is CPU-throttled
        // and timer-coalesced. This tap sits in the input path of every keystroke on the
        // machine, so letting the system throttle us delays the user's typing everywhere —
        // and the user is typing in *another* app, which is precisely when we look idle.
        // `.userInitiatedAllowingIdleSystemSleep` rather than `.userInitiated`: we must not
        // nap, but we have no business keeping the Mac awake.
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Global dictation hotkey event tap"
            )
        }

        routingBox = boxPtr
        eventTap = tap
        runLoopSource = source
        tapThread = handoff

        if TapDiagnostics.enabled { startDiagnosticsReporting() }
    }

    private func tearDownTap(endActivity: Bool) {
        let tap = eventTap
        let handoff = tapThread

        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        // Stop and wake the owning run loop, then wait until the callback can no longer be using
        // its userInfo box before balancing passRetained. The callback never waits on MainActor,
        // so this handoff cannot form an actor deadlock.
        if let handoff, let loop = handoff.runLoop {
            CFRunLoopRemoveSource(loop, handoff.source, .commonModes)
            CFRunLoopStop(loop)
            CFRunLoopWakeUp(loop)
            handoff.waitUntilStopped()
        }
        if let tap {
            CFMachPortInvalidate(tap)
        }

        tapThread = nil
        eventTap = nil
        runLoopSource = nil

        if let boxPtr = routingBox {
            Unmanaged<RoutingBox>.fromOpaque(boxPtr).release()
            routingBox = nil
        }

        if endActivity, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    private func startWatchdog() {
        guard watchdogTask == nil else { return }
        watchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.evaluateTapHealth()
                self.reconcileStalePressOwnership()
            }
        }
    }

    /// Reads only local WindowServer/CoreFoundation state. The decision itself stays value-only
    /// (`HotkeyTapWatchdogPolicy`) so every recovery branch is host-less testable.
    private func evaluateTapHealth() {
        let secureInputEnabled = IsSecureEventInputEnabled()
        let recoveringFromSecureInput = wasSecureInputActive && !secureInputEnabled
        wasSecureInputActive = secureInputEnabled

        let health = currentTapHealth(
            secureInputEnabled: secureInputEnabled,
            recoveringFromSecureInput: recoveringFromSecureInput
        )
        switch HotkeyTapWatchdogPolicy.action(for: health) {
        case .unavailable:
            // Secure Event Input belongs to the foreground secure app. Never re-enable or recreate
            // the tap while it is active; just make the UI tell the truth until it ends.
            setAvailability(false)
            // No keyboard event reaches the tap meanwhile, so no press we took can be closed
            // by its own release. Forget them rather than swallowing the next unrelated press.
            currentRoutingBox?.clearPressOwnership()

        case .healthy:
            setAvailability(true)

        case .reenable:
            setAvailability(false)
            // Whatever arrived while delivery was disabled is gone, releases included.
            currentRoutingBox?.clearPressOwnership()
            guard !IsSecureEventInputEnabled() else {
                wasSecureInputActive = true
                return
            }
            guard let tap = eventTap, CFMachPortIsValid(tap) else {
                restartTap()
                return
            }
            CGEvent.tapEnable(tap: tap, enable: true)

            // Re-read every signal after enabling. A dead port/run loop is a restart, while a
            // still-disabled but valid tap remains unavailable and will be retried next tick.
            let verified = currentTapHealth(
                secureInputEnabled: IsSecureEventInputEnabled(),
                recoveringFromSecureInput: false
            )
            switch HotkeyTapWatchdogPolicy.action(for: verified) {
            case .healthy:
                setAvailability(true)
            case .restart:
                restartTap()
            case .unavailable, .reenable:
                setAvailability(false)
            }

        case .restart:
            restartTap()
        }
    }

    private func currentTapHealth(
        secureInputEnabled: Bool,
        recoveringFromSecureInput: Bool
    ) -> HotkeyTapHealth {
        let tap = eventTap
        let handoff = tapThread
        return HotkeyTapHealth(
            secureInputEnabled: secureInputEnabled,
            portIsValid: tap.map(CFMachPortIsValid) ?? false,
            tapIsEnabled: tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false,
            runLoopIsAlive: handoff?.isRunning ?? false,
            heartbeatIsFresh: handoff?.heartbeatIsFresh ?? false,
            recoveringFromSecureInput: recoveringFromSecureInput
        )
    }

    private func restartTap() {
        setAvailability(false)
        guard !IsSecureEventInputEnabled() else {
            wasSecureInputActive = true
            return
        }
        tearDownTap(endActivity: false)
        guard !IsSecureEventInputEnabled() else {
            wasSecureInputActive = true
            return
        }
        do {
            try installTap()
            let secureInputEnabled = IsSecureEventInputEnabled()
            wasSecureInputActive = secureInputEnabled
            let health = currentTapHealth(
                secureInputEnabled: secureInputEnabled,
                recoveringFromSecureInput: false
            )
            setAvailability(HotkeyTapWatchdogPolicy.action(for: health) == .healthy)
            Self.log.notice("event tap watchdog recreated the hotkey tap")
        } catch {
            setAvailability(false)
            if let activity {
                ProcessInfo.processInfo.endActivity(activity)
                self.activity = nil
            }
            Self.log.error("event tap watchdog could not recreate the tap: \(error.localizedDescription)")
        }
    }

    private func setAvailability(_ available: Bool) {
        guard available != isAvailable else { return }
        isAvailable = available
        // 9 Oct 2026: the shortcut stayed dead for seven hours and nothing on disk said why.
        // Record every transition at notice level (persisted) with the Secure Event Input owner,
        // the usual culprit, so the next report can name the app instead of guessing.
        if available {
            Self.log.notice("hotkey available")
        } else if IsSecureEventInputEnabled() {
            Self.log.notice("hotkey unavailable: secure input held by \(Self.secureInputOwner(), privacy: .public)")
        } else {
            let tap = eventTap
            Self.log.notice("hotkey unavailable: tap=\(tap != nil) enabled=\(tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false) runLoop=\(self.tapThread?.isRunning ?? false)")
        }
        onAvailabilityChanged?(available)
    }

    /// Name and pid of the process holding Secure Event Input, from the session dictionary.
    private static func secureInputOwner() -> String {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              let pid = (session["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value,
              pid > 0
        else { return "unknown" }
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid"
        return "\(name) (\(pid))"
    }

    private func startDiagnosticsReporting() {
        guard diagnosticsTask == nil else { return }
        let log = Logger(subsystem: "com.subralabs.Dictari", category: "tapstats")
        diagnosticsTask = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                let s = TapDiagnostics.shared.drain()
                let service = s.serviceNs.sorted()
                let beat = s.beatLateNs.sorted()
                func pct(_ a: [UInt64], _ p: Double) -> Double {
                    guard !a.isEmpty else { return 0 }
                    return Double(a[min(a.count - 1, Int(Double(a.count) * p))]) / 1_000_000
                }
                log.notice("""
                    n=\(s.count) \
                    service p50=\(pct(service, 0.5), format: .fixed(precision: 3))ms \
                    p99=\(pct(service, 0.99), format: .fixed(precision: 3))ms \
                    max=\(Double(service.last ?? 0) / 1_000_000, format: .fixed(precision: 3))ms | \
                    beat n=\(beat.count) \
                    p50=\(pct(beat, 0.5), format: .fixed(precision: 2))ms \
                    p99=\(pct(beat, 0.99), format: .fixed(precision: 2))ms \
                    max=\(Double(beat.last ?? 0) / 1_000_000, format: .fixed(precision: 2))ms
                    """)
            }
        }
    }

    // MARK: MainActor-isolated state

    private(set) var dictationShortcut: Shortcut
    private(set) var cancelShortcut: Shortcut
    private(set) var conversationShortcut: Shortcut?
    private var dictating = false
    private var deferredSubmitOnStopEnabled = false

    // `nonisolated(unsafe)`: mutated only from @MainActor methods (start/stop), but the
    // nonisolated `deinit` must read them to tear down the C handles. By the time deinit
    // runs there are no other references, so there is no concurrent access.
    private nonisolated(unsafe) var eventTap: CFMachPort?
    private nonisolated(unsafe) var runLoopSource: CFRunLoopSource?
    /// Opaque pointer to the retained `RoutingBox` handed to the C callback.
    private nonisolated(unsafe) var routingBox: UnsafeMutableRawPointer?
    /// Handles for the dedicated thread servicing the tap.
    private nonisolated(unsafe) var tapThread: TapThreadHandoff?
    /// One MainActor watchdog for the manager lifetime. Its closure captures `self` weakly, so
    /// storing the task cannot keep the manager alive after app shutdown.
    private var watchdogTask: Task<Void, Never>?
    private var wasSecureInputActive = false
    /// Periodic latency log, only alive under `DICTARI_TAPSTATS=1`.
    private var diagnosticsTask: Task<Void, Never>?
    /// App Nap opt-out, held for exactly as long as the tap is installed.
    private nonisolated(unsafe) var activity: (any NSObjectProtocol)?

    /// Lock-protected store shared with the C callback so the tap thread can
    /// read the current matching parameters without touching MainActor state.
    private let snapshotStore = SnapshotStore()
    /// A separate gate because the event-tap thread mutates its pending bit. Keeping
    /// it out of the immutable shortcut snapshot prevents a MainActor refresh from
    /// racing away a Return that the tap has already claimed.
    private let deferredSubmitGate = DeferredSubmitGate()

    // MARK: Snapshot synchronisation

    /// Publishes the current shortcuts + mode into the lock-protected store.
    private func refreshSnapshot() {
        snapshotStore.update(
            ShortcutSnapshot(
                dictationKeyCode: dictationShortcut.keyCode,
                dictationModifiers: dictationShortcut.modifierFlags
                    .intersection(Self.matchedModifiers),
                cancelKeyCode: cancelShortcut.keyCode,
                cancelModifiers: cancelShortcut.modifierFlags
                    .intersection(Self.matchedModifiers),
                pushToTalk: mode == .pushToTalk,
                dictating: dictating,
                deferredSubmitOnStopEnabled: deferredSubmitOnStopEnabled,
                conversationKeyCode: conversationShortcut?.keyCode ?? 0,
                conversationModifiers: (conversationShortcut?.modifierFlags ?? [])
                    .intersection(Self.matchedModifiers),
                conversationEnabled: conversationShortcut != nil
            )
        )
    }

    // MARK: Event handling (MainActor)

    /// Subset of device-independent modifier flags we match against.
    /// `nonisolated`: an immutable Sendable constant read from the nonisolated tap path.
    fileprivate nonisolated static let matchedModifiers: NSEvent.ModifierFlags =
        [.command, .option, .control, .shift]

    /// Modifier keycodes on the standard layout (shift/control/option/command,
    /// left & right, plus caps lock). A shortcut whose keyCode is one of these
    /// is "modifier only" and toggles on `flagsChanged`.
    fileprivate nonisolated static let modifierKeyCodes: Set<UInt16> =
        [54, 55, 56, 57, 58, 59, 60, 61, 62]

    /// Invoked on the MainActor for each tapped event to run side effects.
    fileprivate func handle(type: CGEventType, keyCode: UInt16, flags: CGEventFlags) {
        let pressed = Self.modifierFlags(from: flags)

        switch type {
        case .keyDown:
            if matches(.revisionDictation, keyCode: keyCode, modifiers: pressed) {
                revisionChordOwnsModifiers = true
                onRevisionActivate?()
                if mode == .pushToTalk {
                    beginPushToTalkHold(keyCode: keyCode, startedSession: !dictating)
                }
            } else if let conversationShortcut,
                      matches(conversationShortcut, keyCode: keyCode, modifiers: pressed) {
                // Same precedence as the tap's decision: after the fixed correction chord,
                // before dictation. No push-to-talk hold: the conversation shortcut toggles.
                onConversationActivate?()
            } else if matches(dictationShortcut, keyCode: keyCode, modifiers: pressed) {
                let startedSession = !dictating
                onActivate?()
                if mode == .pushToTalk {
                    beginPushToTalkHold(keyCode: keyCode, startedSession: startedSession)
                }
            } else if matches(cancelShortcut, keyCode: keyCode, modifiers: pressed) {
                onCancel?()
            }

        case .keyUp:
            // Match by keyCode alone on the release edge: the modifier may have
            // already lifted by the time the regular key comes up.
            if mode == .pushToTalk,
               keyCode == dictationShortcut.keyCode || keyCode == Shortcut.revisionDictation.keyCode {
                endPushToTalkHold()
                onDeactivate?()
            }

        case .flagsChanged:
            // Space owns a correction chord's release. Its constituent modifier
            // releases must not stop PTT early or toggle a fresh ordinary capture.
            // (The modifier-only gesture already stepped aside when the chord was taken.)
            if revisionChordOwnsModifiers,
               pressed.intersection(Shortcut.revisionDictation.modifierFlags).isEmpty {
                revisionChordOwnsModifiers = false
            }
            // Modifier-only shortcuts are no longer decided here: whether a modifier press was
            // a tap, a hold or the first half of a chord depends on events *after* it, which
            // only the tap thread sees in order. See `handleModifierGesture`.

        default:
            break
        }
    }

    /// Side effects of a modifier-only shortcut edge decided by `ModifierTapGesture` on the tap
    /// thread (MainActor).
    fileprivate func handleModifierGesture(_ action: ModifierTapGesture.Action) {
        switch action {
        case .none:
            break
        case .activate:
            let startedSession = !dictating
            onActivate?()
            if mode == .pushToTalk {
                beginPushToTalkHold(keyCode: dictationShortcut.keyCode, startedSession: startedSession)
            }
        case .deactivate:
            endPushToTalkHold()
            onDeactivate?()
        case .abort:
            // The hold was the start of a chord (⌘C, ⌥ò for @). If this press started the
            // session, discard it — the user never meant to dictate, so nothing is transcribed
            // or inserted. If a session was already running (started from the pill), leave it
            // alone: the hold stays tracked and ends it on release as push-to-talk always has.
            guard pushToTalkHold?.startedSession == true else { return }
            endPushToTalkHold()
            onCancel?()
        }
    }

    // MARK: Push-to-talk release recovery

    /// The key whose physical release ends the current push-to-talk session.
    private struct PushToTalkHold {
        var keyCode: UInt16
        /// Whether this press started the session (vs. pressing during a pill-started one).
        var startedSession: Bool
    }

    private var pushToTalkHold: PushToTalkHold?
    private var pushToTalkPollTask: Task<Void, Never>?
    private static let pushToTalkPollInterval: Duration = .milliseconds(40)

    /// A push-to-talk release is an *event*, and events can be lost: the system disables the
    /// tap on a timeout or user-input burst, Secure Event Input hides the keyboard from every
    /// tap, and the watchdog's `restartTap` drops whatever is in flight. Losing the keyUp left
    /// dictation `.listening` with nobody holding the key. So while — and only while — a hold is
    /// active, poll the HID state itself. It is independent of the tap, cheap, and runs on the
    /// MainActor because it only ever produces a MainActor side effect.
    private func beginPushToTalkHold(keyCode: UInt16, startedSession: Bool) {
        if let existing = pushToTalkHold, existing.keyCode == keyCode {
            // A duplicate down (release lost, key pressed again) keeps the original meaning.
            pushToTalkHold = PushToTalkHold(keyCode: keyCode,
                                            startedSession: existing.startedSession || startedSession)
        } else {
            pushToTalkHold = PushToTalkHold(keyCode: keyCode, startedSession: startedSession)
        }
        guard pushToTalkPollTask == nil else { return }
        pushToTalkPollTask = Task { @MainActor [weak self] in
            // Require two consecutive "up" samples. A normally delivered keyUp is processed
            // within microseconds and ends the hold first, so the poll only ever acts on a
            // release the tap really lost — and never races an in-flight keyUp for ownership.
            var upSamples = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pushToTalkPollInterval)
                guard !Task.isCancelled, let self else { return }
                guard let hold = self.pushToTalkHold, self.mode == .pushToTalk else {
                    self.pushToTalkPollTask = nil
                    self.pushToTalkHold = nil
                    return
                }
                if Self.isPhysicallyDown(keyCode: hold.keyCode) {
                    upSamples = 0
                    continue
                }
                upSamples += 1
                guard upSamples >= 2 else { continue }
                self.pushToTalkPollTask = nil
                self.recoverLostPushToTalkRelease(hold)
                return
            }
        }
    }

    private func endPushToTalkHold() {
        pushToTalkHold = nil
        pushToTalkPollTask?.cancel()
        pushToTalkPollTask = nil
    }

    private func recoverLostPushToTalkRelease(_ hold: PushToTalkHold) {
        Self.log.notice("push-to-talk key \(hold.keyCode) is up but its release never reached the tap; stopping")
        // The tap still believes it owns the press: its next keyDown of this key would be
        // swallowed as a "repeat" and never start dictation.
        if let box = currentRoutingBox {
            if hold.keyCode == Shortcut.revisionDictation.keyCode {
                box.revisionPress.set(false)
            }
            if hold.keyCode == dictationShortcut.keyCode {
                box.press.set(false)
                box.modifierGesture.reset()
            }
        }
        pushToTalkHold = nil
        onDeactivate?()
    }

    /// Once a second (watchdog tick), drop press ownership whose physical key is already up.
    /// Covers toggle mode too: a keyUp lost to Secure Event Input otherwise made the next press
    /// of the shortcut vanish as a swallowed "repeat".
    private func reconcileStalePressOwnership() {
        guard let box = currentRoutingBox else { return }
        if box.press.isHeld, !Self.isPhysicallyDown(keyCode: dictationShortcut.keyCode) {
            box.press.set(false)
        }
        if box.revisionPress.isHeld,
           !Self.isPhysicallyDown(keyCode: Shortcut.revisionDictation.keyCode) {
            box.revisionPress.set(false)
        }
        if box.conversationPress.isHeld,
           conversationShortcut.map({ !Self.isPhysicallyDown(keyCode: $0.keyCode) }) ?? true {
            box.conversationPress.set(false)
        }
        if box.revisionModifiers.isHeld,
           Self.modifierFlags(from: CGEventSource.flagsState(.combinedSessionState))
               .intersection(Shortcut.revisionDictation.modifierFlags).isEmpty {
            box.revisionModifiers.set(false)
            revisionChordOwnsModifiers = false
        }
        if let cancelKey = box.cancelPress.heldKeyCode, !Self.isPhysicallyDown(keyCode: cancelKey) {
            box.cancelPress.clear()
        }
    }

    /// Hardware state of one key, read from the HID system rather than the event stream.
    private static func isPhysicallyDown(keyCode: UInt16) -> Bool {
        if ModifierKeyIdentity.isModifierKey(keyCode) {
            let flags = CGEventSource.flagsState(.combinedSessionState).rawValue
            return ModifierKeyIdentity.isDown(keyCode: keyCode, flags: flags)
        }
        return CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(keyCode))
    }

    /// The live routing box, for MainActor bookkeeping on its thread-safe stores.
    private var currentRoutingBox: RoutingBox? {
        routingBox.map { Unmanaged<RoutingBox>.fromOpaque($0).takeUnretainedValue() }
    }

    // MARK: Matching helpers

    private func matches(
        _ shortcut: Shortcut,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        guard keyCode == shortcut.keyCode else { return false }
        let required = shortcut.modifierFlags.intersection(Self.matchedModifiers)
        return modifiers == required
    }

    /// Maps `CGEventFlags` to the device-independent `NSEvent.ModifierFlags`
    /// subset we compare against.
    fileprivate nonisolated static func modifierFlags(from flags: CGEventFlags) -> NSEvent.ModifierFlags {
        var result: NSEvent.ModifierFlags = []
        if flags.contains(.maskCommand) { result.insert(.command) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskControl) { result.insert(.control) }
        if flags.contains(.maskShift) { result.insert(.shift) }
        return result
    }
}

// MARK: - Event-tap watchdog policy

/// Local signals sampled by the watchdog. Keeping CoreGraphics handles out of this value makes
/// recovery ordering deterministic and testable without installing a global event tap.
struct HotkeyTapHealth: Equatable, Sendable {
    var secureInputEnabled: Bool
    var portIsValid: Bool
    var tapIsEnabled: Bool
    var runLoopIsAlive: Bool
    var heartbeatIsFresh: Bool
    var recoveringFromSecureInput: Bool = false
}

enum HotkeyTapWatchdogAction: Equatable, Sendable {
    /// Secure Event Input is active. Report unavailable and do not touch the tap.
    case unavailable
    /// The tap transport is live but delivery is disabled (or Secure Input just ended).
    case reenable
    /// A handle, run loop, or tap-thread heartbeat is dead and the tap transport must be rebuilt.
    case restart
    case healthy
}

enum HotkeyTapWatchdogPolicy {
    static func action(for health: HotkeyTapHealth) -> HotkeyTapWatchdogAction {
        // This must win over every apparent failure: recreating or re-enabling during Secure
        // Event Input would be a bypass attempt and still could not receive protected events.
        if health.secureInputEnabled { return .unavailable }
        if !health.portIsValid || !health.runLoopIsAlive || !health.heartbeatIsFresh {
            return .restart
        }
        if health.recoveringFromSecureInput || !health.tapIsEnabled { return .reenable }
        return .healthy
    }
}

// MARK: - Errors

enum HotkeyError: LocalizedError {
    case tapCreationFailed
    case conversationShortcutUnavailable

    var errorDescription: String? {
        switch self {
        case .tapCreationFailed:
            return String(localized: "Could not create the global hotkey event tap. Grant Accessibility permission to Dictari in System Settings → Privacy & Security → Accessibility.",
                          comment: "Shortcut error; use the macOS names of System Settings panes")
        case .conversationShortcutUnavailable:
            return String(localized: "The Conversation Mode shortcut needs a modifier or a function key, and must differ from the other shortcuts.",
                          comment: "Shortcut error")
        }
    }
}

// MARK: - Thread-safe shortcut snapshot

/// Immutable, `Sendable` snapshot of the matching parameters, read from the C
/// callback thread without touching MainActor state.
struct ShortcutSnapshot: Sendable {
    var dictationKeyCode: UInt16 = 0
    var dictationModifiers: NSEvent.ModifierFlags = []
    var cancelKeyCode: UInt16 = 0
    var cancelModifiers: NSEvent.ModifierFlags = []
    var pushToTalk: Bool = false
    /// True while a dictation session (or the pill menu) is actually open. The cancel
    /// shortcut is only meaningful then — see `decide`.
    var dictating: Bool = false
    /// The coordinator's opt-in for opening a submit window exactly at the next
    /// hotkey stop edge. The C callback owns that edge; it cannot wait for a
    /// MainActor state transition after the focused app has already seen Return.
    var deferredSubmitOnStopEnabled: Bool = false
    /// Conversation mode's shortcut. `conversationEnabled == false` means the mode has no
    /// shortcut and the key/modifier fields are ignored.
    var conversationKeyCode: UInt16 = 0
    var conversationModifiers: NSEvent.ModifierFlags = []
    var conversationEnabled: Bool = false

    /// What the tap should do with one event. The two answers are separate on purpose:
    /// there are events we want to *hear* without removing them from the stream.
    struct Decision: Equatable, Sendable {
        var route: Bool     // hop to the MainActor for side effects
        var swallow: Bool   // remove the event from every app on the machine

        static let ignore = Decision(route: false, swallow: false)
        static let take = Decision(route: true, swallow: true)
        static let observe = Decision(route: true, swallow: false)
    }

    /// Synchronous, value-only decision mirroring `HotkeyManager.handle(type:keyCode:flags:)`.
    ///
    /// - Parameter pressHeld: whether *we* swallowed the dictation keyDown that this keyUp
    ///   would close. Without it, a push-to-talk shortcut whose key is an ordinary one (Space
    ///   in ⌥⌘Space) swallowed the release of every plain press of that key on the machine,
    ///   leaving apps with a key they saw go down and never come up.
    func decide(type: CGEventType, keyCode: UInt16, flags: CGEventFlags,
                pressHeld: Bool, cancelPressHeld: Bool = false) -> Decision {
        let pressed = HotkeyManager.modifierFlags(from: flags)
        switch type {
        case .keyDown:
            // A physical cancel press stays ours until its matching release, even after the
            // MainActor handles Escape and publishes `dictating = false`. Never route repeats.
            if cancelPressHeld { return Decision(route: false, swallow: true) }
            // Once we swallowed the physical down, its repeats stay ours even if the user
            // releases a modifier before the ordinary key. Test this before the exact chord
            // too: a duplicate down with an unreliable repeat bit must not toggle again.
            if keyCode == dictationKeyCode, pressHeld {
                return Decision(route: false, swallow: true)
            }
            if keyCode == dictationKeyCode, pressed == dictationModifiers { return .take }
            // The cancel shortcut is swallowed ONLY while there is something to cancel.
            // It defaults to a bare Escape, so an unconditional match removed Escape from
            // every application on the machine for as long as Dictari was running — no
            // dialog dismissal, no leaving full screen, no cancelling anything, anywhere.
            if dictating, keyCode == cancelKeyCode, pressed == cancelModifiers { return .take }
            return .ignore
        case .keyUp:
            // Without this, the foreground app sees Escape-up after Dictari swallowed its
            // down. The press is tracked independently of the current dictating snapshot.
            if cancelPressHeld { return Decision(route: false, swallow: true) }
            // Match by keyCode alone (the modifier may already be up), but only for a
            // release that closes a press we took. Toggle does not act on release, but the
            // focused app must not see a keyUp whose keyDown Dictari swallowed.
            guard pressHeld, keyCode == dictationKeyCode else { return .ignore }
            return pushToTalk ? .take : Decision(route: false, swallow: true)
        case .flagsChanged:
            // A modifier-only shortcut is *observed*, never swallowed. Removing a modifier's
            // flagsChanged from the stream hides that modifier from the whole system —
            // including the window server's own modifier-sensitive gestures and shortcuts —
            // while gaining nothing: a bare modifier press does not type anything.
            guard keyCode == dictationKeyCode,
                  HotkeyManager.modifierKeyCodes.contains(dictationKeyCode) else { return .ignore }
            return .observe
        default:
            return .ignore
        }
    }

    /// The callback records only a cancel down that actually wins shortcut priority. If the
    /// configured cancel chord also matches dictation or revision, those actions take precedence.
    func claimsCancelKeyDown(keyCode: UInt16, flags: CGEventFlags) -> Bool {
        let pressed = HotkeyManager.modifierFlags(from: flags)
        return dictating
            && keyCode == cancelKeyCode
            && pressed == cancelModifiers
            && !(keyCode == dictationKeyCode && pressed == dictationModifiers)
            && !(keyCode == Shortcut.revisionDictation.keyCode
                 && pressed == Shortcut.revisionDictation.modifierFlags)
            && !(conversationEnabled && keyCode == conversationKeyCode
                 && pressed == conversationModifiers)
    }

    /// Conversation mode's shortcut, with its own physical press ownership exactly like the
    /// fixed correction chord: the exact keyDown is taken; its repeats and its release stay
    /// swallowed (never routed) so the focused app never sees half of a press. It is a toggle
    /// in both interaction modes, so the release never routes.
    ///
    /// - Parameter dictationPressHeld: the dictation shortcut already owns this physical key
    ///   (same key, e.g. Space). Adding Shift to a held ⌥Space must stay that press's repeat
    ///   rather than become a conversation start.
    func decideConversation(type: CGEventType, keyCode: UInt16, flags: CGEventFlags,
                            pressHeld: Bool, dictationPressHeld: Bool = false) -> Decision {
        guard conversationEnabled, keyCode == conversationKeyCode else { return .ignore }
        switch type {
        case .keyDown:
            // Repeats remain owned even if a modifier was released first.
            if pressHeld { return Decision(route: false, swallow: true) }
            if dictationPressHeld { return .ignore }
            if HotkeyManager.modifierFlags(from: flags) == conversationModifiers { return .take }
            return .ignore
        case .keyUp:
            return pressHeld ? Decision(route: false, swallow: true) : .ignore
        default:
            return .ignore
        }
    }

    /// Fixed revision shortcut has its own physical press ownership, even when the
    /// configurable ordinary shortcut uses another key or a modifier-only key.
    func decideRevision(type: CGEventType, keyCode: UInt16, flags: CGEventFlags,
                        pressHeld: Bool, ownsModifiers: Bool = false) -> Decision {
        // Observe every release in an owned chord, including a last Command/Shift
        // release when the configurable ordinary shortcut is Option-only.
        if type == .flagsChanged, ownsModifiers { return .observe }
        guard keyCode == Shortcut.revisionDictation.keyCode else { return .ignore }
        if type == .keyDown,
           HotkeyManager.modifierFlags(from: flags) == Shortcut.revisionDictation.modifierFlags {
            return .take
        }
        if type == .keyUp, pressHeld { return pushToTalk ? .take : Decision(route: false, swallow: true) }
        // Repeats remain owned even if modifiers were released first.
        if type == .keyDown, pressHeld { return Decision(route: false, swallow: true) }
        return .ignore
    }

    /// Whether this event is the actual stop edge of the configured dictation
    /// shortcut, rather than its start edge or an auto-repeat (which the caller
    /// filters with the raw CGEvent repeat bit). Kept as a value-only seam so
    /// tests can pin the C-callback routing without installing an event tap.
    func deferredSubmitStopEdge(
        type: CGEventType,
        keyCode: UInt16,
        flags: CGEventFlags,
        pressHeld: Bool
    ) -> Bool {
        guard deferredSubmitOnStopEnabled else { return false }
        let modifiers = HotkeyManager.modifierFlags(from: flags)
        let isModifierOnly = HotkeyManager.modifierKeyCodes.contains(dictationKeyCode)

        // A modifier-only shortcut's edges are not a property of any single event: a press is
        // only a toggle if nothing followed it, and a push-to-talk release is only a stop if the
        // hold was not aborted as a chord. `ModifierTapGesture` owns those edges; see
        // `deferredSubmitStopEdge(modifierGesture:)`.
        if isModifierOnly { return false }

        if pushToTalk {
            // Match release by key code only, as `decide` does: modifiers may
            // legitimately have lifted before the regular key comes up.
            return type == .keyUp && pressHeld && keyCode == dictationKeyCode
        }

        // In toggle mode the second exact keyDown is the stop edge. The
        // coordinator only enables this bit while a recording is active, so
        // the first keyDown of a session cannot arm the gate.
        return type == .keyDown
            && keyCode == dictationKeyCode
            && modifiers == dictationModifiers
    }

    /// Stop edge for a modifier-only shortcut, from the gesture's decision for this event.
    /// Toggle stops on the tap that fires (its release); push-to-talk on a real release — an
    /// aborted hold is discarded, and must not reserve the user's next Return.
    func deferredSubmitStopEdge(modifierGesture action: ModifierTapGesture.Action) -> Bool {
        guard deferredSubmitOnStopEnabled, hasModifierOnlyDictation else { return false }
        return action == (pushToTalk ? .deactivate : .activate)
    }

    /// Whether the configured dictation shortcut is a bare modifier key.
    var hasModifierOnlyDictation: Bool {
        HotkeyManager.modifierKeyCodes.contains(dictationKeyCode)
    }

    var modifierGestureConfiguration: ModifierTapGesture.Configuration {
        ModifierTapGesture.Configuration(
            keyCode: dictationKeyCode,
            modifiers: dictationModifiers,
            pushToTalk: pushToTalk
        )
    }

    /// Full value-only seam used by the C callback. Keeping the routing predicate and stop-edge
    /// predicate together prevents modifier-only shortcuts (`.observe`, not `.take`) from being
    /// accidentally excluded by an assertion that the triggering event must be swallowed.
    func shouldArmDeferredSubmit(
        decision: Decision,
        type: CGEventType,
        keyCode: UInt16,
        flags: CGEventFlags,
        pressHeld: Bool,
        isAutoRepeat: Bool
    ) -> Bool {
        decision.route
            && !isAutoRepeat
            && deferredSubmitStopEdge(
                type: type,
                keyCode: keyCode,
                flags: flags,
                pressHeld: pressHeld
            )
    }
}

// MARK: Bit-packed transport

/// The snapshot squeezed into one scalar, purely so the lock below can be typed
/// over a `UInt64`. See `SnapshotStore` for why that matters.
extension ShortcutSnapshot {

    /// Order is fixed and must match `unpack(modifiers:)`.
    private static let packedModifiers: [NSEvent.ModifierFlags] =
        [.command, .option, .control, .shift]

    private static func pack(_ modifiers: NSEvent.ModifierFlags) -> UInt64 {
        var bits: UInt64 = 0
        for (index, flag) in packedModifiers.enumerated() where modifiers.contains(flag) {
            bits |= 1 << UInt64(index)
        }
        return bits
    }

    private static func unpack(modifiers bits: UInt64) -> NSEvent.ModifierFlags {
        var result: NSEvent.ModifierFlags = []
        for (index, flag) in packedModifiers.enumerated() where bits & (1 << UInt64(index)) != 0 {
            result.insert(flag)
        }
        return result
    }

    var bits: UInt64 {
        UInt64(dictationKeyCode)
            | UInt64(cancelKeyCode) << 16
            | Self.pack(dictationModifiers) << 32
            | Self.pack(cancelModifiers) << 36
            | (pushToTalk ? UInt64(1) : 0) << 40
            | (dictating ? UInt64(1) : 0) << 41
            | (deferredSubmitOnStopEnabled ? UInt64(1) : 0) << 42
            // Bits 43...63: the conversation shortcut fills the word exactly (16 + 4 + 1).
            | UInt64(conversationKeyCode) << 43
            | Self.pack(conversationModifiers) << 59
            | (conversationEnabled ? UInt64(1) : 0) << 63
    }

    init(bits: UInt64) {
        self.init(
            dictationKeyCode: UInt16(truncatingIfNeeded: bits),
            dictationModifiers: Self.unpack(modifiers: (bits >> 32) & 0xF),
            cancelKeyCode: UInt16(truncatingIfNeeded: bits >> 16),
            cancelModifiers: Self.unpack(modifiers: (bits >> 36) & 0xF),
            pushToTalk: (bits >> 40) & 1 == 1,
            dictating: (bits >> 41) & 1 == 1,
            deferredSubmitOnStopEnabled: (bits >> 42) & 1 == 1,
            conversationKeyCode: UInt16(truncatingIfNeeded: bits >> 43),
            conversationModifiers: Self.unpack(modifiers: (bits >> 59) & 0xF),
            conversationEnabled: (bits >> 63) & 1 == 1
        )
    }
}

/// Lock-protected holder for the latest `ShortcutSnapshot`.
///
/// Written from the MainActor (`HotkeyManager.refreshSnapshot`) and read from
/// the event-tap thread. Marked `@unchecked Sendable` because all access to the
/// wrapped value is funnelled through the lock.
///
/// ## Why the lock is typed over a `UInt64`
/// This lock is the *only* thing the tap callback waits on, and the other side
/// of it is the MainActor. That makes it the one place where a stalled main
/// thread could, in principle, hold up every keystroke on the machine — so the
/// critical section has to be provably incapable of stalling, not merely short
/// today.
///
/// Storing a scalar is what makes it provable. Both critical sections are a
/// register move: no allocation, no retain/release, no call-out that could
/// block, and no way for a later edit to smuggle one in without changing the
/// lock's type and tripping the reviewer. On top of that `os_unfair_lock`
/// donates the waiter's priority to the holder, so even a main thread that is
/// preempted mid-move is boosted to the tap thread's `userInteractive` band and
/// finishes immediately.
///
/// A main-actor *stall* — a multi-second Accessibility call, a slow redraw —
/// always happens outside this critical section, because there is nothing
/// inside it to stall on. Measured: with the main thread deliberately blocked
/// for 10 s, callback p99 was 0.026–0.040 ms, indistinguishable from idle.
private final class SnapshotStore: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<UInt64>(initialState: ShortcutSnapshot().bits)

    func update(_ snapshot: ShortcutSnapshot) {
        let bits = snapshot.bits          // encode outside the critical section
        lock.withLock { $0 = bits }
    }

    var value: ShortcutSnapshot {
        ShortcutSnapshot(bits: lock.withLock { $0 })   // decode outside
    }
}

// MARK: - Tap thread handles

/// Carries the CF handles the tap thread needs, plus the run loop it ends up owning.
///
/// `@unchecked Sendable`: `source` and `tap` are immutable CF references; `runLoop` is
/// written once by the tap thread before it signals the start-up semaphore, and only read
/// afterwards from `stop()` / `deinit`, so the wait establishes the ordering.
private final class TapThreadHandoff: @unchecked Sendable {
    static let heartbeatInterval: CFTimeInterval = 0.25
    private static let maximumHeartbeatAge: UInt64 = 2_500_000_000

    let source: CFRunLoopSource
    let tap: CFMachPort
    var runLoop: CFRunLoop?
    private let running = OSAllocatedUnfairLock<Bool>(initialState: false)
    private let lastHeartbeat = OSAllocatedUnfairLock<UInt64>(initialState: 0)
    private let stopped = DispatchSemaphore(value: 0)

    var isRunning: Bool { running.withLock { $0 } }
    var heartbeatIsFresh: Bool {
        let beat = lastHeartbeat.withLock { $0 }
        guard beat != 0 else { return false }
        let now = DispatchTime.now().uptimeNanoseconds
        return now >= beat && now - beat <= Self.maximumHeartbeatAge
    }

    init(source: CFRunLoopSource, tap: CFMachPort) {
        self.source = source
        self.tap = tap
    }

    func markRunning(on runLoop: CFRunLoop) {
        self.runLoop = runLoop
        running.withLock { $0 = true }
    }

    func recordHeartbeat() {
        let now = DispatchTime.now().uptimeNanoseconds
        lastHeartbeat.withLock { $0 = now }
    }

    func markStopped() {
        running.withLock { $0 = false }
        stopped.signal()
    }

    func waitUntilStopped() {
        stopped.wait()
    }
}

// MARK: - C-callback bridging

/// An opaque generation for one coordinator-owned deferred-submit window.
///
/// It is intentionally a value rather than a Bool so a stale asynchronous cleanup
/// cannot close a new dictation's window.
struct DeferredSubmitToken: Equatable, Sendable {
    fileprivate let generation: UInt64
}

/// The one Return request the coordinator may replay after posting the transcript.
/// Preserving the original hardware key code keeps keypad Enter semantically intact.
struct DeferredSubmitRequest: Equatable, Sendable {
    let keyCode: UInt16
}

/// Final outcome of a coordinator-owned deferred Return window.
enum DeferredSubmitCompletion: Equatable, Sendable {
    case noRequest
    case discarded
    case posted
    case replayFailed
}

/// The only mutable state needed to reserve a bare Return for a completed
/// transcript. This is separate from `ShortcutSnapshot`: the tap mutates
/// `pending` synchronously, whereas the MainActor replaces snapshots wholesale.
///
/// The gate is consulted only after the configured dictation/cancel shortcut has
/// declined an event, and only for Return's two hardware key codes. Consequently
/// ordinary typing never takes this lock, and shortcut priority remains unchanged.
/// Each critical section is scalar reads/writes only: no actor hop, allocation,
/// callback, or I/O can enter the active event-tap path.
final class DeferredSubmitGate: @unchecked Sendable {
    private static let returnKeyCode: UInt16 = 36
    private static let keypadEnterKeyCode: UInt16 = 76

    private struct State: Sendable {
        var generation: UInt64 = 0
        var isOpen = false
        /// Zero means no submit; valid captured key codes are 36 and 76.
        var pendingKeyCode: UInt16 = 0
        /// One bit per physical Return key. A keyUp must be swallowed only if
        /// its own bare keyDown was swallowed, even if modifiers changed later.
        var heldKeys: UInt8 = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Called by the C event tap at the exact hotkey stop edge. It cannot return
    /// a token to the MainActor, so that actor adopts the open generation later.
    func armAtStopEdge() {
        state.withLock { state in
            guard !state.isOpen else { return }
            _ = Self.openWindow(&state)
        }
    }

    /// MainActor path: use a C-tap-armed generation if it exists, or optionally
    /// create a fresh one for a pill/VAD stop that had no edge to observe.
    func claim(openIfMissing: Bool) -> DeferredSubmitToken? {
        state.withLock { state in
            if state.isOpen { return DeferredSubmitToken(generation: state.generation) }
            guard openIfMissing else { return nil }
            return Self.openWindow(&state)
        }
    }

    /// Returns whether this event belongs to the currently open submit window,
    /// updating the pending/held state in the same lock acquisition.
    func swallows(
        type: CGEventType,
        keyCode: UInt16,
        flags: CGEventFlags,
        isAutoRepeat: Bool = false
    ) -> Bool {
        guard let keyBit = Self.keyBit(for: keyCode) else { return false }

        return state.withLock { state in
            switch type {
            case .keyDown:
                // A repeat belongs to the original physical keyDown even if a
                // previous submit window closed and a new one opened meanwhile.
                // Swallow it, but never let it manufacture a second request.
                if state.heldKeys & keyBit != 0 { return true }
                // If the physical key went down before this window opened, its first event here
                // is an autorepeat we do not own. Let it continue to the app and never reinterpret
                // a held key as the user's post-dictation submit gesture.
                if isAutoRepeat { return false }
                // Only a bare Return creates a submit request. Caps Lock and the
                // numeric-pad flag do not change its meaning; command/option/control/
                // shift always do, so those keys must reach the focused app.
                guard state.isOpen,
                      HotkeyManager.modifierFlags(from: flags).isEmpty
                else { return false }
                // Repeats deliberately stay swallowed but do not queue extra work.
                state.heldKeys |= keyBit
                if state.pendingKeyCode == 0 { state.pendingKeyCode = keyCode }
                return true

            case .keyUp:
                // Balance only a keyDown that this gate actually claimed. Do not
                // consult modifier flags: users may press one before releasing Return.
                guard state.heldKeys & keyBit != 0 else { return false }
                state.heldKeys &= ~keyBit
                return true

            default:
                return false
            }
        }
    }

    func closeAndConsume(_ token: DeferredSubmitToken) -> DeferredSubmitRequest? {
        state.withLock { state in
            guard state.isOpen, state.generation == token.generation else { return nil }
            let request = state.pendingKeyCode == 0
                ? nil
                : DeferredSubmitRequest(keyCode: state.pendingKeyCode)
            state.isOpen = false
            state.pendingKeyCode = 0
            // Keep held keys until their physical releases arrive. Otherwise a
            // very fast insertion could expose a keyUp to an app that never saw
            // the corresponding keyDown.
            return request
        }
    }

    /// Consumes and replays outside the realtime lock. This is also the host-less integration
    /// seam for the rare case where CoreGraphics cannot allocate a balanced event pair.
    func closeAndReplay(
        _ token: DeferredSubmitToken,
        inputWasPosted: Bool,
        replay: (UInt16) -> Bool
    ) -> DeferredSubmitCompletion {
        guard let request = closeAndConsume(token) else { return .noRequest }
        guard inputWasPosted else { return .discarded }
        return replay(request.keyCode) ? .posted : .replayFailed
    }

    func close(_ token: DeferredSubmitToken) {
        state.withLock { state in
            guard state.isOpen, state.generation == token.generation else { return }
            state.isOpen = false
            state.pendingKeyCode = 0
            // As above, let a keyDown we swallowed retain ownership of its keyUp.
        }
    }

    private static func openWindow(_ state: inout State) -> DeferredSubmitToken {
        state.generation &+= 1
        // `0` is valid too, but skipping it leaves the default state visibly
        // distinct in diagnostics and costs nothing on this infrequent path.
        if state.generation == 0 { state.generation = 1 }
        state.isOpen = true
        state.pendingKeyCode = 0
        // Do NOT reset `heldKeys`: an already-swallowed keyDown owns all of its
        // repeats and its eventual keyUp even across close/reopen generations.
        return DeferredSubmitToken(generation: state.generation)
    }

    private static func keyBit(for keyCode: UInt16) -> UInt8? {
        switch keyCode {
        case returnKeyCode: return 1 << 0
        case keypadEnterKeyCode: return 1 << 1
        default: return nil
        }
    }
}

/// Whether the tap swallowed the dictation keyDown that is still down.
///
/// Same discipline as `SnapshotStore`: a lock typed over a scalar, both critical sections a
/// register move, so the tap can never wait on anything that could stall.
private final class PressStore: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<Bool>(initialState: false)
    var isHeld: Bool { lock.withLock { $0 } }
    func set(_ held: Bool) { lock.withLock { $0 = held } }
}

/// The physical cancel key remains owned across the asynchronous transition to idle. Store its
/// key code rather than just a Bool so changing the configured shortcut mid-press cannot leak
/// the old key's release or swallow an unrelated new key.
private final class CancelPressStore: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<UInt32>(initialState: 0)
    func owns(_ keyCode: UInt16) -> Bool { lock.withLock { $0 == UInt32(keyCode) + 1 } }
    var heldKeyCode: UInt16? {
        let raw = lock.withLock { $0 }
        return raw == 0 ? nil : UInt16(truncatingIfNeeded: raw - 1)
    }
    func set(_ keyCode: UInt16) { lock.withLock { $0 = UInt32(keyCode) + 1 } }
    func clear() { lock.withLock { $0 = 0 } }
}

/// The modifier-only gesture, mutated by the tap thread on every relevant event.
///
/// Same discipline as the other stores: the locked value is a handful of scalars, so the
/// critical section is a few register moves with no allocation, retain or call-out.
private final class ModifierGestureStore: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: ModifierTapGesture())

    func handle(_ input: ModifierTapGesture.Input,
                configuration: ModifierTapGesture.Configuration,
                now: UInt64) -> ModifierTapGesture.Action {
        lock.withLock { $0.handle(input, configuration: configuration, now: now) }
    }

    func reset() { lock.withLock { $0.reset() } }
}

/// Heap box handed to the C tap callback via `userInfo`.
///
/// Holds an `unowned` back-reference to the manager (to avoid a retain cycle,
/// since the manager retains this box) and strong references to the shared
/// snapshot and submit gate. Marked `@unchecked Sendable`: the `manager` is only
/// ever touched after an explicit MainActor hop; the two stores are thread-safe.
private final class RoutingBox: @unchecked Sendable {
    unowned let manager: HotkeyManager
    let snapshot: SnapshotStore
    let deferredSubmitGate: DeferredSubmitGate
    let press = PressStore()
    let cancelPress = CancelPressStore()
    let revisionPress = PressStore()
    let revisionModifiers = PressStore()
    /// Whether the tap swallowed the conversation shortcut's keyDown that is still down.
    let conversationPress = PressStore()
    let modifierGesture = ModifierGestureStore()
    /// The tap itself, so the callback can re-arm it without a MainActor hop.
    /// Written once in `start()` before the tap is enabled, read only from the tap thread.
    var tap: CFMachPort?

    init(manager: HotkeyManager, snapshot: SnapshotStore,
         deferredSubmitGate: DeferredSubmitGate) {
        self.manager = manager
        self.snapshot = snapshot
        self.deferredSubmitGate = deferredSubmitGate
    }

    /// Forget every press the tap believes it owns. Called when events were (or are being)
    /// lost: the matching releases will never arrive, and a stale flag would swallow the next
    /// press of that key as a "repeat". Thread-safe; callable from the tap thread or MainActor.
    func clearPressOwnership() {
        press.set(false)
        revisionPress.set(false)
        revisionModifiers.set(false)
        conversationPress.set(false)
        cancelPress.clear()
        modifierGesture.reset()
    }
}

/// Compared with `eventTargetUnixProcessID` to recognise clicks on Dictari's own pill.
private let hotkeyTapOwnProcessIdentifier = Int64(ProcessInfo.processInfo.processIdentifier)

/// Global C function used as the `CGEventTap` callback.
///
/// Runs in a `nonisolated` context on the run loop the tap was added to. It
/// must NOT touch `MainActor`-isolated state synchronously. It reads the raw
/// key code / flags (thread-safe `CGEvent` getters), decides synchronously via
/// the lock-protected snapshot whether to swallow the event, then dispatches
/// the side effects to the `MainActor`.
private func hotkeyEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {

    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let box = Unmanaged<RoutingBox>.fromOpaque(userInfo).takeUnretainedValue()

    let entry = TapDiagnostics.enabled ? mach_absolute_time() : 0

    // Re-arm the tap if the system disabled it (timeout or user-input disable), except while
    // Secure Event Input is active. That protection belongs to the foreground secure app: the
    // watchdog reports our shortcut unavailable and performs a verified re-enable only after the
    // protection ends. This path stays entirely on the tap thread and does not allocate a Task.
    //
    // Synchronously, on this thread. Recovery must not depend on the MainActor: the most
    // likely reason the system timed the tap out in the first place is that the process was
    // stalled, and queueing the fix behind the very thing that is stuck means the shortcut
    // stays dead until the app is restarted — which is exactly the symptom users report.
    // `CGEvent.tapEnable` is a thread-safe C call on an immutable handle.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        // Events were dropped while the tap was off, releases included. A push-to-talk stop is
        // recovered by the MainActor's physical-key poll; here, only stop claiming presses.
        box.clearPressOwnership()
        // While the tap was off, user keystrokes went by unseen. Live typing can no longer
        // prove the caret is where it left it, so count this as input and let it stop.
        UserInputMonitor.shared.noteKeyPress()
        if !IsSecureEventInputEnabled(), let tap = box.tap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return nil
    }

    // Dictari's own live-typing keystrokes: never a shortcut, never "the user typed". One
    // integer field read, and the event passes through untouched.
    if event.getIntegerValueField(.eventSourceUserData) == SyntheticInputMarker.liveTyping {
        return Unmanaged.passUnretained(event)
    }

    // Mouse-button downs only ever interrupt a modifier-only gesture (a Command-click is not
    // a tap of Command). Never swallowed, never routed unless the gesture produced an edge.
    if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
        // A click may move the caret, so live typing must stop — unless it lands on Dictari's
        // own non-activating pill (its stop button), which cannot move anyone's caret. A
        // lock-free counter bump: no lock, no allocation, no MainActor hop.
        if event.getIntegerValueField(.eventTargetUnixProcessID) != hotkeyTapOwnProcessIdentifier {
            UserInputMonitor.shared.notePointerPress()
        }
        let snapshot = box.snapshot.value
        if snapshot.hasModifierOnlyDictation {
            let configuration = snapshot.modifierGestureConfiguration
            if ModifierTapGesture.mayObserve(flags: event.flags.rawValue, configuration: configuration) {
                let action = box.modifierGesture.handle(
                    .pointerDown, configuration: configuration,
                    now: DispatchTime.now().uptimeNanoseconds)
                if action != .none {
                    Task { @MainActor in box.manager.handleModifierGesture(action) }
                }
            }
        }
        return Unmanaged.passUnretained(event)
    }

    // Read raw fields synchronously — these CGEvent getters are safe off-main
    // and involve no actor-isolated state.
    let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
    let flags = event.flags

    // Synchronous, value-only decision against the thread-safe snapshot. Read once: every
    // extra read is another lock acquisition on the path of every keystroke on the machine.
    let snapshot = box.snapshot.value
    let cancelPressHeld = (type == .keyDown || type == .keyUp)
        && box.cancelPress.owns(keyCode)
    let isRevisionKey = keyCode == Shortcut.revisionDictation.keyCode
    let revisionDecision = snapshot.decideRevision(type: type, keyCode: keyCode, flags: flags,
                                                    pressHeld: isRevisionKey && box.revisionPress.isHeld,
                                                    ownsModifiers: type == .flagsChanged && box.revisionModifiers.isHeld)
    // Same precedence as `HotkeyManager.handle`: correction chord, conversation, dictation.
    // Any other key costs one scalar compare; only the conversation key itself (often Space)
    // pays one more scalar lock read, the same discipline as `box.press` for dictation.
    let isConversationKey = snapshot.conversationEnabled && keyCode == snapshot.conversationKeyCode
    let conversationDecision: ShortcutSnapshot.Decision =
        !isConversationKey || revisionDecision.route || revisionDecision.swallow ? .ignore
        : snapshot.decideConversation(
            type: type, keyCode: keyCode, flags: flags,
            pressHeld: box.conversationPress.isHeld,
            dictationPressHeld: keyCode == snapshot.dictationKeyCode && box.press.isHeld)
    let decision = revisionDecision.route || revisionDecision.swallow ? revisionDecision
        : conversationDecision.route || conversationDecision.swallow ? conversationDecision
        : snapshot.decide(type: type, keyCode: keyCode, flags: flags,
                          pressHeld: box.press.isHeld, cancelPressHeld: cancelPressHeld)
    let isAutoRepeat = type == .keyDown
        && event.getIntegerValueField(.keyboardEventAutorepeat) != 0

    // Modifier-only shortcut: feed the tap-alone gesture every event that can start, end or
    // interrupt it. Ordinary typing without the shortcut's modifier held skips the lock.
    var gestureAction = ModifierTapGesture.Action.none
    if snapshot.hasModifierOnlyDictation {
        let configuration = snapshot.modifierGestureConfiguration
        let input: ModifierTapGesture.Input?
        switch type {
        case .flagsChanged:
            input = .flagsChanged(keyCode: keyCode, flags: flags.rawValue)
        case .keyDown where ModifierTapGesture.mayObserve(flags: flags.rawValue,
                                                          configuration: configuration):
            input = .keyDown(isRevisionChord: revisionDecision.swallow)
        default:
            input = nil
        }
        if let input {
            gestureAction = box.modifierGesture.handle(
                input, configuration: configuration, now: DispatchTime.now().uptimeNanoseconds)
        }
    }
    // Shortcut routing always wins. The deferred-submit gate is only checked for
    // Return/Enter by its own value-only seam, so it adds no lock acquisition to
    // unrelated keystrokes and cannot suppress a configured dictation/cancel action.
    let deferredSubmitSwallow = !decision.swallow
        && box.deferredSubmitGate.swallows(
            type: type,
            keyCode: keyCode,
            flags: flags,
            isAutoRepeat: isAutoRepeat
        )
    let swallow = decision.swallow || deferredSubmitSwallow
    // Any key press that reaches the focused app is the user typing, which ends live typing
    // for the session (the caret may have moved). Swallowed shortcut presses — the stop key,
    // push-to-talk repeats, a reserved Return — are Dictari's, so they are not counted.
    // Modifier changes (flagsChanged) are not counted either: live typing holds its writes
    // while a modifier is down instead, so reaching for ⌥ of ⌥Space does not abort it.
    if type == .keyDown, !swallow {
        UserInputMonitor.shared.noteKeyPress()
    }

    // Arm before the MainActor receives the stop callback. Opening the window
    // there was a race: a quick user Return reached the focused app while the
    // state transition/inference task was still queued. A repeat is not another
    // stop edge, so it must not replace the generation we just armed.
    let revisionStop = revisionDecision.route && snapshot.deferredSubmitOnStopEnabled
        && (snapshot.pushToTalk ? type == .keyUp : type == .keyDown) && !isAutoRepeat
    if revisionStop || snapshot.deferredSubmitStopEdge(modifierGesture: gestureAction)
        || (!(type == .flagsChanged && box.revisionModifiers.isHeld)
        && snapshot.shouldArmDeferredSubmit(
        decision: decision,
        type: type,
        keyCode: keyCode,
        flags: flags,
        pressHeld: box.press.isHeld,
        isAutoRepeat: isAutoRepeat
    )) {
        box.deferredSubmitGate.armAtStopEdge()
    }

    // Remember whether the dictation key is down *because we took it*, so its release can be
    // matched to that press rather than to any press of the same key.
    if type == .flagsChanged, box.revisionModifiers.isHeld,
       HotkeyManager.modifierFlags(from: flags).intersection(Shortcut.revisionDictation.modifierFlags).isEmpty {
        box.revisionModifiers.set(false)
    }
    if keyCode == Shortcut.revisionDictation.keyCode {
        if type == .keyDown, revisionDecision.swallow {
            box.revisionPress.set(true)
            if HotkeyManager.modifierFlags(from: flags) == Shortcut.revisionDictation.modifierFlags {
                box.revisionModifiers.set(true)
            }
        }
        else if type == .keyUp { box.revisionPress.set(false) }
    }
    if isConversationKey, !revisionDecision.swallow {
        if type == .keyDown, conversationDecision.swallow {
            box.conversationPress.set(true)
        } else if type == .keyUp {
            box.conversationPress.set(false)
        }
    }
    if keyCode == snapshot.dictationKeyCode, !revisionDecision.swallow, !conversationDecision.swallow {
        if type == .keyDown, decision.swallow {
            box.press.set(true)
        } else if type == .keyUp {
            box.press.set(false)
        }
    }
    if type == .keyDown, decision.route, decision.swallow,
       snapshot.claimsCancelKeyDown(keyCode: keyCode, flags: flags) {
        box.cancelPress.set(keyCode)
    } else if type == .keyUp, cancelPressHeld {
        box.cancelPress.clear()
    }

    // Only an event we decided to route can have a side effect, so anything else leaves
    // this callback having done only CGEvent reads and short scalar lock reads.
    //
    // This matters more than it looks. The tap sees every keystroke on the machine, and the
    // MainActor hop below allocates a Swift task and enqueues it. Doing that per keystroke
    // made ordinary typing in any app a steady producer into a queue that only the MainActor
    // drains — so a stalled MainActor (model load, a slow redraw) turned the user's typing
    // into unbounded backlog in our process. Now the queue only ever sees the shortcut.
    //
    // `decide` and `handle(type:keyCode:flags:)` act on exactly the same set of events, so
    // routing on the decision cannot drop a side effect. `HotkeyMatchingTests` pins that set.
    //
    // Never route an auto-repeat. Holding the shortcut makes the system emit a keyDown
    // every few tens of milliseconds; in toggle mode each one flips dictation, so holding
    // the key started and stopped a session over and over and the history filled with
    // zero-second entries. The repeats are still swallowed, so they do not leak into the
    // focused app. A gesture edge (e.g. a repeat aborting a push-to-talk chord) is routed
    // on its own, without replaying the event through `handle`.
    let routeEvent = decision.route && !isAutoRepeat
    if routeEvent || gestureAction != .none {
        Task { @MainActor in
            if gestureAction != .none { box.manager.handleModifierGesture(gestureAction) }
            if routeEvent { box.manager.handle(type: type, keyCode: keyCode, flags: flags) }
        }
    }

    if TapDiagnostics.enabled {
        TapDiagnostics.shared.record(entry: entry, exit: mach_absolute_time(), eventStamp: event.timestamp)
    }

    return swallow ? nil : Unmanaged.passUnretained(event)
}

// MARK: - Diagnostics

/// Latency recorder for the tap callback, off unless `DICTARI_TAPSTATS=1`.
///
/// Two numbers matter and they fail differently:
///  - *service* — how long the callback itself runs. If this exceeds the tap
///    timeout macOS disables the tap.
///  - *queue* — how long the event waited between being stamped by the window
///    server and reaching us. This is the one that measures CPU starvation of
///    the tap thread, and it is what a system-wide typing freeze looks like.
final class TapDiagnostics: @unchecked Sendable {

    static let enabled = ProcessInfo.processInfo.environment["DICTARI_TAPSTATS"] == "1"
    static let shared = TapDiagnostics()

    struct Sample: Sendable {
        var count = 0
        var serviceNs: [UInt64] = []
        var queueNs: [UInt64] = []
        /// Lateness of a fixed-interval timer on the tap thread's own run loop.
        /// This is the starvation metric: if this thread cannot get CPU, every
        /// keystroke on the machine is delayed by the same amount.
        var beatLateNs: [UInt64] = []
    }

    /// Schedules the heartbeat on the *current* run loop — call from the tap thread.
    func installHeartbeat() {
        let interval = 0.02
        var expected = CFAbsoluteTimeGetCurrent() + interval
        let timer = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault, expected, interval, 0, 0
        ) { _ in
            let now = CFAbsoluteTimeGetCurrent()
            let late = max(0, now - expected)
            expected += interval
            if expected < now { expected = now + interval }
            self.state.withLock { $0.beatLateNs.append(UInt64(late * 1_000_000_000)) }
        }
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .commonModes)
    }

    private let state = OSAllocatedUnfairLock(initialState: Sample())
    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(info.denom))
    }()

    private static func nanos(_ ticks: UInt64) -> UInt64 {
        ticks &* timebase.numer / timebase.denom
    }

    func record(entry: UInt64, exit: UInt64, eventStamp: CGEventTimestamp) {
        let service = Self.nanos(exit &- entry)
        // CGEvent timestamps are mach absolute time; guard against a stamp in the future.
        let queue = eventStamp <= entry ? Self.nanos(entry &- eventStamp) : 0
        state.withLock {
            $0.count += 1
            $0.serviceNs.append(service)
            $0.queueNs.append(queue)
        }
    }

    /// Drains the accumulated samples and returns them.
    func drain() -> Sample {
        state.withLock {
            let s = $0
            $0 = Sample()
            return s
        }
    }
}
