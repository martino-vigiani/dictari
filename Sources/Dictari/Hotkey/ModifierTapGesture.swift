import AppKit
import CoreGraphics

// MARK: - Physical modifier identity

/// Which *physical* modifier key a virtual key code names, and how to read that key's own
/// state out of a `CGEventFlags` word.
///
/// The device-independent bits (`.maskCommand`, …) say "some Command key is down" and cannot
/// tell Left-⌘ from Right-⌘. A modifier-only shortcut always names one side through its key
/// code (54 is Right-⌘, 55 is Left-⌘, …), so the down/up edge of *that* key has to be read from
/// the device-dependent bits the HID driver sets per physical key (IOKit's `NX_DEVICE*KEYMASK`).
/// Without them, releasing Right-⌘ while Left-⌘ is still held looks like a press — which
/// toggled dictation on the release edge.
enum ModifierKeyIdentity {
    static let capsLockKeyCode: UInt16 = 57

    struct Bits: Equatable, Sendable {
        /// Device-independent family bit (`.maskCommand`, …).
        var family: UInt64
        /// Device-dependent bit of this exact physical key; 0 for Caps Lock.
        var side: UInt64
        /// Device-dependent bits of both sides of the family.
        var bothSides: UInt64
    }

    // NX_DEVICE* masks from IOKit/hidsystem/IOLLEvent.h.
    static let leftControl: UInt64 = 0x0000_0001
    static let leftShift: UInt64 = 0x0000_0002
    static let rightShift: UInt64 = 0x0000_0004
    static let leftCommand: UInt64 = 0x0000_0008
    static let rightCommand: UInt64 = 0x0000_0010
    static let leftOption: UInt64 = 0x0000_0020
    static let rightOption: UInt64 = 0x0000_0040
    static let rightControl: UInt64 = 0x0000_2000

    static func bits(for keyCode: UInt16) -> Bits? {
        let command = CGEventFlags.maskCommand.rawValue
        let shift = CGEventFlags.maskShift.rawValue
        let option = CGEventFlags.maskAlternate.rawValue
        let control = CGEventFlags.maskControl.rawValue
        switch keyCode {
        case 54: return Bits(family: command, side: rightCommand, bothSides: leftCommand | rightCommand)
        case 55: return Bits(family: command, side: leftCommand, bothSides: leftCommand | rightCommand)
        case 56: return Bits(family: shift, side: leftShift, bothSides: leftShift | rightShift)
        case 60: return Bits(family: shift, side: rightShift, bothSides: leftShift | rightShift)
        case 58: return Bits(family: option, side: leftOption, bothSides: leftOption | rightOption)
        case 61: return Bits(family: option, side: rightOption, bothSides: leftOption | rightOption)
        case 59: return Bits(family: control, side: leftControl, bothSides: leftControl | rightControl)
        case 62: return Bits(family: control, side: rightControl, bothSides: leftControl | rightControl)
        case capsLockKeyCode:
            return Bits(family: CGEventFlags.maskAlphaShift.rawValue, side: 0, bothSides: 0)
        default: return nil
        }
    }

    static func isModifierKey(_ keyCode: UInt16) -> Bool { bits(for: keyCode) != nil }

    /// Whether this exact physical key is down in `flags`.
    ///
    /// Falls back to the family bit only when the word carries *no* device bits for the family
    /// at all (a synthetic event posted without them); then the side is unknowable and the
    /// family bit is the best available answer. For Caps Lock this is the lock state, since the
    /// key produces one `flagsChanged` per press rather than a down/up pair.
    static func isDown(keyCode: UInt16, flags: UInt64) -> Bool {
        guard let bits = bits(for: keyCode) else { return false }
        if bits.bothSides != 0, flags & bits.bothSides != 0 {
            return flags & bits.side != 0
        }
        return flags & bits.family != 0
    }

    /// Whether the *other* key of the same family is held (Left-⌘ while the shortcut is Right-⌘).
    static func oppositeSideIsDown(keyCode: UInt16, flags: UInt64) -> Bool {
        guard let bits = bits(for: keyCode) else { return false }
        return flags & (bits.bothSides & ~bits.side) != 0
    }

    /// The device-independent family as `NSEvent.ModifierFlags` (empty for Caps Lock, which is
    /// not part of the matched modifier set).
    static func family(of keyCode: UInt16) -> NSEvent.ModifierFlags {
        switch keyCode {
        case 54, 55: return .command
        case 56, 60: return .shift
        case 58, 61: return .option
        case 59, 62: return .control
        default: return []
        }
    }

