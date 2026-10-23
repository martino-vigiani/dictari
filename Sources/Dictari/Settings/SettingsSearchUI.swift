// SettingsSearchUI.swift
// Dictari — the settings sidebar search field, its results, and row reveal.
//
// Flow: the sidebar runs `SettingsSearchIndex.search` on every keystroke (microseconds, see
// SettingsSearch.swift). Choosing a result selects its section and hands its anchor to the
// shared `SettingsSearchNavigator`. The newly shown page's `SettingsScrollPane` scrolls to that
// anchor, and the row carrying `.settingsSearchAnchor(id)` washes itself briefly so the eye
// lands on it. Pages whose rows hide behind local state (History's storage popover, Files &
// Meetings' source switch, Writing's editor) watch the navigator and open themselves.

import AppKit
import SwiftUI

// MARK: - Navigator

/// Owned by `SettingsRootView`, shared through the environment. Holds only the request to
/// reveal a row; which section is shown stays in the root's own selection state.
@MainActor
@Observable
final class SettingsSearchNavigator {
    /// The anchor the current page should scroll to and highlight, if any.
    private(set) var pendingAnchor: String?
    /// Bumped on every request, so choosing the same result twice still reveals it again.
    private(set) var revealToken = 0

    @ObservationIgnored private var expiry: Task<Void, Never>?

    func reveal(_ anchor: String?) {
        pendingAnchor = anchor
        revealToken &+= 1
        expiry?.cancel()
        guard anchor != nil else { return }
        // A request is consumed by whatever page appears next. Expire it so that a later,
        // ordinary visit to the same page does not replay the highlight.
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.pendingAnchor = nil
        }
    }

    func isPending(_ anchor: String) -> Bool { pendingAnchor == anchor }
}

// MARK: - Anchor modifier

extension View {
    /// Marks a settings row or card as a search destination. `id` must match an entry's
    /// `anchor` in `SettingsSearchCatalog` (a test checks every catalog anchor is used).
    func settingsSearchAnchor(_ id: String) -> some View {
        modifier(SettingsSearchAnchorModifier(anchorID: id))
    }
}

private struct SettingsSearchAnchorModifier: ViewModifier {
    let anchorID: String
    @Environment(SettingsSearchNavigator.self) private var navigator: SettingsSearchNavigator?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var highlighted = false

    func body(content: Content) -> some View {
        content
            // An overlay, not a background: several anchored rows paint their own opaque card
            // fill, which would hide a wash placed underneath.
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Mono.searchHighlight)
                    .opacity(highlighted ? 1 : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .id(anchorID)
            .task(id: navigator?.revealToken) {
                guard let navigator, navigator.isPending(anchorID) else {
                    // Every anchor on a page runs this when the page appears; writing only
                    // when lit keeps dozens of no-op state writes out of the first frames
                    // of the page transition.
                    if highlighted { highlighted = false }
                    return
                }
                // Wait for the scroll to land so the wash is seen arriving, not mid-flight.
                try? await Task.sleep(for: .milliseconds(reduceMotion ? 80 : 320))
                guard !Task.isCancelled else { return }
                // A quick fade in reads as "here", a hard switch read as a flicker.
                withAnimation(Motion.reduced(Motion.swap, reduceMotion: reduceMotion)) {
                    highlighted = true
                }
                try? await Task.sleep(for: .seconds(1.1))
                guard !Task.isCancelled else { highlighted = false; return }
                withAnimation(Motion.reduced(.easeOut(duration: 0.9), reduceMotion: reduceMotion)) {
                    highlighted = false
                }
            }
    }
}

// MARK: - Scroll-to-anchor for pages

/// Applied inside `SettingsScrollPane`: scrolls to the pending anchor once the page exists.
struct SettingsSearchScrollTarget: ViewModifier {
    let proxy: ScrollViewProxy
    @Environment(SettingsSearchNavigator.self) private var navigator: SettingsSearchNavigator?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.task(id: navigator?.revealToken) {
            guard let anchor = navigator?.pendingAnchor else { return }
            // A page that just replaced another has not laid out its rows yet; scrollTo on an
            // unmeasured id silently does nothing.
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            // Upper third rather than centre: a tall card still shows its header.
            let point = UnitPoint(x: 0.5, y: 0.3)
            if reduceMotion {
                proxy.scrollTo(anchor, anchor: point)
            } else {
                // `reveal`, not `appear`: a scroll that overshoots its target makes the eye
                // hunt for the row it was just shown.
                withAnimation(Motion.reveal) { proxy.scrollTo(anchor, anchor: point) }
            }
        }
    }
}

