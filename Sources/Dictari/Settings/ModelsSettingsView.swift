// ModelsSettingsView.swift
// Dictari — Whisper model library: per-model size, download, use, delete.

import SwiftUI

struct ModelsSettingsView: View {
    @Environment(AppCoordinator.self) private var app
    // Bumped after a download/delete to re-read on-disk state in the rows.
    @State private var rev = 0

    var body: some View {
        SettingsScrollPane(
            title: SettingsSection.models.label,
            subtitle: "Choose the model that turns your voice into text. It runs on this Mac."
        ) {
            SettingsCard(title: "Transcription Model") {
                ForEach(Array(ModelDescriptor.curated.enumerated()), id: \.element.id) { index, model in
                    if index > 0 { SettingsCardDivider() }
                    ModelRow(model: model, rev: $rev)
                        .settingsSearchAnchor("models.\(model.id)")
                }
            }
            .settingsSearchAnchor("models.transcriptionModel")
            ModelsFooterView(rev: rev)
        }
    }
}

// MARK: - Model row

private struct ModelRow: View {
    @Environment(AppCoordinator.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let model: ModelDescriptor
    @Binding var rev: Int

    private var isActive: Bool { app.settings.data.activeModelID == model.id }
    private var isDownloading: Bool {
        guard case .downloading(let modelID, _, _) = app.modelDownloadState else { return false }
        return modelID == model.id
    }
    private var isCancelling: Bool {
        guard case .cancelling(let modelID, _) = app.modelDownloadState else { return false }
        return modelID == model.id
    }
    private var failure: ModelDownloadFailure? {
        app.modelDownloadState.failure(for: model.id)
    }
    private var activeLoadFailure: String? {
        guard isActive, failure == nil, case .failed(let reason) = app.modelState else { return nil }
        return reason
    }
    private var anotherModelIsBusy: Bool {
        app.modelDownloadState.isInProgress && app.modelDownloadState.modelID != model.id
    }
    private var downloaded: Bool { _ = rev; return ModelFiles.cachedStatus(model).downloaded }

    private var sizeText: String {
        _ = rev
        let status = ModelFiles.cachedStatus(model)
        if status.downloaded, status.bytes > 0 { return ModelFiles.formatted(status.bytes) }
        return model.approxSizeText
    }

    /// Which trailing control is showing. The actions cross-fade on this rather than on every
    /// input separately, so one state change is one animation.
    private var actionPhase: Int {
        if isDownloading { return 0 }
        if isCancelling { return 1 }
        if failure != nil { return 2 }
        if isActive { return !downloaded || activeLoadFailure != nil ? 3 : 4 }
        return downloaded ? 5 : 6
    }

    /// The bar stays on screen while cancelling, so the row does not jump twice (bar out,
    /// then the Download button in) for one action.
    private var showsProgress: Bool { isDownloading || isCancelling }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(model.displayName)
                            .font(isActive ? Typo.body.weight(.medium) : Typo.body)
                            .foregroundStyle(Mono.primaryText)
                        // State and capability are separate: ACTIVE/DEFAULT describes selection,
                        // while LIVE tells the user what the model can do before they choose it.
                        if isActive {
                            Badge(text: LocalizedStringResource("ACTIVE", comment: "Model badge: the model in use"),
                                  filled: true)
                                .transition(.opacity)
                        } else if model.isDefault {
                            Badge(text: LocalizedStringResource("DEFAULT", comment: "Model badge: the recommended model"))
                                .transition(.opacity)
                        }
                        if model.supportsLiveTranscriptPreview {
                            Badge(text: LocalizedStringResource(
                                "LIVE", comment: "Model badge: can show the transcript while you speak"))
                                .help("Supports live transcript preview while recording")
                                .accessibilityLabel("Supports live transcript preview")
                        }
                    }
                    // The note carries speed and coverage in words, which the two dot
                    // meters were trying and failing to say.
                    Text(model.note)
                        .font(Typo.secondary)
                        .foregroundStyle(Mono.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                Text(sizeText)
                    .font(Typo.mono)
                    .foregroundStyle(Mono.tertiaryText)
                    .monospacedDigit()
                    .contentTransition(.numericText())

                actions
                    .id(actionPhase)
                    .transition(.opacity)
            }

