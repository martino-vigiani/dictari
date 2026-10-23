import AppKit
import Carbon.HIToolbox
import XCTest

/// Covers everything in `TextInjector` that does not need a live UI session: text
/// preprocessing, and the pasteboard snapshot/restore contract that decides whether the
/// user gets their previous clipboard back.
///
/// The injector is pointed at a private named pasteboard throughout — a test run must never
/// clobber the clipboard of whoever is running it.
@MainActor
final class InjectionTests: XCTestCase {

    private var board: NSPasteboard!
    private var injector: TextInjector!

    override func setUp() async throws {
        try await super.setUp()
        board = NSPasteboard(name: .init("com.dictari.tests.\(UUID().uuidString)"))
        board.clearContents()
        injector = TextInjector()
        injector.pasteboard = board
    }

    override func tearDown() async throws {
        board.releaseGlobally()
        board = nil
        injector = nil
        try await super.tearDown()
    }

    // MARK: - Preprocessing

    func testAppendsATrailingSpaceSoConsecutiveDictationsDontRunTogether() {
        injector.trailingSpace = true
        injector.autoCapitalize = false
        XCTAssertEqual(injector.preprocess("ciao"), "ciao ")
    }

    func testTrailingSpaceCanBeTurnedOff() {
        injector.trailingSpace = false
        injector.autoCapitalize = false
        XCTAssertEqual(injector.preprocess("ciao"), "ciao")
    }

    func testTrailingSpaceIsNotAppendedToEmptyText() {
        injector.trailingSpace = true
        XCTAssertEqual(injector.preprocess(""), "")
    }

    func testAutoCapitalizeUppercasesTheFirstLetter() {
        injector.autoCapitalize = true
        injector.trailingSpace = false
        XCTAssertEqual(injector.preprocess("ciao mondo"), "Ciao mondo")
    }

    func testAutoCapitalizeSkipsLeadingWhitespace() {
        injector.autoCapitalize = true
        injector.trailingSpace = false
        XCTAssertEqual(injector.preprocess("  ciao"), "  Ciao")
    }

    func testAutoCapitalizeLeavesNonLatinAndAlreadyCapitalTextAlone() {
        injector.autoCapitalize = true
        injector.trailingSpace = false
        XCTAssertEqual(injector.preprocess("Ciao"), "Ciao")
        XCTAssertEqual(injector.preprocess("123 via"), "123 via")
        XCTAssertEqual(injector.preprocess("日本語"), "日本語")
    }

    func testAutoCapitalizeHandlesAccentedFirstLetters() {
        injector.autoCapitalize = true
        injector.trailingSpace = false
        XCTAssertEqual(injector.preprocess("è vero"), "È vero")
    }

    func testAutoCapitalizeOnWhitespaceOnlyTextIsANoOp() {
        injector.autoCapitalize = true
        injector.trailingSpace = false
        XCTAssertEqual(injector.preprocess("   "), "   ")
    }

    func testBothTransformsApplyTogether() {
        injector.autoCapitalize = true
        injector.trailingSpace = true
        XCTAssertEqual(injector.preprocess("ciao"), "Ciao ")
    }

    // MARK: - Clipboard round-trip

    func testCopyToClipboardWritesTheText() {
        injector.copyToClipboard("trascrizione")
        XCTAssertEqual(board.string(forType: .string), "trascrizione")
    }

    func testSnapshotAndRestoreBringBackPlainText() {
        board.clearContents()
        board.setString("qualcosa di importante", forType: .string)
        let snapshot = injector.snapshotPasteboard()

        injector.copyToClipboard("la trascrizione")
        XCTAssertEqual(board.string(forType: .string), "la trascrizione")

        injector.restorePasteboard(snapshot)
        XCTAssertEqual(board.string(forType: .string), "qualcosa di importante")
    }

