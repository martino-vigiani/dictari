// ConversationPolicyTests.swift
// Conversation mode: keep listening, deliver each pause, stop on the next press.
//
// The coordinator executes exactly what `ConversationPolicy` answers, so its lifecycle — start,
// pause → deliver → keep listening, stop from either shortcut, cancel, silent pauses, delivery
// order, and the pill growing with undelivered text — is pinned here without a microphone.

import AppKit
import XCTest

final class ConversationPolicyTests: XCTestCase {

    // MARK: - Start

    func testConversationShortcutStartsFromEveryRestingState() {
        let resting: [DictationState] = [.idle, .cancelled, .error("x"),
                                          .success(.inserted), .success(.copiedToClipboard)]
        for state in resting {
            XCTAssertEqual(
                ConversationPolicy.activation(.conversationShortcut, state: state, conversationActive: false),
                .startConversation, "\(state)")
        }
    }

    func testConversationShortcutStopsAnOrdinaryDictationInsteadOfStartingOverIt() {
        XCTAssertEqual(
            ConversationPolicy.activation(.conversationShortcut, state: .listening, conversationActive: false),
            .stopDictation)
        XCTAssertEqual(
            ConversationPolicy.activation(.conversationShortcut, state: .transcribing, conversationActive: false),
            .ignore)
    }

    func testOtherShortcutsKeepTheirOrdinaryMeaningOutsideAConversation() {
        for source in [ConversationPolicy.ActivationSource.dictationShortcut, .revisionShortcut, .stopRequest] {
            for state: DictationState in [.idle, .listening, .transcribing] {
                XCTAssertEqual(
                    ConversationPolicy.activation(source, state: state, conversationActive: false),
                    .ordinary)
            }
        }
    }

    // MARK: - Stop: its own shortcut and the dictation shortcut

    func testEveryShortcutEndsAListeningConversation() {
        for source in [ConversationPolicy.ActivationSource.conversationShortcut, .dictationShortcut,
                       .revisionShortcut, .stopRequest] {
            XCTAssertEqual(
                ConversationPolicy.activation(source, state: .listening, conversationActive: true),
                .endConversation, "\(source)")
        }
    }

    func testPressesWhileTheLastSegmentsAreDeliveredDoNothing() {
        for source in [ConversationPolicy.ActivationSource.conversationShortcut, .dictationShortcut] {
            XCTAssertEqual(
                ConversationPolicy.activation(source, state: .transcribing, conversationActive: true),
                .ignore)
        }
    }

    // MARK: - Pause → deliver → keep listening

    func testAutoStopDeliversTheSegmentAndKeepsListening() {
        XCTAssertEqual(
            ConversationPolicy.autoStop(conversationActive: true, state: .listening, captureContinues: true),
            .deliverSegmentAndContinue)
    }

    /// A route change stops the audio engine underneath us: there is no capture to continue.
    func testAutoStopFromADeadCaptureEndsTheConversation() {
        XCTAssertEqual(
            ConversationPolicy.autoStop(conversationActive: true, state: .listening, captureContinues: false),
            .endConversation)
    }

    func testOrdinaryDictationAutoStopIsUnchanged() {
        XCTAssertEqual(
            ConversationPolicy.autoStop(conversationActive: false, state: .listening, captureContinues: true),
            .ordinary)
    }

    func testConversationAlwaysAutoStopsOnSilence() {
        XCTAssertEqual(ConversationPolicy.silenceSeconds(vadEnabled: false, configuredSeconds: 2.5),
                       ConversationPolicy.defaultSilenceSeconds)
        XCTAssertEqual(ConversationPolicy.silenceSeconds(vadEnabled: true, configuredSeconds: 2.5), 2.5)
        XCTAssertEqual(ConversationPolicy.defaultSilenceSeconds, 1.2, accuracy: 0.001)
    }

    // MARK: - Cancel

    func testEscapeDiscardsTheCurrentTurnButLetsFinishedTurnsLand() {
        XCTAssertEqual(
            ConversationPolicy.cancel(conversationActive: true, state: .listening, pendingSegments: 2),
            .discardCurrentAndFinishPending)
    }

    func testEscapeWithNothingPendingCancelsImmediately() {
        XCTAssertEqual(
            ConversationPolicy.cancel(conversationActive: true, state: .listening, pendingSegments: 0),
            .cancelNow)
    }

