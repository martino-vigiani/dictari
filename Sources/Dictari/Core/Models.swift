// Models.swift
// Dictari — shared value types, enums, and the persisted settings model.
// This file is the data contract every component and view binds to.

import AppKit
import Foundation

// MARK: - Dictation lifecycle

/// The state of a single dictation session, surfaced to the pill and menu bar.
enum DictationState: Equatable, Sendable {
    case idle
    case listening
    case transcribing
    case success(SuccessKind)
    case error(String)
    case cancelled

    /// Three outcomes, not two: "we pasted and saw it land", "we pasted and could not
    /// prove it landed" and "there was nowhere to paste". Posted input stays compact and hides;
    /// only clipboard-only delivery opens the transcript. Recovery retention is independent.
    enum SuccessKind: Equatable, Sendable {
        case inserted
        case pastedUnverified
        /// Paste/type was posted but not verified, and a reserved Return could not be replayed.
        case submitFailed
        case copiedToClipboard

        var statusLabel: String {
            switch self {
            case .inserted:
                return String(localized: "Inserted", comment: "Dictation status: text was inserted into the focused app")
            case .pastedUnverified:
                return String(localized: "Pasted", comment: "Dictation status: paste was sent but not verified")
            case .submitFailed:
                return String(localized: "Paste unverified — check, then press Return",
                              comment: "Dictation status: paste not verified, the reserved Return key was not sent")
            case .copiedToClipboard:
                return String(localized: "Copied to clipboard", comment: "Dictation status: transcript was copied, not pasted")
            }
        }
    }

    var isActive: Bool {
        switch self {
        case .listening, .transcribing: return true
        default: return false
        }
    }
}

/// State of the active transcription model (download / load).
enum ModelState: Equatable, Sendable {
    case idle
    case loading(Double?)   // optional 0...1 progress
    case ready
    case failed(String)
}

/// One explicit model preparation at a time. This is separate from `ModelState`: downloading
/// or validating a candidate must not make the already-active, ready model look unavailable.
enum ModelPreparationPurpose: Equatable, Sendable {
    case download
    case activate
}

/// A model can finish warming while a recording is still using the current engine. Swapping the
/// coordinator's engine at that point makes the stop-time readiness check reject otherwise valid
/// audio. Keep the decision value-only so it stays testable without the coordinator.
enum PreparedModelActivationPolicy: Equatable, Sendable {
    case activateNow
    case deferUntilIdle

    static func resolve(
        dictationState: DictationState,
        mediaIsBusy: Bool,
        hasActiveInference: Bool,
        hasQuarantinedInference: Bool
    ) -> Self {
        guard !dictationState.isActive,
              !mediaIsBusy,
              !hasActiveInference,
              !hasQuarantinedInference
        else { return .deferUntilIdle }
        return .activateNow
    }
}

/// Edge-triggered ownership for a queued model switch. Lifecycle notifications can arrive more
/// than once for the same terminal state (for example inference completion followed by pill hide),
/// so draining must consume the pending edge before coordinator side effects begin.
struct PreparedModelActivationLifecycle: Equatable, Sendable {
    enum Decision: Equatable, Sendable {
        case wait
        case drainExactlyOnce
    }

    private(set) var hasPending = false

    mutating func stage() {
        hasPending = true
    }

    mutating func clear() {
        hasPending = false
    }

    mutating func lifecycleChanged(
        dictationState: DictationState,
        mediaIsBusy: Bool,
        hasActiveInference: Bool,
        hasQuarantinedInference: Bool
    ) -> Decision {
        guard hasPending,
              PreparedModelActivationPolicy.resolve(
                dictationState: dictationState,
                mediaIsBusy: mediaIsBusy,
                hasActiveInference: hasActiveInference,
                hasQuarantinedInference: hasQuarantinedInference
              ) == .activateNow
        else { return .wait }

        hasPending = false
        return .drainExactlyOnce
    }
}

enum ModelActivationDrainResult: Equatable, Sendable {
    case blocked
    case noPending
    case drained
}

/// The MainActor can consume a pending model before the Task that prepares it gets its first turn.
/// Treat that dispatch window as real preparation ownership so a second lifecycle notification
/// cannot mistake it for idle and start a quarantine rebuild in parallel.
struct ModelPreparationLease: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case idle
        case dispatching
        case preparing
    }

    private(set) var state: State = .idle

    var isActive: Bool { state != .idle }

    mutating func reserveDispatch() -> Bool {
        guard state == .idle else { return false }
        state = .dispatching
        return true
    }

    mutating func beginPreparation(ownsReservedDispatch: Bool) -> Bool {
        let expected: State = ownsReservedDispatch ? .dispatching : .idle
        guard state == expected else { return false }
        state = .preparing
        return true
    }

    mutating func cancelDispatch() {
        guard state == .dispatching else { return }
        state = .idle
    }

    mutating func finishPreparation() {
        guard state == .preparing else { return }
        state = .idle
    }
}

/// A quarantined engine must be replaced exactly once, but a model candidate may already be
/// warming when the native inference finally releases its owner. Keep that obligation latched
/// until either a fresh candidate commits or the lifecycle proves there is no candidate to drain.
struct QuarantineModelReplacementGate: Equatable, Sendable {
    enum Command: Equatable, Sendable {
        case none
        case rebuildActive
    }

    private(set) var replacementRequired = false

    mutating func quarantineReleased() -> Command {
        replacementRequired = true
        return .none
    }

    mutating func freshEngineCommitted() {
        replacementRequired = false
    }

    mutating func command(after drainResult: ModelActivationDrainResult) -> Command {
        guard drainResult == .noPending, replacementRequired else { return .none }
        replacementRequired = false
        return .rebuildActive
    }
}

/// A downloaded model must match the exact artifact inventory pinned for release.
/// These errors stay typed so callers can distinguish an incomplete/corrupt download from a
/// malformed trust manifest and present a useful retry path.
enum ModelIntegrityError: Error, Equatable, LocalizedError {
    case malformedManifest
    case missingModel(String)
    case malformedDigest(path: String)
    case missingFile(path: String)
    case sizeMismatch(path: String, expected: Int64, actual: Int64)
    case checksumMismatch(path: String, expected: String, actual: String)
    case symbolicLink(path: String)
    case unexpectedFile(path: String)

    // Deliberately not localized. These messages are wrapped by the engines into
    // `TranscriptionError` text, and `ModelDownloadFailure.kind(for:)` recognises damaged files
    // by matching that English text ("failed its integrity check", "wrong size"…). A
    // translated message would stop the damaged download from being deleted. The user sees the
    // localized `ModelDownloadFailure` title and message instead.
    var errorDescription: String? {
        switch self {
        case .malformedManifest:
            return "The bundled model integrity manifest is invalid. Reinstall Dictari and try again."
        case let .missingModel(modelID):
            return "No trusted artifact record exists for model \(modelID)."
        case let .malformedDigest(path):
            return "The trusted checksum for \(path) is invalid."
        case let .missingFile(path):
            return "The model download is incomplete: \(path) is missing or unreadable."
        case let .sizeMismatch(path, expected, actual):
            return "The downloaded model file \(path) has the wrong size (expected \(expected) bytes, found \(actual))."
        case let .checksumMismatch(path, _, _):
            return "The downloaded model file \(path) failed its integrity check. Delete it and retry the download."
        case let .symbolicLink(path):
            return "The downloaded model contains an unsafe symbolic link at \(path)."
        case let .unexpectedFile(path):
            return "The downloaded model contains an unreviewed file at \(path). Delete the model and retry."
        }
    }
}

