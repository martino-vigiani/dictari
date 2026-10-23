// HotkeyMatchingTests.swift
// The swallow decision is the highest-consequence pure function in the app.
//
// It runs inside an active CGEventTap, so returning true removes the keystroke from every
// application on the machine. A match that is too broad silently eats a key the user needs;
// a match that is too narrow means the shortcut does nothing. Neither failure produces an
// error, and both are invisible until someone notices their keyboard behaving strangely —
// which is exactly the kind of bug that belongs in a test rather than in a bug report.

import AppKit
import XCTest

final class HotkeyMatchingTests: XCTestCase {

    private let space: UInt16 = 49
    private let escape: UInt16 = 53
    private let leftOption: UInt16 = 58

    private func snapshot(
        dictationKey: UInt16,
        dictationModifiers: NSEvent.ModifierFlags,
        cancelKey: UInt16 = 53,
        cancelModifiers: NSEvent.ModifierFlags = [],
        pushToTalk: Bool = false,
        dictating: Bool = false,
        deferredSubmitOnStopEnabled: Bool = false
    ) -> ShortcutSnapshot {
        ShortcutSnapshot(
            dictationKeyCode: dictationKey,
            dictationModifiers: dictationModifiers,
            cancelKeyCode: cancelKey,
            cancelModifiers: cancelModifiers,
            pushToTalk: pushToTalk,
            dictating: dictating,
            deferredSubmitOnStopEnabled: deferredSubmitOnStopEnabled
        )
    }

    // MARK: - The configured shortcut is taken

    func testSwallowsTheExactDictationCombo() {
        let s = snapshot(dictationKey: space, dictationModifiers: [.option, .command])
        XCTAssertTrue(s.swallows(
            type: .keyDown, keyCode: space, flags: [.maskAlternate, .maskCommand]))
    }

    /// The cancel shortcut is a bare Escape by default, so it may only be claimed while
    /// there is a session to cancel. Claiming it permanently took Escape away from every
    /// application on the machine.
    func testSwallowsTheCancelShortcutOnlyWhileDictating() {
        let idle = snapshot(dictationKey: space, dictationModifiers: [.option, .command])
        XCTAssertFalse(idle.swallows(type: .keyDown, keyCode: escape, flags: []),
                       "Escape was eaten system-wide with nothing to cancel")

        let active = snapshot(dictationKey: space, dictationModifiers: [.option, .command],
                              dictating: true)
        XCTAssertTrue(active.swallows(type: .keyDown, keyCode: escape, flags: []))
        XCTAssertTrue(active.routes(type: .keyDown, keyCode: escape, flags: []))
    }

    /// Regression: cancelling clears `dictating` before the physical Escape is released. The
    /// app must not receive an orphaned keyUp for the keyDown Dictari already swallowed.
    func testOwnedCancelEscapeKeyUpStaysSwallowedAfterDictationEnds() {
        let active = snapshot(dictationKey: space, dictationModifiers: [.option, .command],
                              dictating: true)
        let idle = snapshot(dictationKey: space, dictationModifiers: [.option, .command])

        let down = active.decide(type: .keyDown, keyCode: escape, flags: [],
                                 pressHeld: false, cancelPressHeld: false)
        let up = idle.decide(type: .keyUp, keyCode: escape, flags: [],
                             pressHeld: false, cancelPressHeld: down.swallow)

        XCTAssertTrue(up.swallow)
        XCTAssertFalse(up.route, "Cancel must run only on the owned keyDown")
    }

    /// Regression: Escape must remain available to the focused app when Dictari did not
    /// swallow its keyDown, even if dictation starts before that Escape is released.
    func testUnownedCancelEscapeKeyUpIsNotSwallowedWhenDictationStarts() {
        let active = snapshot(dictationKey: space, dictationModifiers: [.option, .command],
                              dictating: true)

        let up = active.decide(type: .keyUp, keyCode: escape, flags: [],
                               pressHeld: false, cancelPressHeld: false)

        XCTAssertFalse(up.swallow)
        XCTAssertFalse(up.route)
    }

