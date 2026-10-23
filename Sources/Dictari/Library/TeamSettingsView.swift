import SwiftUI
import UniformTypeIdentifiers

struct TeamSettingsView: View {
    @Environment(AppCoordinator.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pending: TeamPackage?
    @State private var message: String?
    /// Whether `message` reports a failure. Presentation only: it picks the notice's glyph.
    @State private var messageIsError = false
    @State private var working = false

    var body: some View {
        SettingsScrollPane(
            title: "Shared Settings",
            subtitle: "Move your vocabulary, profiles and language rules to another Mac, or share them with a colleague."
        ) {
            SettingsCard(
                title: "Share a settings file",
                footer: "Recordings, transcripts and permissions are never included. Export a new file to share later changes."
            ) {
                VStack(spacing: 0) {
                    SettingsRow("Export", sublabel: "Saves vocabulary, custom profiles and language rules to a file.") {
                        Button("Export\u{2026}", action: exportPackage)
                            .buttonStyle(MonoActionButtonStyle(.secondary, size: .small))
                    }
                    SettingsCardDivider()
                    SettingsRow("Import", sublabel: "Adds what is new from a file. Duplicates merge and your existing settings win.") {
                        Button("Import\u{2026}", action: importPackage)
                            .buttonStyle(MonoActionButtonStyle(.secondary, size: .small))
                    }

                    if working {
                        MonoProgressBar(value: nil, height: 3)
                            .padding([.horizontal, .bottom], Metrics.cardPadding)
                            .transition(.opacity)
                    }
                    if let message {
                        SettingsNotice(message, systemImage: messageIsError ? "exclamationmark.triangle" : "checkmark.circle")
                            .padding([.horizontal, .bottom], Metrics.cardPadding)
                            .transition(.monoReveal(reduceMotion: reduceMotion))
                    }
                    if let error = app.vocabulary.persistenceError {
                        SettingsNotice(error, systemImage: "exclamationmark.triangle")
                            .padding([.horizontal, .bottom], Metrics.cardPadding)
                            .transition(.monoReveal(reduceMotion: reduceMotion))
                    }
                }
                .disabled(working)
                .monoAnimation(Motion.reveal, value: message)
                .monoAnimation(Motion.swap, value: working)
                .monoAnimation(Motion.reveal, value: app.vocabulary.persistenceError)
            }
            .settingsSearchAnchor("team.share")
        }
        .alert("Import shared settings?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("Cancel", role: .cancel) { pending = nil }
            Button("Import") {
                guard let package = pending else { return }
                pending = nil
                do {
                    let merged = package.merging(into: app.settings.data)
                    let summary = try app.vocabulary.importData(JSONEncoder().encode(package.vocabulary))
                    app.settings.data = merged
                    messageIsError = false
                    message = String(localized: "Added \(summary.added) words; merged \(summary.merged) entries. Existing profiles and language choices were kept.",
                                     comment: "Shared settings import result; both numbers need plural forms")
                } catch { messageIsError = true; message = error.localizedDescription }
            }
        } message: {
            if let pending {
                Text("\(pending.vocabulary.count) vocabulary entries, \(pending.customDictationProfiles?.count ?? 0) custom profiles, \(pending.profileLanguages.count) profile languages and \(pending.applicationLanguages.count) app rules. Duplicates merge; existing settings win.",
                     comment: "Import confirmation; every number needs plural forms")
            }
        }
    }

    private func exportPackage() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Dictari Settings.json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let package = TeamPackage(vocabulary: app.vocabulary.terms, settings: app.settings.data)
            working = true
            Task {
                defer { working = false }
                do {
                    try await Task.detached { try package.encoded().write(to: url, options: .atomic) }.value
                    messageIsError = false
                    message = String(localized: "Settings exported. You can now share the file.")
                } catch { messageIsError = true; message = error.localizedDescription }
            }
        }
    }
    private func importPackage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            working = true
            Task {
                defer { working = false }
                do {
                    pending = try await Task.detached {
                        let file = try FileHandle(forReadingFrom: url)
                        defer { try? file.close() }
                        return try TeamPackage.decode(file.read(upToCount: 2 * 1024 * 1024 + 1) ?? Data())
                    }.value
                } catch { messageIsError = true; message = error.localizedDescription }
            }
        }
    }
}