    func testRestorePreservesEveryRepresentationOfAnItem() {
        let rtf = NSAttributedString(string: "grassetto")
            .rtf(from: NSRange(location: 0, length: 9), documentAttributes: [:])!
        let item = NSPasteboardItem()
        item.setString("grassetto", forType: .string)
        item.setData(rtf, forType: .rtf)
        board.clearContents()
        board.writeObjects([item])

        let snapshot = injector.snapshotPasteboard()
        injector.copyToClipboard("la trascrizione")
        injector.restorePasteboard(snapshot)

        XCTAssertEqual(board.string(forType: .string), "grassetto")
        XCTAssertEqual(board.data(forType: .rtf), rtf)
    }

    func testRestorePreservesMultipleItems() {
        let first = NSPasteboardItem()
        first.setString("uno", forType: .string)
        let second = NSPasteboardItem()
        second.setString("due", forType: .string)
        board.clearContents()
        board.writeObjects([first, second])

        let snapshot = injector.snapshotPasteboard()
        XCTAssertEqual(snapshot.count, 2)

        injector.copyToClipboard("la trascrizione")
        injector.restorePasteboard(snapshot)

        XCTAssertEqual(board.pasteboardItems?.count, 2)
        XCTAssertEqual(board.pasteboardItems?.first?.string(forType: .string), "uno")
        XCTAssertEqual(board.pasteboardItems?.last?.string(forType: .string), "due")
    }

    func testRestoringAnEmptySnapshotLeavesAnEmptyPasteboard() {
        board.clearContents()
        let snapshot = injector.snapshotPasteboard()
        XCTAssertTrue(snapshot.isEmpty)

        injector.copyToClipboard("la trascrizione")
        injector.restorePasteboard(snapshot)

        XCTAssertNil(board.string(forType: .string))
    }

    /// Terminals and many web views accept the paste without exposing a watchable signature.
    /// After the grace delay the user's own clipboard comes back; History keeps the transcript.
    func testUnobservableVerificationRestoresTheUsersClipboard() async {
        board.setString("clipboard prima della dettatura", forType: .string)
        let snapshot = injector.snapshotPasteboard()
        injector.copyToClipboard("trascrizione incollata")
        let ownership = ClipboardOwnershipToken(
            injectionGeneration: 0,
            pasteboardChangeCount: board.changeCount
        )

        await injector.restorePasteboardAfterVerification(
            snapshot,
            outcome: .unobservable,
            ownership: ownership
        )

        XCTAssertEqual(board.string(forType: .string), "clipboard prima della dettatura")
    }

    func testFailedVerificationLeavesTranscriptOnClipboard() async {
        board.setString("clipboard prima della dettatura", forType: .string)
        let snapshot = injector.snapshotPasteboard()
        injector.copyToClipboard("trascrizione non verificata")
        let ownership = ClipboardOwnershipToken(
            injectionGeneration: 0,
            pasteboardChangeCount: board.changeCount
        )

        await injector.restorePasteboardAfterVerification(
            snapshot,
            outcome: .failed,
            ownership: ownership
        )

        XCTAssertEqual(board.string(forType: .string), "trascrizione non verificata")
    }

    func testConfirmedVerificationRestoresSnapshotWhenClipboardOwnershipIsUnchanged() async {
        board.setString("clipboard prima della dettatura", forType: .string)
        let snapshot = injector.snapshotPasteboard()
        injector.copyToClipboard("trascrizione consegnata")
        let ownership = ClipboardOwnershipToken(
            injectionGeneration: 0,
            pasteboardChangeCount: board.changeCount
        )

        await injector.restorePasteboardAfterVerification(
            snapshot,
            outcome: .confirmed,
            ownership: ownership
        )

        XCTAssertEqual(board.string(forType: .string), "clipboard prima della dettatura")
    }

