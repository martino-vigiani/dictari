import AppKit
import QuartzCore
import SwiftUI

/// A native viewport reuses a handful of cells regardless of archive size. Fixed row heights
/// avoid SwiftUI measuring every transcript while the user scrolls; full text stays in the model.
struct HistoryTableView: NSViewRepresentable {
    let items: [HistoryTimelineItem]
    let historyRevision: UInt
    let recoveryRevision: UInt
    let query: String
    let onRead: (HistoryEntry) -> Void
    let onRevise: (HistoryEntry) -> Void
    let onCorrect: (HistoryEntry) -> Void
    let onRetryRecovery: (DictationRecovery) -> Void
    let onDelete: (HistoryTimelineItem) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        // SwiftUI must size the viewport, never the native document's 10,000-row fitting
        // height. An unspecified ideal stays modest; a zero proposal must remain zero so
        // NSHostingController cannot enlarge the user's settings window to fit the archive.
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 500
        let height = proposal.height.flatMap { $0.isFinite ? $0 : nil } ?? 240
        return CGSize(width: max(0, width), height: max(0, height))
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let table = NSTableView()
        table.headerView = nil
        table.rowHeight = 86
        table.intercellSpacing = .zero
        table.backgroundColor = NSColor(Mono.card)
        table.selectionHighlightStyle = .none
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("history"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.setAccessibilityLabel(String(localized: "Transcription history", comment: "Accessibility label of the history list"))
        scroll.documentView = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onRead = onRead
        coordinator.onRevise = onRevise
        coordinator.onCorrect = onCorrect
        coordinator.onRetryRecovery = onRetryRecovery
        coordinator.onDelete = onDelete
        guard coordinator.historyRevision != historyRevision
                || coordinator.recoveryRevision != recoveryRevision
                || coordinator.query != query else { return }
        let queryChanged = coordinator.query != query
        let previous = coordinator.items
        coordinator.items = items
        coordinator.historyRevision = historyRevision
        coordinator.recoveryRevision = recoveryRevision
        coordinator.query = query
        guard let table = scroll.documentView as? NSTableView else { return }
        // One row added or removed, everything else identical (a new dictation, a delete):
        // animate just that row. Anything else — search, edits, bulk changes — reloads as
        // before, so the fast path can never show stale content.
        if !queryChanged, let change = Self.singleRowChange(from: previous, to: items) {
            let animation: NSTableView.AnimationOptions =
                NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? [] : [.effectFade, .slideUp]
            switch change {
            case .inserted(let row): table.insertRows(at: IndexSet(integer: row), withAnimation: animation)
            case .removed(let row): table.removeRows(at: IndexSet(integer: row), withAnimation: animation)
            }
            return
        }
        table.reloadData()
        if queryChanged { scroll.contentView.scroll(to: .zero) }
    }

    private enum RowChange { case inserted(Int), removed(Int) }

    /// Returns the single row that differs between two timelines, or nil when the change is
    /// anything other than exactly one insertion or one removal with all other rows equal.
    /// Linear, and only run when the counts differ by one.
    private static func singleRowChange(
        from old: [HistoryTimelineItem],
        to new: [HistoryTimelineItem]
    ) -> RowChange? {
        guard !old.isEmpty, !new.isEmpty, abs(old.count - new.count) == 1 else { return nil }
        let (longer, shorter) = old.count > new.count ? (old, new) : (new, old)
        var index = 0
        while index < shorter.count, longer[index] == shorter[index] { index += 1 }
        // Everything after the odd row out must line up shifted by one.
        guard longer[(index + 1)...].elementsEqual(shorter[index...]) else { return nil }
        return old.count > new.count ? .removed(index) : .inserted(index)
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var items: [HistoryTimelineItem] = []
        var historyRevision: UInt?
        var recoveryRevision: UInt?
        var query: String?
        var onRead: ((HistoryEntry) -> Void)?
        var onRevise: ((HistoryEntry) -> Void)?
        var onCorrect: ((HistoryEntry) -> Void)?
        var onRetryRecovery: ((DictationRecovery) -> Void)?
        var onDelete: ((HistoryTimelineItem) -> Void)?
        private let cellID = NSUserInterfaceItemIdentifier("history-row")

        func numberOfRows(in tableView: NSTableView) -> Int { items.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard items.indices.contains(row) else { return nil }
            let cell = tableView.makeView(withIdentifier: cellID, owner: self) as? HistoryNativeCell
                ?? HistoryNativeCell(frame: .zero)
            cell.identifier = cellID
            cell.configure(items[row])
            cell.onRead = { [weak self] entry in self?.onRead?(entry) }
            cell.onRevise = { [weak self] entry in self?.onRevise?(entry) }
            cell.onCorrect = { [weak self] entry in self?.onCorrect?(entry) }
            cell.onRetryRecovery = { [weak self] recovery in self?.onRetryRecovery?(recovery) }
            cell.onDelete = { [weak self] item in self?.onDelete?(item) }
            return cell
        }
    }
}

