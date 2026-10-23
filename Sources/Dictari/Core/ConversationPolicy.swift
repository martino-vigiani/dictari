// ConversationPolicy.swift
// Dictari — Conversation mode: keep listening, deliver each pause, stop on the next press.
//
// Every decision the coordinator makes for a conversation lives here as a value-only function,
// so the whole lifecycle (start, pause → deliver → keep listening, stop, cancel, silent pauses,
// ordering, pill growth) is covered by the host-less test suite. `AppCoordinator` only executes
// what these functions answer.

import AppKit
import Foundation

enum ConversationPolicy {

    // MARK: Shortcut validity

    /// Why a conversation shortcut cannot be used. `nil` from `validate` means it is usable.
    enum ShortcutProblem: Equatable, Sendable {
        /// Collides with dictation, cancel, or the fixed correction shortcut.
        case duplicate
        /// A bare printable key or a modifier on its own. The conversation shortcut is always
        /// matched on a keyDown and swallowed, so a bare key would disappear from every app.
        case unsafe
        /// Option Command Space belongs to Finder Search (see `Shortcut.finderSearch`).
        case systemOwned
    }

    /// "Needs a modifier or a function key" is exactly what makes a swallowed global keyDown
    /// safe.
    /// Modifier-only conversation shortcuts are out of scope (their tap/hold gesture machinery
    /// belongs to the dictation shortcut alone).
    static func validate(
        _ shortcut: Shortcut,
        dictation: Shortcut,
        cancel: Shortcut
    ) -> ShortcutProblem? {
        if shortcut == .finderSearch { return .systemOwned }
        if modifierKeyCodes.contains(shortcut.keyCode) { return .unsafe }
        guard shortcut.isSafeGlobalHotkey() else { return .unsafe }
        if shortcut == dictation || shortcut == cancel || shortcut == .revisionDictation {
            return .duplicate
        }
        return nil
    }

    /// The shortcut actually armed. A colliding persisted value (the user later moved dictation
    /// onto ⇧⌥Space, or edited settings.json) disables the mode instead of stealing a key that
    /// another action already owns.
    static func effectiveShortcut(
        _ stored: Shortcut?,
        dictation: Shortcut,
        cancel: Shortcut
    ) -> Shortcut? {
        guard let stored, validate(stored, dictation: dictation, cancel: cancel) == nil else {
            return nil
        }
        return stored
    }

