// Stores.swift
// Dictari — local-only persistence for settings, history, and derived stats.
// Everything lives in ~/Library/Application Support/Dictari/. Nothing is networked.

import Foundation
import Observation

// MARK: - Paths

enum AppPaths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Dictari", isDirectory: true)
        adoptLegacyDirectoryIfPresent(into: dir, from: base)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// The app shipped as "RobinWhisper" before being renamed. Anyone who used that build has
    /// their settings and their whole dictation history under the old folder, and a rename
    /// that silently abandons a year of transcripts is data loss with extra steps.
    ///
    /// Moved rather than copied, so there is exactly one live copy and the migration cannot
    /// run twice. Only ever runs when the new folder does not exist yet.
    private static func adoptLegacyDirectoryIfPresent(into target: URL, from base: URL) {
        let fm = FileManager.default
        let legacy = base.appendingPathComponent("RobinWhisper", isDirectory: true)
        guard fm.fileExists(atPath: legacy.path), !fm.fileExists(atPath: target.path) else { return }
        try? fm.moveItem(at: legacy, to: target)
    }
    static let settings = support.appendingPathComponent("settings.json")
    static let history = support.appendingPathComponent("history.json")
    static let recoveries = support.appendingPathComponent("Recoveries", isDirectory: true)
    static let models = support.appendingPathComponent("Models", isDirectory: true)
}

/// Preserve the original before a fallback can ever be saved over it. A failed backup
/// locks persistence for this session; missing files alone are normal first-run state.
enum ProtectedJSONLoad {
    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> (value: T?, warning: String?, blocked: Bool) {
        do {
            let data = try Data(contentsOf: url)
            do { return (try JSONDecoder().decode(type, from: data), nil, false) }
            catch {
                let backup = url.appendingPathExtension("unreadable-" + UUID().uuidString + ".backup")
                do {
                    try data.write(to: backup, options: .atomic)
                    return (nil, String(localized: "Could not read \(url.lastPathComponent). Original preserved as \(backup.lastPathComponent).",
                                        comment: "Load warning; the arguments are file names"), false)
                } catch {
                    return (nil, String(localized: "Could not preserve \(url.lastPathComponent). Saving is paused to protect the original file.",
                                        comment: "Load warning; the argument is a file name"), true)
                }
            }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return (nil, nil, false)
        } catch {
            return (nil, String(localized: "Could not read \(url.lastPathComponent). Saving is paused to protect the original file.",
                                comment: "Load warning; the argument is a file name"), true)
        }
    }
}

// MARK: - Ordered JSON persistence

struct JSONSnapshotWriterDiagnostics: Equatable, Sendable {
    let durableRevision: UInt
    let writeCount: Int
}

/// Serial disk endpoint with a revision fence. Tasks that were cancelled after they reached the
/// writer can still finish, but an older snapshot can never replace a newer durable one.
actor LatestJSONSnapshotWriter<Value: Encodable & Sendable> {
    private let fileURL: URL
    private let beforeWrite: (@Sendable () async -> Void)?
    private var durableRevision: UInt = 0
    private var writeCount = 0

    init(
        fileURL: URL,
        beforeWrite: (@Sendable () async -> Void)? = nil
    ) {
        self.fileURL = fileURL
        self.beforeWrite = beforeWrite
    }

    func persist(_ value: Value, revision: UInt) async throws {
        guard revision > durableRevision else { return }
        if let beforeWrite { await beforeWrite() }
        // The optional test barrier above makes the actor reentrant. A newer revision may have
        // committed while this call was suspended, so fence again before touching the file.
        guard revision > durableRevision else { return }
        let data = try JSONEncoder().encode(value)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
        durableRevision = revision
        writeCount += 1
    }

    func diagnostics() -> JSONSnapshotWriterDiagnostics {
        JSONSnapshotWriterDiagnostics(
            durableRevision: durableRevision,
            writeCount: writeCount
        )
    }
}

