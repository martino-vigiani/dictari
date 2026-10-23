import AppKit
import XCTest

final class PillGeometryTests: XCTestCase {

    private let panelSize = CGSize(width: 384, height: 236)
    private let collapsedTranscriptSize = CGSize(width: 290, height: 52)
    private let expandedTranscriptSize = CGSize(width: 360, height: 220)
    private let horizontalMargin: CGFloat = 12
    private let verticalMargin: CGFloat = 8

    func testTranscriptAndPanelDimensionsMatchTheGeometryContract() {
        XCTAssertEqual(PillGeometry.transcriptWidth, 290)
        XCTAssertEqual(PillGeometry.expandedTranscriptWidth, 360)
        XCTAssertEqual(PillGeometry.collapsedTranscriptHeight, 52)
        XCTAssertEqual(PillGeometry.expandedTranscriptHeight, 220)
        XCTAssertEqual(PillGeometry.panelSize, panelSize)
    }

    func testVisibleWidthMapsEveryStateAndStyle() {
        for style in PillStyle.allCases {
            let idleWidth = style == .orb ? PillGeometry.orbWidth : PillGeometry.idleWidth
            XCTAssertEqual(
                PillGeometry.visibleWidth(state: .idle, style: style, isExpanded: false),
                idleWidth,
                "idle width mismatch for \(style)"
            )
            XCTAssertEqual(
                PillGeometry.visibleWidth(state: .cancelled, style: style, isExpanded: false),
                idleWidth,
                "cancelled width mismatch for \(style)"
            )
            XCTAssertEqual(
                PillGeometry.visibleWidth(state: .idle, style: style, isExpanded: true),
                PillGeometry.expandedMenuWidth,
                "expanded menu width mismatch for \(style)"
            )

            let listeningWidth: CGFloat
            switch style {
            case .compact: listeningWidth = PillGeometry.listeningWidth
            case .expanded: listeningWidth = PillGeometry.expandedListeningWidth
            case .orb: listeningWidth = PillGeometry.listeningWidth
            }
            XCTAssertEqual(
                PillGeometry.visibleWidth(state: .listening, style: style, isExpanded: false),
                listeningWidth,
                "listening width mismatch for \(style)"
            )

            let transcribingWidth = style == .expanded
                ? PillGeometry.expandedTranscribingWidth
                : PillGeometry.transcribingWidth
            XCTAssertEqual(
                PillGeometry.visibleWidth(state: .transcribing, style: style, isExpanded: false),
                transcribingWidth,
                "transcribing width mismatch for \(style)"
            )

            for state in [
                DictationState.success(.inserted),
                .success(.pastedUnverified),
                .success(.submitFailed),
                .error("failure")
            ] {
                let expectedWidth: CGFloat
                switch state {
                case .success(.inserted): expectedWidth = PillGeometry.insertedWidth
                case .success(.pastedUnverified): expectedWidth = PillGeometry.pastedUnverifiedWidth
                case .success(.submitFailed): expectedWidth = PillGeometry.submitFailedWidth
                case .error: expectedWidth = PillGeometry.errorWidth
                default: XCTFail("unexpected state in fixed-width geometry cases"); continue
                }
                XCTAssertEqual(
                    PillGeometry.visibleWidth(state: state, style: style, isExpanded: false),
                    expectedWidth,
                    "fixed width mismatch for \(state) / \(style)"
                )
            }
        }
    }

    func testVisibleWidthUsesExpandedTranscriptWidthOnlyForExpandedClipboardTranscript() {
        let state = DictationState.success(.copiedToClipboard)

        XCTAssertEqual(
            PillGeometry.visibleWidth(state: state, style: .compact, isExpanded: false),
            290
        )
        XCTAssertEqual(
            PillGeometry.visibleWidth(
                state: state,
                style: .compact,
                isExpanded: false,
                transcriptExpanded: true
            ),
            360
        )
        XCTAssertEqual(
            PillGeometry.visibleWidth(
                state: state,
                style: .expanded,
                isExpanded: true,
                transcriptExpanded: true
            ),
            360
        )
    }