    /// Regression: holding the swallowed cancel key can generate duplicate keyDown events
    /// after the first event has already closed the dictation session.
    func testOwnedCancelEscapeRepeatDoesNotCancelAgain() {
        let idle = snapshot(dictationKey: space, dictationModifiers: [.option, .command])

        let repeatedDown = idle.decide(type: .keyDown, keyCode: escape, flags: [],
                                       pressHeld: false, cancelPressHeld: true)

        XCTAssertTrue(repeatedDown.swallow)
        XCTAssertFalse(repeatedDown.route)
    }

    func testIdleEscapeDownAndUpReachFocusedAppWhenUnowned() {
        let idle = snapshot(dictationKey: space, dictationModifiers: [.option, .command])

        let down = idle.decide(type: .keyDown, keyCode: escape, flags: [],
                               pressHeld: false, cancelPressHeld: false)
        let up = idle.decide(type: .keyUp, keyCode: escape, flags: [],
                             pressHeld: false, cancelPressHeld: false)

        XCTAssertFalse(down.swallow)
        XCTAssertFalse(up.swallow)
    }

    /// Regression: the event-tap callback may record physical cancel-key ownership only when
    /// cancel wins shortcut priority; overlapping dictation/revision chords are not cancels.
    func testCancelPressOwnershipRequiresActiveExactNonOverlappingShortcut() {
        let active = snapshot(dictationKey: space, dictationModifiers: [.option, .command],
                              dictating: true)
        let idle = snapshot(dictationKey: space, dictationModifiers: [.option, .command])
        let overlapsDictation = snapshot(dictationKey: escape, dictationModifiers: [],
                                         dictating: true)
        let revision = Shortcut.revisionDictation
        let overlapsRevision = snapshot(
            dictationKey: escape,
            dictationModifiers: [],
            cancelKey: revision.keyCode,
            cancelModifiers: revision.modifierFlags,
            dictating: true
        )

        XCTAssertTrue(active.claimsCancelKeyDown(keyCode: escape, flags: []))
        XCTAssertFalse(idle.claimsCancelKeyDown(keyCode: escape, flags: []))
        XCTAssertFalse(overlapsDictation.claimsCancelKeyDown(keyCode: escape, flags: []))
        XCTAssertFalse(overlapsRevision.claimsCancelKeyDown(
            keyCode: revision.keyCode,
            flags: [.maskCommand, .maskAlternate, .maskShift]
        ))
    }

    // MARK: - Everything else must reach the focused app

    /// Plain Space is the single most-typed key on the machine. If a modifier mismatch ever
    /// stopped being checked, typing would break everywhere.
    func testDoesNotSwallowPlainSpace() {
        let s = snapshot(dictationKey: space, dictationModifiers: [.option, .command])
        XCTAssertFalse(s.swallows(type: .keyDown, keyCode: space, flags: []))
    }

    func testDoesNotSwallowASupersetOfTheModifiers() {
        let s = snapshot(dictationKey: space, dictationModifiers: [.option, .command])
        XCTAssertFalse(
            s.swallows(type: .keyDown, keyCode: space,
                            flags: [.maskAlternate, .maskCommand, .maskShift]),
            "⌥⌘⇧Space was eaten by a shortcut configured as ⌥⌘Space"
        )
    }

    func testDoesNotSwallowASubsetOfTheModifiers() {
        let s = snapshot(dictationKey: space, dictationModifiers: [.option, .command])
        XCTAssertFalse(s.swallows(type: .keyDown, keyCode: space, flags: [.maskCommand]))
    }

    func testDoesNotSwallowAnUnrelatedKey() {
        let s = snapshot(dictationKey: space, dictationModifiers: [.option, .command])
        // "A" with the same modifiers held.
        XCTAssertFalse(s.swallows(
            type: .keyDown, keyCode: 0, flags: [.maskAlternate, .maskCommand]))
    }

    /// Caps lock and the numeric keypad set flags of their own. They must not defeat a match.
    func testIgnoresFlagsOutsideTheMatchedSet() {
        let s = snapshot(dictationKey: space, dictationModifiers: [.option, .command])
        XCTAssertTrue(
            s.swallows(type: .keyDown, keyCode: space,
                            flags: [.maskAlternate, .maskCommand, .maskAlphaShift]),
            "caps lock stopped the shortcut from matching"
        )
    }

    // MARK: - Key release

