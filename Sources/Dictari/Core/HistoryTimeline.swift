import Foundation

/// One chronological row in History. A recovery is attached to its original history entry when
/// both records describe the same dictation; otherwise it remains a standalone row. This keeps
/// recovery visible without presenting a second archive or duplicating the same transcript.
struct HistoryTimelineItem: Identifiable, Equatable, Sendable {
    enum ID: Hashable, Sendable {
        case history(UUID)
        case recovery(UUID)
    }

    let id: ID
    let history: HistoryEntry?
    let recovery: DictationRecovery?

    var date: Date { history?.date ?? recovery?.createdAt ?? .distantPast }
}

enum HistoryTimeline {
    /// Recovery is written when recording stops; History is written after inference/delivery.
    /// Existing real records differ by at most ~5 seconds, so 10 seconds leaves scheduling room
    /// without allowing unrelated dictations to collapse together.
    static let matchTolerance: TimeInterval = 10

    static func merge(
        history: [HistoryEntry],
        recoveries: [DictationRecovery]
    ) -> [HistoryTimelineItem] {
        var historyIndexesByKey: [String: [Int]] = [:]
        for (index, entry) in history.enumerated() {
            if let key = matchKey(for: entry) {
                historyIndexesByKey[key, default: []].append(index)
            }
        }

        var recoveryByHistoryID: [UUID: DictationRecovery] = [:]
        var unmatchedRecoveries: [DictationRecovery] = []

        // Newest first makes the choice deterministic when old malformed data contains duplicate
        // metadata. Each history entry can absorb exactly one recovery.
        for recovery in recoveries.sorted(by: recoveryOrder) {
            guard let key = matchKey(for: recovery),
                  let candidateIndexes = historyIndexesByKey[key]
            else {
                unmatchedRecoveries.append(recovery)
                continue
            }

            let best = candidateIndexes
                .filter { recoveryByHistoryID[history[$0].id] == nil }
                .filter { applicationsAreCompatible(history[$0], recovery) }
                .map { index in
                    (index: index, distance: abs(history[index].date.timeIntervalSince(recovery.createdAt)))
                }
                .filter { $0.distance <= matchTolerance }
                .min { lhs, rhs in
                    if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
                    return history[lhs.index].id.uuidString < history[rhs.index].id.uuidString
                }

            guard let best else {
                unmatchedRecoveries.append(recovery)
                continue
            }
            recoveryByHistoryID[history[best.index].id] = recovery
        }

        var items = history.map { entry in
            HistoryTimelineItem(
                id: .history(entry.id),
                history: entry,
                recovery: recoveryByHistoryID[entry.id]
            )
        }
        items.append(contentsOf: unmatchedRecoveries.map { recovery in
            HistoryTimelineItem(id: .recovery(recovery.id), history: nil, recovery: recovery)
        })
        return items.sorted(by: timelineOrder)
    }

    private static func matchKey(for entry: HistoryEntry) -> String? {
        if let transcript = normalizedTranscript(entry.text) { return "text:\(transcript)" }
        guard entry.isFailure, let failure = failureKind(tag: entry.tag) else { return nil }
        return "failure:\(failure)"
    }

    private static func matchKey(for recovery: DictationRecovery) -> String? {
        if let transcript = normalizedTranscript(recovery.transcript ?? "") {
            return "text:\(transcript)"
        }
        guard recovery.state != .metadataDamaged else { return nil }
        let failure = failureKind(description: recovery.failureDescription)
            ?? (recovery.state == .transcriptionFailed ? "failed" : nil)
        guard let failure else { return nil }
        return "failure:\(failure)"
    }

    /// Whitespace differs between old insertion and recovery records (notably trailing spaces),
    /// while the spoken content is identical. Do not perform fuzzy matching: one changed word
    /// must keep the recovery standalone rather than decorating the wrong transcript.
    private static func normalizedTranscript(_ text: String) -> String? {
        let normalized = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return normalized.isEmpty ? nil : normalized
    }

    private static func failureKind(tag: String?) -> String? {
        switch tag {
        case "no speech": return "no-speech"
        case "no audio": return "no-audio"
        case "too far": return "too-far"
        case "failed", "revision failed": return "failed"
        default: return nil
        }
    }

    private static func failureKind(description: String) -> String? {
        let value = description.localizedLowercase
        if value.contains("no speech") { return "no-speech" }
        if value.contains("no audio") || value.contains("input device") { return "no-audio" }
        if value.contains("too far") || value.contains("too quiet") { return "too-far" }
        if value.contains("fail") || value.contains("timed out") { return "failed" }
        return nil
    }

    private static func applicationsAreCompatible(
        _ entry: HistoryEntry,
        _ recovery: DictationRecovery
    ) -> Bool {
        if let lhs = nonempty(entry.appBundleID), let rhs = nonempty(recovery.appBundleID) {
            return lhs == rhs
        }
        if let lhs = nonempty(entry.appName), let rhs = nonempty(recovery.appName) {
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedSame
        }
        return true
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func recoveryOrder(_ lhs: DictationRecovery, _ rhs: DictationRecovery) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func timelineOrder(_ lhs: HistoryTimelineItem, _ rhs: HistoryTimelineItem) -> Bool {
        if lhs.date != rhs.date { return lhs.date > rhs.date }
        return stableKey(lhs.id) < stableKey(rhs.id)
    }

    private static func stableKey(_ id: HistoryTimelineItem.ID) -> String {
        switch id {
        case .history(let value): return "h:\(value.uuidString)"
        case .recovery(let value): return "r:\(value.uuidString)"
        }
    }
}