extension View {
    /// Runs `action` whenever search asks this page to reveal one of `anchors` — for rows that
    /// hide behind local state (a popover, a segmented switch, a collapsed editor).
    func onSettingsSearchReveal(_ anchors: Set<String>, perform action: @escaping (String) -> Void) -> some View {
        modifier(SettingsSearchRevealAction(anchors: anchors, action: action))
    }
}

private struct SettingsSearchRevealAction: ViewModifier {
    let anchors: Set<String>
    let action: (String) -> Void
    @Environment(SettingsSearchNavigator.self) private var navigator: SettingsSearchNavigator?

    func body(content: Content) -> some View {
        content.task(id: navigator?.revealToken) {
            guard let anchor = navigator?.pendingAnchor, anchors.contains(anchor) else { return }
            action(anchor)
        }
    }
}

// MARK: - Sidebar search field

struct SettingsSearchField: View {
    @Binding var query: String
    /// Bump to move keyboard focus into the field (⌘F).
    let focusRequest: Int
    let onMove: (Int) -> Void
    let onSubmit: () -> Void
    @State private var isEditing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(isEditing ? Mono.primaryText : Mono.secondaryText)
                .font(.system(size: 11, weight: .medium))
                .accessibilityHidden(true)
            SettingsSearchTextField(
                text: $query,
                isEditing: $isEditing,
                focusRequest: focusRequest,
                onMove: onMove,
                onSubmit: onSubmit
            )
            if !query.isEmpty {
                Button("Clear search", systemImage: "xmark.circle.fill") { query = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(MonoPlainButtonStyle(scales: true))
                    .font(Typo.secondary)
                    .foregroundStyle(Mono.secondaryText)
                    .help("Clear search")
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Metrics.controlHeight)
        .background(shape.fill(Mono.fieldFill))
        .overlay(
            // Focus shown in ink, not the system's blue focus ring.
            shape.strokeBorder(isEditing ? Mono.ink(0.35) : Mono.cardBorder, lineWidth: isEditing ? 1 : 0.5)
        )
        .monoAnimation(Motion.hover, value: isEditing)
        .monoAnimation(Motion.swap, value: query.isEmpty)
    }
}

/// A plain AppKit text field, because the keys that drive the results must reach us while
/// typing. SwiftUI's `TextField` hands ↑/↓/Esc to its field editor first, which moves the
/// caret or does nothing; `doCommandBy` sees every one of those commands reliably.
private struct SettingsSearchTextField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isEditing: Bool
    let focusRequest: Int
    let onMove: (Int) -> Void
    let onSubmit: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.textColor = .labelColor
        field.placeholderString = String(localized: "Search settings",
                                         comment: "Placeholder of the search field in the settings sidebar")
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = context.coordinator
        field.setAccessibilityLabel(String(localized: "Search settings",
                                           comment: "Placeholder of the search field in the settings sidebar"))
        field.setAccessibilityHelp(String(
            localized: "Type a word such as microphone or lingua. Use the arrow keys and Return to open a result.",
            comment: "VoiceOver help for the settings search field. Give example words in the display language and English."
        ))
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            // Next runloop turn: the window may still be applying this update.
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SettingsSearchTextField
        var lastFocusRequest: Int

        init(parent: SettingsSearchTextField) {
            self.parent = parent
            lastFocusRequest = parent.focusRequest
        }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidBeginEditing(_ note: Notification) { parent.isEditing = true }
        func controlTextDidEndEditing(_ note: Notification) { parent.isEditing = false }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveDown(_:)):
                parent.onMove(1)
            case #selector(NSResponder.moveUp(_:)):
                parent.onMove(-1)
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
            case #selector(NSResponder.cancelOperation(_:)):
                // First Esc clears, second leaves the field, like Finder and Mail.
                if parent.text.isEmpty {
                    control.window?.makeFirstResponder(nil)
                } else {
                    parent.text = ""
                    control.stringValue = ""
                }
            default:
                return false
            }
            return true
        }
    }
}

// MARK: - Results list