    func testConfirmedVerificationDoesNotRestoreAfterAnExternalClipboardWrite() async {
        board.setString("clipboard prima della dettatura", forType: .string)
        let snapshot = injector.snapshotPasteboard()
        injector.copyToClipboard("trascrizione consegnata")
        let ownership = ClipboardOwnershipToken(
            injectionGeneration: 0,
            pasteboardChangeCount: board.changeCount
        )
        injector.copyToClipboard("testo copiato dall'utente")

        await injector.restorePasteboardAfterVerification(
            snapshot,
            outcome: .confirmed,
            ownership: ownership
        )

        XCTAssertEqual(board.string(forType: .string), "testo copiato dall'utente")
    }

    func testConfirmedVerificationDoesNotRestoreAfterANewInjectionGeneration() async {
        board.setString("clipboard prima della dettatura", forType: .string)
        let snapshot = injector.snapshotPasteboard()
        injector.copyToClipboard("trascrizione consegnata")
        let staleOwnership = ClipboardOwnershipToken(
            injectionGeneration: 1,
            pasteboardChangeCount: board.changeCount
        )

        await injector.restorePasteboardAfterVerification(
            snapshot,
            outcome: .confirmed,
            ownership: staleOwnership
        )

        XCTAssertEqual(board.string(forType: .string), "trascrizione consegnata")
    }

    // MARK: - Injection results that don't need a UI session

    func testInjectingWhitespaceOnlyTextIsAClipboardNoOp() async {
        injector.trailingSpace = false
        let result = await injector.inject("   ")
        XCTAssertEqual(result, .copiedToClipboard)
    }

    /// The suite runs host-less with no Accessibility grant, so `inject` must take the
    /// clipboard fallback rather than try to synthesize a keystroke into nothing — and the
    /// text must still be on the pasteboard afterwards.
    func testWithoutAccessibilityInjectFallsBackToTheClipboardAndKeepsTheText() async throws {
        try XCTSkipIf(TextInjector.hasAccessibilityPermission(),
                      "This process is AX-trusted; the fallback path can't be exercised.")
        injector.trailingSpace = false
        let result = await injector.inject("testo da conservare")
        XCTAssertEqual(result, .copiedToClipboard)
        XCTAssertEqual(board.string(forType: .string), "testo da conservare")
    }

    func testTheAutoPasteGateIsClosedOnlyWhenInsertionIsImpossible() {
        // This is only the cheap permission preflight. Delivery separately requires a fresh,
        // positively editable focus target immediately before it can post keyboard events.
        XCTAssertEqual(injector.canAttemptInsertion(), TextInjector.hasAccessibilityPermission())
    }

    /// A still-held dictation modifier must not turn synthetic Command-V or Return into a
    /// different shortcut in the frontmost app after the bounded release wait expires.
    func testSyntheticInputRejectsHeldShortcutModifiers() {
        XCTAssertTrue(TextInjector.modifiersAllowSyntheticInput([]))
        XCTAssertTrue(TextInjector.modifiersAllowSyntheticInput(.maskNumericPad))
        let modifiers: [CGEventFlags] = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        for flag in modifiers {
            XCTAssertFalse(TextInjector.modifiersAllowSyntheticInput(flag))
        }
        XCTAssertFalse(TextInjector.modifiersAllowSyntheticInput([.maskCommand, .maskAlternate]))
    }

    func testModifierReleaseTimeoutDoesNotAuthorizeSyntheticInput() async {
        let released = await injector.awaitModifierRelease(budget: .zero) { .maskAlternate }
        XCTAssertFalse(released)
    }

    func testModifierReleaseWaitsForHeldKeyThenAllowsInput() async {
        var polls = 0
        let released = await injector.awaitModifierRelease(budget: .milliseconds(50)) {
            polls += 1
            return polls == 1 ? .maskAlternate : []
        }
        XCTAssertTrue(released)
        XCTAssertGreaterThanOrEqual(polls, 2)
    }