enum ModelDownloadState: Equatable, Sendable {
    case idle
    case downloading(modelID: String, progress: Double?, purpose: ModelPreparationPurpose)
    case cancelling(modelID: String, purpose: ModelPreparationPurpose)
    case failed(ModelDownloadFailure)

    var modelID: String? {
        switch self {
        case .idle: return nil
        case .downloading(let modelID, _, _), .cancelling(let modelID, _): return modelID
        case .failed(let failure): return failure.modelID
        }
    }

    var progress: Double? {
        guard case .downloading(_, let progress, _) = self else { return nil }
        return progress
    }

    var purpose: ModelPreparationPurpose? {
        switch self {
        case .idle: return nil
        case .downloading(_, _, let purpose), .cancelling(_, let purpose): return purpose
        case .failed(let failure): return failure.purpose
        }
    }

    var isInProgress: Bool {
        switch self {
        case .downloading, .cancelling: return true
        case .idle, .failed: return false
        }
    }

    func failure(for modelID: String) -> ModelDownloadFailure? {
        guard case .failed(let failure) = self, failure.modelID == modelID else { return nil }
        return failure
    }
}

/// A deliberately small, user-safe description of why model preparation failed. Framework
/// errors can contain cache paths, repository URLs, or opaque numeric domains; those are useful
/// in a log but make a poor Settings message. Known failures get stable recovery instructions,
/// while an ordinary localized description is retained only when it contains no path or URL.
struct ModelDownloadFailure: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case insufficientDiskSpace
        case corruptFiles
        case network
        case other
    }

    let modelID: String
    let purpose: ModelPreparationPurpose
    let kind: Kind
    let title: String
    let message: String

    init(
        model: ModelDescriptor,
        purpose: ModelPreparationPurpose = .download,
        error: any Error
    ) {
        modelID = model.id
        self.purpose = purpose
        kind = Self.kind(for: error)

        switch kind {
        case .insufficientDiskSpace:
            title = String(localized: "Not enough disk space", comment: "Model download failure title")
            message = String(localized: "Free up space, then try downloading \(model.displayName) again.",
                             comment: "Model download failure; the argument is the model name")
        case .corruptFiles:
            title = String(localized: "Model files are damaged", comment: "Model download failure title")
            message = String(localized: "Dictari removed the incomplete files. Download \(model.displayName) again.",
                             comment: "Model download failure; the argument is the model name")
        case .network:
            title = String(localized: "Download interrupted", comment: "Model download failure title")
            message = String(localized: "Check your connection, then try downloading \(model.displayName) again.",
                             comment: "Model download failure; the argument is the model name")
        case .other:
            title = String(localized: "Model couldn’t be prepared", comment: "Model download failure title")
            if let detail = Self.safeLocalizedDescription(for: error) {
                message = String(localized: "\(detail) Try again.",
                                 comment: "Model preparation failure; the argument is the underlying error message")
            } else {
                message = String(localized: "Try again. If the problem continues, restart Dictari.",
                                 comment: "Model preparation failure without a usable detail")
            }
        }
    }

    static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        let errors = errorChain(startingAt: error)
        if errors.contains(where: { $0.domain == NSURLErrorDomain && $0.code == NSURLErrorCancelled }) {
            return true
        }
        let text = errors.map(\.localizedDescription).joined(separator: " ").lowercased()
        return text.contains("cancellationerror")
            || text.contains("cancelled")
            || text.contains("canceled")
    }

    private static func kind(for error: any Error) -> Kind {
        if let integrityError = error as? ModelIntegrityError {
            switch integrityError {
            case .missingFile, .sizeMismatch, .checksumMismatch, .symbolicLink, .unexpectedFile:
                return .corruptFiles
            case .malformedManifest, .missingModel, .malformedDigest:
                // These describe a bad trust record shipped inside the signed app, not bytes
                // the user can repair by repeatedly downloading the same model.
                return .other
            }
        }

        let errors = errorChain(startingAt: error)

        if errors.contains(where: {
            ($0.domain == NSCocoaErrorDomain && $0.code == NSFileWriteOutOfSpaceError)
                || ($0.domain == NSPOSIXErrorDomain && $0.code == Int(POSIXErrorCode.ENOSPC.rawValue))
        }) {
            return .insufficientDiskSpace
        }

        let corruptURLCodes: Set<Int> = [
            NSURLErrorCannotDecodeRawData,
            NSURLErrorCannotDecodeContentData,
            NSURLErrorCannotParseResponse,
        ]
        if errors.contains(where: {
            ($0.domain == NSCocoaErrorDomain && $0.code == NSFileReadCorruptFileError)
                || ($0.domain == NSURLErrorDomain && corruptURLCodes.contains($0.code))
        }) {
            return .corruptFiles
        }

        let networkCodes: Set<Int> = [
            NSURLErrorTimedOut,
            NSURLErrorCannotFindHost,
            NSURLErrorCannotConnectToHost,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorDNSLookupFailed,
            NSURLErrorNotConnectedToInternet,
            NSURLErrorInternationalRoamingOff,
            NSURLErrorCallIsActive,
            NSURLErrorDataNotAllowed,
            NSURLErrorSecureConnectionFailed,
        ]
        if errors.contains(where: {
            $0.domain == NSURLErrorDomain && networkCodes.contains($0.code)
        }) {
            return .network
        }

        // Both engines currently wrap dependency errors in `TranscriptionError` with a
        // localized string, so retain a conservative textual fallback after checking domains.
        let text = errors
            .flatMap { [$0.domain, $0.localizedDescription] }
            .joined(separator: " ")
            .lowercased()
        if containsAny(text, [
            "no space left", "not enough space", "isn’t enough space", "isn't enough space",
            "disk is full", "disk full", "volume is full", "out of space",
        ]) {
            return .insufficientDiskSpace
        }
        if containsAny(text, [
            "internet connection", "network connection", "offline", "timed out", "timeout",
            "cannot connect", "could not connect", "cannot find host", "dns lookup",
        ]) {
            return .network
        }
        if containsAny(text, [
            "corrupt", "checksum mismatch", "failed its integrity check", "incomplete model",
            "model download is incomplete", "wrong size", "unsafe symbolic link",
            "invalid model", "coremldata",
            "could not load model", "cannot load model", "failed to load model",
        ]) {
            return .corruptFiles
        }
        return .other
    }

    private static func safeLocalizedDescription(for error: any Error) -> String? {
        let raw = errorChain(startingAt: error).first?.localizedDescription
            ?? error.localizedDescription
        let normalized = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !normalized.isEmpty else { return nil }

        let lower = normalized.lowercased()
        guard !lower.contains("://"),
              !lower.contains("file:"),
              !normalized.contains("/Users/"),
              !normalized.contains("/Library/"),
              !normalized.contains("/private/"),
              !normalized.contains("/var/"),
              !normalized.contains("/tmp/"),
              !(lower.contains("couldn’t be completed") && lower.contains(" error "))
        else { return nil }

        let limit = 180
        if normalized.count <= limit { return normalized }
        return String(normalized.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private static func errorChain(startingAt error: any Error) -> [NSError] {
        var result: [NSError] = []
        var next: NSError? = error as NSError
        var seen = Set<ObjectIdentifier>()

        while let current = next,
              result.count < 8,
              seen.insert(ObjectIdentifier(current)).inserted {
            result.append(current)
            next = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return result
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains(where: text.contains)
    }
}

/// One truthful presentation state shared by the menu-bar icon, popover copy and status glyph.
///
/// A live dictation always wins over model/permission background state. The old UI resolved those
/// signals independently and checked model loading first, so a microphone that was genuinely
/// recording could be represented by three loading dots and the words “Loading model…”. Terminal
/// feedback also belongs to the session that just finished and must not be overwritten by a model
/// switch starting in the background.
enum AppFeedbackPresentation: Equatable, Sendable {
    case ready
    case loading(Double?)
    case attention(String)
    case listening
    case transcribing
    case success(DictationState.SuccessKind)
    case error(String)
    case cancelled

    /// Refines feedback after input was posted. A watchable field that did not change means the
    /// paste did not land, so the pill reopens with the transcript and its Copy button — the user
    /// must never be left with nothing. Exception: when Return was replayed right after the paste,
    /// the composer may have submitted and cleared before the first check, which looks identical.
    static func successAfterPostedInputVerification(
        _ outcome: InjectionVerificationOutcome,
        submitWasPosted: Bool = false
    ) -> DictationState.SuccessKind? {
        switch outcome {
        case .confirmed: .inserted
        case .failed: submitWasPosted ? nil : .copiedToClipboard
        case .unobservable: nil
        }
    }

    static func resolve(
        dictation: DictationState,
        model: ModelState,
        attentionReason: String?
    ) -> AppFeedbackPresentation {
        switch dictation {
        case .listening:
            return .listening
        case .transcribing:
            return .transcribing
        case .success(let kind):
            return .success(kind)
        case .error(let message):
            return .error(message)
        case .cancelled:
            return .cancelled
        case .idle:
            if let attentionReason { return .attention(attentionReason) }
            if case .failed(let reason) = model { return .attention(reason) }
            if case .loading(let progress) = model { return .loading(progress) }
            return .ready
        }
    }

    var statusLabel: String {
        switch self {
        case .ready:
            return String(localized: "Ready", comment: "Menu bar status: ready to dictate")
        case .loading(let progress):
            if let progress {
                return String(localized: "Loading model… \(Int(progress * 100))%",
                              comment: "Menu bar status; the argument is a percentage")
            }
            return String(localized: "Loading model…", comment: "Menu bar status")
        case .attention(let reason):
            return reason
        case .listening:
            return String(localized: "Listening…", comment: "Dictation status: recording")
        case .transcribing:
            return String(localized: "Transcribing…", comment: "Dictation status: converting speech to text")
        case .success(let kind):
            return kind.statusLabel
        case .error(let message):
            return String(localized: "Error: \(message)", comment: "Menu bar status; the argument is the error message")
        case .cancelled:
            return String(localized: "Cancelled", comment: "Dictation status: the user cancelled")
        }
    }
}

/// Resolve the single actionable idle blocker shown by both the status item and its popover.
/// Preserve model-provided diagnostics: a quarantined cancelled inference is not a load failure,
/// and replacing its reason with a generic label sends the user toward the wrong fix.
enum AppAttentionReason {
    static func resolve(
        model: ModelState,
        hasAccessibility: Bool,
        hasMicrophone: Bool,
        hotkeyArmed: Bool
    ) -> String? {
        if case .failed(let reason) = model { return reason }
        // Same keys as `PermissionIssue.title` (not compiled into the host-less test target).
        if !hasAccessibility {
            return String(localized: "Accessibility access needed", comment: "Permission status: Accessibility is not granted")
        }
        if !hasMicrophone {
            return String(localized: "Microphone access needed", comment: "Permission status: Microphone is not granted")
        }
        if !hotkeyArmed {
            return String(localized: "Shortcut not active", comment: "Status: the global dictation shortcut is not armed")
        }
        return nil
    }
}

/// What the menu's primary button can actually do in the current lifecycle state. A single
/// `isRecording` boolean collapsed `.listening` and `.transcribing`, producing a “Stop Recording”
/// button during inference even though `stopDictation()` deliberately accepts only `.listening`.
enum PrimaryDictationAction: Equatable, Sendable {
    case start
    case stop
    case cancel

    static func resolve(for state: DictationState) -> PrimaryDictationAction {
        switch state {
        case .listening: return .stop
        case .transcribing: return .cancel
        default: return .start
        }
    }

    var title: String {
        switch self {
        case .start: return String(localized: "Start Recording", comment: "Menu button")
        case .stop: return String(localized: "Stop Recording", comment: "Menu button")
        case .cancel: return String(localized: "Cancel Transcription", comment: "Menu button")
        }
    }
}

/// The global toggle shortcut only owns capture. Once inference has started, another press is a
/// harmless no-op; Escape and the explicit popover button remain the deliberate cancel actions.
enum ToggleHotkeyAction: Equatable, Sendable {
    case start
    case stop
    case ignore

    static func resolve(for state: DictationState) -> ToggleHotkeyAction {
        switch state {
        case .listening: return .stop
        case .transcribing: return .ignore
        default: return .start
        }
    }
}

/// Generation token for delayed UI transitions. Cancellation remains the cheap first line of
/// defence, while the token makes a stale task harmless even if it has already resumed. This is
/// deliberately value-only so the race can be proved in the host-less test target.
struct ScheduledTransitionGate: Sendable {
    private(set) var generation: UInt = 0

    mutating func invalidate() {
        generation &+= 1
    }

    var token: UInt { generation }

    func isCurrent(_ token: UInt) -> Bool {
        token == generation
    }
}

enum SuccessFeedbackTiming {
    static func hideDelay(for kind: DictationState.SuccessKind) -> Double {
        switch kind {
        case .copiedToClipboard: return TranscriptPillPolicy.collapsedHoldSeconds
        case .submitFailed: return 2.5
        case .inserted, .pastedUnverified: return 0.9
        }
    }
}

/// Pure presentation policy for the clipboard fallback pill. Keeping the threshold and timings
/// outside SwiftUI makes the behaviour deterministic in the host-less suite.
enum TranscriptPillPolicy {
    static let previewCharacterLimit = 96
    /// The clipboard fallback is the one success state that asks the user to act (paste it
    /// themselves), so it holds long enough to read and reach. Four seconds proved too short.
    static let collapsedHoldSeconds: Double = 8
    static let expandedHoldSeconds: Double = 15
    static let copyConfirmationSeconds: Double = 1.2

    static func canExpand(_ transcript: String) -> Bool {
        let lineCount = transcript.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).count
        return lineCount > 2 || transcript.count > previewCharacterLimit
    }

    /// How long the copied pill holds after an interaction (hover exit, re-copy, expansion).
    static func holdSeconds(transcriptExpanded: Bool) -> Double {
        transcriptExpanded ? expandedHoldSeconds : collapsedHoldSeconds
    }

    enum HoverAction: Equatable, Sendable {
        case none
        /// Cancel the pending auto-hide while the pointer rests on the pill.
        case pause
        /// Re-arm the auto-hide with a full hold once the pointer leaves.
        case resume
    }

    /// Hovering the clipboard pill pauses its auto-hide so its controls stay reachable. The
    /// Improve card owns its own lifetime (it cancels the hide), so hover never re-arms it.
    static func hoverAction(
        isCopiedState: Bool,
        writingVisible: Bool,
        pointerInside: Bool,
        pausedByHover: Bool
    ) -> HoverAction {
        guard isCopiedState, !writingVisible else { return .none }
        if pointerInside { return pausedByHover ? .none : .pause }
        return pausedByHover ? .resume : .none
    }
}

/// What the cancel shortcut (a bare Escape by default) means in each state. The tap claims the
/// key only while one of these has a target, so Escape keeps working in every other app.
enum CancelShortcutPolicy {
    enum Target: Equatable, Sendable {
        case none
        case cancelDictation
        case dismissCopiedPill
        case collapseIdleMenu
    }

    static func target(state: DictationState, idleMenuExpanded: Bool) -> Target {
        if state.isActive { return .cancelDictation }
        // Not the copied pill: it lingers for seconds while the user is back at work, and holding
        // Escape system-wide that long steals it from dialogs and editors (see the August
        // WindowServer-gesture regression). The pill's ✕ dismisses it instead.
        if idleMenuExpanded { return .collapseIdleMenu }
        return .none
    }

    static func claimsShortcut(state: DictationState, idleMenuExpanded: Bool) -> Bool {
        target(state: state, idleMenuExpanded: idleMenuExpanded) != .none
    }
}

enum FeedbackTiming {
    static let errorHoldSeconds: Double = 2.0
}

/// When a session that captured nothing usable is an accidental open-and-close rather than a
/// failed dictation. Those close silently: no pill message, no History entry, no safety copy.
/// Before this, pressing and releasing the key within a second flashed "Too far from the mic"
/// for something the user never meant as a dictation.
enum AccidentalSession {
    /// Below this nothing is kept, whatever was captured: there is nothing worth transcribing.
    static let misTapSeconds: Double = 0.35
    /// Below this a session is still treated as accidental when it also held no usable voice.
    /// A real one-word dictation ("sì", "ok") that is loud enough is unaffected — only the
    /// rejection is silenced, and only for sessions this short.
    static let quietTapSeconds: Double = 1.5

    /// Checked before transcription, from the capture's own measurements.
    static func isAccidental(duration: Double, peak: Float, speechLevel: Float,
                             minimumSpeechLevel: Float) -> Bool {
        if duration < misTapSeconds { return true }
        guard duration < quietTapSeconds else { return false }
        return peak < silencePeak || speechLevel < minimumSpeechLevel
    }

    /// Checked after transcription: a short session the model heard nothing in.
    static func isAccidental(duration: Double, transcriptIsEmpty: Bool) -> Bool {
        transcriptIsEmpty && duration < quietTapSeconds
    }

    /// Peak amplitude under which a capture counts as digital silence.
    static let silencePeak: Float = 0.005
}

/// Human-readable explanation for failed history entries. Kept outside SwiftUI so every persisted
/// failure tag, especially a failed safety commit, is covered by the host-less suite.
enum HistoryFailureDescription {
    static func text(for tag: String?) -> String {
        switch tag {
        // The tags are persisted English identifiers; only the returned text is localized.
        case "no audio":
            return String(localized: "No audio captured — check the input device", comment: "History failure reason")
        case "no speech":
            return String(localized: "No speech detected", comment: "Dictation failure: nothing was said")
        case "too far":
            return String(localized: "Too far from the microphone — ignored", comment: "History failure reason")
        case "failed":
            return String(localized: "Transcription failed", comment: "History failure reason")
        case "recovery failed":
            return String(localized: "Recording couldn't be saved — check free disk space", comment: "History failure reason")
        case "revision failed":
            return String(localized: "Correction failed — original saved", comment: "History failure reason")
        default:
            return String(localized: "Nothing recorded", comment: "History failure reason")
        }
    }
}

// MARK: - Preference enums

enum InteractionMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case toggle, pushToTalk
    var id: String { rawValue }
    var label: String {
        self == .toggle
            ? String(localized: "Toggle", comment: "Shortcut mode: press once to start, again to stop")
            : String(localized: "Push-to-Talk", comment: "Shortcut mode: hold the key while speaking")
    }
}

