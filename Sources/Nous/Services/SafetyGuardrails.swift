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
        "sexual assault"
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
        "addiction"
    ]

    private static let hardMemoryOptOutPhrases = [
        "don't remember this",
        "do not remember this",
        "don't store this",
        "do not store this",
        "don't save this",
        "do not save this",
        "keep this off memory",
        "off the record",
        "don't keep this",
        "do not keep this"
    ]

    private static let consentBoundaryPhrases = [
        "ask before storing",
        "ask first before storing",
        "ask before you store",
        "don't store sensitive",
        "do not store sensitive",
        "don't keep sensitive",
        "do not keep sensitive"
    ]

    static func isHighRiskQuery(_ text: String?) -> Bool {
        containsAnyPhrase(text, phrases: highRiskPhrases)
    }

    static func containsSensitiveMemory(_ text: String?) -> Bool {
        containsAnyPhrase(text, phrases: sensitiveMemoryPhrases)
    }

    static func containsHardMemoryOptOut(_ text: String?) -> Bool {
        containsAnyPhrase(text, phrases: hardMemoryOptOutPhrases)
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

    private static func normalize(_ text: String?) -> String {
        (text ?? "")
            .lowercased()
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
