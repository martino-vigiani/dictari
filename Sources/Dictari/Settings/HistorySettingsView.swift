// HistorySettingsView.swift
// Dictari — Transcription history list with search, actions, and retention settings.

import AppKit
import SwiftUI

struct HistorySettingsView: View {
    @Environment(AppCoordinator.self) private var app
    @State private var searchQuery = ""
    @State private var showClearConfirmation = false
    @State private var searchResults: [HistoryEntry] = []
    @State private var completedSearch: HistorySearchKey?
    @State private var readingEntry: HistoryEntry?
    @State private var writingEntry: HistoryEntry?
    @State private var correctingEntry: HistoryEntry?
    @State private var storageExpanded = false
    /// Memo for `HistoryTimeline.merge`, which normalises every transcript. Not observed:
    /// reading or refilling it never invalidates the view. Shared rather than `@State`:
    /// each settings page is rebuilt on every visit, and a per-view memo was thrown away
    /// with it, so every return to History paid the full merge (~30 ms) mid-transition.
    private var timelineCache: HistoryTimelineCache { .shared }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct HistorySearchKey: Equatable {
        var query: String
        var revision: UInt
    }

    private var searchKey: HistorySearchKey {
        HistorySearchKey(query: normalizedQuery, revision: app.history.contentRevision)
    }

    private var isSearching: Bool {
        !normalizedQuery.isEmpty && completedSearch != searchKey
    }

    private var normalizedQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredEntries: [HistoryEntry] {
        normalizedQuery.isEmpty ? app.history.entries : (completedSearch == searchKey ? searchResults : [])
    }

    private var filteredRecoveries: [DictationRecovery] {
        guard !normalizedQuery.isEmpty else { return app.recoveries }
        return app.recoveries.filter { recovery in
            [recovery.transcript, recovery.appName, recovery.failureDescription, recovery.displayFailureDescription]
                .compactMap { $0 }
                .contains { $0.localizedStandardContains(normalizedQuery) }
        }
    }

    /// Reads through `effectiveRetention` so a legacy day-based choice shows as itself rather
    /// than snapping back to "Forever" the first time this screen is opened.
    private var retentionBinding: Binding<HistoryRetention> {
        Binding(
            get: { app.settings.data.effectiveRetention },
            set: { app.settings.data.historyRetentionMinutes = $0.minutes }
        )
    }

    /// Which of the three mutually exclusive states fills the list area. Only this flips the
    /// cross-fade: the table itself updates in place as rows change.
    private enum ListPhase: Equatable { case searching, empty, list }