    /// Once stopped, a second Escape is an ordinary cancel of the remaining delivery.
    func testEscapeAfterTheConversationStoppedIsAnOrdinaryCancel() {
        XCTAssertEqual(
            ConversationPolicy.cancel(conversationActive: true, state: .transcribing, pendingSegments: 1),
            .ordinary)
        XCTAssertEqual(
            ConversationPolicy.cancel(conversationActive: false, state: .listening, pendingSegments: 0),
            .ordinary)
    }

    // MARK: - Accidental / silent segments

    func testSilentOrAccidentalSegmentsAreDiscardedQuietly() {
        // A mis-trigger.
        XCTAssertEqual(ConversationPolicy.segmentDisposition(
            duration: 0.2, peak: 0.5, speechLevel: 0.5, minimumSpeechLevel: 0), .discard)
        // Long, but digital silence: an ordinary dictation says "No audio"; a conversation gap does not.
        XCTAssertEqual(ConversationPolicy.segmentDisposition(
            duration: 30, peak: 0.001, speechLevel: 0, minimumSpeechLevel: 0), .discard)
        // A voice across the room under the proximity filter.
        XCTAssertEqual(ConversationPolicy.segmentDisposition(
            duration: 4, peak: 0.2, speechLevel: 0.1, minimumSpeechLevel: 0.3), .discard)
    }

    func testARealTurnIsTranscribed() {
        XCTAssertEqual(ConversationPolicy.segmentDisposition(
            duration: 3, peak: 0.3, speechLevel: 0.6, minimumSpeechLevel: 0.2), .transcribe)
    }

    func testAnEmptyTranscriptIsAGapNotAFailure() {
        XCTAssertTrue(ConversationPolicy.discardsTranscript(""))
        XCTAssertFalse(ConversationPolicy.discardsTranscript("ciao"))
    }

    // MARK: - In-order delivery

    /// The first segment is slow (a long turn) and the second fast. Delivered in speaking order
    /// anyway, and the second never starts while the first runs — that is also what keeps two
    /// transcriptions off the engine at once.
    @MainActor
    func testSegmentsAreDeliveredInSpeakingOrderEvenWhenAnEarlierOneIsSlower() async {
        let chain = OrderedSegmentChain()
        var events: [String] = []
        chain.enqueue {
            events.append("start 0")
            try? await Task.sleep(for: .milliseconds(120))
            events.append("end 0")
        }
        chain.enqueue {
            events.append("start 1")
            events.append("end 1")
        }
        chain.enqueue {
            events.append("start 2")
            try? await Task.sleep(for: .milliseconds(10))
            events.append("end 2")
        }
        XCTAssertEqual(chain.pendingCount, 3)
        await chain.last?.value
        XCTAssertEqual(events, ["start 0", "end 0", "start 1", "end 1", "start 2", "end 2"])
        XCTAssertEqual(chain.pendingCount, 0)
    }

    /// A job enqueued from inside a running job (a failure ending the conversation) still runs
    /// after it, and the chain drains.
    @MainActor
    func testJobsEnqueuedFromARunningJobRunAfterIt() async {
        let chain = OrderedSegmentChain()
        var events: [Int] = []
        chain.enqueue {
            events.append(0)
            chain.enqueue { events.append(2) }
            events.append(1)
        }
        await chain.last?.value
        // `last` was read before the nested enqueue ran; wait for the new tail too.
        await chain.last?.value
        XCTAssertEqual(events, [0, 1, 2])
    }

    @MainActor
    func testCancelAllReachesQueuedJobsWithoutBreakingOrder() async {
        let chain = OrderedSegmentChain()
        var observed: [Bool] = []
        chain.enqueue {
            try? await Task.sleep(for: .milliseconds(50))
            observed.append(Task.isCancelled)
        }
        chain.enqueue { observed.append(Task.isCancelled) }
        chain.cancelAll()
        await chain.last?.value
        XCTAssertEqual(observed, [true, true])
        XCTAssertEqual(chain.pendingCount, 0)
    }

    // MARK: - Undelivered text: accumulation and the end-of-conversation pill

    func testUndeliveredTurnsAccumulateInSpeakingOrder() {
        var transcript = ConversationTranscript()
        transcript.insert("second", at: 2)
        transcript.insert("  first  ", at: 0)
        transcript.insert("", at: 1)           // nothing to show
        transcript.insert("again", at: 2)      // a segment is reported once
        XCTAssertEqual(transcript.text, "first second")
    }

    func testASpokenLineBreakIsNotFollowedByASpace() {
        var transcript = ConversationTranscript()
        transcript.insert("Dear Anna,\n", at: 0)
        XCTAssertEqual(transcript.text, "Dear Anna,")
        var withBreak = ConversationTranscript()
        withBreak.insert("one\ntwo", at: 0)
        withBreak.insert("three", at: 1)
        XCTAssertEqual(withBreak.text, "one\ntwo three")
    }

