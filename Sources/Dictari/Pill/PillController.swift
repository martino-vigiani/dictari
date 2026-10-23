// PillController.swift
// Dictari — manages the floating pill panel.
//
// The pill is a non-activating overlay: its explicit controls accept clicks, but the panel never
// becomes key/main and transparent space passes through. Position is chosen from the presets in
// Settings (no dragging — dragging made the panel steal focus).

import AppKit
import Observation
import SwiftUI

/// A panel that refuses key/main status — it must never interrupt the user's active app.
private final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// AppKit pulls windows back onto the screen by default. The pill's panel is mostly
    /// transparent, so keeping the whole panel on screen kept the visible pill far from the
    /// edge — near the sides it stopped following the pointer. The controller clamps the
    /// visible content itself, so the panel is allowed to hang off.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

@MainActor
final class PillController {
    private let coordinator: AppCoordinator
    private var panel: NonActivatingPanel?
    private weak var hostingView: PillHostingView?
    /// A second panel allocated before the first hotkey press. Recovery moves the existing hosting
    /// view onto it, preserving SwiftUI state without constructing presentation objects while a
    /// dictation is starting.
    private var standbyPanel: NonActivatingPanel?
    private var activeSurfaceSlot: PillSurfaceSlot = .primary
    private var promotionsUsed = 0
    private var fadeOutTask: Task<Void, Never>?
    private var revealGeneration: UInt = 0
    private var presentationRequested = false
    private var settingsForeground = false
    /// Whether the pointer is over the drawn pill, as last reported to the coordinator.
    private var pointerInside = false
    private var workspaceObservers: [NSObjectProtocol] = []

    /// Samples the pointer only while the pill is visible. Besides driving "Near Cursor", this
    /// switches the whole NSPanel between interactive and click-through. An NSView returning nil
    /// from `hitTest` is not enough: WindowServer can still choose the transparent 384 x 236 panel
    /// and prevent the window underneath from receiving the click.
    private var pointerTimer: DispatchSourceTimer?
    /// Last origin actually applied, so a stationary pointer costs nothing.
    private var lastCursorOrigin: NSPoint = .zero
    /// Off-screen sentinel so the very first tick always positions the panel.
    private var lastMouseLocation = NSPoint(x: -.greatestFiniteMagnitude, y: 0)

    /// Panel just big enough for the widest pill state plus a hair of breathing room.
    private let panelSize = PillGeometry.panelSize

