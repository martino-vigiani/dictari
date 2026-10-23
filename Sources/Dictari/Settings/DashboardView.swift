// DashboardView.swift
// Dictari — home / landing screen showing dictation stats and usage trends.
// Strictly B/W, editorial hierarchy: big page title, tracked section labels, a serif
// hero figure (the signature detail), tabular metric tiles, soft white cards.

import AVFoundation
import Charts
import SwiftUI

// MARK: - Root

struct DashboardView: View {
    @Environment(AppCoordinator.self) private var app
    @State private var selectedRange: StatsRange = .month
    @State private var metrics = DashboardMetrics()
    @State private var wpm: Double = 60

    /// `animated: false` is for the very first pass. The hero figure uses a numeric-text
    /// content transition, so seeding it after the view is on screen rolled every digit up
    /// from zero — which reads as the window hanging, not as a flourish.
    private func refresh(animated: Bool = true) {
        let fresh = Stats.metrics(
            from: app.history.entries,
            range: selectedRange,
            typingWPM: app.settings.data.assumedTypingWPM
        )
        guard animated else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { metrics = fresh }
            return
        }
        metrics = fresh
    }

    var body: some View {
        SettingsScrollPane(title: "Home",
                           subtitle: "How much Dictari has saved you, and the setup it is using.") {
            // First thing on the page when something is missing: without these the app is
            // inert, and every other number here would be a distraction.
            PermissionBanner(issues: app.permissions.issues)
                // Permissions change outside any animation (the window regaining focus), so
                // the banner's arrival and departure are animated here, where it is inserted.
                .monoAnimation(Motion.reveal, value: app.permissions.issues)
                .settingsSearchAnchor("home.permissions")

            DashboardHeroCard(metrics: metrics, wpm: $wpm)
                .settingsSearchAnchor("home.timeSaved")

            DashboardSetupCard()
                .settingsSearchAnchor("home.setup")

            DashboardSection(label: "Activity") {
                DashboardMetricsGrid(metrics: metrics)
            }
            .settingsSearchAnchor("home.activity")

            DashboardSection(label: "Words over Time") {
                DashboardUsageChart(
                    buckets: metrics.chartBuckets,
                    selectedRange: $selectedRange
                )
            }
            .settingsSearchAnchor("home.wordsOverTime")
        }
        .onAppear {
            wpm = Double(app.settings.data.assumedTypingWPM)
            refresh(animated: false)
            app.refreshPermissions()
        }
        // Permissions are granted in System Settings, so nothing in this process notices.
        // Re-read whenever the user comes back to the window.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            app.refreshPermissions()
        }
        .onChange(of: selectedRange) { refresh() }
        .onChange(of: app.settings.data.assumedTypingWPM) { refresh() }
        .onChange(of: app.history.entries.count) { refresh() }
        .onChange(of: wpm) { app.settings.data.assumedTypingWPM = Int(wpm) }
    }
}

// MARK: - Your setup

/// The three things people most often need to check or change — which microphone, which
/// key, which languages — each one click from its page. Before this card they were spread
/// over three settings pages under names like "Input Device".
private struct DashboardSetupCard: View {
    @Environment(AppCoordinator.self) private var app
    @Environment(\.openSettingsSection) private var openSection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var microphoneName: String?

    var body: some View {
        let data = app.settings.data
        SettingsCard(title: "Your setup") {
            row(String(localized: "Microphone", comment: "Home setup row"),
                value: microphoneName ?? String(localized: "System Default", comment: "Microphone choice: the Mac's default input"),
                help: String(localized: "Change Microphone", comment: "Tooltip on the Home setup row"),
                to: .sound, anchor: "sound.inputDevice")
            SettingsCardDivider()
            row(String(localized: "Shortcut", comment: "Home setup row"),
                value: Self.shortcutSummary(data.dictationShortcut.displayString, mode: data.interactionMode),
                help: String(localized: "Change Shortcut", comment: "Tooltip on the Home setup row"),
                to: .dictation, anchor: "dictation.shortcut")
            SettingsCardDivider()
            row(String(localized: "Languages", comment: "Home setup row: the languages the user speaks"),
                value: data.effectiveSpokenLanguages.map(SpokenLanguagesControl.name).joined(separator: ", "),
                help: String(localized: "Change Languages", comment: "Tooltip on the Home setup row"),
                to: .dictation, anchor: "dictation.spokenLanguages")
        }
        .monoAnimation(Motion.reveal, value: app.permissions.accessibility)
        .task(id: data.inputDeviceUID) { await resolveMicrophoneName(data.inputDeviceUID) }
    }