    /// Same mapping as `HotkeyManager.modifierFlags(from:)`, kept here so this file stays
    /// self-contained for the host-less test target.
    static func matchedModifiers(_ flags: UInt64) -> NSEvent.ModifierFlags {
        var result: NSEvent.ModifierFlags = []
        if flags & CGEventFlags.maskCommand.rawValue != 0 { result.insert(.command) }
        if flags & CGEventFlags.maskAlternate.rawValue != 0 { result.insert(.option) }
        if flags & CGEventFlags.maskControl.rawValue != 0 { result.insert(.control) }
        if flags & CGEventFlags.maskShift.rawValue != 0 { result.insert(.shift) }
        return result
    }
}

// MARK: - Tap-alone gesture

/// Value-only state machine that turns the raw event stream into activate / deactivate /
/// abort edges for a **modifier-only** dictation shortcut (e.g. Right-⌘ on its own).
///
/// A modifier's job is to modify other keys, so "the modifier went down" is not evidence the
/// user wanted dictation: with Right-⌘ as the shortcut, ⌘C started a session, and with
/// Right-⌥ the Italian layout's @ # [ (⌥ò ⌥à ⌥è) did too. So:
///
/// - **Toggle**: arm on the key's own down edge (only when it is pressed alone), fire on its up
///   edge — and only if nothing else (another key, another modifier, a mouse button) was pressed
///   in between and the whole tap took at most `tapAloneWindow`. A held modifier used for a
///   chord therefore never toggles dictation.
/// - **Push-to-talk**: start immediately on the down edge (waiting for the release would make
///   push-to-talk useless), but if an ordinary key or a mouse button goes down within
///   `pushToTalkAbortWindow`, the press was a chord: **abort** (discard, never transcribe).
///   After the window, keys typed during a long hold are the user's business and are ignored.
///   Other *modifiers* do not abort: the fixed ⌘⌥⇧Space correction chord is assembled on top of
///   a constituent-modifier shortcut, and a real chord always ends in an ordinary key anyway.
///
/// This lives in the tap thread's lock (see `RoutingBox.modifierGesture`) because it must see
/// every keystroke in order, synchronously; it is plain scalars so the critical section can
/// never allocate or block. It never decides to swallow anything: a modifier's `flagsChanged`
/// is always delivered to the system.
struct ModifierTapGesture: Equatable, Sendable {

    static let tapAloneWindowNanos: UInt64 = 400_000_000
    static let pushToTalkAbortWindowNanos: UInt64 = 300_000_000

    struct Configuration: Equatable, Sendable {
        var keyCode: UInt16
        /// Device-independent modifiers stored with the shortcut. The key's own family is added
        /// implicitly, so a shortcut persisted as "keyCode 54, no modifiers" still matches.
        var modifiers: NSEvent.ModifierFlags
        var pushToTalk: Bool

        var requiredModifiers: NSEvent.ModifierFlags {
            modifiers.intersection([.command, .option, .control, .shift])
                .union(ModifierKeyIdentity.family(of: keyCode))
        }
    }

    enum Input: Equatable, Sendable {
        /// A `flagsChanged` event: `keyCode` is the modifier key that changed.
        case flagsChanged(keyCode: UInt16, flags: UInt64)
        /// A non-modifier keyDown (including auto-repeats). `isRevisionChord` marks the fixed
        /// correction chord the tap has just taken, which hands the gesture off.
        case keyDown(isRevisionChord: Bool)
        /// Any mouse button went down.
        case pointerDown
        /// The tap lost events (disabled, restarted) or the configuration changed: forget
        /// everything without emitting an edge. A push-to-talk stop is then recovered by the
        /// MainActor's physical-key poll, never guessed here.
        case reset
    }

    enum Action: Equatable, Sendable {
        case none
        case activate
        case deactivate
        /// Push-to-talk only: the hold turned out to be a chord. Discard the session.
        case abort
    }

    enum Phase: Equatable, Sendable {
        case idle
        /// Toggle: the key is down alone; fires on release unless interrupted or too slow.
        case armed(downAt: UInt64, interrupted: Bool)
        /// Push-to-talk: `.activate` was emitted; `.deactivate` or `.abort` is owed.
        case holding(downAt: UInt64)
    }

    private(set) var phase: Phase = .idle

    init() {}

    mutating func reset() { phase = .idle }

