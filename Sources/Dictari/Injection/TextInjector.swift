import AppKit
import ApplicationServices
import Carbon.HIToolbox
import os

/// The documented string value of `kAXTrustedCheckOptionPrompt`. Using the literal avoids
/// reading the concurrency-unsafe C global at the declaration site; the value is stable.
private let axTrustedCheckOptionPrompt = "AXTrustedCheckOptionPrompt"

enum InjectionVerificationOutcome: Equatable, Sendable {
    /// The focused element visibly changed — the text is in.
    case confirmed
    /// The target exposes nothing we can watch; the paste has to be taken on faith.
    case unobservable
    /// Watchable, watched, and nothing happened.
    case failed
}

/// The exact pasteboard state a deferred restore is allowed to replace. A newer delivery or any
/// clipboard write by the user invalidates it, so a late restore can never clobber either.
struct ClipboardOwnershipToken: Equatable, Sendable {
    let injectionGeneration: UInt
    let pasteboardChangeCount: Int
}

/// A one-shot result channel for the verification that runs after the paste was posted.
actor InjectionVerificationReceipt {
    private var outcome: InjectionVerificationOutcome?
    private var waiters: [CheckedContinuation<InjectionVerificationOutcome, Never>] = []

    func resolve(_ outcome: InjectionVerificationOutcome) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        let waiters = waiters
        self.waiters.removeAll()
        for waiter in waiters { waiter.resume(returning: outcome) }
    }

    func waitForOutcome() async -> InjectionVerificationOutcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

/// Immediate delivery result plus an optional later verification receipt. `initialResult` tells
/// the coordinator whether input was posted; `verificationOutcome()` then resolves exactly once.
struct InjectionDelivery: Sendable {
    let initialResult: InjectionResult
    private let receipt: InjectionVerificationReceipt?

    init(initialResult: InjectionResult, receipt: InjectionVerificationReceipt?) {
        self.initialResult = initialResult
        self.receipt = receipt
    }

    var hasDeferredVerification: Bool { receipt != nil }

    func verificationOutcome() async -> InjectionVerificationOutcome? {
        guard let receipt else { return nil }
        return await receipt.waitForOutcome()
    }
}

/// Puts the transcript into the text field that has focus.
///
/// The whole policy fits in one sentence: paste into whatever has keyboard focus when the
/// transcript is ready, unless Accessibility *proves* there is no text box there (or it is a
/// password field), in which case the transcript goes on the clipboard and the pill offers Copy.
///
/// History, and why it is this simple: the August build pasted unconditionally and worked
/// everywhere. September added a positive "is this an editable field?" gate, then a focus target
/// frozen at Stop, input epochs, focus leases and a delivery-time revalidation — a dozen gates in
/// series, any of which routed to the clipboard. Chromium/Electron apps (Claude, ChatGPT, Chrome,
/// Slack) fail most of them because they expose no accessibility tree until asked, so dictation
/// stopped pasting almost everywhere. `FocusInspector` now asks those apps to expose their tree
/// when recording starts, and `FocusVerdict` treats "AX could not tell" as "paste".
///
/// Strategies:
///  - `.paste`: writes the pasteboard and synthesizes ⌘V, restoring the previous clipboard once
///    the paste is confirmed (or after a grace period when the target can't be observed).
///  - `.type`: synthesizes the text as Unicode key events, independent of keyboard layout.
///    The transcript is also left on the pasteboard as a safety net until verification.
///
/// `@MainActor`: pasteboard and CGEvent calls are local and fast. Every Accessibility call is
/// blocking IPC into another app and lives in `FocusInspector`, off the main actor.
@MainActor
final class TextInjector {

    var method: InjectionMethod = .paste
    var restoreClipboard: Bool = true
    var autoCapitalize: Bool = false
    var trailingSpace: Bool = true

    /// The pasteboard to paste through. Overridden by tests so they never touch the user's
    /// real clipboard; production always uses `.general`.
    var pasteboard: NSPasteboard = .general

