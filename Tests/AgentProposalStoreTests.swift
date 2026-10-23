import XCTest

@MainActor
final class AgentProposalStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictari-agent-proposals-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testApprovalAppliesThroughVocabularyStoreAndReplacesPendingFile() async throws {
        let proposal = AgentVocabularyProposal(
            id: UUID(), created: "2026-09-17T07:00:00Z", status: "pending", action: "add",
            word: "Dictari", alternatives: ["Kittari"], reason: "User confirmed",
            evidenceTranscriptIDs: [], decided: nil
        )
        try write(proposal)
        let store = AgentProposalStore(root: root)
        let vocabularyURL = root.appendingPathComponent("vocabulary.json")
        let vocabulary = VocabularyStore(url: vocabularyURL)

        await store.approve(proposal, vocabulary: vocabulary)

        XCTAssertEqual(vocabulary.terms.map(\.text), ["Dictari"])
        XCTAssertEqual(store.pending.count, 0)
        XCTAssertEqual(store.proposals.count, 1)
        XCTAssertEqual(store.proposals.first?.status, "approved")
        let persisted = try JSONDecoder().decode([VocabularyTerm].self, from: Data(contentsOf: vocabularyURL))
        XCTAssertEqual(persisted.map(\.text), ["Dictari"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".json") && $0.lastPathComponent != "vocabulary.json" }.count, 1)
    }

    func testRejectionDoesNotChangeVocabulary() throws {
        let proposal = AgentVocabularyProposal(
            id: UUID(), created: "2026-09-17T07:00:00Z", status: "pending", action: "delete",
            word: "Dictari", alternatives: [], reason: "Possible false positive",
            evidenceTranscriptIDs: [], decided: nil
        )
        try write(proposal)
        let store = AgentProposalStore(root: root)
        store.reject(proposal)
        XCTAssertEqual(store.pending.count, 0)
        XCTAssertEqual(store.proposals.first?.status, "rejected")
    }

    func testApplyingAddReconcilesIdempotentlyAfterRestart() async throws {
        let proposal = AgentVocabularyProposal(
            id: UUID(), created: "2026-09-17T07:00:00Z", status: "applying", action: "add",
            word: "Dictari", alternatives: ["Kittari"], reason: "User confirmed",
            evidenceTranscriptIDs: [], idempotencyKey: UUID(), decided: nil
        )
        try write(proposal)
        let store = AgentProposalStore(root: root)
        let vocabulary = VocabularyStore(terms: [VocabularyTerm(text: "Dictari", alternatives: ["Kittari"])])

        await store.approve(proposal, vocabulary: vocabulary)

        XCTAssertEqual(vocabulary.terms.count, 1)
        XCTAssertEqual(store.proposals.first?.status, "approved")
    }

    func testApprovalStaysApplyingWhenVocabularyCannotPersist() async throws {
        let proposal = AgentVocabularyProposal(
            id: UUID(), created: "2026-09-17T07:00:00Z", status: "pending", action: "add",
            word: "Dictari", alternatives: [], reason: "User confirmed",
            evidenceTranscriptIDs: [], idempotencyKey: UUID(), decided: nil
        )
        try write(proposal)
        let blockedURL = root.appendingPathComponent("blocked", isDirectory: true)
        try FileManager.default.createDirectory(at: blockedURL, withIntermediateDirectories: true)
        let vocabulary = VocabularyStore(url: blockedURL)
        let store = AgentProposalStore(root: root)

        await store.approve(proposal, vocabulary: vocabulary)

        XCTAssertEqual(store.proposals.first(where: { $0.id == proposal.id })?.status, "applying")
        XCTAssertNotNil(store.error)
    }

    func testHistoryRevisedTagIsNotAFailure() {
        let revised = HistoryEntry(date: Date(), text: "Corrected", durationSeconds: 1,
                                   wordCount: 1, latencyMs: 1, tag: "revised")
        let failed = HistoryEntry(date: Date(), text: "", durationSeconds: 1,
                                  wordCount: 0, latencyMs: 1, tag: "failed")
        XCTAssertFalse(revised.isFailure)
        XCTAssertTrue(failed.isFailure)
    }

    private func write(_ proposal: AgentVocabularyProposal) throws {
        let url = root.appendingPathComponent(proposal.id.uuidString.lowercased()).appendingPathExtension("json")
        try JSONEncoder().encode(proposal).write(to: url, options: .atomic)
    }
}
