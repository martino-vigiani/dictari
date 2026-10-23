import AppKit
import ApplicationServices
import os

/// What Accessibility could tell us about the element that has keyboard focus, reduced to the
/// few facts the paste decision needs. Pure data so the decision is testable without an AX server.
struct FocusProbe: Equatable, Sendable {
    /// False when AX itself failed: timeout, `cannotComplete`, API disabled. Not an answer.
    var axAnswered: Bool = true
    /// False when the app answered but reported no focused element at all.
    var hasFocusedElement: Bool = true
    var role: String?
    var subrole: String?
    var selectedRangeSettable = false
    var valueSettable = false
    var hasSelectedRange = false
    /// WebKit and Chromium expose `AXEditableAncestor` on anything inside a contenteditable.
    var hasEditableAncestor = false
    /// Chromium/Electron app (Claude, ChatGPT, Chrome, Slack, VS Code…).
    var isWebEngineApp = false
    /// The "frontmost app" is loginwindow while the screen is unlocked. After an unlock macOS
    /// hands the front back to loginwindow a few milliseconds after the real app, and keeps it
    /// there until the user clicks: the window they see and type into is not the one AX asks.
    var frontmostIsStaleLoginWindow = false
}

/// The paste decision. Biased on purpose: not pasting into a real text box is the failure the
/// user sees every day, while a stray ⌘V into a non-text control does nothing. So only *proof*
/// that nothing editable has focus sends the transcript to the pill's copy button.
enum FocusVerdict: Equatable, Sendable {
    /// A text field, text area, or a web/custom editor that says it is editable.
    case editable
    /// AX could not tell. Paste anyway — that is how the build that worked behaved, and it is
    /// the only thing that works for apps whose accessibility tree is missing or slow.
    case unknown
    /// AX answered clearly: a button, a list, a bare window, or nothing at all has focus.
    case notEditable
    /// A password field. Never receives synthetic input.
    case secure

    var allowsPaste: Bool { self == .editable || self == .unknown }

    static let textRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
        "AXSearchField",
    ]

    /// Controls that can hold focus but never take typed text, in any app.
    static let controlRoles: Set<String> = [
        kAXButtonRole as String, kAXCheckBoxRole as String, kAXRadioButtonRole as String,
        kAXPopUpButtonRole as String, kAXMenuButtonRole as String, kAXDisclosureTriangleRole as String,
        kAXImageRole as String, kAXListRole as String, kAXTableRole as String, kAXOutlineRole as String,
        kAXRowRole as String, kAXCellRole as String, kAXColumnRole as String, kAXSliderRole as String,
        kAXIncrementorRole as String, kAXTabGroupRole as String, kAXToolbarRole as String,
        kAXMenuRole as String, kAXMenuItemRole as String, kAXMenuBarRole as String,
        kAXMenuBarItemRole as String, kAXScrollBarRole as String, kAXSplitterRole as String,
        "AXLink",
    ]

    /// Roles that mean "no field" in a native app but are exactly what Chromium reports while its
    /// accessibility tree is still being built, so they only count as proof outside web engines.
    static let nativeOnlyNonTextRoles: Set<String> = [
        kAXWindowRole as String, kAXApplicationRole as String, kAXStaticTextRole as String,
    ]

    static func classify(_ probe: FocusProbe) -> FocusVerdict {
        if probe.subrole == (kAXSecureTextFieldSubrole as String) { return .secure }
        // loginwindow's empty answer says nothing about the app the user is looking at.
        if probe.frontmostIsStaleLoginWindow { return .unknown }
        guard probe.axAnswered else { return .unknown }
        guard probe.hasFocusedElement else {
            return probe.isWebEngineApp ? .unknown : .notEditable
        }
        if let role = probe.role, textRoles.contains(role) { return .editable }
        if probe.selectedRangeSettable || probe.hasEditableAncestor { return .editable }
        if probe.valueSettable && probe.hasSelectedRange { return .editable }
        if let role = probe.role {
            if controlRoles.contains(role) { return .notEditable }
            if !probe.isWebEngineApp, nativeOnlyNonTextRoles.contains(role) { return .notEditable }
        }
        return .unknown
    }
}

