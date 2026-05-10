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

    // MARK: - Phase 1C — UI quality gates

    func testFlagOnFiltersOutAtomsBelowConfidenceFloor() {
        let lowConfidence = Self.makeAtom(id: "low", confidence: 0.6)
        let citation = Self.makeCitation()

        let result = AttributionDisplay.cascade(
            flagEnabled: true,
            resolvedCorpusEntries: [lowConfidence],
            citations: [citation]
        )

        // Low-confidence atom dropped; legacy citations are the fallback.
        XCTAssertEqual(result, .legacyCitations([citation]))
    }

    func testFlagOnKeepsAtomsAtOrAboveConfidenceFloor() {
        let onFloor = Self.makeAtom(id: "on-floor", confidence: 0.7)

        let result = AttributionDisplay.cascade(
            flagEnabled: true,
            resolvedCorpusEntries: [onFloor],
            citations: []
        )

        XCTAssertEqual(result, .atomCards([onFloor]))
    }

    func testFlagOnMixedConfidenceKeepsOnlyHighConfidenceAtoms() {
        let high = Self.makeAtom(id: "high", confidence: 0.9)
        let low = Self.makeAtom(id: "low", confidence: 0.6)
        let alsoHigh = Self.makeAtom(id: "also-high", confidence: 0.8)

        let result = AttributionDisplay.cascade(
            flagEnabled: true,
            resolvedCorpusEntries: [high, low, alsoHigh],
            citations: []
        )

        XCTAssertEqual(result, .atomCards([high, alsoHigh]))
    }

    func testFlagOnAllBelowFloorFallsBackToCitations() {
        let lowA = Self.makeAtom(id: "a", confidence: 0.5)
        let lowB = Self.makeAtom(id: "b", confidence: 0.65)
        let citation = Self.makeCitation()

        let result = AttributionDisplay.cascade(
            flagEnabled: true,
            resolvedCorpusEntries: [lowA, lowB],
            citations: [citation]
        )

        XCTAssertEqual(result, .legacyCitations([citation]))
    }

    func testFlagOnTruncatesToMaxAtomCards() {
        let entries = (0..<8).map { idx in
            Self.makeAtom(id: "atom-\(idx)", confidence: 0.85)
        }

        let result = AttributionDisplay.cascade(
            flagEnabled: true,
            resolvedCorpusEntries: entries,
            citations: []
        )

        guard case .atomCards(let displayed) = result else {
            XCTFail("Expected atomCards branch, got \(result)")
            return
        }
        XCTAssertEqual(displayed.count, 5)
        XCTAssertEqual(displayed.map(\.entry.id), entries.prefix(5).map(\.entry.id))
    }

    func testCustomFloorAndCapOverridesDefaults() {
        let entry = Self.makeAtom(id: "borderline", confidence: 0.55)

        // Custom floor 0.5 admits the entry that the default 0.7 floor rejects.
        let result = AttributionDisplay.cascade(
            flagEnabled: true,
            resolvedCorpusEntries: [entry, Self.makeAtom(confidence: 0.6), Self.makeAtom(confidence: 0.6)],
            citations: [],
            minConfidence: 0.5,
            maxAtomCards: 2
        )

        guard case .atomCards(let displayed) = result else {
            XCTFail("Expected atomCards branch, got \(result)")
            return
        }
        XCTAssertEqual(displayed.count, 2, "cap=2 should truncate")
    }

    // MARK: - Fixtures

    private static func makeAtom(
        id: String = UUID().uuidString,
        confidence: Double = 0.82,
        sourceNodeId: UUID? = UUID()
    ) -> ResolvedCitableEntry {
        let entry = CitableEntry(
            id: id,
            text: "Networking events feel like a stage to me.",
            scope: .global,
            promptAnnotation: "atom-recall",
            confidence: confidence,
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
