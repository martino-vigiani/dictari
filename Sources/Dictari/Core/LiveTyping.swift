// LiveTyping.swift
// Dictari — the pure half of "Live typing": what to type for each hypothesis, and when to stop.
//
// Live typing writes the transcript into the focused field *while* the user speaks, then
// corrects it as the model revises earlier words. Everything here is value logic with no
// AppKit, no CGEvent and no actor, so it is compiled into the host-less test bundle and into
// both app targets. The mechanical half (posting key events) is `LiveTyper`, and every
// decision about when a session may run lives in `AppCoordinator`.
//
// Why keystrokes and not Accessibility: an earlier "live field" wrote through
// `AXUIElementSetAttributeValue` and only ever worked in a handful of native text views;
// Chromium, Electron and most web editors ignore or mangle it. Backspace plus Unicode key
// events is the one channel every text field accepts, which is also why the safety rules
// below are strict: a keystroke into the wrong place is not reversible by us.

import Foundation
import Synchronization

// MARK: - Edits

/// One correction: press Backspace `deleteCount` times, then type `insert`.
/// `deleteCount` counts grapheme clusters (`Character`s) — one Backspace removes one.
struct LiveTypingEdit: Equatable, Sendable {
    var deleteCount: Int
    var insert: String

    var isEmpty: Bool { deleteCount == 0 && insert.isEmpty }
}

/// Turns a stream of hypotheses into the smallest edits that keep the field in step, while
/// letting only the unstable tail churn.
///
/// Stabilisation rule: a word is shown once two consecutive hypotheses agree on it (and on
/// every word before it). The last word of a hypothesis is usually cut mid-syllable, so this
/// alone holds back the trailing one or two words until the next pass confirms them.
///
/// Revision rule: text already typed is only retracted when the new wording is itself stable
/// (two hypotheses agree on it). A single hypothesis that flip-flops never moves the caret, so
/// the user does not see a word vanish and come back 400 ms later.
///
/// Invariant: `typed` is exactly what this planner has asked to be typed, and no edit ever
/// deletes more than `typed.count` characters. That is what makes "never Backspace beyond our
/// own text" a property of the type rather than of the caller.
struct LiveTypingPlanner: Sendable {
    /// What has been typed into the field so far (NFC).
    private(set) var typed = ""
    private var previousWords: [String]?

    init() {}

    // MARK: Partials

    /// Feed the next hypothesis. Returns the edit to apply, or nil when nothing should change.
    /// Always call this for every hypothesis — even ones that will not be written — so the
    /// stability history stays correct. Apply a returned edit with `commit(_:)` only once it
    /// has actually been posted.
    mutating func propose(partial: String) -> LiveTypingEdit? {
        let words = Self.words(in: partial)
        defer { previousWords = words }
        guard let previous = previousWords else { return nil }

        let typedWords = Self.words(in: typed)
        let stable = Self.commonPrefixCount(previous, words)
        let agree = Self.commonPrefixCount(typedWords, words)

        let targetCount: Int
        if agree == typedWords.count {
            // What is on screen is still a prefix of the hypothesis: only ever extend it.
            targetCount = max(stable, agree)
        } else if stable > agree {
            // The hypothesis contradicts typed text *and* the new wording is confirmed.
            targetCount = stable
        } else {
            // Contradiction not yet confirmed. Hold: it may flip back next pass.
            return nil
        }
        guard targetCount > 0 else { return nil }
        let target = words.prefix(targetCount).joined(separator: " ")
        let edit = Self.edit(from: typed, to: target)
        return edit.isEmpty ? nil : edit
    }

    /// Record that `edit` reached the field.
    mutating func commit(_ edit: LiveTypingEdit) {
        assert(edit.deleteCount <= typed.count, "live typing may only delete its own text")
        typed = String(typed.dropLast(min(edit.deleteCount, typed.count))) + Self.normalized(edit.insert)
    }

    // MARK: Final

    /// The minimal correction from what is typed to the authoritative final transcript
    /// (already formatted: capitalisation and trailing suffix included). Nil when the final
    /// text cannot be typed safely — it contains a line break or another control character,
    /// which as a synthetic key event means Return (a sent message) in chat apps.
    func finalEdit(for final: String) -> LiveTypingEdit? {
        guard Self.isTypeable(final) else { return nil }
        return Self.edit(from: typed, to: Self.normalized(final))
    }

    /// Removes everything this session typed.
    var revertEdit: LiveTypingEdit {
        LiveTypingEdit(deleteCount: typed.count, insert: "")
    }

    // MARK: Pure helpers

    static func edit(from current: String, to target: String) -> LiveTypingEdit {
        let target = normalized(target)
        let currentCharacters = Array(current)
        let targetCharacters = Array(target)
        var common = 0
        let limit = min(currentCharacters.count, targetCharacters.count)
        while common < limit, currentCharacters[common] == targetCharacters[common] {
            common += 1
        }
        return LiveTypingEdit(
            deleteCount: currentCharacters.count - common,
            insert: String(targetCharacters[common...])
        )
    }

