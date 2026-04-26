import Foundation

enum JudgeError: Error, Equatable {
    case timeout
    case apiError
    case badJSON
    case emptyOutput
}

protocol Judging {
    func judge(
        userMessage: String,
        citablePool: [CitableEntry],
        previousMode: ChatMode?,
        provider: LLMProvider,
        feedbackLoop: JudgeFeedbackLoop?
    ) async throws -> JudgeVerdict
}

extension ProvocationJudge: Judging {}

final class ProvocationJudge {
    private let llmService: any LLMService
    private let timeout: TimeInterval

    init(llmService: any LLMService, timeout: TimeInterval = 1.5) {
        self.llmService = llmService
        self.timeout = timeout
    }

    func judge(
        userMessage: String,
        citablePool: [CitableEntry],
        previousMode: ChatMode?,
        provider: LLMProvider,
        feedbackLoop: JudgeFeedbackLoop?
    ) async throws -> JudgeVerdict {
        let systemPrompt = Self.buildPrompt(
            pool: citablePool,
            previousMode: previousMode,
            feedbackLoop: feedbackLoop
        )
        let llmMessages = [LLMMessage(role: "user", content: userMessage)]

        let rawOutput: String
        do {
            rawOutput = try await withTimeout(seconds: timeout) {
                try await self.collect(try await self.llmService.generate(messages: llmMessages, system: systemPrompt))
            }
        } catch is TimeoutError {
            throw JudgeError.timeout
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw JudgeError.apiError
        }

        let trimmed = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw JudgeError.emptyOutput }