    func testOwnedKeyUpIsBalancedInBothModesButOnlyRoutesPushToTalk() {
        let toggle = snapshot(dictationKey: space, dictationModifiers: [.option, .command])
        XCTAssertTrue(toggle.swallows(type: .keyUp, keyCode: space, flags: [], pressHeld: true))
        XCTAssertFalse(toggle.routes(type: .keyUp, keyCode: space, flags: [], pressHeld: true))

        let ptt = snapshot(dictationKey: space, dictationModifiers: [.option, .command],
                           pushToTalk: true)
        XCTAssertTrue(ptt.swallows(type: .keyUp, keyCode: space, flags: [], pressHeld: true))
        XCTAssertTrue(ptt.routes(type: .keyUp, keyCode: space, flags: [], pressHeld: true))
    }

    func testOwnedKeyRepeatsStaySwallowedAfterModifiersAreReleased() {
        let toggle = snapshot(dictationKey: space, dictationModifiers: [.option, .command])
        let repeatWithNoModifiers = toggle.decide(
            type: .keyDown, keyCode: space, flags: [], pressHeld: true
        )
        XCTAssertTrue(repeatWithNoModifiers.swallow)
        XCTAssertFalse(repeatWithNoModifiers.route)
        let duplicateDownWithMatchingModifiers = toggle.decide(
            type: .keyDown, keyCode: space, flags: [.maskAlternate, .maskCommand], pressHeld: true
        )
        XCTAssertTrue(duplicateDownWithMatchingModifiers.swallow)
        XCTAssertFalse(duplicateDownWithMatchingModifiers.route)

        // A fresh plain Space was never claimed by Dictari and must reach the target app.
        XCTAssertFalse(toggle.swallows(type: .keyDown, keyCode: space, flags: [], pressHeld: false))
        XCTAssertFalse(toggle.swallows(type: .keyUp, keyCode: space, flags: [], pressHeld: false))
    }

    func testUnownedTypingIsNeverSwallowedAcrossModifierCombinations() {
        for pushToTalk in [false, true] {
            let hotkey = snapshot(
                dictationKey: space,
                dictationModifiers: [.option, .command],
                pushToTalk: pushToTalk
            )
            for bits in 0..<16 {
                var flags: CGEventFlags = []
                if bits & 1 != 0 { flags.insert(.maskCommand) }
                if bits & 2 != 0 { flags.insert(.maskAlternate) }
                if bits & 4 != 0 { flags.insert(.maskControl) }
                if bits & 8 != 0 { flags.insert(.maskShift) }
                if bits != 3 {
                    XCTAssertFalse(hotkey.swallows(
                        type: .keyDown, keyCode: space, flags: flags, pressHeld: false
                    ))
                }
                XCTAssertFalse(hotkey.swallows(
                    type: .keyUp, keyCode: space, flags: flags, pressHeld: false
                ))
                XCTAssertFalse(hotkey.swallows(
                    type: .keyDown, keyCode: 0, flags: flags, pressHeld: false
                ))
            }
        }
    }

    /// The push-to-talk shortcut's key is an ordinary one (Space in ⌥⌘Space). Swallowing its
    /// release whenever it is seen ate the keyUp of every plain Space typed on the machine,
    /// leaving apps with a key that went down and never came back up.
    func testKeyUpIsNotSwallowedWhenWeNeverTookTheKeyDown() {
        let ptt = snapshot(dictationKey: space, dictationModifiers: [.option, .command],
                           pushToTalk: true)
        XCTAssertFalse(ptt.swallows(type: .keyUp, keyCode: space, flags: [], pressHeld: false))
    }

    func testUnrelatedKeyUpIsNeverSwallowed() {
        let ptt = snapshot(dictationKey: space, dictationModifiers: [.option, .command],
                           pushToTalk: true)
        XCTAssertFalse(ptt.swallows(type: .keyUp, keyCode: 0, flags: [], pressHeld: true))
    }

    // MARK: - Modifier-only shortcuts