    /// Virtual key codes of the modifier keys themselves (shift/control/option/command, both
    /// sides, and caps lock). Mirrors `HotkeyManager.modifierKeyCodes`.
    static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62]

    // MARK: Activation

    enum ActivationSource: Equatable, Sendable {
        case conversationShortcut
        case dictationShortcut
        case revisionShortcut
        /// The pill's finish button or any other explicit "stop" request.
        case stopRequest
    }

    enum ActivationAction: Equatable, Sendable {
        case startConversation
        /// Finish the segment in progress, play the stop cue once, and end the conversation.
        case endConversation
        /// The conversation shortcut pressed during an ordinary dictation: it stops that
        /// dictation, exactly like pressing its own shortcut again would.
        case stopDictation
        /// Not a conversation concern: the ordinary dictation handling applies unchanged.
        case ordinary
        case ignore
    }

    /// The conversation shortcut is always a toggle, whatever the interaction mode: holding a
    /// key for a whole conversation would defeat its purpose. While a conversation runs, every
    /// Dictari shortcut means "stop" — the user should not have to remember which one started it.
    static func activation(
        _ source: ActivationSource,
        state: DictationState,
        conversationActive: Bool
    ) -> ActivationAction {
        if conversationActive {
            // `.transcribing` during a conversation means it has already been stopped and is
            // delivering its last segments; another press must not start anything over them.
            return state == .listening ? .endConversation : .ignore
        }
        guard source == .conversationShortcut else { return .ordinary }
        switch state {
        case .listening: return .stopDictation
        case .transcribing: return .ignore
        case .idle, .success, .error, .cancelled: return .startConversation
        }
    }

    // MARK: Pauses

    /// Used when the user has not turned on "Stop After Silence": long enough not to split a
    /// sentence at a breath, short enough that a finished thought lands promptly.
    static let defaultSilenceSeconds: Double = 1.2

    /// A conversation always auto-stops on silence — that is the mode. The user's own quiet
    /// period applies when they chose one; otherwise a conversational default.
    static func silenceSeconds(vadEnabled: Bool, configuredSeconds: Double) -> Double {
        vadEnabled ? configuredSeconds : defaultSilenceSeconds
    }

    enum AutoStopAction: Equatable, Sendable {
        /// Cut the finished segment off the running capture and keep listening.
        case deliverSegmentAndContinue
        /// The capture itself ended underneath us (audio route change): deliver what was said
        /// and end the conversation, exactly as an ordinary dictation ends on a route change.
        case endConversation
        /// Not a conversation: the ordinary auto-stop path.
        case ordinary
    }

    static func autoStop(conversationActive: Bool, state: DictationState,
                         captureContinues: Bool) -> AutoStopAction {
        guard conversationActive else { return .ordinary }
        guard state == .listening else { return .ordinary }
        return captureContinues ? .deliverSegmentAndContinue : .endConversation
    }

    // MARK: Cancel

    enum CancelAction: Equatable, Sendable {
        /// Discard the segment being recorded and end the conversation. Segments whose pause
        /// was already reached are the user's finished words and still land; the pill shows
        /// "transcribing" until they have.
        case discardCurrentAndFinishPending
        /// Nothing is left to deliver: an ordinary cancellation.
        case cancelNow
        /// Not a conversation: the ordinary cancel path.
        case ordinary
    }

    static func cancel(conversationActive: Bool, state: DictationState,
                       pendingSegments: Int) -> CancelAction {
        guard conversationActive, state == .listening else { return .ordinary }
        return pendingSegments > 0 ? .discardCurrentAndFinishPending : .cancelNow
    }

    // MARK: Segments

    enum SegmentDisposition: Equatable, Sendable {
        case transcribe
        /// Silence, a mis-trigger, or a voice across the room: dropped without a History entry,
        /// a safety copy or any message, and the conversation keeps listening. An ordinary
        /// dictation reports these ("No audio", "Too far") because the user asked for that one
        /// recording; in a conversation they are just the gaps between turns.
        case discard
    }

    static func segmentDisposition(
        duration: Double,
        peak: Float,
        speechLevel: Float,
        minimumSpeechLevel: Float
    ) -> SegmentDisposition {
        if AccidentalSession.isAccidental(duration: duration, peak: peak, speechLevel: speechLevel,
                                          minimumSpeechLevel: minimumSpeechLevel) {
            return .discard
        }
        if peak < AccidentalSession.silencePeak { return .discard }
        if speechLevel < minimumSpeechLevel { return .discard }
        return .transcribe
    }

    /// After transcription: a segment the model heard nothing in is a gap, not a failure.
    static func discardsTranscript(_ trimmedTranscript: String) -> Bool {
        trimmedTranscript.isEmpty
    }

    // MARK: End of conversation

    enum EndPresentation: Equatable, Sendable {
        /// Some text had nowhere to go: show all of it, expanded when long.
        case copied(String)
        case success(DictationState.SuccessKind)
        case error(String)
        /// Nothing was said, or nothing needs saying: close quietly.
        case quiet
    }

    static func endPresentation(_ outcome: ConversationOutcome) -> EndPresentation {
        // Undelivered words outrank everything else: they exist only in the pill and on the
        // clipboard until the user acts on them.
        if !outcome.copiedTranscript.text.isEmpty { return .copied(outcome.copiedTranscript.text) }
        if let failure = outcome.lastFailure { return .error(failure) }
        if let kind = outcome.lastDeliveredKind { return .success(kind) }
        return .quiet
    }

    // MARK: Pill

    /// The pill during a conversation. It stays the listening capsule while every pause lands
    /// in a field; once something could not be pasted it becomes a transcript card that keeps
    /// growing with the conversation instead of hiding after the first line.
    static func pillLayout(state: DictationState, conversationActive: Bool,
                           copiedTranscript: String) -> ConversationPillLayout {
        guard conversationActive, state == .listening, !copiedTranscript.isEmpty else { return .none }
        return TranscriptPillPolicy.canExpand(copiedTranscript) ? .expanded : .compact
    }
}

