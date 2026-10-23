// DictationRecoveryStore.swift
// Dictari — durable local recovery for dictations that did not reach their destination.

import Foundation

/// Why a captured dictation still needs attention.
enum DictationRecoveryState: String, Codable, Sendable {
    /// The local transcription engine did not produce a transcript; retry from saved PCM.
    case transcriptionFailed
    /// A transcript exists but could not be reliably inserted; retry or copy it later.
    case injectionFailed
    /// A successful transcript and its audio remain available until the user deletes the recording
    /// or `DictationRecoveryRetentionPolicy` ages it out (the text itself lives on in History).
    case transcribed
    /// The record directory is still present, but its metadata cannot be decoded. Keep a visible
    /// diagnostic row so a damaged safety copy never looks as though it disappeared.
    case metadataDamaged
}

/// Metadata shown when offering a saved dictation for recovery.
struct DictationRecovery: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    let durationSeconds: Double
    let language: String
    let modelID: String
    let appName: String?
    let appBundleID: String?
    var state: DictationRecoveryState
    var failureDescription: String
    var transcript: String?
}

extension DictationRecovery {
    /// `failureDescription` is persisted, and `HistoryTimeline` matches it by English substring
    /// ("no speech", "too far", "fail") to pair a recovery with its History entry. It therefore
    /// stays the English text the app wrote; screens show this translation instead. Text that
    /// is not one of the app's own phrases (a system or engine error message) is shown as stored.
    var displayFailureDescription: String {
        Self.localizedFailureDescription(failureDescription)
    }

    static func localizedFailureDescription(_ stored: String) -> String {
        switch stored {
        case "No audio from the mic":
            String(localized: "No audio from the mic", comment: "Dictation failure: the microphone delivered silence")
        case "Too far from the mic":
            String(localized: "Too far from the mic", comment: "Dictation failure: the voice was too quiet")
        case "No speech detected":
            String(localized: "No speech detected", comment: "Dictation failure: nothing was said")
        case "Model still loading":
            String(localized: "Model still loading", comment: "Dictation failure: the transcription model is not ready yet")
        case "Model not ready":
            String(localized: "Model not ready", comment: "Dictation failure: the transcription model is not ready")
        case "Transcription did not finish":
            String(localized: "Transcription did not finish", comment: "Saved recording status")
        case "Transcribed":
            String(localized: "Transcribed", comment: "Saved recording status: a transcript exists")
        case "Transcribed and copied":
            String(localized: "Transcribed and copied", comment: "Saved recording status")
        case "Typed live into the focused field":
            String(localized: "Typed live into the focused field", comment: "Saved recording status")
        case "Typed live; check the text before pressing Return":
            String(localized: "Typed live; check the text before pressing Return", comment: "Saved recording status")
        case "Live typing interrupted; transcript copied":
            String(localized: "Live typing interrupted; transcript copied", comment: "Saved recording status")
        case "Live typing interrupted; copy failed":
            String(localized: "Live typing interrupted; copy failed", comment: "Saved recording status")
        case "Paste could not be verified":
            String(localized: "Paste could not be verified", comment: "Saved recording status")
        case "Paste unverified; check the text before pressing Return":
            String(localized: "Paste unverified; check the text before pressing Return", comment: "Saved recording status")
        case "Could not insert; transcript copied":
            String(localized: "Could not insert; transcript copied", comment: "Saved recording status")
        case "Secure field blocked insertion; transcript copied":
            String(localized: "Secure field blocked insertion; transcript copied", comment: "Saved recording status")
        case "Clipboard write failed":
            String(localized: "Clipboard write failed", comment: "Saved recording status")
        case "Saved recording audio is missing or damaged":
            String(localized: "Saved recording audio is missing or damaged", comment: "Saved recording status")
        case "Saved recording metadata is damaged; audio remains on this Mac":
            String(localized: "Saved recording metadata is damaged; audio remains on this Mac", comment: "Saved recording status")
        case "Saved recording metadata and audio are damaged":
            String(localized: "Saved recording metadata and audio are damaged", comment: "Saved recording status")
        default:
            stored
        }
    }
}

/// One recovery record together with its original 16 kHz mono Float32 PCM samples.
struct DictationRecoveryPayload: Sendable {
    let recovery: DictationRecovery
    let samples: [Float]
}

/// Metadata-only startup snapshot plus a non-destructive warning if the recovery directory itself
/// could not be listed. A listing failure must not be presented as an empty recovery history.
struct DictationRecoveryListing: Sendable {
    let recoveries: [DictationRecovery]
    let warning: String?
}