    func testDeferredClipboardWorkRequiresCurrentSessionAndUnchangedPasteboard() {
        let expected = ClipboardOwnershipToken(injectionGeneration: 7, pasteboardChangeCount: 12)
        XCTAssertTrue(TextInjector.ownsDeferredClipboard(expected: expected, current: expected))
        XCTAssertFalse(TextInjector.ownsDeferredClipboard(
            expected: expected,
            current: ClipboardOwnershipToken(injectionGeneration: 8, pasteboardChangeCount: 12)
        ))
        XCTAssertFalse(TextInjector.ownsDeferredClipboard(
            expected: expected,
            current: ClipboardOwnershipToken(injectionGeneration: 7, pasteboardChangeCount: 13)
        ))
    }

    // MARK: - Safe transport policy

    func testDeliveryReceiptPublishesDeferredVerificationExactlyOnce() async {
        let receipt = InjectionVerificationReceipt()
        let delivery = InjectionDelivery(initialResult: .pasteUnverified, receipt: receipt)
        await receipt.resolve(.confirmed)
        await receipt.resolve(.failed)

        XCTAssertEqual(delivery.initialResult, .pasteUnverified)
        XCTAssertTrue(delivery.hasDeferredVerification)
        let outcome = await delivery.verificationOutcome()
        XCTAssertEqual(outcome, .confirmed)
    }

    func testSubmitKeyMappingAcceptsReturnAndKeypadEnterOnly() {
        XCTAssertEqual(TextInjector.submitKeyCode(for: 36), 36)
        XCTAssertEqual(TextInjector.submitKeyCode(for: 76), 76)
        XCTAssertNil(TextInjector.submitKeyCode(for: 49))
    }

    func testMissingKeyboardEventCannotClaimThatInputWasPosted() {
        let pair = TextInjector.keyboardEventPair(keyCode: 9) { _, _ in nil }
        XCTAssertNil(pair, "a missing event half must fail before paste or deferred Enter is posted")
    }

    /// Regression: posting only V down/up with Command flags left Command latched in the
    /// combined session state. A paste must balance the modifier around the V keystroke.
    func testPasteShortcutBalancesCommandDownAndUpAroundV() throws {
        let chord = try XCTUnwrap(TextInjector.pasteShortcutEventChord { keyCode, keyDown in
            CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: keyDown)
        })
        let events = [chord.commandDown, chord.vDown, chord.vUp, chord.commandUp]

        XCTAssertEqual(events.map { $0.getIntegerValueField(.keyboardEventKeycode) }, [
            Int64(kVK_Command), Int64(kVK_ANSI_V), Int64(kVK_ANSI_V), Int64(kVK_Command),
        ], "The modifier must be released after, not before, V key-up")
        XCTAssertEqual(events.map(\.type), [.flagsChanged, .keyDown, .keyUp, .flagsChanged],
                       "Modifier transitions are flagsChanged events around the V keystroke")
    }

    /// Regression: Command-up must clear the synthetic flag or the following dictation sees
    /// Command still pressed and falls back to clipboard-only.
    func testPasteShortcutClearsCommandFlagOnFinalModifierRelease() throws {
        let chord = try XCTUnwrap(TextInjector.pasteShortcutEventChord { keyCode, keyDown in
            CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: keyDown)
        })
        let events = [chord.commandDown, chord.vDown, chord.vUp, chord.commandUp]

        XCTAssertEqual(events.map(\.flags), [
            .maskCommand, .maskCommand, .maskCommand, [],
        ], "Only the final Command-up may clear the modifier flag")
    }

    func testMissingPasteChordEventCannotProduceAPartialPostableShortcut() {
        for missingEvent in 1...4 {
            var allocation = 0

            let chord = TextInjector.pasteShortcutEventChord { keyCode, keyDown in
                allocation += 1
                guard allocation != missingEvent else { return nil }
                return CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: keyDown)
            }

            XCTAssertNil(chord, "A missing event at position \(missingEvent) must prevent posting any chord")
        }
    }

    /// The gate runs on the main actor on the post-dictation path, so it must not perform any
    /// Accessibility IPC — a single call to a wedged app measured 1508 ms. This is a timing
    /// assertion on purpose: it fails the moment someone puts an AX round trip back in here.
    func testTheAutoPasteGateDoesNoBlockingAccessibilityWork() {
        let start = Date()
        for _ in 0..<50 { _ = injector.canAttemptInsertion() }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.05,
                          "canAttemptInsertion must stay a local check, not an AX round trip")
    }

    // MARK: - Accessibility is bounded and off the main actor

}


