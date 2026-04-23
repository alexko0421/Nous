import Foundation

/// Thin seam around the one Gemini call WeeklyReflectionService needs.
/// The concrete `GeminiLLMService.generateStructured` satisfies this via an
/// adapter so tests can inject canned responses without an HTTP round-trip.
protocol StructuredLLMClient {
    func generateStructured(
        messages: [LLMMessage],
        system: String?,
        responseSchema: [String: Any],
        temperature: Double
    ) async throws -> (text: String, usage: GeminiUsageMetadata?)
}

struct GeminiStructuredLLMAdapter: StructuredLLMClient {
    let service: GeminiLLMService

    func generateStructured(
        messages: [LLMMessage],
        system: String?,
        responseSchema: [String: Any],
        temperature: Double
    ) async throws -> (text: String, usage: GeminiUsageMetadata?) {
        try await service.generateStructured(
            messages: messages,
            system: system,
            responseSchema: responseSchema,
            temperature: temperature
        )
    }
}