        let jsonString = Self.extractJSONObject(from: trimmed) ?? trimmed
        guard let data = jsonString.data(using: .utf8) else { throw JudgeError.badJSON }
        do {
            return try JSONDecoder().decode(JudgeVerdict.self, from: data)
        } catch {
            throw JudgeError.badJSON
        }
    }

    // MARK: Prompt

    static func buildPrompt(
        pool: [CitableEntry],
        previousMode: ChatMode?,
        feedbackLoop: JudgeFeedbackLoop?
    ) -> String {
        let poolText: String
        if pool.isEmpty {
            poolText = "(empty — no citable entries this turn)"
        } else {
            poolText = pool.enumerated().map { idx, e in
                let annotation = e.promptAnnotation.map { "[\($0)] " } ?? ""
                let kind = e.kind.map { " kind=\($0.rawValue)" } ?? ""
                return "[\(idx + 1)] \(annotation)id=\(e.id) scope=\(e.scope.rawValue)\(kind)\n\(e.text)"
            }.joined(separator: "\n---\n")
        }

        let feedbackText: String = {
            guard let feedbackLoop, !feedbackLoop.isEmpty else {
                return "No explicit recent thumbs feedback."
            }

            var lines: [String] = []

            if !feedbackLoop.entrySuppressions.isEmpty {
                lines.append("recently_downvoted_entry_ids:")
                for suppression in feedbackLoop.entrySuppressions {
                    let reasons = suppression.reasonHints.isEmpty
                        ? "none recorded"
                        : suppression.reasonHints.joined(separator: ", ")
                    lines.append("- \(suppression.entryId) | penalty=\(String(format: "%.2f", suppression.penalty)) | complaints=\(reasons)")
                }
            }

            if !feedbackLoop.kindAdjustments.isEmpty {
                lines.append("tighten_these_provocation_kinds:")
                for adjustment in feedbackLoop.kindAdjustments {
                    let reasons = adjustment.reasonHints.isEmpty
                        ? "none recorded"
                        : adjustment.reasonHints.joined(separator: ", ")
                    lines.append("- \(adjustment.kind.rawValue) | penalty=\(String(format: "%.2f", adjustment.penalty)) | complaints=\(reasons)")
                }
            }

            if !feedbackLoop.globalReasonHints.isEmpty {
                lines.append("global_complaints: \(feedbackLoop.globalReasonHints.joined(separator: ", "))")
            }

            if !feedbackLoop.noteHints.isEmpty {
                lines.append("recent_note_hints:")
                for note in feedbackLoop.noteHints {
                    lines.append("- \(note)")
                }
            }

            return lines.joined(separator: "\n")
        }()

        return """
        You are a silent judge deciding (a) whether Nous should interject during its next reply, and (b) what framing mode the next reply should use.
        Do NOT address the user. Your entire output is one JSON object exactly matching the schema below — nothing before or after.

        SCHEMA
        {
          "tension_exists": true | false,
          "user_state": "deciding" | "exploring" | "venting",
          "monitor_summary": {
            "state": "<one short clause about confidence, clarity, momentum, or receptivity>",
            "confidence_evidence_gap": "none" | "high-conviction-thin-grounding" | "low-confidence-strong-evidence",
            "positive_event_share": true | false
          },
          "should_provoke": true | false,
          "entry_id": "<id from citable entries>" | null,
          "reason": "<short natural-language reason>",
          "inferred_mode": "companion" | "strategist"
        }

        MODE INFERENCE
        Pick inferred_mode based on the user's register in the message below:
        - companion: casual, emotional, reflective, open-ended, asking for warmth or reassurance.
        - strategist: analytical, decomposing a problem, asking for structure, planning, tradeoff weighing.
        Prefer CONTINUITY with the previous turn — only switch if the user's register clearly shifted (e.g. casual-emotional → structured-analytical, or vice versa). Small drift within one register is NOT a switch.

        RULES (must hold in your output)
        - should_provoke = true must be entailed by monitor_summary + CITABLE ENTRIES. If the monitoring read does not support intervention (e.g., monitor_summary state suggests opening / muddled / receptive but should_provoke ignores that), set should_provoke = false. Confidence ≠ accuracy: high conviction is not by itself a reason to defer; thin grounding is not by itself a reason to provoke.
        - monitor_summary.positive_event_share = true (Alex shared a positive event / 报喜) means do not interrupt the savoring window. should_provoke = false unless contradiction is exceptionally clear and important. Risk-check / contradiction can wait for the next conversational opening.
        - should_provoke = true REQUIRES: tension_exists = true, user_state != "venting", and entry_id is a real id from CITABLE ENTRIES below.
        - user_state = "venting" FORCES should_provoke = false regardless of any tension. Venting is not a moment to challenge.
        - entry_id MUST be copied verbatim from the `id=` field of one CITABLE ENTRY. Do not invent.
        - Entries tagged `[contradiction-candidate]` are retrieval hints only. They often mark earlier decisions, boundaries, or constraints that may be in tension with the user's current message, but they are not proof by themselves.
        - Entries tagged `[weekly-reflection]` (scope=self_reflection) are patterns Nous inferred from the user's conversations last week. They describe conversational behavior in our chats, NOT whole-person traits. Treat them as background context. You MAY anchor a provocation on a weekly-reflection entry ONLY when the user's current message is in clear tension with that conversational pattern (e.g., previously grounded decisions in environment-first, now asking purely tactical questions with no context). Soft tension with a reflection → should_provoke = false.
        - inferred_mode-dependent threshold (apply to YOUR OWN inferred_mode choice):
          * strategist → if tension_exists is true AND user_state ∈ {deciding, exploring}, set should_provoke = true. Soft tensions count.
          * companion  → only set should_provoke = true when the tension is strong AND clearly relevant to a decision the user is making. Soft tensions → false.
        - Recent thumbs feedback is behavior tuning from the same user. Treat it as a real preference signal.
        - If an entry id appears in RECENT USER FEEDBACK as downvoted, do NOT reuse that same entry unless the evidence is clearly stronger now. Borderline reuse => should_provoke = false.
        - If a provocation kind appears with a penalty, raise the bar for that kind. Borderline cases should flip to should_provoke = false.
        - Apply complaint hints:
          * wrong memory  → only provoke if the cited memory directly fits the current message.
          * wrong timing  → if the user is still opening up or timing is uncertain, prefer should_provoke = false.
          * too forceful  → avoid sharp challenge; require unusually clear tension.
          * too repetitive → avoid repeating the same challenge pattern again.
          * not useful    → if the intervention adds little leverage, prefer should_provoke = false.
        - Recent note hints are literal complaints. Respect their direction, but never quote them back to the user.

        PREVIOUS TURN MODE
        \(previousMode?.rawValue ?? "none (first turn)")

        RECENT USER FEEDBACK
        \(feedbackText)

        CITABLE ENTRIES
        \(poolText)

        USER MESSAGE (next after this system block)
        """
    }

    // MARK: Output helpers

    private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> String {
        var acc = ""
        for try await chunk in stream { acc += chunk }
        return acc
    }

    /// Pulls the first top-level `{...}` block out of free-form model output.
    /// Tolerates leading prose or stray backticks from models that don't perfectly follow
    /// "output JSON only" instructions.
    /// String-aware: correctly handles escaped quotes and literal `}` inside strings.
    static func extractJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var idx = start
        while idx < text.endIndex {
            let ch = text[idx]

            if escaped {
                escaped = false
            } else if ch == "\\" && inString {
                escaped = true
            } else if ch == "\"" {
                inString.toggle()
            } else if !inString {
                if ch == "{" { depth += 1 }
                if ch == "}" {
                    depth -= 1
                    if depth == 0 { return String(text[start...idx]) }
                }
            }
            idx = text.index(after: idx)
        }
        return nil
    }
}

// MARK: - Timeout helper

private struct TimeoutError: Error {}

private func withTimeout<T>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
