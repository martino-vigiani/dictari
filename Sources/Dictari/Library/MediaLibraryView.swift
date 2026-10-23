import SwiftUI
import UniformTypeIdentifiers
import ScreenCaptureKit

struct MediaLibraryView: View {
    private enum Source: String, Hashable { case meeting, file }
    @Environment(AppCoordinator.self) private var app
    @State private var source = Source.meeting
    @State private var readingDocument: MediaDocument?
    @State private var applications: [SCRunningApplication] = []
    @State private var informedParticipants = false
    @State private var loadingApplications = false
    @State private var savedApplicationIsRunning = false
    @State private var selectedApplicationIcon: NSImage?
    @State private var applicationStateGeneration = 0
    @State private var applicationPanel: NSOpenPanel?
    @State private var applicationPanelDelegate: MeetingApplicationPanelDelegate?
    @State private var applicationError: String?
    @State private var error: String?
    @State private var stoppingCapture = false
    @State private var cancelling = false
    @State private var deleting: MediaDocument?
    @State private var writingDocument: MediaDocument?

    private var savedApplicationID: String? {
        MeetingApplicationSelection.normalizedBundleID(app.settings.data.meetingApplicationBundleID)
    }

    private var savedApplicationName: String? {
        guard let name = app.settings.data.meetingApplicationName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        return name
    }

    private var meetingApplicationTitle: String {
        savedApplicationName ?? selectedApplication?.applicationName ?? savedApplicationID
            ?? String(localized: "Choose meeting app…", comment: "Meeting app picker row before an app is chosen")
    }

    private var meetingApplicationSubtitle: String {
        guard savedApplicationID != nil else {
            return String(localized: "A browser or calling app that’s open", comment: "Meeting app picker row subtitle")
        }
        if savedApplicationIsRunning {
            return String(localized: "Saved · Includes every window and tab", comment: "Meeting app picker row subtitle")
        }
        return String(localized: "Open \(meetingApplicationTitle) to use this saved choice",
                      comment: "Meeting app picker row subtitle; the argument is the app name")
    }

    private var meetingApplicationAccessibilityLabel: String {
        guard savedApplicationID != nil else { return String(localized: "Choose meeting app") }
        if savedApplicationIsRunning { return String(localized: "Change meeting app, \(meetingApplicationTitle)") }
        return String(localized: "Change meeting app, \(meetingApplicationTitle). Open \(meetingApplicationTitle) before starting")
    }

    private var meetingMicrophoneBinding: Binding<Bool> {
        Binding(
            get: { app.settings.data.meetingIncludeMicrophone ?? true },
            set: { app.settings.data.meetingIncludeMicrophone = $0 }
        )
    }

    private var selectedApplication: SCRunningApplication? {
        let runningApplications = applications.filter {
            NSRunningApplication(processIdentifier: $0.processID)?.isTerminated == false
        }
        guard let resolvedBundleID = MeetingApplicationSelection.resolve(
            savedBundleID: savedApplicationID,
            in: runningApplications.map(\.bundleIdentifier)
        ) else { return nil }
        return runningApplications.first { $0.bundleIdentifier == resolvedBundleID }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var activeDocument: MediaDocument? {
        app.mediaLibrary.documents.first(where: { $0.id == app.mediaLibrary.activeID })
    }

    var body: some View {
        SettingsScrollPane(title: "Files & Meetings",
                           subtitle: "Transcribe a call or a recording. Everything stays on this Mac.") {
            // One slot for "start something" and "something is running": the two states
            // cross-fade in place so the saved list below doesn't jump twice.
            ZStack(alignment: .topLeading) {
                if app.mediaLibrary.isBusy {
                    activityCard
                        .transition(.monoReveal(reduceMotion: reduceMotion))
                } else {
                    startPanel
                        .transition(.monoReveal(reduceMotion: reduceMotion))
                }
            }
            .monoAnimation(Motion.reveal, value: app.mediaLibrary.isBusy)

            VStack(alignment: .leading, spacing: 8) {
                if let message = app.mediaLibrary.message {
                    SettingsNotice(message)
                        .transition(.monoReveal(reduceMotion: reduceMotion))
                }
                if let error {
                    SettingsNotice(error, systemImage: "exclamationmark.circle")
                        .transition(.monoReveal(reduceMotion: reduceMotion))
                }
            }
            .monoAnimation(Motion.reveal, value: app.mediaLibrary.message)
            .monoAnimation(Motion.reveal, value: error)

            savedTranscripts.settingsSearchAnchor("library.saved")
        }
        // The meeting and import cards share one slot; a search result for either picks it.
        .onSettingsSearchReveal(["library.meeting", "library.microphone", "library.import"]) { anchor in
            source = anchor == "library.import" ? .file : .meeting
        }
        .foregroundStyle(Mono.primaryText)
        .sheet(item: $writingDocument) { WritingSheet(text: $0.localizedTranscript) }
        .sheet(item: $readingDocument) { document in
            // Resolve by identity again inside the sheet: live segments must keep updating.
            MediaReadingSheet(documentID: document.id).environment(app)
        }
        .task {
            app.mediaLibrary.load()
            refreshSavedApplicationState()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in
            refreshSavedApplicationState()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
            refreshSavedApplicationState()
        }
        .onChange(of: savedApplicationID) { _, _ in
            informedParticipants = false
            refreshSavedApplicationState()
        }
        .onChange(of: app.mediaLibrary.isBusy) { _, busy in
            if !busy { stoppingCapture = false; cancelling = false }
        }
        .alert("Delete transcript and saved audio?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete", role: .destructive) {
                if let deleting { Task { await app.mediaLibrary.delete(deleting) } }
                deleting = nil
            }
        } message: { Text("This removes this transcript and its audio from the local archive.") }
    }

