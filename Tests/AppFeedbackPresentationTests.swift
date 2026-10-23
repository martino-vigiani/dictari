import XCTest

final class AppFeedbackPresentationTests: XCTestCase {
    func testDisabledIdlePillStaysHiddenEvenWhenShortcutIsUnavailable() {
        XCTAssertFalse(
            PillPresentationPolicy.shouldShow(
                alwaysShowPill: false,
                dictationIsActive: false
            )
        )
    }

    func testActiveDictationStillShowsPillWhenIdlePreferenceIsOff() {
        XCTAssertTrue(
            PillPresentationPolicy.shouldShow(
                alwaysShowPill: false,
                dictationIsActive: true
            )
        )
    }

    func testListeningWinsOverModelLoading() {
        XCTAssertEqual(
            AppFeedbackPresentation.resolve(
                dictation: .listening,
                model: .loading(0.25),
                attentionReason: "Microphone access needed"
            ),
            .listening
        )
    }

    func testTranscribingWinsOverModelLoading() {
        XCTAssertEqual(
            AppFeedbackPresentation.resolve(
                dictation: .transcribing,
                model: .loading(nil),
                attentionReason: "Shortcut not active"
            ),
            .transcribing
        )
    }

    func testSuccessWinsOverModelLoading() {
        XCTAssertEqual(
            AppFeedbackPresentation.resolve(
                dictation: .success(.inserted),
                model: .loading(0.9),
                attentionReason: nil
            ),
            .success(.inserted)
        )
    }

    func testClipboardFallbackRemainsAClipboardSuccessForTheTranscriptPill() {
        XCTAssertEqual(
            AppFeedbackPresentation.resolve(
                dictation: .success(.copiedToClipboard),
                model: .ready,
                attentionReason: nil
            ),
            .success(.copiedToClipboard)
        )
        XCTAssertGreaterThan(
            SuccessFeedbackTiming.hideDelay(for: .copiedToClipboard),
            SuccessFeedbackTiming.hideDelay(for: .inserted)
        )
    }

    func testUnsupportedAXVerificationDoesNotOpenTranscriptAfterPaste() async {
        let receipt = InjectionVerificationReceipt()
        let delivery = InjectionDelivery(initialResult: .pasteUnverified, receipt: receipt)
        await receipt.resolve(.unobservable)
        let outcome = await delivery.verificationOutcome()
        XCTAssertEqual(delivery.initialResult, .pasteUnverified)
        let refinement = AppFeedbackPresentation.successAfterPostedInputVerification(outcome!)
        XCTAssertNil(refinement, "Missing AX evidence must not turn an already-posted paste into a transcript preview")
        XCTAssertEqual(SuccessFeedbackTiming.hideDelay(for: refinement ?? .pastedUnverified), 0.9)
    }

    func testMissedObservationAfterEditorClearsDoesNotReopenTranscript() async {
        // A submitted composer can already be empty at the delayed read, just like an ignored
        // paste. The receipt still protects clipboard/recovery, but cannot prove no input landed.
        let receipt = InjectionVerificationReceipt()
        let delivery = InjectionDelivery(initialResult: .pasteUnverified, receipt: receipt)
        await receipt.resolve(.failed)
        let outcome = await delivery.verificationOutcome()
        XCTAssertNil(AppFeedbackPresentation.successAfterPostedInputVerification(outcome!, submitWasPosted: true))
    }

    /// A paste that visibly did not land must reopen the pill with Copy, never leave nothing.
    func testFailedPasteWithoutSubmitReopensTheCopyPill() {
        XCTAssertEqual(AppFeedbackPresentation.successAfterPostedInputVerification(.failed), .copiedToClipboard)
    }

    func testConfirmedPasteRefinesToInsertedWithoutTranscriptPreview() {
        XCTAssertEqual(AppFeedbackPresentation.successAfterPostedInputVerification(.confirmed), .inserted)
    }

    func testErrorWinsOverModelLoading() {
        XCTAssertEqual(
            AppFeedbackPresentation.resolve(
                dictation: .error("Saved for retry"),
                model: .loading(nil),
                attentionReason: nil
            ),
            .error("Saved for retry")
        )
    }

    func testCancelledWinsOverModelLoading() {
        XCTAssertEqual(
            AppFeedbackPresentation.resolve(
                dictation: .cancelled,
                model: .loading(nil),
                attentionReason: nil
            ),
            .cancelled
        )
    }

    func testIdleReflectsModelLoadingProgress() {
        let presentation = AppFeedbackPresentation.resolve(
            dictation: .idle,
            model: .loading(0.5),
            attentionReason: nil
        )

        XCTAssertEqual(presentation, .loading(0.5))
        XCTAssertEqual(presentation.statusLabel, "Loading model… 50%")
    }

