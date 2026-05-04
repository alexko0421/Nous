import XCTest
@testable import Nous

final class ProvocationJudgeTests: XCTestCase {

    // MARK: Fake LLM Service

    final class FakeLLMService: LLMService {
        private let lock = NSLock()
        private var storedReceivedSystem: String?
        private var storedReceivedUserMessage: String?
        private var storedOutput: String
        private var storedShouldThrow: Error?
        private var storedDelay: TimeInterval = 0

        var output: String {
            get { lock.withLock { storedOutput } }
            set { lock.withLock { storedOutput = newValue } }
        }
        var shouldThrow: Error? {
            get { lock.withLock { storedShouldThrow } }
            set { lock.withLock { storedShouldThrow = newValue } }
        }
        var delay: TimeInterval {
            get { lock.withLock { storedDelay } }
            set { lock.withLock { storedDelay = newValue } }
        }
        var receivedSystem: String? {
            lock.withLock { storedReceivedSystem }
        }
        var receivedUserMessage: String? {
            lock.withLock { storedReceivedUserMessage }
        }

        init(output: String) {
            self.storedOutput = output
        }

        func generate(messages: [LLMMessage], system: String?) async throws -> AsyncThrowingStream<String, Error> {
            let snapshot = lock.withLock { () -> (String, String?, Error?, TimeInterval) in
                storedReceivedSystem = system
                storedReceivedUserMessage = messages.last?.content
                return (storedOutput, storedReceivedUserMessage, storedShouldThrow, storedDelay)
            }
            if let err = snapshot.2 { throw err }
            let output = snapshot.0
            let delay = snapshot.3
            return AsyncThrowingStream { cont in
                Task {
                    if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                    cont.yield(output)
                    cont.finish()
                }
            }
        }
    }

    struct FakeThinkingLLMService: LLMService, ThinkingDeltaConfigurableLLMService {
        let output: String
        let thinkingDelta: String
        var onThinkingDelta: ThinkingDeltaHandler?

        func withThinkingDeltaHandler(_ handler: @escaping ThinkingDeltaHandler) -> any LLMService {
            FakeThinkingLLMService(
                output: output,
                thinkingDelta: thinkingDelta,
                onThinkingDelta: handler
            )
        }

        func generate(messages: [LLMMessage], system: String?) async throws -> AsyncThrowingStream<String, Error> {
            let output = output
            let thinkingDelta = thinkingDelta
            let onThinkingDelta = onThinkingDelta
            return AsyncThrowingStream { continuation in
                Task {
                    if let onThinkingDelta {
                        await onThinkingDelta(thinkingDelta)
                    }
                    continuation.yield(output)
                    continuation.finish()
                }
            }
        }
    }

    actor ThinkingCapture {
        private var values: [String] = []

        func append(_ value: String) {
            values.append(value)
        }

        func all() -> [String] {
            values
        }
    }

    private func pool() -> [CitableEntry] {
        [CitableEntry(id: "E1", text: "Do not compete on price.", scope: .global)]
    }

    func testParsesWellFormedJSONVerdict() async throws {
        let fake = FakeLLMService(output: """
        {"tension_exists":true,"user_state":"deciding","should_provoke":true,
         "entry_id":"E1","reason":"pricing conflict","inferred_mode":"strategist"}
        """)
        let judge = ProvocationJudge(llmService: fake, timeout: 1.0)

        let verdict = try await judge.judge(
            userMessage: "I'm going with the cheapest option",
            citablePool: pool(),
            previousMode: .companion,
            provider: .claude,
            feedbackLoop: nil
        )

        XCTAssertTrue(verdict.shouldProvoke)
        XCTAssertEqual(verdict.entryId, "E1")
        XCTAssertEqual(verdict.userState, .deciding)
    }

