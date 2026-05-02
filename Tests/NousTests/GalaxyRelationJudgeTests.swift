import XCTest
@testable import Nous

final class GalaxyRelationJudgeTests: XCTestCase {
    func testChineseAtomOverlapCanSupportLowConfidenceLocalRelation() {
        let judge = GalaxyRelationJudge()
        let source = NousNode(type: .note, title: "Product boundary")
        let target = NousNode(type: .conversation, title: "Product direction")
        let sourceAtom = MemoryAtom(
            type: .boundary,
            statement: "Alex 唔想将 Nous 变成情绪产品",
            scope: .conversation,
            confidence: 0.2
        )
        let targetAtom = MemoryAtom(
            type: .goal,
            statement: "Nous 要避免变成情绪产品，保持工具属性",
            scope: .conversation,
            confidence: 0.2
        )

        let verdict = judge.judge(
            source: source,
            target: target,
            similarity: 0.1,
            sourceAtoms: [sourceAtom],
            targetAtoms: [targetAtom]
        )

        XCTAssertEqual(verdict?.relationKind, .tension)
        XCTAssertEqual(verdict?.sourceAtomId, sourceAtom.id)
        XCTAssertEqual(verdict?.targetAtomId, targetAtom.id)
    }

    func testTelemetryTracksLLMNone() async {
        let telemetry = GalaxyRelationTelemetry()
        let suiteName = "GalaxyRelationJudgeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let backgroundTelemetry = BackgroundAIJobTelemetryStore(defaults: defaults)
        let judge = GalaxyRelationJudge(
            telemetry: telemetry,
            backgroundTelemetry: backgroundTelemetry,
            llmServiceProvider: {
                StaticRelationLLMService(output: """
                {
                  "relation": "none",
                  "confidence": 0.93,
                  "explanation": "not useful",
                  "source_evidence": "source",
                  "target_evidence": "target",
                  "source_atom_id": null,
                  "target_atom_id": null
                }
                """)
            }
        )

        let verdict = await judge.judgeRefined(
            source: NousNode(type: .note, title: "A", content: "same topic"),
            target: NousNode(type: .note, title: "B", content: "same topic"),
            similarity: 0.9
        )

        XCTAssertNil(verdict)
        let snapshot = telemetry.snapshot()
        XCTAssertEqual(snapshot.localVerdictCount, 1)
        XCTAssertEqual(snapshot.llmNilCount, 1)
        XCTAssertEqual(backgroundTelemetry.lastRun(for: .galaxyRelationRefinement)?.status, .completed)
        XCTAssertEqual(backgroundTelemetry.lastRun(for: .galaxyRelationRefinement)?.outputCount, 0)
    }

    func testTelemetryTracksLLMFallback() async {
        let telemetry = GalaxyRelationTelemetry()
        let suiteName = "GalaxyRelationJudgeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let backgroundTelemetry = BackgroundAIJobTelemetryStore(defaults: defaults)
        let judge = GalaxyRelationJudge(
            telemetry: telemetry,
            backgroundTelemetry: backgroundTelemetry,
            llmServiceProvider: { FailingRelationLLMService() }
        )

        let verdict = await judge.judgeRefined(
            source: NousNode(type: .note, title: "A", content: "same topic"),
            target: NousNode(type: .note, title: "B", content: "same topic"),
            similarity: 0.9
        )

        XCTAssertEqual(verdict?.relationKind, .topicSimilarity)
        XCTAssertEqual(telemetry.snapshot().llmFallbackCount, 1)
        XCTAssertEqual(backgroundTelemetry.lastRun(for: .galaxyRelationRefinement)?.status, .failed)
        XCTAssertEqual(backgroundTelemetry.lastRun(for: .galaxyRelationRefinement)?.detail, "llm_fallback")
    }
}

private struct StaticRelationLLMService: LLMService {
    let output: String

    func generate(messages: [LLMMessage], system: String?) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(output)
            continuation.finish()
        }
    }
}

private struct FailingRelationLLMService: LLMService {
    func generate(messages: [LLMMessage], system: String?) async throws -> AsyncThrowingStream<String, Error> {
        throw FailingRelationLLMServiceError.failed
    }
}

private enum FailingRelationLLMServiceError: Error {
    case failed
}
