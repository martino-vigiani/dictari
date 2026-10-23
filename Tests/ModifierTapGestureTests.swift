// ModifierTapGestureTests.swift
// A modifier-only dictation shortcut must fire only when the modifier is *tapped alone*.
//
// The regressions these pin were silent and system-wide: with Right-⌘ as the shortcut, ⌘C
// started dictation; with Right-⌥, typing @ # [ on the Italian layout (⌥ò ⌥à ⌥è) did too;
// and because left/right were read from device-independent flags, releasing Right-⌘ while
// Left-⌘ was held looked like a press. The gesture is value-only, so every case runs here
// without an event tap.

import AppKit
import XCTest

final class ModifierTapGestureTests: XCTestCase {

    // Device-independent family bits.
    private let cmd = CGEventFlags.maskCommand.rawValue
    private let opt = CGEventFlags.maskAlternate.rawValue
    private let shift = CGEventFlags.maskShift.rawValue
    private let ctrl = CGEventFlags.maskControl.rawValue
    /// NX_NONCOALSESCEDMASK: present on real hardware events, irrelevant to matching.
    private let nonCoalesced: UInt64 = 0x100

    private let rightCommand: UInt16 = 54
    private let leftCommand: UInt16 = 55
    private let leftShift: UInt16 = 56
    private let rightOption: UInt16 = 61
    private let rightControl: UInt16 = 62
    private let capsLock: UInt16 = 57

    private let ms: UInt64 = 1_000_000
    private let t0: UInt64 = 5_000_000_000

    private func config(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags,
                        pushToTalk: Bool = false) -> ModifierTapGesture.Configuration {
        .init(keyCode: keyCode, modifiers: modifiers, pushToTalk: pushToTalk)
    }

    private func flags(_ keyCode: UInt16, _ raw: UInt64) -> ModifierTapGesture.Input {
        .flagsChanged(keyCode: keyCode, flags: raw | nonCoalesced)
    }

    // MARK: Toggle: tap alone

    func testToggleFiresOnTheReleaseOfABareTap() {
        let c = config(rightCommand, [.command])
        var g = ModifierTapGesture()
        XCTAssertEqual(g.handle(flags(rightCommand, cmd | 0x10), configuration: c, now: t0), .none,
                       "the press alone must not fire: a key may still follow it")
        XCTAssertEqual(g.handle(flags(rightCommand, 0), configuration: c, now: t0 + 120 * ms), .activate)
        XCTAssertEqual(g.phase, .idle)
    }

    func testCommandCWithRightCommandShortcutNeverToggles() {
        let c = config(rightCommand, [.command])
        var g = ModifierTapGesture()
        _ = g.handle(flags(rightCommand, cmd | 0x10), configuration: c, now: t0)
        XCTAssertEqual(g.handle(.keyDown(isRevisionChord: false), configuration: c, now: t0 + 60 * ms), .none)
        XCTAssertEqual(g.handle(flags(rightCommand, 0), configuration: c, now: t0 + 150 * ms), .none)
    }

    func testItalianOptionCharactersWithRightOptionShortcutNeverToggle() {
        // ⌥ò = @, ⌥à = #, ⌥è = [ on the Italian layout.
        let c = config(rightOption, [.option])
        var g = ModifierTapGesture()
        _ = g.handle(flags(rightOption, opt | 0x40), configuration: c, now: t0)
        XCTAssertEqual(g.handle(.keyDown(isRevisionChord: false), configuration: c, now: t0 + 40 * ms), .none)
        XCTAssertEqual(g.handle(flags(rightOption, 0), configuration: c, now: t0 + 90 * ms), .none)
    }

    func testToggleDoesNotFireForAHoldLongerThanTheTapWindow() {
        let c = config(rightCommand, [.command])
        var g = ModifierTapGesture()
        _ = g.handle(flags(rightCommand, cmd | 0x10), configuration: c, now: t0)
        XCTAssertEqual(g.handle(flags(rightCommand, 0), configuration: c,
                                now: t0 + ModifierTapGesture.tapAloneWindowNanos + 1), .none)

        _ = g.handle(flags(rightCommand, cmd | 0x10), configuration: c, now: t0)
        XCTAssertEqual(g.handle(flags(rightCommand, 0), configuration: c,
                                now: t0 + ModifierTapGesture.tapAloneWindowNanos), .activate,
                       "the window is inclusive")
    }