/// A handle on a focused Accessibility element that can cross an isolation boundary.
///
/// `@unchecked Sendable` is sound only because the wrapped `AXUIElement` is never touched outside
/// `FocusInspector`, which funnels every access through one serial queue.
struct FocusedElement: @unchecked Sendable {
    fileprivate let element: AXUIElement
}

/// Every Accessibility question Dictari asks, answered off the main actor and on a leash.
///
/// An AX call is a synchronous IPC round trip to another app's main thread. A wedged app used to
/// cost 1.5 s per call on the main actor, so: a bounded messaging timeout, and a private serial
/// queue (a plain class, not an actor — blocking a cooperative-pool thread starves other work).
final class FocusInspector: Sendable {

    /// Ceiling for any single AX round trip. A responsive app answers in well under 1 ms.
    static let messagingTimeout: Float = 0.2

    private static let log = Logger(subsystem: "com.dictari.app", category: "focus")

    private let queue = DispatchQueue(label: "com.dictari.focus-inspector", qos: .userInitiated)
    private let configured = OSAllocatedUnfairLock(initialState: false)
    /// PIDs already asked to expose their accessibility tree. Asking is idempotent but costs IPC.
    private let enabledProcesses = OSAllocatedUnfairLock(initialState: Set<pid_t>())
    /// Bundle path → "is a Chromium/Electron app", so the filesystem check runs once per app.
    private let webEngineCache = OSAllocatedUnfairLock(initialState: [String: Bool]())

    init() {}

    // MARK: - Chromium / Electron

    /// Chromium builds its accessibility tree only when an assistive client asks for it; until
    /// then `AXFocusedUIElement` returns the window or nothing, which is why pastes into Claude,
    /// ChatGPT, Chrome and Slack all fell back to the clipboard. `AXManualAccessibility` is the
    /// switch Electron documents and Chromium honours; unlike `AXEnhancedUserInterface` it does
    /// not disturb window animations or window managers. Called when recording starts, so the
    /// tree has the whole dictation to build before the delivery-time lookup.
    func enableAccessibilityIfWebEngine(processIdentifier pid: pid_t, bundleURL: URL?) {
        guard isWebEngineApp(bundleURL: bundleURL) else { return }
        let isNew = enabledProcesses.withLock { $0.insert(pid).inserted }
        guard isNew else { return }
        queue.async {
            self.configureTimeoutIfNeeded()
            let app = AXUIElementCreateApplication(pid)
            let result = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            if result != .success {
                Self.log.debug("AXManualAccessibility not accepted pid=\(pid, privacy: .public) error=\(result.rawValue, privacy: .public)")
            }
        }
    }

    /// Detects Chromium by what every Chromium embedder ships: a framework carrying
    /// `chrome_100_percent.pak` (Electron, Chrome, Edge, Brave, the ChatGPT app's "Codex
    /// Framework"). Filesystem only, cached per bundle.
    func isWebEngineApp(bundleURL: URL?) -> Bool {
        guard let bundleURL else { return false }
        let key = bundleURL.path
        if let cached = webEngineCache.withLock({ $0[key] }) { return cached }
        let result = Self.bundleEmbedsChromium(bundleURL)
        webEngineCache.withLock { $0[key] = result }
        return result
    }

    static func bundleEmbedsChromium(_ bundleURL: URL) -> Bool {
        let fm = FileManager.default
        let frameworks = bundleURL.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        guard let names = try? fm.contentsOfDirectory(atPath: frameworks.path) else { return false }
        for name in names where name.hasSuffix(".framework") {
            if name == "Electron Framework.framework" { return true }
            let framework = frameworks.appendingPathComponent(name, isDirectory: true)
            for resources in ["Resources", "Versions/Current/Resources"] {
                let pak = framework.appendingPathComponent("\(resources)/chrome_100_percent.pak")
                if fm.fileExists(atPath: pak.path) { return true }
            }
        }
        return false
    }

