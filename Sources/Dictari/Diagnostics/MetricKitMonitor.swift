// MetricKitMonitor.swift
// Dictari — receives Apple's crash, hang and performance payloads and keeps them local.

import Foundation
import MetricKit

/// MetricKit invokes its subscriber on a background queue. The callback immediately converts
/// framework objects to immutable Data, then hands that Sendable value to the actor-backed local
/// archive. No app state, transcript or focused-application context crosses the callback boundary.
final class MetricKitMonitor: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    private let store: LocalDiagnosticsStore
    private var isStarted = false

    init(store: LocalDiagnosticsStore) {
        self.store = store
        super.init()
    }

    @MainActor
    func start() {
        guard !isStarted else { return }
        isStarted = true
        MXMetricManager.shared.add(self)
    }

    @MainActor
    func stop() {
        guard isStarted else { return }
        MXMetricManager.shared.remove(self)
        isStarted = false
    }

    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        persist(payloads.map { $0.jsonRepresentation() }, kind: .metrics)
    }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        persist(payloads.map { $0.jsonRepresentation() }, kind: .diagnostics)
    }

    private nonisolated func persist(_ payloads: [Data], kind: LocalDiagnosticPayloadKind) {
        let store = self.store
        Task.detached(priority: .utility) {
            for payload in payloads {
                _ = try? await store.store(payload, kind: kind)
            }
        }
    }
}