    /// Unit tests run inside an Accessibility-trusted `xctest`: a real ⌘V from a test would land
    /// in whatever window the developer is typing in. Synthetic input is impossible under XCTest.
    var postsSyntheticInput: Bool = NSClassFromString("XCTestCase") == nil

    /// How long to wait for the paste to show up in an observable field before calling it failed.
    private static let verificationBudget: Double = 1.5
    /// Unobservable targets (terminals, some web views) get this long to read the pasteboard
    /// before the previous clipboard is restored. Chromium reads it on the ⌘V keyDown itself.
    private static let unobservableRestoreDelay: Duration = .milliseconds(500)
    /// Stop is usually a shortcut with modifiers (⌥Space). Posting ⌘V while ⌥ is still down makes
    /// the target see ⌥⌘V, so wait for the release — bounded, then paste anyway.
    private static let modifierReleaseBudget: Duration = .milliseconds(600)

    private let focus = FocusInspector()
    /// Invalidates a pending clipboard restore as soon as a newer delivery starts.
    private var injectionGeneration: UInt = 0
    /// Test seam: lets tests observe or fail pasteboard writes without touching `.general`.
    private let clipboardWriter: (@MainActor (String) -> Bool)?

    static let log = Logger(subsystem: "com.dictari.app", category: "injection")

    init(clipboardWriter: (@MainActor (String) -> Bool)? = nil) {
        self.clipboardWriter = clipboardWriter
    }

    // MARK: - Lifecycle

    /// Called when recording starts. Chromium/Electron apps build their accessibility tree only
    /// on request; asking now gives them the whole dictation to do it, so the delivery-time
    /// lookup finds the real text box instead of a bare window.
    func prepareForDictation() {
        guard postsSyntheticInput, Self.hasAccessibilityPermission(),
              let app = NSWorkspace.shared.frontmostApplication else { return }
        focus.enableAccessibilityIfWebEngine(processIdentifier: app.processIdentifier, bundleURL: app.bundleURL)
    }

    // MARK: - Delivery

    func inject(_ text: String) async -> InjectionResult {
        await injectDelivery(text).initialResult
    }

    /// Delivers `text` into the focused field and returns a receipt for the deferred check.
    func injectDelivery(_ text: String, textIsPreprocessed: Bool = false) async -> InjectionDelivery {
        guard !Task.isCancelled else { return InjectionDelivery(initialResult: .cancelled, receipt: nil) }
        let prepared = textIsPreprocessed ? text : preprocess(text)
        // Whitespace, not just emptiness: `trailingSpace` turns "" into " ", and pasting nothing
        // but blanks would put a stray space in the user's document.
        guard prepared.contains(where: { !$0.isWhitespace }) else { return clipboardDelivery(prepared) }

        // Secure event input (a focused password field anywhere, Terminal's Secure Keyboard
        // Entry, password managers) makes the window server drop synthesized keys. Local call.
        if IsSecureEventInputEnabled() {
            Self.log.notice("secure event input active — clipboard only")
            return clipboardDelivery(prepared)
        }
        guard postsSyntheticInput, Self.hasAccessibilityPermission(),
              let app = NSWorkspace.shared.frontmostApplication else {
            Self.log.notice("no Accessibility permission or no frontmost app — clipboard only")
            return clipboardDelivery(prepared)
        }
        let pid = app.processIdentifier
        let isWebEngine = focus.isWebEngineApp(bundleURL: app.bundleURL)
        // No-op when recording already asked; covers switching apps mid-dictation.
        focus.enableAccessibilityIfWebEngine(processIdentifier: pid, bundleURL: app.bundleURL)

        var (probe, element) = await focus.probe(processIdentifier: pid, isWebEngineApp: isWebEngine)
        // Locked screen: loginwindow really is the target (its password field), never paste there.
        probe.frontmostIsStaleLoginWindow = app.bundleIdentifier == Self.loginWindowBundleID
            && !Self.isScreenLocked()
        let verdict = FocusVerdict.classify(probe)
        Self.log.notice("""
            focus verdict=\(String(describing: verdict), privacy: .public) \
            role=\(probe.role ?? "-", privacy: .public) web=\(isWebEngine, privacy: .public) \
            answered=\(probe.axAnswered, privacy: .public) focused=\(probe.hasFocusedElement, privacy: .public) \
            staleLoginWindow=\(probe.frontmostIsStaleLoginWindow, privacy: .public)
            """)
        guard !Task.isCancelled else { return InjectionDelivery(initialResult: .cancelled, receipt: nil) }
        switch verdict {
        case .secure:
            return clipboardDelivery(prepared, success: .secureFieldBlocked)
        case .notEditable:
            return clipboardDelivery(prepared)
        case .editable, .unknown:
            break
        }

        var before: String?
        if let element { before = await focus.signature(of: element) }
        let released = await awaitModifierRelease(budget: Self.modifierReleaseBudget)
        guard !Task.isCancelled else { return InjectionDelivery(initialResult: .cancelled, receipt: nil) }
        if !released { Self.log.notice("modifiers still held after the budget — pasting anyway") }

        // The awaits above take milliseconds, but the user can switch apps in that window. The
        // transcript belongs to the app that had focus; a different app gets the copy pill.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            Self.log.notice("frontmost app changed before delivery — clipboard only")
            return clipboardDelivery(prepared)
        }
        if IsSecureEventInputEnabled() {
            return clipboardDelivery(prepared, success: .secureFieldBlocked)
        }