    // MARK: - Focus

    /// Reads the focused element of `processIdentifier` and the attributes the verdict needs,
    /// in one queue hop. Asks the app directly rather than the system-wide element: the
    /// system-wide object returns `cannotComplete` for some processes and can answer for a
    /// different app than the one we are about to paste into.
    func probe(processIdentifier pid: pid_t, isWebEngineApp: Bool) async -> (FocusProbe, FocusedElement?) {
        await run {
            self.configureTimeoutIfNeeded()
            var probe = FocusProbe(isWebEngineApp: isWebEngineApp)
            let app = AXUIElementCreateApplication(pid)
            var focusedRef: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focusedRef)
            switch error {
            case .success:
                break
            case .noValue, .attributeUnsupported:
                probe.hasFocusedElement = false
                return (probe, nil)
            default:
                probe.axAnswered = false
                Self.log.notice("AX focused element unavailable pid=\(pid, privacy: .public) error=\(error.rawValue, privacy: .public)")
                return (probe, nil)
            }
            guard let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
                probe.hasFocusedElement = false
                return (probe, nil)
            }
            let element = focusedRef as! AXUIElement

            let names = [
                kAXRoleAttribute, kAXSubroleAttribute, kAXSelectedTextRangeAttribute, "AXEditableAncestor",
            ] as CFArray
            var valuesRef: CFArray?
            if AXUIElementCopyMultipleAttributeValues(element, names, [], &valuesRef) == .success,
               let values = valuesRef as? [Any] {
                func present(_ index: Int) -> Any? {
                    guard index < values.count else { return nil }
                    let value = values[index] as CFTypeRef
                    // Missing attributes come back as an AXValue of type `.axError`.
                    if CFGetTypeID(value) == AXValueGetTypeID(),
                       AXValueGetType(value as! AXValue) == .axError { return nil }
                    return values[index]
                }
                probe.role = present(0) as? String
                probe.subrole = present(1) as? String
                probe.hasSelectedRange = present(2) != nil
                probe.hasEditableAncestor = present(3) != nil
            } else {
                probe.axAnswered = false
                return (probe, FocusedElement(element: element))
            }
            probe.selectedRangeSettable = Self.isSettable(kAXSelectedTextRangeAttribute, on: element)
            if !probe.selectedRangeSettable {
                probe.valueSettable = Self.isSettable(kAXValueAttribute, on: element)
            }
            return (probe, FocusedElement(element: element))
        }
    }

    /// A cheap fingerprint of "how much text is here and where is the caret", used after a paste
    /// to tell whether it landed. `nil` when the element exposes neither. Never reads `AXValue`:
    /// on a terminal that is the whole scrollback, built on the target app's main thread.
    func signature(of focused: FocusedElement) async -> String? {
        await run { Self.signature(of: focused.element) }
    }

    /// Polls until the signature changes or the deadline passes, in one queue hop.
    func awaitChange(of focused: FocusedElement, from before: String, within seconds: Double) async -> Bool {
        await run {
            let deadline = Date().addingTimeInterval(seconds)
            while true {
                if Self.signature(of: focused.element) != before { return true }
                guard Date() < deadline else { return false }
                usleep(15_000)
            }
        }
    }

    // MARK: - Internals

    private static func isSettable(_ attribute: String, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success
            && settable.boolValue
    }

    private static func signature(of element: AXUIElement) -> String? {
        var parts: [String] = []
        var count: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &count) == .success,
           let n = count as? Int {
            parts.append("n\(n)")
        }
        var selection: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selection) == .success,
           let selection, CFGetTypeID(selection) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(selection as! AXValue, .cfRange, &range) {
                parts.append("s\(range.location).\(range.length)")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "|")
    }

    /// Sets the process-wide AX messaging timeout once, from the inspector's own queue.
    private func configureTimeoutIfNeeded() {
        let needed = configured.withLock { done -> Bool in
            defer { done = true }
            return !done
        }
        guard needed else { return }
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), Self.messagingTimeout)
    }

    private func run<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }
}