enum InjectionMethod: String, Codable, CaseIterable, Sendable, Identifiable {
    case paste, type
    var id: String { rawValue }
    var label: String {
        self == .paste
            ? String(localized: "Paste (⌘V)", comment: "Insertion method")
            : String(localized: "Type", comment: "Insertion method: simulate typing each character")
    }
}

enum AppearanceMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return String(localized: "appearance.system", defaultValue: "System",
                                    comment: "Appearance: follow the system light/dark setting")
        case .light: return String(localized: "appearance.light", defaultValue: "Light",
                                   comment: "Appearance: light theme (not the Light model)")
        case .dark: return String(localized: "appearance.dark", defaultValue: "Dark", comment: "Appearance: dark theme")
        }
    }
    var colorScheme: ColorSchemeChoice {
        switch self {
        case .system: return .system
        case .light: return .light
        case .dark: return .dark
        }
    }
    enum ColorSchemeChoice { case system, light, dark }
}

enum PillStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    case compact, expanded
    /// A bare disc with live bars inside: no capsule, no text, just "am I being heard".
    case orb

    var id: String { rawValue }

    var label: String {
        switch self {
        case .compact:  return String(localized: "Compact", comment: "Pill style")
        case .expanded: return String(localized: "Expanded", comment: "Pill style")
        case .orb:      return String(localized: "Orb", comment: "Pill style: a small circle")
        }
    }

    var detail: String {
        switch self {
        case .compact:  return String(localized: "A small capsule with a live waveform", comment: "Pill style description")
        case .expanded: return String(localized: "Wider capsule, room for the transcript preview", comment: "Pill style description")
        case .orb:      return String(localized: "Just a circle that reacts to your voice", comment: "Pill style description")
        }
    }
}