    /// Strong ease-out (Emil's UI curve) for the soft window fade in/out.
    private static let easeOut = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        buildPanel()
        prepareStandbySurfaceIfNeeded()
        observeVisibleGeometry()
        // A Space change may require re-ordering this one window. Ordinary application
        // switches need no re-fronting: the overlay has its own cross-application role.
        for name in [NSWorkspace.activeSpaceDidChangeNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, !self.isSuppressedBySettings, self.coordinator.pillVisible,
                          self.panel?.isVisible == true else { return }
                    self.orderPanelFront()
                }
            })
        }
    }

    // MARK: - Public API

    /// Show the pill with a soft fade-in (never makes key / never activates the app).
    func show() {
        presentationRequested = true
        guard let panel, !isSuppressedBySettings else { return }
        fadeOutTask?.cancel()
        revealGeneration &+= 1
        promotionsUsed = 0
        let generation = revealGeneration
        updateInteractiveRegion()
        positionPanel(panel, reusingCurrentScreen: false)
        startPointerTracking()
        updateMousePassthrough()
        if panel.isVisible {
            // An interrupted exit reverses from its current presentation instead of restarting.
            coordinator.setPillVisible(true)
            orderPanelFront()
            return
        }
        // Commit an invisible starting frame before exposing the window. Otherwise SwiftUI's
        // first render already contains pillVisible=true and no entrance can interpolate.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { coordinator.setPillVisible(false) }
        panel.alphaValue = 1
        orderPanelFront()
        CATransaction.flush()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.revealGeneration == generation,
                  self.presentationRequested, !self.isSuppressedBySettings else { return }
            self.coordinator.setPillVisible(true)
        }
    }

    private func orderPanelFront() {
        guard let panel else { return }
        let generation = revealGeneration
        // Dictari is normally inactive while it presents the overlay. This API orders the
        // panel above the active application's windows without making it key or main.
        panel.orderFrontRegardless()

        // AppKit can keep `isVisible == true` after the panel's WindowServer device has become
        // detached from every Space. Re-ordering that stale device is a no-op, so verify after
        // one display frame and replace it with a fresh NSPanel if necessary.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(20)) {
            [weak self, weak panel] in
            guard let self, let panel, self.panel === panel,
                  self.revealGeneration == generation,
                  self.presentationRequested, !self.isSuppressedBySettings else { return }

            let backingState = PillWindowRecovery.backingState(for: panel.windowNumber)
            switch PillWindowRecovery.action(
                presentationRequested: self.presentationRequested,
                settingsForeground: self.isSuppressedBySettings,
                activeSlot: self.activeSurfaceSlot,
                appKitVisible: panel.isVisible,
                backingState: backingState,
                promotionsUsed: self.promotionsUsed
            ) {
            case .noAction:
                if PillWindowRecovery.shouldReplenishStandby(
                    promotionsUsed: self.promotionsUsed,
                    coordinatorStateIsActive: self.coordinator.state.isActive,
                    backingState: backingState
                ) {
                    // An always-visible idle pill may not produce another state change. Refill
                    // its reserve and re-arm the bounded budget as soon as the promoted surface
                    // is proven healthy. A later Space change is a new failure, not a retry loop.
                    self.prepareStandbySurfaceIfNeeded()
                    self.promotionsUsed = 0
                }
                return
            case .promote(let slot):
                self.promoteStandbySurface(replacing: panel, as: slot, generation: generation)
            case .exhausted:
                // One final order request is cheap and bounded. Do not recurse or allocate here.
                panel.orderFrontRegardless()
            }
        }
    }

    private func promoteStandbySurface(
        replacing detachedPanel: NonActivatingPanel,
        as replacementSlot: PillSurfaceSlot,
        generation: UInt
    ) {
        guard panel === detachedPanel, revealGeneration == generation,
              presentationRequested, !isSuppressedBySettings,
              replacementSlot == activeSurfaceSlot.alternate,
              let replacement = standbyPanel,
              let hostingView
        else { return }

        // Stop the stale SwiftUI surface from continuing to submit constraints to an invalid
        // window device, then promote the surface prepared at launch. Coordinator state and the
        // in-flight dictation remain untouched, and no presentation objects are allocated here.
        standbyPanel = nil
        detachedPanel.contentView = nil
        detachedPanel.close()
        replacement.contentView = hostingView
        panel = replacement
        activeSurfaceSlot = replacementSlot
        promotionsUsed += 1

        updateInteractiveRegion()
        positionPanel(replacement, reusingCurrentScreen: false)
        updateMousePassthrough()
        replacement.alphaValue = 1
        // Validate the promoted surface once. The per-presentation promotion budget prevents a
        // failed replacement from entering an allocation or retry loop.
        orderPanelFront()
    }

    /// Soft fade-out. `force` overrides the always-show preference (used by the idle timeout).
    func hide(force: Bool = false) {
        guard force || !coordinator.settings.data.alwaysShowPill else { return }
        presentationRequested = false
        revealGeneration &+= 1
        stopPointerTracking()
        guard let panel, panel.isVisible else { return }

        // Animate the content away first, then remove the window. Previously the window's
        // alpha was faded while the SwiftUI content underneath was unchanged, so an error bar
        // or the transcript box read as dissolving rather than as dismissing — and if the
        // state flipped to idle mid-fade the content swapped abruptly behind the fade.
        coordinator.setPillVisible(false)

        fadeOutTask?.cancel()
        fadeOutTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(Int(Motion.pillExitMilliseconds))) }
            catch { return }
            guard !Task.isCancelled, let self, let panel = self.panel else { return }
            // show() may have re-shown it in the meantime.
            guard !self.coordinator.pillVisible else { return }
            panel.orderOut(nil)
        }
    }

    /// Settings suppress only the resting pill's presentation (see
    /// `PillPresentationPolicy.suppressedBySettings`), never the capture/revision lifecycle and
    /// never live feedback. A normal hide while suppressed still clears the request so expired
    /// feedback cannot reappear later.
    func setSettingsForeground(_ active: Bool) {
        guard settingsForeground != active else { return }
        settingsForeground = active
        applySettingsSuppression()
    }

    private var isSuppressedBySettings: Bool {
        PillPresentationPolicy.suppressedBySettings(
            settingsForeground: settingsForeground,
            state: coordinator.state
        )
    }

    /// Re-evaluated when Settings changes foreground status and on every pill state change: a
    /// dictation started from Settings must appear, and the pill returning to rest must yield.
    private func applySettingsSuppression() {
        if isSuppressedBySettings {
            guard panel?.isVisible == true else { return }
            revealGeneration &+= 1
            fadeOutTask?.cancel()
            stopPointerTracking()
            coordinator.setPillVisible(false)
            panel?.orderOut(nil)
        } else if presentationRequested, panel?.isVisible != true {
            show()
        }
    }

    /// Re-apply position / visibility when settings change.
    func refresh() {
        if PillPresentationPolicy.shouldShow(
            alwaysShowPill: coordinator.settings.data.alwaysShowPill,
            dictationIsActive: coordinator.state.isActive
        ) {
            show()
        } else {
            hide(force: true)
        }
    }

    /// Re-clamp the transparent host whenever the drawn pill changes width. Cursor tracking skips
    /// stationary samples by design; without this observation a success/error expansion near a
    /// display edge could stay clipped until the mouse moved again.
    private func observeVisibleGeometry() {
        withObservationTracking {
            _ = coordinator.state
            _ = coordinator.settings.data.pillStyle
            _ = coordinator.settings.data.pillPosition
            _ = coordinator.pillExpanded
            _ = coordinator.transcriptExpanded
            _ = coordinator.pillWritingVisible
            _ = coordinator.pillWritingExpanded
            _ = coordinator.conversationPillLayout
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateInteractiveRegion()
                self.applySettingsSuppression()
                if self.coordinator.settings.data.pillPosition == .cursor,
                   self.coordinator.pillVisible, let panel = self.panel, panel.isVisible {
                    // Fixed presets keep the host still throughout a morph. Only cursor mode
                    // needs a new clamp when its visible bounds grow near a screen edge. A
                    // frozen pill (it has controls, or the pointer is on it) is clamped where
                    // it stands: re-anchoring to the pointer made Expand jump away from it.
                    if self.shouldFollowCursor(pointerInsidePill: self.pointerInside) {
                        self.positionPanel(panel, reusingCurrentScreen: true)
                    } else {
                        self.clampFrozenPanel(panel)
                    }
                }
                if self.coordinator.pillVisible, self.panel?.isVisible == true {
                    // A state change can grow the pill under a still pointer; report it so a
                    // copied pill that appears beneath the pointer is treated as hovered.
                    self.updateMousePassthrough(forceReport: true)
                }
                if !self.coordinator.state.isActive {
                    // Replenish outside the start-dictation path for a later presentation.
                    self.prepareStandbySurfaceIfNeeded()
                }
                self.observeVisibleGeometry()
            }
        }
    }

    // MARK: - Panel construction

    private func buildPanel() {
        let p = makePanel()
        let host = PillHostingView(rootView: AnyView(PillView().environment(coordinator)))
        host.frame = NSRect(origin: .zero, size: panelSize)
        host.layer?.backgroundColor = NSColor.clear.cgColor
        p.contentView = host
        panel = p
        hostingView = host
        updateInteractiveRegion()
    }

    private func prepareStandbySurfaceIfNeeded() {
        guard standbyPanel == nil else { return }
        standbyPanel = makePanel()
    }

    private func makePanel() -> NonActivatingPanel {
        let panel = NonActivatingPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // A floating tool palette belongs to its application's window group. This is an
        // independent overlay, with its elevation supplied explicitly by the window level.
        panel.isFloatingPanel = false
        panel.level = .statusBar               // keep the overlay above other applications
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false                // no window halo — only the black pill shows
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications,
                                    .fullScreenAuxiliary, .transient, .ignoresCycle]
        // Start fully click-through. The pointer sampler enables input only while the pointer is
        // over the pixels occupied by the visible pill.
        panel.ignoresMouseEvents = true
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        return panel
    }

    private var visibleSize: CGSize {
        if coordinator.pillWritingVisible {
            return CGSize(width: PillGeometry.expandedTranscriptWidth,
                          height: coordinator.pillWritingExpanded ? PillGeometry.expandedTranscriptHeight : PillGeometry.writingPromptHeight)
        }
        return CGSize(
            width: PillGeometry.visibleWidth(
                state: coordinator.state,
                style: coordinator.settings.data.pillStyle,
                isExpanded: coordinator.pillExpanded,
                transcriptExpanded: coordinator.transcriptExpanded,
                conversation: coordinator.conversationPillLayout
            ),
            height: PillGeometry.visibleHeight(
                state: coordinator.state,
                style: coordinator.settings.data.pillStyle,
                idleMenuExpanded: coordinator.pillExpanded,
                transcriptExpanded: coordinator.transcriptExpanded,
                conversation: coordinator.conversationPillLayout
            )
        )
    }

    private func updateInteractiveRegion() {
        guard let hostingView else { return }
        let size = visibleSize
        hostingView.interactiveRect = PillGeometry.interactiveRect(
            size: size,
            position: coordinator.settings.data.pillPosition,
            isFlipped: hostingView.isFlipped
        )
    }

    // MARK: - Pointer tracking and click-through

    /// Track the pointer while the pill is on screen. For fixed positions the tick performs one
    /// location read and one rectangle containment check; cursor mode additionally moves the panel.
    ///
    /// This polls `NSEvent.mouseLocation` on a timer rather than subscribing to mouse events.
    /// A global event monitor looked cheaper and was tried first, but its delivery is not
    /// dependable across states: the pill tracked the cursor once dictation had finished and
    /// stood still for the whole time it was actually listening. `mouseLocation` is a direct
    /// read of the current pointer position and is correct regardless of what is going on with
    /// event routing.
    ///
    /// The timer exists only while the pill is visible, so a hidden pill has zero idle cost.
    private func startPointerTracking() {
        guard pointerTimer == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        // 60 Hz keeps both cursor following and the click-through boundary ahead of a normal
        // mouse click. The panel property is written only when the boundary is crossed.
        timer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(4))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.trackPointer() }
        }
        timer.resume()
        pointerTimer = timer
    }

    private func stopPointerTracking() {
        pointerTimer?.cancel()
        pointerTimer = nil
        panel?.ignoresMouseEvents = true
        // Deliberately not reported: a hiding pill must not re-arm the auto-hide it is running.
        // The coordinator clears its hover pause itself whenever the state changes.
        pointerInside = false
    }

    private func trackPointer() {
        guard panel?.isVisible == true else { return }
        let mouse = NSEvent.mouseLocation
        if coordinator.settings.data.pillPosition == .cursor,
           shouldFollowCursor(pointerInsidePill: interactiveScreenRect()?.contains(mouse) == true) {
            followCursor(mouse: mouse)
        }
        updateMousePassthrough(mouse: mouse)
    }

    private func shouldFollowCursor(pointerInsidePill: Bool) -> Bool {
        PillCursorFollowPolicy.shouldFollow(
            state: coordinator.state,
            idleMenuExpanded: coordinator.pillExpanded,
            transcriptExpanded: coordinator.transcriptExpanded,
            writingVisible: coordinator.pillWritingVisible,
            pointerInsidePill: pointerInsidePill,
            conversationCardVisible: coordinator.conversationPillLayout != .none
        )
    }

    private func interactiveScreenRect() -> NSRect? {
        guard let panel, let hostingView else { return nil }
        let windowRect = hostingView.convert(hostingView.interactiveRect, to: nil)
        return panel.convertToScreen(windowRect)
    }

    /// WindowServer hit testing happens before AppKit asks the hosting view for its hit view. The
    /// panel therefore has to opt out as a whole whenever the pointer is in its transparent area.
    /// The same boundary crossing is the pill's hover signal: SwiftUI hover tracking inside a
    /// panel that is click-through most of the time is not dependable.
    private func updateMousePassthrough(mouse: NSPoint = NSEvent.mouseLocation,
                                        forceReport: Bool = false) {
        guard let panel, let interactiveScreenRect = interactiveScreenRect() else { return }
        let shouldIgnore = PillGeometry.shouldIgnoreMouseEvents(
            mouseLocation: mouse,
            interactiveScreenRect: interactiveScreenRect
        )
        if panel.ignoresMouseEvents != shouldIgnore {
            panel.ignoresMouseEvents = shouldIgnore
        }
        let inside = !shouldIgnore
        if inside != pointerInside || forceReport {
            pointerInside = inside
            coordinator.pillPointerDidChange(inside: inside)
        }
    }

    private func followCursor(mouse: NSPoint) {
        guard let panel, panel.isVisible else { return }

        // Deadband on the *mouse*, before any other work: with "always show pill" this timer
        // runs for the whole app lifetime, and a still pointer used to pay a screen
        // enumeration (`NSScreen.screens` allocates a fresh array) plus a second
        // `mouseLocation` read on every one of its 60 ticks per second.
        guard abs(mouse.x - lastMouseLocation.x) >= 1 || abs(mouse.y - lastMouseLocation.y) >= 1
        else { return }
        lastMouseLocation = mouse

        let origin = cursorOrigin(mouse: mouse)
        // Sub-pixel jitter would re-layout the panel on every mouse sample for no visible
        // gain; a one-point deadband keeps the follow smooth and the work bounded.
        guard abs(origin.x - lastCursorOrigin.x) >= 1 || abs(origin.y - lastCursorOrigin.y) >= 1
        else { return }
        lastCursorOrigin = origin
        panel.setFrameOrigin(origin)
    }

    /// Half-width of the pill currently drawn. The panel is transparent around it, so only this
    /// value belongs in the cursor clamp; `PillGeometry` covers every visible state.
    private var visibleHalfWidth: CGFloat {
        visibleSize.width / 2
    }

    private func cursorOrigin(mouse: NSPoint = NSEvent.mouseLocation) -> NSPoint {
        let frame = targetScreen(mouse: mouse).visibleFrame
        let pw = panelSize.width
        // Keep the drawn pill on screen; let the transparent panel run past the edge.
        let size = visibleSize
        let centerX = min(
            max(mouse.x, frame.minX + visibleHalfWidth + 6),
            frame.maxX - visibleHalfWidth - 6
        )
        let desiredCenterY = mouse.y + 24 + size.height / 2
        let centerY = min(
            max(desiredCenterY, frame.minY + size.height / 2 + 8),
            frame.maxY - size.height / 2 - 8
        )
        let x = centerX - pw / 2
        let y = centerY - size.height / 2 - PillGeometry.verticalInset
        return NSPoint(x: x, y: y)
    }

    /// Keep a frozen "Near Cursor" pill where the user found it, shifting it only as far as
    /// needed to keep its drawn content on screen after a size change.
    private func clampFrozenPanel(_ panel: NSPanel) {
        let screen = panel.screen ?? targetScreen()
        let local = PillGeometry.visibleRect(size: visibleSize, position: .cursor)
        let drawn = local.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
        let clamped = PillGeometry.clamp(drawn, into: screen.visibleFrame, margin: 6)
        guard clamped.origin != drawn.origin else { return }
        let origin = NSPoint(x: clamped.minX - local.minX, y: clamped.minY - local.minY)
        lastCursorOrigin = origin
        panel.setFrameOrigin(origin)
    }

    // MARK: - Positioning (presets only)

    private func positionPanel(_ panel: NSPanel, reusingCurrentScreen: Bool = false) {
        let screen = reusingCurrentScreen && coordinator.settings.data.pillPosition != .cursor
            ? (panel.screen ?? targetScreen())
            : targetScreen()
        let frame = screen.visibleFrame
        let pw = panelSize.width
        let ph = panelSize.height
        let size = visibleSize
        let contentRect = PillGeometry.visibleRect(
            size: size, position: coordinator.settings.data.pillPosition
        )

        let origin: NSPoint
        switch coordinator.settings.data.pillPosition {
        case .bottomCenter:
            origin = NSPoint(
                x: frame.midX - pw / 2,
                y: frame.minY + Metrics.pillBottomInset - contentRect.minY
            )
        case .bottomLeading:
            origin = NSPoint(
                x: frame.minX + 24 - contentRect.minX,
                y: frame.minY + Metrics.pillBottomInset - contentRect.minY
            )
        case .bottomTrailing:
            origin = NSPoint(
                x: frame.maxX - 24 - contentRect.maxX,
                y: frame.minY + Metrics.pillBottomInset - contentRect.minY
            )
        case .topCenter:
            // Hug just under the notch / menu bar.
            origin = NSPoint(
                x: frame.midX - pw / 2,
                y: frame.maxY - ph
            )
        case .cursor:
            origin = cursorOrigin()
            lastCursorOrigin = origin
        }
        panel.setFrameOrigin(origin)
    }

    /// The screen the user is on (contains the cursor); falls back to main.
    private func targetScreen(mouse: NSPoint = NSEvent.mouseLocation) -> NSScreen {
        if let s = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            return s
        }
        return NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
    }
}
