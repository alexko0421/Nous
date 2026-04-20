import Foundation

enum ClarificationCardParser {
    private static let blockPattern = #"<clarify>\s*<question>(.*?)</question>(.*?)</clarify>"#
    private static let optionPattern = #"<option>(.*?)</option>"#
    private static let understandingPhasePattern = #"<phase>\s*understanding\s*</phase>"#

    private static let internalReasoningPatterns: [String] = [
        #"<thinking>[\s\S]*?</thinking>"#,
        #"<phase>\s*\w+\s*</phase>"#,
        #"<thinking>[\s\S]*$"#,
        #"<phase>[^<]*$"#,
    ]

    static func parse(_ text: String) -> ClarificationContent {
        let phaseKept = containsUnderstandingPhaseMarker(in: text)
        let sanitizedText = removingInternalReasoningMarkers(from: text)

        guard
            let blockRegex = try? NSRegularExpression(
                pattern: blockPattern,
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            ),
            let fullRange = nsRange(for: sanitizedText),
            let match = blockRegex.firstMatch(in: sanitizedText, options: [], range: fullRange),
            let matchRange = Range(match.range(at: 0), in: sanitizedText),
            let questionRange = Range(match.range(at: 1), in: sanitizedText),
            let bodyRange = Range(match.range(at: 2), in: sanitizedText)
        else {
            return ClarificationContent(
                displayText: sanitizedText.trimmingCharacters(in: .whitespacesAndNewlines),
                card: nil,
                keepsQuickActionMode: phaseKept
            )
        }

        let question = cleaned(sanitizedText[questionRange])
        let optionsBody = String(sanitizedText[bodyRange])
        let options = extractOptions(from: optionsBody)

        guard !question.isEmpty, (2...4).contains(options.count) else {
            return ClarificationContent(
                displayText: sanitizedText.trimmingCharacters(in: .whitespacesAndNewlines),
                card: nil,
                keepsQuickActionMode: phaseKept
            )
        }

        var displayText = sanitizedText
        displayText.removeSubrange(matchRange)

        return ClarificationContent(
            displayText: displayText.trimmingCharacters(in: .whitespacesAndNewlines),
            card: ClarificationCard(question: question, options: options),
            keepsQuickActionMode: true
        )
    }

    private static func extractOptions(from body: String) -> [String] {
        guard
            let optionRegex = try? NSRegularExpression(
                pattern: optionPattern,
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            ),
            let range = nsRange(for: body)
        else {
            return []
        }

        return optionRegex.matches(in: body, options: [], range: range).compactMap { match in
            guard let optionRange = Range(match.range(at: 1), in: body) else { return nil }
            let option = cleaned(body[optionRange])
            return option.isEmpty ? nil : option
        }
    }

    private static func cleaned<S: StringProtocol>(_ value: S) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func nsRange(for text: String) -> NSRange? {
        NSRange(text.startIndex..<text.endIndex, in: text)
    }

    private static func containsUnderstandingPhaseMarker(in text: String) -> Bool {
        guard
            let regex = try? NSRegularExpression(
                pattern: understandingPhasePattern,
                options: [.caseInsensitive]
            ),
            let range = nsRange(for: text)
        else {
            return false
        }

        return regex.firstMatch(in: text, options: [], range: range) != nil
    }

    private static func removingInternalReasoningMarkers(from text: String) -> String {
        var result = text
        for pattern in internalReasoningPatterns {
            guard
                let regex = try? NSRegularExpression(
                    pattern: pattern,
                    options: [.caseInsensitive, .dotMatchesLineSeparators]
                ),
                let range = nsRange(for: result)
            else {
                continue
            }

            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: ""
            )
        }
        return result
    }
}