/// File-backed recovery store. Each record lives in its own directory until confirmed delivery,
/// explicit deletion or (for records that already have a transcript) bounded retention, so adding a capture is one directory rename: a crash cannot leave a
/// visible JSON file without its PCM.
struct DictationRecoveryStore {

    enum StoreError: LocalizedError, Equatable {
        case missing(UUID)
        case malformedAudio(UUID)

        var errorDescription: String? {
            switch self {
            case .missing(let id):
                return String(localized: "Saved dictation \(id.uuidString) was not found",
                              comment: "Saved recording error; the argument is an identifier")
            case .malformedAudio(let id):
                return String(localized: "Saved dictation \(id.uuidString) has invalid audio",
                              comment: "Saved recording error; the argument is an identifier")
            }
        }
    }

    static let sampleRate = 16_000

    /// Store instances are deliberately short-lived, so serialize their file transactions here
    /// rather than relying on each caller to coordinate a read-modify-write sequence.
    private static let fileLock = NSLock()
    /// A normal pre-rename save lasts milliseconds; waiting five minutes avoids deleting a
    /// temporary directory owned by another active instance during startup cleanup.
    private static let interruptedTemporaryDirectoryMinimumAge: TimeInterval = 5 * 60

    private let rootURL: URL
    private let fileManager: FileManager

    /// The caller chooses the root so production uses Application Support and tests use a
    /// fresh temporary directory without touching any user data.
    init(rootURL: URL, fileManager: FileManager = .default) throws {
        self.rootURL = rootURL
        self.fileManager = fileManager
        Self.fileLock.lock()
        defer { Self.fileLock.unlock() }
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        removeInterruptedTemporaryDirectoriesLocked()
    }