    func testIdleAttentionWinsOverBackgroundModelLoading() {
        XCTAssertEqual(
            AppFeedbackPresentation.resolve(
                dictation: .idle,
                model: .loading(0.5),
                attentionReason: "Microphone access needed"
            ),
            .attention("Microphone access needed")
        )
    }

    func testAttentionPreservesTheActualModelFailureReason() {
        XCTAssertEqual(
            AppAttentionReason.resolve(
                model: .failed("Finishing cancelled transcription"),
                hasAccessibility: true,
                hasMicrophone: true,
                hotkeyArmed: true
            ),
            "Finishing cancelled transcription"
        )
    }

    func testAttentionFallsBackThroughPermissionsAndShortcut() {
        XCTAssertEqual(
            AppAttentionReason.resolve(
                model: .ready,
                hasAccessibility: false,
                hasMicrophone: false,
                hotkeyArmed: false
            ),
            "Accessibility access needed"
        )
        XCTAssertEqual(
            AppAttentionReason.resolve(
                model: .ready,
                hasAccessibility: true,
                hasMicrophone: false,
                hotkeyArmed: false
            ),
            "Microphone access needed"
        )
        XCTAssertEqual(
            AppAttentionReason.resolve(
                model: .ready,
                hasAccessibility: true,
                hasMicrophone: true,
                hotkeyArmed: false
            ),
            "Shortcut not active"
        )
    }

    func testListeningActionStopsRecording() {
        XCTAssertEqual(PrimaryDictationAction.resolve(for: .listening), .stop)
        XCTAssertEqual(PrimaryDictationAction.stop.title, "Stop Recording")
    }

    func testTranscribingActionCancelsTranscription() {
        XCTAssertEqual(PrimaryDictationAction.resolve(for: .transcribing), .cancel)
        XCTAssertEqual(PrimaryDictationAction.cancel.title, "Cancel Transcription")
    }

    func testToggleHotkeyIsInertDuringTranscription() {
        XCTAssertEqual(ToggleHotkeyAction.resolve(for: .listening), .stop)
        XCTAssertEqual(ToggleHotkeyAction.resolve(for: .transcribing), .ignore)
        XCTAssertEqual(ToggleHotkeyAction.resolve(for: .idle), .start)
    }

    func testTerminalActionStartsANewRecording() {
        XCTAssertEqual(PrimaryDictationAction.resolve(for: .success(.inserted)), .start)
        XCTAssertEqual(PrimaryDictationAction.resolve(for: .error("failed")), .start)
        XCTAssertEqual(PrimaryDictationAction.resolve(for: .cancelled), .start)
    }

    func testStateChangeInvalidatesScheduledHide() {
        var gate = ScheduledTransitionGate()
        let terminalStateHide = gate.token

        gate.invalidate()

        XCTAssertFalse(gate.isCurrent(terminalStateHide))
    }

    func testLatestScheduledHideRemainsCurrentUntilAnotherStateChange() {
        var gate = ScheduledTransitionGate()
        gate.invalidate()
        let latestHide = gate.token

        XCTAssertTrue(gate.isCurrent(latestHide))
        gate.invalidate()
        XCTAssertFalse(gate.isCurrent(latestHide))
    }

    func testCancelledSessionHideCannotReturnActiveRetryToIdle() {
        var gate = ScheduledTransitionGate()
        gate.invalidate() // cancelled
        let cancelledSessionHide = gate.token

        gate.invalidate() // retry moved the app to transcribing

        XCTAssertFalse(gate.isCurrent(cancelledSessionHide))
    }

    func testPromotingUnverifiedPasteRequiresANewCurrentHide() {
        var gate = ScheduledTransitionGate()
        gate.invalidate() // pasted, unverified
        let unverifiedHide = gate.token

        gate.invalidate() // promoted to confirmed insertion
        let confirmedHide = gate.token

        XCTAssertFalse(gate.isCurrent(unverifiedHide))
        XCTAssertTrue(gate.isCurrent(confirmedHide))
        XCTAssertEqual(SuccessFeedbackTiming.hideDelay(for: .inserted), 0.9)
    }

    func testErrorFeedbackMeetsTheTwoSecondStatusContract() {
        XCTAssertEqual(FeedbackTiming.errorHoldSeconds, 2.0)
    }

    func testTranscriptPillExpandsOnlyWhenThePreviewWouldTruncate() {
        XCTAssertFalse(TranscriptPillPolicy.canExpand("Short transcript"))
        XCTAssertFalse(TranscriptPillPolicy.canExpand("First line\nSecond line"))
        XCTAssertTrue(TranscriptPillPolicy.canExpand("First line\nSecond line\nThird line"))
        XCTAssertTrue(TranscriptPillPolicy.canExpand(String(repeating: "word ", count: 24)))
    }

