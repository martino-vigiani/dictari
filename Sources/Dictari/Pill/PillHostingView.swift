import AppKit
import SwiftUI

/// AppKit gives hitTest a point in the superview's coordinates. The interactive rectangle
/// belongs to this flipped hosting view. Comparing them directly rejects real buttons near
/// the top and accepts transparent space near the bottom. Keep the original point for super.
final class PillHostingView: NSHostingView<AnyView> {
    var interactiveRect: NSRect = .zero
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    func acceptsHit(at point: NSPoint) -> Bool {
        let localPoint = convert(point, from: superview)
        return interactiveRect.contains(localPoint)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        acceptsHit(at: point) ? super.hitTest(point) : nil
    }
}