    // MARK: - Start panel

    private var startPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            MonoSegmented(selection: $source, options: [
                (.meeting, String(localized: "Meeting", comment: "Files & Meetings source tab")),
                (.file, String(localized: "Audio or video", comment: "Files & Meetings source tab: import a file"))
            ])
                .frame(maxWidth: 280)
            // Both cards occupy the same slot so switching tabs cross-fades in place instead
            // of stacking two cards for the length of the transition.
            ZStack(alignment: .topLeading) {
                if source == .meeting {
                    meetingCard.settingsSearchAnchor("library.meeting")
                        .transition(.monoReveal(reduceMotion: reduceMotion))
                } else {
                    importCard.settingsSearchAnchor("library.import")
                        .transition(.monoReveal(reduceMotion: reduceMotion))
                }
            }
            .monoAnimation(Motion.select, value: source)
            if !app.canStartMedia {
                SettingsFootnote("Available when your model is ready and dictation has finished.")
                    .transition(.monoReveal(reduceMotion: reduceMotion))
            }
        }
        .monoAnimation(Motion.reveal, value: app.canStartMedia)
    }

    private var meetingCard: some View {
        SettingsCard(title: "New meeting") {
            if #available(macOS 15.0, *) {
                MediaCardHeader(
                    systemImage: "person.2.wave.2",
                    title: "Transcribe a meeting",
                    message: "Choose the call app. Recording starts when you press Start meeting."
                )
                SettingsCardDivider()
                Button(action: loadApplications) {
                    HStack(spacing: 12) {
                        Group {
                            if let selectedApplicationIcon {
                                Image(nsImage: selectedApplicationIcon).resizable().interpolation(.high)
                                    .scaledToFit()
                            } else {
                                Image(systemName: "app.dashed").font(.system(size: 20, weight: .light))
                                    .foregroundStyle(Mono.tertiaryText)
                            }
                        }
                        .frame(width: 30, height: 30)
                        .transition(.opacity)
                        .id(savedApplicationID)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(meetingApplicationTitle).font(Typo.body)
                                .contentTransition(.opacity)
                            Text(meetingApplicationSubtitle)
                                .font(Typo.secondary).foregroundStyle(Mono.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                                .contentTransition(.opacity)
                        }
                        Spacer(minLength: 8)
                        ZStack {
                            if loadingApplications {
                                ProgressView().controlSize(.small)
                                    .transition(.opacity)
                            } else {
                                Image(systemName: savedApplicationID != nil && !savedApplicationIsRunning
                                      ? "exclamationmark.circle" : "chevron.right")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(savedApplicationID != nil && !savedApplicationIsRunning
                                                     ? Mono.secondaryText : Mono.tertiaryText)
                                    .contentTransition(.symbolEffect(.replace))
                                    .transition(.opacity)
                            }
                        }
                        .frame(width: 18)
                    }
                    .padding(.horizontal, Metrics.cardPadding).padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(MediaRowButtonStyle())
                .disabled(loadingApplications || !app.canStartMedia || applicationPanel != nil)
                .accessibilityLabel(meetingApplicationAccessibilityLabel)
                .monoAnimation(Motion.swap, value: loadingApplications)
                .monoAnimation(Motion.swap, value: savedApplicationIsRunning)
                .monoAnimation(Motion.swap, value: savedApplicationID)
                if let applicationError {
                    SettingsNotice(applicationError, systemImage: "exclamationmark.circle")
                        .padding(.horizontal, Metrics.cardPadding)
                        .padding(.bottom, 12)
                        .transition(.monoReveal(reduceMotion: reduceMotion))
                }
                SettingsCardDivider()
                SettingsRow("Include my microphone", sublabel: "Adds your voice alongside the app’s audio") {
                    Toggle("Include my microphone", isOn: meetingMicrophoneBinding)
                        .labelsHidden().toggleStyle(MonoToggleStyle()).disabled(!app.canStartMedia)
                }
                .settingsSearchAnchor("library.microphone")
                SettingsCardDivider()
                VStack(alignment: .leading, spacing: 14) {
                    Toggle(isOn: $informedParticipants) {
                        Text("Everyone agrees to the recording")
                            .font(Typo.body).fixedSize(horizontal: false, vertical: true)
                    }
                    .toggleStyle(MediaCheckboxToggleStyle())
                    .disabled(!app.canStartMedia)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            headphonesHint
                            Spacer(minLength: 12)
                            startMeetingButton
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            headphonesHint
                            startMeetingButton
                        }
                    }
                }
                .padding(Metrics.cardPadding)
                SettingsCardDivider()
                MediaInlineDisclosure(title: "What gets recorded") {
                    Text("Records audio from the selected app and your microphone, if enabled. No video. Voice labels are optional after recording and support up to one hour of audio.")
                        .font(Typo.secondary).foregroundStyle(Mono.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                SettingsRow("Meeting recording", sublabel: "Requires macOS 15 or later. You can still import an audio or video file.") { EmptyView() }
            }
        }
        .monoAnimation(Motion.reveal, value: applicationError)
    }

    private var headphonesHint: some View {
        Label("Use headphones to avoid echo", systemImage: "headphones")
            .labelStyle(MediaHintLabelStyle())
    }

    @available(macOS 15.0, *)
    private var startMeetingButton: some View {
        Button("Start meeting", action: startMeeting)
            .buttonStyle(MonoActionButtonStyle(.primary))
            .disabled(!app.canStartMedia || !informedParticipants || savedApplicationID == nil
                      || !savedApplicationIsRunning || loadingApplications || applicationPanel != nil)
    }

    private var importCard: some View {
        SettingsCard(title: "Import a recording") {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    MediaCardHeader(
                        systemImage: "waveform",
                        title: "Transcribe audio or video",
                        message: "Dictari reads the audio track and leaves the original file untouched.",
                        padded: false
                    )
                    Spacer(minLength: 12)
                    chooseFileButton
                }
                VStack(alignment: .leading, spacing: 14) {
                    MediaCardHeader(
                        systemImage: "waveform",
                        title: "Transcribe audio or video",
                        message: "Dictari reads the audio track and leaves the original file untouched.",
                        padded: false
                    )
                    chooseFileButton
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Metrics.cardPadding)
            SettingsCardDivider()
            HStack(spacing: 16) {
                Label("Up to 4 hours per file", systemImage: "clock")
                Label("Processed on this Mac", systemImage: "lock")
                Spacer(minLength: 0)
            }
            .labelStyle(MediaHintLabelStyle())
            .padding(.horizontal, Metrics.cardPadding)
            .padding(.vertical, 12)
        }
    }

    private var chooseFileButton: some View {
        Button("Choose File…", action: importFile)
            .buttonStyle(MonoActionButtonStyle(.primary)).disabled(!app.canStartMedia)
    }

    // MARK: - Activity

    private var activityTitle: String {
        if app.mediaLibrary.waitingForEngine { return String(localized: "Waiting for the model") }
        if stoppingCapture { return String(localized: "Finishing recording") }
        if cancelling {
            return app.mediaLibrary.isAnalyzingSpeakers
                ? String(localized: "Stopping voice analysis") : String(localized: "Stopping transcription")
        }
        if app.mediaLibrary.isAnalyzingSpeakers { return String(localized: "Distinguishing voices") }
        if app.mediaLibrary.isRecording { return String(localized: "Recording meeting") }
        // Compares the stored (English) status, never its display form.
        if app.mediaLibrary.documents.first(where: { $0.id == app.mediaLibrary.activeID })?.status == "Preparing" {
            return String(localized: "Preparing audio")
        }
        return String(localized: "Transcribing audio")
    }

    private var activitySymbol: String {
        if app.mediaLibrary.waitingForEngine { return "hourglass" }
        if app.mediaLibrary.isRecording && !stoppingCapture { return "record.circle" }
        if app.mediaLibrary.isAnalyzingSpeakers { return "person.2.wave.2" }
        return "text.bubble"
    }

    /// 0…1 when the work has a measurable end, nil while it doesn't (recording, preparing,
    /// waiting for the model). Drives one bar, so the card never shows two progress styles.
    private func activityProgress(_ document: MediaDocument?) -> Double? {
        if app.mediaLibrary.isAnalyzingSpeakers { return app.mediaLibrary.speakerAnalysisProgress }
        guard let document, !app.mediaLibrary.isRecording, !document.segments.isEmpty else { return nil }
        let completed = document.segments.filter { $0.text != nil }.count
        return Double(completed) / Double(document.segments.count)
    }

    private var activityCard: some View {
        let document = activeDocument
        let progress = activityProgress(document)
        return SettingsCard(title: "In progress", footer: "Dictation is unavailable until this finishes.") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: activitySymbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Mono.secondaryText)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 18)
                        .accessibilityHidden(true)
                    Text(activityTitle)
                        .font(Typo.cardTitle)
                        .contentTransition(.opacity)
                    Spacer(minLength: 8)
                    if let progress {
                        Text(verbatim: min(max(progress, 0), 1).formatted(.percent.precision(.fractionLength(0))))
                            .font(Typo.body.weight(.medium)).monospacedDigit()
                            .foregroundStyle(Mono.secondaryText)
                            .contentTransition(.numericText())
                            .transition(.opacity)
                    }
                }
                if let document {
                    Text(document.displayTitle)
                        .font(Typo.secondary).foregroundStyle(Mono.secondaryText)
                        .lineLimit(2)
                        .padding(.leading, 28)
                }
                MonoProgressBar(value: progress)
                    .padding(.top, 2)
                if let document { activityDetail(document) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Metrics.cardPadding)
            .monoAnimation(Motion.swap, value: activityTitle)
            .monoAnimation(Motion.snap, value: progress)

            if let document {
                SettingsCardDivider()
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { activityActions(document) }
                    VStack(alignment: .leading, spacing: 8) { activityActions(document) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Metrics.cardPadding)
                .padding(.vertical, 12)
            }
        }
    }

    @ViewBuilder private func activityDetail(_ document: MediaDocument) -> some View {
        if app.mediaLibrary.isAnalyzingSpeakers {
            if app.mediaLibrary.speakerAnalysisProgress != nil {
                Text("Analyzing saved app audio")
                    .font(Typo.secondary).foregroundStyle(Mono.secondaryText)
            } else {
                Text("Preparing the local voice model. The first use needs a download.")
                    .font(Typo.secondary).foregroundStyle(Mono.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if !document.segments.isEmpty {
            let completed = document.segments.filter { $0.text != nil }.count
            Text("\(completed) of \(document.segments.count) audio segments transcribed",
                 comment: "Transcription progress; plural follows the second number")
                .font(Typo.secondary).monospacedDigit().foregroundStyle(Mono.secondaryText)
                .contentTransition(.numericText())
                .monoAnimation(Motion.snap, value: completed)
        }
    }

    @ViewBuilder private func activityActions(_ document: MediaDocument) -> some View {
        if app.mediaLibrary.waitingForEngine {
            Button("Quit Dictari") { NSApp.terminate(nil) }.buttonStyle(MonoActionButtonStyle())
        } else if app.mediaLibrary.isRecording {
            Button(stoppingCapture ? "Finishing…" : "Stop & Finish") {
                stoppingCapture = true
                Task { await app.mediaLibrary.stopMeeting(); stoppingCapture = false }
            }
            .buttonStyle(MonoActionButtonStyle(.primary)).disabled(stoppingCapture)
        } else {
            Button(cancelling ? "Stopping…" : "Stop Processing") {
                cancelling = true
                app.mediaLibrary.cancel()
            }
            .buttonStyle(MonoActionButtonStyle()).disabled(cancelling || stoppingCapture)
        }
        Button("View Transcript") { readingDocument = document }
            .buttonStyle(MonoActionButtonStyle()).disabled(!document.hasTranscript)
        if !app.mediaLibrary.waitingForEngine && !app.mediaLibrary.isRecording {
            Text("Saved audio is kept").font(Typo.secondary).foregroundStyle(Mono.secondaryText)
                .padding(.leading, 4)
        }
    }

    // MARK: - Saved transcripts

    private var savedTranscripts: some View {
        let documents = app.mediaLibrary.documents.filter { $0.id != app.mediaLibrary.activeID }
        return VStack(alignment: .leading, spacing: Metrics.cardLabelGap) {
            HStack(alignment: .firstTextBaseline) {
                SettingsSectionLabel("Saved transcripts")
                Spacer()
                Label("On this Mac", systemImage: "lock")
                    .labelStyle(MediaHintLabelStyle())
            }
            .padding(.horizontal, 4)
            SettingsCard {
                if documents.isEmpty {
                    SettingsEmptyState(
                        systemImage: "doc.text",
                        title: app.mediaLibrary.isBusy ? "Your transcript will appear here" : "No transcripts yet",
                        message: "Record a meeting or import a file to get started."
                    )
                    .transition(.opacity)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(documents.enumerated()), id: \.element.id) { index, document in
                            VStack(spacing: 0) {
                                if index > 0 { SettingsCardDivider() }
                                MediaDocumentRow(
                                    document: document,
                                    canStartMedia: app.canStartMedia,
                                    isBusy: app.mediaLibrary.isBusy,
                                    onRead: { readingDocument = document },
                                    onRevise: { writingDocument = document },
                                    onAnalyze: { app.analyzeMeetingSpeakers(document) },
                                    onExport: { export(document) },
                                    onResume: { app.resumeMedia(document) },
                                    onDelete: { deleting = document }
                                )
                            }
                            .transition(.monoReveal(reduceMotion: reduceMotion))
                        }
                    }
                }
            }
            .monoAnimation(Motion.reveal, value: documents.map(\.id))
        }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            app.transcribeMediaFile(url)
        }
    }
    @available(macOS 15.0, *)
    private func loadApplications() {
        guard !loadingApplications else { return }
        loadingApplications = true
        applicationError = nil
        Task {
            defer { loadingApplications = false }
            do {
                applications = try await availableMeetingApplications()
                guard !applications.isEmpty else {
                    applicationError = String(localized: "Open your browser or calling app, then choose it here.")
                    return
                }
                presentApplicationPanel()
            } catch {
                applicationError = String(localized: "Couldn’t list apps. \(error.localizedDescription)",
                                          comment: "The argument is the system error message")
            }
        }
    }
    private func presentApplicationPanel() {
        let available = applications
        let choices = available.compactMap { application -> (String, URL)? in
            guard let url = NSRunningApplication(processIdentifier: application.processID)?.bundleURL else { return nil }
            return (application.bundleIdentifier, url.resolvingSymlinksInPath().standardizedFileURL)
        }
        let delegate = MeetingApplicationPanelDelegate(allowedURLs: Set(choices.map { $0.1 }))
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = String(localized: "Choose meeting app")
        panel.prompt = String(localized: "Choose app", comment: "Open panel confirm button for the meeting app")
        panel.message = String(localized: "Choose an open browser or calling app.")
        panel.delegate = delegate
        applicationPanel = panel
        applicationPanelDelegate = delegate
        panel.begin { response in
            defer { applicationPanel = nil; applicationPanelDelegate = nil }
            guard response == .OK, let url = panel.url?.resolvingSymlinksInPath().standardizedFileURL,
                  let choice = choices.first(where: { $0.1 == url }),
                  let selected = available.first(where: { $0.bundleIdentifier == choice.0 }),
                  let running = NSRunningApplication(processIdentifier: selected.processID), !running.isTerminated else { return }
            selectedApplicationIcon = NSWorkspace.shared.icon(forFile: url.path)
            persistMeetingApplication(selected)
            applicationError = nil
        }
    }

    @available(macOS 15.0, *)
    private func startMeeting() {
        guard savedApplicationID != nil, !loadingApplications else { return }
        applicationError = nil
        if let selectedApplication {
            beginMeeting(with: selectedApplication)
            return
        }

        loadingApplications = true
        Task {
            defer { loadingApplications = false }
            do {
                applications = try await availableMeetingApplications()
                guard let application = selectedApplication else {
                    refreshSavedApplicationState()
                    applicationError = String(localized: "Open \(meetingApplicationTitle), then start the meeting again. Your saved choice was kept.")
                    return
                }
                beginMeeting(with: application)
            } catch {
                applicationError = String(localized: "Couldn’t access \(meetingApplicationTitle). \(error.localizedDescription)",
                                          comment: "First argument: app name; second: the system error message")
            }
        }
    }

    @available(macOS 15.0, *)
    private func availableMeetingApplications() async throws -> [SCRunningApplication] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        var seen = Set<String>()
        return content.applications.filter {
            // ScreenCaptureKit also lists Dock, input services and helper processes.
            // Only user-facing apps are useful meeting sources in this picker.
            $0.bundleIdentifier != Bundle.main.bundleIdentifier
                && NSRunningApplication(processIdentifier: $0.processID)?.activationPolicy == .regular
                && MeetingApplicationPanelDelegate.isMeetingApplication($0.bundleIdentifier)
                && !$0.bundleIdentifier.isEmpty && seen.insert($0.bundleIdentifier).inserted
        }.sorted { $0.applicationName.localizedStandardCompare($1.applicationName) == .orderedAscending }
    }

    @available(macOS 15.0, *)
    private func beginMeeting(with application: SCRunningApplication) {
        persistMeetingApplication(application)
        app.recordMeeting(
            application: application,
            microphone: app.settings.data.meetingIncludeMicrophone ?? true
        )
        informedParticipants = false
    }

    private func persistMeetingApplication(_ application: SCRunningApplication) {
        var settings = app.settings.data
        settings.meetingApplicationBundleID = application.bundleIdentifier
        settings.meetingApplicationName = application.applicationName
        app.settings.data = settings
        refreshSavedApplicationState()
    }

    private func refreshSavedApplicationState() {
        guard let savedApplicationID else {
            applicationStateGeneration &+= 1
            savedApplicationIsRunning = false
            selectedApplicationIcon = nil
            return
        }
        // Off the main thread: every `NSRunningApplication` property read below is a
        // synchronous LaunchServices round trip, one per running app. On the main thread it
        // cost ~9 ms each time this page appeared, with spikes past 100 ms, right inside the
        // page transition. The generation drops a result a newer refresh has overtaken.
        applicationStateGeneration &+= 1
        let generation = applicationStateGeneration
        Task {
            let state = await Self.savedApplicationState(bundleID: savedApplicationID)
            guard generation == applicationStateGeneration else { return }
            savedApplicationIsRunning = state.isRunning
            selectedApplicationIcon = state.icon
        }
    }

    /// `NSRunningApplication` is documented as thread safe.
    nonisolated private static func savedApplicationState(bundleID: String) async -> (isRunning: Bool, icon: NSImage?) {
        await Task.detached(priority: .userInitiated) { () -> (isRunning: Bool, icon: NSImage?) in
            let runningApplications = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
            let resolvedBundleID = MeetingApplicationSelection.resolve(
                savedBundleID: bundleID,
                in: runningApplications.compactMap(\.bundleIdentifier)
            )
            let runningApplication = resolvedBundleID.flatMap { resolvedBundleID in
                runningApplications.first { $0.bundleIdentifier == resolvedBundleID }
            }
            let applicationURL = runningApplication?.bundleURL
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            return (runningApplication != nil, applicationURL.map { NSWorkspace.shared.icon(forFile: $0.path) })
        }.value
    }

    private func export(_ document: MediaDocument) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = String(localized: "Transcript", comment: "Default file name of an exported transcript")
            + ".txt"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                do {
                    try await Task.detached { try document.localizedTranscript.write(to: url, atomically: true, encoding: .utf8) }.value
                } catch { self.error = error.localizedDescription }
            }
        }
    }
}