    /// One whole phrase per mode, so a translation can reorder it around the key glyphs
    /// (which are never translated).
    private static func shortcutSummary(_ keys: String, mode: InteractionMode) -> String {
        switch mode {
        case .toggle:
            String(localized: "\(keys) · press to start and stop",
                   comment: "Home setup row value: shortcut glyphs, then how the mode works")
        case .pushToTalk:
            String(localized: "\(keys) · hold while speaking",
                   comment: "Home setup row value: shortcut glyphs, then how the mode works")
        }
    }

    /// The whole row is the link: a hover wash and a chevron say "this opens the page", which
    /// a small "Change…" text button at the far edge never did. `title`, `value` and `help`
    /// arrive already localized.
    private func row(_ title: String, value: String, help: String,
                     to section: SettingsSection, anchor: String) -> some View {
        Button { openSection(section, anchor: anchor) } label: {
            HStack(spacing: 10) {
                Text(title)
                    .font(Typo.body)
                    .foregroundStyle(Mono.primaryText)
                    .layoutPriority(1)
                Spacer(minLength: 16)
                Text(value)
                    .font(Typo.secondary)
                    .foregroundStyle(Mono.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    // The microphone name resolves a moment after Home opens; let it settle
                    // in with a cross-fade instead of popping.
                    .contentTransition(.opacity)
                    .monoAnimation(Motion.swap, value: value)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Mono.tertiaryText)
                    .accessibilityHidden(true)
            }
            .padding(Metrics.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(DashboardLinkRowStyle())
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .accessibilityHint("Opens the page where you can change it")
        .help(help)
    }

    /// Device lookup goes off the main thread, as in the Microphone page: CoreAudio discovery
    /// can take long enough to hitch the first frame of Home.
    private func resolveMicrophoneName(_ uid: String?) async {
        let name = await Task.detached(priority: .utility) { () -> String? in
            if let uid, let device = AVCaptureDevice(uniqueID: uid) { return device.localizedName }
            guard let fallback = AVCaptureDevice.default(for: .audio)?.localizedName else { return nil }
            return String(localized: "System Default (\(fallback))",
                          comment: "Microphone choice: the Mac's default input, with the device name in brackets")
        }.value
        microphoneName = name
    }
}

/// A card row that is a button as a whole: full-bleed hover wash (the card clips the
/// corners), no press scale, since a row shrinking inside its card looks broken.
private struct DashboardLinkRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .modifier(MonoPressFeedback(
                isPressed: configuration.isPressed,
                scales: false,
                hoverBackground: Mono.hover,
                cornerRadius: 0
            ))
    }
}

// MARK: - Section wrapper

/// Same label and gap as `SettingsCard(title:)`, for blocks that are not a single card.
private struct DashboardSection<Content: View>: View {
    let label: LocalizedStringKey
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.cardLabelGap) {
            SettingsSectionLabel(label)
                .padding(.leading, 4)
            content
        }
    }
}

// MARK: - Range picker

private struct DashboardRangePicker: View {
    @Binding var selectedRange: StatsRange

    var body: some View {
        // Monochrome segmented control — the system `.segmented` style renders blue.
        MonoSegmented(
            selection: $selectedRange,
            options: StatsRange.allCases.map { ($0, $0.label) }
        )
        .accessibilityLabel("Chart time range")
        .accessibilityValue(selectedRange.accessibilityLabel)
        .accessibilityHint("Changes every dashboard metric")
    }
}

// MARK: - Hero card (signature: serif figure)

private struct DashboardHeroCard: View {
    let metrics: DashboardMetrics
    @Binding var wpm: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hasSavings: Bool { metrics.timeSavedSeconds > 0 }