    func testVisibleHeightMapsEveryStateAndStyle() {
        for style in PillStyle.allCases {
            let idleHeight = style == .orb ? PillGeometry.orbWidth : 26
            XCTAssertEqual(
                PillGeometry.visibleHeight(
                    state: .idle,
                    style: style,
                    idleMenuExpanded: false,
                    transcriptExpanded: false
                ),
                idleHeight,
                "idle height mismatch for \(style)"
            )
            XCTAssertEqual(
                PillGeometry.visibleHeight(
                    state: .cancelled,
                    style: style,
                    idleMenuExpanded: true,
                    transcriptExpanded: false
                ),
                36,
                "expanded menu height mismatch for \(style)"
            )

            XCTAssertEqual(
                PillGeometry.visibleHeight(
                    state: .listening,
                    style: style,
                    idleMenuExpanded: false,
                    transcriptExpanded: false
                ),
                PillGeometry.listeningHeight,
                "listening height mismatch for \(style)"
            )

            for state in [
                DictationState.transcribing,
                .success(.inserted),
                .success(.pastedUnverified),
                .success(.submitFailed),
                .error("failure")
            ] {
                XCTAssertEqual(
                    PillGeometry.visibleHeight(
                        state: state,
                        style: style,
                        idleMenuExpanded: false,
                        transcriptExpanded: false
                    ),
                    28,
                    "fixed height mismatch for \(state) / \(style)"
                )
            }
        }

        let transcriptState = DictationState.success(.copiedToClipboard)
        XCTAssertEqual(
            PillGeometry.visibleHeight(
                state: transcriptState,
                style: .compact,
                idleMenuExpanded: false,
                transcriptExpanded: false
            ),
            52
        )
        XCTAssertEqual(
            PillGeometry.visibleHeight(
                state: transcriptState,
                style: .compact,
                idleMenuExpanded: false,
                transcriptExpanded: true
            ),
            220
        )
    }

    func testVisibleRectFitsInsidePanelWithRequiredMarginsForEveryPreset() {
        let positions = PillPosition.allCases
        let sizes = [
            collapsedTranscriptSize,
            expandedTranscriptSize,
            CGSize(width: PillGeometry.expandedMenuWidth, height: 36),
            CGSize(width: PillGeometry.orbWidth, height: PillGeometry.orbWidth)
        ]

        for size in sizes {
            for position in positions {
                let rect = PillGeometry.visibleRect(size: size, position: position)

                XCTAssertEqual(rect.size, size, "size changed for \(position)")
                XCTAssertGreaterThanOrEqual(
                    rect.minX,
                    horizontalMargin,
                    "left margin violated for \(position)"
                )
                XCTAssertLessThanOrEqual(
                    rect.maxX,
                    panelSize.width - horizontalMargin,
                    "right margin violated for \(position)"
                )
                XCTAssertGreaterThanOrEqual(
                    rect.minY,
                    verticalMargin,
                    "bottom margin violated for \(position)"
                )
                XCTAssertLessThanOrEqual(
                    rect.maxY,
                    panelSize.height - verticalMargin,
                    "top margin violated for \(position)"
                )
            }
        }
    }

    func testVisibleRectKeepsPresetAnchorsStableWhenTranscriptExpands() {
        for position in PillPosition.allCases {
            let collapsed = PillGeometry.visibleRect(
                size: collapsedTranscriptSize,
                position: position
            )
            let expanded = PillGeometry.visibleRect(
                size: expandedTranscriptSize,
                position: position
            )

            switch position {
            case .bottomLeading:
                XCTAssertEqual(collapsed.minX, horizontalMargin)
                XCTAssertEqual(expanded.minX, horizontalMargin)
                XCTAssertEqual(collapsed.minY, verticalMargin)
                XCTAssertEqual(expanded.minY, verticalMargin)
            case .bottomTrailing:
                XCTAssertEqual(collapsed.maxX, panelSize.width - horizontalMargin)
                XCTAssertEqual(expanded.maxX, panelSize.width - horizontalMargin)
                XCTAssertEqual(collapsed.minY, verticalMargin)
                XCTAssertEqual(expanded.minY, verticalMargin)
            case .bottomCenter, .cursor:
                XCTAssertEqual(collapsed.midX, panelSize.width / 2)
                XCTAssertEqual(expanded.midX, panelSize.width / 2)
                XCTAssertEqual(collapsed.minY, verticalMargin)
                XCTAssertEqual(expanded.minY, verticalMargin)
            case .topCenter:
                XCTAssertEqual(collapsed.midX, panelSize.width / 2)
                XCTAssertEqual(expanded.midX, panelSize.width / 2)
                XCTAssertEqual(collapsed.maxY, panelSize.height - verticalMargin)
                XCTAssertEqual(expanded.maxY, panelSize.height - verticalMargin)
            }
        }
    }

    func testInteractiveRectMatchesVisibleRectForAnUnflippedHost() {
        let sizes = [collapsedTranscriptSize, expandedTranscriptSize]

        for size in sizes {
            for position in PillPosition.allCases {
                XCTAssertEqual(
                    PillGeometry.interactiveRect(size: size, position: position, isFlipped: false),
                    PillGeometry.visibleRect(size: size, position: position),
                    "unflipped host changed the \(position) rect"
                )
            }
        }
    }

