import Foundation
import Observation
import ScreenCaptureKit

@MainActor @Observable
final class MediaLibrary {
    private(set) var documents: [MediaDocument] = []
    private(set) var isBusy = false
    private(set) var isRecording = false
    private(set) var isAnalyzingSpeakers = false
    private(set) var speakerAnalysisProgress: Double?
    @ObservationIgnored private let speakerAnalyzer: any MeetingSpeakerAnalyzing
    @ObservationIgnored private var segmentWaiter: CheckedContinuation<Void, Never>?
    private(set) var activeID: UUID?
    private var captureFailed = false
    private(set) var message: String?
    @ObservationIgnored private let archive: MediaArchive
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var capture: AnyObject?
    @ObservationIgnored private var stopTask: Task<[MediaSegment], Never>?
    private(set) var waitingForEngine = false
    @ObservationIgnored private var pendingOperations = Set<UUID>()
    @ObservationIgnored private let inferenceTimeout: Duration
    @ObservationIgnored private var loadGeneration = UUID()
    @ObservationIgnored var onFinished: (() -> Void)?

    init(archive: MediaArchive = MediaArchive(), inferenceTimeout: Duration = .seconds(60),
         speakerAnalyzer: any MeetingSpeakerAnalyzing = FluidMeetingSpeakerAnalyzer()) {
        self.speakerAnalyzer = speakerAnalyzer
        self.archive = archive
        self.inferenceTimeout = inferenceTimeout
    }

    func load() {
        guard !isBusy else { return }
        let archive = archive
        let token = UUID()
        loadGeneration = token
        Task {
            do {
                let values = try await Task.detached { try archive.list().map { try archive.recoverSegments($0) } }.value
                guard !isBusy, loadGeneration == token else { return }
                documents = values.map { document in
                    var recovered = document
                    if recovered.status != "Completed" && recovered.status != "No audio" {
                        recovered.status = "Interrupted — saved audio available"
                    }
                    return recovered
                }
            } catch { message = error.localizedDescription }
        }
    }

    func startFile(_ url: URL, engine: any TranscriptionEngine, language: String, corrector: VocabularyCorrector) {
        guard !isBusy else { return }
        let document = MediaDocument(title: url.deletingPathExtension().lastPathComponent, language: language)
        begin(document)
        worker = Task { [self] in
            do {
                try await persist()
                let archive = archive
                let decoder = Task.detached(priority: .utility) { try await MediaFileDecoder.decode(url: url, document: document, archive: archive) }
                let decoded = try await withTaskCancellationHandler { try await decoder.value } onCancel: { decoder.cancel() }
                replace(decoded)
                try await process(engine: engine, corrector: corrector)
            } catch { await fail(error) }
            finish()
        }
    }

    @available(macOS 15.0, *)
    func startMeeting(application: SCRunningApplication, microphone: Bool, engine: any TranscriptionEngine, language: String, corrector: VocabularyCorrector) {
        guard !isBusy else { return }
        // Stored in English on purpose (see `MediaDocument.displayTitle`): the title is saved
        // data, and the interface language can change after the meeting.
        let document = MediaDocument(title: "Meeting — " + application.applicationName, language: language)
        begin(document)
        worker = Task { [self] in
            do {
                try await persist()
                let recorder = MeetingCapture(archive: archive, documentID: document.id, onSegment: { [weak self] segment in
                    Task { @MainActor [weak self] in self?.append(segment, documentID: document.id) }
                }, onError: { [weak self] error in
                    Task { @MainActor [weak self] in
                        guard let self, self.activeID == document.id else { return }
                        self.message = error
                        self.captureFailed = true
                        await self.stopMeeting()
                    }
                })
                capture = recorder
                try await recorder.start(application: application, microphone: microphone)
                try Task.checkCancellation()
                guard !captureFailed else { throw MediaArchiveError.decodeFailed }
                isRecording = true
                try await process(engine: engine, corrector: corrector)
            } catch {
                await stopMeeting()
                await fail(error)
            }
            finish()
        }
    }

    func resume(_ document: MediaDocument, engine: any TranscriptionEngine, corrector: VocabularyCorrector) {
        guard !isBusy else { return }
        var restored = document
        for index in restored.segments.indices where restored.segments[index].text == nil { restored.segments[index].error = nil }
        begin(restored)
        worker = Task { [self] in
            do { try await process(engine: engine, corrector: corrector) }
            catch { await fail(error) }
            finish()
        }
    }