    var body: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 14) {
                SettingsSectionLabel("Time Saved")

                Text(Stats.formatDuration(metrics.timeSavedSeconds))
                    .font(Typo.heroMetric)
                    .monospacedDigit()
                    .foregroundStyle(hasSavings ? Mono.primaryText : Mono.tertiaryText)
                    .contentTransition(.numericText())
                    .monoAnimation(Motion.snap, value: metrics.timeSavedSeconds)
                    .accessibilityLabel("Time saved: \(Stats.formatDuration(metrics.timeSavedSeconds))")

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Compared with typing at")
                            .font(Typo.secondary)
                            .foregroundStyle(Mono.secondaryText)
                        Spacer()
                        // Rolls digit by digit while dragging; the slider steps by 5, so it
                        // changes at most a few times a second, never per frame.
                        Text("\(Int(wpm)) WPM")
                            .font(Typo.secondary.weight(.semibold))
                            .foregroundStyle(Mono.primaryText)
                            .monospacedDigit()
                            .contentTransition(.numericText(value: wpm))
                            .monoAnimation(Motion.snap, value: wpm)
                    }
                    MonoSlider(value: $wpm, range: 20...120, step: 5)
                        .accessibilityLabel("Assumed typing speed")
                        .accessibilityValue("\(Int(wpm)) words per minute")
                }

                if !hasSavings {
                    SettingsNotice("Dictate something to start counting. Set the slider to how fast you usually type.",
                                   systemImage: "clock")
                        .transition(.monoReveal(reduceMotion: reduceMotion))
                }
            }
            .monoAnimation(Motion.reveal, value: hasSavings)
        }
    }
}

// MARK: - Metrics grid

private struct DashboardMetricsGrid: View {
    let metrics: DashboardMetrics

    private var avgSessionLabel: String {
        guard metrics.sessions > 0 else { return "—" }
        return Stats.formatDuration(metrics.speechSeconds / Double(metrics.sessions))
    }

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)],
            spacing: 14
        ) {
            DashboardMetricTile(title: "Words Dictated", value: "\(metrics.wordsDictated)")
            DashboardMetricTile(title: "Sessions", value: "\(metrics.sessions)")
            DashboardMetricTile(title: LocalizedStringResource("Avg Session", comment: "Tile title: average dictation length"),
                                value: avgSessionLabel)
            DashboardMetricTile(title: LocalizedStringResource("Avg Latency", comment: "Tile title: average time from stop to text"),
                                value: metrics.avgLatencyMs > 0
                                    ? String(localized: "\(metrics.avgLatencyMs) ms", comment: "Milliseconds, abbreviated")
                                    : "—")
            DashboardMetricTile(title: "Most Used App", value: metrics.mostUsedApp ?? "—")
            DashboardMetricTile(title: LocalizedStringResource("Streak", comment: "Tile title: consecutive days with a dictation"),
                                value: String(localized: "\(metrics.currentStreakDays)d",
                                              comment: "Streak length in days, abbreviated (e.g. 4d)"),
                                subtitle: String(localized: "Longest \(metrics.longestStreakDays)d",
                                                 comment: "Longest streak in days, abbreviated (e.g. Longest 12d)"))
        }
    }
}

private struct DashboardMetricTile: View {
    let title: LocalizedStringResource
    let value: String
    var subtitle: String? = nil

    var body: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 6) {
                // `textCase` upper-cases with the interface locale, after translation.
                Text(title)
                    .textCase(.uppercase)
                    .font(Typo.tileLabel)
                    .tracking(0.6)
                    .foregroundStyle(Mono.tertiaryText)
                    .lineLimit(1)
                // Keep every activity tile to the same two text rows. The streak's
                // secondary value shares the value baseline instead of adding height.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(value)
                        .font(Typo.metricValue)
                        .monospacedDigit()
                        .foregroundStyle(Mono.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        // Switching the range rolls the figures instead of swapping them.
                        .contentTransition(.numericText())
                        .monoAnimation(Motion.snap, value: value)
                    if let subtitle {
                        Spacer(minLength: 0)
                        Text(subtitle)
                            .font(Typo.secondary)
                            .foregroundStyle(Mono.tertiaryText)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .contentTransition(.numericText())
                            .monoAnimation(Motion.snap, value: subtitle)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let name = String(localized: title)
        if let subtitle {
            return String(localized: "\(name): \(value), \(subtitle)",
                          comment: "Accessibility: metric tile title, value, then secondary value")
        }
        return String(localized: "\(name): \(value)", comment: "Accessibility: metric tile title, then value")
    }
}

// MARK: - Usage chart

private struct DashboardUsageChart: View {
    let buckets: [DashboardChartBucket]
    @Binding var selectedRange: StatsRange
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hasWords: Bool { buckets.contains { $0.words > 0 } }

    var body: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 12) {
                DashboardRangePicker(selectedRange: $selectedRange)

                HStack {
                    Text(selectedRange.accessibilityLabel)
                    Spacer()
                    Text(selectedRange.bucketLabel)
                }
                .font(Typo.secondary)
                .foregroundStyle(Mono.tertiaryText)
                .contentTransition(.opacity)
                .monoAnimation(Motion.swap, value: selectedRange)

                // Same height either way, so switching between an empty and a full range
                // cross-fades in place instead of resizing the card.
                ZStack {
                    if hasWords {
                        DashboardBarChart(buckets: buckets, range: selectedRange)
                            .transition(.opacity)
                    } else {
                        SettingsEmptyState(
                            systemImage: "chart.bar",
                            title: "No dictations in this range",
                            message: "Pick a longer range, or dictate something and come back."
                        )
                        .padding(.vertical, -16)
                        .transition(.opacity)
                    }
                }
                .frame(minHeight: DashboardBarChart.height)
                .monoAnimation(Motion.swap, value: hasWords)
            }
        }
    }
}