struct SettingsSearchResultsList: View {
    let query: String
    let results: [SettingsSearchResult]
    let highlightedIndex: Int
    let onChoose: (Int) -> Void
    /// One ink pill shared by every row, so moving through results with ↑/↓ slides it instead
    /// of blinking it from row to row — the same gesture as the section list's selection.
    @Namespace private var selectionNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            if results.isEmpty {
                SettingsSearchNoResults(query: query)
                    .transition(.monoReveal(reduceMotion: reduceMotion))
            } else {
                list
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .monoAnimation(Motion.swap, value: results.isEmpty)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    // One key with plural variants in the catalog ("1 result" / "%lld results"), so
                    // languages with several plural forms get each of them right.
                    SettingsSectionLabel(Text("\(results.count) results",
                                              comment: "Number of settings search results, above the list"))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .padding(.horizontal, 18)
                        .padding(.bottom, 4)
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                            Button { onChoose(index) } label: {
                                SettingsSearchResultRow(
                                    entry: result.entry,
                                    query: query,
                                    isSelected: index == highlightedIndex,
                                    selectionNamespace: selectionNamespace
                                )
                            }
                            .buttonStyle(MonoPlainButtonStyle(scales: true, pressedScale: 0.985))
                            .id(result.id)
                            .accessibilityLabel("\(result.entry.title), \(result.entry.breadcrumb)")
                            .accessibilityAddTraits(index == highlightedIndex ? .isSelected : [])
                            .transition(.opacity)
                        }
                    }
                }
                .padding(.vertical, 6)
                // Typing re-ranks the list: rows that stay glide to their new place, new ones
                // fade in. No travel on insert — it would jitter on every keystroke.
                .monoAnimation(Motion.swap, value: results.map(\.id))
                .monoAnimation(Motion.select, value: highlightedIndex)
            }
            .scrollIndicators(.automatic)
            .onChange(of: highlightedIndex) { _, index in
                guard results.indices.contains(index) else { return }
                proxy.scrollTo(results[index].id)
            }
        }
    }
}

/// What the sidebar shows when nothing matches: the query echoed back, so a typo is visible,
/// and a hint about what works.
private struct SettingsSearchNoResults: View {
    let query: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: .regular))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(Mono.tertiaryText)
                .padding(.bottom, 4)
                .accessibilityHidden(true)
            Text("No results for \u{201C}\(query.trimmingCharacters(in: .whitespaces))\u{201D}")
                .font(Typo.cardTitle)
                .foregroundStyle(Mono.primaryText)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Text("Try another word, in English or Italian.",
                 comment: "Settings search with no results. Name the display language and English, e.g. 'in German or English'.")
                .font(Typo.secondary)
                .foregroundStyle(Mono.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
        .padding(.top, 28)
        .accessibilityElement(children: .combine)
    }
}

struct SettingsSearchResultRow: View {
    let entry: SettingsSearchEntry
    let query: String
    let isSelected: Bool
    /// Shared with the other rows so the selection pill moves between them.
    var selectionNamespace: Namespace.ID? = nil
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: entry.section.systemImage)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 11))
                .frame(width: 16)
                .padding(.top, 2)
                .foregroundStyle(isSelected ? Mono.selectionText : Mono.secondaryText)
            VStack(alignment: .leading, spacing: 1) {
                Text(emphasisedTitle)
                    .lineLimit(2)
                    .foregroundStyle(isSelected ? Mono.selectionText : Mono.primaryText)
                if !entry.isSection {
                    Text(entry.breadcrumb)
                        .font(Typo.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(isSelected ? Mono.selectionText.opacity(0.75) : Mono.secondaryText)
                }
            }
            Spacer(minLength: 0)
            // Says what Return will do, only on the row it will do it to.
            Image(systemName: "return")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Mono.selectionText.opacity(0.7))
                .padding(.top, 4)
                .opacity(isSelected ? 1 : 0)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
        .background { background }
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .monoAnimation(Motion.hover, value: isHovered)
    }

    @ViewBuilder
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.controlRadius + 1, style: .continuous)
        if isSelected {
            if let selectionNamespace {
                shape.fill(Mono.selection)
                    .matchedGeometryEffect(id: "settings.search.selection", in: selectionNamespace)
            } else {
                shape.fill(Mono.selection)
            }
        } else {
            shape.fill(isHovered ? Mono.hover : Color.clear)
        }
    }

    /// Matched word starts in semibold, the rest regular — emphasis by weight, never colour.
    private var emphasisedTitle: AttributedString {
        let title = entry.title
        var result = AttributedString()
        var cursor = title.startIndex
        for range in SettingsSearchText.emphasisRanges(in: title, query: query) {
            if cursor < range.lowerBound {
                var plain = AttributedString(title[cursor..<range.lowerBound])
                plain.font = Typo.body
                result += plain
            }
            var bold = AttributedString(title[range])
            bold.font = Typo.body.weight(.semibold)
            result += bold
            cursor = range.upperBound
        }
        if cursor < title.endIndex {
            var plain = AttributedString(title[cursor...])
            plain.font = Typo.body
            result += plain
        }
        return result
    }
}