enum PillPosition: String, Codable, CaseIterable, Sendable, Identifiable {
    case bottomCenter, bottomLeading, bottomTrailing, topCenter, cursor
    var id: String { rawValue }
    var label: String {
        switch self {
        case .bottomCenter: return String(localized: "Bottom Center", comment: "Pill position on screen")
        case .bottomLeading: return String(localized: "Bottom Left", comment: "Pill position on screen")
        case .bottomTrailing: return String(localized: "Bottom Right", comment: "Pill position on screen")
        case .topCenter: return String(localized: "Top Center", comment: "Pill position on screen")
        case .cursor: return String(localized: "Near Cursor", comment: "Pill position: next to the mouse pointer")
        }
    }
}

/// How aggressively to reject a dictation whose measured voice level is too low.
///
/// Loudness is only a coarse guard, not speaker recognition: it can reject a wholly quiet or
/// distant session, but cannot separate two similarly loud speakers inside one recording. Keep
/// that limitation visible in Settings rather than presenting this as voice isolation.
enum ProximityFilter: String, Codable, CaseIterable, Sendable, Identifiable {
    case off, gentle, normal, strict

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off:    return String(localized: "Off", comment: "Setting value: disabled")
        case .gentle: return String(localized: "Gentle", comment: "Voice level filter strength")
        case .normal: return String(localized: "Balanced", comment: "Voice level filter strength")
        case .strict: return String(localized: "Strict", comment: "Voice level filter strength")
        }
    }

    var detail: String {
        switch self {
        case .off:    return String(localized: "No minimum voice level", comment: "Voice level filter description")
        case .gentle: return String(localized: "Reject below 0.04 on the 0–1 voice meter", comment: "Voice level filter description")
        case .normal: return String(localized: "Reject below 0.08 on the 0–1 voice meter", comment: "Voice level filter description")
        case .strict: return String(localized: "Reject below 0.15 on the 0–1 voice meter", comment: "Voice level filter description")
        }
    }

    /// Minimum 90th-percentile frame level, on the same normalized scale the waveform uses.
    ///
    /// Calibrated against measurement, not taste: speech at normal dictation distance from a
    /// MacBook microphone measures around 0.10-0.15 on this scale, so the first cut of these
    /// numbers rejected the user's own voice. Every history entry now stores the level it
    /// measured, so these can be checked against real sessions rather than guessed again.
    var minimumSpeechLevel: Float {
        switch self {
        case .off:    return 0
        case .gentle: return 0.04
        case .normal: return 0.08
        case .strict: return 0.15
        }
    }
}

