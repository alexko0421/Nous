import XCTest
@testable import Nous

final class AttributionDisplayCascadeTests: XCTestCase {
    func testFlagOffWithCitationsReturnsLegacy() {
        let entry = Self.makeAtom()
        let citation = Self.makeCitation()

        let result = AttributionDisplay.cascade(
            flagEnabled: false,
            resolvedCorpusEntries: [entry],
            citations: [citation]
        )

        XCTAssertEqual(result, .legacyCitations([citation]))
    }

    func testFlagOffWithNoCitationsReturnsNone() {
        let result = AttributionDisplay.cascade(
            flagEnabled: false,
            resolvedCorpusEntries: [Self.makeAtom()],
            citations: []
        )

        XCTAssertEqual(result, .none)
    }

    func testFlagOnWithCorpusEntriesPrefersAtomCards() {
        let entry = Self.makeAtom()
        let citation = Self.makeCitation()

        let result = AttributionDisplay.cascade(
            flagEnabled: true,
            resolvedCorpusEntries: [entry],
            citations: [citation]
        )

        XCTAssertEqual(result, .atomCards([entry]))
    }

    func testFlagOnWithEmptyCorpusFallsBackToCitations() {
        let citation = Self.makeCitation()

        let result = AttributionDisplay.cascade(
            flagEnabled: true,
            resolvedCorpusEntries: [],
            citations: [citation]
        )

        XCTAssertEqual(result, .legacyCitations([citation]))
    }

    func testFlagOnWithBothEmptyReturnsNone() {
        let result = AttributionDisplay.cascade(
            flagEnabled: true,
            resolvedCorpusEntries: [],
            citations: []
        )

        XCTAssertEqual(result, .none)
    }

    // MARK: - Fixtures

    private static func makeAtom(
        id: String = UUID().uuidString,
        sourceNodeId: UUID? = UUID()
    ) -> ResolvedCitableEntry {
        let entry = CitableEntry(
            id: id,
            text: "Networking events feel like a stage to me.",
            scope: .global,
            promptAnnotation: "atom-recall",
            confidence: 0.82,
            sourceNodeId: sourceNodeId,
            atomType: .insight,
            recordedAt: Date(timeIntervalSince1970: 1_000)
        )
        let node: NousNode? = sourceNodeId.map { id in
            NousNode(
                id: id,
                type: .conversation,
                title: "Earlier chat",
                projectId: nil
            )
        }
        return ResolvedCitableEntry(entry: entry, node: node)
    }

    private static func makeCitation() -> SearchResult {
        let node = NousNode(
            type: .conversation,
            title: "Some past conversation",
            projectId: nil
        )
        return SearchResult(node: node, similarity: 0.7)
    }
}
