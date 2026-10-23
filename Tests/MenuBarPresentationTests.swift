import XCTest

final class MenuBarPresentationTests: XCTestCase {
    func testIdleMenuKeepsOnlyEssentialRowsInStableOrder() {
        let presentation = makePresentation()

        XCTAssertNil(presentation.status)
        XCTAssertEqual(
            presentation.visibleItemOrder,
            [.primary, .copy, .profile, .settings, .quit]
        )
    }

    func testStatusAppearsOnlyForAttentionLoadingFailureOrMediaWork() {
        XCTAssertNil(makePresentation(feedback: .ready).status)
        XCTAssertNil(makePresentation(state: .listening, feedback: .listening).status)
        XCTAssertNil(makePresentation(state: .transcribing, feedback: .transcribing).status)
        XCTAssertNil(makePresentation(feedback: .success(.inserted)).status)
        XCTAssertNil(makePresentation(feedback: .cancelled).status)

        XCTAssertEqual(makePresentation(feedback: .attention("Microphone access needed")).status,
                       "Microphone access needed")
        XCTAssertEqual(makePresentation(feedback: .loading(0.42)).status, "Loading model… 42%")
        XCTAssertEqual(makePresentation(feedback: .error("Model unavailable")).status,
                       "Error: Model unavailable")
        XCTAssertEqual(makePresentation(isMediaBusy: true).status,
                       "Files & Meetings is busy")
    }

    func testPrimaryActionMatchesListeningAndTranscribing() {
        let listening = makePresentation(state: .listening, feedback: .listening)
        XCTAssertEqual(listening.primary.action, .stop)
        XCTAssertEqual(listening.primary.title, "Finish Dictation")
        XCTAssertEqual(listening.primary.symbolName, "stop.fill")
        XCTAssertNil(listening.primary.shortcut)

        let transcribing = makePresentation(state: .transcribing, feedback: .transcribing)
        XCTAssertEqual(transcribing.primary.action, .cancel)
        XCTAssertEqual(transcribing.primary.title, "Cancel Transcription")
        XCTAssertEqual(transcribing.primary.symbolName, "xmark")
        XCTAssertNil(transcribing.primary.shortcut)
    }

    func testPrimaryActionIsDisabledWhileMediaModelIsBusy() {
        let presentation = makePresentation(isMediaBusy: true)

        XCTAssertFalse(presentation.primary.isEnabled)
        XCTAssertEqual(presentation.primary.action, .start)
    }

    func testCopyPreviewIsBoundedButActionRetainsFullTranscript() {
        let transcript = "This is a deliberately long dictation\nwith several words that must remain intact when copied."
        let presentation = makePresentation(transcript: transcript)

        XCTAssertTrue(presentation.copy.isEnabled)
        XCTAssertEqual(presentation.copy.fullText, transcript)
        XCTAssertEqual(presentation.copy.preview,
                       "This is a deliberately long dictation with sev…")
        XCTAssertLessThanOrEqual(presentation.copy.preview?.count ?? .max, 47)
    }

    func testSelectedProfileIsMarkedAndCustomBoundaryIsClamped() {
        let profiles = [
            MenuBarPresentation.ProfileInput(id: "standard", name: "Default"),
            MenuBarPresentation.ProfileInput(id: "code", name: "Code"),
            MenuBarPresentation.ProfileInput(id: "research", name: "Research")
        ]
        let presentation = makePresentation(
            profiles: profiles,
            builtInProfileCount: 99,
            activeProfileID: "research",
            activeProfileName: "Research"
        )

        XCTAssertEqual(presentation.profileTitle, "Profile: Research")
        XCTAssertEqual(presentation.profiles.map(\.isSelected), [false, false, true])
        XCTAssertEqual(presentation.builtInProfileCount, profiles.count)
    }

    func testUpdateRowIsConditionalAndKeepsItsEnabledState() {
        XCTAssertFalse(makePresentation().visibleItemOrder.contains(.updates))

        let presentation = makePresentation(updatesVisible: true, updatesEnabled: false)
        XCTAssertEqual(
            presentation.visibleItemOrder,
            [.primary, .copy, .profile, .settings, .updates, .quit]
        )
        XCTAssertFalse(presentation.updatesEnabled)
    }

    private func makePresentation(
        state: DictationState = .idle,
        feedback: AppFeedbackPresentation = .ready,
        isMediaBusy: Bool = false,
        transcript: String = "",
        profiles: [MenuBarPresentation.ProfileInput] = [
            .init(id: "standard", name: "Default"),
            .init(id: "code", name: "Code")
        ],
        builtInProfileCount: Int = 2,
        activeProfileID: String = "standard",
        activeProfileName: String = "Default",
        updatesVisible: Bool = false,
        updatesEnabled: Bool = false
    ) -> MenuBarPresentation {
        MenuBarPresentation.resolve(.init(
            dictationState: state,
            feedback: feedback,
            isMediaBusy: isMediaBusy,
            shortcut: "⌥ Space",
            profiles: profiles,
            builtInProfileCount: builtInProfileCount,
            activeProfileID: activeProfileID,
            activeProfileName: activeProfileName,
            transcript: transcript,
            updatesVisible: updatesVisible,
            updatesEnabled: updatesEnabled
        ))
    }
}