/// How long dictations are kept before being deleted automatically.
///
/// Stored in minutes rather than days so short windows are expressible: someone dictating
/// passwords or client notes wants an hour, not a week. `never` (0) keeps everything.
enum HistoryRetention: Int, Codable, CaseIterable, Sendable, Identifiable {
    case forever = 0
    case oneHour = 60
    case oneDay = 1_440
    case oneWeek = 10_080
    case thirtyDays = 43_200
    case oneYear = 525_600

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .forever:    return String(localized: "Forever", comment: "History retention")
        case .oneHour:    return String(localized: "1 hour", comment: "History retention")
        case .oneDay:     return String(localized: "1 day", comment: "History retention")
        case .oneWeek:    return String(localized: "7 days", comment: "Time span: history retention or statistics range")
        case .thirtyDays: return String(localized: "30 days", comment: "Time span: history retention or statistics range")
        case .oneYear:    return String(localized: "1 year", comment: "History retention")
        }
    }

    var minutes: Int { rawValue }
}

/// Result of attempting to inject transcribed text into the frontmost app.
enum InjectionResult: Equatable, Sendable {
    /// ⌘V was synthesized into a real target but the change could not be observed through
    /// Accessibility. The text is also on the pasteboard as a safety net. Distinct from
    /// `.copiedToClipboard`, which means there was no target at all.
    case pasteUnverified
    case copiedToClipboard
    case secureFieldBlocked
    /// The transcription succeeded, but the system pasteboard rejected the write. The caller
    /// must preserve the transcript and must not report success.
    case clipboardWriteFailed
    /// Escape won while an Accessibility query or modifier-release wait was in flight, before
    /// any synthetic input was posted.
    case cancelled
}

/// The idle overlay follows the user's preference exactly. Shortcut availability belongs in the
/// menu-bar status; turning a disabled pill back on as a fallback makes the setting untrustworthy.
enum PillPresentationPolicy {
    static func shouldShow(alwaysShowPill: Bool, dictationIsActive: Bool) -> Bool {
        alwaysShowPill || dictationIsActive
    }

    /// While Settings is the foreground window only the resting (always-show) pill is withheld:
    /// it would sit over the window the user is working in and carries no news. Recording,
    /// transcription, success and error feedback always present — the status-level panel sits
    /// above Settings, and hiding it made a dictation started from Settings look dead.
    static func suppressedBySettings(settingsForeground: Bool, state: DictationState) -> Bool {
        guard settingsForeground else { return false }
        switch state {
        case .idle, .cancelled: return true
        case .listening, .transcribing, .success, .error: return false
        }
    }
}

// MARK: - Keyboard shortcut

/// A device-independent keyboard shortcut (virtual keycode + modifier flags).
struct Shortcut: Codable, Equatable, Sendable {
    var keyCode: UInt16
    /// Raw value of `NSEvent.ModifierFlags` (device-independent subset).
    var modifiers: UInt

    var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    // ⌥Space by default. The previous ⌥⌘Space default is macOS's system-wide Finder Search
    // command: whenever Secure Event Input legitimately hides our tap, that shortcut opens a
    // Finder window. Keep the default away from OS-owned global actions.
    static let defaultDictation = Shortcut(
        keyCode: 49 /* space */,
        modifiers: NSEvent.ModifierFlags.option.rawValue
    )
    /// The retired default. It remains named so persistence and Settings can migrate/reject it.
    static let finderSearch = Shortcut(
        keyCode: 49 /* space */,
        modifiers: NSEvent.ModifierFlags.option.rawValue | NSEvent.ModifierFlags.command.rawValue
    )
    static let revisionDictation = Shortcut(
        keyCode: 49,
        modifiers: NSEvent.ModifierFlags([.command, .option, .shift]).rawValue
    )
    static let escape = Shortcut(keyCode: 53 /* esc */, modifiers: 0)
    /// Conversation mode. ⇧⌥Space: one modifier away from the default ⌥Space dictation
    /// shortcut, so it is easy to find, while staying clear of ⌘⌥⇧Space (Dictate and Fix
    /// Mistakes) and of every macOS system action.
    static let defaultConversation = Shortcut(
        keyCode: 49 /* space */,
        modifiers: NSEvent.ModifierFlags([.shift, .option]).rawValue
    )

    /// A swallowed global keyDown must not reserve an ordinary typing key without a modifier.
    /// Validate at the registration boundary: persisted or imported settings are untrusted
    /// input and can bypass the UI entirely.
    func isSafeGlobalHotkey(allowBareEscape: Bool = false) -> Bool {
        let allowedModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let flags = modifierFlags
        guard flags.subtracting(allowedModifiers).isEmpty else { return false }
        if !flags.isEmpty { return true }
        if allowBareEscape, keyCode == Self.escape.keyCode { return true }
        return Self.functionKeyCodes.contains(keyCode)
    }

    static let functionKeyCodes: Set<UInt16> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109,
        103, 111, 105, 107, 113, 106, 64, 79, 80, 90,
    ]

    /// Human-readable form, e.g. "⌥Space" or "esc".
    var displayString: String {
        var s = ""
        let f = modifierFlags
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option) { s += "⌥" }
        if f.contains(.shift) { s += "⇧" }
        if f.contains(.command) { s += "⌘" }
        s += Self.keyName(for: keyCode)
        return s
    }

    static func keyName(for keyCode: UInt16) -> String {
        switch keyCode {
        case 49: return String(localized: "key.space", defaultValue: "Space", comment: "Name of the space bar on a shortcut keycap; use the name printed on Mac keyboards")
        case 53: return "esc"
        case 36: return "↩"
        case 51: return "⌫"
        case 48: return "⇥"
        case 0: return "A"; case 1: return "S"; case 2: return "D"; case 3: return "F"
        case 4: return "H"; case 5: return "G"; case 6: return "Z"; case 7: return "X"
        case 8: return "C"; case 9: return "V"; case 11: return "B"; case 12: return "Q"
        case 13: return "W"; case 14: return "E"; case 15: return "R"; case 17: return "T"
        case 16: return "Y"; case 32: return "U"; case 34: return "I"; case 31: return "O"
        case 35: return "P"; case 37: return "L"; case 38: return "J"; case 40: return "K"
        case 45: return "N"; case 46: return "M"
        default: return String(localized: "Key \(keyCode)", comment: "Shortcut display for an unnamed key; the argument is its key code")
        }
    }
}

// MARK: - Curated transcription models

/// Which on-device backend runs a given model.
/// Parakeet goes through FluidAudio; everything else through WhisperKit.
enum ModelBackend: String, Codable, Sendable {
    case whisperKit
    case parakeet
}