    /// A modifier-only shortcut toggles on flagsChanged — but it is *observed*, never
    /// swallowed. Removing a modifier's flagsChanged from the stream hides that modifier
    /// from the whole system, including the window server's modifier-sensitive gestures,
    /// and gains nothing: a bare modifier press types nothing that could leak.
    func testFlagsChangedIsObservedButNeverSwallowed() {
        let regular = snapshot(dictationKey: space, dictationModifiers: [.option, .command])
        XCTAssertFalse(regular.routes(
            type: .flagsChanged, keyCode: leftOption, flags: [.maskAlternate]))

        let modifierOnly = snapshot(dictationKey: leftOption, dictationModifiers: [.option])
        XCTAssertTrue(modifierOnly.routes(
            type: .flagsChanged, keyCode: leftOption, flags: [.maskAlternate]))
        XCTAssertFalse(modifierOnly.swallows(
            type: .flagsChanged, keyCode: leftOption, flags: [.maskAlternate]))
    }

    // MARK: - Defaults

    /// The default must not collide with Spotlight (⌘Space) or Finder Search (⌥⌘Space),
    /// and must not be a bare key.
    func testDefaultShortcutIsSafe() {
        let d = Shortcut.defaultDictation
        XCTAssertEqual(d.keyCode, 49, "the default should still be Space")
        XCTAssertEqual(d.modifierFlags, [.option])
        XCTAssertNotEqual(d.modifierFlags, [.command], "⌘Space is Spotlight")
        XCTAssertNotEqual(d, .finderSearch, "⌥⌘Space is Finder Search")
    }

    func testDisplayStringUsesTheStandardGlyphOrder() {
        // macOS renders modifiers as ⌃⌥⇧⌘ regardless of press order.
        let s = Shortcut(
            keyCode: 49,
            modifiers: NSEvent.ModifierFlags.command.rawValue
                | NSEvent.ModifierFlags.option.rawValue
        )
        XCTAssertEqual(s.displayString.prefix(2), "⌥⌘")
    }

    // MARK: - Bit-packed transport

    /// The snapshot crosses to the tap thread as a single `UInt64`, so that the only lock the
    /// tap callback ever waits on is typed over a scalar and its critical section cannot be
    /// extended into something that blocks. That is only safe if the packing is lossless —
    /// a dropped modifier bit would silently stop the shortcut matching.
    func testSnapshotSurvivesTheRoundTripThroughItsPackedForm() {
        let originals = [
            snapshot(dictationKey: space, dictationModifiers: [.option]),
            snapshot(dictationKey: space, dictationModifiers: [.command, .option, .control, .shift]),
            snapshot(dictationKey: 58, dictationModifiers: [], cancelKey: 53,
                     cancelModifiers: [.control, .shift], pushToTalk: true, dictating: true,
                     deferredSubmitOnStopEnabled: true),
            snapshot(dictationKey: .max, dictationModifiers: [.shift],
                     cancelKey: .max, cancelModifiers: [.command]),
        ]
        for original in originals {
            let restored = ShortcutSnapshot(bits: original.bits)
            XCTAssertEqual(restored.dictationKeyCode, original.dictationKeyCode)
            XCTAssertEqual(restored.dictationModifiers, original.dictationModifiers)
            XCTAssertEqual(restored.cancelKeyCode, original.cancelKeyCode)
            XCTAssertEqual(restored.cancelModifiers, original.cancelModifiers)
            XCTAssertEqual(restored.pushToTalk, original.pushToTalk)
            XCTAssertEqual(restored.dictating, original.dictating)
            XCTAssertEqual(restored.deferredSubmitOnStopEnabled,
                           original.deferredSubmitOnStopEnabled)
        }
    }

    /// Modifiers outside the matched set have no bit reserved for them; they must be dropped
    /// on the way in rather than corrupting a neighbouring field.
    func testPackingIgnoresUnmatchedModifiers() {
        let s = snapshot(dictationKey: space, dictationModifiers: [.option, .capsLock, .function])
        let restored = ShortcutSnapshot(bits: s.bits)
        XCTAssertEqual(restored.dictationModifiers, [.option])
        XCTAssertEqual(restored.dictationKeyCode, space)
    }
}

// MARK: - Test conveniences

/// The production API answers two questions at once (route / swallow); the tests read better
/// asking one at a time.
private extension ShortcutSnapshot {
    func swallows(type: CGEventType, keyCode: UInt16, flags: CGEventFlags,
                  pressHeld: Bool = false) -> Bool {
        decide(type: type, keyCode: keyCode, flags: flags, pressHeld: pressHeld).swallow
    }