/// No hosting views, per-row sheets, relative-date timers or constraints rebuilt during reuse.
@MainActor
private final class HistoryNativeCell: NSTableCellView {
    private let recoveryBackground = NSView()
    private let preview = NSTextField(wrappingLabelWithString: "")
    private let metadata = NSTextField(labelWithString: "")
    private let read = HistoryActionButton()
    private let revise = HistoryActionButton()
    private let correct = HistoryActionButton()
    private let copy = HistoryActionButton()
    private let retry = HistoryActionButton()
    private let delete = HistoryActionButton()
    private var item: HistoryTimelineItem?
    private var copyResetTask: Task<Void, Never>?
    private static let deleteLabel = String(localized: "Delete transcription", comment: "History row button")
    private static let copyLabel = String(localized: "Copy transcription", comment: "History row button")
    private static let copiedLabel = String(localized: "Copied", comment: "History row copy button after copying")
    private static let copyImage = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: copyLabel)
    private static let copiedImage = NSImage(systemSymbolName: "checkmark", accessibilityDescription: copiedLabel)
    var onRead: ((HistoryEntry) -> Void)?
    var onRevise: ((HistoryEntry) -> Void)?
    var onCorrect: ((HistoryEntry) -> Void)?
    var onRetryRecovery: ((DictationRecovery) -> Void)?
    var onDelete: ((HistoryTimelineItem) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        recoveryBackground.wantsLayer = true
        recoveryBackground.layer?.cornerRadius = 10
        recoveryBackground.layer?.cornerCurve = .continuous
        recoveryBackground.layer?.backgroundColor = NSColor(Mono.fieldFill).cgColor
        addSubview(recoveryBackground)
        preview.font = .systemFont(ofSize: 13)
        preview.maximumNumberOfLines = 2
        preview.lineBreakMode = .byTruncatingTail
        // The preview is attributed text (for the uncertain-word underline) whose paragraph
        // style wraps; the cell still ends the second visible line with an ellipsis.
        preview.cell?.truncatesLastVisibleLine = true
        // Wrapping labels are selectable by default. A click then swaps in the field editor,
        // which lays the text out on one line and hides the rest. Read/Copy cover selection.
        preview.isSelectable = false
        metadata.font = .systemFont(ofSize: 11)
        metadata.lineBreakMode = .byTruncatingTail
        metadata.textColor = NSColor(Mono.tertiaryText)
        for field in [preview, metadata] {
            addSubview(field)
        }
        for (button, symbol, title, action) in [
            (read, "doc.text", String(localized: "Read transcription", comment: "History row button"),
             #selector(readText)),
            (revise, "pencil.line", String(localized: "Revise text", comment: "History row button"),
             #selector(reviseText)),
            (correct, "character.cursor.ibeam",
             String(localized: "Correct transcription", comment: "History row button"), #selector(correctText)),
            (copy, "doc.on.doc", Self.copyLabel, #selector(copyText)),
            (retry, "arrow.clockwise", String(localized: "Retry saved recording", comment: "History row button"),
             #selector(retryRecovery)),
            (delete, "trash", Self.deleteLabel, #selector(deleteEntry))
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            button.imagePosition = .imageOnly
            button.isBordered = false
            button.contentTintColor = NSColor(Mono.secondaryText)
            button.toolTip = title
            button.setAccessibilityLabel(title)
            button.target = self
            button.action = action
            addSubview(button)
        }
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        // Every row has a fixed height: direct frames avoid solving the same constraint
        // graph on each scroll/reuse. Text remains bounded; Read exposes the entire original.
        let hasRecovery = item?.recovery != nil
        recoveryBackground.frame = bounds.insetBy(dx: 8, dy: 4)
        let leading: CGFloat = hasRecovery ? 20 : 16
        let textWidth = max(40, bounds.width - leading - 218)
        preview.frame = NSRect(x: leading, y: 13, width: textWidth, height: 34)
        metadata.frame = NSRect(x: leading, y: 52, width: textWidth, height: 16)
        for (offset, button) in [delete, retry, copy, correct, revise, read].enumerated() {
            button.frame = NSRect(x: bounds.width - 44 - CGFloat(offset) * 32,
                                  y: (bounds.height - 28) / 2, width: 28, height: 28)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard item?.recovery == nil else { return }
        NSColor(Mono.cardBorder).setFill()
        NSRect(x: 16, y: bounds.maxY - 0.5, width: max(0, bounds.width - 16), height: 0.5).fill()
    }

    func configure(_ item: HistoryTimelineItem) {
        copyResetTask?.cancel()
        copy.setSymbol(Self.copyImage, label: Self.copyLabel, animated: false)
        self.item = item

        let transcript = transcriptText(for: item)
        let previewString: String
        if !transcript.isEmpty {
            previewString = String(transcript.prefix(360))
        } else if let entry = item.history, entry.isFailure {
            previewString = HistoryFailureDescription.text(for: entry.tag)
        } else {
            previewString = item.recovery?.displayFailureDescription
                ?? String(localized: "Saved dictation needs attention", comment: "History row preview of a recovery")
        }
        // Underlines only when the row shows the entry's original text: spans index `text`,
        // not a correction or a recovery transcript.
        let showsOriginal = !transcript.isEmpty && transcript == item.history?.text
        preview.attributedStringValue = previewAttributed(
            previewString,
            // Spans index the full text; the prefix keeps its leading offsets, and any span
            // past the cut is clamped or dropped by the renderer.
            spans: showsOriginal ? item.history?.displayedUncertainSpans : nil,
            color: NSColor(item.recovery == nil ? Mono.primaryText : Mono.secondaryText)
        )

        let entry = item.history
        let recovery = item.recovery
        let duration = entry?.durationSeconds ?? recovery?.durationSeconds ?? 0
        let appName = entry?.appName ?? recovery?.appName
        let language = entry?.language ?? recovery?.language
        var details = [item.date.formatted(date: .abbreviated, time: .shortened),
                       Stats.formatDuration(duration)]
        if let appName { details.append(appName) }
        if let language, language != "auto" { details.append(language.uppercased()) }
        if showsOriginal, let entry, entry.displayedUncertainSpans != nil {
            let uncertain = entry.uncertainWordCount
            if uncertain > 0 {
                details.append(String(localized: "\(uncertain) uncertain",
                                      comment: "History row metadata: number of words the model was unsure of"))
            }
        }
        // The row shows the correction; say so, so the original is never mistaken for lost.
        let status = recoveryLabel(recovery).isEmpty && entry?.correctedText != nil
            ? String(localized: "Corrected", comment: "History row status: the row shows a hand correction")
            : recoveryLabel(recovery)
        metadata.attributedStringValue = metadataText(
            recoveryStatus: status,
            details: details.joined(separator: " · ")
        )

        let historyHasText = !(entry?.text.isEmpty ?? true)
        read.isHidden = !historyHasText
        revise.isHidden = !historyHasText
        correct.isHidden = !historyHasText || entry?.isFailure == true
        copy.isHidden = transcript.isEmpty
        retry.isHidden = recovery == nil || recovery?.state == .metadataDamaged
        let deleteLabel = recovery == nil
            ? Self.deleteLabel
            : String(localized: "Delete this dictation and saved recovery", comment: "History row button")
        delete.toolTip = deleteLabel
        delete.setAccessibilityLabel(deleteLabel)
        recoveryBackground.isHidden = recovery == nil
        needsLayout = true
        needsDisplay = true
    }

    @objc private func readText() { if let entry = item?.history { onRead?(entry) } }
    @objc private func reviseText() { if let entry = item?.history { onRevise?(entry) } }
    @objc private func correctText() { if let entry = item?.history { onCorrect?(entry) } }
    @objc private func copyText() {
        guard let item else { return }
        let text = transcriptText(for: item)
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copy.setSymbol(Self.copiedImage, label: Self.copiedLabel, animated: true)
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: Motion.feedbackHold) } catch { return }
            guard let self, self.item?.id == item.id else { return }
            self.copy.setSymbol(Self.copyImage, label: Self.copyLabel, animated: true)
        }
    }
    @objc private func retryRecovery() {
        if let recovery = item?.recovery { onRetryRecovery?(recovery) }
    }
    @objc private func deleteEntry() { if let item { onDelete?(item) } }

    private func transcriptText(for item: HistoryTimelineItem) -> String {
        if let transcript = item.recovery?.transcript, !transcript.isEmpty { return transcript }
        return item.history?.displayText ?? ""
    }

    private func recoveryLabel(_ recovery: DictationRecovery?) -> String {
        switch recovery?.state {
        case .injectionFailed: return String(localized: "Needs paste", comment: "History row status of a recovery")
        case .transcriptionFailed: return String(localized: "Needs retry", comment: "History row status of a recovery")
        case .transcribed: return String(localized: "Recovered", comment: "History row status of a recovery")
        case .metadataDamaged:
            return String(localized: "Needs attention", comment: "History row status of a recovery")
        case nil: return ""
        }
    }

    private func previewAttributed(_ text: String, spans: [UncertainSpan]?, color: NSColor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let value = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ])
        for range in UncertainSpanRendering.ranges(in: text, spans: spans) {
            value.addAttributes([
                .underlineStyle: NSUnderlineStyle([.single, .patternDot]).rawValue,
                .underlineColor: NSColor(Mono.secondaryText).withAlphaComponent(0.7)
            ], range: NSRange(range, in: text))
        }
        return value
    }

    private func metadataText(recoveryStatus: String, details: String) -> NSAttributedString {
        guard !recoveryStatus.isEmpty else {
            return NSAttributedString(
                string: details,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor(Mono.tertiaryText)
                ]
            )
        }

        let value = NSMutableAttributedString(
            string: recoveryStatus,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor(Mono.secondaryText)
            ]
        )
        value.append(NSAttributedString(
            string: "  ·  \(details)",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor(Mono.tertiaryText)
            ]
        ))
        return value
    }
}