/// The paste decision, exercised on plain data. These are the cases that decide whether the
/// user's transcript lands in their text box or in the copy pill.
final class FocusVerdictTests: XCTestCase {

    func testNativeTextFieldsAndAreasPaste() {
        for role in ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"] {
            XCTAssertEqual(FocusVerdict.classify(FocusProbe(role: role)), .editable, role)
        }
    }

    func testPasswordFieldsNeverReceiveInput() {
        let probe = FocusProbe(role: "AXTextField", subrole: "AXSecureTextField", selectedRangeSettable: true)
        XCTAssertEqual(FocusVerdict.classify(probe), .secure)
        XCTAssertFalse(FocusVerdict.secure.allowsPaste)
    }

    /// Regression for the September bug: AX failing to answer is not proof of "no text box".
    func testAccessibilityFailurePastesAnyway() {
        XCTAssertEqual(FocusVerdict.classify(FocusProbe(axAnswered: false)), .unknown)
        XCTAssertTrue(FocusVerdict.unknown.allowsPaste)
    }

    /// Chromium reports the window, a group or nothing while its tree is still being built.
    func testChromiumWithoutATreeStillPastes() {
        XCTAssertEqual(FocusVerdict.classify(FocusProbe(hasFocusedElement: false, isWebEngineApp: true)), .unknown)
        XCTAssertEqual(FocusVerdict.classify(FocusProbe(role: "AXWindow", isWebEngineApp: true)), .unknown)
        XCTAssertEqual(FocusVerdict.classify(FocusProbe(role: "AXWebArea", isWebEngineApp: true)), .unknown)
        XCTAssertEqual(FocusVerdict.classify(FocusProbe(role: "AXGroup", isWebEngineApp: true)), .unknown)
    }

    /// Claude / Slack composers are contenteditable groups; Mail compose is a WebKit web area.
    func testWebAndCustomEditorsAreEditable() {
        XCTAssertEqual(FocusVerdict.classify(FocusProbe(role: "AXGroup", selectedRangeSettable: true)), .editable)
        XCTAssertEqual(FocusVerdict.classify(FocusProbe(role: "AXGroup", hasEditableAncestor: true)), .editable)
        XCTAssertEqual(FocusVerdict.classify(FocusProbe(role: "AXWebArea", hasEditableAncestor: true)), .editable)
        XCTAssertEqual(
            FocusVerdict.classify(FocusProbe(role: "AXScrollArea", valueSettable: true, hasSelectedRange: true)),
            .editable
        )
    }

    func testNothingFocusedInANativeAppShowsTheCopyPill() {
        XCTAssertEqual(FocusVerdict.classify(FocusProbe(hasFocusedElement: false)), .notEditable)
        XCTAssertEqual(FocusVerdict.classify(FocusProbe(role: "AXWindow")), .notEditable)
        XCTAssertEqual(FocusVerdict.classify(FocusProbe(role: "AXStaticText")), .notEditable)
    }

    func testFocusedControlsShowTheCopyPillInEveryApp() {
        for isWeb in [false, true] {
            for role in ["AXButton", "AXList", "AXOutline", "AXTable", "AXLink", "AXCheckBox"] {
                XCTAssertEqual(
                    FocusVerdict.classify(FocusProbe(role: role, isWebEngineApp: isWeb)), .notEditable,
                    "\(role) web=\(isWeb)"
                )
            }
        }
    }

    /// A settable value alone is not a text box: sliders and steppers expose one too.
    func testSettableValueWithoutSelectionIsNotEnough() {
        XCTAssertEqual(FocusVerdict.classify(FocusProbe(role: "AXSlider", valueSettable: true)), .notEditable)
    }

    /// Regression, 29 Sep 2026: right after an unlock macOS reports loginwindow as frontmost,
    /// which has no focused element, while the user is typing into Claude. That empty answer
    /// sent the transcript to the copy pill instead of pasting.
    func testStaleLoginWindowAfterUnlockPastes() {
        let probe = FocusProbe(hasFocusedElement: false, frontmostIsStaleLoginWindow: true)
        XCTAssertEqual(FocusVerdict.classify(probe), .unknown)
        XCTAssertTrue(FocusVerdict.classify(probe).allowsPaste)
    }

    /// A password field still wins, whatever is reported as frontmost.
    func testStaleLoginWindowNeverOverridesASecureField() {
        let probe = FocusProbe(role: "AXTextField", subrole: "AXSecureTextField", frontmostIsStaleLoginWindow: true)
        XCTAssertEqual(FocusVerdict.classify(probe), .secure)
    }

    /// Unknown native roles paste: a stray ⌘V is harmless, a missed paste is the bug.
    func testUnknownNativeRolePastes() {
        XCTAssertEqual(FocusVerdict.classify(FocusProbe(role: "AXGroup")), .unknown)
    }

    func testChromiumIsDetectedFromItsBundledResources() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dictari-bundles-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        func makeApp(_ name: String, framework: String, pakPath: String?) throws -> URL {
            let app = root.appendingPathComponent("\(name).app")
            let fw = app.appendingPathComponent("Contents/Frameworks/\(framework)")
            try FileManager.default.createDirectory(at: fw, withIntermediateDirectories: true)
            if let pakPath {
                let pak = fw.appendingPathComponent(pakPath)
                try FileManager.default.createDirectory(at: pak.deletingLastPathComponent(), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: pak.path, contents: Data())
            }
            return app
        }
        let electron = try makeApp("Claude", framework: "Electron Framework.framework", pakPath: nil)
        let chrome = try makeApp("Chrome", framework: "Google Chrome Framework.framework",
                                 pakPath: "Versions/Current/Resources/chrome_100_percent.pak")
        let native = try makeApp("Notes", framework: "Sparkle.framework", pakPath: "Resources/Info.plist")

        XCTAssertTrue(FocusInspector.bundleEmbedsChromium(electron))
        XCTAssertTrue(FocusInspector.bundleEmbedsChromium(chrome))
        XCTAssertFalse(FocusInspector.bundleEmbedsChromium(native))
        XCTAssertFalse(FocusInspector.bundleEmbedsChromium(root.appendingPathComponent("Missing.app")))
    }
}