    /// A paste verification can report "did not land" after later turns were already copied.
    func testALateFailedLandingIsInsertedAtItsOwnPlace() {
        var outcome = ConversationOutcome()
        outcome.record(.delivered(.pastedUnverified, text: "zero"), index: 0)
        outcome.record(.delivered(.copiedToClipboard, text: "two"), index: 2)
        outcome.recordFailedLanding("zero", index: 0)
        XCTAssertEqual(outcome.copiedTranscript.text, "zero two")
    }

    func testEndPresentationPrefersUndeliveredTextThenFailuresThenTheLastPaste() {
        var outcome = ConversationOutcome()
        XCTAssertEqual(ConversationPolicy.endPresentation(outcome), .quiet)

        outcome.record(.discarded, index: 0)
        XCTAssertEqual(ConversationPolicy.endPresentation(outcome), .quiet)

        outcome.record(.delivered(.pastedUnverified, text: "a"), index: 1)
        outcome.record(.delivered(.inserted, text: "b"), index: 2)
        XCTAssertEqual(ConversationPolicy.endPresentation(outcome), .success(.inserted))

        outcome.record(.failed("Model not ready"), index: 3)
        XCTAssertEqual(ConversationPolicy.endPresentation(outcome), .error("Model not ready"))

        outcome.record(.delivered(.copiedToClipboard, text: "keep me"), index: 4)
        XCTAssertEqual(ConversationPolicy.endPresentation(outcome), .copied("keep me"))
    }

    // MARK: - Pill

    func testThePillStaysTheListeningCapsuleWhileEveryTurnIsPasted() {
        XCTAssertEqual(ConversationPolicy.pillLayout(
            state: .listening, conversationActive: true, copiedTranscript: ""), .none)
    }

    func testTheCardGrowsWithUndeliveredText() {
        XCTAssertEqual(ConversationPolicy.pillLayout(
            state: .listening, conversationActive: true, copiedTranscript: "Short line."), .compact)
        let long = String(repeating: "A long conversation keeps going. ", count: 6)
        XCTAssertTrue(TranscriptPillPolicy.canExpand(long))
        XCTAssertEqual(ConversationPolicy.pillLayout(
            state: .listening, conversationActive: true, copiedTranscript: long), .expanded)
    }

    func testTheCardIsOnlyForAListeningConversation() {
        XCTAssertEqual(ConversationPolicy.pillLayout(
            state: .transcribing, conversationActive: true, copiedTranscript: "text"), .none)
        XCTAssertEqual(ConversationPolicy.pillLayout(
            state: .listening, conversationActive: false, copiedTranscript: "text"), .none)
    }

    func testCardGeometryFitsThePanelAndDoesNotChangeOrdinaryListening() {
        let ordinaryWidth = PillGeometry.visibleWidth(state: .listening, style: .compact, isExpanded: false)
        let ordinaryHeight = PillGeometry.visibleHeight(state: .listening, style: .compact,
                                                        idleMenuExpanded: false, transcriptExpanded: false)
        XCTAssertEqual(ordinaryWidth, PillGeometry.listeningWidth)
        XCTAssertEqual(ordinaryHeight, PillGeometry.listeningHeight)

        for layout in [ConversationPillLayout.compact, .expanded] {
            let width = PillGeometry.visibleWidth(state: .listening, style: .orb, isExpanded: false,
                                                  conversation: layout)
            let height = PillGeometry.visibleHeight(state: .listening, style: .orb, idleMenuExpanded: false,
                                                    transcriptExpanded: false, conversation: layout)
            XCTAssertEqual(width, PillGeometry.expandedTranscriptWidth)
            XCTAssertLessThanOrEqual(width + PillGeometry.horizontalInset * 2, PillGeometry.panelSize.width)
            XCTAssertLessThanOrEqual(height + PillGeometry.verticalInset * 2, PillGeometry.panelSize.height)
        }
        XCTAssertLessThan(
            PillGeometry.visibleHeight(state: .listening, style: .compact, idleMenuExpanded: false,
                                       transcriptExpanded: false, conversation: .compact),
            PillGeometry.visibleHeight(state: .listening, style: .compact, idleMenuExpanded: false,
                                       transcriptExpanded: false, conversation: .expanded))
    }