/// Main-actor submission queue that coalesces rapid UI changes, then hands encoding and disk I/O
/// to one actor. `flush()` is used during orderly termination so the debounce cannot lose the last
/// slider movement or history deletion.
@MainActor
final class DebouncedJSONPersistence<Value: Encodable & Sendable> {
    private let writer: LatestJSONSnapshotWriter<Value>
    private let delay: Duration
    private var revision: UInt = 0
    private var latestValue: Value?
    private var pendingTask: Task<Void, Never>?
    private(set) var lastError: String?

    init(
        fileURL: URL,
        delay: Duration,
        beforeWrite: (@Sendable () async -> Void)? = nil
    ) {
        self.writer = LatestJSONSnapshotWriter(fileURL: fileURL, beforeWrite: beforeWrite)
        self.delay = delay
    }

    func submit(_ value: Value) {
        revision &+= 1
        latestValue = value
        let submittedRevision = revision
        pendingTask?.cancel()
        pendingTask = Task { [writer, delay] in
            do {
                try await Task.sleep(for: delay)
                try Task.checkCancellation()
                try await writer.persist(value, revision: submittedRevision)
                guard !Task.isCancelled else { return }
                self.lastError = nil
            } catch is CancellationError {
                // A newer snapshot owns persistence now.
            } catch {
                guard !Task.isCancelled else { return }
                self.lastError = error.localizedDescription
            }
        }
    }

