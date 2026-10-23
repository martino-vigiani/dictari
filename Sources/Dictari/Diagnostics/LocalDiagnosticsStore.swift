// LocalDiagnosticsStore.swift
// Dictari — bounded, local-only storage for Apple and app lifecycle diagnostics.
//
// The archive deliberately has no generic log-message API. MetricKit JSON is accepted as an
// opaque Apple payload; app activity uses a closed, typed schema with no text-bearing field.
// Both are size-bounded and kept on this Mac until the user explicitly exports them. This makes
// it impossible for a future call site to casually add transcript text, clipboard contents or
// focused-window metadata to the diagnostic stream.

import Foundation

enum LocalDiagnosticPayloadKind: String, Codable, Sendable {
    case metrics
    case diagnostics
    case operational
}

/// A privacy-safe snapshot of the state needed to diagnose the app without recording what the
/// person dictated or which app/field they were using.
struct LocalDiagnosticsSnapshot: Codable, Equatable, Sendable {
    let distributionChannel: String
    let appVersion: String
    let buildNumber: String
    let automaticInsertionSupported: Bool
    let automaticInsertionEnabled: Bool
    let accessibilityGranted: Bool
    let microphoneGranted: Bool
    let hotkeyArmed: Bool
    let modelState: String
    let modelIdentifier: String
    let injectionMethod: String
    let realtimeTranscriptionEnabled: Bool
}

enum LocalOperationalDiagnosticState: String, Codable, Sendable {
    case servicesStarted
    case idle
    case listening
    case transcribing
    case inserted
    case pastedUnverified
    case submitFailed
    case copiedToClipboard
    case error
    case cancelled
}

/// One typed state transition. There is intentionally no arbitrary message, transcript, bundle
/// identifier or clipboard field on this value.
struct LocalOperationalDiagnosticEvent: Codable, Equatable, Sendable {
    let recordedAt: Date
    let state: LocalOperationalDiagnosticState
    let snapshot: LocalDiagnosticsSnapshot
}

struct LocalDiagnosticsSummary: Equatable, Sendable {
    let payloadCount: Int
    let operationalEventCount: Int
    let newestPayloadDate: Date?
    let newestOperationalEventDate: Date?
}