/// The file chooser matches Writing's native app picker. Eligibility is deliberately
/// explicit: registering http/https alone also includes non-browser apps such as Codex.
@MainActor private final class MeetingApplicationPanelDelegate: NSObject, NSOpenSavePanelDelegate {
    let allowedURLs: Set<URL>
    init(allowedURLs: Set<URL>) { self.allowedURLs = allowedURLs }

    private static let browsers: Set<String> = [
            "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome",
            "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
            "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly",
            "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser",
            "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "com.kagi.kagimacOS", "app.zen-browser.zen"
        ]
    private static let callingApps: Set<String> = [
            "us.zoom.xos", "com.microsoft.teams", "com.microsoft.teams2",
            "com.cisco.webexmeetingsapp", "com.cisco.webex.meetings", "com.cisco.wx2",
            "com.tinyspeck.slackmacgap", "com.hnc.Discord", "net.whatsapp.WhatsApp",
            "org.whispersystems.signal-desktop", "ru.keepcoder.Telegram", "com.apple.FaceTime",
            "com.skype.skype"
        ]
    static func isMeetingApplication(_ bundleID: String) -> Bool {
        browsers.contains(bundleID) || callingApps.contains(bundleID)
    }

    func panel(_ sender: Any, validate url: URL) throws {
        guard allowedURLs.contains(url.resolvingSymlinksInPath().standardizedFileURL) else {
            throw NSError(domain: "Dictari.MeetingApp", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "Choose an open browser or calling app.")])
        }
    }

    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        // Keep ordinary folders navigable, but app bundles are selectable only when the
        // corresponding running app is an eligible ScreenCaptureKit audio source.
        guard url.pathExtension.lowercased() == "app" else { return true }
        return allowedURLs.contains(url.resolvingSymlinksInPath().standardizedFileURL)
    }
}

