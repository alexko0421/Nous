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

    func testRefinementPromptAsksForChineseExplanationAndChineseEvidenceSummary() async throws {
        let llm = PromptCapturingRelationLLMService(output: """
        {
          "relation": "same_pattern",
          "confidence": 0.87,
          "explanation": "这两段都把速度当成应对不确定性的方式。",
          "source_evidence": "第一段说 Alex 在不确定变大时会加速行动。",
          "target_evidence": "第二段说速度被用来释放压力。",
          "source_atom_id": null,
          "target_atom_id": null
        }
        """)
        let judge = GalaxyRelationJudge(llmServiceProvider: { llm })

        let verdict = await judge.judgeRefined(
            source: NousNode(
                type: .conversation,
                title: "Mental load",
                content: "I keep moving faster when uncertainty gets loud."
            ),
            target: NousNode(
                type: .note,
                title: "Shipping pattern",
                content: "Speed is being used as a pressure valve."
            ),
            similarity: 0.9
        )

        let prompt = try XCTUnwrap(llm.capturedMessages.first?.content)
        let system = try XCTUnwrap(llm.capturedSystem)
        XCTAssertEqual(verdict?.explanation, "这两段都把速度当成应对不确定性的方式。")
        XCTAssertEqual(verdict?.sourceEvidence, "第一段说 Alex 在不确定变大时会加速行动。")
        XCTAssertEqual(verdict?.targetEvidence, "第二段说速度被用来释放压力。")
        XCTAssertTrue(prompt.contains("\"explanation\": \"中文一句话"), prompt)
        XCTAssertTrue(prompt.contains("\"source_evidence\": \"中文短句，紧贴 SOURCE"), prompt)
        XCTAssertTrue(prompt.contains("\"target_evidence\": \"中文短句，紧贴 TARGET"), prompt)
        XCTAssertTrue(system.contains("explanation 用中文"), system)
        XCTAssertTrue(system.contains("evidence 用中文"), system)
    }

    func testRefinementRejectsStrongRelationWithEnglishEvidence() async {
        let judge = GalaxyRelationJudge(
            llmServiceProvider: {
                StaticRelationLLMService(output: """
                {
                  "relation": "same_pattern",
                  "confidence": 0.91,
                  "explanation": "两段都把速度当成面对压力时的默认处理方式。",
                  "source_evidence": "moving faster when uncertainty gets loud",
                  "target_evidence": "Speed is being used as a pressure valve",
                  "source_atom_id": null,
                  "target_atom_id": null
                }
                """)
            }
        )

        let verdict = await judge.judgeRefined(
            source: NousNode(
                type: .conversation,
                title: "Mental load",
                content: "I keep moving faster when uncertainty gets loud."
            ),
            target: NousNode(
                type: .note,
                title: "Shipping pattern",
                content: "Speed is being used as a pressure valve."
            ),
            similarity: 0.91
        )

        XCTAssertNil(verdict)
    }

    func testRefinementRejectsGenericHighConfidenceRelation() async {
        let judge = GalaxyRelationJudge(
            llmServiceProvider: {
                StaticRelationLLMService(output: """
                {
                  "relation": "tension",
                  "confidence": 0.96,
                  "explanation": "它们之间有一个值得留意的张力。",
                  "source_evidence": "Alex plans to buy the shoes tomorrow right after class",
                  "target_evidence": "Alex and the Mexican girl previously hung out around shopping/buying things",
                  "source_atom_id": null,
                  "target_atom_id": null
                }
                """)
            }
        )

        let verdict = await judge.judgeRefined(
            source: NousNode(
                type: .conversation,
                title: "Evo SL 定 Cloudmonster 3 最终决定",
                content: "Alex plans to buy the shoes tomorrow right after class."
            ),
            target: NousNode(
                type: .note,
                title: "购物约会模式",
                content: "Alex and the Mexican girl previously hung out around shopping/buying things."
            ),
            similarity: 0.96
        )

        XCTAssertNil(verdict)
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

private final class PromptCapturingRelationLLMService: LLMService {
    let output: String
    private(set) var capturedMessages: [LLMMessage] = []
    private(set) var capturedSystem: String?

    init(output: String) {
        self.output = output
    }

    func generate(messages: [LLMMessage], system: String?) async throws -> AsyncThrowingStream<String, Error> {
        capturedMessages = messages
        capturedSystem = system

        return AsyncThrowingStream { continuation in
            continuation.yield(output)
            continuation.finish()
        }
    }
}