        injectionGeneration &+= 1
        let generation = injectionGeneration
        let snapshot = restoreClipboard ? snapshotPasteboard() : []
        // The pasteboard is written for `.type` too: if the keystrokes are dropped, the user
        // still holds the transcript.
        guard writeStringToPasteboard(prepared) else {
            return InjectionDelivery(initialResult: .clipboardWriteFailed, receipt: nil)
        }
        let ownership = ClipboardOwnershipToken(
            injectionGeneration: generation,
            pasteboardChangeCount: pasteboard.changeCount
        )
        let posted = switch method {
        case .paste: synthesizePasteShortcut()
        case .type: synthesizeTyping(prepared)
        }
        guard posted else {
            Self.log.notice("could not create keyboard events — clipboard only")
            return InjectionDelivery(initialResult: .copiedToClipboard, receipt: nil)
        }

        let receipt = InjectionVerificationReceipt()
        let shouldRestore = restoreClipboard
        Task { [snapshot] in
            let outcome: InjectionVerificationOutcome
            if let element, let before {
                outcome = await focus.awaitChange(of: element, from: before, within: Self.verificationBudget)
                    ? .confirmed : .failed
            } else {
                outcome = .unobservable
                try? await Task.sleep(for: Self.unobservableRestoreDelay)
            }
            await receipt.resolve(outcome)
            if outcome == .failed { Self.log.notice("paste not observed — transcript left on the clipboard") }
            guard shouldRestore else { return }
            await self.restorePasteboardAfterVerification(snapshot, outcome: outcome, ownership: ownership)
        }
        return InjectionDelivery(initialResult: .pasteUnverified, receipt: receipt)
    }

    static let loginWindowBundleID = "com.apple.loginwindow"

    /// Local WindowServer session lookup, no Accessibility IPC.
    static func isScreenLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    // MARK: - Small public helpers

    func frontAppInfo() -> (name: String?, bundleID: String?, processIdentifier: pid_t?) {
        let app = NSWorkspace.shared.frontmostApplication
        return (app?.localizedName, app?.bundleIdentifier, app?.processIdentifier)
    }

    /// Cheap preflight, no Accessibility IPC: whether synthesizing input is possible at all.
    func canAttemptInsertion() -> Bool {
        Self.hasAccessibilityPermission()
    }

    /// Place text on the clipboard without injecting (used when showing it in the pill).
    @discardableResult
    func copyToClipboard(_ text: String) -> Bool {
        writeStringToPasteboard(text)
    }

    /// The permission that lets Dictari post ⌘V into other apps.
    static func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func requestAccessibilityPermission() -> Bool {
        let options: CFDictionary = [axTrustedCheckOptionPrompt as NSString: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Text preprocessing

    func preprocess(_ text: String) -> String {
        var result = text
        if autoCapitalize {
            result = capitalizingFirstLetter(result)
        }
        if trailingSpace, !result.isEmpty {
            result.append(" ")
        }
        return result
    }

    private func capitalizingFirstLetter(_ text: String) -> String {
        guard let firstIndex = text.firstIndex(where: { !$0.isWhitespace }) else {
            return text
        }
        let upper = String(text[firstIndex]).uppercased()
        return text.replacingCharacters(in: firstIndex...firstIndex, with: upper)
    }

    // MARK: - Pasteboard

    @discardableResult
    private func writeStringToPasteboard(_ text: String) -> Bool {
        if let clipboardWriter { return clipboardWriter(text) }
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    private func clipboardDelivery(
        _ text: String,
        success: InjectionResult = .copiedToClipboard
    ) -> InjectionDelivery {
        InjectionDelivery(
            initialResult: writeStringToPasteboard(text) ? success : .clipboardWriteFailed,
            receipt: nil
        )
    }

    /// Snapshots every item on the pasteboard, preserving all representation types as `Data`.
    func snapshotPasteboard() -> [[NSPasteboard.PasteboardType: Data]] {
        guard let items = pasteboard.pasteboardItems else { return [] }
        return items.map { item in
            var representations: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    representations[type] = data
                }
            }
            return representations
        }
    }

    /// Restores a previously captured pasteboard snapshot.
    func restorePasteboard(_ snapshot: [[NSPasteboard.PasteboardType: Data]]) {
        pasteboard.clearContents()
        guard !snapshot.isEmpty else { return }
        let items: [NSPasteboardItem] = snapshot.map { representations in
            let item = NSPasteboardItem()
            for (type, data) in representations {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(items)
    }

    /// Puts the user's previous clipboard back after a delivery. A failed paste keeps the
    /// transcript on the clipboard — the paste may merely be late, and it is the user's only
    /// quick way to get the text. The restore is skipped if anything wrote the pasteboard since,
    /// or a newer dictation started. The transcript is always in History either way.
    func restorePasteboardAfterVerification(
        _ snapshot: [[NSPasteboard.PasteboardType: Data]],
        outcome: InjectionVerificationOutcome,
        ownership: ClipboardOwnershipToken
    ) async {
        guard outcome != .failed else { return }
        guard Self.ownsDeferredClipboard(
            expected: ownership,
            current: ClipboardOwnershipToken(
                injectionGeneration: injectionGeneration,
                pasteboardChangeCount: pasteboard.changeCount
            )
        ) else { return }
        restorePasteboard(snapshot)
    }

    static func ownsDeferredClipboard(
        expected: ClipboardOwnershipToken,
        current: ClipboardOwnershipToken
    ) -> Bool {
        expected == current
    }

    // MARK: - Synthetic input

    static func modifiersAllowSyntheticInput(_ flags: CGEventFlags) -> Bool {
        let watched: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        return flags.intersection(watched).isEmpty
    }

    /// Waits until no modifier is physically held. Returns false on timeout or cancellation.
    /// Normally free: transcription takes longer than releasing the shortcut.
    func awaitModifierRelease(
        budget: Duration,
        flagsState: () -> CGEventFlags = { CGEventSource.flagsState(.combinedSessionState) }
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: budget)
        while !Self.modifiersAllowSyntheticInput(flagsState()) {
            guard !Task.isCancelled, clock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return !Task.isCancelled
    }

    /// The only Return variants a deferred-submit gesture may reproduce.
    static func submitKeyCode(for keyCode: UInt16) -> CGKeyCode? {
        switch keyCode {
        case UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter):
            return CGKeyCode(keyCode)
        default:
            return nil
        }
    }

    /// Creates a balanced keyboard event pair or returns nil without posting either half.
    static func keyboardEventPair(
        keyCode: CGKeyCode,
        factory: (_ keyCode: CGKeyCode, _ keyDown: Bool) -> CGEvent?
    ) -> (keyDown: CGEvent, keyUp: CGEvent)? {
        guard let keyDown = factory(keyCode, true),
              let keyUp = factory(keyCode, false) else { return nil }
        return (keyDown, keyUp)
    }

    /// Build the entire shortcut before posting any part of it. Merely tagging V down/up with
    /// `.maskCommand` can leave Command latched in the combined session state after the paste;
    /// a real modifier down/up pair closes the synthetic chord.
    static func pasteShortcutEventChord(
        factory: (_ keyCode: CGKeyCode, _ keyDown: Bool) -> CGEvent?
    ) -> (commandDown: CGEvent, vDown: CGEvent, vUp: CGEvent, commandUp: CGEvent)? {
        guard let commandDown = factory(CGKeyCode(kVK_Command), true),
              let vDown = factory(CGKeyCode(kVK_ANSI_V), true),
              let vUp = factory(CGKeyCode(kVK_ANSI_V), false),
              let commandUp = factory(CGKeyCode(kVK_Command), false) else { return nil }

        commandDown.flags = .maskCommand
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
        commandUp.flags = []
        return (commandDown, vDown, vUp, commandUp)
    }

    /// Synthesizes the captured Return (36) or keypad Enter (76) down/up without suspending.
    /// `AppCoordinator` owns the completed-state gate that decides when this is appropriate.
    @discardableResult
    func synthesizeSubmitKey(_ keyCode: UInt16 = UInt16(kVK_Return)) -> Bool {
        guard postsSyntheticInput,
              Self.modifiersAllowSyntheticInput(CGEventSource.flagsState(.combinedSessionState)),
              let submitKeyCode = Self.submitKeyCode(for: keyCode) else { return false }
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let events = Self.keyboardEventPair(keyCode: submitKeyCode, factory: { keyCode, keyDown in
            CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown)
        }) else { return false }

        // Post downstream of Dictari's session event tap. Otherwise the gate can mistake this
        // synthetic keyUp for the release of the physical Return it reserved.
        events.keyDown.post(tap: .cgAnnotatedSessionEventTap)
        events.keyUp.post(tap: .cgAnnotatedSessionEventTap)
        return true
    }

    /// Synthesizes a ⌘V keystroke at the session event tap.
    private func synthesizePasteShortcut() -> Bool {
        guard postsSyntheticInput else { return false }
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let events = Self.pasteShortcutEventChord(factory: { keyCode, keyDown in
            CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown)
        }) else { return false }

        events.commandDown.post(tap: .cgSessionEventTap)
        events.vDown.post(tap: .cgSessionEventTap)
        events.vUp.post(tap: .cgSessionEventTap)
        events.commandUp.post(tap: .cgSessionEventTap)
        return true
    }

    /// Types the text as Unicode key events, one grapheme cluster per event so emoji and
    /// combined accents arrive whole. Independent of the active keyboard layout.
    private func synthesizeTyping(_ text: String) -> Bool {
        guard postsSyntheticInput else { return false }
        let source = CGEventSource(stateID: .combinedSessionState)
        for character in text {
            let utf16 = Array(String(character).utf16)
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { return false }
            keyDown.flags = []
            keyUp.flags = []
            utf16.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                keyDown.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
                keyUp.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
            }
            keyDown.post(tap: .cgSessionEventTap)
            keyUp.post(tap: .cgSessionEventTap)
        }
        return true
    }
}