/// A selectable transcription model. `whisperKitName` maps to a WhisperKit model identifier
/// for `.whisperKit` models, and to a descriptive variant id for `.parakeet` ones.
struct ModelDescriptor: Identifiable, Equatable, Sendable {
    let id: String              // stable id == settings.activeModelID
    let displayName: String
    let whisperKitName: String  // WhisperKit model repo/name
    let approxSizeMB: Int
    let speed: Int              // 1...5
    let accuracy: Int           // 1...5
    let note: String
    let isDefault: Bool
    var backend: ModelBackend = .whisperKit

    /// Whether this model can publish changing hypotheses while recording. Keep this next to the
    /// backend capability so Settings never promises live UI that the active engine cannot run.
    var supportsLiveTranscriptPreview: Bool { backend == .parakeet }

    /// Which Parakeet weights a `.parakeet` model loads; nil for WhisperKit models.
    var parakeetVariant: ParakeetVariant? {
        backend == .parakeet ? ParakeetVariant(rawValue: id) : nil
    }

    /// Four choices, named for what the user wants rather than for the model that provides
    /// it. Six near-identical Whisper sizes asked people to research an answer they have no
    /// way to research; these cover the real cases — the good default, the slightly more
    /// accurate one, the one for weak hardware, and the one for languages outside Europe.
    ///
    /// Order is the recommendation. Whisper Turbo is last on purpose (17 Oct 2026): on Italian
    /// it is no more accurate than Parakeet (Open ASR multilingual 4.69 vs 4.81), it is several
    /// times slower, it invents text on silence, and with English terms inside Italian speech
    /// it tends to translate them. It stays only for languages Parakeet does not cover.
    /// Evidence: the model benchmark on branch bench/fluidaudio-0.17
    /// (docs/research/2026-10-17-model-comparison-benchmark.md there).
    static let curated: [ModelDescriptor] = [
        // Default. Transducer on the Neural Engine: much faster than Whisper at a third of
        // the parameters, and native on the 25 European languages we sell into.
        // `displayName` and `note` are display text only: the persisted identity is `id`.
        ModelDescriptor(id: "parakeet-v3",
                        displayName: String(localized: "Fast", comment: "Model name: the recommended default model"),
                        whisperKitName: "parakeet-tdt-0.6b-v3-coreml",
                        approxSizeMB: 483, speed: 5, accuracy: 4,
                        note: String(localized: "Parakeet v3 · 25 European languages · recommended",
                                     comment: "Model note; keep the model name Parakeet v3"),
                        isDefault: true, backend: .parakeet),
        // Optional, not the default: Moondream's post-training of the same v3 network, same
        // speed. On the 17 Oct 2026 benchmark it cut word errors by ~6% relative and text
        // invented on silent clips from 5 to 2 of 18 — below the 20% bar for replacing the
        // default, and measured on synthetic voices only.
        ModelDescriptor(id: "parakeet-ultra",
                        displayName: String(localized: "Accurate", comment: "Model name: a slightly more accurate alternative to the default model"),
                        whisperKitName: "parakeet-ultra-coreml",
                        approxSizeMB: 632, speed: 5, accuracy: 5,
                        note: String(localized: "Parakeet Ultra · 25 European languages · slightly more accurate, larger download",
                                     comment: "Model note; keep the model name Parakeet Ultra"),
                        isDefault: false, backend: .parakeet),
        ModelDescriptor(id: "base",
                        displayName: String(localized: "Light", comment: "Model name: the small, lightweight model"),
                        whisperKitName: "openai_whisper-base",
                        approxSizeMB: 147, speed: 4, accuracy: 2,
                        note: String(localized: "Whisper Base · smaller download, lower accuracy",
                                     comment: "Model note; keep the model name Whisper Base"),
                        isDefault: false),
        ModelDescriptor(id: "large-v3-turbo",
                        displayName: String(localized: "Maximum coverage", comment: "Model name: the model covering the most languages"),
                        whisperKitName: "openai_whisper-large-v3-v20240930_turbo",
                        approxSizeMB: 1638, speed: 2, accuracy: 4,
                        note: String(localized: "Whisper Large v3 Turbo · only for languages outside Europe · much slower",
                                     comment: "Model note; keep the model name Whisper Large v3 Turbo"),
                        isDefault: false),
    ]

    static func descriptor(for id: String) -> ModelDescriptor {
        curated.first(where: { $0.id == id }) ?? curated.first(where: { $0.isDefault })!
    }
}

/// The Parakeet weights Dictari can load through FluidAudio. Raw values are the catalog ids;
/// both variants share v3's tokenizer, window and decoder/joint contract, so one engine runs
/// either one and only the files differ.
enum ParakeetVariant: String, CaseIterable, Sendable {
    case v3 = "parakeet-v3"
    case ultra = "parakeet-ultra"

    /// Key of the variant's entry in ModelIntegrityManifest.json.
    var manifestModelID: String {
        switch self {
        case .v3: return "parakeet-tdt-0.6b-v3-coreml"
        case .ultra: return "parakeet-ultra-coreml"
        }
    }
}

// MARK: - History

/// One completed (or failed) dictation, stored locally only.
struct HistoryEntry: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var date: Date
    var text: String
    var durationSeconds: Double
    var wordCount: Int
    var latencyMs: Int
    var appName: String?
    var appBundleID: String?
    var language: String?
    var tag: String?                   // e.g. "no speech", "failed", "too far"
    /// Measured loudness of the speech (90th percentile of frame levels). Optional because
    /// entries written before this existed have none. Without it a "too far" rejection is
    /// impossible to diagnose: the entry says it was rejected but not by how much.
    var speechLevel: Float?
    /// The user's hand correction from History, kept beside the original transcript (which stays
    /// the reference for recovery matching). Optional so history.json written before it decodes.
    var correctedText: String?

    /// What copy, export and the list show: the correction when there is one.
    var displayText: String {
        if let correctedText, correctedText.contains(where: { !$0.isWhitespace }) { return correctedText }
        return text
    }
    /// Stretches of `text` the engine was unsure of, as UTF-16 ranges into `text` (see
    /// `UncertainSpan`). nil = no confidence information (older entries, unscored engines);
    /// empty = scored, and every word was confident. Optional so old history.json decodes.
    var uncertainSpans: [UncertainSpan]? = nil

    /// "revised" records a successful post-processing action, not a failed dictation.
    var isFailure: Bool { tag != nil && tag != "revised" }
}

/// Resolves a persisted meeting choice against the applications available right now.
///
/// Process identifiers are deliberately absent: they change on every launch. The saved bundle
/// identifier remains unchanged when an app is closed and becomes resolvable again when that app
/// returns, including after replacing or updating its `.app` bundle.
enum MeetingApplicationSelection {
    static func normalizedBundleID(_ bundleID: String?) -> String? {
        guard let bundleID = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bundleID.isEmpty else { return nil }
        return bundleID
    }

    static func resolve(savedBundleID: String?, in runningBundleIDs: [String]) -> String? {
        guard let savedBundleID = normalizedBundleID(savedBundleID) else { return nil }
        return runningBundleIDs.first { $0 == savedBundleID }
    }
}

// MARK: - Persisted settings snapshot