    func testAnotherModifierDuringTheTapInterruptsIt() {
        let c = config(rightCommand, [.command])
        var g = ModifierTapGesture()
        _ = g.handle(flags(rightCommand, cmd | 0x10), configuration: c, now: t0)
        _ = g.handle(flags(leftShift, cmd | shift | 0x10 | 0x02), configuration: c, now: t0 + 30 * ms)
        _ = g.handle(flags(leftShift, cmd | 0x10), configuration: c, now: t0 + 60 * ms)
        XCTAssertEqual(g.handle(flags(rightCommand, 0), configuration: c, now: t0 + 90 * ms), .none)
    }

    func testMouseButtonDuringTheTapInterruptsIt() {
        let c = config(rightCommand, [.command])
        var g = ModifierTapGesture()
        _ = g.handle(flags(rightCommand, cmd | 0x10), configuration: c, now: t0)
        XCTAssertEqual(g.handle(.pointerDown, configuration: c, now: t0 + 50 * ms), .none)
        XCTAssertEqual(g.handle(flags(rightCommand, 0), configuration: c, now: t0 + 90 * ms), .none,
                       "⌘-click is not a tap of ⌘")
    }

    func testANewTapAfterAnInterruptedOneStillFires() {
        let c = config(rightCommand, [.command])
        var g = ModifierTapGesture()
        _ = g.handle(flags(rightCommand, cmd | 0x10), configuration: c, now: t0)
        _ = g.handle(.keyDown(isRevisionChord: false), configuration: c, now: t0 + 10 * ms)
        _ = g.handle(flags(rightCommand, 0), configuration: c, now: t0 + 20 * ms)
        _ = g.handle(flags(rightCommand, cmd | 0x10), configuration: c, now: t0 + 500 * ms)
        XCTAssertEqual(g.handle(flags(rightCommand, 0), configuration: c, now: t0 + 560 * ms), .activate)
    }

    func testTypingWithoutAGestureIsIgnored() {
        let c = config(rightCommand, [.command])
        var g = ModifierTapGesture()
        XCTAssertEqual(g.handle(.keyDown(isRevisionChord: false), configuration: c, now: t0), .none)
        XCTAssertEqual(g.handle(.pointerDown, configuration: c, now: t0), .none)
        XCTAssertEqual(g.phase, .idle)
    }

    // MARK: Left / right

    func testTheOtherSideOfTheSameFamilyNeverTriggers() {
        let c = config(rightCommand, [.command])
        var g = ModifierTapGesture()
        // Left-⌘ has its own key code; it never matches a Right-⌘ shortcut.
        _ = g.handle(flags(leftCommand, cmd | 0x08), configuration: c, now: t0)
        XCTAssertEqual(g.handle(flags(leftCommand, 0), configuration: c, now: t0 + 50 * ms), .none)
    }

    func testRightCommandPressedWhileLeftCommandIsHeldIsAChord() {
        let c = config(rightCommand, [.command])
        var g = ModifierTapGesture()
        // Left-⌘ is held; Right-⌘ goes down and up. The device-independent flags read
        // "⌘ only" throughout, which is exactly what used to fire.
        _ = g.handle(flags(leftCommand, cmd | 0x08), configuration: c, now: t0)
        XCTAssertEqual(g.handle(flags(rightCommand, cmd | 0x08 | 0x10), configuration: c,
                                now: t0 + 30 * ms), .none)
        XCTAssertEqual(g.handle(flags(rightCommand, cmd | 0x08), configuration: c,
                                now: t0 + 60 * ms), .none,
                       "releasing Right-⌘ while Left-⌘ is held is a release, not a press")
    }

    func testReleaseOfOurSideIsDetectedEvenWhileTheOtherSideIsStillDown() {
        let c = config(rightCommand, [.command], pushToTalk: true)
        var g = ModifierTapGesture()
        XCTAssertEqual(g.handle(flags(rightCommand, cmd | 0x10), configuration: c, now: t0), .activate)
        _ = g.handle(flags(leftCommand, cmd | 0x10 | 0x08), configuration: c, now: t0 + 400 * ms)
        XCTAssertEqual(g.handle(flags(rightCommand, cmd | 0x08), configuration: c,
                                now: t0 + 800 * ms), .deactivate)
    }

    func testRightControlUsesItsOwnDeviceBit() {
        let c = config(rightControl, [.control])
        var g = ModifierTapGesture()
        _ = g.handle(flags(rightControl, ctrl | 0x2000), configuration: c, now: t0)
        XCTAssertEqual(g.handle(flags(rightControl, 0), configuration: c, now: t0 + 80 * ms), .activate)
        XCTAssertTrue(ModifierKeyIdentity.isDown(keyCode: 59, flags: ctrl | 0x01))
        XCTAssertFalse(ModifierKeyIdentity.isDown(keyCode: 62, flags: ctrl | 0x01))
    }