    func flush() async throws {
        pendingTask?.cancel()
        pendingTask = nil
        guard latestValue != nil else { return }

        do {
            // MainActor is reentrant while the writer works. Loop until the revision that reached
            // disk is still the latest one, cancelling any debounce scheduled during the await.
            while let value = latestValue {
                let targetRevision = revision
                try await writer.persist(value, revision: targetRevision)
                guard revision != targetRevision else { break }
                pendingTask?.cancel()
                pendingTask = nil
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    func diagnostics() async -> JSONSnapshotWriterDiagnostics {
        await writer.diagnostics()
    }

    var currentRevision: UInt { revision }
}

// MARK: - Settings store

/// Observable wrapper over `SettingsData`. Any mutation persists (debounced) to JSON.
@MainActor
@Observable
final class SettingsStore {
    var data: SettingsData {
        didSet { if data != oldValue { save() } }
    }
    private(set) var loadWarning: String?
    @ObservationIgnored private var savingBlocked = false
    @ObservationIgnored private var blockedMutation = false
    @ObservationIgnored private let persistence: DebouncedJSONPersistence<SettingsData>

    init(
        fileURL: URL = AppPaths.settings,
        saveDebounce: Duration = .milliseconds(180),
        beforePersistenceWrite: (@Sendable () async -> Void)? = nil
    ) {
        self.persistence = DebouncedJSONPersistence(
            fileURL: fileURL,
            delay: saveDebounce,
            beforeWrite: beforePersistenceWrite
        )
        let loaded = ProtectedJSONLoad.read(SettingsData.self, from: fileURL)
        loadWarning = loaded.warning
        savingBlocked = loaded.blocked
        if let decoded = loaded.value {
            let migrated = Self.migrate(decoded)
            self.data = migrated
            // Assignment inside `init` does not run `didSet`, so a migration would live only
            // in memory and re-run on every launch — overwriting a later explicit choice.
            // Persist it here, once, when it actually changed something.
            if migrated != decoded { save() }
        } else {
            self.data = SettingsData()
        }
    }

    /// One-shot upgrades applied to settings written by an older build.
    ///
    /// Parakeet replaced Whisper Large v3 Turbo as the default engine. A stored
    /// `activeModelID` always wins over the new default, so anyone who ran an earlier build
    /// would silently stay on Whisper — including users who never made an explicit choice.
    /// Move those forward once, and leave every other stored choice alone.
    nonisolated static func migrate(_ stored: SettingsData) -> SettingsData {
        var out = stored
        // ⌥⌘Space belongs to Finder Search. It appeared safe only while our event tap could
        // swallow every press; Secure Event Input correctly makes that impossible and exposed
        // the system action. Move the retired default to the non-system ⌥Space shortcut.
        if out.dictationShortcut == .finderSearch {
            out.dictationShortcut = .defaultDictation
        }
        if out.didMigrateToParakeetDefault != true {
            if out.activeModelID == "large-v3-turbo" {
                out.activeModelID = "parakeet-v3"
            }
            out.didMigrateToParakeetDefault = true
        }
        return out
    }

    var activeModel: ModelDescriptor { ModelDescriptor.descriptor(for: data.activeModelID) }

    private func save() {
        guard !savingBlocked else { blockedMutation = true; return }
        persistence.submit(data)
    }

    func flushPendingWrites() async throws {
        guard !blockedMutation else { throw CocoaError(.fileWriteNoPermission) }
        try await persistence.flush()
    }

    func persistenceDiagnostics() async -> JSONSnapshotWriterDiagnostics {
        await persistence.diagnostics()
    }

    var persistenceRevision: UInt { persistence.currentRevision }
}

// MARK: - History store

@MainActor
@Observable
final class HistoryStore {
    private(set) var entries: [HistoryEntry] = [] {
        didSet { contentRevision &+= 1 }
    }
    /// Cheap invalidation for derived history views; avoids comparing every transcript.
    private(set) var contentRevision: UInt = 0
    @ObservationIgnored private let fileURL: URL
    private(set) var loadWarning: String?
    @ObservationIgnored private var savingBlocked = false
    @ObservationIgnored private var blockedMutation = false
    @ObservationIgnored private let persistence: DebouncedJSONPersistence<[HistoryEntry]>

    init(
        retentionMinutes: Int = 0,
        fileURL: URL = AppPaths.history,
        saveDebounce: Duration = .milliseconds(180),
        beforePersistenceWrite: (@Sendable () async -> Void)? = nil
    ) {
        self.fileURL = fileURL
        self.persistence = DebouncedJSONPersistence(
            fileURL: fileURL,
            delay: saveDebounce,
            beforeWrite: beforePersistenceWrite
        )
        load()
        purge(retentionMinutes: retentionMinutes)
    }

    func add(_ entry: HistoryEntry) {
        entries.insert(entry, at: 0)
        save()
    }

    /// Store (or clear, with `nil`) the user's correction of an entry. A correction identical to
    /// the original transcript is no correction, so it is stored as `nil`.
    func setCorrectedText(_ corrected: String?, for id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = corrected?.trimmingCharacters(in: .whitespacesAndNewlines)
        let original = entries[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: String? = if let trimmed, !trimmed.isEmpty, trimmed != original { trimmed } else { nil }
        guard entries[index].correctedText != value else { return }
        entries[index].correctedText = value
        save()
    }

    func delete(_ entry: HistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    func purge(retentionMinutes: Int) {
        guard retentionMinutes > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(retentionMinutes) * 60)
        let before = entries.count
        entries.removeAll { $0.date < cutoff }
        if entries.count != before { save() }
    }

    func search(_ query: String) -> [HistoryEntry] {
        guard !query.isEmpty else { return entries }
        return entries.filter {
            $0.text.localizedCaseInsensitiveContains(query)
                || $0.correctedText?.localizedCaseInsensitiveContains(query) == true
        }
    }

    private func load() {
        let loaded = ProtectedJSONLoad.read([HistoryEntry].self, from: fileURL)
        loadWarning = loaded.warning
        savingBlocked = loaded.blocked
        entries = loaded.value ?? []
    }

    private func save() {
        guard !savingBlocked else { blockedMutation = true; return }
        persistence.submit(entries)
    }

    func flushPendingWrites() async throws {
        guard !blockedMutation else { throw CocoaError(.fileWriteNoPermission) }
        try await persistence.flush()
    }

    func persistenceDiagnostics() async -> JSONSnapshotWriterDiagnostics {
        await persistence.diagnostics()
    }

    var persistenceRevision: UInt { persistence.currentRevision }
}

/// Flush both user-data stores as one termination barrier. Each store already loops across its
/// own MainActor reentrancy, but Settings can still change while History is awaiting disk (or vice
/// versa). The pair of revision tokens closes that cross-store window before the app replies that
/// it is safe to quit.
@MainActor
func flushUserDataUntilStable(settings: SettingsStore, history: HistoryStore) async throws {
    while true {
        let settingsRevision = settings.persistenceRevision
        let historyRevision = history.persistenceRevision

        try await settings.flushPendingWrites()
        try await history.flushPendingWrites()

        guard settings.persistenceRevision == settingsRevision,
              history.persistenceRevision == historyRevision else { continue }
        return
    }
}

// MARK: - Derived statistics

enum StatsRange: String, CaseIterable, Identifiable, Sendable {
    case today, week, month, quarter, all
    var id: String { rawValue }

    var label: String {
        switch self {
        case .today: return String(localized: "24h", comment: "Statistics range: last 24 hours, short")
        case .week: return String(localized: "7 days", comment: "Time span: history retention or statistics range")
        case .month: return String(localized: "30 days", comment: "Time span: history retention or statistics range")
        case .quarter: return String(localized: "3 months", comment: "Statistics range")
        case .all: return String(localized: "stats.range.all", defaultValue: "All", comment: "Statistics range: all time, short")
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .today: return String(localized: "Last 24 hours", comment: "Statistics range")
        case .week: return String(localized: "Last 7 days", comment: "Statistics range")
        case .month: return String(localized: "Last 30 days", comment: "Statistics range")
        case .quarter: return String(localized: "Last 3 months", comment: "Statistics range")
        case .all: return String(localized: "All time", comment: "Statistics range")
        }
    }

    var bucketLabel: String {
        switch self {
        case .today: return String(localized: "Hourly", comment: "Chart bucket size")
        case .week, .month: return String(localized: "Daily", comment: "Chart bucket size")
        case .quarter: return String(localized: "Weekly", comment: "Chart bucket size")
        case .all: return String(localized: "Monthly", comment: "Chart bucket size")
        }
    }

    var bucketComponent: Calendar.Component {
        switch self {
        case .today: return .hour
        case .week, .month: return .day
        case .quarter: return .weekOfYear
        case .all: return .month
        }
    }

    /// Inclusive lower bound for this range (nil == no bound).
    func lowerBound(now: Date = Date(), calendar: Calendar = .current) -> Date? {
        switch self {
        case .today:
            return calendar.date(byAdding: .hour, value: -24, to: now)
        case .week:
            return calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))
        case .month:
            return calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now))
        case .quarter:
            guard let date = calendar.date(byAdding: .month, value: -3, to: now) else { return nil }
            return calendar.startOfDay(for: date)
        case .all: return nil
        }
    }
}