    func testForwardsVisibleJudgeThinkingDeltas() async throws {
        let fake = FakeThinkingLLMService(
            output: """
            {"tension_exists":true,"user_state":"deciding","should_provoke":true,
             "entry_id":"E1","reason":"pricing conflict","inferred_mode":"strategist"}
            """,
            thinkingDelta: "I compared the current price choice against entry E1."
        )
        let capture = ThinkingCapture()
        let judge = ProvocationJudge(
            llmService: fake,
            timeout: 1.0,
            onThinkingDelta: { delta in
                await capture.append(delta)
            }
        )

        _ = try await judge.judge(
            userMessage: "I'm going with the cheapest option",
            citablePool: pool(),
            previousMode: .companion,
            provider: .openrouter,
            feedbackLoop: nil
        )

        let thinkingDeltas = await capture.all()
        XCTAssertEqual(thinkingDeltas, ["I compared the current price choice against entry E1."])
    }

    func testRejectsMalformedJSON() async {
        let fake = FakeLLMService(output: "not json at all")
        let judge = ProvocationJudge(llmService: fake, timeout: 1.0)

        do {
            _ = try await judge.judge(
                userMessage: "hi", citablePool: pool(),
                previousMode: .companion, provider: .claude, feedbackLoop: nil
            )
            XCTFail("Expected badJSON throw")
        } catch let error as JudgeError {
            XCTAssertEqual(error, .badJSON)
        } catch {
            XCTFail("Expected JudgeError.badJSON, got \(error)")
        }
    }

    func testSurfacesAPIError() async {
        let fake = FakeLLMService(output: "")
        fake.shouldThrow = URLError(.badServerResponse)
        let judge = ProvocationJudge(llmService: fake, timeout: 1.0)

        do {
            _ = try await judge.judge(
                userMessage: "hi", citablePool: pool(),
                previousMode: .companion, provider: .claude, feedbackLoop: nil
            )
            XCTFail("Expected apiError throw")
        } catch let error as JudgeError {
            XCTAssertEqual(error, .apiError)
        } catch {
            XCTFail("Expected JudgeError.apiError, got \(error)")
        }
    }

    func testTimesOutWhenLLMExceedsBudget() async {
        let fake = FakeLLMService(output: """
        {"tension_exists":false,"user_state":"exploring","should_provoke":false,
         "entry_id":null,"reason":"ok"}
        """)
        fake.delay = 0.5
        let judge = ProvocationJudge(llmService: fake, timeout: 0.1)

        do {
            _ = try await judge.judge(
                userMessage: "hi", citablePool: pool(),
                previousMode: .companion, provider: .claude, feedbackLoop: nil
            )
            XCTFail("Expected timeout throw")
        } catch let error as JudgeError {
            XCTAssertEqual(error, .timeout)
        } catch {
            XCTFail("Expected JudgeError.timeout, got \(error)")
        }
    }

    func testDefaultTimeoutAllowsNormalCloudJudgeLatency() async throws {
        let fake = FakeLLMService(output: """
        {"tension_exists":false,"user_state":"exploring","should_provoke":false,
         "entry_id":null,"reason":"ok","inferred_mode":"companion"}
        """)
        fake.delay = 2.0
        let judge = ProvocationJudge(llmService: fake)

        let verdict = try await judge.judge(
            userMessage: "hi",
            citablePool: pool(),
            previousMode: .companion,
            provider: .openrouter,
            feedbackLoop: nil
        )

        XCTAssertFalse(verdict.shouldProvoke)
    }

