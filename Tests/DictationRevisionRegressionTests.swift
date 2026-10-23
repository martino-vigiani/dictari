import AppKit
import XCTest

final class DictationRevisionPolicyTests: XCTestCase {
    // Regression: a constituent modifier must not turn the explicit chord into an ordinary stop.
    func testBothSidesOfRevisionModifiersAreRecognizedAsChordConstituents() {
        let modifiers: [(UInt16, NSEvent.ModifierFlags)] = [
            (54, .command), (55, .command), (56, .shift),
            (60, .shift), (58, .option), (61, .option)]

        let matches = modifiers.map { key, flags in
            DictationRevisionPolicy.isConstituentModifier(Shortcut(keyCode: key, modifiers: flags.rawValue))
        }

        XCTAssertEqual(matches, Array(repeating: true, count: modifiers.count))
    }

    func testControlCapsLockAndOrdinaryKeysAreNotRevisionChordConstituents() {
        let shortcuts = [Shortcut(keyCode: 59, modifiers: NSEvent.ModifierFlags.control.rawValue),
                         Shortcut(keyCode: 57, modifiers: NSEvent.ModifierFlags.capsLock.rawValue),
                         Shortcut.defaultDictation, Shortcut(keyCode: 58, modifiers: 0),
                         Shortcut(keyCode: 58, modifiers: NSEvent.ModifierFlags.control.rawValue)]

        let matches = shortcuts.map(DictationRevisionPolicy.isConstituentModifier)

        XCTAssertEqual(matches, Array(repeating: false, count: shortcuts.count))
    }

    // Regression: the explicit shortcut must not inherit per-app or Code-profile exclusions.
    func testExplicitCorrectionWorksForCodeProfileAndUnlistedApp() {
        var settings = SettingsData()
        settings.selectedDictationProfile = "code"

        let action = DictationRevisionPolicy.action(
            explicitCorrection: true, rule: settings.writingRule(for: "unlisted.editor"))

        XCTAssertEqual(action, .correct)
    }

    func testExplicitCorrectionOverridesAnAutomaticEmailAction() {
        let rule = AppWritingRule(name: "Mail", trigger: "automatic", action: "email")

        let action = DictationRevisionPolicy.action(explicitCorrection: true, rule: rule)

        XCTAssertEqual(action, .correct)
    }

    func testOrdinaryDictationOnlyRevisesForAutomaticRules() {
        // Regression: Ask must not silently delay and rewrite ordinary dictation.
        let rules: [AppWritingRule?] = [nil, AppWritingRule(name: "Mail", trigger: "ask"),
            AppWritingRule(name: "Mail", trigger: "never"),
            AppWritingRule(name: "Mail", trigger: "future")]

        let actions = rules.map { DictationRevisionPolicy.action(explicitCorrection: false, rule: $0) }

        XCTAssertTrue(actions.allSatisfy { $0 == nil })
    }

    func testOrdinaryAutomaticDictationUsesTheConfiguredAction() {
        let rule = AppWritingRule(name: "Notes", trigger: "automatic", action: "notes")

        let action = DictationRevisionPolicy.action(explicitCorrection: false, rule: rule)

        XCTAssertEqual(action, .notes)
    }
}

final class RevisionHotkeyTests: XCTestCase {
    private let revisionKey = Shortcut.revisionDictation.keyCode
    private let revisionFlags: CGEventFlags = [.maskAlternate, .maskCommand, .maskShift]

    func testRevisionShortcutIsRecognizedWhenOrdinaryShortcutCollides() {
        let snapshot = ShortcutSnapshot(dictationKeyCode: revisionKey,
            dictationModifiers: Shortcut.revisionDictation.modifierFlags)

        let decision = snapshot.decideRevision(type: .keyDown, keyCode: revisionKey,
            flags: revisionFlags, pressHeld: false)

        XCTAssertEqual(decision, .take)
    }

    func testHeldPushToTalkReleaseStopsAfterModifiersAreReleasedFirst() {
        // Regression: independently owned revision presses must stop even with another ordinary key.
        let snapshot = ShortcutSnapshot(dictationKeyCode: 58, dictationModifiers: [.option], pushToTalk: true)

        let decision = snapshot.decideRevision(type: .keyUp, keyCode: revisionKey,
            flags: [], pressHeld: true)

        XCTAssertEqual(decision, .take)
    }