struct DashboardChartBucket: Identifiable, Sendable, Equatable {
    var id: Date { start }
    let start: Date
    let end: Date
    let words: Int
}

enum DashboardTimeline {
    /// Produces a complete time axis, including zero-value bands, so sparse history does not
    /// visually collapse a selected range. Entries outside the range, failures and future-dated
    /// records never contribute to a bar.
    static func buckets(
        from entries: [HistoryEntry],
        range: StatsRange,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [DashboardChartBucket] {
        let successful = entries.filter { $0.isFailure == false && $0.date <= now }
        let lowerBound = range.lowerBound(now: now, calendar: calendar)
        guard let requestedStart = lowerBound ?? successful.map(\.date).min(),
              let start = alignedStart(
                for: requestedStart,
                component: range.bucketComponent,
                calendar: calendar
              )
        else { return [] }

        let scoped = successful.filter { entry in
            lowerBound.map { entry.date >= $0 } ?? true
        }
        var totals: [Date: Int] = [:]
        for entry in scoped {
            guard let bucketStart = alignedStart(
                for: entry.date,
                component: range.bucketComponent,
                calendar: calendar
            ) else { continue }
            totals[bucketStart, default: 0] += entry.wordCount
        }

        var buckets: [DashboardChartBucket] = []
        var cursor = start
        while cursor <= now {
            guard let end = calendar.date(
                byAdding: range.bucketComponent,
                value: 1,
                to: cursor
            ), end > cursor else { break }
            buckets.append(DashboardChartBucket(
                start: cursor,
                end: end,
                words: totals[cursor, default: 0]
            ))
            cursor = end
        }
        return buckets
    }

    private static func alignedStart(
        for date: Date,
        component: Calendar.Component,
        calendar: Calendar
    ) -> Date? {
        switch component {
        case .day:
            calendar.startOfDay(for: date)
        case .hour, .weekOfYear, .month:
            calendar.dateInterval(of: component, for: date)?.start
        default:
            nil
        }
    }
}

/// Aggregated dashboard numbers. The hero metric is **time saved**, not WPM.
struct DashboardMetrics: Sendable, Equatable {
    var wordsDictated = 0
    var sessions = 0
    var speechSeconds: Double = 0
    var timeSavedSeconds: Double = 0
    var avgLatencyMs = 0
    var mostUsedApp: String?
    var currentStreakDays = 0
    var longestStreakDays = 0
    /// Complete range buckets, oldest first — including empty bands for the usage chart.
    var chartBuckets: [DashboardChartBucket] = []