    /// Saves one complete capture and makes it visible only after both metadata and PCM exist.
    @discardableResult
    func save(
        samples: [Float],
        durationSeconds: Double,
        language: String,
        modelID: String,
        appName: String? = nil,
        appBundleID: String? = nil,
        state: DictationRecoveryState,
        failureDescription: String,
        transcript: String? = nil,
        createdAt: Date = Date()
    ) throws -> DictationRecovery {
        Self.fileLock.lock()
        defer { Self.fileLock.unlock() }

        let recovery = DictationRecovery(
            id: UUID(),
            createdAt: createdAt,
            durationSeconds: durationSeconds,
            language: language,
            modelID: modelID,
            appName: appName,
            appBundleID: appBundleID,
            state: state,
            failureDescription: failureDescription,
            transcript: transcript
        )
        let temporaryURL = rootURL.appendingPathComponent(".\(recovery.id.uuidString).tmp-\(UUID().uuidString)")
        let finalURL = directoryURL(for: recovery.id)

        try fileManager.createDirectory(at: temporaryURL, withIntermediateDirectories: false)
        do {
            try Self.encode(samples).write(to: temporaryURL.appendingPathComponent("audio.pcm"), options: .atomic)
            try JSONEncoder().encode(recovery).write(to: temporaryURL.appendingPathComponent("metadata.json"), options: .atomic)
            try fileManager.moveItem(at: temporaryURL, to: finalURL)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
        return recovery
    }

    /// Lists recoveries newest first without loading their audio payloads.
    func recoveries() throws -> [DictationRecovery] {
        Self.fileLock.lock()
        defer { Self.fileLock.unlock() }

        return try recoveriesLocked()
    }

    /// Launch-time retention: removes only the records `DictationRecoveryRetentionPolicy` marks
    /// disposable (a transcript already exists elsewhere), then returns the surviving listing so
    /// the caller pays for one directory scan instead of two.
    func applyRetention(
        now: Date = Date(),
        protecting protectedIDs: Set<UUID> = []
    ) throws -> (remaining: [DictationRecovery], deleted: [UUID]) {
        Self.fileLock.lock()
        defer { Self.fileLock.unlock() }

        let listing = try recoveriesLocked()
        let prune = Set(DictationRecoveryRetentionPolicy.idsToPrune(
            listing, now: now, protecting: protectedIDs
        ))
        var deleted: [UUID] = []
        for id in prune {
            // A failed removal keeps the record visible; retention must never hide surviving PCM.
            if (try? fileManager.removeItem(at: directoryURL(for: id))) != nil { deleted.append(id) }
        }
        let deletedSet = Set(deleted)
        return (listing.filter { !deletedSet.contains($0.id) }, deleted)
    }

    private func recoveriesLocked() throws -> [DictationRecovery] {
        let directories = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return directories.compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            let audio = audioFileStatus(at: url.appendingPathComponent("audio.pcm"))
            if var recovery = try? loadMetadata(at: url) {
                guard audio.isValid else {
                    recovery.state = .metadataDamaged
                    recovery.failureDescription = "Saved recording audio is missing or damaged"
                    return recovery
                }
                return recovery
            }

            // A final recovery directory is named with its record UUID. If its JSON is damaged,
            // retain that identity and derive only display-safe facts from the filesystem. Retry
            // stays disabled, but the user can see that audio remains and explicitly delete it.
            guard let id = UUID(uuidString: url.lastPathComponent) else { return nil }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            let duration = Double(audio.byteCount) /
                Double(MemoryLayout<Float>.size * Self.sampleRate)
            return DictationRecovery(
                id: id,
                createdAt: values?.contentModificationDate ?? .distantPast,
                durationSeconds: duration,
                language: "auto",
                modelID: "unknown",
                appName: nil,
                appBundleID: nil,
                state: .metadataDamaged,
                failureDescription: audio.isValid
                    ? "Saved recording metadata is damaged; audio remains on this Mac"
                    : "Saved recording metadata and audio are damaged",
                transcript: nil
            )
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    /// Makes a completed transcript durable while retaining its original audio until explicit
    /// deletion, so inaccurate results can be retried later.
    @discardableResult
    func markTranscribed(_ id: UUID, transcript: String) throws -> DictationRecovery {
        Self.fileLock.lock()
        defer { Self.fileLock.unlock() }

        return try updateLocked(
            id,
            state: .transcribed,
            failureDescription: "Transcribed",
            transcript: transcript
        )
    }

    /// Reloads the exact capture bytes for a retry.
    func load(_ id: UUID) throws -> DictationRecoveryPayload {
        Self.fileLock.lock()
        defer { Self.fileLock.unlock() }

        return try loadLocked(id)
    }

    private func loadLocked(_ id: UUID) throws -> DictationRecoveryPayload {
        let directory = directoryURL(for: id)
        guard fileManager.fileExists(atPath: directory.path) else { throw StoreError.missing(id) }
        let recovery = try loadMetadata(at: directory)
        let data = try Data(contentsOf: directory.appendingPathComponent("audio.pcm"))
        return DictationRecoveryPayload(recovery: recovery, samples: try Self.decode(data, id: id))
    }

    /// Updates the recoverable outcome while retaining the original audio until explicit deletion.
    @discardableResult
    func update(
        _ id: UUID,
        state: DictationRecoveryState,
        failureDescription: String,
        transcript: String?
    ) throws -> DictationRecovery {
        Self.fileLock.lock()
        defer { Self.fileLock.unlock() }

        return try updateLocked(id, state: state, failureDescription: failureDescription, transcript: transcript)
    }

    private func updateLocked(
        _ id: UUID,
        state: DictationRecoveryState,
        failureDescription: String,
        transcript: String?
    ) throws -> DictationRecovery {
        let directory = directoryURL(for: id)
        guard fileManager.fileExists(atPath: directory.path) else { throw StoreError.missing(id) }
        var recovery = try loadMetadata(at: directory)
        recovery.state = state
        recovery.failureDescription = failureDescription
        recovery.transcript = transcript
        try JSONEncoder().encode(recovery).write(to: directory.appendingPathComponent("metadata.json"), options: .atomic)
        return recovery
    }

    /// Called after confirmed delivery or an explicit user deletion.
    func delete(_ id: UUID) throws {
        Self.fileLock.lock()
        defer { Self.fileLock.unlock() }

        let directory = directoryURL(for: id)
        guard fileManager.fileExists(atPath: directory.path) else { throw StoreError.missing(id) }
        try fileManager.removeItem(at: directory)
    }

    /// Batch removal for retention after an upsert. Returns the IDs actually removed (or already
    /// absent), so the caller drops exactly those from its in-memory snapshot.
    func delete(_ ids: [UUID]) -> [UUID] {
        Self.fileLock.lock()
        defer { Self.fileLock.unlock() }

        return ids.filter { id in
            let directory = directoryURL(for: id)
            guard fileManager.fileExists(atPath: directory.path) else { return true }
            return (try? fileManager.removeItem(at: directory)) != nil
        }
    }

    private func directoryURL(for id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// A save writes into `.<record UUID>.tmp-<writer UUID>` before the final directory rename.
    /// Only that private shape is eligible for cleanup; unrelated hidden files are left alone.
    private func removeInterruptedTemporaryDirectoriesLocked() {
        guard let items = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: []
        ) else { return }
        let now = Date()
        for item in items {
            guard let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey]),
                  values.isDirectory == true,
                  let modificationDate = values.contentModificationDate,
                  now.timeIntervalSince(modificationDate) >= Self.interruptedTemporaryDirectoryMinimumAge
            else { continue }
            guard Self.isInterruptedTemporaryDirectory(item.lastPathComponent) else { continue }
            try? fileManager.removeItem(at: item)
        }
    }