// MARK: - Local building blocks
//
// Small, page-specific pieces. Candidates for `SettingsCard.swift` / `MonoControls.swift`
// if another page needs the same thing (a monochrome checkbox, an in-card disclosure, a
// clickable card row with a hover wash).

/// Icon tile + title + one line of explanation: the top of a "do one thing" card.
private struct MediaCardHeader: View {
    let systemImage: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    var padded = true

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(Mono.primaryText)
                .frame(width: 32, height: 32)
                .background(Mono.fieldFill,
                            in: RoundedRectangle(cornerRadius: Metrics.controlRadius + 1, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Typo.cardTitle)
                Text(message)
                    .font(Typo.secondary).foregroundStyle(Mono.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 1)
        }
        .frame(maxWidth: padded ? .infinity : nil, alignment: .leading)
        .padding(padded ? Metrics.cardPadding : 0)
        .accessibilityElement(children: .combine)
    }
}

/// A quiet caption with a small leading glyph ("Use headphones…", "On this Mac").
private struct MediaHintLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Mono.tertiaryText)
            configuration.title
                .font(Typo.secondary)
                .foregroundStyle(Mono.secondaryText)
        }
    }
}

/// A full-width card row that is one big button: hover wash inset from the card edge so it
/// reads as a control, not a selection.
private struct MediaRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MediaRowButtonBody(configuration: configuration)
    }
}