    /// Whether a non-flagsChanged event could matter at all. Lets the tap skip the lock for
    /// ordinary typing: during any gesture the shortcut's own modifier is held, so its family
    /// bit is set on every event that could interrupt it.
    static func mayObserve(flags: UInt64, configuration: Configuration) -> Bool {
        guard let bits = ModifierKeyIdentity.bits(for: configuration.keyCode),
              configuration.keyCode != ModifierKeyIdentity.capsLockKeyCode else { return false }
        return flags & bits.family != 0
    }

    mutating func handle(_ input: Input, configuration: Configuration, now: UInt64) -> Action {
        switch input {
        case .reset:
            reset()
            return .none

        case .keyDown(let isRevisionChord):
            switch phase {
            case .idle:
                return .none
            case .armed(let downAt, _):
                phase = .armed(downAt: downAt, interrupted: true)
                return .none
            case .holding(let downAt):
                if isRevisionChord {
                    // The correction chord upgrades this capture and owns its release
                    // (Space keyUp). The modifier's own release must not stop it.
                    phase = .idle
                    return .none
                }
                guard Self.elapsed(since: downAt, now: now) <= Self.pushToTalkAbortWindowNanos
                else { return .none }
                phase = .idle
                return .abort
            }

        case .pointerDown:
            switch phase {
            case .idle:
                return .none
            case .armed(let downAt, _):
                phase = .armed(downAt: downAt, interrupted: true)
                return .none
            case .holding(let downAt):
                guard Self.elapsed(since: downAt, now: now) <= Self.pushToTalkAbortWindowNanos
                else { return .none }
                phase = .idle
                return .abort
            }

        case .flagsChanged(let keyCode, let flags):
            guard keyCode == configuration.keyCode else {
                // A different modifier moved while ours was down: a chord, not a tap.
                if case .armed(let downAt, _) = phase {
                    phase = .armed(downAt: downAt, interrupted: true)
                }
                return .none
            }
            if keyCode == ModifierKeyIdentity.capsLockKeyCode {
                return handleCapsLock(flags: flags, configuration: configuration, now: now)
            }
            if ModifierKeyIdentity.isDown(keyCode: keyCode, flags: flags) {
                return handleDown(flags: flags, configuration: configuration, now: now)
            }
            return handleUp(now: now)
        }
    }

    private mutating func handleDown(flags: UInt64, configuration: Configuration,
                                     now: UInt64) -> Action {
        let alone = ModifierKeyIdentity.matchedModifiers(flags) == configuration.requiredModifiers
            && !ModifierKeyIdentity.oppositeSideIsDown(keyCode: configuration.keyCode, flags: flags)
        guard alone else {
            // Pressed on top of other modifiers (or the other side of its own family): part of a
            // chord. A push-to-talk hold that is already running keeps running.
            if case .holding = phase { return .none }
            phase = .idle
            return .none
        }
        if configuration.pushToTalk {
            // A second down without an up means the release was lost; re-emitting activate is
            // harmless (the coordinator ignores it while a session is active).
            phase = .holding(downAt: now)
            return .activate
        }
        phase = .armed(downAt: now, interrupted: false)
        return .none
    }

    private mutating func handleUp(now: UInt64) -> Action {
        defer { phase = .idle }
        switch phase {
        case .idle:
            return .none
        case .armed(let downAt, let interrupted):
            guard !interrupted,
                  Self.elapsed(since: downAt, now: now) <= Self.tapAloneWindowNanos
            else { return .none }
            return .activate
        case .holding:
            return .deactivate
        }
    }

    /// Caps Lock emits one `flagsChanged` per press (the lock state flips) with no separate
    /// release, so tap-alone timing cannot apply. Toggle fires per press; push-to-talk follows
    /// the lock state. Kept only so a persisted Caps Lock shortcut behaves as before.
    private mutating func handleCapsLock(flags: UInt64, configuration: Configuration,
                                         now: UInt64) -> Action {
        guard ModifierKeyIdentity.matchedModifiers(flags) == configuration.requiredModifiers else {
            return .none
        }
        guard configuration.pushToTalk else { return .activate }
        if ModifierKeyIdentity.isDown(keyCode: ModifierKeyIdentity.capsLockKeyCode, flags: flags) {
            phase = .holding(downAt: now)
            return .activate
        }
        return handleUp(now: now)
    }

    private static func elapsed(since start: UInt64, now: UInt64) -> UInt64 {
        now >= start ? now - start : 0
    }
}