private struct DashboardBarChart: View {
    let buckets: [DashboardChartBucket]
    let range: StatsRange

    static let height: CGFloat = 130

    private struct AxisScale {
        let component: Calendar.Component
        let stride: Calendar.Component
        let strideCount: Int
        let format: Date.FormatStyle

        static func forRange(_ range: StatsRange) -> AxisScale {
            switch range {
            case .today:
                AxisScale(component: .hour, stride: .hour, strideCount: 4,
                          format: .dateTime.hour())
            case .week:
                AxisScale(component: .day, stride: .day, strideCount: 1,
                          format: .dateTime.weekday(.abbreviated))
            case .month:
                AxisScale(component: .day, stride: .day, strideCount: 5,
                          format: .dateTime.day())
            case .quarter:
                AxisScale(component: .weekOfYear, stride: .weekOfYear, strideCount: 2,
                          format: .dateTime.month(.abbreviated).day())
            case .all:
                AxisScale(component: .month, stride: .month, strideCount: 1,
                          format: .dateTime.month(.abbreviated).year(.twoDigits))
            }
        }
    }

    private func accessibilityLabel(for bucket: DashboardChartBucket) -> String {
        switch range {
        case .today:
            return bucket.start.formatted(date: .omitted, time: .shortened)
        case .week, .month:
            return bucket.start.formatted(date: .abbreviated, time: .omitted)
        case .quarter:
            let end = bucket.end.addingTimeInterval(-1)
            return String(localized: "Week \(bucket.start.formatted(date: .abbreviated, time: .omitted)) to \(end.formatted(date: .abbreviated, time: .omitted))",
                          comment: "Accessibility label of a chart bar covering one week: start date to end date")
        case .all:
            return bucket.start.formatted(.dateTime.month(.wide).year())
        }
    }

    var body: some View {
        let scale = AxisScale.forRange(range)
        let now = Date()
        Chart(buckets) { entry in
            BarMark(
                x: .value("Time period", entry.start, unit: scale.component),
                y: .value("Words dictated", entry.words),
                width: .ratio(0.6)
            )
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .foregroundStyle(entry.start <= now && now < entry.end ? Mono.ink() : Mono.ink(0.28))
            .accessibilityLabel(accessibilityLabel(for: entry))
            .accessibilityValue("\(entry.words) words")
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: scale.stride, count: scale.strideCount)) { _ in
                AxisValueLabel(format: scale.format, centered: true)
                    .foregroundStyle(Mono.tertiaryText)
                    .font(Typo.secondary)
            }
        }
        .chartYAxis {
            AxisMarks { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Mono.cardBorder)
                AxisValueLabel()
                    .foregroundStyle(Mono.tertiaryText)
                    .font(Typo.secondary)
            }
        }
        .frame(height: Self.height)
        .monoAnimation(Motion.snap, value: buckets)
    }
}

// MARK: - Soft card shell

/// A padded card surface for free-form content (hero, tiles, chart). Same surface, border
/// and single shadow as `SettingsCard`, so Home sits on the same elevation as every other
/// page; the old double shadow with a compositing group also cost an off-screen pass per
/// tile.
private struct DashboardCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(Metrics.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The shadow is cast by the surface shape, not by the content: on the content it
            // would also shadow the chart and every figure, re-rendered off-screen whenever
            // they animate or the page scrolls.
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
}

// MARK: - Preview

#Preview {
    DashboardView()
        .environment(AppCoordinator())
        .frame(width: 620, height: 600)
}