/// A lightweight native button for the virtualised history table. Layer animations keep the
/// feedback off the layout path, so thousands of rows still scroll without remeasurement.
@MainActor
private final class HistoryActionButton: NSButton {
    private var hoverTrackingArea: NSTrackingArea?
    private var isPointerInside = false
    private var symbolRevision = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Metrics.controlRadius - 1
        layer?.cornerCurve = .continuous
    }

    convenience init() { self.init(frame: .zero) }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        animateInteraction(scale: 1, opacity: 1, highlighted: true, duration: Motion.hoverDuration)
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        animateInteraction(scale: 1, opacity: 1, highlighted: false, duration: Motion.hoverDuration)
    }

    override func mouseDown(with event: NSEvent) {
        animateInteraction(scale: 0.94, opacity: 0.78, highlighted: true, duration: Motion.pressDuration)
        super.mouseDown(with: event)
        animateInteraction(
            scale: 1,
            opacity: 1,
            highlighted: isPointerInside,
            duration: Motion.hoverDuration
        )
    }

    func setSymbol(_ symbol: NSImage?, label: String, animated: Bool) {
        symbolRevision += 1
        let revision = symbolRevision
        toolTip = label
        setAccessibilityLabel(label)

        guard animated,
              window != nil,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            alphaValue = 1
            image = symbol
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.06
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 0.25
        }
        Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(60)) } catch { return }
            guard let self, self.symbolRevision == revision else { return }
            self.image = symbol
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.10
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.animator().alphaValue = 1
            }
        }
    }

    private func animateInteraction(
        scale: CGFloat,
        opacity: Float,
        highlighted: Bool,
        duration: TimeInterval
    ) {
        guard let layer else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let targetTransform = CATransform3DMakeScale(reduceMotion ? 1 : scale, reduceMotion ? 1 : scale, 1)
        let targetBackground = highlighted ? NSColor(Mono.hover).cgColor : NSColor.clear.cgColor

        if reduceMotion {
            layer.transform = targetTransform
            layer.opacity = opacity
            layer.backgroundColor = targetBackground
            return
        }

        let visibleLayer = layer.presentation() ?? layer
        addAnimation(
            to: layer,
            keyPath: "transform",
            from: NSValue(caTransform3D: visibleLayer.transform),
            to: NSValue(caTransform3D: targetTransform),
            duration: duration
        )
        addAnimation(
            to: layer,
            keyPath: "opacity",
            from: visibleLayer.opacity,
            to: opacity,
            duration: duration
        )
        addAnimation(
            to: layer,
            keyPath: "backgroundColor",
            from: visibleLayer.backgroundColor ?? NSColor.clear.cgColor,
            to: targetBackground,
            duration: duration
        )
        layer.transform = targetTransform
        layer.opacity = opacity
        layer.backgroundColor = targetBackground
    }

    private func addAnimation(
        to layer: CALayer,
        keyPath: String,
        from: Any,
        to: Any,
        duration: TimeInterval
    ) {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animation, forKey: "dictari.\(keyPath)")
    }
}
