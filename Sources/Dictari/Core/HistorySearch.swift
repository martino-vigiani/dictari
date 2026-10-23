import Foundation

/// Scans a value snapshot so long archives never block the main actor while typing.
enum HistorySearch {
    static func matches(in entries: [HistoryEntry], query: String) -> [HistoryEntry] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return entries }
        var matches: [HistoryEntry] = []
        for entry in entries {
            if Task.isCancelled { return [] }
            if entry.text.localizedStandardContains(query)
                || entry.correctedText?.localizedStandardContains(query) == true
                || entry.appName?.localizedStandardContains(query) == true {
                matches.append(entry)
            }
        }
        return matches
    }
}