    func testToggleReleaseIsSwallowedWithoutDispatchingAnotherAction() {
        let snapshot = ShortcutSnapshot(pushToTalk: false)

        let decision = snapshot.decideRevision(type: .keyUp, keyCode: revisionKey,
            flags: [], pressHeld: true)

        XCTAssertEqual(decision, .init(route: false, swallow: true))
    }

    func testUnownedPlainKeyReleaseReachesTheApplication() {
        let snapshot = ShortcutSnapshot(pushToTalk: true)

        let decision = snapshot.decideRevision(type: .keyUp, keyCode: revisionKey,
            flags: [], pressHeld: false)

        XCTAssertEqual(decision, .ignore)
    }

    func testHeldRepeatAfterModifierReleaseDoesNotLeakOrReactivate() {
        let snapshot = ShortcutSnapshot()

        let decision = snapshot.decideRevision(type: .keyDown, keyCode: revisionKey,
            flags: [], pressHeld: true)

        XCTAssertEqual(decision, .init(route: false, swallow: true))
    }

    func testOwnedModifierReleaseIsObservedAfterSpaceAndOptionAreAlreadyReleased() {
        // Regression: the final Command/Shift release was lost for an Option-only ordinary
        // shortcut, leaving chord ownership stuck and suppressing later ordinary presses.
        let snapshot = ShortcutSnapshot(dictationKeyCode: 58, dictationModifiers: [.option])
        let modifierKeys: [UInt16] = [55, 56, 58]

        let decisions = modifierKeys.map { key in
            snapshot.decideRevision(type: .flagsChanged, keyCode: key,
                flags: [], pressHeld: false, ownsModifiers: true)
        }

        XCTAssertEqual(decisions, Array(repeating: .observe, count: modifierKeys.count),
                       "Owned modifier releases must route without hiding system modifier changes")
    }

    func testUnownedModifierChangesAreNotRoutedAsRevisionEvents() {
        let snapshot = ShortcutSnapshot(dictationKeyCode: 58, dictationModifiers: [.option])
        let modifierKeys: [UInt16] = [55, 56, 58]

        let decisions = modifierKeys.map { key in
            snapshot.decideRevision(type: .flagsChanged, keyCode: key,
                flags: [], pressHeld: false, ownsModifiers: false)
        }

        XCTAssertEqual(decisions, Array(repeating: .ignore, count: modifierKeys.count))
    }

    func testOrdinaryShortcutIsNotMistakenForRevision() {
        let snapshot = ShortcutSnapshot()

        let decision = snapshot.decideRevision(type: .keyDown, keyCode: revisionKey,
            flags: [.maskAlternate, .maskCommand], pressHeld: false)

        XCTAssertEqual(decision, .ignore)
    }
}

@MainActor
final class BeforeInsertionRevisionTests: XCTestCase {
    func testRevisionTrimsOutputAndPassesOriginalAndAction() async throws {
        let backend = ControlledRevisionBackend()
        let writing = TextRefinement(refiner: backend)
        let original = "  Keep 42 unchanged.\n"

        let result = try await writing.reviseBeforeInsertion(original, action: .email)

        XCTAssertEqual(result, "Revised")
        XCTAssertEqual(backend.receivedText, original)
        XCTAssertEqual(backend.receivedAction, .email)
        XCTAssertFalse(writing.isBusy)
        XCTAssertNil(writing.result, "automatic revision must not publish a preview")
    }

    func testInvalidInputsNeverInvokeBackend() async {
        let backend = ControlledRevisionBackend()
        let writing = TextRefinement(refiner: backend)
        let inputs = [" \n", String(repeating: "a", count: 3001),
                      String(repeating: "👨‍👩‍👧‍👦", count: 1000)]

        for (index, input) in inputs.enumerated() {
            do {
                _ = try await writing.reviseBeforeInsertion(input, action: .correct)
                XCTFail("Invalid input \(index) was accepted")
            } catch WritingError.empty { XCTAssertEqual(index, 0) }
            catch WritingError.tooLong { XCTAssertGreaterThan(index, 0) }
            catch { XCTFail("Unexpected error: \(error)") }
        }

        XCTAssertEqual(backend.calls, 0)
        XCTAssertFalse(writing.isBusy)
    }

