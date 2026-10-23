import XCTest
import Foundation

@MainActor
final class VocabularyTransferTests: XCTestCase {
    func testRoundTripPreservesWordsAlternativesAndDisabledState() throws {
        let source = VocabularyStore(terms: [
            VocabularyTerm(text: "Bézier", enabled: false, alternatives: ["bez ear"]),
            VocabularyTerm(text: "kubectl", alternatives: ["cube cuddle"])
        ])
        let target = VocabularyStore(url: nil)
        let result = try target.importData(source.exportData())
        XCTAssertEqual(result.added, 2)
        XCTAssertEqual(target.terms.map(\.text), ["Bézier", "kubectl"])
        XCTAssertEqual(target.terms.map(\.enabled), [false, true])
        XCTAssertEqual(target.terms.map(\.alternatives), [["bez ear"], ["cube cuddle"]])
        XCTAssertEqual(target.corrector.correct("cube cuddle"), "kubectl")
        XCTAssertEqual(target.corrector.correct("bez ear"), "bez ear")
    }

    func testMergePreservesExistingIdentitySpellingAndDisabledState() throws {
        let original = VocabularyTerm(text: "Bézier", enabled: false, alternatives: ["bez ear"])
        let store = VocabularyStore(terms: [original])
        let source = VocabularyStore(terms: [VocabularyTerm(text: " BEZIER ", alternatives: [" BEZ EAR ", "bee zier"])])
        let result = try store.importData(source.exportData())
        XCTAssertEqual(result.added, 0)
        XCTAssertEqual(result.merged, 1)
        XCTAssertEqual(store.terms.count, 1)
        XCTAssertEqual(store.terms[0].id, original.id)
        XCTAssertEqual(store.terms[0].text, "Bézier")
        XCTAssertFalse(store.terms[0].enabled)
        XCTAssertEqual(store.terms[0].alternatives, ["bez ear", "bee zier"])
        let snapshot = store.terms
        _ = try store.importData(source.exportData())
        XCTAssertEqual(store.terms, snapshot)
    }

    func testLegacyArrayDeduplicatesWordsAndRegeneratesCollidingIDs() throws {
        let id = UUID()
        let imported = [VocabularyTerm(id: id, text: "Dictari"),
                        VocabularyTerm(id: id, text: "DICTARI", alternatives: ["dictary"]),
                        VocabularyTerm(id: id, text: "Swift")]
        let store = VocabularyStore(url: nil)
        let result = try store.importData(JSONEncoder().encode(imported))
        XCTAssertEqual(result.added, 2)
        XCTAssertEqual(result.merged, 1)
        XCTAssertEqual(Set(store.terms.map(\.id)).count, 2)
        XCTAssertEqual(store.terms[0].alternatives, ["dictary"])
    }

    func testMalformedOrUnsupportedFilesNeverPartiallyChangeVocabulary() throws {
        let store = VocabularyStore(terms: [VocabularyTerm(text: "Keep")])
        let before = store.terms
        for input in ["not json", "{}", "[{\"text\":\"Good\"},{\"text\":\"  \"}]",
                      "[{\"text\":\"Good\"},{\"text\":23}]",
                      "{\"format\":\"dictari-vocabulary\",\"version\":2,\"terms\":[]}",
                      "{\"format\":\"other\",\"version\":1,\"terms\":[]}"] {
            XCTAssertThrowsError(try store.importData(Data(input.utf8)), input)
            XCTAssertEqual(store.terms, before)
        }
        XCTAssertThrowsError(try store.importData(Data(repeating: 32, count: VocabularyStore.maximumImportBytes + 1)))
        let many = (0..<5001).map { VocabularyTerm(text: "Word\($0)") }
        XCTAssertThrowsError(try store.importData(JSONEncoder().encode(many)))
        XCTAssertEqual(store.terms, before)
    }

    func testQueuedEditsAndImportPersistTheLatestSnapshot() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("vocabulary.json")
        let store = VocabularyStore(url: url)
        for index in 0..<60 { store.add(VocabularyTerm(text: "Word\(index)")) }
        let imported = VocabularyStore(terms: [VocabularyTerm(text: "kubectl", alternatives: ["cube cuddle"])])
        _ = try store.importData(imported.exportData())
        store.delete(store.terms[0])
        await store.waitForPendingSaves()
        let reopened = VocabularyStore(url: url)
        XCTAssertEqual(reopened.terms, store.terms)
        XCTAssertEqual(reopened.terms.count, 60)
        XCTAssertEqual(reopened.corrector.correct("cube cuddle"), "kubectl")
    }
}

extension VocabularyTransferTests {
    func testCorruptVocabularySurvivesLaterEditsInBackup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("vocabulary.json")
        let original = Data("[ damaged words".utf8)
        try original.write(to: url)
        let store = VocabularyStore(url: url)
        XCTAssertNotNil(store.loadWarning)
        store.add(VocabularyTerm(text: "Dictari"))
        await store.waitForPendingSaves()
        let backup = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.pathExtension == "backup" })
        XCTAssertEqual(try Data(contentsOf: backup), original)
        XCTAssertEqual(try JSONDecoder().decode([VocabularyTerm].self, from: Data(contentsOf: url)).first?.text, "Dictari")
    }
}
