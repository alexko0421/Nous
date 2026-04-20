import XCTest
@testable import Nous

final class ProvocationJudgeTests: XCTestCase {

    // MARK: Fake LLM Service

    final class FakeLLMService: LLMService {
        var output: String
        var shouldThrow: Error?
        var delay: TimeInterval = 0
        var receivedSystem: String?
        var receivedUserMessage: String?

        init(output: String) { self.output = output }

        func generate(messages: [LLMMessage], system: String?) async throws -> AsyncThrowingStream<String, Error> {
            receivedSystem = system
            receivedUserMessage = messages.last?.content
            if let err = shouldThrow { throw err }
            let output = self.output
            let delay = self.delay
            return AsyncThrowingStream { cont in
                Task {
                    if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                    cont.yield(output)
                    cont.finish()
                }
            }
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
            provider: .claude
        )

        XCTAssertTrue(verdict.shouldProvoke)
        XCTAssertEqual(verdict.entryId, "E1")
        XCTAssertEqual(verdict.userState, .deciding)
    }

    func testRejectsMalformedJSON() async {
        let fake = FakeLLMService(output: "not json at all")
        let judge = ProvocationJudge(llmService: fake, timeout: 1.0)

        do {
            _ = try await judge.judge(
                userMessage: "hi", citablePool: pool(),
                previousMode: .companion, provider: .claude
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
                previousMode: .companion, provider: .claude
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
                previousMode: .companion, provider: .claude
            )
            XCTFail("Expected timeout throw")
        } catch let error as JudgeError {
            XCTAssertEqual(error, .timeout)
        } catch {
            XCTFail("Expected JudgeError.timeout, got \(error)")
        }
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
            provider: .claude
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
            provider: .claude
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
            provider: .claude
        )

        XCTAssertTrue(verdict.shouldProvoke)
        XCTAssertTrue(verdict.reason.contains("hi"), "reason should contain the escaped quoted 'hi'")
        XCTAssertEqual(verdict.entryId, "E1")
    }
}
