// VocabularyStore.swift
// Dictari — persistence for the user's custom vocabulary.
// Local JSON in ~/Library/Application Support/Dictari/, same idiom as SettingsStore.

import Foundation
import Observation

extension AppPaths {
    static let vocabulary = support.appendingPathComponent("vocabulary.json")
}

/// Observable list of vocabulary terms. Every mutation persists.
///
/// Holds a prebuilt `corrector` because the transcription path wants one synchronously and
/// compiling the terms is the only non-trivial cost in the feature. Rebuilding it here — once
/// per edit, in settings — keeps that cost off the stop→inject path entirely.
@MainActor
@Observable
final class VocabularyStore {

    private(set) var terms: [VocabularyTerm] = []

    /// Ready to use on the transcription path: `store.corrector.correct(transcript)`.
    private(set) var corrector = VocabularyCorrector(terms: [])

    /// `nil` builds an in-memory store that never touches disk (previews, tests).
    private let url: URL?
    @ObservationIgnored private let saveQueue = DispatchQueue(label: "Dictari.vocabulary.persistence", qos: .utility)
    @ObservationIgnored private var saveRevision = 0
    private(set) var persistenceError: String?
    private(set) var loadWarning: String?
    @ObservationIgnored private var savingBlocked = false

    struct ImportSummary {
        let added: Int
        let merged: Int
    }

    private struct Archive: Codable {
        let format: String
        let version: Int
        let terms: [VocabularyTerm]
    }

