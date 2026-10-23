// ConversationHotkeyTests.swift
// The conversation shortcut's swallow decision, in the style of `HotkeyMatchingTests`.
//
// It shares Space with the default ⌥Space dictation shortcut, so the dangerous failures are a
// match too broad (eating ⌥Space or a plain Space) or press ownership leaking across the two.

import AppKit
import XCTest

final class ConversationHotkeyTests: XCTestCase {

    private let space: UInt16 = 49
    private let escape: UInt16 = 53

    private func snapshot(
        conversationEnabled: Bool = true,
        conversationModifiers: NSEvent.ModifierFlags = [.shift, .option],
        pushToTalk: Bool = false,
        dictating: Bool = false
    ) -> ShortcutSnapshot {
        ShortcutSnapshot(
            dictationKeyCode: space,
            dictationModifiers: [.option],
            cancelKeyCode: escape,
            cancelModifiers: [],
            pushToTalk: pushToTalk,
            dictating: dictating,
            deferredSubmitOnStopEnabled: false,
            conversationKeyCode: space,
            conversationModifiers: conversationModifiers,
            conversationEnabled: conversationEnabled
        )
    }

    func testTakesTheExactConversationChord() {
        let decision = snapshot().decideConversation(
            type: .keyDown, keyCode: space, flags: [.maskShift, .maskAlternate], pressHeld: false)
        XCTAssertEqual(decision, .take)
    }

    func testDisabledModeTakesNothing() {
        let decision = snapshot(conversationEnabled: false).decideConversation(
            type: .keyDown, keyCode: space, flags: [.maskShift, .maskAlternate], pressHeld: false)
        XCTAssertEqual(decision, .ignore)
    }

    /// ⌥Space is dictation's; Space alone and ⇧⌥⌘Space belong to others.
    func testNeighbouringChordsAreLeftAlone() {
        let s = snapshot()
        for flags: CGEventFlags in [[], [.maskAlternate], [.maskShift],
                                    [.maskShift, .maskAlternate, .maskCommand]] {
            XCTAssertEqual(s.decideConversation(type: .keyDown, keyCode: space, flags: flags,
                                                pressHeld: false), .ignore, "\(flags)")
        }
        XCTAssertEqual(s.decideConversation(type: .keyDown, keyCode: 0,
                                            flags: [.maskShift, .maskAlternate], pressHeld: false), .ignore)
    }

    /// Holding the chord must not toggle the conversation on every auto-repeat, and the repeats
    /// must not leak into the focused app even after Shift is released first.
    func testOwnedRepeatsAreSwallowedButNeverRouted() {
        let s = snapshot()
        for flags: CGEventFlags in [[.maskShift, .maskAlternate], [.maskAlternate], []] {
            let decision = s.decideConversation(type: .keyDown, keyCode: space, flags: flags, pressHeld: true)
            XCTAssertEqual(decision, ShortcutSnapshot.Decision(route: false, swallow: true))
        }
    }

    /// Always a toggle: the release never routes (no push-to-talk stop), in either mode.
    func testOwnedReleaseIsBalancedButNeverRoutes() {
        for pushToTalk in [false, true] {
            let s = snapshot(pushToTalk: pushToTalk)
            XCTAssertEqual(s.decideConversation(type: .keyUp, keyCode: space, flags: [], pressHeld: true),
                           ShortcutSnapshot.Decision(route: false, swallow: true))
            XCTAssertEqual(s.decideConversation(type: .keyUp, keyCode: space, flags: [], pressHeld: false),
                           .ignore, "a Space release we never took must reach the app")
        }
    }

    /// Adding Shift while ⌥Space (dictation) is held is that press's repeat, not a new chord.
    func testADictationPressOnTheSameKeyKeepsOwnership() {
        let decision = snapshot().decideConversation(
            type: .keyDown, keyCode: space, flags: [.maskShift, .maskAlternate],
            pressHeld: false, dictationPressHeld: true)
        XCTAssertEqual(decision, .ignore)
    }

    func testFlagsChangedIsNeverTaken() {
        XCTAssertEqual(snapshot().decideConversation(
            type: .flagsChanged, keyCode: 56, flags: [.maskShift], pressHeld: false), .ignore)
    }

    /// The dictation decision itself is unchanged by the conversation shortcut's presence.
    func testDictationDecisionIsUnchanged() {
        let s = snapshot()
        XCTAssertEqual(s.decide(type: .keyDown, keyCode: space, flags: [.maskAlternate], pressHeld: false), .take)
        XCTAssertEqual(s.decide(type: .keyDown, keyCode: space, flags: [], pressHeld: false), .ignore)
    }

    func testCancelOwnershipYieldsToTheConversationChord() {
        var s = snapshot(dictating: true)
        s.cancelKeyCode = space
        s.cancelModifiers = [.shift, .option]
        XCTAssertFalse(s.claimsCancelKeyDown(keyCode: space, flags: [.maskShift, .maskAlternate]))
    }

    /// The conversation fields fill the remaining 21 bits of the packed word; a lost bit would
    /// silently stop the shortcut matching or corrupt a neighbouring field.
    func testPackedSnapshotRoundTripsTheConversationShortcut() {
        let originals = [
            snapshot(),
            snapshot(conversationEnabled: false, conversationModifiers: []),
            ShortcutSnapshot(
                dictationKeyCode: .max, dictationModifiers: [.command, .option, .control, .shift],
                cancelKeyCode: .max, cancelModifiers: [.command, .option, .control, .shift],
                pushToTalk: true, dictating: true, deferredSubmitOnStopEnabled: true,
                conversationKeyCode: .max, conversationModifiers: [.command, .option, .control, .shift],
                conversationEnabled: true),
            ShortcutSnapshot(
                dictationKeyCode: 0, dictationModifiers: [], cancelKeyCode: 0, cancelModifiers: [],
                conversationKeyCode: 122, conversationModifiers: [.control], conversationEnabled: true),
        ]
        for original in originals {
            let restored = ShortcutSnapshot(bits: original.bits)
            XCTAssertEqual(restored.conversationKeyCode, original.conversationKeyCode)
            XCTAssertEqual(restored.conversationModifiers, original.conversationModifiers)
            XCTAssertEqual(restored.conversationEnabled, original.conversationEnabled)
            XCTAssertEqual(restored.dictationKeyCode, original.dictationKeyCode)
            XCTAssertEqual(restored.dictationModifiers, original.dictationModifiers)
            XCTAssertEqual(restored.cancelKeyCode, original.cancelKeyCode)
            XCTAssertEqual(restored.cancelModifiers, original.cancelModifiers)
            XCTAssertEqual(restored.pushToTalk, original.pushToTalk)
            XCTAssertEqual(restored.dictating, original.dictating)
            XCTAssertEqual(restored.deferredSubmitOnStopEnabled, original.deferredSubmitOnStopEnabled)
        }
    }

    // MARK: - Manager boundary

    @MainActor
    func testManagerRejectsAnUnsafeOrCollidingConversationShortcut() {
        let manager = HotkeyManager()
        XCTAssertThrowsError(try manager.setConversationShortcut(.defaultDictation))
        XCTAssertThrowsError(try manager.setConversationShortcut(Shortcut(keyCode: 0, modifiers: 0)))
        XCTAssertNil(manager.conversationShortcut)
        XCTAssertNoThrow(try manager.setConversationShortcut(.defaultConversation))
        XCTAssertEqual(manager.conversationShortcut, .defaultConversation)
        XCTAssertNoThrow(try manager.setConversationShortcut(nil))
        XCTAssertNil(manager.conversationShortcut)
    }
}
