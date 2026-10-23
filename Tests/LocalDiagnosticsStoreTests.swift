import Foundation
import XCTest

final class LocalDiagnosticsStoreTests: XCTestCase {
    func testRejectsInvalidAndOversizedPayloads() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalDiagnosticsStore(
            directoryURL: root,
            maximumPayloadBytes: 16,
            maximumStoredPayloads: 3
        )

        let invalid = try await store.store(Data("not-json".utf8), kind: .metrics)
        let oversized = try await store.store(Data(repeating: 0x61, count: 17), kind: .diagnostics)

        XCTAssertFalse(invalid)
        XCTAssertFalse(oversized)
        let summary = try await store.summary()
        XCTAssertEqual(summary.payloadCount, 0)
        XCTAssertEqual(summary.operationalEventCount, 0)
    }

    func testArchiveKeepsOnlyNewestBoundedPayloads() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalDiagnosticsStore(
            directoryURL: root,
            maximumPayloadBytes: 1_024,
            maximumStoredPayloads: 2
        )

        for value in 1...3 {
            let data = try JSONSerialization.data(withJSONObject: ["sequence": value])
            let stored = try await store.store(
                data,
                kind: value == 2 ? .diagnostics : .metrics,
                receivedAt: Date(timeIntervalSince1970: TimeInterval(value))
            )
            XCTAssertTrue(stored)
        }

        let summary = try await store.summary()
        XCTAssertEqual(summary.payloadCount, 2)
        XCTAssertEqual(summary.operationalEventCount, 0)

        let export = try await store.exportData(
            appVersion: "1.0",
            buildNumber: "3",
            operatingSystem: "Test OS",
            generatedAt: Date(timeIntervalSince1970: 10)
        )
        let text = try XCTUnwrap(String(data: export, encoding: .utf8))
        XCTAssertFalse(text.contains("\"sequence\" : 1"))
        XCTAssertTrue(text.contains("\"sequence\" : 2"))
        XCTAssertTrue(text.contains("\"sequence\" : 3"))
    }

    func testExportDeclaresPrivacyBoundaryAndEmbedsMetricKitJSON() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalDiagnosticsStore(directoryURL: root)
        let payload = try JSONSerialization.data(withJSONObject: ["crashDiagnostics": [["signal": 11]]])
        let stored = try await store.store(payload, kind: .diagnostics)
        XCTAssertTrue(stored)

        let data = try await store.exportData(
            appVersion: "1.0",
            buildNumber: "3",
            operatingSystem: "Test OS"
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let privacy = try XCTUnwrap(object["privacy"] as? [String: Any])
        let records = try XCTUnwrap(object["metricKitPayloads"] as? [[String: Any]])

        XCTAssertEqual(privacy["automaticUpload"] as? Bool, false)
        XCTAssertEqual(privacy["containsAudio"] as? Bool, false)
        XCTAssertEqual(privacy["containsTranscripts"] as? Bool, false)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?["kind"] as? String, "diagnostics")
    }

    func testExportIncludesRuntimeSnapshotAndTypedOperationalEvents() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalDiagnosticsStore(directoryURL: root)
        let snapshot = makeSnapshot()
        let event = LocalOperationalDiagnosticEvent(
            recordedAt: Date(timeIntervalSince1970: 123),
            state: .copiedToClipboard,
            snapshot: snapshot
        )

        let recorded = try await store.record(event)
        XCTAssertTrue(recorded)
        let data = try await store.exportData(
            appVersion: "1.0",
            buildNumber: "29",
            operatingSystem: "Test OS",
            generatedAt: Date(timeIntervalSince1970: 456),
            snapshot: snapshot
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let runtime = try XCTUnwrap(object["runtimeSnapshot"] as? [String: Any])
        let events = try XCTUnwrap(object["operationalEvents"] as? [[String: Any]])
        let privacy = try XCTUnwrap(object["privacy"] as? [String: Any])

        XCTAssertEqual(object["schemaVersion"] as? Int, 2)
        XCTAssertEqual(runtime["distributionChannel"] as? String, "Direct")
        XCTAssertEqual(runtime["automaticInsertionSupported"] as? Bool, false)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?["state"] as? String, "copiedToClipboard")
        let eventKeys = Set(try XCTUnwrap(events.first).keys)
        XCTAssertEqual(eventKeys, Set(["recordedAt", "state", "snapshot"]))
        XCTAssertEqual(privacy["containsFocusedAppMetadata"] as? Bool, false)

        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("\"transcript\""))
        XCTAssertFalse(text.contains("\"clipboardContents\""))
        XCTAssertFalse(text.contains("\"bundleIdentifier\""))
    }

    func testOperationalRetentionDoesNotEvictMetricKitPayloads() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalDiagnosticsStore(
            directoryURL: root,
            maximumPayloadBytes: 4_096,
            maximumStoredPayloads: 1,
            maximumStoredOperationalEvents: 2
        )

        for sequence in 1...2 {
            let payload = try JSONSerialization.data(withJSONObject: ["sequence": sequence])
            let stored = try await store.store(
                payload,
                kind: .metrics,
                receivedAt: Date(timeIntervalSince1970: TimeInterval(sequence))
            )
            XCTAssertTrue(stored)
        }
        for sequence in 3...5 {
            let recorded = try await store.record(LocalOperationalDiagnosticEvent(
                recordedAt: Date(timeIntervalSince1970: TimeInterval(sequence)),
                state: sequence.isMultiple(of: 2) ? .listening : .transcribing,
                snapshot: makeSnapshot()
            ))
            XCTAssertTrue(recorded)
        }

        let summary = try await store.summary()
        XCTAssertEqual(summary.payloadCount, 1)
        XCTAssertEqual(summary.operationalEventCount, 2)
    }

    func testOperationalEventsAppendToOneLogFile() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalDiagnosticsStore(directoryURL: root)

        for sequence in 1...5 {
            try await store.record(event(at: sequence, state: .listening))
        }

        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(names, [LocalDiagnosticsStore.operationalLogName])
        let log = try String(contentsOf: root.appendingPathComponent(LocalDiagnosticsStore.operationalLogName), encoding: .utf8)
        XCTAssertEqual(log.split(separator: "\n").count, 5)
        let summary = try await store.summary()
        XCTAssertEqual(summary.operationalEventCount, 5)
        XCTAssertEqual(summary.newestOperationalEventDate, Date(timeIntervalSince1970: 5))
    }

    func testOperationalLogRotatesBySizeAndKeepsTwoGenerations() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let lineBytes = try JSONEncoderForTest.lineBytes(of: event(at: 1, state: .idle))
        // Room for exactly three lines per file.
        let store = LocalDiagnosticsStore(
            directoryURL: root,
            maximumStoredOperationalEvents: 1_000,
            maximumOperationalLogBytes: lineBytes * 3
        )

        for sequence in 1...10 {
            try await store.record(event(at: sequence, state: .idle))
        }

        let names = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        XCTAssertEqual(names, [LocalDiagnosticsStore.operationalLogName, LocalDiagnosticsStore.rotatedOperationalLogName])
        for name in names {
            let size = try XCTUnwrap(
                FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(name).path)[.size] as? Int
            )
            XCTAssertLessThanOrEqual(size, lineBytes * 3)
        }
        // 10 events, 3 per file: [7,8,9] rotated, [10] active; events 1–6 were rotated away.
        let data = try await store.exportData(generatedAt: Date(timeIntervalSince1970: 100))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let events = try XCTUnwrap(object["operationalEvents"] as? [[String: Any]])
        let formatter = ISO8601DateFormatter()
        let seconds = events.compactMap { ($0["recordedAt"] as? String).flatMap(formatter.date(from:)) }
            .map { Int($0.timeIntervalSince1970) }
        XCTAssertEqual(seconds, [7, 8, 9, 10])
    }

    func testTornLogLineIsSkipped() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalDiagnosticsStore(directoryURL: root)
        try await store.record(event(at: 1, state: .listening))
        let logURL = root.appendingPathComponent(LocalDiagnosticsStore.operationalLogName)
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"recordedAt\":\"2026".utf8))
        try handle.close()

        let summary = try await store.summary()

        XCTAssertEqual(summary.operationalEventCount, 1)
    }

    func testLegacyPerEventFilesAreRemovedButMetricKitPayloadsSurvive() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacyEvent = try JSONEncoderForTest.data(of: event(at: 1, state: .listening))
        for index in 0..<3 {
            try legacyEvent.write(to: root.appendingPathComponent(
                "2026-09-2\(index)T10:00:00.000Z-operational-\(UUID().uuidString).json"
            ))
        }
        let metrics = try JSONSerialization.data(withJSONObject: ["sequence": 1])
        let metricsName = "2026-09-20T10:00:00.000Z-metrics-\(UUID().uuidString).json"
        try metrics.write(to: root.appendingPathComponent(metricsName))
        let store = LocalDiagnosticsStore(directoryURL: root)

        try await store.record(event(at: 2, state: .idle))

        let names = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        XCTAssertEqual(names, [metricsName, LocalDiagnosticsStore.operationalLogName])
        let summary = try await store.summary()
        XCTAssertEqual(summary.payloadCount, 1)
        XCTAssertEqual(summary.operationalEventCount, 1)
    }

    private func event(at seconds: Int, state: LocalOperationalDiagnosticState) -> LocalOperationalDiagnosticEvent {
        LocalOperationalDiagnosticEvent(
            recordedAt: Date(timeIntervalSince1970: TimeInterval(seconds)),
            state: state,
            snapshot: makeSnapshot()
        )
    }

    /// Mirrors `LocalDiagnosticsStore.record`'s encoding so size-based tests can budget exactly.
    private enum JSONEncoderForTest {
        static func data(of event: LocalOperationalDiagnosticEvent) throws -> Data {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(event)
        }

        static func lineBytes(of event: LocalOperationalDiagnosticEvent) throws -> Int {
            try data(of: event).count + 1
        }
    }

    private func makeSnapshot() -> LocalDiagnosticsSnapshot {
        LocalDiagnosticsSnapshot(
            distributionChannel: "Direct",
            appVersion: "1.0",
            buildNumber: "29",
            automaticInsertionSupported: false,
            automaticInsertionEnabled: false,
            accessibilityGranted: false,
            microphoneGranted: true,
            hotkeyArmed: true,
            modelState: "ready",
            modelIdentifier: "test-model",
            injectionMethod: "clipboard",
            realtimeTranscriptionEnabled: true
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Dictari-DiagnosticsTests-\(UUID().uuidString)", isDirectory: true)
    }
}
