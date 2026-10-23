// OnboardingModelView.swift
// Dictari — step three: choose the engine and get it onto the Mac.
//
// This is where first-run flows lose people. A few hundred megabytes arrive over an unknown
// connection, and then CoreML spends a further stretch compiling them for the Neural Engine —
// during which a naive UI shows a full progress bar and nothing else, which reads as frozen.
// Show reported progress rather than presenting estimated model sizes as downloaded bytes.
// The selected model remains visible; alternatives are available without crowding setup.

import SwiftUI

struct OnboardingModelView: View {
    @Environment(AppCoordinator.self) private var app

    var onContinue: () -> Void

    @State private var selection: String?
    @State private var installedModelIDs: Set<String> = []

    private var chosen: ModelDescriptor {
        ModelDescriptor.descriptor(for: selection ?? app.settings.data.activeModelID)
    }
    private var isActiveChoice: Bool { chosen.id == app.settings.data.activeModelID }

    private var progress: Double? {
        if case .loading(let value) = app.modelState { return value }
        return nil
    }
    private var isLoading: Bool {
        if case .loading = app.modelState { return true }
        return false
    }
    private var isReady: Bool { app.modelState == .ready }
    private var failure: String? {
        if case .failed(let reason) = app.modelState { return reason }
        return nil
    }

    var body: some View {
        OnboardingScaffold(
            eyebrow: Strings.eyebrow,
            title: Strings.title,
            subtitle: Strings.subtitle
        ) {
            VStack(alignment: .leading, spacing: 0) {
                MonoCard {
                    HStack(spacing: 12) {
                        Image(systemName: "waveform")
                            .foregroundStyle(Mono.secondaryText)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(chosen.displayName)
                                .font(Typo.cardTitle)
                                .foregroundStyle(Mono.primaryText)
                            Text(chosen.note)
                                .font(Typo.secondary)
                                .foregroundStyle(Mono.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Text(installedModelIDs.contains(chosen.id) ? "On disk" : "~\(chosen.approxSizeMB) MB")
                            .font(Typo.mono)
                            .foregroundStyle(Mono.secondaryText)
                    }
                }
                .staged(3)

                Menu {
                    ForEach(ModelDescriptor.curated) { model in
                        Button {
                            selection = model.id
                        } label: {
                            if model.id == chosen.id {
                                Label(model.displayName, systemImage: "checkmark")
                            } else {
                                Text(model.displayName)
                            }
                        }
                    }
                } label: {
                    Text("Other models")
                        .font(Typo.secondary)
                        .foregroundStyle(Mono.secondaryText)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(isLoading)
                .padding(.top, 10)
                .staged(3)

                // Fixed-height so the card and the buttons never move when the download starts.
                statusArea
                    .frame(height: 64, alignment: .topLeading)
                    .padding(.top, 14)
                    .staged(4)
            }
            .padding(.top, 20)
        } actions: {
            if failure != nil {
                OnboardingButton(title: Strings.continueAnyway, kind: .quiet, action: onContinue)
            }
            OnboardingButton(title: primaryTitle, isEnabled: !isLoading, action: primaryAction)
        }
        .onAppear { if selection == nil { selection = app.settings.data.activeModelID } }
        .task(id: isLoading) {
            // File inspection must not block SwiftUI's first render or run for every progress
            // update. Recheck after loading ends; never walk the model tree from body.
            guard !isLoading else { return }
            let models = ModelDescriptor.curated
            let installed = await Task.detached(priority: .utility) {
                Set(models.filter { ModelFiles.isDownloaded($0) }.map(\.id))
            }.value
            guard !Task.isCancelled else { return }
            installedModelIDs = installed
        }
    }

    // MARK: - Status

    @ViewBuilder
    private var statusArea: some View {
        if isLoading {
            VStack(alignment: .leading, spacing: 8) {
                MonoProgressBar(value: progress)
                HStack {
                    Text(phaseCaption)
                        .font(Typo.secondary)
                        .foregroundStyle(Mono.secondaryText)
                    Spacer(minLength: 12)
                    if let progress {
                        Text(progress, format: .percent.precision(.fractionLength(0)))
                            .font(Typo.mono)
                            .foregroundStyle(Mono.tertiaryText)
                            .monospacedDigit()
                    }
                }
            }
            .transition(.opacity)
        } else if let failure {
            VStack(alignment: .leading, spacing: 4) {
                Text(Strings.failedTitle)
                    .font(Typo.cardTitle)
                    .foregroundStyle(Mono.primaryText)
                Text(failure)
                    .font(Typo.secondary)
                    .foregroundStyle(Mono.secondaryText)
                    .lineLimit(2)
            }
            .transition(.opacity)
        } else if isReady && isActiveChoice {
            Text(Strings.readyNote)
                .font(Typo.secondary)
                .foregroundStyle(Mono.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460, alignment: .leading)
                .transition(.opacity)
        }
    }

    /// The download itself is only the first half of the wait; naming the second half is what
    /// keeps a full bar from reading as a hang.
    private var phaseCaption: String {
        guard let progress else { return Strings.preparing }
        if progress >= 0.995 { return Strings.compiling }
        return Strings.downloading
    }

    // MARK: - Primary action

    private var primaryTitle: String {
        if isLoading { return Strings.working }
        if failure != nil { return Strings.tryAgain }
        if isReady && isActiveChoice { return Strings.continueTitle }
        if installedModelIDs.contains(chosen.id) { return Strings.useThis }
        return String(localized: "Download · ~\(chosen.approxSizeMB) MB",
                      comment: "Onboarding, model step: button title; the argument is the download size in megabytes")
    }

    private func primaryAction() {
        if isReady && isActiveChoice { return onContinue() }
        let target = chosen
        Task {
            if target.id != app.settings.data.activeModelID {
                // Switching builds a fresh engine and drives `modelState` all the way through
                // download, so the bar above needs nothing else wired to it.
                await app.setActiveModel(target)
            } else {
                await app.reloadModel()
            }
        }
    }

    // MARK: - Strings

    private enum Strings {
        static let eyebrow = String(localized: "Offline dictation", comment: "Onboarding, model step")
        static let title = String(localized: "Get ready to dictate", comment: "Onboarding, model step")
        static let subtitle = String(localized: "Download one model to dictate offline. You can switch models later in Settings.", comment: "Onboarding, model step")
        static let readyNote = String(localized: "Ready to go — this model is already on your Mac.", comment: "Onboarding, model step")
        static let preparing = String(localized: "Preparing…", comment: "Onboarding, model step")
        static let downloading = String(localized: "Downloading…", comment: "Onboarding, model step")
        static let compiling = String(localized: "Preparing model…", comment: "Onboarding, model step")
        static let failedTitle = String(localized: "That download didn't finish", comment: "Onboarding, model step")
        static let useThis = String(localized: "Use this model", comment: "Onboarding, model step")
        static let continueTitle = String(localized: "Continue", comment: "Onboarding, model step")
        static let continueAnyway = String(localized: "Continue anyway", comment: "Onboarding, model step")
        static let tryAgain = String(localized: "Try again", comment: "Onboarding, model step")
        static let working = String(localized: "Working…", comment: "Onboarding, model step")
    }
}
