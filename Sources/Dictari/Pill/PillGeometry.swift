import Foundation

/// The drawn pill's dimensions. The cursor clamp, host hit area and SwiftUI states share this
/// table so a new visible state cannot silently use the default capsule width at a screen edge.
enum PillGeometry {
    static let idleWidth: CGFloat = 62
    static let expandedMenuWidth: CGFloat = 144
    static let orbWidth: CGFloat = 38
    /// Recording grows into an explicit three-part control: cancel, live feedback, finish.
    /// Orb and compact share the same safe click targets; expanded adds transcript context.
    static let listeningWidth: CGFloat = 150
    static let expandedListeningWidth: CGFloat = 276
    static let listeningHeight: CGFloat = 40
    static let transcribingWidth: CGFloat = 70
    static let expandedTranscribingWidth: CGFloat = 144
    static let insertedWidth: CGFloat = 58
    static let pastedUnverifiedWidth: CGFloat = 74
    static let submitFailedWidth: CGFloat = 124
    static let writingPromptHeight: CGFloat = 62
    /// Room for a two-line preview beside three 28 pt actions (Improve, Copy, Close).
    static let transcriptWidth: CGFloat = 290
    static let expandedTranscriptWidth: CGFloat = 360
    static let collapsedTranscriptHeight: CGFloat = 52
    static let expandedTranscriptHeight: CGFloat = 220
    /// Conversation card with a short transcript: the listening controls over two lines of text.
    static let conversationCompactHeight: CGFloat = 104
    static let errorWidth: CGFloat = 260
    static let horizontalInset: CGFloat = 12
    static let verticalInset: CGFloat = 8
    static let panelSize = CGSize(
        width: expandedTranscriptWidth + horizontalInset * 2,
        height: expandedTranscriptHeight + verticalInset * 2
    )

    static func visibleWidth(
        state: DictationState,
        style: PillStyle,
        isExpanded: Bool,
        transcriptExpanded: Bool = false,
        conversation: ConversationPillLayout = .none
    ) -> CGFloat {
        switch state {
        case .idle, .cancelled:
            return isExpanded ? expandedMenuWidth : (style == .orb ? orbWidth : idleWidth)
        case .listening where conversation != .none:
            return expandedTranscriptWidth
        case .listening:
            switch style {
            case .compact: return listeningWidth
            case .expanded: return expandedListeningWidth
            case .orb: return listeningWidth
            }
        case .transcribing:
            return style == .expanded ? expandedTranscribingWidth : transcribingWidth
        case .success(.inserted): return insertedWidth
        case .success(.pastedUnverified): return pastedUnverifiedWidth
        case .success(.submitFailed): return submitFailedWidth
        case .success(.copiedToClipboard):
            return transcriptExpanded ? expandedTranscriptWidth : transcriptWidth
        case .error: return errorWidth
        }
    }

    static func visibleHeight(
        state: DictationState,
        style: PillStyle,
        idleMenuExpanded: Bool,
        transcriptExpanded: Bool,
        conversation: ConversationPillLayout = .none
    ) -> CGFloat {
        switch state {
        case .idle, .cancelled:
            if idleMenuExpanded { return 36 }
            return style == .orb ? orbWidth : 26
        case .listening:
            switch conversation {
            case .none: return listeningHeight
            case .compact: return conversationCompactHeight
            case .expanded: return expandedTranscriptHeight
            }
        case .transcribing, .success(.inserted), .success(.pastedUnverified),
             .success(.submitFailed), .error:
            return 28
        case .success(.copiedToClipboard):
            return transcriptExpanded ? expandedTranscriptHeight : collapsedTranscriptHeight
        }
    }

    /// Match SwiftUI's edge alignment in AppKit coordinates. Anchoring inside a fixed host
    /// lets expansion grow away from the screen edge without a simultaneous window jump.
    static func visibleRect(size: CGSize, position: PillPosition) -> CGRect {
        let x: CGFloat
        switch position {
        case .bottomLeading: x = horizontalInset
        case .bottomTrailing: x = panelSize.width - horizontalInset - size.width
        default: x = (panelSize.width - size.width) / 2
        }
        let y = position == .topCenter
            ? panelSize.height - verticalInset - size.height
            : verticalInset
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    /// NSHostingView is flipped, whereas panel positioning uses AppKit's bottom-left origin.
    /// Centered content hid this distinction; edge-anchored controls need the conversion.
    static func interactiveRect(size: CGSize, position: PillPosition, isFlipped: Bool) -> CGRect {
        let rect = visibleRect(size: size, position: position)
        guard isFlipped else { return rect }
        return CGRect(x: rect.minX, y: panelSize.height - rect.maxY,
                      width: rect.width, height: rect.height)
    }

    /// The transparent host is intentionally much larger than most pill states so animations can
    /// expand without moving their anchor. WindowServer sees that full host, not `NSView.hitTest`,
    /// so only the visible pill's screen-space rectangle may make the panel interactive.
    static func shouldIgnoreMouseEvents(
        mouseLocation: CGPoint,
        interactiveScreenRect: CGRect
    ) -> Bool {
        !interactiveScreenRect.contains(mouseLocation)
    }

    /// Keep a visible frame on screen by shifting it, never resizing it. Used when a frozen
    /// "Near Cursor" pill changes size in place instead of jumping back to the pointer.
    static func clamp(_ rect: CGRect, into bounds: CGRect, margin: CGFloat) -> CGRect {
        var result = rect
        let inner = bounds.insetBy(dx: margin, dy: margin)
        if result.maxX > inner.maxX { result.origin.x = inner.maxX - result.width }
        if result.minX < inner.minX { result.origin.x = inner.minX }
        if result.maxY > inner.maxY { result.origin.y = inner.maxY - result.height }
        if result.minY < inner.minY { result.origin.y = inner.minY }
        return result
    }
}

/// "Near Cursor" keeps the pill just above the pointer, so the pointer can never reach it: the
/// pill moves away as fast as the user approaches. Following stops whenever the pill offers
/// something to click, and whenever the pointer has actually arrived on it.
enum PillCursorFollowPolicy {
    static func shouldFollow(
        state: DictationState,
        idleMenuExpanded: Bool,
        transcriptExpanded: Bool,
        writingVisible: Bool,
        pointerInsidePill: Bool,
        conversationCardVisible: Bool = false
    ) -> Bool {
        // The conversation card carries Copy and a transcript to read; like the copied pill,
        // it must hold still to be reachable.
        if pointerInsidePill || idleMenuExpanded || transcriptExpanded || writingVisible
            || conversationCardVisible {
            return false
        }
        switch state {
        case .success, .error: return false
        case .idle, .listening, .transcribing, .cancelled: return true
        }
    }
}