private struct MediaRowButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
                    .fill(enabled && (hovered || configuration.isPressed) ? Mono.hover : Color.clear)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
            }
            .opacity(enabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
            .onHover { hovered = $0 }
            .monoAnimation(Motion.hover, value: hovered)
            .monoAnimation(Motion.press, value: configuration.isPressed)
    }
}

/// The system checkbox draws its checked state in the accent colour; this one stays ink.
private struct MediaCheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        MediaCheckbox(configuration: configuration)
    }
}

private struct MediaCheckbox: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(configuration.isOn ? Mono.ink() : Mono.card)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(configuration.isOn ? Color.clear : Mono.ink(0.30), lineWidth: 1)
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Mono.selectionText)
                        .opacity(configuration.isOn ? 1 : 0)
                        .scaleEffect(configuration.isOn ? 1 : 0.6)
                }
                .frame(width: 15, height: 15)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                configuration.label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(MonoPlainButtonStyle(scales: false))
        .monoAnimation(Motion.snap, value: configuration.isOn)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

/// A disclosure that lives inside a card row: chevron, label, and the text revealed under it.
/// Replaces `DisclosureGroup`, whose chevron takes the accent tint.
private struct MediaInlineDisclosure<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: () -> Content
    @State private var expanded = false
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(Motion.reduced(Motion.reveal, reduceMotion: reduceMotion)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(title).font(Typo.secondary.weight(.medium))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(hovered || expanded ? Mono.primaryText : Mono.secondaryText)
                .contentShape(Rectangle())
            }
            .buttonStyle(MonoPlainButtonStyle(scales: false))
            .onHover { hovered = $0 }
            .monoAnimation(Motion.hover, value: hovered)
            .accessibilityLabel(title)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")

            if expanded {
                content()
                    .padding(.leading, 15)
                    .transition(.monoReveal(reduceMotion: reduceMotion))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Metrics.cardPadding)
        .padding(.vertical, 12)
    }
}