    var body: some View {
        @Bindable var settings = app.settings
        // Filter once per body eval (used by both the empty check and the list).
        let entries = filteredEntries
        let recoveries = filteredRecoveries
        // Memoised: this body also re-runs for every search keystroke, sheet, popover and
        // settings change, and re-merging thousands of entries each time cost frames.
        let timeline = timelineCache.timeline(history: entries, recoveries: recoveries)
        let phase: ListPhase = isSearching ? .searching : (timeline.isEmpty ? .empty : .list)
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("History")
                    .font(Typo.screenTitle)
                    .foregroundStyle(Mono.primaryText)
                    .accessibilityAddTraits(.isHeader)
                Text("Everything you’ve dictated, kept on this Mac.")
                    .font(Typo.pageSubtitle)
                    .foregroundStyle(Mono.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 4)
            .padding(.bottom, 4)

            searchField
                .settingsSearchAnchor("history.search")

            if let warning = app.recoveryLoadWarning {
                SettingsNotice(warning, systemImage: "exclamationmark.triangle")
                    .transition(.monoReveal(reduceMotion: reduceMotion))
            }

            // List or empty state, cross-faded in one slot so the footer never jumps.
            ZStack {
                switch phase {
                case .searching:
                    historySurface {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Searching history…")
                                .font(Typo.secondary)
                                .foregroundStyle(Mono.secondaryText)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .transition(.opacity)
                case .empty:
                    historySurface {
                        HistoryEmptyStateView(query: normalizedQuery)
                            .frame(maxHeight: .infinity)
                    }
                    .transition(.opacity)
                case .list:
                    HistoryTableView(
                        items: timeline,
                        historyRevision: app.history.contentRevision,
                        recoveryRevision: app.recoveryContentRevision,
                        query: normalizedQuery,
                        onRead: { readingEntry = $0 },
                        onRevise: { writingEntry = $0 },
                        onCorrect: { correctingEntry = $0 },
                        onRetryRecovery: { app.retryRecovery($0) },
                        onDelete: { item in
                            if let entry = item.history { app.history.delete(entry) }
                            if let recovery = item.recovery { app.deleteRecovery(recovery) }
                        }
                    )
                    .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
                    // The shadow belongs to a shape behind the table, never to the scrolling
                    // native view itself: shadowing that would re-render it on every scroll.
                    .background(
                        RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                            .fill(Mono.card)
                            .shadow(color: Mono.cardShadow, radius: 4, x: 0, y: 1)
                    )
                    .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                        .strokeBorder(Mono.cardBorder, lineWidth: 0.5))
                    .transition(.opacity)
                }
            }
            .frame(minHeight: 80, maxHeight: .infinity)
            // Keyed on "empty or not" only: every keystroke passes through `.searching` for
            // ~200 ms, and fading the list out and back on each one would flicker.
            .monoAnimation(Motion.swap, value: phase == .empty)

            // Count on the left, storage on the right: one quiet footer line.
            HStack(alignment: .center, spacing: 12) {
                Text(countLabel(timeline.count))
                    .font(Typo.secondary).monospacedDigit()
                    .foregroundStyle(Mono.secondaryText)
                    .contentTransition(.numericText())
                    .monoAnimation(Motion.snap, value: timeline.count)
                Spacer(minLength: 12)
                storageButton(settings: settings)
            }
            .padding(.horizontal, 4)

            // Privacy footer
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "lock.shield")
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(Mono.tertiaryText)
                    .imageScale(.small)
                    .accessibilityHidden(true)
                Text((app.settings.data.mcpEnabled ?? false)
                     ? "AI agents can read only enabled categories."
                     : "AI agent access is off.")
                    .font(Typo.secondary)
                    .foregroundStyle(Mono.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 4)
        }
        .monoAnimation(Motion.reveal, value: app.recoveryLoadWarning)
        .padding(.horizontal, Metrics.pageGutter)
        .padding(.vertical, 26)
        // Fills the detail column exactly, like the fixed frame a GeometryReader used to
        // supply, without the reader's extra layout pass and whole-page re-evaluation on
        // every size change (window resize, sidebar drag).
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Mono.windowBackground)
        .sheet(item: $readingEntry) { HistoryTranscriptSheet(entry: $0) }
        .sheet(item: $writingEntry) { WritingSheet(text: $0.displayText) }
        .sheet(item: $correctingEntry) { entry in
            HistoryCorrectionSheet(entry: entry, history: app.history, vocabulary: app.vocabulary)
        }
        .task(id: searchKey) {
            let key = searchKey
            guard !key.query.isEmpty else {
                searchResults = []
                completedSearch = key
                return
            }
            // Debounce typing, then scan an immutable snapshot away from the UI actor.
            // Cancellation and the key fence prevent an older query from replacing new results.
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            let snapshot = app.history.entries
            let worker = Task.detached(priority: .userInitiated) { () -> [HistoryEntry] in
                HistorySearch.matches(in: snapshot, query: key.query)
            }
            let matches = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, key == searchKey else { return }
            searchResults = matches
            completedSearch = key
        }
    }

    // MARK: - Pieces

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(Mono.secondaryText)
                .accessibilityHidden(true)
            TextField("Search history…", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(Typo.body)
                .foregroundStyle(Mono.primaryText)
            if !searchQuery.isEmpty {
                Button(String(localized: "Clear", comment: "Clears the history search field"),
                       systemImage: "xmark.circle.fill") { searchQuery = "" }
                    .buttonStyle(MonoPlainButtonStyle(scales: true))
                    .font(Typo.body)
                    .foregroundStyle(Mono.tertiaryText)
                    .labelStyle(.iconOnly)
                    .help("Clear search")
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: Metrics.controlRadius + 1, style: .continuous).fill(Mono.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.controlRadius + 1, style: .continuous)
                .strokeBorder(Mono.cardBorder, lineWidth: 0.5)
        )
        .monoAnimation(Motion.swap, value: searchQuery.isEmpty)
    }

    /// The card surface the empty and searching states sit on, matching the table's.
    private func historySurface<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                    .fill(Mono.card)
                    .shadow(color: Mono.cardShadow, radius: 4, x: 0, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                    .strokeBorder(Mono.cardBorder, lineWidth: 0.5)
            )
    }

    /// One key per noun with the count interpolated: the singular comes from the catalog's
    /// plural variations, not from a hand-written `count == 1` branch that only fits English.
    private func countLabel(_ count: Int) -> String {
        if !normalizedQuery.isEmpty {
            return String(localized: "\(count) results", comment: "History footer: number of search matches")
        }
        return String(localized: "\(count) dictations", comment: "History footer: number of saved dictations")
    }

    private func storageButton(settings: SettingsStore) -> some View {
        Button {
            storageExpanded = true
        } label: {
            Label("History storage…", systemImage: "externaldrive")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(MonoActionButtonStyle(.secondary, size: .small))
        .settingsSearchAnchor("history.storage")
        // Keep History, Recovery Audio and Clear All live in this popover. A search
        // result for any of them opens it, after the page has settled: presenting a
        // popover from a view still being inserted can anchor it to a stale frame.
        .onSettingsSearchReveal(["history.storage"]) { _ in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                storageExpanded = true
            }
        }
        .popover(isPresented: $storageExpanded, arrowEdge: .top) {
            SettingsCard(title: "History storage") {
                SettingsRow("Keep History",
                            sublabel: "Older transcriptions are deleted automatically") {
                    Picker("", selection: retentionBinding) {
                        ForEach(HistoryRetention.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }
                .onChange(of: settings.data.historyRetentionMinutes) {
                    app.history.purge(retentionMinutes: settings.data.effectiveRetention.minutes)
                }

                SettingsCardDivider()

                SettingsRow(
                    "Recovery Audio",
                    sublabel: "Saved when a dictation needs attention (~3.84 MB/min). Clear All doesn't delete it."
                ) {
                    EmptyView()
                }

                SettingsCardDivider()

                SettingsRow("Clear All Transcriptions") {
                    Button("Clear All…") {
                        showClearConfirmation = true
                    }
                    .buttonStyle(MonoActionButtonStyle(.destructive, size: .small))
                    .confirmationDialog(
                        "Clear all transcriptions?",
                        isPresented: $showClearConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Clear All", role: .destructive) {
                            app.clearTranscriptionHistory()
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Deletes dictation history and the last transcript in memory. Saved recovery audio remains.")
                    }
                }
            }
            .padding(16)
            .frame(width: 460)
            .fixedSize(horizontal: false, vertical: true)
            .background(Mono.windowBackground)
        }
    }
}

// MARK: - Entry row

/// A no-speech event is a status, not transcript content. Share its appearance with Recents.
struct NoSpeechHistoryLabel: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform.slash")
                .symbolRenderingMode(.monochrome)
                .accessibilityHidden(true)
            Text("No speech detected")
                .lineLimit(1)
        }
        .font(Typo.secondary)
        .foregroundStyle(Mono.secondaryText)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Mono.hover, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Empty state