/// All user preferences. Persisted as JSON; observed via `SettingsStore.data`.
struct SettingsData: Codable, Equatable, Sendable {
    // General
    var launchAtLogin = true
    var appearance: AppearanceMode = .system
    var pillStyle: PillStyle = .compact
    var pillPosition: PillPosition = .topCenter
    var alwaysShowPill = true
    /// User-dragged pill origin (screen coords). Overrides `pillPosition` once set.
    var pillCustomOrigin: CGPoint? = nil
    // Optional additions keep existing settings files decodable.
    var applicationLanguages: [String: String]?
    var applicationNames: [String: String]?
    var applicationWritingRules: [String: AppWritingRule]?
    var selectedDictationProfile: String?
    var customDictationProfiles: [CustomDictationProfile]?
    var profileLanguages: [String: String]?
    /// Stable identity and last display name for the meeting source. Keeping the bundle identifier
    /// instead of an application path lets the selection survive replacing or updating the app.
    var meetingApplicationBundleID: String?
    var meetingApplicationName: String?
    /// `nil` means the pre-existing default: include the user's microphone.
    var meetingIncludeMicrophone: Bool?
    /// Reserved for the real-time transcription feature. Optional so older settings remain valid.
    var realtimeTranscriptionEnabled: Bool?
    var defaultLanguage = "auto"        // "auto" or ISO 639-1
    /// "Languages I speak": what "auto" may choose between (see `SpokenLanguages`). `nil`
    /// means never chosen, so the Mac's own preferred languages apply.
    var spokenLanguages: [String]?
    var effectiveSpokenLanguages: [String] { SpokenLanguages.sanitized(spokenLanguages) }
    var injectionMethod: InjectionMethod = .paste
    var restoreClipboard = true
    /// Smart behaviour: when ON, if a text field is focused the transcript is pasted into
    /// it directly; otherwise it's shown in the pill (and copied). When OFF, never auto-paste
    /// — always show the transcript in the pill and copy it.
    var autoPasteIntoFocus = true
    var autoCapitalize = true
    var trailingSpace = true
    var showTranscriptPreview = true
    /// Spoken punctuation ("virgola", "a capo", "new line"). Optional so older settings decode;
    /// `nil` means off.
    var spokenCommands: Bool?
    var spokenCommandsEnabled: Bool {
        get { spokenCommands ?? false }
        set { spokenCommands = newValue }
    }
    /// Live typing: words typed into the focused field while the user speaks. Optional so
    /// older settings decode; `nil` means off. Deliberately a new key rather than
    /// `realtimeTranscriptionEnabled`, which an earlier Accessibility-based preview used:
    /// nobody who opted into that gets synthetic keystrokes without opting in again.
    var liveTyping: Bool?
    var liveTypingEnabled: Bool {
        get { liveTyping ?? false }
        set { liveTyping = newValue }
    }

    // Shortcuts
    var interactionMode: InteractionMode = .toggle
    var dictationShortcut: Shortcut = .defaultDictation
    var cancelShortcut: Shortcut = .escape
    /// Conversation mode's shortcut as chosen by the user. Both halves are optional so settings
    /// written before the mode existed decode (the synthesized decoder throws on a missing
    /// non-optional key), and so "never chosen" (nil → ⇧⌥Space) stays distinct from "turned
    /// off" (`conversationModeDisabled == true`). Read and write through `conversationShortcut`.
    var conversationShortcutChoice: Shortcut?
    var conversationModeDisabled: Bool?

    /// nil = Conversation mode is off. Collisions are resolved where the shortcut is armed
    /// (`ConversationPolicy.effectiveShortcut`), never by rewriting the user's choice here.
    var conversationShortcut: Shortcut? {
        get { conversationModeDisabled == true ? nil : (conversationShortcutChoice ?? .defaultConversation) }
        set {
            if let newValue {
                conversationShortcutChoice = newValue
                conversationModeDisabled = nil
            } else {
                conversationModeDisabled = true
            }
        }
    }

    // Sound / capture
    var soundCues = true
    var inputDeviceUID: String? = nil
    var vadEnabled = false
    /// Seconds of silence before auto-stop. 2.5 rather than 2.0: dictating is not reading,
    /// and a person composing a sentence pauses to think. Anything under ~2 s cuts them off
    /// mid-thought, which is far more annoying than a recording that runs half a second long.
    var vadSilenceSeconds: Double = 2.5
    var proximityFilter: ProximityFilter?
    var vadSensitivity: Int = 3

    // Models
    var activeModelID = "parakeet-v3"
    /// Set once by `SettingsStore.migrate`.
    ///
    /// Optional on purpose. The synthesized `Decodable` throws `keyNotFound` for a missing
    /// non-optional property — it does not fall back to the declared default — so adding a
    /// required key here would make every settings file written by an older build fail to
    /// decode and silently reset the user to factory defaults. Optionals decode to `nil`
    /// instead, and `nil` reads as "not migrated yet".
    var didMigrateToParakeetDefault: Bool?

    // Stats
    var assumedTypingWPM = 40

    // History
    /// Minutes to keep history. Optional so files written before hour-granularity existed
    /// still decode; `effectiveRetention` folds the old day-based value in.
    var historyRetentionMinutes: Int?
    var historyRetentionDays = 0        // legacy, days; superseded by the field above

    // AI agents. Every field is optional so older settings snapshots remain decodable, and
    // nil always means denied. The local MCP process reads this same snapshot and fails closed.
    var mcpEnabled: Bool?
    var mcpHistoryAccess: Bool?
    var mcpStatisticsAccess: Bool?
    var mcpMediaAccess: Bool?
    var mcpVocabularyAccess: Bool?
    var mcpAllowProposals: Bool?

    /// The retention actually in force, folding the legacy day-based value forward so an
    /// existing choice is not silently reset to "forever".
    var effectiveRetention: HistoryRetention {
        if let minutes = historyRetentionMinutes,
           let match = HistoryRetention(rawValue: minutes) {
            return match
        }
        switch historyRetentionDays {
        case 7:    return .oneWeek
        case 30:   return .thirtyDays
        case 90:   return .thirtyDays   // no 90-day step any more; nearest kept window
        case 365:  return .oneYear
        default:   return .forever
        }
    }
}

// MARK: - Lightweight dictation profiles

enum DictationProfile: String, CaseIterable, Identifiable, Sendable {
    case standard, code, email, notes
    var id: String { rawValue }
    var label: String {
        // Display only: the persisted selection is `rawValue`.
        switch self {
        case .standard: String(localized: "Default", comment: "Built-in dictation profile name")
        case .code: String(localized: "Code", comment: "Built-in dictation profile name: for writing code")
        case .email: String(localized: "Email", comment: "Built-in dictation profile name")
        case .notes: String(localized: "Notes", comment: "Built-in dictation profile name")
        }
    }
    var detail: String {
        switch self {
        case .standard: String(localized: "Uses the capitalisation and spacing set in Dictation.", comment: "Profile description")
        case .code: String(localized: "Keeps case and punctuation; adds no trailing space.", comment: "Profile description")
        case .email: String(localized: "Capitalises the first letter and adds a trailing space.", comment: "Profile description")
        case .notes: String(localized: "Capitalises the first letter and ends each dictation with a new line.",
                            comment: "Profile description")
        }
    }
}

enum ProfileEnding: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, space, newline
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: String(localized: "Nothing", comment: "Profile ending: add nothing after the text")
        case .space: String(localized: "profile.ending.space", defaultValue: "Space",
                            comment: "Profile ending: add a space after the text")
        case .newline: String(localized: "New line", comment: "Profile ending: add a line break after the text")
        }
    }
    var suffix: String {
        switch self { case .none: ""; case .space: " "; case .newline: "\n" }
    }
}