/// How the listening pill is drawn during a conversation. Value-only so `PillGeometry` can size
/// the card host-less.
enum ConversationPillLayout: Equatable, Sendable {
    case none
    /// A short transcript under the listening controls.
    case compact
    /// The full-height card: the transcript scrolls, pinned to its newest line.
    case expanded
}

/// What one delivered segment reports back to its conversation.
enum ConversationSegmentResult: Equatable, Sendable {
    case discarded
    case delivered(DictationState.SuccessKind, text: String)
    case failed(String)
}

/// Text that could not be pasted, in speaking order. A paste verification can report a failed
/// landing after later segments were already appended, so segments are kept by index rather
/// than appended blindly.
struct ConversationTranscript: Equatable, Sendable {
    private(set) var segments: [Segment] = []

    struct Segment: Equatable, Sendable {
        let index: Int
        let text: String
    }

    mutating func insert(_ text: String, at index: Int) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !segments.contains(where: { $0.index == index }) else { return }
        let position = segments.firstIndex(where: { $0.index > index }) ?? segments.endIndex
        segments.insert(Segment(index: index, text: trimmed), at: position)
    }

    /// Segments are sentences spoken after a pause: one space between them, except where a
    /// spoken "new line" already ended the previous one.
    var text: String {
        var out = ""
        for segment in segments {
            if !out.isEmpty, !out.hasSuffix("\n") { out += " " }
            out += segment.text
        }
        return out
    }
}

/// Aggregate of every segment's result, from which the end-of-conversation pill is chosen.
struct ConversationOutcome: Equatable, Sendable {
    private(set) var copiedTranscript = ConversationTranscript()
    private(set) var lastDeliveredKind: DictationState.SuccessKind?
    private(set) var lastFailure: String?

    mutating func record(_ result: ConversationSegmentResult, index: Int) {
        switch result {
        case .discarded:
            break
        case .delivered(let kind, let text):
            if kind == .copiedToClipboard {
                copiedTranscript.insert(text, at: index)
            } else {
                lastDeliveredKind = kind
            }
        case .failed(let message):
            lastFailure = message
        }
    }

    /// A paste that was posted but later proved not to land (AX saw the field unchanged).
    mutating func recordFailedLanding(_ text: String, index: Int) {
        copiedTranscript.insert(text, at: index)
    }
}

/// Delivers segments strictly in the order they were spoken, even though each one is handed
/// over the moment its pause is reached and capture continues immediately.
///
/// Every enqueued job first waits for the previous job to finish completely — transcription,
/// formatting, paste and History — before it starts. That is what keeps segment 2 from pasting
/// before segment 1 when segment 1 is longer, and it also serializes engine access: the
/// coordinator's single `activeInference` slot and the WhisperKit `nonisolated(unsafe)` pipe
/// both rely on one transcription at a time.
@MainActor
final class OrderedSegmentChain {
    private var tail: Task<Void, Never>?
    private var jobs: [Task<Void, Never>] = []
    private(set) var pendingCount = 0

    /// The last enqueued job. Awaiting it awaits every job before it.
    var last: Task<Void, Never>? { tail }

    @discardableResult
    func enqueue(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = tail
        pendingCount += 1
        let task = Task { @MainActor [weak self] in
            // A cancelled predecessor still completes its `value`; ordering holds either way.
            await previous?.value
            await work()
            self?.pendingCount -= 1
        }
        tail = task
        jobs.append(task)
        return task
    }

    /// Cancel every job not yet finished. Each job observes `Task.isCancelled` itself.
    func cancelAll() {
        for job in jobs { job.cancel() }
    }

    /// Drop finished references so a long conversation does not accumulate task handles.
    func pruneFinished() {
        if pendingCount == 0 { jobs.removeAll() }
    }
}