    func routes(type: CGEventType, keyCode: UInt16, flags: CGEventFlags,
                pressHeld: Bool = false) -> Bool {
        decide(type: type, keyCode: keyCode, flags: flags, pressHeld: pressHeld).route
    }
}

// MARK: - Auto-repeat

/// Holding the shortcut makes the system emit a keyDown every few tens of milliseconds.
/// In toggle mode each one flips dictation, so holding the key started and stopped a session
/// repeatedly and filled the history with zero-second entries and no transcript.
///
/// The tap callback owns that decision, so this mirrors its rule as a named predicate and
/// pins the behaviour: repeats are still swallowed (they must not leak into the focused app)
/// but must not drive side effects.
enum AutoRepeatPolicy {
    static func shouldDispatchSideEffects(type: CGEventType, isAutoRepeat: Bool) -> Bool {
        !(isAutoRepeat && type == .keyDown)
    }
}

final class AutoRepeatTests: XCTestCase {

    func testFirstKeyDownDrivesSideEffects() {
        XCTAssertTrue(AutoRepeatPolicy.shouldDispatchSideEffects(
            type: .keyDown, isAutoRepeat: false))
    }

    func testRepeatedKeyDownDoesNot() {
        XCTAssertFalse(
            AutoRepeatPolicy.shouldDispatchSideEffects(type: .keyDown, isAutoRepeat: true),
            "holding the shortcut would toggle dictation on every repeat"
        )
    }

    /// Release must always be delivered, or push-to-talk would never stop.
    func testKeyUpAlwaysDrivesSideEffects() {
        XCTAssertTrue(AutoRepeatPolicy.shouldDispatchSideEffects(
            type: .keyUp, isAutoRepeat: false))
        XCTAssertTrue(AutoRepeatPolicy.shouldDispatchSideEffects(
            type: .keyUp, isAutoRepeat: true))
    }

    func testFlagsChangedAlwaysDrivesSideEffects() {
        XCTAssertTrue(AutoRepeatPolicy.shouldDispatchSideEffects(
            type: .flagsChanged, isAutoRepeat: true))
    }
}

// MARK: - Deferred submit

/// The gate is intentionally tested without a real event tap. It is the exact
/// value-only decision invoked by the tap after normal shortcut routing declines
/// an event, so these tests cannot steal keyboard input from the test host.
final class DeferredSubmitGateTests: XCTestCase {
    private let returnKey: UInt16 = 36
    private let keypadEnter: UInt16 = 76

    func testReturnIsNeverSwallowedWithoutACoordinatorOpenedWindow() {
        let gate = DeferredSubmitGate()

        XCTAssertFalse(gate.swallows(type: .keyDown, keyCode: returnKey, flags: []))
        XCTAssertFalse(gate.swallows(type: .keyUp, keyCode: returnKey, flags: []))
    }

    func testBareReturnAndKeypadEnterAreSwallowedWithTheirOwnKeyUps() {
        let gate = DeferredSubmitGate()

        for keyCode in [returnKey, keypadEnter] {
            let token = gate.claim(openIfMissing: true)!
            XCTAssertTrue(gate.swallows(type: .keyDown, keyCode: keyCode, flags: []))
            // The release stays balanced even if a modifier was pressed afterwards.
            XCTAssertTrue(gate.swallows(type: .keyUp, keyCode: keyCode, flags: [.maskCommand]))
            XCTAssertEqual(gate.closeAndConsume(token), DeferredSubmitRequest(keyCode: keyCode))
        }
    }

    func testModifiedReturnAlwaysReachesTheFocusedApp() {
        let gate = DeferredSubmitGate()
        let token = gate.claim(openIfMissing: true)!

        for flags: CGEventFlags in [.maskCommand, .maskAlternate, .maskControl, .maskShift] {
            XCTAssertFalse(gate.swallows(type: .keyDown, keyCode: returnKey, flags: flags))
        }
        XCTAssertNil(gate.closeAndConsume(token))
    }