private struct HistoryEmptyStateView: View {
    let query: String

    var body: some View {
        if query.isEmpty {
            SettingsEmptyState(
                systemImage: "clock",
                title: "No transcriptions yet",
                message: "Start dictating to see your history here."
            )
        } else {
            SettingsEmptyState(
                systemImage: "magnifyingglass",
                title: "No results",
                message: "Nothing in your history matches “\(query)”."
            )
        }
    }
}

#Preview {
    HistorySettingsView()
        .environment(AppCoordinator())
        .frame(width: 620, height: 560)
}

private struct HistoryTranscriptSheet: View {
    @Environment(\.dismiss) private var dismiss
    let entry: HistoryEntry
    private let underline = Mono.secondaryText.opacity(0.7)

    private var subtitle: String {
        var parts = [entry.date.formatted(date: .abbreviated, time: .shortened),
                     Stats.formatDuration(entry.durationSeconds)]
        if let appName = entry.appName { parts.append(appName) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        SettingsSheet("Transcription", subtitle: subtitle, width: 580, height: 440) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Spans index the original, so a shown correction stays plain.
                    Text(UncertainSpanRendering.attributed(
                        text: entry.displayText, spans: entry.displayedUncertainSpans, underline: underline
                    ))
                        .font(Typo.body).lineSpacing(3).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if entry.correctedText != nil {
                        VStack(alignment: .leading, spacing: Metrics.cardLabelGap) {
                            Rectangle().fill(Mono.cardBorder).frame(height: 0.5)
                            SettingsSectionLabel("Original transcription")
                                .padding(.top, 6)
                            Text(UncertainSpanRendering.attributed(
                                text: entry.text, spans: entry.uncertainSpans, underline: underline
                            ))
                                .font(Typo.body).lineSpacing(3).textSelection(.enabled)
                                .foregroundStyle(Mono.secondaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(Metrics.cardPadding)
            }
            .background(
                RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).fill(Mono.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                    .strokeBorder(Mono.cardBorder, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        } actions: {
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(MonoActionButtonStyle(.primary))
        }
    }
}

/// Returns the previous `HistoryTimeline.merge` result while its inputs are unchanged. Array
/// `==` short-circuits on a shared buffer, so the common case (nothing changed) is O(1); a
/// real change falls through to the same merge as before, so the output is identical.
@MainActor
private final class HistoryTimelineCache {
    static let shared = HistoryTimelineCache()

    private var history: [HistoryEntry] = []
    private var recoveries: [DictationRecovery] = []
    private var cached: [HistoryTimelineItem]?

    func timeline(history: [HistoryEntry], recoveries: [DictationRecovery]) -> [HistoryTimelineItem] {
        if let cached, history == self.history, recoveries == self.recoveries { return cached }
        let fresh = HistoryTimeline.merge(history: history, recoveries: recoveries)
        self.history = history
        self.recoveries = recoveries
        cached = fresh
        return fresh
    }
}