            // Full-width while downloading: a 70-point stub could not show progress, and a
            // percentage next to it was reading the same number twice.
            if showsProgress {
                ModelDownloadProgress(
                    progress: isDownloading ? app.modelDownloadState.progress : nil,
                    isCancelling: isCancelling,
                    sizeText: model.approxSizeText
                )
                .transition(.monoReveal(reduceMotion: reduceMotion))
            }

            if let failure {
                ModelFailureMessage(failure: failure)
                    .transition(.monoReveal(reduceMotion: reduceMotion))
            } else if let activeLoadFailure {
                ModelFailureMessage(
                    title: String(localized: "Model couldn\u{2019}t be prepared"),
                    message: activeLoadFailure
                )
                .transition(.monoReveal(reduceMotion: reduceMotion))
            }
        }
        .padding(Metrics.cardPadding)
        .monoAnimation(Motion.snap, value: isActive)
        .monoAnimation(Motion.swap, value: actionPhase)
        .monoAnimation(Motion.reveal, value: showsProgress)
        .monoAnimation(Motion.reveal, value: failure)
        .monoAnimation(Motion.reveal, value: activeLoadFailure)
        .monoAnimation(Motion.snap, value: sizeText)
    }

    @ViewBuilder
    private var actions: some View {
        if isDownloading {
            Button("Cancel download", systemImage: "xmark") {
                app.cancelModelDownload()
            }
            .buttonStyle(MonoGlyphButtonStyle(side: 22))
            .help("Cancel download")
        } else if isCancelling {
            Text("Cancelling\u{2026}")
                .font(Typo.secondary)
                .foregroundStyle(Mono.secondaryText)
        } else if let failure {
            Button {
                startPreparation(failure.purpose)
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .buttonStyle(MonoActionButtonStyle(.primary, size: .small))
        } else if isActive {
            if !downloaded || activeLoadFailure != nil {
                Button {
                    startPreparation(.activate)
                } label: {
                    Label(activeLoadFailure == nil ? "Download" : "Retry",
                          systemImage: activeLoadFailure == nil ? "arrow.down" : "arrow.clockwise")
                }
                .buttonStyle(MonoActionButtonStyle(.primary, size: .small))
                .disabled(anotherModelIsBusy)
            } else {
                ModelStateIndicator(state: app.modelState)
            }
        } else if downloaded {
            HStack(spacing: 4) {
                Button(String(localized: "Use", comment: "Button: switch to this transcription model")) {
                    startPreparation(.activate)
                }
                .buttonStyle(MonoActionButtonStyle(.secondary, size: .small))
                .accessibilityLabel("Use \(model.displayName)")
                Button("Delete model", systemImage: "trash") {
                    app.deleteModel(model)
                    ModelFiles.invalidateStatusCache()
                    rev += 1
                }
                .buttonStyle(MonoGlyphButtonStyle(side: 22))
                .help("Delete the downloaded files")
            }
            .disabled(anotherModelIsBusy)
        } else {
            Button {
                startPreparation(.download)
            } label: {
                Label("Download", systemImage: "arrow.down")
            }
            .buttonStyle(MonoActionButtonStyle(.secondary, size: .small))
            .disabled(anotherModelIsBusy)
        }
    }

    private func startPreparation(_ purpose: ModelPreparationPurpose) {
        Task {
            switch purpose {
            case .download: await app.downloadModel(model)
            case .activate: await app.setActiveModel(model)
            }
            ModelFiles.invalidateStatusCache()
            rev += 1
        }
    }
}

// MARK: - Small pieces

private extension ModelDescriptor {
    /// The catalogue's approximate download size, with the unit in the interface language.
    /// Kept in megabytes as before (no switch to GB) so the English text is unchanged.
    var approxSizeText: String {
        let size = Measurement(value: Double(approxSizeMB), unit: UnitInformationStorage.megabytes)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided))
        return String(localized: "~\(size)", comment: "Approximate model download size, e.g. ~483 MB")
    }
}

private struct Badge: View {
    let text: LocalizedStringResource
    var filled = false
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(filled ? Mono.selectionText : Mono.secondaryText)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(filled ? Mono.ink() : Mono.ink(0.08))
            .clipShape(Capsule())
    }
}

/// The download in progress: a full-width bar with the percentage and size underneath.
/// The percentage rolls (`numericText`) instead of flickering through digits, and an
/// unknown total shows the indeterminate bar rather than a stuck 0 %.
private struct ModelDownloadProgress: View {
    let progress: Double?
    let isCancelling: Bool
    let sizeText: String

