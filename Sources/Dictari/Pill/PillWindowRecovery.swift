import CoreGraphics
import Foundation

/// Public WindowServer evidence for the panel's current window device. `NSWindow.isVisible`
/// can remain true after that device has disappeared from the screen list, so it is not enough
/// to decide whether an already-created pill can be reused.
enum PillWindowBackingState: Equatable, Sendable {
    case absent
    case offscreen
    case onscreen
}

enum PillSurfaceSlot: Equatable, Sendable {
    case primary
    case standby

    var alternate: Self { self == .primary ? .standby : .primary }
}

enum PillRecoveryAction: Equatable, Sendable {
    case noAction
    case promote(PillSurfaceSlot)
    case exhausted
}

enum PillWindowRecovery {
    static let maxPromotionsPerPresentation = 1

    /// Query only Dictari's known window number. This is a public Core Graphics API and avoids
    /// enumerating or inspecting the contents of other applications' windows.
    static func backingState(for windowNumber: Int) -> PillWindowBackingState {
        guard windowNumber > 0,
              let descriptions = CGWindowListCopyWindowInfo(
                  .optionIncludingWindow,
                  CGWindowID(windowNumber)
              ) as? [[CFString: Any]]
        else { return .absent }

        return backingState(for: windowNumber, descriptions: descriptions)
    }

    static func shouldReplace(
        presentationRequested: Bool,
        appKitVisible: Bool,
        backingState: PillWindowBackingState
    ) -> Bool {
        guard presentationRequested else { return false }
        return !appKitVisible || backingState != .onscreen
    }

    /// Keep recovery deterministic and bounded. A presentation may promote the surface that was
    /// prepared at launch once, then verify it without entering a rebuild/retry loop.
    static func action(
        presentationRequested: Bool,
        settingsForeground: Bool,
        activeSlot: PillSurfaceSlot,
        appKitVisible: Bool,
        backingState: PillWindowBackingState,
        promotionsUsed: Int
    ) -> PillRecoveryAction {
        guard !settingsForeground,
              shouldReplace(
                  presentationRequested: presentationRequested,
                  appKitVisible: appKitVisible,
                  backingState: backingState
              )
        else { return .noAction }

        guard promotionsUsed < maxPromotionsPerPresentation else { return .exhausted }
        return .promote(activeSlot.alternate)
    }

    static func shouldReplenishStandby(
        promotionsUsed: Int,
        coordinatorStateIsActive: Bool,
        backingState: PillWindowBackingState
    ) -> Bool {
        promotionsUsed > 0 && !coordinatorStateIsActive && backingState == .onscreen
    }

    /// Kept separate from the live query so the stale-window cases are deterministic in the
    /// host-less test target and do not depend on the current Space or WindowServer timing.
    static func backingState(
        for windowNumber: Int,
        descriptions: [[CFString: Any]]
    ) -> PillWindowBackingState {
        guard let description = descriptions.first(where: {
            ($0[kCGWindowNumber] as? NSNumber)?.intValue == windowNumber
        }) else { return .absent }

        return (description[kCGWindowIsOnscreen] as? NSNumber)?.boolValue == true
            ? .onscreen
            : .offscreen
    }
}
