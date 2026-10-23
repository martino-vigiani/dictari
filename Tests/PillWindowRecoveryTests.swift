import CoreGraphics
import Foundation
import XCTest

final class PillWindowRecoveryTests: XCTestCase {
    func testRequestedVisiblePanelWithoutWindowServerBackingRequiresReplacement() {
        XCTAssertTrue(PillWindowRecovery.shouldReplace(
            presentationRequested: true,
            appKitVisible: true,
            backingState: .absent
        ))
    }

    func testRequestedVisiblePanelDetachedFromActiveSpaceRequiresReplacement() {
        XCTAssertTrue(PillWindowRecovery.shouldReplace(
            presentationRequested: true,
            appKitVisible: true,
            backingState: .offscreen
        ))
    }

    func testOnscreenPanelIsPreserved() {
        XCTAssertFalse(PillWindowRecovery.shouldReplace(
            presentationRequested: true,
            appKitVisible: true,
            backingState: .onscreen
        ))
    }

    func testPanelIsNotRebuiltWhilePresentationIsSuppressed() {
        for visible in [true, false] {
            XCTAssertFalse(PillWindowRecovery.shouldReplace(
                presentationRequested: false,
                appKitVisible: visible,
                backingState: .absent
            ))
        }
    }

    func testPanelStillOrderedOutAfterPresentationAttemptRequiresReplacement() {
        XCTAssertTrue(PillWindowRecovery.shouldReplace(
            presentationRequested: true,
            appKitVisible: false,
            backingState: .absent
        ))
    }

    func testWindowDescriptionsDistinguishAbsentDetachedAndOnscreenBacking() {
        let number = 42
        XCTAssertEqual(
            PillWindowRecovery.backingState(for: number, descriptions: []),
            .absent
        )
        XCTAssertEqual(
            PillWindowRecovery.backingState(for: number, descriptions: [[
                kCGWindowNumber: NSNumber(value: number)
            ]]),
            .offscreen
        )
        XCTAssertEqual(
            PillWindowRecovery.backingState(for: number, descriptions: [[
                kCGWindowNumber: NSNumber(value: number),
                kCGWindowIsOnscreen: NSNumber(value: true)
            ]]),
            .onscreen
        )
    }

    func testStalePrimaryPromotesPreallocatedStandbyOnFirstVerification() {
        XCTAssertEqual(
            PillWindowRecovery.action(
                presentationRequested: true,
                settingsForeground: false,
                activeSlot: .primary,
                appKitVisible: true,
                backingState: .absent,
                promotionsUsed: 0
            ),
            .promote(.standby)
        )
    }

    func testStaleStandbyPromotesPrimaryAfterHealthyIdleRecoveryResetsBudget() {
        XCTAssertEqual(
            PillWindowRecovery.action(
                presentationRequested: true,
                settingsForeground: false,
                activeSlot: .standby,
                appKitVisible: true,
                backingState: .offscreen,
                promotionsUsed: 0
            ),
            .promote(.primary)
        )
    }

    func testStalePromotedStandbyExhaustsSinglePromotionBudget() {
        XCTAssertEqual(
            PillWindowRecovery.action(
                presentationRequested: true,
                settingsForeground: false,
                activeSlot: .standby,
                appKitVisible: true,
                backingState: .absent,
                promotionsUsed: 1
            ),
            .exhausted
        )
    }

    func testOnscreenPromotedStandbyCompletesRecoveryWithoutAnotherPromotion() {
        XCTAssertEqual(
            PillWindowRecovery.action(
                presentationRequested: true,
                settingsForeground: false,
                activeSlot: .standby,
                appKitVisible: true,
                backingState: .onscreen,
                promotionsUsed: 1
            ),
            .noAction
        )
    }

    func testSettingsSuppressionPreventsStandbyPromotion() {
        XCTAssertEqual(
            PillWindowRecovery.action(
                presentationRequested: true,
                settingsForeground: true,
                activeSlot: .primary,
                appKitVisible: true,
                backingState: .absent,
                promotionsUsed: 0
            ),
            .noAction
        )
    }

    func testCancelledPresentationPreventsStandbyPromotion() {
        XCTAssertEqual(
            PillWindowRecovery.action(
                presentationRequested: false,
                settingsForeground: false,
                activeSlot: .primary,
                appKitVisible: true,
                backingState: .absent,
                promotionsUsed: 0
            ),
            .noAction
        )
    }

    func testHealthyIdleRecoveryReplenishesConsumedStandby() {
        XCTAssertTrue(PillWindowRecovery.shouldReplenishStandby(
            promotionsUsed: 1,
            coordinatorStateIsActive: false,
            backingState: .onscreen
        ))
        XCTAssertFalse(PillWindowRecovery.shouldReplenishStandby(
            promotionsUsed: 1,
            coordinatorStateIsActive: true,
            backingState: .onscreen
        ))
        XCTAssertFalse(PillWindowRecovery.shouldReplenishStandby(
            promotionsUsed: 1,
            coordinatorStateIsActive: false,
            backingState: .offscreen
        ))
    }
}