    func analyzeSpeakers(_ document: MediaDocument) {
        guard !isBusy, document.canAnalyzeSpeakers else { return }
        begin(document)
        isAnalyzingSpeakers = true
        let analyzer = speakerAnalyzer
        let generation = loadGeneration
        let archive = archive
        worker = Task { [self] in
            do {
                let labels = try await analyzer.analyze(archive: archive, document: document) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.isAnalyzingSpeakers, self.activeID == document.id, self.loadGeneration == generation,
                              self.worker?.isCancelled == false else { return }
                        self.speakerAnalysisProgress = min(1, max(0, progress))
                    }
                }
                try Task.checkCancellation()
                var updated = document
                for index in updated.segments.indices where updated.segments[index].source == "App audio" {
                    updated.segments[index].speakerIndices = labels[updated.segments[index].id] ?? []
                }
                // Commit the whole annotation pass together. Failure/cancellation leaves
                // the saved transcript and PCM intact, including any previous labels.
                let snapshot = updated
                try await Task.detached(priority: .utility) { try archive.save(snapshot) }.value
                replace(updated)
                message = String(localized: "Voice analysis complete. Speaker labels are estimates; shared blocks may contain several voices.")
            } catch {
                message = error is CancellationError
                    ? String(localized: "Voice analysis stopped. Your transcript and audio are unchanged.")
                    : error.localizedDescription
            }
            finish()
        }
    }

    func stopMeeting() async {
        // Keep recording true until capture has flushed its last chunks.
        if stopTask == nil, #available(macOS 15.0, *), let recorder = capture as? MeetingCapture {
            capture = nil
            stopTask = Task { await recorder.stop() }
        }
        if let stopTask {
            for segment in await stopTask.value {
                if let activeID { append(segment, documentID: activeID) }
            }
        }
        isRecording = false
        wakeSegmentWaiter()
    }

    func cancel() {
        message = String(localized: "Stopping after the current operation. Saved audio remains available.")
        worker?.cancel()
        wakeSegmentWaiter()
    }

    func delete(_ document: MediaDocument) async {
        guard !isBusy else { return }
        do {
            loadGeneration = UUID()
            let archive = archive
            try await Task.detached { try archive.delete(document.id) }.value
            documents.removeAll { $0.id == document.id }
        } catch { message = error.localizedDescription }
    }

    private func begin(_ document: MediaDocument) {
        loadGeneration = UUID()
        waitingForEngine = false
        isAnalyzingSpeakers = false
        speakerAnalysisProgress = nil
        isBusy = true
        activeID = document.id
        message = nil
        stopTask = nil
        captureFailed = false
        replace(document)
    }
    private func replace(_ document: MediaDocument) {
        if let index = documents.firstIndex(where: { $0.id == document.id }) { documents[index] = document }
        else { documents.insert(document, at: 0) }
    }
    private func append(_ segment: MediaSegment, documentID: UUID) {
        guard isBusy, activeID == documentID, let index = documents.firstIndex(where: { $0.id == documentID }),
              !documents[index].segments.contains(where: { $0.id == segment.id }) else { return }
        documents[index].segments.append(segment)
        wakeSegmentWaiter()
    }
    private var activeIndex: Int? { documents.firstIndex { $0.id == activeID } }

    private func persist() async throws {
        guard let index = activeIndex else { return }
        let snapshot = documents[index]
        let archive = archive
        try await Task.detached(priority: .utility) { try archive.save(snapshot) }.value
    }

    /// A single inference at a time. Never re-transcribe the growing meeting from the start.
    private func process(engine: any TranscriptionEngine, corrector: VocabularyCorrector) async throws {
        while let index = activeIndex {
            try Task.checkCancellation()
            if let next = documents[index].segments.firstIndex(where: { $0.text == nil && $0.error == nil }) {
                documents[index].status = isRecording ? "Recording and transcribing" : "Transcribing"
                let segment = documents[index].segments[next]
                let document = documents[index]
                let archive = archive
                let samples = try await Task.detached { try archive.samples(segment, documentID: document.id) }.value
                if MediaAudioActivity.isDigitalSilence(samples) {
                    documents[index].segments[next].text = ""
                    try await persist()
                    continue
                }
                do {
                    let token = UUID()
                    pendingOperations.insert(token)
                    let text = try await TranscriptionDeadline.run(for: inferenceTimeout, onOperationFinished: { [weak self] in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.pendingOperations.remove(token)
                            if self.worker == nil && self.pendingOperations.isEmpty && self.isBusy { self.finish() }
                        }
                    }) {
                        try await engine.transcribe(samples: samples, language: document.language)
                    }
                    try Task.checkCancellation()
                    documents[index].segments[next].text = corrector.correct(text).trimmingCharacters(in: .whitespacesAndNewlines)
                    try await persist()
                } catch {
                    documents[index].segments[next].error = error.localizedDescription
                    throw error
                }
            } else if isRecording {
                documents[index].status = "Recording — waiting for next audio segment"
                // Capture callbacks wake the worker. Silence causes no periodic task
                // wakeups and no inference until a real segment arrives or recording stops.
                await withCheckedContinuation { segmentWaiter = $0 }
            } else {
                documents[index].status = captureFailed ? "Interrupted — capture error" : (documents[index].segments.isEmpty ? "No audio" : "Completed")
                try await persist()
                return
            }
        }
    }
    private func fail(_ error: Error) async {
        message = error is CancellationError
            ? String(localized: "Stopped. You can resume the saved audio.", comment: "Files & Meetings: processing was cancelled")
            : error.localizedDescription
        guard let index = activeIndex else { return }
        let archive = archive
        let snapshot = documents[index]
        if let recovered = try? await Task.detached(operation: { try archive.recoverSegments(snapshot) }).value { replace(recovered) }
        if let index = activeIndex { documents[index].status = "Interrupted — audio retained" }
        do { try await persist() } catch {
            message = String(localized: "Could not save the transcript: \(error.localizedDescription). Audio chunks remain in the archive folder.")
        }
    }
    private func wakeSegmentWaiter() {
        let waiter = segmentWaiter
        segmentWaiter = nil
        waiter?.resume()
    }

    private func finish() {
        worker = nil
        // Deadline/cancel finishes the UI operation, not necessarily native inference.
        // Keep the shared engine quarantined until its completion callback arrives.
        guard pendingOperations.isEmpty else {
            waitingForEngine = true
            let reason = message ?? String(localized: "Transcription stopped.")
            message = String(localized: "\(reason) Waiting for the model to stop. If it remains stuck, quit and reopen Dictari, then resume the saved audio.",
                             comment: "The argument is the previous message (why processing stopped)")
            return
        }
        if waitingForEngine { message = String(localized: "Model stopped. You can resume the saved audio.") }
        waitingForEngine = false
        isBusy = false
        isAnalyzingSpeakers = false
        speakerAnalysisProgress = nil
        wakeSegmentWaiter()
        isRecording = false
        activeID = nil
        worker = nil
        onFinished?()
    }
}