    func testEventsWithoutDeviceBitsFallBackToTheFamilyFlag() {
        // Synthetic events may carry no device-dependent bits at all.
        XCTAssertTrue(ModifierKeyIdentity.isDown(keyCode: rightCommand, flags: cmd))
        XCTAssertFalse(ModifierKeyIdentity.isDown(keyCode: rightCommand, flags: 0))
        let c = config(rightCommand, [.command])
        var g = ModifierTapGesture()
        _ = g.handle(.flagsChanged(keyCode: rightCommand, flags: cmd), configuration: c, now: t0)
        XCTAssertEqual(g.handle(.flagsChanged(keyCode: rightCommand, flags: 0), configuration: c,
                                now: t0 + 50 * ms), .activate)
    }

    func testShortcutStoredWithoutItsOwnFamilyStillMatches() {
        XCTAssertEqual(config(rightOption, []).requiredModifiers, [.option])
        XCTAssertEqual(config(rightOption, [.option, .capsLock]).requiredModifiers, [.option])
        let c = config(rightOption, [])
        var g = ModifierTapGesture()
        _ = g.handle(flags(rightOption, opt | 0x40), configuration: c, now: t0)
        XCTAssertEqual(g.handle(flags(rightOption, 0), configuration: c, now: t0 + 50 * ms), .activate)
    }

    func testExtraConfiguredModifiersMustAlreadyBeHeld() {
        // "⇧ + tap Right-⌘": ⇧ is down before the tap, so it is not an interruption.
        let c = config(rightCommand, [.command, .shift])
        var g = ModifierTapGesture()
        _ = g.handle(flags(rightCommand, cmd | shift | 0x10 | 0x02), configuration: c, now: t0)
        XCTAssertEqual(g.handle(flags(rightCommand, shift | 0x02), configuration: c,
                                now: t0 + 50 * ms), .activate)
        // Without ⇧ it is not the configured shortcut.
        _ = g.handle(flags(rightCommand, cmd | 0x10), configuration: c, now: t0 + 1_000 * ms)
        XCTAssertEqual(g.handle(flags(rightCommand, 0), configuration: c, now: t0 + 1_050 * ms), .none)
    }

    // MARK: Push-to-talk

    func testPushToTalkStartsOnPressAndStopsOnRelease() {
        let c = config(rightOption, [.option], pushToTalk: true)
        var g = ModifierTapGesture()
        XCTAssertEqual(g.handle(flags(rightOption, opt | 0x40), configuration: c, now: t0), .activate)
        XCTAssertEqual(g.handle(flags(rightOption, 0), configuration: c, now: t0 + 3_000 * ms), .deactivate)
        XCTAssertEqual(g.phase, .idle)
    }

    func testPushToTalkChordWithinTheWindowAbortsAndOwesNoRelease() {
        let c = config(rightOption, [.option], pushToTalk: true)
        var g = ModifierTapGesture()
        XCTAssertEqual(g.handle(flags(rightOption, opt | 0x40), configuration: c, now: t0), .activate)
        XCTAssertEqual(g.handle(.keyDown(isRevisionChord: false), configuration: c,
                                now: t0 + ModifierTapGesture.pushToTalkAbortWindowNanos), .abort)
        XCTAssertEqual(g.handle(.keyDown(isRevisionChord: false), configuration: c,
                                now: t0 + 350 * ms), .none, "a second key must not abort twice")
        XCTAssertEqual(g.handle(flags(rightOption, 0), configuration: c, now: t0 + 400 * ms), .none,
                       "an aborted hold must not also stop (and transcribe) on release")
    }

    func testPushToTalkMouseButtonWithinTheWindowAborts() {
        let c = config(rightCommand, [.command], pushToTalk: true)
        var g = ModifierTapGesture()
        _ = g.handle(flags(rightCommand, cmd | 0x10), configuration: c, now: t0)
        XCTAssertEqual(g.handle(.pointerDown, configuration: c, now: t0 + 100 * ms), .abort)
    }

    func testPushToTalkIgnoresKeysTypedAfterTheWindow() {
        let c = config(rightOption, [.option], pushToTalk: true)
        var g = ModifierTapGesture()
        _ = g.handle(flags(rightOption, opt | 0x40), configuration: c, now: t0)
        XCTAssertEqual(g.handle(.keyDown(isRevisionChord: false), configuration: c,
                                now: t0 + ModifierTapGesture.pushToTalkAbortWindowNanos + 1), .none)
        XCTAssertEqual(g.handle(.pointerDown, configuration: c, now: t0 + 900 * ms), .none)
        XCTAssertEqual(g.handle(flags(rightOption, 0), configuration: c, now: t0 + 2_000 * ms), .deactivate)
    }