    static func == (lhs: DashboardMetrics, rhs: DashboardMetrics) -> Bool {
        lhs.wordsDictated == rhs.wordsDictated && lhs.sessions == rhs.sessions &&
        lhs.speechSeconds == rhs.speechSeconds && lhs.timeSavedSeconds == rhs.timeSavedSeconds &&
        lhs.avgLatencyMs == rhs.avgLatencyMs && lhs.mostUsedApp == rhs.mostUsedApp &&
        lhs.currentStreakDays == rhs.currentStreakDays && lhs.longestStreakDays == rhs.longestStreakDays &&
        lhs.chartBuckets == rhs.chartBuckets
    }
}

enum Stats {
    /// Compute dashboard metrics for a range. `typingWPM` drives the time-saved formula:
    /// timeSaved = (words / typingWPM) * 60  −  speechSeconds.
    static func metrics(
        from entries: [HistoryEntry],
        range: StatsRange,
        typingWPM: Int,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> DashboardMetrics {
        let lower = range.lowerBound(now: now, calendar: calendar)
        let scoped = entries.filter { entry in
            entry.isFailure == false && entry.date <= now && (lower.map { entry.date >= $0 } ?? true)
        }

        var m = DashboardMetrics()
        m.sessions = scoped.count
        m.wordsDictated = scoped.reduce(0) { $0 + $1.wordCount }
        m.speechSeconds = scoped.reduce(0) { $0 + $1.durationSeconds }
        let typingSeconds = typingWPM > 0 ? Double(m.wordsDictated) / Double(typingWPM) * 60.0 : 0
        m.timeSavedSeconds = max(0, typingSeconds - m.speechSeconds)

        let latencies = scoped.map(\.latencyMs)
        m.avgLatencyMs = latencies.isEmpty ? 0 : latencies.reduce(0, +) / latencies.count

        // Most used app
        let appCounts = Dictionary(grouping: scoped.compactMap(\.appName), by: { $0 }).mapValues(\.count)
        m.mostUsedApp = appCounts.max(by: { $0.value < $1.value })?.key

        // Streaks + chart buckets
        let cal = calendar
        let days = Set(scoped.map { cal.startOfDay(for: $0.date) })
        m.longestStreakDays = longestStreak(days: days, cal: cal)
        m.currentStreakDays = currentStreak(days: days, cal: cal, now: now)

        m.chartBuckets = DashboardTimeline.buckets(
            from: entries,
            range: range,
            now: now,
            calendar: calendar
        )
        return m
    }

    private static func currentStreak(days: Set<Date>, cal: Calendar, now: Date) -> Int {
        var streak = 0
        var cursor = cal.startOfDay(for: now)
        while days.contains(cursor) {
            streak += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return streak
    }

    private static func longestStreak(days: Set<Date>, cal: Calendar) -> Int {
        guard !days.isEmpty else { return 0 }
        let sorted = days.sorted()
        var best = 1, run = 1
        for i in 1..<sorted.count {
            if let prev = cal.date(byAdding: .day, value: 1, to: sorted[i - 1]), prev == sorted[i] {
                run += 1; best = max(best, run)
            } else {
                run = 1
            }
        }
        return best
    }

    /// Format seconds as "X h Y min" / "Y min Z s" / "Z s".
    static func formatDuration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s >= 3600 {
            return String(localized: "\(s / 3600) h \((s % 3600) / 60) min", comment: "Duration: hours and minutes")
        }
        if s >= 60 { return String(localized: "\(s / 60) min \(s % 60) s", comment: "Duration: minutes and seconds") }
        return String(localized: "\(s) s", comment: "Duration: seconds")
    }
}
