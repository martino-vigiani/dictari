import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Posts live-typing edits (Backspace × n, then Unicode text) into whatever has keyboard focus.
///
/// Mechanical on purpose: it owns no session state and makes no decisions. `LiveTypingPlanner`
/// decides *what* to type, `LiveTypingPolicy` decides *whether* it is safe, and `AppCoordinator`
/// decides when a session exists at all. This type only answers the environment questions the
/// policy needs and turns an approved edit into key events.
///
/// Every event carries `SyntheticInputMarker.liveTyping` in `eventSourceUserData`, so the
/// global hotkey tap neither routes it as a shortcut nor counts it as the user typing (which
/// would abort the session on its own keystrokes).
@MainActor
final class LiveTyper {

    /// Same rule as `TextInjector`: a test runs inside an Accessibility-trusted `xctest`, and a
    /// real keystroke from it would land in whatever window the developer is typing in.
    var postsSyntheticInput: Bool = NSClassFromString("XCTestCase") == nil

    /// UTF-16 units per key event. `keyboardSetUnicodeString` accepts up to 20; batching keeps
    /// a 100-character correction to ~5 events instead of 100.
    static let maxUnitsPerEvent = 20

    private let focus = FocusInspector()

    init() {}

    /// Cheap, local: whether this process may post input at all.
    var isAvailable: Bool {
        postsSyntheticInput && AXIsProcessTrusted()
    }

    // MARK: - Environment (all local calls, no IPC except the one-shot probe)

    /// One Accessibility probe of the focused element, off the main actor. Called once per
    /// session at start; the paste path keeps its own probe at delivery time.
    func focusClass(processIdentifier pid: pid_t) async -> LiveTypingFocus {
        let bundleURL = NSRunningApplication(processIdentifier: pid)?.bundleURL
        let isWebEngine = focus.isWebEngineApp(bundleURL: bundleURL)
        let (probe, _) = await focus.probe(processIdentifier: pid, isWebEngineApp: isWebEngine)
        switch FocusVerdict.classify(probe) {
        case .editable: return .editable
        case .unknown: return .unknown
        case .notEditable: return .notEditable
        case .secure: return .secure
        }
    }

    func frontmostProcessIdentifier() -> pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    func secureInputEnabled() -> Bool {
        IsSecureEventInputEnabled()
    }

    /// A synthetic Backspace with ⌥ or ⌘ physically held becomes "delete word" / "delete line".
    func modifiersHeld() -> Bool {
        !TextInjector.modifiersAllowSyntheticInput(CGEventSource.flagsState(.combinedSessionState))
    }

    /// Waits (bounded) for the stop shortcut's modifiers to be released before the final edit.
    func awaitModifierRelease(budget: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: budget)
        while modifiersHeld() {
            guard !Task.isCancelled, clock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return !Task.isCancelled
    }

    // MARK: - Posting

    /// Posts `edit` as key events. All events are created before any is posted, so a creation
    /// failure never leaves half an edit in the field. Returns false when nothing was posted.
    func post(_ edit: LiveTypingEdit) -> Bool {
        guard postsSyntheticInput, !edit.isEmpty else { return edit.isEmpty }
        guard let events = Self.events(for: edit) else { return false }
        for event in events {
            event.post(tap: .cgSessionEventTap)
        }
        return true
    }

    /// Key-down/key-up pairs for the edit, tagged as Dictari's own.
    static func events(for edit: LiveTypingEdit) -> [CGEvent]? {
        let source = CGEventSource(stateID: .combinedSessionState)
        var events: [CGEvent] = []
        events.reserveCapacity(edit.deleteCount * 2 + 8)

        func pair(keyCode: CGKeyCode, text: String?) -> Bool {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
            else { return false }
            for event in [down, up] {
                event.flags = []
                event.setIntegerValueField(.eventSourceUserData, value: SyntheticInputMarker.liveTyping)
                if let text {
                    let utf16 = Array(text.utf16)
                    utf16.withUnsafeBufferPointer { buffer in
                        guard let base = buffer.baseAddress else { return }
                        event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
                    }
                }
                events.append(event)
            }
            return true
        }

        for _ in 0..<edit.deleteCount {
            guard pair(keyCode: CGKeyCode(kVK_Delete), text: nil) else { return nil }
        }
        for chunk in LiveTypingPlanner.chunks(of: edit.insert, maxUTF16: maxUnitsPerEvent) {
            guard pair(keyCode: 0, text: chunk) else { return nil }
        }
        return events
    }
}