    func testPushToTalkIsNotAbortedByOtherModifiers() {
        let c = config(rightCommand, [.command], pushToTalk: true)
        var g = ModifierTapGesture()
        _ = g.handle(flags(rightCommand, cmd | 0x10), configuration: c, now: t0)
        XCTAssertEqual(g.handle(flags(leftShift, cmd | shift | 0x10 | 0x02), configuration: c,
                                now: t0 + 20 * ms), .none)
        XCTAssertEqual(g.handle(flags(rightCommand, shift | 0x02), configuration: c,
                                now: t0 + 900 * ms), .deactivate)
    }

    func testRevisionChordHandsTheHoldOffWithoutStoppingOrAborting() {
        // Right-⌘ push-to-talk, then ⌥⇧Space completes ⌘⌥⇧Space: the chord upgrades the capture
        // and its Space keyUp owns the stop. The ⌘ release afterwards must do nothing.
        let c = config(rightCommand, [.command], pushToTalk: true)
        var g = ModifierTapGesture()
        XCTAssertEqual(g.handle(flags(rightCommand, cmd | 0x10), configuration: c, now: t0), .activate)
        XCTAssertEqual(g.handle(.keyDown(isRevisionChord: true), configuration: c, now: t0 + 80 * ms), .none)
        XCTAssertEqual(g.handle(flags(rightCommand, 0), configuration: c, now: t0 + 900 * ms), .none)
    }

    func testPushToTalkPressOnTopOfAnotherModifierDoesNotStart() {
        let c = config(rightOption, [.option], pushToTalk: true)
        var g = ModifierTapGesture()
        XCTAssertEqual(g.handle(flags(rightOption, opt | shift | 0x40 | 0x02), configuration: c, now: t0), .none)
        XCTAssertEqual(g.handle(flags(rightOption, shift | 0x02), configuration: c, now: t0 + 50 * ms), .none)
    }

    func testDuplicatePressAfterALostReleaseStartsAgain() {
        let c = config(rightOption, [.option], pushToTalk: true)
        var g = ModifierTapGesture()
        _ = g.handle(flags(rightOption, opt | 0x40), configuration: c, now: t0)
        XCTAssertEqual(g.handle(flags(rightOption, opt | 0x40), configuration: c, now: t0 + 2_000 * ms), .activate)
        XCTAssertEqual(g.handle(.keyDown(isRevisionChord: false), configuration: c,
                                now: t0 + 2_100 * ms), .abort,
                       "the abort window restarts with the new press")
    }

    // MARK: Lost events

    func testResetForgetsAHalfFinishedGestureWithoutEmittingAnEdge() {
        let toggle = config(rightCommand, [.command])
        var g = ModifierTapGesture()
        _ = g.handle(flags(rightCommand, cmd | 0x10), configuration: toggle, now: t0)
        XCTAssertEqual(g.handle(.reset, configuration: toggle, now: t0 + 10 * ms), .none)
        XCTAssertEqual(g.handle(flags(rightCommand, 0), configuration: toggle, now: t0 + 50 * ms), .none)

        let ptt = config(rightCommand, [.command], pushToTalk: true)
        _ = g.handle(flags(rightCommand, cmd | 0x10), configuration: ptt, now: t0)
        g.reset()
        XCTAssertEqual(g.handle(flags(rightCommand, 0), configuration: ptt, now: t0 + 50 * ms), .none,
                       "a push-to-talk stop after lost events belongs to the physical-key poll")
    }

    // MARK: Tap-thread cost

    func testOrdinaryTypingNeverTakesTheGestureLock() {
        let c = config(rightCommand, [.command])
        XCTAssertFalse(ModifierTapGesture.mayObserve(flags: 0, configuration: c))
        XCTAssertFalse(ModifierTapGesture.mayObserve(flags: shift | 0x02, configuration: c))
        XCTAssertTrue(ModifierTapGesture.mayObserve(flags: cmd | 0x10, configuration: c))
        XCTAssertFalse(ModifierTapGesture.mayObserve(
            flags: CGEventFlags.maskAlphaShift.rawValue, configuration: config(capsLock, [])))
    }

    // MARK: Caps Lock (legacy)

    func testCapsLockToggleStillFiresPerPress() {
        let c = config(capsLock, [])
        var g = ModifierTapGesture()
        let lock = CGEventFlags.maskAlphaShift.rawValue
        XCTAssertEqual(g.handle(flags(capsLock, lock), configuration: c, now: t0), .activate)
        XCTAssertEqual(g.handle(flags(capsLock, 0), configuration: c, now: t0 + 500 * ms), .activate)
    }
}
