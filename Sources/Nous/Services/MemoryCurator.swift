import Foundation

final class MemoryCurator {
    func assess(
        latestUserText: String?,
        boundaryLines: [String]
    ) -> MemoryCurationAssessment {
        let normalized = Self.normalized(latestUserText)
        if normalized.isEmpty {
            return rejected("empty latest user text", suppressionReason: .unspecified)
        }

        if SafetyGuardrails.containsHardMemoryOptOut(normalized) {
            return rejected("hard opt-out", suppressionReason: .hardOptOut)
        }

        if Self.looksLowSignalChat(normalized) {
            return ephemeral("low-signal chat without new durable memory")
        }

        if Self.looksMemoryStatusProbe(normalized) {
            return ephemeral("memory-status probe without new durable memory")
        }

        if Self.looksLowSignalProbe(normalized) {
            return ephemeral("low-signal probe without new durable memory")
        }

        if Self.looksProbeOnlyQuestion(normalized) {
            return ephemeral("probe-only question without new durable memory")
        }

        if SafetyGuardrails.requiresConsentForSensitiveMemory(boundaryLines: boundaryLines),
           SafetyGuardrails.containsSensitiveMemory(normalized) {
            return consentRequired("sensitive memory needs consent")
        }

        if Self.looksTemporary(normalized), !Self.hasStableHorizon(normalized) {
            return ephemeral("temporary instruction or short-lived errand")
        }

        return stable(
            kind: Self.inferredKind(from: normalized),
            reason: "stable enough for memory refresh"
        )
    }

    private func stable(kind: MemoryKind?, reason: String) -> MemoryCurationAssessment {
        MemoryCurationAssessment(
            role: .memoryCurator,
            lifecycle: .stable,
            kind: kind,
            persistenceDecision: .persist,
            reason: reason
        )
    }

    private func ephemeral(_ reason: String) -> MemoryCurationAssessment {
        MemoryCurationAssessment(
            role: .memoryCurator,
            lifecycle: .ephemeral,
            kind: .temporaryContext,
            persistenceDecision: .suppress(.unspecified),
            reason: reason
        )
    }

    private func rejected(_ reason: String, suppressionReason: MemorySuppressionReason) -> MemoryCurationAssessment {
        MemoryCurationAssessment(
            role: .memoryCurator,
            lifecycle: .rejected,
            kind: nil,
            persistenceDecision: .suppress(suppressionReason),
            reason: reason
        )
    }

    private func consentRequired(_ reason: String) -> MemoryCurationAssessment {
        MemoryCurationAssessment(
            role: .memoryCurator,
            lifecycle: .consentRequired,
            kind: nil,
            persistenceDecision: .suppress(.sensitiveConsentRequired),
            reason: reason
        )
    }

    private static func looksTemporary(_ text: String) -> Bool {
        let phrases = [
            "today",
            "tomorrow",
            "right now",
            "for now",
            "this week",
            "今日",
            "聽日",
            "听日",
            "而家",
            "暂时",
            "暫時"
        ]
        return phrases.contains { text.contains($0) }
    }

    private static func looksLowSignalProbe(_ text: String) -> Bool {
        guard !hasSubstantiveDurableSignal(text) else { return false }
        let phrases = [
            "context unclear",
            "final probe",
            "recall probe",
            "qa probe",
            "memory probe",
            "probe:",
            "测试 probe",
            "測試 probe"
        ]
        if phrases.contains(where: { text.contains($0) }) {
            return true
        }

        let compact = compactSignalText(text)
        let compactPhrases = [
            "contextunclear",
            "finalprobe",
            "recallprobe",
            "qaprobe",
            "memoryprobe",
            "测试probe",
            "測試probe"
        ]
        return compact == "probe" || compactPhrases.contains { compact.contains($0) }
    }