    /// Words of a hypothesis, whitespace-collapsed and stripped of control characters, so a
    /// partial can never type a line break or a tab.
    static func words(in text: String) -> [String] {
        normalized(text)
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map { word in
                String(String.UnicodeScalarView(word.unicodeScalars.filter { !isControl($0) }))
            }
            .filter { !$0.isEmpty }
    }

    static func isTypeable(_ text: String) -> Bool {
        !text.unicodeScalars.contains(where: isControl)
    }

    /// C0/C1 controls only (general category Cc). Not `CharacterSet.controlCharacters`, which
    /// also covers format characters such as the zero-width joiner inside emoji sequences.
    static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .control
    }

    static func normalized(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
    }

    static func commonPrefixCount(_ a: [String], _ b: [String]) -> Int {
        var count = 0
        while count < a.count, count < b.count, a[count] == b[count] { count += 1 }
        return count
    }

    /// Splits text into key-event payloads of at most `maxUTF16` UTF-16 units without ever
    /// cutting a grapheme cluster (an emoji or an accented letter arrives whole).
    static func chunks(of text: String, maxUTF16: Int = 20) -> [String] {
        var result: [String] = []
        var current = ""
        var units = 0
        for character in text {
            let length = character.utf16.count
            if units + length > maxUTF16, !current.isEmpty {
                result.append(current)
                current = ""
                units = 0
            }
            current.append(character)
            units += length
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

// MARK: - Safety policy

/// What Accessibility said about the focused element when the session started.
enum LiveTypingFocus: Equatable, Sendable {
    case editable, unknown, notEditable, secure
}

enum LiveTypingAbortReason: String, Equatable, Sendable {
    /// The user pressed a key or clicked: the caret may have moved, so a Backspace could
    /// delete their text.
    case userInput
    /// Another app came to the front.
    case appChanged
    /// Secure Event Input is on (a password field somewhere, Terminal's secure entry).
    case secureInput
    case secureField
    case fieldNotEditable
    /// Key events could not be created or the typer is unavailable.
    case postFailed
}

enum LiveTypingDecision: Equatable, Sendable {
    /// Safe to post this edit now.
    case write
    /// Not now, but nothing is wrong: the focus probe is still running or a modifier is held
    /// (a synthetic key with ⌥ or ⌘ down would become a shortcut).
    case hold
    /// Stop writing for the rest of the session. What is already typed stays.
    case abort(LiveTypingAbortReason)
}

/// A snapshot of everything the policy looks at. Pure data, so the policy is testable.
struct LiveTypingConditions: Equatable, Sendable {
    var userInputSinceStart = false
    var frontmostAppUnchanged = true
    var secureInputEnabled = false
    /// nil while the one-shot focus probe is still running.
    var focus: LiveTypingFocus? = .editable
    var modifiersHeld = false
}

enum LiveTypingPolicy {
    /// Ordered so the most dangerous condition wins: anything that means "the keystrokes may
    /// land somewhere else" aborts before anything that merely means "wait".
    static func decide(_ conditions: LiveTypingConditions) -> LiveTypingDecision {
        if conditions.secureInputEnabled { return .abort(.secureInput) }
        if conditions.userInputSinceStart { return .abort(.userInput) }
        if !conditions.frontmostAppUnchanged { return .abort(.appChanged) }
        switch conditions.focus {
        case .secure: return .abort(.secureField)
        case .notEditable: return .abort(.fieldNotEditable)
        case nil: return .hold
        case .editable, .unknown: break
        }
        if conditions.modifiersHeld { return .hold }
        return .write
    }
}

// MARK: - User input, observed from the event tap

/// Marks every key event Dictari's live typer posts (`CGEventField.eventSourceUserData`), so
/// the global event tap can tell them from the user's own keystrokes and skip them.
enum SyntheticInputMarker {
    /// "DICTARI" in ASCII: arbitrary, but no other process has a reason to use it.
    static let liveTyping: Int64 = 0x44_49_43_54_41_52_49
}

/// Two monotonic counters bumped by the hotkey event tap for every *user* key press and mouse
/// button press it lets through. Lock-free on purpose: the tap sees every keystroke on the
/// machine and must not take a lock or hop to the main actor per event. Readers compare a
/// snapshot taken when live typing started with one taken before each write.
final class UserInputMonitor: Sendable {
    static let shared = UserInputMonitor()

    struct Snapshot: Equatable, Sendable {
        let keys: UInt64
        let pointer: UInt64
    }

    private let keys = Atomic<UInt64>(0)
    private let pointer = Atomic<UInt64>(0)

    init() {}

    func noteKeyPress() { keys.add(1, ordering: .relaxed) }
    func notePointerPress() { pointer.add(1, ordering: .relaxed) }

    var snapshot: Snapshot {
        Snapshot(keys: keys.load(ordering: .relaxed), pointer: pointer.load(ordering: .relaxed))
    }
}