    func testRepeatAfterCloseAndReopenStaysSwallowedWithoutASecondSubmit() {
        let gate = DeferredSubmitGate()
        let firstToken = gate.claim(openIfMissing: true)!

        XCTAssertTrue(gate.swallows(type: .keyDown, keyCode: returnKey, flags: []))
        XCTAssertEqual(gate.closeAndConsume(firstToken), DeferredSubmitRequest(keyCode: returnKey))

        // The old Return remains physically held while a new window starts. Its
        // repeat is still ours, but must not become the new window's pending submit.
        let secondToken = gate.claim(openIfMissing: true)!
        XCTAssertTrue(gate.swallows(type: .keyDown, keyCode: returnKey, flags: []),
                      "key repeats must not leak into the frontmost app")
        XCTAssertFalse(gate.swallows(type: .keyUp, keyCode: keypadEnter, flags: []))
        XCTAssertNil(gate.closeAndConsume(secondToken))
        // The focused app still must not receive an unmatched keyUp.
        XCTAssertTrue(gate.swallows(type: .keyUp, keyCode: returnKey, flags: []))

        let thirdToken = gate.claim(openIfMissing: true)!
        XCTAssertTrue(gate.swallows(type: .keyDown, keyCode: returnKey, flags: []))
        XCTAssertEqual(gate.closeAndConsume(thirdToken), DeferredSubmitRequest(keyCode: returnKey))
    }

    func testKeypadEnterRequestPreservesTheExactKeyCodeForReplay() {
        let gate = DeferredSubmitGate()
        let token = gate.claim(openIfMissing: true)!

        XCTAssertTrue(gate.swallows(type: .keyDown, keyCode: keypadEnter, flags: []))
        XCTAssertTrue(gate.swallows(type: .keyDown, keyCode: returnKey, flags: []),
                      "the second physical Return is swallowed but cannot queue another replay")
        XCTAssertEqual(gate.closeAndConsume(token), DeferredSubmitRequest(keyCode: keypadEnter))
        XCTAssertTrue(gate.swallows(type: .keyUp, keyCode: keypadEnter, flags: []))
        XCTAssertTrue(gate.swallows(type: .keyUp, keyCode: returnKey, flags: []))
    }

    func testStaleCloseCannotConsumeANewerWindow() {
        let gate = DeferredSubmitGate()
        let staleToken = gate.claim(openIfMissing: true)!
        gate.close(staleToken)
        let currentToken = gate.claim(openIfMissing: true)!

        XCTAssertNil(gate.closeAndConsume(staleToken))
        XCTAssertTrue(gate.swallows(type: .keyDown, keyCode: returnKey, flags: []))
        XCTAssertEqual(gate.closeAndConsume(currentToken), DeferredSubmitRequest(keyCode: returnKey))
    }

    func testRepeatFromAKeyHeldBeforeTheWindowDoesNotQueueSubmit() {
        let gate = DeferredSubmitGate()
        let token = gate.claim(openIfMissing: true)!

        XCTAssertFalse(gate.swallows(
            type: .keyDown,
            keyCode: returnKey,
            flags: [],
            isAutoRepeat: true
        ))
        XCTAssertNil(gate.closeAndConsume(token))
    }

    func testReplayFailureIsObservableAfterThePhysicalReturnWasConsumed() {
        let gate = DeferredSubmitGate()
        let token = gate.claim(openIfMissing: true)!
        XCTAssertTrue(gate.swallows(type: .keyDown, keyCode: returnKey, flags: []))

        var attemptedKeyCode: UInt16?
        let outcome = gate.closeAndReplay(token, inputWasPosted: true) { keyCode in
            attemptedKeyCode = keyCode
            return false
        }

        XCTAssertEqual(outcome, .replayFailed)
        XCTAssertEqual(attemptedKeyCode, returnKey)
        XCTAssertEqual(gate.closeAndReplay(token, inputWasPosted: true) { _ in true }, .noRequest)
        XCTAssertTrue(gate.swallows(type: .keyUp, keyCode: returnKey, flags: []),
                      "the swallowed physical keyDown still owns its eventual keyUp")
    }
}

final class DeferredSubmitStopEdgeTests: XCTestCase {
    private let space: UInt16 = 49
    private let leftOption: UInt16 = 58

    private func snapshot(pushToTalk: Bool) -> ShortcutSnapshot {
        ShortcutSnapshot(
            dictationKeyCode: space,
            dictationModifiers: [.option, .command],
            pushToTalk: pushToTalk,
            dictating: true,
            deferredSubmitOnStopEnabled: true
        )
    }