actor LocalDiagnosticsStore {
    static let defaultMaximumPayloadBytes = 2 * 1_024 * 1_024
    static let defaultMaximumStoredPayloads = 20
    static let defaultMaximumStoredOperationalEvents = 200
    static let defaultMaximumOperationalLogBytes = 512 * 1_024

    /// Operational events are one JSON object per line in an append-only log. A state change used
    /// to write its own file and then list + sort the whole directory to prune; an append is one
    /// `stat` and one write. When the active log would exceed its byte budget it replaces the
    /// single rotated generation, so disk use is bounded to two logs.
    static let operationalLogName = "operational.ndjson"
    static let rotatedOperationalLogName = "operational.1.ndjson"

    private let directoryURL: URL
    private let maximumPayloadBytes: Int
    private let maximumStoredPayloads: Int
    private let maximumStoredOperationalEvents: Int
    private let maximumOperationalLogBytes: Int
    private let fileManager: FileManager
    /// Per-event files from earlier builds are removed on first use in each process. They are
    /// diagnostics only, so migrating them into the log would buy nothing.
    private var removedLegacyOperationalFiles = false

    init(
        directoryURL: URL = AppPaths.support.appendingPathComponent("Diagnostics", isDirectory: true),
        maximumPayloadBytes: Int = LocalDiagnosticsStore.defaultMaximumPayloadBytes,
        maximumStoredPayloads: Int = LocalDiagnosticsStore.defaultMaximumStoredPayloads,
        maximumStoredOperationalEvents: Int = LocalDiagnosticsStore.defaultMaximumStoredOperationalEvents,
        maximumOperationalLogBytes: Int = LocalDiagnosticsStore.defaultMaximumOperationalLogBytes,
        fileManager: FileManager = .default
    ) {
        self.directoryURL = directoryURL
        self.maximumPayloadBytes = maximumPayloadBytes
        self.maximumStoredPayloads = maximumStoredPayloads
        self.maximumStoredOperationalEvents = maximumStoredOperationalEvents
        self.maximumOperationalLogBytes = maximumOperationalLogBytes
        self.fileManager = fileManager
    }

    /// Stores only a complete, bounded JSON value produced by MetricKit. Invalid or unexpectedly
    /// large payloads are discarded instead of turning diagnostics into an unbounded data sink.
    @discardableResult
    func store(_ data: Data, kind: LocalDiagnosticPayloadKind, receivedAt: Date = Date()) throws -> Bool {
        guard !data.isEmpty, data.count <= maximumPayloadBytes,
              (try? JSONSerialization.jsonObject(with: data)) != nil else { return false }

        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        if kind == .operational {
            try appendOperationalLine(data)
            return true
        }
        let timestamp = formattedTimestamp(receivedAt, includingFractionalSeconds: true)
        let filename = "\(timestamp)-\(kind.rawValue)-\(UUID().uuidString).json"
        try data.write(to: directoryURL.appendingPathComponent(filename), options: .atomic)
        try pruneIfNeeded(afterStoring: kind)
        return true
    }

    @discardableResult
    func record(_ event: LocalOperationalDiagnosticEvent) throws -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try store(
            encoder.encode(event),
            kind: .operational,
            receivedAt: event.recordedAt
        )
    }

    func summary() throws -> LocalDiagnosticsSummary {
        let payloads = try payloadFiles()
        let events = try operationalEventObjects()
        let newestEventDate = events.last
            .flatMap { $0["recordedAt"] as? String }
            .flatMap { ISO8601DateFormatter().date(from: $0) }
        return LocalDiagnosticsSummary(
            payloadCount: payloads.count,
            operationalEventCount: events.count,
            newestPayloadDate: payloads.map(\.modifiedAt).max(),
            newestOperationalEventDate: newestEventDate
        )
    }

    /// Produces one support-friendly JSON document. Export is the only path out of the local
    /// archive and is initiated by an explicit NSSavePanel action in Settings.
    func exportData(
        appVersion: String? = nil,
        buildNumber: String? = nil,
        operatingSystem: String = ProcessInfo.processInfo.operatingSystemVersionString,
        generatedAt: Date = Date(),
        snapshot: LocalDiagnosticsSnapshot? = nil
    ) throws -> Data {
        let files = try payloadFiles()
        let payloads: [[String: Any]] = files.compactMap { file in
            guard let data = try? Data(contentsOf: file.url),
                  let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
            return [
                "kind": file.kind.rawValue,
                "receivedAt": formattedTimestamp(file.modifiedAt),
                "payload": object,
            ]
        }
        let operationalEvents: [Any] = try operationalEventObjects()

        var document: [String: Any] = [
            "schemaVersion": 2,
            "generatedAt": formattedTimestamp(generatedAt),
            "app": [
                "version": appVersion ?? currentAppVersion,
                "build": buildNumber ?? currentBuildNumber,
                "operatingSystem": operatingSystem,
            ],
            "privacy": [
                "storedLocally": true,
                "automaticUpload": false,
                "containsAudio": false,
                "containsTranscripts": false,
                "containsClipboard": false,
                "containsFocusedAppMetadata": false,
            ],
            "operationalEvents": operationalEvents,
            "metricKitPayloads": payloads,
        ]
        if let snapshot {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(snapshot)
            document["runtimeSnapshot"] = try JSONSerialization.jsonObject(with: data)
        }
        return try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: - Retention

    private struct PayloadFile {
        let url: URL
        let kind: LocalDiagnosticPayloadKind
        let modifiedAt: Date
    }

    /// MetricKit payload files only; operational events live in the NDJSON logs.
    private func payloadFiles() throws -> [PayloadFile] {
        removeLegacyOperationalFilesIfNeeded()
        guard fileManager.fileExists(atPath: directoryURL.path) else { return [] }
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        return try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ).compactMap { url in
            guard url.pathExtension == "json",
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { return nil }
            let kind: LocalDiagnosticPayloadKind
            if url.lastPathComponent.contains("-diagnostics-") {
                kind = .diagnostics
            } else if url.lastPathComponent.contains("-metrics-") {
                kind = .metrics
            } else {
                return nil
            }
            return PayloadFile(
                url: url,
                kind: kind,
                modifiedAt: values.contentModificationDate ?? .distantPast
            )
        }.sorted {
            if $0.modifiedAt == $1.modifiedAt {
                return $0.url.lastPathComponent < $1.url.lastPathComponent
            }
            return $0.modifiedAt < $1.modifiedAt
        }
    }

    /// Only MetricKit payloads reach here (they arrive about once a day), so a directory scan is
    /// fine; operational events are bounded by log rotation instead.
    private func pruneIfNeeded(afterStoring kind: LocalDiagnosticPayloadKind) throws {
        let candidates = try payloadFiles()
        let overflow = max(0, candidates.count - maximumStoredPayloads)
        for file in candidates.prefix(overflow) {
            try fileManager.removeItem(at: file.url)
        }
    }

    // MARK: - Operational log

    private var operationalLogURL: URL { directoryURL.appendingPathComponent(Self.operationalLogName) }
    private var rotatedOperationalLogURL: URL { directoryURL.appendingPathComponent(Self.rotatedOperationalLogName) }

    /// Appends one event as a single line. The encoder output is already compact, but anything
    /// containing a newline is re-serialized so one event can never span two lines.
    private func appendOperationalLine(_ data: Data) throws {
        removeLegacyOperationalFilesIfNeeded()
        var line = data
        if line.contains(0x0A) {
            let object = try JSONSerialization.jsonObject(with: data)
            line = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
        line.append(0x0A)

        let currentSize = (try? fileManager.attributesOfItem(atPath: operationalLogURL.path))?[.size] as? Int
        if let currentSize, currentSize > 0, currentSize + line.count > maximumOperationalLogBytes {
            if fileManager.fileExists(atPath: rotatedOperationalLogURL.path) {
                try fileManager.removeItem(at: rotatedOperationalLogURL)
            }
            try fileManager.moveItem(at: operationalLogURL, to: rotatedOperationalLogURL)
        }

        guard fileManager.fileExists(atPath: operationalLogURL.path) else {
            try line.write(to: operationalLogURL, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: operationalLogURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    /// Oldest-first events from the rotated then active log, capped to the newest
    /// `maximumStoredOperationalEvents`. A torn line from a crash mid-append is skipped, not fatal.
    private func operationalEventObjects() throws -> [[String: Any]] {
        removeLegacyOperationalFilesIfNeeded()
        var events: [[String: Any]] = []
        for url in [rotatedOperationalLogURL, operationalLogURL] {
            guard let data = try? Data(contentsOf: url) else { continue }
            for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
                else { continue }
                events.append(object)
            }
        }
        return Array(events.suffix(maximumStoredOperationalEvents))
    }

    /// Earlier builds wrote `<timestamp>-operational-<uuid>.json` per state change (~200 files).
    /// They are diagnostics only, so they are deleted once per process rather than migrated.
    private func removeLegacyOperationalFilesIfNeeded() {
        guard !removedLegacyOperationalFiles else { return }
        removedLegacyOperationalFiles = true
        guard let items = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for url in items where url.pathExtension == "json"
            && url.lastPathComponent.contains("-operational-") {
            try? fileManager.removeItem(at: url)
        }
    }

    private func formattedTimestamp(
        _ date: Date,
        includingFractionalSeconds: Bool = false
    ) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = includingFractionalSeconds
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private var currentAppVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    private var currentBuildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    }
}
