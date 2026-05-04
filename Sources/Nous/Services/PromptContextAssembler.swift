import Foundation

struct MemoryPromptPacket {
    var operatingContext: OperatingContext? = nil
    var globalMemory: String?
    var essentialStory: String?
    var userModel: UserModel?
    var memoryEvidence: [MemoryEvidenceSnippet]
    var projectMemory: String?
    var conversationMemory: String?
    var recentConversations: [(title: String, memory: String)]
    var projectGoal: String?

    var coveredSourceNodeIds: Set<UUID> {
        Set(memoryEvidence.map(\.sourceNodeId))
    }

    var promptMemoryEvidence: [MemoryEvidenceSnippet] {
        let covered = scopedSummaryClaimKeys
        guard !covered.isEmpty else { return memoryEvidence }
        return memoryEvidence.filter { evidence in
            !covered.contains(Self.normalizedClaim(evidence.snippet))
        }
    }

    var promptRecentConversations: [(title: String, memory: String)] {
        let covered = scopedSummaryClaimKeys
        var seen = Set<String>()

        return recentConversations.compactMap { conversation in
            let memory = Self.filteredMemoryText(conversation.memory, excluding: covered)
            let key = Self.normalizedClaim(memory)
            guard !key.isEmpty else { return nil }
            guard seen.insert(key).inserted else { return nil }
            return (conversation.title, memory)
        }
    }

    var promptUserModelBlock: String? {
        promptUserModel?.promptBlock(includeIdentity: globalMemory?.isEmpty ?? true)
    }

    private var promptUserModel: UserModel? {
        guard let userModel else { return nil }
        let model = UserModel(
            identity: userModel.identity,
            goals: filteredUserModelGoals(userModel.goals),
            workStyle: userModel.workStyle,
            memoryBoundary: userModel.memoryBoundary
        )
        return model.isEmpty ? nil : model
    }

    var stableBlocks: [String] {
        var blocks: [String] = []

        if let operatingContextBlock = operatingContext?.promptBlock() {
            blocks.append("---\n\n\(operatingContextBlock)")
        }

        if let globalMemory, !globalMemory.isEmpty {
            blocks.append("---\n\nLONG-TERM MEMORY ABOUT ALEX:\n\(globalMemory)")
        }

        if let essentialStory, !essentialStory.isEmpty {
            blocks.append("---\n\nBROADER SITUATION RIGHT NOW:\n\(essentialStory)")
        }

        if let projectMemory, !projectMemory.isEmpty {
            blocks.append("---\n\nTHIS PROJECT'S CONTEXT:\n\(projectMemory)")
        }

        if let conversationMemory, !conversationMemory.isEmpty {
            blocks.append("---\n\nTHIS CHAT'S THREAD SO FAR:\n\(conversationMemory)")
        }

        let promptEvidence = promptMemoryEvidence
        if !promptEvidence.isEmpty {
            blocks.append("---\n\nSHORT SOURCE EVIDENCE FOR THE ABOVE MEMORY:")
            for evidence in promptEvidence {
                blocks.append("- \(evidence.label) · \"\(evidence.sourceTitle)\": \(evidence.snippet)")
            }
        }

        if let promptBlock = promptUserModelBlock {
            blocks.append("---\n\nDERIVED USER MODEL:\n\(promptBlock)")
        }

        if let projectGoal, !projectGoal.isEmpty {
            blocks.append("---\n\nCURRENT PROJECT GOAL: \(projectGoal)")
        }

        let recents = promptRecentConversations
        if !recents.isEmpty {
            blocks.append("---\n\nRECENT CONVERSATIONS WITH ALEX:")
            for conversation in recents {
                let snippet = String(conversation.memory.prefix(280))
                blocks.append("\"\(conversation.title)\": \(snippet)")
            }
        }

        return blocks
    }

    func filteredCitations(_ citations: [SearchResult]) -> [SearchResult] {
        let covered = coveredSourceNodeIds
        guard !covered.isEmpty else { return citations }
        return citations.filter { !covered.contains($0.node.id) }
    }

    private func filteredUserModelGoals(_ goals: [String]) -> [String] {
        guard let projectGoal, !projectGoal.isEmpty else { return goals }
        let projectGoalKey = Self.normalizedClaim(projectGoal)
        guard !projectGoalKey.isEmpty else { return goals }
        return goals.filter { Self.normalizedClaim($0) != projectGoalKey }
    }

    private var scopedSummaryClaimKeys: Set<String> {
        var keys = Set<String>()
        for text in [globalMemory, essentialStory, projectMemory, conversationMemory, projectGoal] {
            keys.formUnion(Self.normalizedClaimKeys(from: text))
        }
        return keys
    }