    func testToggleStopEdgeArmsBeforeTheMainActorClaimsTheWindow() {
        let snapshot = snapshot(pushToTalk: false)
        XCTAssertTrue(snapshot.deferredSubmitStopEdge(
            type: .keyDown, keyCode: space, flags: [.maskAlternate, .maskCommand], pressHeld: false
        ))

        let gate = DeferredSubmitGate()
        gate.armAtStopEdge()
        let adopted = gate.claim(openIfMissing: true)!
        XCTAssertEqual(adopted, gate.claim(openIfMissing: true)!,
                       "claiming must adopt the tap generation")

        XCTAssertTrue(gate.swallows(type: .keyDown, keyCode: 36, flags: []))
        XCTAssertEqual(gate.closeAndConsume(adopted), DeferredSubmitRequest(keyCode: 36))
    }

    func testClaimWithoutFallbackCanAdoptOrDiscardAStaleTapWindow() {
        let gate = DeferredSubmitGate()
        XCTAssertNil(gate.claim(openIfMissing: false))

        gate.armAtStopEdge()
        let armedToken = gate.claim(openIfMissing: false)
        XCTAssertNotNil(armedToken, "a stale arm must be claimable so the coordinator can close it")
        gate.close(armedToken!)
        XCTAssertNil(gate.claim(openIfMissing: false))
    }

    func testPushToTalkArmsOnlyOnTheHeldKeyUpStopEdge() {
        let snapshot = snapshot(pushToTalk: true)

        XCTAssertFalse(snapshot.deferredSubmitStopEdge(
            type: .keyDown, keyCode: space, flags: [.maskAlternate, .maskCommand], pressHeld: true
        ))
        XCTAssertFalse(snapshot.deferredSubmitStopEdge(
            type: .keyUp, keyCode: space, flags: [], pressHeld: false
        ))
        XCTAssertTrue(snapshot.deferredSubmitStopEdge(
            type: .keyUp, keyCode: space, flags: [], pressHeld: true
        ))
    }

    func testDisabledSnapshotNeverArmsAtAnOtherwiseValidStopEdge() {
        var snapshot = snapshot(pushToTalk: false)
        snapshot.deferredSubmitOnStopEnabled = false

        XCTAssertFalse(snapshot.deferredSubmitStopEdge(
            type: .keyDown, keyCode: space, flags: [.maskAlternate, .maskCommand], pressHeld: false
        ))
    }

    /// A modifier-only toggle no longer fires on the press (that is how ⌘C started dictation
    /// with Right-⌘ as the shortcut). The stop edge is the tap-alone release the gesture fires
    /// on, so the single-event predicate must never arm for a modifier-only shortcut.
    func testModifierOnlyToggleArmsOnlyWhenTheTapGestureFires() {
        let snapshot = ShortcutSnapshot(
            dictationKeyCode: leftOption,
            dictationModifiers: [.option],
            pushToTalk: false,
            dictating: true,
            deferredSubmitOnStopEnabled: true
        )

        let pressDecision = snapshot.decide(
            type: .flagsChanged,
            keyCode: leftOption,
            flags: [.maskAlternate],
            pressHeld: false
        )
        XCTAssertTrue(pressDecision.route)
        XCTAssertFalse(pressDecision.swallow, "modifier flagsChanged must remain visible system-wide")
        XCTAssertFalse(snapshot.shouldArmDeferredSubmit(
            decision: pressDecision,
            type: .flagsChanged,
            keyCode: leftOption,
            flags: [.maskAlternate],
            pressHeld: false,
            isAutoRepeat: false
        ), "the press alone is not a stop: a key may still follow it")

        XCTAssertTrue(snapshot.deferredSubmitStopEdge(modifierGesture: .activate))
        XCTAssertFalse(snapshot.deferredSubmitStopEdge(modifierGesture: .none))
        XCTAssertFalse(snapshot.deferredSubmitStopEdge(modifierGesture: .deactivate))
        XCTAssertFalse(snapshot.deferredSubmitStopEdge(modifierGesture: .abort))
    }