@MainActor
final class InjectionDeliverySafetyTests: XCTestCase {
    /// The test runner is Accessibility-trusted. A delivery from a test must never post ⌘V into
    /// whatever window the developer is typing in.
    func testDeliveryNeverPostsInputUnderXCTest() async {
        let board = NSPasteboard(name: .init("com.dictari.tests.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let injector = TextInjector()
        injector.pasteboard = board
        injector.trailingSpace = false
        XCTAssertFalse(injector.postsSyntheticInput)

        for method in InjectionMethod.allCases {
            injector.method = method
            let delivery = await injector.injectDelivery("testo \(method.rawValue)")
            XCTAssertEqual(delivery.initialResult, .copiedToClipboard)
            XCTAssertFalse(delivery.hasDeferredVerification)
            XCTAssertEqual(board.string(forType: .string), "testo \(method.rawValue)")
        }
        XCTAssertFalse(injector.synthesizeSubmitKey())
    }

    func testTypeIsARealDeliveryMethodAgain() {
        XCTAssertEqual(InjectionMethod.type.label, "Type")
    }
}

@MainActor
final class ClipboardPerformanceBenchmarks: XCTestCase {
    private let binaryType = NSPasteboard.PasteboardType("com.dictari.tests.performance.binary")
    private let originalText = "original clipboard text"
    private let secondItemText = "second clipboard item"
    private let transcript = "dictated transcript"
    private let repetitions = 5

    func testSnapshotWriteAndRestoreAcrossClipboardSizes() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["DICTARI_CLIPBOARD_BENCH"] != "1",
                      "Set DICTARI_CLIPBOARD_BENCH=1 to run the private-pasteboard benchmark")

        let board = NSPasteboard(name: .init("com.dictari.tests.clipboard-bench.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let injector = TextInjector()
        injector.pasteboard = board
        let clock = ContinuousClock()

        print("Clipboard bench: private pasteboard, 5 repetitions, milliseconds (median/min/max); no production CPU or energy inference")
        for sizeMiB in [1, 10, 100] {
            let payload = Data(repeating: 0xA5, count: sizeMiB * 1_048_576)
            var snapshotTimes: [Double] = []
            var writeTimes: [Double] = []
            var restoreTimes: [Double] = []

            for _ in 0..<repetitions {
                board.clearContents()
                XCTAssertTrue(board.writeObjects(makeOriginalItems(payload: payload)),
                              "The private board must accept the \(sizeMiB) MiB fixture")

                let snapshotStart = clock.now
                let snapshot = injector.snapshotPasteboard()
                snapshotTimes.append(milliseconds(clock.now - snapshotStart))

                let writeStart = clock.now
                let wroteTranscript = injector.copyToClipboard(transcript)
                writeTimes.append(milliseconds(clock.now - writeStart))
                XCTAssertTrue(wroteTranscript, "Transcript write must succeed before restoration")
                XCTAssertEqual(board.string(forType: .string), transcript)

                let restoreStart = clock.now
                injector.restorePasteboard(snapshot)
                restoreTimes.append(milliseconds(clock.now - restoreStart))

                XCTAssertEqual(snapshot.count, 2, "Snapshot must preserve both original items")
                try verifyRestoredItems(on: board, expectedPayload: payload)
            }

            print("Clipboard \(sizeMiB) MiB: snapshot \(summary(snapshotTimes)); write \(summary(writeTimes)); restore \(summary(restoreTimes))")
        }
    }

    private func makeOriginalItems(payload: Data) -> [NSPasteboardItem] {
        let first = NSPasteboardItem()
        first.setString(originalText, forType: .string)
        first.setData(payload, forType: binaryType)
        let second = NSPasteboardItem()
        second.setString(secondItemText, forType: .string)
        return [first, second]
    }

    private func verifyRestoredItems(on board: NSPasteboard, expectedPayload: Data) throws {
        let items = try XCTUnwrap(board.pasteboardItems)
        XCTAssertEqual(items.count, 2, "Restore must preserve both items and their order")
        guard items.count == 2 else { return }
        XCTAssertEqual(items[0].string(forType: .string), originalText)
        XCTAssertEqual(items[1].string(forType: .string), secondItemText)
        XCTAssertEqual(Set(items[0].types), Set([.string, binaryType]))
        XCTAssertEqual(Set(items[1].types), Set([.string]))
        XCTAssertEqual(items[0].data(forType: binaryType), expectedPayload,
                       "Restore must preserve every byte of the binary representation")
    }

    private func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1_000_000_000_000_000
    }

    private func summary(_ samples: [Double]) -> String {
        let ordered = samples.sorted()
        return String(format: "%.2f/%.2f/%.2f", ordered[ordered.count / 2],
                      ordered[0], ordered[ordered.count - 1])
    }
}