    private var statusText: String {
        if isCancelling { return String(localized: "Stopping download") }
        guard let progress else { return String(localized: "Preparing download") }
        let percent = min(max(progress, 0), 1).formatted(.percent.precision(.fractionLength(0)))
        return String(localized: "Downloading \(percent)", comment: "Model download progress; the argument is a percentage")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MonoProgressBar(value: isCancelling ? nil : progress, height: 4)
                .opacity(isCancelling ? 0.5 : 1)
            HStack(spacing: 6) {
                Text(statusText)
                    .contentTransition(.numericText())
                Spacer(minLength: 8)
                Text(sizeText)
                    .foregroundStyle(Mono.tertiaryText)
            }
            .font(Typo.secondary)
            .foregroundStyle(Mono.secondaryText)
            .monospacedDigit()
            .monoAnimation(Motion.snap, value: statusText)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Inline failure under a model row. Same field-grey surface as `SettingsNotice`, with a
/// bold first line: the shared notice has no title slot, and the failure reads better
/// split into what happened and what to do.
private struct ModelFailureMessage: View {
    let title: String
    let message: String

    init(failure: ModelDownloadFailure) {
        title = failure.title
        message = failure.message
    }

    init(title: String, message: String) {
        self.title = title
        self.message = message
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(Mono.secondaryText)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Typo.secondary.weight(.semibold))
                    .foregroundStyle(Mono.primaryText)
                Text(message)
                    .font(Typo.secondary)
                    .foregroundStyle(Mono.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: Metrics.controlRadius + 1, style: .continuous)
                .fill(Mono.fieldFill)
        )
        .accessibilityElement(children: .combine)
    }
}

// MARK: - State indicator (active model)

private struct ModelStateIndicator: View {
    let state: ModelState

    var body: some View {
        Group {
            switch state {
            case .ready:
                status("Ready", comment: "Active model is loaded", systemImage: "checkmark.circle.fill")
            case .idle:
                Text("Not ready")
                    .font(Typo.secondary)
                    .foregroundStyle(Mono.secondaryText)
            case .loading(let progress):
                HStack(spacing: 6) {
                    MonoProgressBar(value: progress).frame(width: 70)
                    Text(verbatim: progress.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "\u{2026}")
                        .font(Typo.mono)
                        .foregroundStyle(Mono.secondaryText)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Loading model")
            case .failed(let reason):
                status("Failed", comment: "Active model failed to load", systemImage: "exclamationmark.circle")
                    .help(reason)
            }
        }
        .monoAnimation(Motion.swap, value: state)
    }

    private func status(_ text: String.LocalizationValue, comment: StaticString,
                        systemImage: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(Mono.ink())
                .imageScale(.small)
                .contentTransition(.symbolEffect(.replace))
            Text(LocalizedStringResource(text, comment: comment))
                .font(Typo.secondary)
                .foregroundStyle(Mono.secondaryText)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Footer

private struct ModelsFooterView: View {
    let rev: Int

    /// Only complete models count: the leftovers of an interrupted download are not something
    /// the user has, and adding them here made the byte total disagree with the count beside it.
    private var totalBytes: Int64 {
        _ = rev
        return ModelDescriptor.curated.reduce(0) { sum, desc in
            let status = ModelFiles.cachedStatus(desc)
            return status.downloaded ? sum + status.bytes : sum
        }
    }
    private var downloadedCount: Int {
        _ = rev
        return ModelDescriptor.curated.filter { ModelFiles.cachedStatus($0).downloaded }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            line("internaldrive",
                 Text("\(downloadedCount) downloaded \u{00B7} \(ModelFiles.formatted(totalBytes)) on disk",
                      comment: "Models footer: number of downloaded models and their total size"))
                .contentTransition(.numericText())
                .monoAnimation(Motion.snap, value: rev)
            line("lock.shield", Text("Transcription runs on this Mac. Audio never leaves it."))
            line("waveform", Text("LIVE models can write as you speak in supported fields.",
                                  comment: "LIVE is the model badge shown above"))
        }
        .padding(.horizontal, 4)
    }

    private func line(_ systemImage: String, _ text: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: systemImage)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(Mono.tertiaryText)
                .imageScale(.small)
                .frame(width: 14)
                .accessibilityHidden(true)
            text
                .font(Typo.secondary)
                .foregroundStyle(Mono.secondaryText)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    ModelsSettingsView()
        .environment(AppCoordinator())
        .frame(width: 640, height: 560)
}