    func testModifierOnlyPushToTalkArmsOnTheGestureReleaseButNeverOnAbort() {
        let snapshot = ShortcutSnapshot(
            dictationKeyCode: leftOption,
            dictationModifiers: [.option],
            pushToTalk: true,
            dictating: true,
            deferredSubmitOnStopEnabled: true
        )

        let releaseDecision = snapshot.decide(
            type: .flagsChanged,
            keyCode: leftOption,
            flags: [],
            pressHeld: false
        )
        XCTAssertTrue(releaseDecision.route)
        XCTAssertFalse(releaseDecision.swallow)

        XCTAssertTrue(snapshot.deferredSubmitStopEdge(modifierGesture: .deactivate))
        XCTAssertFalse(snapshot.deferredSubmitStopEdge(modifierGesture: .activate))
        XCTAssertFalse(snapshot.deferredSubmitStopEdge(modifierGesture: .abort),
                       "an aborted chord is discarded and must not reserve the next Return")
    }

    func testGestureStopEdgeNeedsTheCoordinatorOptInAndAModifierOnlyShortcut() {
        var modifierOnly = ShortcutSnapshot(
            dictationKeyCode: leftOption, dictationModifiers: [.option],
            pushToTalk: true, dictating: true, deferredSubmitOnStopEnabled: false)
        XCTAssertFalse(modifierOnly.deferredSubmitStopEdge(modifierGesture: .deactivate))
        modifierOnly.deferredSubmitOnStopEnabled = true
        XCTAssertTrue(modifierOnly.deferredSubmitStopEdge(modifierGesture: .deactivate))

        let keyed = snapshot(pushToTalk: true)
        XCTAssertFalse(keyed.deferredSubmitStopEdge(modifierGesture: .deactivate))
    }
}

// MARK: - Event-tap watchdog

/// The real watchdog reads CoreGraphics and run-loop state, but recovery is chosen by this
/// value-only seam so Secure Event Input can never accidentally become a bypass attempt.
final class HotkeyTapWatchdogPolicyTests: XCTestCase {
    private func health(
        secureInput: Bool = false,
        portValid: Bool = true,
        tapEnabled: Bool = true,
        runLoopAlive: Bool = true,
        heartbeatFresh: Bool = true,
        recoveringFromSecureInput: Bool = false
    ) -> HotkeyTapHealth {
        HotkeyTapHealth(
            secureInputEnabled: secureInput,
            portIsValid: portValid,
            tapIsEnabled: tapEnabled,
            runLoopIsAlive: runLoopAlive,
            heartbeatIsFresh: heartbeatFresh,
            recoveringFromSecureInput: recoveringFromSecureInput
        )
    }

    func testSecureInputMakesShortcutUnavailableWithoutTryingToBypassIt() {
        XCTAssertEqual(
            HotkeyTapWatchdogPolicy.action(for: health(
                secureInput: true,
                portValid: false,
                tapEnabled: false,
                runLoopAlive: false,
                heartbeatFresh: false
            )),
            .unavailable
        )
    }

    func testDisabledTapWithLivePortIsReenabled() {
        XCTAssertEqual(
            HotkeyTapWatchdogPolicy.action(for: health(tapEnabled: false)),
            .reenable
        )
    }

    func testLeavingSecureInputReenablesAndVerifiesEvenIfTapStillReportsEnabled() {
        XCTAssertEqual(
            HotkeyTapWatchdogPolicy.action(for: health(recoveringFromSecureInput: true)),
            .reenable
        )
    }

    func testInvalidPortRestartsTheTap() {
        XCTAssertEqual(
            HotkeyTapWatchdogPolicy.action(for: health(portValid: false)),
            .restart
        )
    }

    func testExitedRunLoopRestartsTheTap() {
        XCTAssertEqual(
            HotkeyTapWatchdogPolicy.action(for: health(runLoopAlive: false)),
            .restart
        )
    }

    func testStaleTapThreadHeartbeatRestartsTheTap() {
        XCTAssertEqual(
            HotkeyTapWatchdogPolicy.action(for: health(heartbeatFresh: false)),
            .restart
        )
    }

    func testHealthyTapNeedsNoRecovery() {
        XCTAssertEqual(
            HotkeyTapWatchdogPolicy.action(for: health()),
            .healthy
        )
    }
}