    enum TransferError: LocalizedError {
        case invalidFile
        case unsupportedVersion
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .invalidFile:
                String(localized: "Choose a valid Dictari vocabulary JSON file. No words were imported.",
                       comment: "Vocabulary import error")
            case .unsupportedVersion:
                String(localized: "This vocabulary needs a newer version of Dictari. No words were imported.",
                       comment: "Vocabulary import error")
            case .tooLarge:
                String(localized: "This file exceeds the import limit (2 MB or 5,000 words). No words were imported.",
                       comment: "Vocabulary import error")
            }
        }
    }

    static let maximumImportBytes = 2 * 1024 * 1024

    func exportData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Archive(format: "dictari-vocabulary", version: 1, terms: terms))
    }

    /// Validate the whole file before changing anything. Existing spelling, identity and
    /// enabled state win; imported alternatives are an additive union.
    func importData(_ data: Data) throws -> ImportSummary {
        guard data.count <= Self.maximumImportBytes else { throw TransferError.tooLarge }
        let imported: [VocabularyTerm]
        do {
            if let archive = try? JSONDecoder().decode(Archive.self, from: data) {
                guard archive.format == "dictari-vocabulary" else { throw TransferError.invalidFile }
                guard archive.version == 1 else { throw TransferError.unsupportedVersion }
                imported = archive.terms
            } else {
                // Also accept the original local vocabulary.json array for existing backups.
                imported = try JSONDecoder().decode([VocabularyTerm].self, from: data)
            }
        } catch let error as TransferError { throw error }
        catch { throw TransferError.invalidFile }
        guard imported.count <= 5_000 else { throw TransferError.tooLarge }
        guard imported.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw TransferError.invalidFile
        }
        var next = terms
        var indices: [String: Int] = [:]
        for (index, term) in next.enumerated() {
            let key = VocabularyCorrector.normalize(term.text)
            if indices[key] == nil { indices[key] = index }
        }
        var added = 0, merged = 0
        for var term in imported {
            term.text = term.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = VocabularyCorrector.normalize(term.text)
            if let index = indices[key] {
                next[index].alternatives = Self.mergedAlternatives(next[index].alternatives, term.alternatives)
                merged += 1
            } else {
                // Archive IDs belong to the exporting store; never create duplicate row IDs.
                term.id = UUID()
                term.alternatives = Self.mergedAlternatives([], term.alternatives)
                indices[key] = next.count
                next.append(term)
                added += 1
            }
        }
        if next != terms {
            terms = next
            commit()
        }
        return ImportSummary(added: added, merged: merged)
    }

    /// Wait behind all queued writes without blocking the main actor (also used by tests).
    func waitForPendingSaves() async {
        await withCheckedContinuation { continuation in
            saveQueue.async { continuation.resume() }
        }
    }

    /// Persist the current snapshot and report this write's result directly to the caller.
    /// Agent approvals need a durable acknowledgement before their proposal can become approved;
    /// observing `persistenceError` after a queue barrier is racy because the UI update is a
    /// separate MainActor task.
    func flushPendingSaves() async throws {
        guard let url else { return }
        guard !savingBlocked else { throw VocabularyPersistenceError.blocked }
        let snapshot = terms
        let message: String? = await withCheckedContinuation { continuation in
            saveQueue.async {
                do {
                    let encoded = try JSONEncoder().encode(snapshot)
                    try encoded.write(to: url, options: .atomic)
                    continuation.resume(returning: nil)
                } catch {
                    continuation.resume(returning: error.localizedDescription)
                }
            }
        }
        persistenceError = message.map { Self.unsavedMessage($0) }
        if let message { throw VocabularyPersistenceError.write(message) }
    }

    init(url: URL? = AppPaths.vocabulary) {
        self.url = url
        load()
        corrector = VocabularyCorrector(terms: terms)
    }

    /// In-memory store seeded with terms. Previews and tests only.
    convenience init(terms: [VocabularyTerm]) {
        self.init(url: nil)
        self.terms = terms
        corrector = VocabularyCorrector(terms: terms)
    }

    // MARK: - Mutations

    func add(_ term: VocabularyTerm) {
        let text = term.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // Adding a word you already have should feel like nothing happened, not like a
        // duplicate row appearing at the bottom of a list you have to go clean up.
        if let existing = terms.firstIndex(where: { $0.text.compare(text, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
            var merged = terms[existing]
            merged.enabled = true
            merged.alternatives = Self.mergedAlternatives(merged.alternatives, term.alternatives)
            terms[existing] = merged
        } else {
            var stored = term
            stored.text = text
            terms.append(stored)
        }
        commit()
    }

    func update(_ term: VocabularyTerm) {
        guard let index = terms.firstIndex(where: { $0.id == term.id }) else { return }
        var stored = term
        stored.text = term.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stored.text.isEmpty else { return }
        stored.alternatives = Self.mergedAlternatives([], term.alternatives)
        terms[index] = stored
        commit()
    }

    /// Remembers a scan suggestion the user dismissed, so the next scan does not offer it again.
    func dismissSuggestion(_ phrase: String, for termID: UUID) {
        guard let index = terms.firstIndex(where: { $0.id == termID }) else { return }
        let key = VocabularySuggestions.key(phrase)
        guard !key.isEmpty,
              !terms[index].dismissed.contains(where: { VocabularySuggestions.key($0) == key }) else { return }
        terms[index].dismissed.append(phrase)
        commit()
    }

    enum LearnOutcome: Equatable {
        /// A new term was created with `written` as its canonical spelling.
        case addedTerm
        /// `heard` became a "Heard as" alternative of an existing term.
        case addedAlternative
        /// The mapping already exists; nothing changed.
        case alreadyKnown
        /// Refused, with the reason the user would see in Vocabulary for the same input.
        case rejected(String)
    }

    /// What `learn(heard:written:)` would do, without changing anything. The History correction
    /// sheet uses it to hide mappings the vocabulary already has and to explain refusals before
    /// the user confirms.
    ///
    /// Reuses the vocabulary's own validation (`VocabularySuggestions.validationMessage`), so a
    /// learned alternative obeys exactly the rules of one picked by hand from history: no
    /// phrase already claimed by another term, nothing the corrector could not match, and no
    /// common word (`CorrectionDiff.isCommon`) on either side.
    func learningOutcome(heard: String, written: String) -> LearnOutcome {
        plan(heard: heard, written: written).outcome
    }

    /// Learn "heard as `heard` → write `written`" from a history correction the user confirmed:
    /// `heard` becomes a "Heard as" alternative of the term spelled `written`, and that term is
    /// created when the vocabulary does not have it yet.
    @discardableResult
    func learn(heard: String, written: String) -> LearnOutcome {
        let planned = plan(heard: heard, written: written)
        switch planned.outcome {
        case .rejected:
            break
        case .alreadyKnown:
            // Re-confirming a mapping on a disabled term is an explicit "I want this fixed".
            if let index = planned.index, !terms[index].enabled {
                terms[index].enabled = true
                commit()
            }
        case .addedAlternative:
            guard let index = planned.index else { break }
            terms[index].alternatives.append(planned.heard)
            // A disabled term would silently ignore the correction the user just confirmed.
            terms[index].enabled = true
            commit()
        case .addedTerm:
            terms.append(VocabularyTerm(text: planned.written, alternatives: [planned.heard]))
            commit()
        }
        return planned.outcome
    }

    private func plan(heard rawHeard: String, written rawWritten: String)
        -> (outcome: LearnOutcome, index: Int?, heard: String, written: String) {
        let heard = rawHeard.trimmingCharacters(in: .whitespacesAndNewlines)
        let written = rawWritten.trimmingCharacters(in: .whitespacesAndNewlines)
        let heardKey = VocabularySuggestions.key(heard)
        let writtenKey = VocabularySuggestions.key(written)
        func result(_ outcome: LearnOutcome, _ index: Int? = nil)
            -> (outcome: LearnOutcome, index: Int?, heard: String, written: String) {
            (outcome, index, heard, written)
        }
        guard !heardKey.isEmpty, !writtenKey.isEmpty else {
            return result(.rejected(String(localized: "Nothing to learn.",
                                           comment: "Vocabulary: why a correction could not be learned")))
        }
        guard heardKey != writtenKey else {
            return result(.rejected(String(localized: "This is already the correct spelling.",
                                           comment: "Vocabulary: why a correction could not be learned")))
        }
        guard !CorrectionDiff.isCommon(heard), !CorrectionDiff.isCommon(written) else {
            return result(.rejected(String(localized: "Common words are never replaced automatically.",
                                           comment: "Vocabulary: why a correction could not be learned")))
        }
        if let index = terms.firstIndex(where: { VocabularySuggestions.key($0.text) == writtenKey }) {
            let term = terms[index]
            if term.alternatives.contains(where: { VocabularySuggestions.key($0) == heardKey }) {
                return result(.alreadyKnown, index)
            }
            if let message = VocabularySuggestions.validationMessage(for: heard, term: term, knownTerms: terms) {
                return result(.rejected(message))
            }
            return result(.addedAlternative, index)
        }
        // A new canonical spelling that another term already rewrites would loop the two terms.
        if let owner = terms.first(where: { $0.alternatives.contains { VocabularySuggestions.key($0) == writtenKey } }) {
            return result(.rejected(String(localized: "\(written) is already corrected to \(owner.text).",
                                           comment: "Vocabulary: first %@ is the new spelling, second the word that already rewrites it")))
        }
        // Validate against a candidate with no alternatives yet, or `heard` would trip
        // "Already in Heard as." on itself.
        let candidate = VocabularyTerm(text: written)
        if let message = VocabularySuggestions.validationMessage(for: heard, term: candidate, knownTerms: terms) {
            return result(.rejected(message))
        }
        return result(.addedTerm)
    }


    func delete(_ term: VocabularyTerm) {
        let before = terms.count
        terms.removeAll { $0.id == term.id }
        guard terms.count != before else { return }
        commit()
    }

    // MARK: - Helpers

    /// Union of two alternative lists, trimmed, de-duplicated case/accent-insensitively,
    /// and with anything empty dropped.
    private static func mergedAlternatives(_ lhs: [String], _ rhs: [String]) -> [String] {
        var out: [String] = []
        var seen: Set<String> = []
        for raw in lhs + rhs {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            let key = VocabularyCorrector.normalize(value)
            guard seen.insert(key).inserted else { continue }
            out.append(value)
        }
        return out
    }

    private func commit() {
        corrector = VocabularyCorrector(terms: terms)
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let url else { return }
        let loaded = ProtectedJSONLoad.read([VocabularyTerm].self, from: url)
        loadWarning = loaded.warning
        savingBlocked = loaded.blocked
        terms = (loaded.value ?? []).filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func save() {
        guard let url, !savingBlocked else { return }
        let snapshot = terms
        saveRevision += 1
        let revision = saveRevision
        // FIFO serialization prevents an older edit from overwriting a newer import.
        saveQueue.async { [weak self] in
            let message: String?
            do {
                let encoded = try JSONEncoder().encode(snapshot)
                try encoded.write(to: url, options: .atomic)
                message = nil
            } catch {
                message = Self.unsavedMessage(error.localizedDescription)
            }
            Task { @MainActor [weak self] in
                guard let self, self.saveRevision == revision else { return }
                self.persistenceError = message
            }
        }
    }
}

extension VocabularyStore {
    /// Shown in Vocabulary and Team settings; `detail` is the system's own (localized) error text.
    nonisolated static func unsavedMessage(_ detail: String) -> String {
        String(localized: "Vocabulary changes are in memory but could not be saved: \(detail)",
               comment: "Vocabulary save error; %@ is the system error description")
    }
}

private enum VocabularyPersistenceError: LocalizedError {
    case blocked
    case write(String)

    var errorDescription: String? {
        switch self {
        case .blocked:
            String(localized: "Vocabulary saving is paused to protect an unreadable file.",
                   comment: "Vocabulary save error")
        case .write(let message): message
        }
    }
}