    private static func isInterruptedTemporaryDirectory(_ name: String) -> Bool {
        guard name.hasPrefix("."), let separator = name.range(of: ".tmp-") else { return false }
        let recordID = String(name[name.index(after: name.startIndex)..<separator.lowerBound])
        let writerID = String(name[separator.upperBound...])
        return UUID(uuidString: recordID) != nil && UUID(uuidString: writerID) != nil
    }

    private func loadMetadata(at directory: URL) throws -> DictationRecovery {
        try JSONDecoder().decode(DictationRecovery.self, from: Data(contentsOf: directory.appendingPathComponent("metadata.json")))
    }

    /// Listing checks the cheap filesystem contract before advertising a record as retryable.
    /// Zero-length PCM is valid (the no-audio path saves it), but a missing/non-regular,
    /// unreadable or non-Float-aligned payload is a diagnostic record only.
    private func audioFileStatus(at url: URL) -> (isValid: Bool, byteCount: Int) {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let byteCount = values.fileSize,
              fileManager.isReadableFile(atPath: url.path),
              byteCount.isMultiple(of: MemoryLayout<Float>.size)
        else { return (false, 0) }
        return (true, byteCount)
    }

    private static func encode(_ samples: [Float]) -> Data {
        samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func decode(_ data: Data, id: UUID) throws -> [Float] {
        guard data.count.isMultiple(of: MemoryLayout<Float>.size) else { throw StoreError.malformedAudio(id) }
        var samples = [Float](repeating: 0, count: data.count / MemoryLayout<Float>.size)
        _ = samples.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return samples
    }
}

/// Bounds disk use for recordings whose words are already safe elsewhere.
///
/// Every delivery that cannot be *confirmed* (Terminal, Electron apps never confirm a paste) keeps
/// its PCM, so without a bound the folder grows by megabytes per day. Only records that already
/// carry a transcript are eligible: that text is in History and was pasted or copied, so the audio
/// is a convenience for re-transcription, not the only copy of what was said. A capture that never
/// produced a transcript (`transcriptionFailed`) or whose metadata is damaged is the user's only
/// copy of their speech and is never removed automatically — only by explicit deletion.
enum DictationRecoveryRetentionPolicy {
    static let maximumTranscribedRecordings = 20
    static let maximumTranscribedAge: TimeInterval = 7 * 24 * 60 * 60

    static func isDisposable(_ recovery: DictationRecovery) -> Bool {
        switch recovery.state {
        case .injectionFailed, .transcribed:
            guard let transcript = recovery.transcript else { return false }
            return !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .transcriptionFailed, .metadataDamaged:
            return false
        }
    }

    /// Returns the disposable records beyond the newest `maximumCount` or older than `maximumAge`.
    /// Protected IDs (a record being retried or just written) are never returned but still occupy
    /// one of the kept slots, so the bound holds without deleting what the user is acting on.
    static func idsToPrune(
        _ recoveries: [DictationRecovery],
        now: Date,
        protecting protectedIDs: Set<UUID> = [],
        maximumCount: Int = maximumTranscribedRecordings,
        maximumAge: TimeInterval = maximumTranscribedAge
    ) -> [UUID] {
        let candidates = recoveries.filter(isDisposable).sorted {
            $0.createdAt == $1.createdAt ? $0.id.uuidString > $1.id.uuidString : $0.createdAt > $1.createdAt
        }
        // Protected records claim their slots first, wherever they fall in age order.
        var kept = candidates.lazy.filter { protectedIDs.contains($0.id) }.count
        var prune: [UUID] = []
        for recovery in candidates where !protectedIDs.contains(recovery.id) {
            // A future timestamp (clock moved backwards) counts as fresh rather than expired.
            let expired = now.timeIntervalSince(recovery.createdAt) > maximumAge
            if expired || kept >= maximumCount {
                prune.append(recovery.id)
            } else {
                kept += 1
            }
        }
        return prune
    }
}
