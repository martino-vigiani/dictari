// LiveTypingTests.swift
// The pure rules behind Live typing: which edits a sequence of hypotheses produces, when a
// session must stop, and that the setting is opt-in and decodes from older files.
//
// Nothing here posts a key event. `LiveTyper.events(for:)` only *builds* CGEvents so their
// shape can be checked, and `postsSyntheticInput` is false under XCTest.

import Carbon.HIToolbox
import XCTest

final class LiveTypingTests: XCTestCase {

    /// Feeds `partials` through a planner, committing every edit as the coordinator does when
    /// the policy says `.write`. Returns the edits in order (nil = nothing typed for that one).
    private func run(_ partials: [String], planner: inout LiveTypingPlanner) -> [LiveTypingEdit?] {
        partials.map { partial in
            let edit = planner.propose(partial: partial)
            if let edit {
                XCTAssertLessThanOrEqual(edit.deleteCount, planner.typed.count,
                                         "an edit would delete text live typing did not type")
                planner.commit(edit)
            }
            return edit
        }
    }

    private func type(_ insert: String) -> LiveTypingEdit { LiveTypingEdit(deleteCount: 0, insert: insert) }

    // MARK: - Stabilisation

    func testWordsAppearOnceTwoHypothesesAgreeAndTheTailIsHeldBack() {
        var planner = LiveTypingPlanner()
        let edits = run([
            "Domani",
            "Domani matti",                  // "matti" is a truncated word: held back
            "Domani mattina devo",
            "Domani mattina devo passare",
        ], planner: &planner)

        XCTAssertEqual(edits, [
            nil,                             // a single hypothesis is never stable
            type("Domani"),
            nil,                             // "matti" ≠ "mattina": nothing new is stable
            type(" mattina devo"),
        ])
        XCTAssertEqual(planner.typed, "Domani mattina devo")
    }

    func testAPauseConfirmsTheLastWord() {
        // The streaming session re-emits an identical hypothesis during a pause; two
        // identical hypotheses make the whole thing stable, last word included.
        var planner = LiveTypingPlanner()
        let edits = run(["Ciao come stai", "Ciao come stai"], planner: &planner)
        XCTAssertEqual(edits, [nil, type("Ciao come stai")])
    }

    func testConfirmedRevisionOfTypedWordsChurnsOnlyTheTail() {
        var planner = LiveTypingPlanner()
        _ = run(["Domani mattina devo passare", "Domani mattina devo passare"], planner: &planner)
        XCTAssertEqual(planner.typed, "Domani mattina devo passare")

        let edits = run([
            "Domani mattina, devo passare in",      // revision seen once: hold, do not touch
            "Domani mattina, devo passare in uff",  // seen twice: correct it
        ], planner: &planner)

        XCTAssertEqual(edits, [
            nil,
            LiveTypingEdit(deleteCount: " devo passare".count, insert: ", devo passare in"),
        ])
        XCTAssertEqual(planner.typed, "Domani mattina, devo passare in")
    }

    func testAFlipFlopRevisionNeverMovesTheCaret() {
        var planner = LiveTypingPlanner()
        _ = run(["Vorrei andare", "Vorrei andare"], planner: &planner)

        let edits = run([
            "Vorrei andate in",                  // one-off misrecognition
            "Vorrei andare in banca",            // back to what is typed
            "Vorrei andare in banca oggi",
        ], planner: &planner)

        XCTAssertEqual(edits, [nil, nil, type(" in banca")])
        XCTAssertFalse(edits.contains { ($0?.deleteCount ?? 0) > 0 }, "a flip-flop deleted typed text")
    }

    func testAccentsInDecomposedFormDoNotChurn() {
        var planner = LiveTypingPlanner()
        let decomposed = "Perche\u{301} no"          // "Perché" as e + combining acute
        _ = run([decomposed, decomposed], planner: &planner)
        XCTAssertEqual(planner.typed, "Perché no")

        let edits = run(["Perché no, però", "Perché no, però sì"], planner: &planner)
        XCTAssertEqual(edits, [nil, type(", però")])
    }

    func testHypothesesCanNeverTypeALineBreakOrTab() {
        var planner = LiveTypingPlanner()
        _ = run(["Prima riga\nseconda\triga", "Prima riga\nseconda\triga"], planner: &planner)
        XCTAssertEqual(planner.typed, "Prima riga seconda riga")
    }

