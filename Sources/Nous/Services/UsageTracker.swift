import Foundation
import Observation

struct UsageEstimate {
    let inputTokens: Int
    let outputTokens: Int
    let estimatedCost: Double
    let provider: String
}

@Observable
final class UsageTracker {

    var sessionCost: Double = 0
    var totalInputTokens: Int = 0
    var totalOutputTokens: Int = 0
    private(set) var history: [UsageEstimate] = []

    // Pricing per 1M tokens (input/output) — as of 2026-04
    private static let pricing: [String: (input: Double, output: Double)] = [
        "gemini-2.5-flash": (0.15, 0.60),
        "claude-sonnet-4-6": (3.00, 15.00),
        "gpt-4o": (2.50, 10.00),
        "local": (0, 0)
    ]

    func record(provider: String, model: String, inputTokens: Int, outputTokens: Int) {
        let rates = Self.pricing[model] ?? Self.pricing[provider] ?? (0, 0)
        let cost = (Double(inputTokens) * rates.input + Double(outputTokens) * rates.output) / 1_000_000
        let estimate = UsageEstimate(
            inputTokens: inputTokens, outputTokens: outputTokens,
            estimatedCost: cost, provider: provider
        )
        history.append(estimate)
        totalInputTokens += inputTokens
        totalOutputTokens += outputTokens
        sessionCost += cost
    }

    func reset() {
        sessionCost = 0
        totalInputTokens = 0
        totalOutputTokens = 0
        history = []
    }

    var formattedCost: String {
        if sessionCost < 0.01 { return "<$0.01" }
        return String(format: "$%.2f", sessionCost)
    }
}