/// One saved transcript in the list: what it is, when, how long, and its two ways in.
private struct MediaDocumentRow: View {
    let document: MediaDocument
    let canStartMedia: Bool
    let isBusy: Bool
    let onRead: () -> Void
    let onRevise: () -> Void
    let onAnalyze: () -> Void
    let onExport: () -> Void
    let onResume: () -> Void
    let onDelete: () -> Void
    @State private var moreHovered = false

    private var isMeeting: Bool { document.segments.contains { $0.source == "App audio" } }

    /// Length of the recording, from the last segment's end. Cheap: segments are ~30 s chunks.
    private var length: Double {
        document.segments.reduce(0) { max($0, $1.start + $1.duration) }
    }

    private var details: String {
        var parts = [document.created.formatted(date: .abbreviated, time: .shortened)]
        if length > 0 { parts.append(Stats.formatDuration(length)) }
        if document.status != "Completed" { parts.append(document.displayStatus) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isMeeting ? "person.2.wave.2" : "waveform")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Mono.secondaryText)
                .frame(width: 28, height: 28)
                .background(Mono.fieldFill,
                            in: RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(document.displayTitle).font(Typo.body.weight(.medium)).lineLimit(2)
                Text(details)
                    .font(Typo.secondary).monospacedDigit()
                    .foregroundStyle(Mono.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Read", action: onRead)
                .buttonStyle(MonoActionButtonStyle(.secondary, size: .small))
                .disabled(!document.hasTranscript)
            Menu {
                Button("Revise text…", action: onRevise).disabled(!document.hasTranscript || isBusy)
                if document.canAnalyzeSpeakers {
                    Button("Distinguish voices", action: onAnalyze).disabled(!canStartMedia)
                }
                Button("Export text…", action: onExport).disabled(!document.hasTranscript)
                if document.segments.contains(where: { $0.text == nil }) {
                    Button("Resume transcription", action: onResume).disabled(!canStartMedia)
                }
                Divider()
                Button("Delete…", role: .destructive, action: onDelete).disabled(isBusy)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(moreHovered ? Mono.primaryText : Mono.secondaryText)
                    .frame(width: 26, height: 24)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .background(
                RoundedRectangle(cornerRadius: Metrics.controlRadius - 1, style: .continuous)
                    .fill(moreHovered ? Mono.hover : Color.clear)
            )
            .onHover { moreHovered = $0 }
            .monoAnimation(Motion.hover, value: moreHovered)
            .help("Transcript actions").accessibilityLabel("Actions for \(document.displayTitle)")
        }
        .padding(.horizontal, Metrics.cardPadding)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Transcript sheet

private struct MediaReadingSheet: View {
    @Environment(AppCoordinator.self) private var app
    @Environment(\.dismiss) private var dismiss
    let documentID: UUID

    var body: some View {
        let document = app.mediaLibrary.documents.first(where: { $0.id == documentID })
        SettingsSheet("Transcript", subtitle: document?.displayTitle, width: 560, height: 480) {
            if let document {
                VStack(alignment: .leading, spacing: 14) {
                    if app.mediaLibrary.activeID == documentID, !document.segments.isEmpty {
                        liveProgress(document)
                    }
                    if document.canAnalyzeSpeakers {
                        speakerPanel(document)
                    }
                    ScrollView {
                        MediaTranscriptPreview(document: document)
                            .padding(Metrics.cardPadding)
                    }
                    .background(
                        RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).fill(Mono.card)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                            .strokeBorder(Mono.cardBorder, lineWidth: 0.5)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
                }
            }
        } actions: {
            MonoCopyButton {
                // One click copies the whole transcript, timestamps included, so long files
                // don't need a manual drag-select. Formatting a long transcript is a one-off
                // on click.
                guard let document else { return }
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(document.localizedTranscript, forType: .string)
            }
            .disabled(document?.segments.isEmpty ?? true)
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(MonoActionButtonStyle(.primary))
        }
    }

    /// While this document is still being transcribed, the sheet says how far along it is.
    private func liveProgress(_ document: MediaDocument) -> some View {
        let completed = document.segments.filter { $0.text != nil }.count
        return VStack(alignment: .leading, spacing: 6) {
            MonoProgressBar(value: app.mediaLibrary.isRecording
                            ? nil : Double(completed) / Double(document.segments.count))
            Text("\(completed) of \(document.segments.count) audio segments transcribed",
                 comment: "Transcription progress; plural follows the second number")
                .font(Typo.secondary).monospacedDigit().foregroundStyle(Mono.secondaryText)
                .contentTransition(.numericText())
                .monoAnimation(Motion.snap, value: completed)
        }
    }

    private func speakerPanel(_ document: MediaDocument) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button("Distinguish Voices") { app.analyzeMeetingSpeakers(document) }
                    .buttonStyle(MonoActionButtonStyle(.secondary, size: .small))
                    .disabled(!app.canStartMedia)
                Text("Optional · After recording · Up to 1 hour")
                    .font(Typo.secondary).foregroundStyle(Mono.secondaryText)
            }
            Text("First use downloads a model. Speaker labels are estimates; one block may include several voices.")
                .font(Typo.secondary).foregroundStyle(Mono.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Build long strings off-main, only when segment content changes. Status ticks and
/// other documents no longer sort and format this transcript on the UI thread.
///
/// The transcript is one `Text`, so a drag can still select across every block; each block's
/// timestamp and speaker sit on their own quieter line above the words. The plain-text
/// format (`MediaDocument.transcript`) used by Copy and Export is unchanged.
private struct MediaTranscriptPreview: View {
    let document: MediaDocument
    @State private var blocks: [Block] = []
    @State private var text = AttributedString()
    @State private var loaded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    struct Block: Sendable, Equatable {
        let time: String
        let speaker: String
        let text: String
    }

    var body: some View {
        Group {
            if blocks.isEmpty {
                HStack(spacing: 8) {
                    if !loaded || isPending { ProgressView().controlSize(.small) }
                    Text("Waiting for transcription…")
                        .font(Typo.body).foregroundStyle(Mono.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
            } else {
                Text(text)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .monoAnimation(Motion.swap, value: blocks.isEmpty)
        .task(id: document.segments) {
            let segments = document.segments
            // Both the blocks and the styled string are built off the main actor: for a
            // four-hour recording the AttributedString alone is thousands of styled runs.
            let (value, styled) = await Task.detached(priority: .utility) {
                let value = Self.blocks(from: segments)
                return (value, Self.attributed(value))
            }.value
            guard !Task.isCancelled else { return }
            text = styled
            blocks = value
            loaded = true
        }
    }

    /// Any segment still without text means work is pending for this document.
    private var isPending: Bool {
        document.segments.contains { $0.text == nil && $0.error == nil }
    }

    /// Mirrors `MediaDocument.localizedTranscript`: same order, same timestamp format, same labels.
    nonisolated private static func blocks(from segments: [MediaSegment]) -> [Block] {
        segments.sorted { $0.start < $1.start }.compactMap { segment in
            guard let text = segment.text, !text.isEmpty else { return nil }
            let seconds = Int(max(0, segment.start))
            let time = String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            return Block(time: time, speaker: segment.localizedSpeakerLabel, text: text)
        }
    }

    nonisolated private static func attributed(_ blocks: [Block]) -> AttributedString {
        var result = AttributedString()
        for (index, block) in blocks.enumerated() {
            var header = AttributedString((index == 0 ? "" : "\n\n") + block.time)
            header.font = Typo.mono
            header.foregroundColor = Mono.tertiaryText
            var speaker = AttributedString("   " + block.speaker + "\n")
            speaker.font = Typo.secondary.weight(.semibold)
            speaker.foregroundColor = Mono.secondaryText
            var body = AttributedString(block.text)
            body.font = Typo.body
            body.foregroundColor = Mono.primaryText
            result += header
            result += speaker
            result += body
        }
        return result
    }
}
