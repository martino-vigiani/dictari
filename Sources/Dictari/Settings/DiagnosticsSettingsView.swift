// DiagnosticsSettingsView.swift
// Dictari — local diagnostics and the support export. Moved out of "General" into the
// Advanced group: it is only ever opened when someone asks for a support file.

import SwiftUI
import UniformTypeIdentifiers

struct DiagnosticsSettingsView: View {
    @Environment(AppCoordinator.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExportingDiagnostics = false
    @State private var diagnosticsMessage: String?
    @State private var diagnosticsError: String?
    @State private var diagnosticsSummary: LocalDiagnosticsSummary?

    var body: some View {
        SettingsScrollPane(
            title: SettingsSection.diagnostics.label,
            subtitle: "A record of how Dictari is working, kept on this Mac for when you ask support for help."
        ) {
            SettingsCard(title: "Diagnostics") {
                SettingsRow(
                    "Local Diagnostics",
                    sublabel: "App state, delivery results, crashes and performance"
                ) {
                    Text(diagnosticsSummaryLabel)
                        .font(Typo.secondary)
                        .foregroundStyle(Mono.secondaryText)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .monoAnimation(Motion.snap, value: diagnosticsSummaryLabel)
                }
                .settingsSearchAnchor("diagnostics.local")

                SettingsCardDivider()

                SettingsRow(
                    "Export for Support",
                    sublabel: "No audio or dictated text"
                ) {
                    Button(action: exportDiagnostics) {
                        // Both labels are laid out so the button keeps one width.
                        ZStack {
                            Text("Export\u{2026}").opacity(isExportingDiagnostics ? 0 : 1)
                            Text("Exporting\u{2026}").opacity(isExportingDiagnostics ? 1 : 0)
                        }
                    }
                    .buttonStyle(MonoActionButtonStyle(.secondary, size: .small))
                    .disabled(isExportingDiagnostics)
                    .accessibilityLabel(isExportingDiagnostics ? "Exporting" : "Export for Support")
                    .monoAnimation(Motion.swap, value: isExportingDiagnostics)
                }
                .settingsSearchAnchor("diagnostics.export")

                if let diagnosticsMessage {
                    SettingsNotice(diagnosticsMessage, systemImage: "checkmark.circle")
                        .padding([.horizontal, .bottom], Metrics.cardPadding)
                        .transition(.monoReveal(reduceMotion: reduceMotion))
                }
            }
            .monoAnimation(Motion.reveal, value: diagnosticsMessage)
        }
        .alert("Diagnostics", isPresented: Binding(
            get: { diagnosticsError != nil },
            set: { if !$0 { diagnosticsError = nil } }
        )) {
            Button("OK", role: .cancel) { diagnosticsError = nil }
        } message: {
            Text(diagnosticsError ?? "")
        }
        .task {
            await refreshDiagnosticsSummary()
        }
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Dictari Diagnostics.json"
        // The default file name stays English: it is a file support recognises, not prose.
        panel.message = String(localized: "Export Dictari diagnostics without audio or dictated text.",
                               comment: "Save panel message for the diagnostics export")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            diagnosticsMessage = nil
            isExportingDiagnostics = true
            Task { @MainActor in
                defer { isExportingDiagnostics = false }
                do {
                    let data = try await app.diagnostics.exportData(
                        snapshot: app.diagnosticsSnapshot()
                    )
                    try await Task.detached(priority: .userInitiated) {
                        try data.write(to: url, options: .atomic)
                    }.value
                    diagnosticsMessage = String(
                        localized: "Diagnostics exported. Attach the file to your message to support.")
                    await refreshDiagnosticsSummary()
                } catch {
                    diagnosticsError = error.localizedDescription
                }
            }
        }
    }

    private var diagnosticsSummaryLabel: String {
        guard let diagnosticsSummary else {
            return String(localized: "Checking…", comment: "Diagnostics record count while it is being read")
        }
        let total = diagnosticsSummary.payloadCount + diagnosticsSummary.operationalEventCount
        return String(localized: "\(total) records", comment: "Number of local diagnostics records")
    }

    private func refreshDiagnosticsSummary() async {
        diagnosticsSummary = try? await app.diagnostics.summary()
    }
}

#Preview {
    DiagnosticsSettingsView()
        .environment(AppCoordinator())
        .frame(width: 600, height: 400)
}
