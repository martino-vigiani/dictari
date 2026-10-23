import AppKit
import SwiftUI
import XCTest

@MainActor
final class PillHostingViewTests: XCTestCase {
    func testTopAndBottomButtonsUseHostingCoordinates() {
        for position in [PillPosition.topCenter, .bottomCenter] {
            let parent = NSView(frame: NSRect(origin: .zero, size: PillGeometry.panelSize))
            let host = PillHostingView(rootView: AnyView(Color.black.frame(maxWidth: .infinity, maxHeight: .infinity)))
            host.frame = parent.bounds
            parent.addSubview(host)
            host.interactiveRect = PillGeometry.interactiveRect(
                size: CGSize(width: 360, height: 62), position: position, isFlipped: host.isFlipped)
            // A real hosting surface, without unsupported AppKit children or an app launch.
            host.layoutSubtreeIfNeeded()
            let buttonPoint = NSPoint(x: host.interactiveRect.midX, y: host.interactiveRect.midY)
            let parentPoint = parent.convert(buttonPoint, from: host)
            XCTAssertTrue(host.acceptsHit(at: parentPoint), "Button rejected at \(position)")
            let outside = NSPoint(x: 1, y: 1)
            XCTAssertFalse(host.acceptsHit(at: parent.convert(outside, from: host)))
        }
    }
    func testOffsetHostConvertsSuperviewPointAndAcceptsFirstClick() {
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let host = PillHostingView(rootView: AnyView(Color.black.frame(maxWidth: .infinity, maxHeight: .infinity)))
        host.frame = NSRect(x: 40, y: 60, width: 384, height: 236)
        parent.addSubview(host)
        host.interactiveRect = NSRect(x: 12, y: 8, width: 360, height: 62)
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(host.acceptsHit(at: parent.convert(NSPoint(x: 40, y: 24), from: host)))
        XCTAssertTrue(host.acceptsFirstMouse(for: nil))
    }
}