    func testPromptEmbedsPoolAndPreviousMode() async throws {
        let fake = FakeLLMService(output: """
        {"tension_exists":false,"user_state":"exploring","should_provoke":false,
         "entry_id":null,"reason":"no tension","inferred_mode":"companion"}
        """)
        let judge = ProvocationJudge(llmService: fake, timeout: 1.0)
        let annotatedPool = [
            CitableEntry(
                id: "E1",
                text: "Do not compete on price.",
                scope: .global,
                kind: .decision,
                promptAnnotation: "contradiction-candidate"
            )
        ]

        _ = try await judge.judge(
            userMessage: "so about pricing",
            citablePool: annotatedPool,
            previousMode: .strategist,
            provider: .claude,
            feedbackLoop: nil
        )

        let prompt = fake.receivedSystem ?? ""
        XCTAssertTrue(prompt.contains("E1"), "judge prompt must include citable entry ids")
        XCTAssertTrue(prompt.contains("strategist"), "judge prompt must include chat mode")
        XCTAssertTrue(prompt.contains("compete on price"), "judge prompt must include entry text")
        XCTAssertTrue(prompt.contains("[contradiction-candidate] id=E1"),
                      "judge prompt must surface contradiction-candidate hints as prompt input only")
        XCTAssertTrue(prompt.contains("kind=decision"),
                      "judge prompt should include entry kind metadata for contradiction-oriented facts")
    }

    func testPromptEmbedsNilPreviousMode() async throws {
        let fake = FakeLLMService(output: """
        {"tension_exists":false,"user_state":"exploring","should_provoke":false,
         "entry_id":null,"reason":"no tension","inferred_mode":"companion"}
        """)
        let judge = ProvocationJudge(llmService: fake, timeout: 1.0)

        _ = try await judge.judge(
            userMessage: "so about pricing",
            citablePool: pool(),
            previousMode: nil,
            provider: .claude,
            feedbackLoop: nil
        )

        let prompt = fake.receivedSystem ?? ""
        XCTAssertTrue(prompt.contains("none (first turn)"),
                      "Prompt must include 'none (first turn)' sentinel when previousMode is nil")
    }

    func testExtractsJSONFromProseWithEscapedQuotes() async throws {
        let fake = FakeLLMService(output: """
        Sure! Here's the verdict:

        {"tension_exists": true, "user_state": "deciding", "should_provoke": true, "entry_id": "E1", "reason": "say \\"hi\\" but question the framing", "inferred_mode": "strategist"}

        Let me know if you need more.
        """)
        let judge = ProvocationJudge(llmService: fake, timeout: 1.0)

        let verdict = try await judge.judge(
            userMessage: "should I proceed?",
            citablePool: pool(),
            previousMode: .companion,
            provider: .claude,
            feedbackLoop: nil
        )

        XCTAssertTrue(verdict.shouldProvoke)
        XCTAssertTrue(verdict.reason.contains("hi"), "reason should contain the escaped quoted 'hi'")
        XCTAssertEqual(verdict.entryId, "E1")
    }

    func testPromptEmbedsRecentFeedbackLoop() async throws {
        let fake = FakeLLMService(output: """
        {"tension_exists":false,"user_state":"exploring","should_provoke":false,
         "entry_id":null,"reason":"no tension","inferred_mode":"companion"}
        """)
        let judge = ProvocationJudge(llmService: fake, timeout: 1.0)
        let feedbackLoop = JudgeFeedbackLoop(
            entrySuppressions: [
                .init(entryId: "E1", penalty: 1.8, reasonHints: ["wrong timing", "too repetitive"])
            ],
            kindAdjustments: [
                .init(kind: .contradiction, penalty: 1.2, reasonHints: ["too forceful"])
            ],
            globalReasonHints: ["wrong timing"],
            noteHints: ["same challenge again"]
        )

        _ = try await judge.judge(
            userMessage: "should I proceed?",
            citablePool: pool(),
            previousMode: .companion,
            provider: .claude,
            feedbackLoop: feedbackLoop
        )

        let prompt = fake.receivedSystem ?? ""
        XCTAssertTrue(prompt.contains("RECENT USER FEEDBACK"))
        XCTAssertTrue(prompt.contains("recently_downvoted_entry_ids:"))
        XCTAssertTrue(prompt.contains("E1"))
        XCTAssertTrue(prompt.contains("contradiction"))
        XCTAssertTrue(prompt.contains("wrong timing"))
        XCTAssertTrue(prompt.contains("same challenge again"))
    }
}