enum ProfileWritingBehavior: String, Codable, CaseIterable, Identifiable, Sendable {
    case appRules, off, ask, automatic
    var id: String { rawValue }
    var label: String {
        switch self {
        case .appRules: String(localized: "Use app rules", comment: "Profile writing behaviour")
        case .off: String(localized: "Off", comment: "Setting value: disabled")
        case .ask: String(localized: "Ask after pasting", comment: "Profile writing behaviour")
        case .automatic: String(localized: "Revise before inserting", comment: "Profile writing behaviour")
        }
    }
}

struct CustomDictationProfile: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var language: String?
    var capitalize: Bool
    var ending: ProfileEnding
    var writingBehavior: ProfileWritingBehavior
    var writingAction: String

    /// The default name is only a starting suggestion the user edits; once saved it is user data.
    init(id: String = "custom:" + UUID().uuidString,
         name: String = String(localized: "New profile", comment: "Default name of a new dictation profile"),
         language: String? = nil, capitalize: Bool = true, ending: ProfileEnding = .space,
         writingBehavior: ProfileWritingBehavior = .appRules, writingAction: String = "correct") {
        self.id = id
        self.name = name
        self.language = language
        self.capitalize = capitalize
        self.ending = ending
        self.writingBehavior = writingBehavior
        self.writingAction = writingAction
    }
}

enum CustomProfileError: LocalizedError {
    case invalidName, duplicateName, invalidIdentifier, tooManyProfiles, invalidLanguage, invalidWritingAction
    var errorDescription: String? {
        switch self {
        case .invalidName: String(localized: "Enter a profile name of 1–80 characters.", comment: "Profile validation error")
        case .duplicateName: String(localized: "A profile with this name already exists. Choose another name.",
                                    comment: "Profile validation error")
        case .invalidIdentifier: String(localized: "This profile has an invalid identifier.", comment: "Profile validation error")
        case .tooManyProfiles: String(localized: "You can save up to 100 custom profiles.", comment: "Profile validation error")
        case .invalidLanguage: String(localized: "Choose a supported profile language.", comment: "Profile validation error")
        case .invalidWritingAction: String(localized: "Choose a supported writing action.", comment: "Profile validation error")
        }
    }
}

struct DictationPreferences: Equatable, Sendable {
    let language: String
    let capitalize: Bool
    let suffix: String

    func format(_ text: String) -> String {
        guard text.contains(where: { !$0.isWhitespace }) else { return text }
        var result = text
        if capitalize, let first = result.firstIndex(where: { !$0.isWhitespace }) {
            result.replaceSubrange(first...first, with: String(result[first]).uppercased())
        }
        return result + suffix
    }
}

extension SettingsData {
    var dictationProfile: DictationProfile {
        DictationProfile(rawValue: selectedDictationProfile ?? "") ?? .standard
    }

    var selectedCustomDictationProfile: CustomDictationProfile? {
        guard let selectedDictationProfile else { return nil }
        return customDictationProfiles?.first { $0.id == selectedDictationProfile }
    }

    var activeDictationProfileID: String {
        selectedCustomDictationProfile?.id ?? dictationProfile.rawValue
    }

    var activeDictationProfileName: String {
        selectedCustomDictationProfile?.name ?? dictationProfile.label
    }

    mutating func saveCustomProfile(_ profile: CustomDictationProfile) throws {
        var profile = profile
        profile.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !profile.name.isEmpty, profile.name.count <= 80 else { throw CustomProfileError.invalidName }
        guard profile.id.hasPrefix("custom:"), profile.id.count > 7, profile.id.count <= 128 else {
            throw CustomProfileError.invalidIdentifier
        }
        let names = DictationProfile.allCases.map(\.label)
            + (customDictationProfiles ?? []).filter { $0.id != profile.id }.map(\.name)
        guard !names.contains(where: { $0.caseInsensitiveCompare(profile.name) == .orderedSame }) else {
            throw CustomProfileError.duplicateName
        }
        if let language = profile.language,
           !["auto", "en", "it", "es", "fr", "de", "pt", "ru", "uk"].contains(language) { throw CustomProfileError.invalidLanguage }
        guard WritingAction(rawValue: profile.writingAction) != nil else { throw CustomProfileError.invalidWritingAction }
        var profiles = customDictationProfiles ?? []
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            guard profiles.count < 100 else { throw CustomProfileError.tooManyProfiles }
            profiles.append(profile)
        }
        customDictationProfiles = profiles
    }

    mutating func removeCustomProfile(id: String) {
        customDictationProfiles?.removeAll { $0.id == id }
        if selectedDictationProfile == id { selectedDictationProfile = DictationProfile.standard.rawValue }
    }

    func customProfileDraft(copying profileID: String? = nil) -> CustomDictationProfile {
        var draft = CustomDictationProfile(capitalize: autoCapitalize, ending: trailingSpace ? .space : .none)
        var baseName = String(localized: "New profile", comment: "Default name of a new dictation profile")
        if let original = customDictationProfiles?.first(where: { $0.id == profileID }) {
            let newID = draft.id
            draft = original
            draft.id = newID
            baseName = Self.copyName(of: original.name)
        } else if let profileID, let builtin = DictationProfile(rawValue: profileID) {
            var settings = self
            settings.selectedDictationProfile = builtin.rawValue
            let preferences = settings.dictationPreferences(for: nil)
            draft.language = profileLanguages?[builtin.rawValue]
            draft.capitalize = preferences.capitalize
            draft.ending = preferences.suffix == "\n" ? .newline : (preferences.suffix == " " ? .space : .none)
            draft.writingBehavior = builtin == .code ? .off : .appRules
            baseName = Self.copyName(of: builtin.label)
        }
        // Leave room for a numeric suffix even when duplicating a maximum-length name.
        baseName = String(baseName.prefix(72))
        let names = DictationProfile.allCases.map(\.label) + (customDictationProfiles ?? []).map(\.name)
        var candidate = baseName
        var suffix = 2
        while names.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) {
            candidate = "\(baseName) \(suffix)"
            suffix += 1
        }
        draft.name = candidate
        return draft
    }

    /// Name suggested for a duplicated profile. It becomes user data once saved.
    private static func copyName(of name: String) -> String {
        String(localized: "\(name) copy", comment: "Suggested name of a duplicated profile; the argument is the original name")
    }

    func dictationPreferences(for bundleID: String?) -> DictationPreferences {
        let appLanguage = bundleID.flatMap { applicationLanguages?[$0] }
        let spoken = effectiveSpokenLanguages
        if let custom = selectedCustomDictationProfile {
            let language = appLanguage ?? custom.language ?? defaultLanguage
            return .init(language: SpokenLanguages.resolve(language, spoken: spoken),
                         capitalize: custom.capitalize, suffix: custom.ending.suffix)
        }
        let profile = dictationProfile
        let language = SpokenLanguages.resolve(
            appLanguage ?? profileLanguages?[profile.rawValue] ?? defaultLanguage, spoken: spoken
        )
        switch profile {
        case .standard: return .init(language: language, capitalize: autoCapitalize, suffix: trailingSpace ? " " : "")
        case .code: return .init(language: language, capitalize: false, suffix: "")
        case .email: return .init(language: language, capitalize: true, suffix: " ")
        case .notes: return .init(language: language, capitalize: true, suffix: "\n")
        }
    }
}
