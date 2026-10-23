import Foundation
import Testing

struct DashboardTimelineTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        calendar.firstWeekday = 2
        return calendar
    }

    @Test("Dashboard ranges are ordered and labelled for the chart")
    func rangeLabels() {
        #expect(StatsRange.allCases == [.today, .week, .month, .quarter, .all])
        #expect(StatsRange.allCases.map(\.label) == ["24h", "7 days", "30 days", "3 months", "All"])
    }

    @Test("Rolling ranges start at the intended boundary")
    func rangeBoundaries() throws {
        let now = try date(2026, 9, 20, 18, 30)
        let previousDay = try date(2026, 9, 19, 18, 30)
        let sevenDays = try date(2026, 9, 14)
        let thirtyDays = try date(2026, 8, 22)
        let threeMonths = try date(2026, 6, 20)

        #expect(StatsRange.today.lowerBound(now: now, calendar: calendar) == previousDay)
        #expect(StatsRange.week.lowerBound(now: now, calendar: calendar) == sevenDays)
        #expect(StatsRange.month.lowerBound(now: now, calendar: calendar) == thirtyDays)
        #expect(StatsRange.quarter.lowerBound(now: now, calendar: calendar) == threeMonths)
        #expect(StatsRange.all.lowerBound(now: now, calendar: calendar) == nil)
    }

    @Test("The last 24 hours are split into hourly bands")
    func hourlyBands() throws {
        let now = try date(2026, 9, 20, 18, 30)
        let entries = [
            entry(at: try date(2026, 9, 20, 17, 15), words: 3),
            entry(at: try date(2026, 9, 20, 17, 45), words: 5),
            entry(at: try date(2026, 9, 20, 16), words: 2),
            entry(at: try date(2026, 9, 19, 18), words: 100),
            entry(at: try date(2026, 9, 20, 15), words: 100, tag: "failed"),
            entry(at: try date(2026, 9, 20, 19), words: 100),
        ]

        let buckets = DashboardTimeline.buckets(
            from: entries, range: .today, now: now, calendar: calendar
        )
        let firstHour = try date(2026, 9, 19, 18)
        let lastHour = try date(2026, 9, 20, 18)
        let fivePM = try date(2026, 9, 20, 17)
        let fourPM = try date(2026, 9, 20, 16)

        #expect(buckets.first?.start == firstHour)
        #expect(buckets.last?.start == lastHour)
        #expect(buckets.count == 25)
        #expect(buckets.reduce(0) { $0 + $1.words } == 10)
        #expect(buckets.first { $0.start == fivePM }?.words == 8)
        #expect(buckets.first { $0.start == fourPM }?.words == 2)
    }

    @Test("Finite ranges retain empty bands and use the requested granularity", arguments: [
        (StatsRange.week, Calendar.Component.day, 7),
        (StatsRange.month, Calendar.Component.day, 30),
    ])
    func finiteDailyBands(range: StatsRange, component: Calendar.Component, count: Int) throws {
        let now = try date(2026, 9, 20, 18, 30)
        let buckets = DashboardTimeline.buckets(
            from: [entry(at: now, words: 9)], range: range, now: now, calendar: calendar
        )

        #expect(range.bucketComponent == component)
        #expect(buckets.count == count)
        #expect(buckets.filter { $0.words == 0 }.count == count - 1)
        #expect(buckets.last?.words == 9)
    }

    @Test("Three months use weekly bands and all time uses monthly bands")
    func longerRangeBands() throws {
        let now = try date(2026, 9, 20, 18, 30)
        let old = entry(at: try date(2025, 12, 12, 9), words: 4)
        let recent = entry(at: try date(2026, 9, 20, 8), words: 6)

        let quarter = DashboardTimeline.buckets(
            from: [old, recent], range: .quarter, now: now, calendar: calendar
        )
        let all = DashboardTimeline.buckets(
            from: [old, recent], range: .all, now: now, calendar: calendar
        )
        let firstMonth = try date(2025, 12, 1)
        let lastMonth = try date(2026, 9, 1)

        #expect(StatsRange.quarter.bucketComponent == .weekOfYear)
        #expect(quarter.reduce(0) { $0 + $1.words } == 6)
        #expect(quarter.count >= 13)
        #expect(quarter.count <= 15)

        #expect(StatsRange.all.bucketComponent == .month)
        #expect(all.first?.start == firstMonth)
        #expect(all.last?.start == lastMonth)
        #expect(all.count == 10)
        #expect(all.reduce(0) { $0 + $1.words } == 10)
    }

    @Test("Dashboard totals and chart bands share the selected range")
    func metricsUseSelectedRange() throws {
        let now = try date(2026, 9, 20, 18, 30)
        let entries = [
            entry(at: try date(2026, 9, 20, 8), words: 10),
            entry(at: try date(2026, 8, 1, 8), words: 50),
            entry(at: try date(2026, 9, 21, 8), words: 100),
        ]

        let month = Stats.metrics(
            from: entries,
            range: .month,
            typingWPM: 60,
            now: now,
            calendar: calendar
        )
        let all = Stats.metrics(
            from: entries,
            range: .all,
            typingWPM: 60,
            now: now,
            calendar: calendar
        )

        #expect(month.wordsDictated == 10)
        #expect(month.sessions == 1)
        #expect(month.chartBuckets.reduce(0) { $0 + $1.words } == 10)
        #expect(all.wordsDictated == 60)
        #expect(all.sessions == 2)
        #expect(all.chartBuckets.reduce(0) { $0 + $1.words } == 60)
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int = 0,
        _ minute: Int = 0
    ) throws -> Date {
        try #require(calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        )))
    }

    private func entry(at date: Date, words: Int, tag: String? = nil) -> HistoryEntry {
        HistoryEntry(
            date: date,
            text: "sample",
            durationSeconds: 1,
            wordCount: words,
            latencyMs: 10,
            tag: tag
        )
    }
}