    private static func looksLowSignalChat(_ text: String) -> Bool {
        guard !hasSubstantiveDurableSignal(text) else { return false }
        let compact = compactSignalText(text)
        let lowSignalExact: Set<String> = [
            "hi", "hey", "hello", "yo", "ok", "okay", "okkk",
            "thanks", "thankyou", "thx", "cool", "nice", "sure",
            "yes", "no", "yep", "nope", "gotit", "understood",
            "noted", "done", "makessense", "soundsgood", "good",
            "continue", "continueplease", "继续", "繼續", "继续吧", "繼續吧",
            "继续扫", "繼續掃", "继续扫继续扫", "繼續掃繼續掃"
        ]
        if lowSignalExact.contains(compact) {
            return true
        }

        let lowSignalPhrases = [
            "thank you",
            "got it",
            "makes sense",
            "sounds good",
            "you are right",
            "you're right",
            "keep going",
            "go on",
            "continue review",
            "continue scanning",
            "继续扫",
            "繼續掃",
            "继续找",
            "繼續搵",
            "继续稳",
            "繼續穩",
            "继续检查",
            "繼續檢查",
            "继续 review",
            "繼續 review"
        ]
        return lowSignalPhrases.contains { text.contains($0) }
    }

    private static func looksMemoryStatusProbe(_ text: String) -> Bool {
        let probeLabels = [
            "final probe",
            "recall probe",
            "qa probe",
            "memory probe",
            "probe:",
            "测试 probe",
            "測試 probe"
        ]
        let compact = compactSignalText(text)
        let compactProbeLabels = [
            "finalprobe",
            "recallprobe",
            "qaprobe",
            "memoryprobe",
            "测试probe",
            "測試probe"
        ]
        guard probeLabels.contains(where: { text.contains($0) }) ||
            compact == "probe" ||
            compactProbeLabels.contains(where: { compact.contains($0) }) else {
            return false
        }
        guard !hasSubstantiveDurableSignal(text) else { return false }

        let statusPhrases = [
            "remember",
            "recall",
            "stored",
            "saved",
            "persisted",
            "记住",
            "記住",
            "记得",
            "記得",
            "记低",
            "記低",
            "写入",
            "寫入",
            "存入",
            "保存"
        ]
        return statusPhrases.contains { text.contains($0) }
    }

    private static func looksProbeOnlyQuestion(_ text: String) -> Bool {
        guard isQuestionLike(text) else { return false }

        let probePhrases = [
            "基于你知道",
            "基於你知道",
            "based on what you know",
            "你记得",
            "你記得",
            "do you remember",
            "刚才",
            "剛才",
            "之前",
            "previously",
            "can you recall",
            "你有没有",
            "你有沒有",
            "有没有把",
            "有沒有把",
            "我到底",
            "什么时候我应该",
            "什麼時候我應該",
            "什么时候我應該",
            "你觉得",
            "你覺得",
            "这两个想法",
            "這兩個想法",
            "这个 project",
            "這個 project",
            "这个项目",
            "這個項目",
            "我现在需要你",
            "我現在需要你",
            "你应该用什么语气",
            "你應該用什麼語氣",
            "should nous",
            "should memory",
            "should we remember",
            "should we save",
            "should i remember",
            "should i save",
            "should you remember",
            "should you save",
            "should this be remembered",
            "should this be saved",
            "do we save",
            "do i save",
            "do you need to remember",
            "what should nous",
            "what should memory",
            "what should branch",
            "nous 应该",
            "nous 應該",
            "memory 应该",
            "memory 應該",
            "应该记",
            "應該記",
            "应不应该记",
            "應不應該記",
            "應唔應該記",
            "该不该记",
            "該不該記",
            "应该保存",
            "應該保存",
            "如果我之前"
        ]
        return probePhrases.contains { text.contains($0) }
    }