    func testUnavailableBackendPreservesItsReasonWithoutGenerating() async {
        let backend = ControlledRevisionBackend()
        backend.unavailableReason = "Model not ready"
        let writing = TextRefinement(refiner: backend)

        do {
            _ = try await writing.reviseBeforeInsertion("Original", action: .correct)
            XCTFail("Unavailable backend was called")
        } catch WritingError.unavailable(let reason) { XCTAssertEqual(reason, "Model not ready") }
        catch { XCTFail("Unexpected error: \(error)") }

        XCTAssertEqual(backend.calls, 0)
        XCTAssertFalse(writing.isBusy)
    }

    func testInvalidOutputIsRejectedAndReleasesSlot() async {
        let backend = ControlledRevisionBackend()
        let writing = TextRefinement(refiner: backend)

        for output in [" \n", String(repeating: "界", count: 10667)] {
            backend.output = output
            do {
                _ = try await writing.reviseBeforeInsertion("Original", action: .correct)
                XCTFail("Invalid output was accepted")
            } catch WritingError.invalidOutput {} catch { XCTFail("Unexpected error: \(error)") }
            XCTAssertFalse(writing.isBusy)
        }
    }

    func testBackendFailureReleasesSlot() async {
        let backend = ControlledRevisionBackend()
        backend.failure = .invalidOutput
        let writing = TextRefinement(refiner: backend)

        do {
            _ = try await writing.reviseBeforeInsertion("Original", action: .correct)
            XCTFail("Backend failure was swallowed")
        } catch WritingError.invalidOutput {} catch { XCTFail("Unexpected error: \(error)") }

        XCTAssertFalse(writing.isBusy)
    }

    func testCancelRejectsLateOutputAndKeepsSlotUntilBackendFinishes() async {
        // Regression: cancel must neither insert a late revision nor permit overlapping inference.
        let backend = ControlledRevisionBackend()
        backend.suspend = true
        let writing = TextRefinement(refiner: backend)
        let request = Task { try await writing.reviseBeforeInsertion("Original", action: .correct) }
        await backend.waitUntilStarted()

        writing.cancel()

        XCTAssertTrue(writing.isBusy)
        writing.start("Preview must wait", action: .notes)
        do {
            _ = try await writing.reviseBeforeInsertion("Second must wait", action: .email)
            XCTFail("A second inference overlapped the cancelled request")
        } catch WritingError.unavailable {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(backend.calls, 1)
        backend.finish("Late output")
        do { _ = try await request.value; XCTFail("Cancelled output escaped") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(writing.isBusy)
        XCTAssertNil(writing.result)
    }

    func testCallerTaskCancellationRejectsBackendThatIgnoresCancellation() async {
        let backend = ControlledRevisionBackend()
        backend.suspend = true
        let writing = TextRefinement(refiner: backend)
        let request = Task { try await writing.reviseBeforeInsertion("Original", action: .correct) }
        await backend.waitUntilStarted()

        request.cancel()
        backend.finish("Late output")

        do { _ = try await request.value; XCTFail("Cancelled caller received output") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(writing.isBusy)
    }
}

@MainActor
private final class ControlledRevisionBackend: TextRefiner {
    var unavailableReason: String?
    var calls = 0
    var receivedText: String?
    var receivedAction: WritingAction?
    var output = " Revised \n"
    var failure: WritingError?
    var suspend = false
    private var pending: CheckedContinuation<String, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func waitUntilStarted() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func finish(_ output: String) {
        let continuation = pending
        pending = nil
        continuation?.resume(returning: output)
    }

    func refine(_ text: String, action: WritingAction) async throws -> String {
        calls += 1
        receivedText = text
        receivedAction = action
        if let failure { throw failure }
        guard suspend else { return output }
        return await withCheckedContinuation { continuation in
            pending = continuation
            started?.resume()
            started = nil
        }
    }
}