    /// Whatever the model does, no edit may delete more than the planner itself typed.
    func testNeverDeletesBeyondItsOwnTextUnderRandomRevisions() {
        let pool = ["ciao", "Ciao", "come", "stai", "stai?", "bene", "grazie,", "e", "tu", "perché"]
        var seed: UInt64 = 0x5EED
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(bound))
        }
        for _ in 0..<200 {
            var planner = LiveTypingPlanner()
            var words: [String] = []
            for _ in 0..<30 {
                switch next(3) {
                case 0: words.append(pool[next(pool.count)])
                case 1 where !words.isEmpty: words[next(words.count)] = pool[next(pool.count)]
                default: if !words.isEmpty, next(4) == 0 { words.removeLast() }
                }
                let before = planner.typed
                if let edit = planner.propose(partial: words.joined(separator: " ")) {
                    XCTAssertLessThanOrEqual(edit.deleteCount, before.count)
                    planner.commit(edit)
                }
            }
            let final = planner.finalEdit(for: "Fine. ")
            XCTAssertLessThanOrEqual(final?.deleteCount ?? 0, planner.typed.count)
        }
    }

    // MARK: - Final reconciliation

    func testFinalTranscriptIsReachedWithAMinimalEdit() {
        var planner = LiveTypingPlanner()
        _ = run(["Domani mattina devo passare", "Domani mattina devo passare"], planner: &planner)

        let edit = planner.finalEdit(for: "Domani mattina devo passare in ufficio. ")
        XCTAssertEqual(edit, type(" in ufficio. "))

        let revised = planner.finalEdit(for: "Domani mattina dovrò passare. ")
        XCTAssertEqual(revised, LiveTypingEdit(deleteCount: "evo passare".count, insert: "ovrò passare. "))
    }

    func testFinalWithALineBreakIsNotTypeable() {
        var planner = LiveTypingPlanner()
        _ = run(["Lista della spesa", "Lista della spesa"], planner: &planner)
        XCTAssertNil(planner.finalEdit(for: "Lista della spesa\n"), "a newline would be Return in chat apps")
        XCTAssertEqual(planner.revertEdit, LiveTypingEdit(deleteCount: "Lista della spesa".count, insert: ""))
    }

    func testCommitOfRevertLeavesNothingTyped() {
        var planner = LiveTypingPlanner()
        _ = run(["Ciao a tutti", "Ciao a tutti"], planner: &planner)
        planner.commit(planner.revertEdit)
        XCTAssertEqual(planner.typed, "")
    }

    func testEmojiSequencesAreKeptWhole() {
        XCTAssertTrue(LiveTypingPlanner.isTypeable("Ciao 👨‍👩‍👧‍👦"), "ZWJ is a format character, not a control")
        let edit = LiveTypingPlanner.edit(from: "Ciao 👨‍👩‍👧", to: "Ciao 👨‍👩‍👧‍👦")
        XCTAssertEqual(edit.deleteCount, 1, "one Backspace removes the whole cluster")
    }

    // MARK: - Chunking

    func testChunksRespectTheUTF16LimitWithoutSplittingCharacters() {
        let ascii = String(repeating: "a", count: 45)
        XCTAssertEqual(LiveTypingPlanner.chunks(of: ascii).map(\.utf16.count), [20, 20, 5])

        let family = "👨‍👩‍👧‍👦"                          // 11 UTF-16 units, one Character
        let chunks = LiveTypingPlanner.chunks(of: "àèìòù " + family + family)
        XCTAssertEqual(chunks.joined(), "àèìòù " + family + family)
        XCTAssertTrue(chunks.allSatisfy { $0.utf16.count <= 20 })
        XCTAssertTrue(chunks.allSatisfy { chunk in chunk.unicodeScalars.first != "\u{200D}" })
    }

    // MARK: - Abort policy

    func testPolicyWritesOnlyWhenEverythingIsSafe() {
        XCTAssertEqual(LiveTypingPolicy.decide(LiveTypingConditions()), .write)
        XCTAssertEqual(LiveTypingPolicy.decide(LiveTypingConditions(focus: .unknown)), .write)
    }

    func testPolicyAbortsOnAnythingThatCouldMoveTheCaretOrLeakInput() {
        XCTAssertEqual(LiveTypingPolicy.decide(.init(userInputSinceStart: true)), .abort(.userInput))
        XCTAssertEqual(LiveTypingPolicy.decide(.init(frontmostAppUnchanged: false)), .abort(.appChanged))
        XCTAssertEqual(LiveTypingPolicy.decide(.init(secureInputEnabled: true)), .abort(.secureInput))
        XCTAssertEqual(LiveTypingPolicy.decide(.init(focus: .secure)), .abort(.secureField))
        XCTAssertEqual(LiveTypingPolicy.decide(.init(focus: .notEditable)), .abort(.fieldNotEditable))
    }

    func testPolicyHoldsWhileTheProbeRunsOrAModifierIsDown() {
        XCTAssertEqual(LiveTypingPolicy.decide(.init(focus: nil)), .hold)
        XCTAssertEqual(LiveTypingPolicy.decide(.init(modifiersHeld: true)), .hold)
    }

    func testDangerWinsOverWaiting() {
        let conditions = LiveTypingConditions(
            userInputSinceStart: true, secureInputEnabled: true, focus: nil, modifiersHeld: true
        )
        XCTAssertEqual(LiveTypingPolicy.decide(conditions), .abort(.secureInput))
        XCTAssertEqual(
            LiveTypingPolicy.decide(.init(userInputSinceStart: true, focus: nil, modifiersHeld: true)),
            .abort(.userInput)
        )
    }

    func testUserInputMonitorDetectsKeysAndClicks() {
        let monitor = UserInputMonitor()
        let baseline = monitor.snapshot
        XCTAssertEqual(monitor.snapshot, baseline)
        monitor.notePointerPress()
        XCTAssertNotEqual(monitor.snapshot, baseline)
        let afterClick = monitor.snapshot
        monitor.noteKeyPress()
        XCTAssertNotEqual(monitor.snapshot, afterClick)
    }

    // MARK: - Key events (built, never posted)

    @MainActor
    func testEventsAreTaggedBackspacesThenBatchedText() throws {
        let events = try XCTUnwrap(LiveTyper.events(for: LiveTypingEdit(deleteCount: 2, insert: "ciao")))
        XCTAssertEqual(events.count, 6)
        for event in events {
            XCTAssertEqual(event.getIntegerValueField(.eventSourceUserData), SyntheticInputMarker.liveTyping,
                           "the hotkey tap must be able to recognise Dictari's own keystrokes")
            XCTAssertTrue(event.flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]).isEmpty)
        }
        XCTAssertEqual(events[0..<4].map { $0.getIntegerValueField(.keyboardEventKeycode) },
                       Array(repeating: Int64(kVK_Delete), count: 4))

        var length = 0
        var buffer = [UniChar](repeating: 0, count: 32)
        events[4].keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length,
                                           unicodeString: &buffer)
        XCTAssertEqual(String(utf16CodeUnits: buffer, count: length), "ciao")
    }

    @MainActor
    func testNothingIsPostedUnderXCTest() {
        let typer = LiveTyper()
        XCTAssertFalse(typer.postsSyntheticInput)
        XCTAssertFalse(typer.isAvailable)
        XCTAssertFalse(typer.post(LiveTypingEdit(deleteCount: 1, insert: "x")))
        XCTAssertTrue(typer.post(LiveTypingEdit(deleteCount: 0, insert: "")), "an empty edit is trivially done")
    }

    // MARK: - Settings

    func testLiveTypingIsOffByDefaultAndDecodesFromOlderSettings() throws {
        XCTAssertFalse(SettingsData().liveTypingEnabled)

        var current = SettingsData()
        current.liveTypingEnabled = true
        let encoded = try JSONEncoder().encode(current)
        XCTAssertTrue(try JSONDecoder().decode(SettingsData.self, from: encoded).liveTypingEnabled)

        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "liveTyping")
        let decoded = try JSONDecoder().decode(
            SettingsData.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(decoded.liveTyping)
        XCTAssertFalse(decoded.liveTypingEnabled)
    }

    func testTheOldRealtimeFlagDoesNotTurnOnLiveTyping() throws {
        var old = SettingsData()
        old.realtimeTranscriptionEnabled = true
        let decoded = try JSONDecoder().decode(SettingsData.self, from: JSONEncoder().encode(old))
        XCTAssertFalse(decoded.liveTypingEnabled)
    }
}
