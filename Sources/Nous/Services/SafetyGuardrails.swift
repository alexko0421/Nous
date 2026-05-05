import Foundation

enum SafetyGuardrails {
    private static let highRiskPhrases = [
        "kill myself",
        "end my life",
        "suicide",
        "suicidal",
        "self harm",
        "hurt myself",
        "overdose",
        "want to die",
        "don't want to live",
        "being abused",
        "domestic violence",
        "sexual assault",
        "自殺",
        "自杀",
        "想死",
        "我想死",
        "我想自殺",
        "我想自杀",
        "唔想活",
        "不想活",
        "輕生",
        "轻生",
        "傷害自己",
        "伤害自己",
        "自殘",
        "自残",
        "割腕",
        "我要死",
        "想殺咗自己",
        "想杀了自己",
        "被家暴",
        "家暴",
        "被性侵",
        "性侵"
    ]

    private static let sensitiveMemoryPhrases = [
        "panic attack",
        "self harm",
        "suicide",
        "suicidal",
        "abuse",
        "assault",
        "trauma",
        "therapy",
        "medication",
        "diagnosis",
        "pregnant",
        "pregnancy",
        "sex",
        "addiction",
        "驚恐發作",
        "惊恐发作",
        "焦慮",
        "焦虑",
        "抑鬱",
        "抑郁",
        "自殘",
        "自残",
        "自殺",
        "自杀",
        "家暴",
        "性侵",
        "創傷",
        "创伤",
        "治療",
        "治疗",
        "藥物",
        "药物",
        "診斷",
        "诊断",
        "懷孕",
        "怀孕",
        "性行為",
        "性行为",
        "成癮",
        "成瘾"
    ]

    private static let hardMemoryOptOutPhrases = [
        "don't remember this",
        "do not remember this",
        "don't store this",
        "do not store this",
        "don't put this in memory",
        "do not put this in memory",
        "don't save this",
        "do not save this",
        "keep this off memory",
        "keep this out of memory",
        "off the record",
        "don't keep this",
        "do not keep this",
        "这件事不要记",
        "這件事不要記",
        "呢件事唔好記",
        "呢件事唔好记",
        "别把这个放进 memory",
        "別把這個放進 memory",
        "别放进 memory",
        "別放進 memory",
        "唔好記住",
        "唔好记住",
        "不要記住",
        "不要记住",
        "唔好儲低",
        "唔好存低",
        "唔好存",
        "不要存",
        "唔好保存",
        "不要保存",
        "唔好記低",
        "唔好记低",
        "不要記低",
        "不要记低",
        "不要記下來",
        "不要记下来",
        "不要放進 memory",
        "不要放进 memory",
        "不要放進memory",
        "不要放进memory",
        "唔好留低",
        "當冇講過",
        "当没说过",
        "唔好記錄",
        "唔好记录",
        "唔好keep"
    ]

    private static let hardMemoryOptOutPatterns = [
        #"do not.{0,40}(remember|store|save|keep).{0,40}(memory|long[- ]?term|durable)"#,
        #"don't.{0,40}(remember|store|save|keep).{0,40}(memory|long[- ]?term|durable)"#,
        #"不要.{0,40}(记住|記住|记低|記低|记下来|記下來|记|記|存|保存|保留).{0,40}(memory|长期记忆|長期記憶|durable)"#,
        #"不要.{0,40}(进入|進入|进|進).{0,40}(memory|长期记忆|長期記憶|durable)"#,
        #"唔好.{0,40}(记住|記住|记低|記低|记|記|存|保存|保留).{0,40}(memory|长期记忆|長期記憶|durable)"#,
        #"唔好.{0,40}(入|进入|進入|进|進).{0,40}(memory|长期记忆|長期記憶|durable)"#
    ]

    private static let consentBoundaryPhrases = [
        "ask before storing",
        "ask first before storing",
        "ask before you store",
        "don't store sensitive",
        "do not store sensitive",
        "don't keep sensitive",
        "do not keep sensitive",
        "問過我先",
        "问过我先",
        "先問再存",
        "先问再存",
        "敏感內容先問",
        "敏感内容先问",
        "敏感嘢先問",
        "敏感嘢要問",
        "唔好存敏感",
        "不要存敏感",
        "唔好記敏感",
        "不要记敏感"
    ]

    static func isHighRiskQuery(_ text: String?) -> Bool {
        containsAnyPhrase(text, phrases: highRiskPhrases)
    }

    static func containsSensitiveMemory(_ text: String?) -> Bool {
        containsAnyPhrase(text, phrases: sensitiveMemoryPhrases)
    }

    static func containsHardMemoryOptOut(_ text: String?) -> Bool {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return false }
        if hardMemoryOptOutPhrases.contains(where: { normalized.contains($0) }) {
            return true
        }
        return hardMemoryOptOutPatterns.contains { regexContains(pattern: $0, in: normalized) }
    }

    static func matchedHardMemoryOptOutPhrases(in text: String?) -> [String] {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return [] }
        var matches = hardMemoryOptOutPhrases.filter { normalized.contains($0) }
        matches.append(contentsOf: hardMemoryOptOutPatterns.compactMap {
            regexFirstMatch(pattern: $0, in: normalized)
        })
        return matches
    }

    static func requiresConsentForSensitiveMemory(boundaryLines: [String]) -> Bool {
        boundaryLines.contains { line in
            let normalized = normalize(line)
            return consentBoundaryPhrases.contains { normalized.contains($0) }
        }
    }

    private static func containsAnyPhrase(_ text: String?, phrases: [String]) -> Bool {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return false }
        return phrases.contains { normalized.contains($0) }
    }

    private static func regexContains(pattern: String, in text: String) -> Bool {
        regexFirstMatch(pattern: pattern, in: text) != nil
    }

    private static func regexFirstMatch(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let matchRange = Range(match.range, in: text)
        else {
            return nil
        }
        return String(text[matchRange])
    }

    private static func normalize(_ text: String?) -> String {
        (text ?? "")
            .lowercased()
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "　", with: " ")
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