    private static func hasSubstantiveDurableSignal(_ text: String) -> Bool {
        let memoryMarkers = [
            "remember that",
            "记住",
            "記住",
            "记低",
            "記低"
        ]
        if memoryMarkers.contains(where: { marker in
            guard let range = text.range(of: marker, options: [.caseInsensitive, .diacriticInsensitive]) else {
                return false
            }
            return hasSubstantiveMemoryFragment(String(text[range.upperBound...]))
        }) {
            return true
        }

        let questionLike = isQuestionLike(text)
        let horizonPhrases = [
            "from now on",
            "going forward",
            "以后",
            "以後",
            "long term",
            "长期",
            "長期"
        ]
        if !questionLike, horizonPhrases.contains(where: { text.contains($0) }) {
            return true
        }

        guard !questionLike else { return false }

        let declarativePhrases = [
            "i prefer",
            "my preference is",
            "i decided",
            "we decided",
            "decision:",
            "decision：",
            "决定:",
            "决定：",
            "決定:",
            "決定：",
            "我偏好",
            "我決定",
            "我决定"
        ]
        let correctionMarkers = [
            "correction:",
            "correction：",
            "修正:",
            "修正：",
            "更正:",
            "更正："
        ]
        return declarativePhrases.contains { text.contains($0) } ||
            correctionMarkers.contains { text.contains($0) }
    }

    private static func hasSubstantiveMemoryFragment(_ raw: String) -> Bool {
        let fragment = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`“”‘’「」『』（）()[]{}，,。.!！?？；;：:"))
        let compact = compactSignalText(fragment)
        guard compact.count >= 8 else { return false }
        let statusOnly = [
            "了吗",
            "了嗎",
            "咗咩",
            "未",
            "what",
            "anything",
            "this",
            "that",
            "it"
        ]
        return !statusOnly.contains(compact)
    }

    private static func isQuestionLike(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.contains("?") ||
            lower.contains("？") ||
            lower.hasSuffix("吗") ||
            lower.hasSuffix("嗎") ||
            lower.hasSuffix("咩") ||
            lower.hasSuffix("么") ||
            lower.hasSuffix("未") {
            return true
        }

        let questionPrefixes = [
            "should ",
            "do you ",
            "can you ",
            "could you ",
            "would you ",
            "what ",
            "when ",
            "why ",
            "how ",
            "where ",
            "is ",
            "are ",
            "am i "
        ]
        if questionPrefixes.contains(where: { lower.hasPrefix($0) }) {
            return true
        }

        let questionPhrases = [
            " should you ",
            " should we ",
            " should i ",
            " should this ",
            "是不是",
            "是否",
            "有没有",
            "有沒有",
            "应不应该",
            "應不應該",
            "應唔應該",
            "该不该",
            "該不該",
            "可不可以",
            "可唔可以",
            "能不能",
            "能唔能",
            "要不要",
            "要唔要",
            "你觉得",
            "你覺得"
        ]
        return questionPhrases.contains { lower.contains($0) }
    }

    private static func hasStableHorizon(_ text: String) -> Bool {
        let phrases = [
            "from now on",
            "going forward",
            "long term",
            "以后",
            "以後",
            "长期",
            "長期"
        ]
        return phrases.contains { text.contains($0) }
    }

    private static func inferredKind(from text: String) -> MemoryKind? {
        if text.contains("prefer") ||
            text.contains("preference") ||
            text.contains("鍾意") ||
            text.contains("钟意") {
            return .preference
        }

        if text.contains("don't") ||
            text.contains("do not") ||
            text.contains("唔好") ||
            text.contains("不要") {
            return .boundary
        }

        if text.contains("decided") ||
            text.contains("decision") ||
            text.contains("决定") ||
            text.contains("決定") {
            return .decision
        }

        return nil
    }

    private static func normalized(_ text: String?) -> String {
        (text ?? "")
            .lowercased()
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func compactSignalText(_ text: String) -> String {
        text.lowercased().unicodeScalars
            .filter { scalar in
                !CharacterSet.whitespacesAndNewlines.contains(scalar) &&
                !CharacterSet.punctuationCharacters.contains(scalar) &&
                !CharacterSet.symbols.contains(scalar)
            }
            .map(String.init)
            .joined()
    }
}