    private static func filteredMemoryText(_ text: String, excluding keys: Set<String>) -> String {
        guard !keys.isEmpty else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let lines = text.components(separatedBy: .newlines).filter { line in
            let key = normalizedClaim(line)
            guard !key.isEmpty else { return true }
            return !keys.contains(key)
        }
        return lines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedClaimKeys(from text: String?) -> Set<String> {
        guard let text else { return [] }

        var keys = Set<String>()
        for line in text.components(separatedBy: .newlines) {
            let key = normalizedClaim(line)
            if !key.isEmpty { keys.insert(key) }
        }

        let whole = normalizedClaim(text)
        if !whole.isEmpty { keys.insert(whole) }
        return keys
    }

    private static func normalizedClaim(_ text: String) -> String {
        strippedMemoryLine(text)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func strippedMemoryLine(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        while trimmed.hasPrefix("#") {
            trimmed.removeFirst()
            trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        for marker in ["- ", "* "] {
            if trimmed.hasPrefix(marker) {
                return String(trimmed.dropFirst(marker.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        if let dot = trimmed.firstIndex(of: ".") {
            let prefix = trimmed[..<dot]
            if !prefix.isEmpty && prefix.allSatisfy(\.isNumber) {
                return String(trimmed[trimmed.index(after: dot)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return trimmed
    }
}

struct PromptContextResourceIds: Equatable {
    let memoryEvidenceSourceIds: Set<UUID>
    let citationIds: Set<UUID>
}

enum PromptContextAssembler {
    /// Loads the anchor document -- Nous's immutable core identity and thinking methods.
    /// This is who Nous is. It does not change with context.
    private static let anchor: String = {
        guard let url = Bundle.main.url(forResource: "anchor", withExtension: "md"),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            print("[Nous] WARNING: anchor.md not found in bundle, using fallback")
            return "You are Nous, Alex 最信任嘅朋友。用广东话回应，语气好似同好朋友倾偈咁。Be warm, genuine, and direct."
        }
        print("[Nous] Anchor loaded: \(content.prefix(80))...")
        return content
    }()

    private static let memoryInterpretationPolicy = """
    ---

    MEMORY INTERPRETATION POLICY:
    If you notice a personal pattern, state it as a hypothesis unless Alex clearly confirmed it or it is strongly supported across multiple moments.
    Prefer wording like: "I might be wrong, but...", "One hypothesis is...", "Does this fit, or is something else more true?"
    Do not present diagnoses or identity labels as certainty.
    """

    private static let coreSafetyPolicy = """
    ---

    CORE SAFETY POLICY:
    Do not encourage Alex to become emotionally dependent on Nous.
    Do not present medical, psychological, or legal certainty when the situation is ambiguous.
    Respect memory boundaries: if Alex asks not to store something, or asked for consent before sensitive storage, do not silently turn that into durable memory.
    """

    private static let userAddressPolicy = """
    ---

    USER ADDRESS POLICY:
    Internal memory, source labels, and system context may refer to Alex in third person.
    In visible replies, Alex is the person you are speaking to. Address him as "你" / "you" / "我哋" naturally, matching the language of the conversation.
    Do not write phrases like "Alex 会觉得", "Alex 最多", or "Alex should..." in direct chat unless you are explicitly quoting a source, showing a debug label, or Alex asked for third-person copy.
    Translate internal third-person memory wording into second-person user-facing wording without calling attention to this policy.
    """

    private static let answerClosurePolicy = """
    ---

    ANSWER CLOSURE POLICY:
    When you give Alex an insight, recommendation, tradeoff, or judgment, end with one usable rule, one judgment test, or one next action.

    A question is not the default closing move. If a missing detail would materially change the judgment, first deliver the best current judgment, then ask at most one focused question.

    Do not force a checklist onto pure emotional support, style demonstrations, or open reflection. In those cases, keep the ending human and grounded, but still avoid mechanical interview-style follow-up questions.
    """

    private static let stoicGroundingPolicy = """
    ---

    STOIC GROUNDING POLICY:
    Let Stoic thinking quietly shape your judgment, not your surface style.
    Help Alex separate what is in his control from what is not.
    Do not spend energy arguing with reality once something has already happened; focus on the next right move.
    When fear, anger, ego, or external pressure is driving the frame, name that plainly and return to facts, choices, and consequences.
    Bias toward steadiness, proportion, self-command, and aligned action.
    Keep this human and grounded. Do not sound like a philosophy book, do not quote Stoics unless Alex asks, and do not turn real emotion into cold detachment.
    """

    private static let realWorldDecisionPolicy = """
    ---

    REAL-WORLD DECISION POLICY:
    Nous does not have live web or shop search unless OpenRouter web search is available in this request, or a tool result, screenshot, or link content is explicitly attached in this turn.
    If OpenRouter web search is available, use it before answering questions that hinge on current prices, stock, availability, product specs, laws, schedules, school rules, visas, news, or deadlines.
    When using web results, cite the source domains or links in the reply. If the search does not verify the needed fact, say what could not be verified.
    When advice depends on current facts — prices, stock, availability, product specs, laws, schedules, school rules, visas, or deadlines — separate known facts from assumptions.
    Do not infer that something is unavailable just because Alex said his current item is in another country, city, or home. Ask whether he means buying it now, waiting, or bringing an existing item back.
    For purchase decisions, preserve Alex's exact prices/currencies and ask for the link or screenshot when that fact would change the recommendation.
    """

    private static let summaryOutputPolicy = """
    ---

    SUMMARY OUTPUT POLICY:
    When Alex asks you to summarize the current conversation (keywords and intents include "总结", "summarize", "repo", "做笔记", "summary", "整份笔记", or equivalents), wrap the summary body in <summary>…</summary>. Inside the tag, use four H2 sections in this order, followed by a bullet list:

      1. Problem / what triggered the discussion
      2. Thinking / the path the conversation took, including pivots
      3. Conclusion / consensus or decisions reached
      4. Next steps / short actionable bullets

    CRITICAL — match the conversation language for ALL of: the # title, the ## section headers, and the body prose. Do not translate to another language. Do not default to Mandarin. Use:
      - 广东话 section headers (问题 / 思考 / 结论 / 下一步) when Alex is writing in Cantonese.
      - 普通话 section headers (问题 / 思考 / 结论 / 下一步) when Alex is writing in Mandarin.
      - English section headers (Problem / Thinking / Conclusion / Next steps) when Alex is writing in English.
      - If Alex mixes Cantonese and English, prefer Cantonese headers with English kept verbatim inside the prose.

    Sections 1–3 must be narrative prose paragraphs, not bullet dumps. Section 4 is a short bullet list. The # title must contain no filename-unsafe characters (avoid /\\:*?"<>|) and should also follow the conversation language.

    Text outside the tag is allowed for a brief conversational wrapper in the same language (e.g. Cantonese: "整好了，睇下右边嘅白纸"; English: "Done, check the right panel."). The summary content itself must strictly live inside the tag. Never emit the tag when Alex is not asking for a summary.
    """

    private static let conversationTitleOutputPolicy = """
    ---

    CONVERSATION TITLE POLICY:
    At the very end of every assistant reply, append exactly one hidden line in this format:
    <chat_title>short topic title here</chat_title>

    Rules:
    - This tag is hidden from Alex and is only used to label the chat.
    - Match the conversation language and dialect. Do not translate Cantonese into Mandarin.
    - Make it a concise topic label, not a full sentence, not a quote, and not a question.
    - No markdown, no emoji, no surrounding quotes, and no trailing punctuation.
    - Keep it specific. Good: "AI 时代仲要唔要生细路". Bad: "Actually you think that in the future..."
    - Prefer 2 to 6 words for spaced languages, or a short phrase for Chinese.
    - Put the tag on its own final line after all visible text, summary tags, or clarification blocks.
    """

    private static let highRiskSafetyModeBlock = """
    ---

    HIGH-RISK SAFETY MODE:
    Alex may be describing imminent danger, self-harm, abuse, or another acute safety issue.
    Prioritize immediate safety, grounding, and real-world human support over abstract analysis.
    Be calm, direct, and practical.
    If he may be in immediate danger, encourage contacting local emergency services or a trusted nearby person right now.
    Do not romanticize self-destruction, isolation, or dependency.
    """

    private static let quickModeQualityPolicy = """
    ---

    QUICK MODE QUALITY POLICY:
    A quick mode is only a lens on Nous's normal judgment. It is not a new persona,
    not a workflow bot, and not permission to flatten Alex into a template.

    Preserve the anchor voice first: specific to Alex, direct, warm, and willing to
    name the real tension. Use the mode to choose the shape of help, not to replace
    the conversation.

    Do not interview by default. If Alex has already given enough signal for a useful
    take, answer. Question is not the default CTA in quick mode.
    End with a usable rule, test, or next action. Ask at most one question only after
    delivering the current best guidance, and only when the missing detail would
    change the judgment materially.
    """

    private static let teachingExplanationFidelityPolicy = """
    ---

    TEACHING EXPLANATION FIDELITY CHECK:
    This is quiet guidance for learning, explanation, and simplification turns.
    If Alex asks to learn, distinguish concepts, or says the explanation was too complex,
    simplify without becoming lossy.

    Keep the domain's exact distinction intact. Use exact terms lightly when they prevent
    confusion, then translate them into Alex's language.

    Do not collapse a nuanced concept into a dry equation unless you immediately explain
    what each side means. Acknowledge Alex's simpler framing when it is directionally
    right, then calibrate it instead of over-agreeing.

    Prefer one concrete example tied to Alex's actual context over a generic worksheet
    example. Keep Nous's surface voice human: short, warm, and specific, not a worksheet.

    If the learning request is mixed with shame, fatigue, frustration, or low mood,
    support the feeling before teaching. Keep the explanation shorter, and skip the Feynman-style check
    unless Alex explicitly asks for it.

    When helpful, add a light Feynman-style check: invite Alex to explain it back
    in his own words, or ask him to make one tiny example from his real day. This
    is not a mandatory study ritual; skip it when it would feel forced or slow down
    a natural conversation.

    Do not expose method names. Let the behavior feel natural; avoid saying
    "Feynman method", "learning technique", "check", or "exercise" unless Alex
    names the method first.
    """

    private static let softHardCalibrationPolicy = """
    ---

    SOFT-HARD CALIBRATION CHECK:
    Alex may be pushing back on tone, harshness, defensiveness, or over-agreement.
    Do not swing from sycophancy into stubbornness.

    First repair tone before defending the point.
    Do not use "my original point still stands" as a shortcut.
    Name exactly which part of Alex's pushback is right.

    Keep only evidence-backed tension: preserve a judgment only when the current
    turn, memory, or clear reasoning supports it.
    If the original claim was weak, soften or retract it.

    Prefer wording like: "You are right that my wording was too hard. The narrower
    point I still trust is..."
    Avoid sounding like you need to win the exchange.
    """

    private static let directJudgmentContractPolicy = """
    ---

    DIRECT JUDGMENT CONTRACT:
    Alex is asking for a call, tradeoff, choice, or decision rather than an interview.

    Give the provisional judgment first. Do not lead with a clarification question.
    If details are missing, make the smallest honest assumption.
    State the assumption you are using, then give the call.
    After the call, name the flip condition instead of ending with a question if it truly matters.

    Ask a clarification question first only when answering would be unsafe, legally/visa/medical/financial high-stakes, require current facts you do not have, or the missing detail would completely invert the answer.
    A question is not the default CTA.
    Do not use "need more context" as a default escape hatch.
    """

    private static let realityConstraintProbeContractPolicy = """
    ---

    REALITY CONSTRAINT PROBE CONTRACT:
    Alex is asking what his known real-world constraints imply, not asking for
    current legal or school-rule advice.

    Use the available memory and answer from the known constraint first.
    Do not lead by asking which decision. If the exact decision is missing,
    name the strongest relevant constraint anyway, then say what detail could
    change the advice.

    If the constraint involves visa, school, immigration, money, deadlines, or
    current rules, Do not turn this into a legal conclusion. Say it is a
    must-not-ignore reality constraint and that current rules should be verified
    outside Nous before acting.
    """

    private static let supportBoundaryProbeContractPolicy = """
    ---

    SUPPORT BOUNDARY PROBE CONTRACT:
    Alex is asking whether he needs comfort or correction. Choose the stance instead of asking Alex to choose.

    Default shape: one steadying line that lowers the emotional temperature,
    then name the likely thinking error, missing fact, or distorted frame if
    the evidence supports one. If there is not enough evidence to identify an
    error, say that and give the next grounded move.

    Use relevant memory about Alex's support preference naturally. Do not
    diagnose, dramatize, or over-soften. Warmth first; honesty immediately after.
    """

    private static let styleDemonstrationContractPolicy = """
    ---

    STYLE DEMONSTRATION CONTRACT:
    Alex is asking for the voice itself. Do not explain the style principles.
    Do not list rules, criteria, or a meta description.

    Answer as a sample message in the voice Nous should use with Alex. Match Alex's mixed Cantonese / Mandarin / English surface when he writes that way:
    Cantonese warmth, Mandarin clarity when natural, technical terms in English.
    Keep it direct, warm, and concrete.
    """

    private static let memoryBoundaryAnswerContractPolicy = """
    ---

    MEMORY BOUNDARY ANSWER CONTRACT:
    Alex is asking whether something he marked "do not remember" was stored as durable / long-term memory.

    Answer the storage question directly first. Do not answer with a generic claim that Nous has long-term memory.
    Separate three things clearly:
    - current chat transcript / visible context
    - durable memory or fact memory that may be reused later
    - the boundary itself, which may be remembered without retaining the protected detail

    If the protected detail is not present in durable memory context, say you do not see evidence that it entered durable memory. Do not ask Alex to repeat the protected detail.
    If there is uncertainty, say what can be checked in the Memory UI and suggest forgetting/rejecting the durable item if it appears.
    Never repeat or reconstruct the do-not-remember detail in the reply.
    """

    private static let memorySynthesisJudgmentContractPolicy = """
    ---

    MEMORY SYNTHESIS JUDGMENT CONTRACT:
    Alex is asking Nous to reconcile tension across remembered context, identify the current meaning, or judge whether two remembered things share a real pattern.

    Use the relevant memory first, but do not overclaim. Do not flatten the answer into "both are valid" unless that is the actual judgment.

    For contradictions or corrections: the latest explicit correction wins. Treat the older statement as historical context, not the current truth.
    For tensions: name the distinction that makes the tension intelligible, then say which behavior should change in practice.
    For project continuity: state the current real goal first, then name directions that have drifted.
    For Galaxy-style connection probes: decide whether the shared mechanism is real or only surface similarity, and cite evidence from both sides if available.
    For UI / taste probes: translate remembered taste into concrete product direction, not generic AI-app principles.
    """

    private static func activeChatModeBlock(_ chatMode: ChatMode) -> String {
        "---\n\nACTIVE CHAT MODE: \(chatMode.label)\n\(chatMode.contextBlock)"
    }

    private static func needsDirectJudgmentGuard(_ input: String?) -> Bool {
        guard let input = input?.lowercased(),
              !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        let explicitDirectCues = [
            "直接判断", "直接判斷", "直接俾判断", "直接俾判斷",
            "直接给判断", "直接給判斷", "你直接判断", "你直接判斷",
            "你直接帮我判断", "你直接幫我判斷", "俾个判断", "俾個判斷",
            "给个判断", "給個判斷", "帮我判断", "幫我判斷",
            "帮我决定", "幫我決定", "帮我做决定", "幫我做決定",
            "direct judgment", "give me your call", "make the call",
            "tell me whether", "decide for me"
        ]
        if explicitDirectCues.contains(where: { input.contains($0) }) {
            return true
        }

        let decisionCues = [
            "应唔应该", "應唔應該", "该不该", "該不該",
            "应该唔应该", "應該唔應該", "should i", "which should",
            "do i", "should we", "which one should"
        ]
        let cjkChoiceCues = ["定系", "还是", "還是", "先"]
        let hasEnglishChoiceCue = input.range(
            of: #"\b(or|vs|versus)\b"#,
            options: .regularExpression
        ) != nil
        let hasChoiceCue = cjkChoiceCues.contains(where: { input.contains($0) }) || hasEnglishChoiceCue

        return decisionCues.contains(where: { input.contains($0) })
            && hasChoiceCue
    }

    private static func needsTeachingExplanationGuard(_ input: String?) -> Bool {
        guard let input = input?.lowercased(),
              !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        let explanationCues = [
            "解释", "解釋", "讲清楚", "講清楚", "点分", "點分", "区别", "區別",
            "差别", "差別", "搞乱", "搞亂", "唔明", "不明白", "太复杂", "太複雜",
            "简单方法", "簡單方法", "简单啲", "簡單啲", "例子",
            "explain", "difference", "distinguish", "what does",
            "define", "too complex", "simpler", "confusing", "confused"
        ]

        return explanationCues.contains { input.contains($0) }
    }

    private static func needsSoftHardCalibrationGuard(_ input: String?) -> Bool {
        guard let input = input?.lowercased(),
              !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        let calibrationCues = [
            "太 harsh", "太硬", "太重", "语气", "語氣", "讲法", "講法",
            "为咗反对而反对", "為咗反對而反對", "反对而反对", "反對而反對",
            "唔好咁硬", "不要这么硬", "不要這麼硬", "爹味",
            "太顺我", "太順我", "太软", "太軟", "顺住我", "順住我",
            "讨好", "討好", "太迎合",
            "too harsh", "harsh", "too hard", "defensive", "pushback",
            "over-agree", "over agree", "too agreeable", "too soft"
        ]

        return calibrationCues.contains { input.contains($0) }
    }

    private static func needsRealityConstraintProbeGuard(_ input: String?) -> Bool {
        guard let input = input?.lowercased(),
              !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        let constraintCues = [
            "现实约束", "現實約束", "真实约束", "真實約束",
            "现实限制", "現實限制", "real constraint", "real-world constraint",
            "constraints you know", "based on what you know"
        ]
        let ignoreCues = [
            "最不能忽略", "最唔可以忽略", "不能忽略什么", "不能忽略什麼",
            "唔可以忽略咩", "不可以忽略", "不要忽略",
            "must not ignore", "can't ignore", "cannot ignore"
        ]

        return constraintCues.contains { input.contains($0) }
            && ignoreCues.contains { input.contains($0) }
    }

    private static func needsSupportBoundaryProbeGuard(_ input: String?) -> Bool {
        guard let input = input?.lowercased(),
              !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        let comfortCues = ["安慰", "陪伴", "哄我", "comfort", "reassure", "support me"]
        let correctionCues = [
            "指出", "想错", "想錯", "哪里错", "邊度错", "邊度錯",
            "哪里想错", "哪裡想錯", "point out", "where i'm wrong",
            "what i'm missing", "call me out"
        ]

        return comfortCues.contains { input.contains($0) }
            && correctionCues.contains { input.contains($0) }
    }

    private static func needsStyleDemonstrationGuard(_ input: String?) -> Bool {
        guard let input = input?.lowercased(),
              !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        let styleCues = ["语气", "語氣", "口吻", "tone", "voice", "style"]
        let demoCues = [
            "示范", "示範", "示例", "直接讲", "直接講", "直接说", "直接說",
            "不要讲原则", "不要講原則", "唔好讲原则", "唔好講原則",
            "demo", "example", "sample", "don't explain", "not principles"
        ]

        return styleCues.contains { input.contains($0) }
            && demoCues.contains { input.contains($0) }
    }

    private static func needsMemoryBoundaryAnswerGuard(_ input: String?) -> Bool {
        guard let input = input?.lowercased(),
              !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        let storageCues = [
            "记忆", "記憶", "长期记忆", "長期記憶", "长期", "長期",
            "long-term memory", "durable memory", "fact memory",
            "memory", "remember", "store", "stored"
        ]
        let optOutCues = [
            "不要记", "不要記", "唔好记", "唔好記", "别记", "別記",
            "不要记住", "不要記住", "不要记低", "不要記低",
            "do not remember", "don't remember", "dont remember",
            "do not store", "don't store", "dont store",
            "not remember", "not store"
        ]
        let auditCues = [
            "有没有", "有冇", "有沒有", "是不是", "系咪", "是否",
            "把", "当成", "當成", "进入", "進入", "存",
            "did you", "have you", "whether", "if"
        ]

        return storageCues.contains { input.contains($0) }
            && optOutCues.contains { input.contains($0) }
            && auditCues.contains { input.contains($0) }
    }

    private static func needsMemorySynthesisJudgmentGuard(_ input: String?) -> Bool {
        guard let input = input?.lowercased(),
              !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        let hasEnglishOrChoiceCue = input.range(
            of: #"\bor\b"#,
            options: .regularExpression
        ) != nil
        let tensionQuestion =
            (input.contains("到底") || input.contains("actually") || input.contains("really"))
            && (input.contains("还是") || input.contains("還是") || input.contains("定系") || hasEnglishOrChoiceCue)

        let fastSlowQuestion =
            (input.contains("什么时候") || input.contains("幾時") || input.contains("when"))
            && (input.contains("快") || input.contains("fast"))
            && (input.contains("慢") || input.contains("slow"))

        let supersessionQuestion =
            (input.contains("之前说过") || input.contains("之前講過") || input.contains("previously said") || input.contains("before"))
            && (input.contains("后来") || input.contains("後來") || input.contains("改成") || input.contains("changed to") || input.contains("now"))

        let galaxyPatternQuestion =
            (input.contains("共同模式") || input.contains("common pattern") || input.contains("共同 pattern"))
            || ((input.contains("表面相似") || input.contains("surface similarity") || input.contains("surface similar"))
                && (input.contains("两个") || input.contains("兩個") || input.contains("two")))

        let projectContinuityQuestion =
            (input.contains("真正目标") || input.contains("真正目標") || input.contains("real goal") || input.contains("actual goal"))
            && (input.contains("偏") || input.contains("drift") || input.contains("off-track") || input.contains("off track"))

        let tasteDirectionQuestion =
            (input.contains("像 nous") || input.contains("feel like nous") || input.contains("普通 ai app"))
            && (input.contains("ui") || input.contains("界面") || input.contains("方向") || input.contains("direction"))

        return tensionQuestion
            || fastSlowQuestion
            || supersessionQuestion
            || galaxyPatternQuestion
            || projectContinuityQuestion
            || tasteDirectionQuestion
    }

    static func assembleContext(
        chatMode: ChatMode = .companion,
        currentUserInput: String? = nil,
        operatingContext: OperatingContext? = nil,
        globalMemory: String?,
        essentialStory: String? = nil,
        userModel: UserModel? = nil,
        memoryEvidence: [MemoryEvidenceSnippet] = [],
        memoryGraphRecall: [String] = [],
        projectMemory: String?,
        conversationMemory: String?,
        recentConversations: [(title: String, memory: String)],
        citations: [SearchResult],
        projectGoal: String?,
        attachments: [AttachedFileContext] = [],
        activeQuickActionMode: QuickActionMode? = nil,
        loadedSkills: [LoadedSkill] = [],
        matchedSkills: [Skill] = [],
        quickActionAddendum: String? = nil,
        allowSkillIndex: Bool = true,
        allowInteractiveClarification: Bool = false,
        shadowLearningHints: [String] = [],
        slowCognitionArtifacts: [CognitionArtifact] = [],
        now: Date = Date()
    ) -> TurnSystemSlice {
        var anchorAndPolicies: [String] = []
        var slowMemory: [String] = []
        var volatilePieces: [String] = []

        // Stable prefix: identity + policies + slow-changing memory layers. This is what
        // gets frozen into cachedContents.systemInstruction; any per-turn additions here
        // would invalidate the cache hash every request and defeat the whole point.
        #if DEBUG
        if !DebugAblation.skipAnchor {
            anchorAndPolicies.append(anchor)
        } else {
            print("[DebugAblation] anchor SKIPPED")
        }
        #else
        anchorAndPolicies.append(anchor)
        #endif
        anchorAndPolicies.append(memoryInterpretationPolicy)
        anchorAndPolicies.append(coreSafetyPolicy)
        anchorAndPolicies.append(userAddressPolicy)
        anchorAndPolicies.append(answerClosurePolicy)
        anchorAndPolicies.append(stoicGroundingPolicy)
        anchorAndPolicies.append(realWorldDecisionPolicy)
        anchorAndPolicies.append(summaryOutputPolicy)
        anchorAndPolicies.append(conversationTitleOutputPolicy)

        let memoryPacket = MemoryPromptPacket(
            operatingContext: operatingContext,
            globalMemory: globalMemory,
            essentialStory: essentialStory,
            userModel: userModel,
            memoryEvidence: memoryEvidence,
            projectMemory: projectMemory,
            conversationMemory: conversationMemory,
            recentConversations: recentConversations,
            projectGoal: projectGoal
        )
        let promptCitations = memoryPacket.filteredCitations(citations)
        slowMemory.append(contentsOf: memoryPacket.stableBlocks)

        if !memoryGraphRecall.isEmpty, activeQuickActionMode != nil {
            volatilePieces.append("---\n\nGRAPH MEMORY RECALL:")
            for recall in memoryGraphRecall {
                volatilePieces.append(recall)
            }
            volatilePieces.append("Use this as scoped graph recall: atoms are claims, chains are decision paths, and source_quote is evidence. Do not claim more certainty than the graph provides.")
        }

        // Volatile: per-turn signals. The judge re-infers chat mode each turn, citations
        // come from fresh RAG, attachments are turn-specific, etc. Keeping these out of
        // the cache costs ~300 tokens/turn in re-send but keeps hit rate near 100%.

        // CHAT FORMAT POLICY: format permission for quick-action modes only
        // (Plan needs table rendering, Direction/Brainstorm benefit from structure).
        // Normal chat reverts to anchor-driven prose -- granting markdown structure
        // here pulled Sonnet toward consultant register and away from the anchor's
        // push-back / first-principles reflexes.
        if activeQuickActionMode != nil {
            volatilePieces.append("""
---

CHAT FORMAT POLICY:
当内容有 distinct items / 周期 schedule / 数据对比，可以用 markdown 结构（`# 标题`、
`- bullet`、`| table |`）呈现。Emphasis 仍然用「」，唔好用 `**bold**` / `*italic*` / 倒勾。
""")
        }

        volatilePieces.append(activeChatModeBlock(chatMode))

        if SafetyGuardrails.isHighRiskQuery(currentUserInput) {
            volatilePieces.append(highRiskSafetyModeBlock)
        }

        if needsDirectJudgmentGuard(currentUserInput) {
            volatilePieces.append(directJudgmentContractPolicy)
        }

        if needsTeachingExplanationGuard(currentUserInput) {
            volatilePieces.append(teachingExplanationFidelityPolicy)
        }

        if needsSoftHardCalibrationGuard(currentUserInput) {
            volatilePieces.append(softHardCalibrationPolicy)
        }

        if needsRealityConstraintProbeGuard(currentUserInput) {
            volatilePieces.append(realityConstraintProbeContractPolicy)
        }

        if needsSupportBoundaryProbeGuard(currentUserInput) {
            volatilePieces.append(supportBoundaryProbeContractPolicy)
        }

        if needsStyleDemonstrationGuard(currentUserInput) {
            volatilePieces.append(styleDemonstrationContractPolicy)
        }

        if needsMemoryBoundaryAnswerGuard(currentUserInput) {
            volatilePieces.append(memoryBoundaryAnswerContractPolicy)
        }

        if needsMemorySynthesisJudgmentGuard(currentUserInput) {
            volatilePieces.append(memorySynthesisJudgmentContractPolicy)
        }

        if !attachments.isEmpty {
            volatilePieces.append("---\n\nATTACHED FILES:")
            for attachment in attachments {
                if let extractedText = attachment.extractedText, !extractedText.isEmpty {
                    volatilePieces.append("FILE: \(attachment.name)\n\(extractedText)")
                } else {
                    volatilePieces.append("FILE: \(attachment.name)\nContent preview unavailable. Ask Alex for the relevant excerpt if more detail is needed.")
                }
            }
        }

        if !promptCitations.isEmpty {
            volatilePieces.append("---\n\nRELEVANT KNOWLEDGE FROM ALEX'S NOTES AND CONVERSATIONS:")
            for (index, result) in promptCitations.enumerated() {
                let percent = Int(result.similarity * 100)
                let snippet = result.surfacedSnippet
                let laneNote = result.lane == .longGap ? ", older cross-time connection" : ""
                volatilePieces.append("[\(index + 1)] \"\(result.node.title)\" (\(percent)% relevance\(laneNote)): \(snippet)")
            }
            volatilePieces.append("Reference the above when relevant. Cite by title. If knowledge contradicts something Alex said before, surface the tension.")
        }

        if let longGapGuidance = longGapConnectionGuidance(
            chatMode: chatMode,
            currentUserInput: currentUserInput,
            citations: promptCitations,
            now: now
        ) {
            volatilePieces.append(longGapGuidance)
        }

        if let slowCognitionArtifact = CognitionArtifactSelector.selectForChat(
            currentInput: currentUserInput,
            artifacts: slowCognitionArtifacts
        ) {
            volatilePieces.append(CognitionPromptFormatter.volatileBlock(for: slowCognitionArtifact))
        }

        if !shadowLearningHints.isEmpty {
            volatilePieces.append("---\n\nSHADOW THINKING HINTS:")
            for hint in shadowLearningHints.prefix(3) {
                volatilePieces.append("- \(hint)")
            }
            volatilePieces.append("Use these as quiet thinking guidance for this turn. Do not mention the shadow profile, learning system, or that these hints were injected.")
        }

        if let activeQuickActionMode {
            volatilePieces.append("ACTIVE QUICK MODE: \(activeQuickActionMode.label)")
            volatilePieces.append(quickModeQualityPolicy)
        }

        if let quickActionAddendum, !quickActionAddendum.isEmpty {
            volatilePieces.append(quickActionAddendum)
        }

        if allowInteractiveClarification {
            volatilePieces.append(
                """
                ---

                INTERACTIVE CLARIFICATION UI:
                You are in the understanding phase of a quick mode.
                While you are still understanding and have not started giving real guidance yet, include this exact hidden marker anywhere in your response:
                <phase>understanding</phase>
                This marker will not be shown to Alex.
                If one missing detail blocks a useful answer, you may ask a short clarification question using this exact format:
                <clarify>
                <question>One short question here</question>
                <option>First option</option>
                <option>Second option</option>
                <option>Third option</option>
                <option>Fourth option</option>
                </clarify>

                Rules:
                - Use this only while you are still understanding Alex's situation in the active quick mode.
                - Keep using the hidden understanding marker while you are still gathering context, even if you ask a normal text question instead of a card.
                - You may ask at most one clarification follow-up after Alex's first reply in the quick mode.
                - If you already asked one follow-up in this quick mode, stop clarifying and give the best real guidance you can with the available context.
                - Ask for one missing distinction at a time.
                - Use 2 to 4 options only.
                - Keep each option short, concrete, and directly clickable.
                - Put any normal explanation outside the clarify block.
                - If discrete options would be misleading, ask a normal question instead.
                - The moment you have enough context to give real guidance, stop using the hidden marker, stop using the clarify block, and answer normally.
                - Do not drag out clarification if you can already give a useful response.
                """
            )
        }

        let loadedSkillIDs = Set(loadedSkills.map(\.skillID))
        let activeSkills = renderActiveSkills(loadedSkills)
        let skillIndex = allowSkillIndex
            ? renderSkillIndex(
                matched: matchedSkills,
                loadedIDs: loadedSkillIDs,
                activeMode: activeQuickActionMode
            )
            : ""

        var blocks: [SystemPromptBlock] = [
            SystemPromptBlock(
                id: .anchorAndPolicies,
                content: anchorAndPolicies.joined(separator: "\n\n"),
                cacheControl: .ephemeral
            )
        ]

        let slowMemoryContent = slowMemory.joined(separator: "\n\n")
        if !slowMemoryContent.isEmpty {
            blocks.append(
                SystemPromptBlock(
                    id: .slowMemory,
                    content: slowMemoryContent,
                    cacheControl: .ephemeral
                )
            )
        }

        if !activeSkills.isEmpty {
            blocks.append(
                SystemPromptBlock(
                    id: .activeSkills,
                    content: activeSkills,
                    cacheControl: .ephemeral
                )
            )
        }

        if !skillIndex.isEmpty {
            blocks.append(
                SystemPromptBlock(
                    id: .skillIndex,
                    content: skillIndex,
                    cacheControl: .ephemeral
                )
            )
        }

        blocks.append(
            SystemPromptBlock(
                id: .volatile,
                content: volatilePieces.joined(separator: "\n\n"),
                cacheControl: nil
            )
        )

        return TurnSystemSlice(blocks: blocks)
    }

    static func promptResourceIds(
        operatingContext: OperatingContext? = nil,
        globalMemory: String?,
        essentialStory: String? = nil,
        userModel: UserModel? = nil,
        memoryEvidence: [MemoryEvidenceSnippet] = [],
        projectMemory: String?,
        conversationMemory: String?,
        recentConversations: [(title: String, memory: String)],
        citations: [SearchResult],
        projectGoal: String?
    ) -> PromptContextResourceIds {
        let memoryPacket = MemoryPromptPacket(
            operatingContext: operatingContext,
            globalMemory: globalMemory,
            essentialStory: essentialStory,
            userModel: userModel,
            memoryEvidence: memoryEvidence,
            projectMemory: projectMemory,
            conversationMemory: conversationMemory,
            recentConversations: recentConversations,
            projectGoal: projectGoal
        )

        return PromptContextResourceIds(
            memoryEvidenceSourceIds: Set(memoryPacket.promptMemoryEvidence.map(\.sourceNodeId)),
            citationIds: Set(memoryPacket.filteredCitations(citations).map(\.node.id))
        )
    }

    static func indexedSkillIds(
        matchedSkills: [Skill],
        loadedSkills: [LoadedSkill],
        activeQuickActionMode: QuickActionMode?,
        allowSkillIndex: Bool = true
    ) -> Set<UUID> {
        guard allowSkillIndex, activeQuickActionMode != nil else { return [] }
        let loadedIDs = Set(loadedSkills.map(\.skillID))
        return Set(
            matchedSkills
                .filter { $0.payload.payloadVersion >= 2 }
                .filter { !loadedIDs.contains($0.id) }
                .map(\.id)
        )
    }

    private static func renderActiveSkills(_ loadedSkills: [LoadedSkill]) -> String {
        guard !loadedSkills.isEmpty else { return "" }

        var pieces = [
            "---",
            "",
            "ACTIVE SKILLS:",
            "The following skill prompt fragments are already loaded for this conversation. Apply them when relevant."
        ]

        for skill in loadedSkills {
            pieces.append("<<skill source=user id=\(skill.skillID.uuidString) name=\(skill.nameSnapshot)>>")
            pieces.append(skill.contentSnapshot)
            pieces.append("<</skill>>")
        }

        return pieces.joined(separator: "\n")
    }

    private static func renderSkillIndex(
        matched skills: [Skill],
        loadedIDs: Set<UUID>,
        activeMode: QuickActionMode?
    ) -> String {
        guard activeMode != nil else { return "" }

        let candidates = skills
            .filter { $0.payload.payloadVersion >= 2 }
            .filter { !loadedIDs.contains($0.id) }
        guard !candidates.isEmpty else { return "" }

        var pieces = [
            "---",
            "",
            "SKILL INDEX:",
            "These skills matched the current turn but their full content is not loaded yet.",
            "If one is needed for a better answer, call loadSkill with its id before relying on it."
        ]

        for skill in candidates {
            let cue = skill.payload.useWhen ?? skill.payload.description ?? "Use when this skill is relevant."
            pieces.append("- id=\(skill.id.uuidString) name=\(skill.payload.name) priority=\(skill.payload.trigger.priority): \(cue)")
        }

        return pieces.joined(separator: "\n")
    }

    static func governanceTrace(
        chatMode: ChatMode = .companion,
        currentUserInput: String? = nil,
        operatingContext: OperatingContext? = nil,
        globalMemory: String?,
        essentialStory: String? = nil,
        userModel: UserModel? = nil,
        memoryEvidence: [MemoryEvidenceSnippet] = [],
        memoryGraphRecall: [String] = [],
        projectMemory: String?,
        conversationMemory: String?,
        recentConversations: [(title: String, memory: String)],
        citations: [SearchResult],
        projectGoal: String?,
        attachments: [AttachedFileContext] = [],
        activeQuickActionMode: QuickActionMode? = nil,
        quickActionAddendum: String? = nil,
        allowInteractiveClarification: Bool = false,
        turnSteward: TurnStewardTrace? = nil,
        agentCoordination: AgentCoordinationTrace? = nil,
        shadowLearningHints: [String] = [],
        slowCognitionArtifacts: [CognitionArtifact] = [],
        now: Date = Date()
    ) -> PromptGovernanceTrace {
        var layers = ["anchor", "memory_interpretation_policy", "core_safety_policy", "user_address_policy", "answer_closure_policy", "stoic_grounding_policy", "real_world_decision_policy", "summary_output_policy", "conversation_title_output_policy", "chat_mode"]
        let highRiskQueryDetected = SafetyGuardrails.isHighRiskQuery(currentUserInput)
        let memoryPacket = MemoryPromptPacket(
            operatingContext: operatingContext,
            globalMemory: globalMemory,
            essentialStory: essentialStory,
            userModel: userModel,
            memoryEvidence: memoryEvidence,
            projectMemory: projectMemory,
            conversationMemory: conversationMemory,
            recentConversations: recentConversations,
            projectGoal: projectGoal
        )
        let promptCitations = memoryPacket.filteredCitations(citations)
        let promptMemoryEvidence = memoryPacket.promptMemoryEvidence
        let promptRecentConversations = memoryPacket.promptRecentConversations

        if operatingContext?.promptBlock() != nil { layers.append("operating_context") }
        if let globalMemory, !globalMemory.isEmpty { layers.append("global_memory") }
        if let essentialStory, !essentialStory.isEmpty { layers.append("essential_story") }
        if let projectMemory, !projectMemory.isEmpty { layers.append("project_memory") }
        if let conversationMemory, !conversationMemory.isEmpty { layers.append("conversation_memory") }
        if !promptMemoryEvidence.isEmpty { layers.append("memory_evidence") }
        if !memoryGraphRecall.isEmpty, activeQuickActionMode != nil { layers.append("memory_graph_recall") }
        if memoryPacket.promptUserModelBlock != nil { layers.append("user_model") }
        if let projectGoal, !projectGoal.isEmpty { layers.append("project_goal") }
        if !promptRecentConversations.isEmpty { layers.append("recent_conversations") }
        if !attachments.isEmpty { layers.append("attachments") }
        if !promptCitations.isEmpty { layers.append("citations") }
        if longGapConnectionGuidance(
            chatMode: chatMode,
            currentUserInput: currentUserInput,
            citations: promptCitations,
            now: now
        ) != nil {
            layers.append("long_gap_bridge_guidance")
        }
        if activeQuickActionMode != nil { layers.append("quick_action_mode") }
        if let quickActionAddendum, !quickActionAddendum.isEmpty { layers.append("quick_action_addendum") }
        if allowInteractiveClarification { layers.append("interactive_clarification") }
        if turnSteward != nil { layers.append("turn_steward") }
        if agentCoordination != nil { layers.append("agent_coordination") }
        if needsDirectJudgmentGuard(currentUserInput) { layers.append("direct_judgment_guard") }
        if needsTeachingExplanationGuard(currentUserInput) { layers.append("teaching_explanation_guard") }
        if needsSoftHardCalibrationGuard(currentUserInput) { layers.append("soft_hard_calibration_guard") }
        if needsRealityConstraintProbeGuard(currentUserInput) { layers.append("reality_constraint_probe_guard") }
        if needsSupportBoundaryProbeGuard(currentUserInput) { layers.append("support_boundary_probe_guard") }
        if needsStyleDemonstrationGuard(currentUserInput) { layers.append("style_demonstration_guard") }
        if needsMemoryBoundaryAnswerGuard(currentUserInput) { layers.append("memory_boundary_answer_guard") }
        if needsMemorySynthesisJudgmentGuard(currentUserInput) { layers.append("memory_synthesis_judgment_guard") }
        let selectedSlowCognitionArtifact = CognitionArtifactSelector.selectForChat(
            currentInput: currentUserInput,
            artifacts: slowCognitionArtifacts
        )
        if selectedSlowCognitionArtifact != nil {
            layers.append("slow_cognition")
        }
        if !shadowLearningHints.isEmpty { layers.append("shadow_learning") }
        if chatMode == .strategist { layers.append("strategist_mode") }
        if highRiskQueryDetected { layers.append("high_risk_safety_mode") }

        return PromptGovernanceTrace(
            promptLayers: layers,
            evidenceAttached: !promptMemoryEvidence.isEmpty,
            safetyPolicyInvoked: highRiskQueryDetected,
            highRiskQueryDetected: highRiskQueryDetected,
            turnSteward: turnSteward,
            agentCoordination: agentCoordination,
            citationTrace: citationTrace(for: promptCitations),
            slowCognitionTrace: selectedSlowCognitionArtifact.map(SlowCognitionPromptTrace.init)
        )
    }

    private static func citationTrace(for citations: [SearchResult]) -> CitationTrace? {
        guard !citations.isEmpty else { return nil }

        let similarities = citations.map { roundedSimilarity($0.similarity) }
        return CitationTrace(
            citationCount: citations.count,
            longGapCount: citations.filter { $0.lane == .longGap }.count,
            minSimilarity: similarities.min() ?? 0,
            maxSimilarity: similarities.max() ?? 0
        )
    }

    private static func roundedSimilarity(_ similarity: Float) -> Double {
        (Double(similarity) * 10_000).rounded() / 10_000
    }

    private static func longGapConnectionGuidance(
        chatMode: ChatMode,
        currentUserInput: String?,
        citations: [SearchResult],
        now: Date
    ) -> String? {
        guard !SafetyGuardrails.isHighRiskQuery(currentUserInput) else { return nil }
        guard let candidate = preferredLongGapBridgeCitation(citations: citations, now: now) else { return nil }

        let snippet = String(candidate.surfacedSnippet.prefix(220))
        let modeSpecificRule: String

        switch chatMode {
        case .companion:
            modeSpecificRule = "- Keep it gentle and hypothesis-led. Use language like \"might\", \"seems\", or \"could be\"."
        case .strategist:
            modeSpecificRule = "- Name the line directly and clearly. Prioritize precision over cushioning, but do not sound prosecutorial or therapeutic."
        }

        return """
        ---

        LONG-GAP CONNECTION CUE:
        Temporal memory trigger, not emotional calibration:
        One retrieved source may matter here as an older cross-time connection:
        "\(candidate.node.title)": \(snippet)

        Use this when the old memory can explain the current tension, repetition, drift, decision, or pattern.
        If you use it:
        - Add at most one short bridge sentence.
        - Explain why that earlier moment matters now.
        - Focus on movement, tension, or progression across time, not on catching Alex being inconsistent.
        - Treat the connection as a hypothesis unless the evidence is explicit.
        - Do not use old memory as pressure, proof of identity, or a way to make Alex agree.
        - Do not mention retrieval, citations, similarity scores, dates, percentages, or the phrase "long-gap".
        - Do not stack multiple older threads in one reply.
        - End with one usable rule, judgment test, or next action if you rely on this older memory.
        \(modeSpecificRule)
        """
    }

    private static func preferredLongGapBridgeCitation(
        citations: [SearchResult],
        now: Date
    ) -> SearchResult? {
        citations.first {
            $0.lane == .longGap &&
            $0.similarity >= 0.62 &&
            ageDays(since: $0.node.createdAt, now: now) >= 45
        }
    }

    private static func ageDays(since createdAt: Date, now: Date) -> Int {
        let elapsed = max(0, now.timeIntervalSince(createdAt))
        return Int(elapsed / 86_400)
    }
}