    func testExpandedTranscriptGetsEnoughTimeToRead() {
        XCTAssertGreaterThanOrEqual(TranscriptPillPolicy.collapsedHoldSeconds, 8)
        XCTAssertGreaterThan(
            TranscriptPillPolicy.expandedHoldSeconds,
            SuccessFeedbackTiming.hideDelay(for: .copiedToClipboard)
        )
        XCTAssertGreaterThan(TranscriptPillPolicy.copyConfirmationSeconds, 0)
    }

    // MARK: - Settings foreground

    func testSettingsForegroundSuppressesOnlyTheRestingPill() {
        XCTAssertTrue(PillPresentationPolicy.suppressedBySettings(settingsForeground: true, state: .idle))
        XCTAssertTrue(PillPresentationPolicy.suppressedBySettings(settingsForeground: true, state: .cancelled))
        let live: [DictationState] = [
            .listening, .transcribing, .success(.inserted), .success(.pastedUnverified),
            .success(.submitFailed), .success(.copiedToClipboard), .error("x"),
        ]
        for state in live {
            XCTAssertFalse(
                PillPresentationPolicy.suppressedBySettings(settingsForeground: true, state: state),
                "\(state) must present over Settings"
            )
        }
    }

    func testBackgroundSettingsNeverSuppresses() {
        XCTAssertFalse(PillPresentationPolicy.suppressedBySettings(settingsForeground: false, state: .idle))
        XCTAssertFalse(PillPresentationPolicy.suppressedBySettings(settingsForeground: false, state: .listening))
    }

    // MARK: - Copied pill hover and hold

    func testCopiedPillHoldsLongerWhenExpanded() {
        XCTAssertEqual(TranscriptPillPolicy.holdSeconds(transcriptExpanded: false),
                       TranscriptPillPolicy.collapsedHoldSeconds)
        XCTAssertEqual(TranscriptPillPolicy.holdSeconds(transcriptExpanded: true),
                       TranscriptPillPolicy.expandedHoldSeconds)
        XCTAssertEqual(SuccessFeedbackTiming.hideDelay(for: .copiedToClipboard),
                       TranscriptPillPolicy.collapsedHoldSeconds)
    }

    func testHoverPausesAndExitResumesTheCopiedPill() {
        XCTAssertEqual(TranscriptPillPolicy.hoverAction(
            isCopiedState: true, writingVisible: false, pointerInside: true, pausedByHover: false
        ), .pause)
        XCTAssertEqual(TranscriptPillPolicy.hoverAction(
            isCopiedState: true, writingVisible: false, pointerInside: true, pausedByHover: true
        ), .none, "repeated reports while hovering must not re-pause")
        XCTAssertEqual(TranscriptPillPolicy.hoverAction(
            isCopiedState: true, writingVisible: false, pointerInside: false, pausedByHover: true
        ), .resume)
        XCTAssertEqual(TranscriptPillPolicy.hoverAction(
            isCopiedState: true, writingVisible: false, pointerInside: false, pausedByHover: false
        ), .none, "an exit without a prior pause must not restart the countdown")
    }

    func testHoverIgnoresOtherStatesAndTheImproveCard() {
        XCTAssertEqual(TranscriptPillPolicy.hoverAction(
            isCopiedState: false, writingVisible: false, pointerInside: true, pausedByHover: false
        ), .none)
        XCTAssertEqual(TranscriptPillPolicy.hoverAction(
            isCopiedState: true, writingVisible: true, pointerInside: false, pausedByHover: true
        ), .none)
    }

    // MARK: - Cancel shortcut

    func testEscapeTargetsFollowThePillState() {
        XCTAssertEqual(CancelShortcutPolicy.target(state: .listening, idleMenuExpanded: false), .cancelDictation)
        XCTAssertEqual(CancelShortcutPolicy.target(state: .transcribing, idleMenuExpanded: false), .cancelDictation)
        XCTAssertEqual(CancelShortcutPolicy.target(state: .success(.copiedToClipboard), idleMenuExpanded: false),
                       .none, "the copied pill must not hold Escape system-wide")
        XCTAssertEqual(CancelShortcutPolicy.target(state: .idle, idleMenuExpanded: true), .collapseIdleMenu)
        XCTAssertEqual(CancelShortcutPolicy.target(state: .idle, idleMenuExpanded: false), .none)
    }

    func testEscapeIsLeftToOtherAppsWhenThePillHasNothingToDismiss() {
        let unclaimed: [DictationState] = [
            .idle, .cancelled, .success(.inserted), .success(.pastedUnverified),
            .success(.submitFailed), .success(.copiedToClipboard), .error("x"),
        ]
        for state in unclaimed {
            XCTAssertFalse(CancelShortcutPolicy.claimsShortcut(state: state, idleMenuExpanded: false),
                           "\(state) must not claim Escape")
        }
    }
}
