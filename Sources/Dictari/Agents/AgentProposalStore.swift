import Foundation
import Observation

extension AppPaths {
    static let agentProposals = support.appendingPathComponent("Agent Proposals", isDirectory: true)
}

struct AgentVocabularyProposal: Codable, Identifiable, Sendable {
    let id: UUID
    let created: String
    var status: String
    let action: String
    let word: String
    let alternatives: [String]
    let reason: String
    let evidenceTranscriptIDs: [String]
    let targetTermID: UUID?
    let idempotencyKey: UUID?
    var decided: String?

    init(id: UUID, created: String, status: String, action: String, word: String,
         alternatives: [String], reason: String, evidenceTranscriptIDs: [String],
         targetTermID: UUID? = nil, idempotencyKey: UUID? = nil, decided: String? = nil) {
        self.id = id
        self.created = created
        self.status = status
        self.action = action
        self.word = word
        self.alternatives = alternatives
        self.reason = reason
        self.evidenceTranscriptIDs = evidenceTranscriptIDs
        self.targetTermID = targetTermID
        self.idempotencyKey = idempotencyKey
        self.decided = decided
    }
}

@MainActor
@Observable
final class AgentProposalStore {
    private(set) var proposals: [AgentVocabularyProposal] = []
    private(set) var error: String?
    private let root: URL

    init(root: URL = AppPaths.agentProposals) {
        self.root = root
        refresh()
    }

    var pending: [AgentVocabularyProposal] {
        proposals.filter { $0.status == "pending" || $0.status == "applying" }
            .sorted { $0.created > $1.created }
    }

    func refresh() {
        do {
            guard FileManager.default.fileExists(atPath: root.path) else {
                proposals = []
                error = nil
                return
            }
            proposals = try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.fileSizeKey]
            )
            .filter { $0.pathExtension == "json" }
            .prefix(500)
            .compactMap { url in
                guard url.deletingPathExtension().lastPathComponent.first != "." else { return nil }
                guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      size <= 64 * 1024 else { return nil }
                return try? JSONDecoder().decode(AgentVocabularyProposal.self, from: Data(contentsOf: url))
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func approve(_ proposal: AgentVocabularyProposal, vocabulary: VocabularyStore) async {
        do {
            if proposal.status == "applying", isAlreadyApplied(proposal, vocabulary: vocabulary) {
                try decide(proposal, status: "approved")
                return
            }
            try decide(proposal, status: "applying")
            switch proposal.action {
            case "add":
                vocabulary.add(VocabularyTerm(text: proposal.word, alternatives: proposal.alternatives))
            case "update":
                guard let targetTermID = proposal.targetTermID,
                      var term = vocabulary.terms.first(where: { $0.id == targetTermID }) else {
                    throw ProposalError.termNotFound
                }
                term.alternatives = Array(Set(term.alternatives + proposal.alternatives)).sorted()
                vocabulary.update(term)
            case "delete":
                guard let targetTermID = proposal.targetTermID,
                      let term = vocabulary.terms.first(where: { $0.id == targetTermID }) else {
                    throw ProposalError.termNotFound
                }
                vocabulary.delete(term)
            default:
                throw ProposalError.invalidAction
            }
            try await vocabulary.flushPendingSaves()
            try decide(proposal, status: "approved")
        } catch {
            self.error = error.localizedDescription
        }
    }

    func reject(_ proposal: AgentVocabularyProposal) {
        do { try decide(proposal, status: "rejected") }
        catch { self.error = error.localizedDescription }
    }

    private func decide(_ proposal: AgentVocabularyProposal, status: String) throws {
        var updated = proposal
        updated.status = status
        updated.decided = ISO8601DateFormatter().string(from: Date())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(updated).write(
            // Python's UUID text is lowercase. Reuse that canonical filename so approval
            // replaces the pending record instead of leaving a duplicate pending copy behind.
            to: root.appendingPathComponent(proposal.id.uuidString.lowercased()).appendingPathExtension("json"),
            options: .atomic
        )
        refresh()
    }

    private func isAlreadyApplied(_ proposal: AgentVocabularyProposal, vocabulary: VocabularyStore) -> Bool {
        switch proposal.action {
        case "add":
            guard let term = vocabulary.terms.first(where: {
                $0.text.compare(proposal.word, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }) else { return false }
            return Set(proposal.alternatives).isSubset(of: Set(term.alternatives))
        case "update":
            guard let targetTermID = proposal.targetTermID,
                  let term = vocabulary.terms.first(where: { $0.id == targetTermID }) else { return false }
            return Set(proposal.alternatives).isSubset(of: Set(term.alternatives))
        case "delete":
            guard let targetTermID = proposal.targetTermID else { return false }
            return !vocabulary.terms.contains(where: { $0.id == targetTermID })
        default:
            return false
        }
    }
}

private enum ProposalError: LocalizedError {
    case invalidAction, termNotFound
    var errorDescription: String? {
        switch self {
        // Shown in the app when the user applies a proposal (not sent over MCP).
        case .invalidAction:
            String(localized: "This proposal uses an unsupported action.", comment: "Error applying an AI agent's vocabulary proposal")
        case .termNotFound:
            String(localized: "The vocabulary entry no longer exists. Refresh the proposal in your agent.",
                   comment: "Error applying an AI agent's vocabulary proposal")
        }
    }
}