    func testInteractiveRectMirrorsAppKitYCoordinatesForAFlippedHost() {
        let sizes = [collapsedTranscriptSize, expandedTranscriptSize]

        for size in sizes {
            for position in PillPosition.allCases {
                let visible = PillGeometry.visibleRect(size: size, position: position)
                let interactive = PillGeometry.interactiveRect(
                    size: size,
                    position: position,
                    isFlipped: true
                )

                XCTAssertEqual(interactive.minX, visible.minX)
                XCTAssertEqual(interactive.width, visible.width)
                XCTAssertEqual(interactive.height, visible.height)
                XCTAssertEqual(interactive.minY, panelSize.height - visible.maxY)
                XCTAssertEqual(interactive.maxY, panelSize.height - visible.minY)
            }
        }
    }

    func testFlippedInteractiveRectKeepsContentCenterInsideAndOppositeMarginOutside() {
        let size = collapsedTranscriptSize

        for position in PillPosition.allCases {
            let rect = PillGeometry.interactiveRect(size: size, position: position, isFlipped: true)
            let center = CGPoint(x: rect.midX, y: rect.midY)
            XCTAssertTrue(rect.contains(center), "content center is not interactive for \(position)")

            let oppositeMarginY = position == .topCenter
                ? rect.minY - 1
                : rect.maxY + 1
            XCTAssertFalse(
                rect.contains(CGPoint(x: rect.midX, y: oppositeMarginY)),
                "opposite transparent margin became interactive for \(position)"
            )

            if position == .topCenter {
                XCTAssertEqual(rect.minY, verticalMargin)
            } else {
                XCTAssertEqual(rect.maxY, panelSize.height - verticalMargin)
            }
        }
    }

    func testTransparentPanelAreaIgnoresMouseEventsOutsideVisiblePill() {
        let visiblePillOnScreen = CGRect(x: 820, y: 940, width: 150, height: 40)

        XCTAssertFalse(PillGeometry.shouldIgnoreMouseEvents(
            mouseLocation: CGPoint(x: visiblePillOnScreen.midX, y: visiblePillOnScreen.midY),
            interactiveScreenRect: visiblePillOnScreen
        ))
        XCTAssertTrue(PillGeometry.shouldIgnoreMouseEvents(
            mouseLocation: CGPoint(x: visiblePillOnScreen.midX, y: visiblePillOnScreen.minY - 80),
            interactiveScreenRect: visiblePillOnScreen
        ))
        XCTAssertTrue(PillGeometry.shouldIgnoreMouseEvents(
            mouseLocation: CGPoint(x: visiblePillOnScreen.maxX + 1, y: visiblePillOnScreen.midY),
            interactiveScreenRect: visiblePillOnScreen
        ))
    }

    // MARK: - Near Cursor follow

    private func follows(_ state: DictationState, menu: Bool = false, expanded: Bool = false,
                         writing: Bool = false, inside: Bool = false) -> Bool {
        PillCursorFollowPolicy.shouldFollow(
            state: state, idleMenuExpanded: menu, transcriptExpanded: expanded,
            writingVisible: writing, pointerInsidePill: inside
        )
    }

    func testCursorFollowFreezesOnActionableStates() {
        XCTAssertTrue(follows(.idle))
        XCTAssertTrue(follows(.listening))
        XCTAssertTrue(follows(.transcribing))
        XCTAssertFalse(follows(.success(.copiedToClipboard)))
        XCTAssertFalse(follows(.success(.inserted)))
        XCTAssertFalse(follows(.error("x")))
    }

    func testCursorFollowFreezesWhileControlsOrPointerAreOnThePill() {
        XCTAssertFalse(follows(.idle, menu: true))
        XCTAssertFalse(follows(.idle, expanded: true))
        XCTAssertFalse(follows(.idle, writing: true))
        XCTAssertFalse(follows(.listening, inside: true))
    }

    func testClampShiftsWithoutResizing() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let offRight = CGRect(x: 900, y: 100, width: 290, height: 52)
        let clamped = PillGeometry.clamp(offRight, into: bounds, margin: 6)
        XCTAssertEqual(clamped.size, offRight.size)
        XCTAssertEqual(clamped.maxX, 994)
        XCTAssertEqual(clamped.minY, 100)

        let offTop = CGRect(x: 10, y: 700, width: 360, height: 220)
        let clampedTop = PillGeometry.clamp(offTop, into: bounds, margin: 6)
        XCTAssertEqual(clampedTop.maxY, 794)
        XCTAssertEqual(clampedTop.minX, 10)

        let inside = CGRect(x: 100, y: 100, width: 62, height: 26)
        XCTAssertEqual(PillGeometry.clamp(inside, into: bounds, margin: 6), inside)
    }
}