    func testCursorModeHoldsTheCardStill() {
        XCTAssertTrue(PillCursorFollowPolicy.shouldFollow(
            state: .listening, idleMenuExpanded: false, transcriptExpanded: false,
            writingVisible: false, pointerInsidePill: false))
        XCTAssertFalse(PillCursorFollowPolicy.shouldFollow(
            state: .listening, idleMenuExpanded: false, transcriptExpanded: false,
            writingVisible: false, pointerInsidePill: false, conversationCardVisible: true))
    }

    // MARK: - Shortcut validity and settings

    func testDefaultShortcutIsShiftOptionSpaceAndValid() {
        XCTAssertEqual(Shortcut.defaultConversation.keyCode, 49)
        XCTAssertEqual(Shortcut.defaultConversation.modifierFlags, [.shift, .option])
        XCTAssertNil(ConversationPolicy.validate(.defaultConversation, dictation: .defaultDictation,
                                                 cancel: .escape))
    }

    func testCollisionsWithEveryOtherActionAreRejected() {
        XCTAssertEqual(ConversationPolicy.validate(.defaultDictation, dictation: .defaultDictation,
                                                   cancel: .escape), .duplicate)
        XCTAssertEqual(ConversationPolicy.validate(.revisionDictation, dictation: .defaultDictation,
                                                   cancel: .escape), .duplicate)
        let cancel = Shortcut(keyCode: 49, modifiers: NSEvent.ModifierFlags([.shift, .option]).rawValue)
        XCTAssertEqual(ConversationPolicy.validate(.defaultConversation, dictation: .defaultDictation,
                                                   cancel: cancel), .duplicate)
        XCTAssertEqual(ConversationPolicy.validate(.finderSearch, dictation: .defaultDictation,
                                                   cancel: .escape), .systemOwned)
    }

    /// Swallowed on every keyDown: a bare letter or Escape would vanish from every app.
    func testBareKeysAndModifierOnlyShortcutsAreRejected() {
        let bareA = Shortcut(keyCode: 0, modifiers: 0)
        let rightOption = Shortcut(keyCode: 61, modifiers: NSEvent.ModifierFlags.option.rawValue)
        XCTAssertEqual(ConversationPolicy.validate(bareA, dictation: .defaultDictation, cancel: .escape), .unsafe)
        XCTAssertEqual(ConversationPolicy.validate(.escape, dictation: .defaultDictation,
                                                   cancel: Shortcut(keyCode: 12, modifiers: NSEvent.ModifierFlags.command.rawValue)),
                       .unsafe)
        XCTAssertEqual(ConversationPolicy.validate(rightOption, dictation: .defaultDictation, cancel: .escape), .unsafe)
        let f5 = Shortcut(keyCode: 96, modifiers: 0)
        XCTAssertNil(ConversationPolicy.validate(f5, dictation: .defaultDictation, cancel: .escape))
    }

    func testACollidingStoredShortcutDisarmsTheModeInsteadOfStealingTheKey() {
        let dictation = Shortcut.defaultConversation
        XCTAssertNil(ConversationPolicy.effectiveShortcut(.defaultConversation, dictation: dictation,
                                                          cancel: .escape))
        XCTAssertNil(ConversationPolicy.effectiveShortcut(nil, dictation: .defaultDictation, cancel: .escape))
        XCTAssertEqual(ConversationPolicy.effectiveShortcut(.defaultConversation, dictation: .defaultDictation,
                                                            cancel: .escape), .defaultConversation)
    }

    /// Settings written before the mode existed must decode (a missing non-optional key resets
    /// every preference) and get the default shortcut.
    func testSettingsWithoutTheNewKeysDecodeWithTheDefaultShortcut() throws {
        var old = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(SettingsData())) as! [String: Any]
        old.removeValue(forKey: "conversationShortcutChoice")
        old.removeValue(forKey: "conversationModeDisabled")
        let decoded = try JSONDecoder().decode(
            SettingsData.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertEqual(decoded.conversationShortcut, .defaultConversation)
    }

    func testTurningTheModeOffSurvivesARoundTripAndRemembersTheChoice() throws {
        var settings = SettingsData()
        let custom = Shortcut(keyCode: 46, modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue)
        settings.conversationShortcut = custom
        settings.conversationShortcut = nil
        let decoded = try JSONDecoder().decode(SettingsData.self, from: JSONEncoder().encode(settings))
        XCTAssertNil(decoded.conversationShortcut)
        XCTAssertEqual(decoded.conversationShortcutChoice, custom)

        var reenabled = decoded
        reenabled.conversationShortcut = reenabled.conversationShortcutChoice
        XCTAssertEqual(reenabled.conversationShortcut, custom)
    }
}
