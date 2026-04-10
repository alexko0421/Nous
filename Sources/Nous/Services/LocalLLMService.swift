import Foundation
import Hub
import MLXLLM
import MLXLMCommon
import Observation

@Observable
final class LocalLLMService: LLMService {
    private(set) var isLoaded = false
    private(set) var isLoading = false
    private(set) var downloadProgress: Double = 0

    private var modelContainer: ModelContainer?
    var contextWindowTokens: Int { 8_192 }

    static let defaultModelId = "mlx-community/Llama-3.2-3B-Instruct-4bit"

    func loadModel(id: String = defaultModelId) async throws {
        guard !isLoaded && !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let configuration = ModelConfiguration(id: id)
        let container = try await LLMModelFactory.shared.loadContainer(
            hub: HubApi(),
            configuration: configuration
        ) { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.downloadProgress = progress.fractionCompleted
            }
        }

        modelContainer = container
        isLoaded = true
    }

    func generate(messages: [LLMMessage], system: String?) async throws -> AsyncThrowingStream<String, Error> {
        guard let container = modelContainer else {
            throw LLMError.modelNotLoaded
        }

        // Build Chat.Message array
        var chatMessages: [Chat.Message] = []
        if let system {
            chatMessages.append(.system(system))
        }
        for msg in messages {
            switch msg.role {
            case "assistant":
                chatMessages.append(.assistant(msg.content))
            default:
                chatMessages.append(.user(msg.content))
            }
        }

        let userInput = UserInput(chat: chatMessages)
        let parameters = GenerateParameters(temperature: 0.7)

        // Prepare input and get the generate stream inside the actor
        let (input, context): (LMInput, ModelContext) = try await container.perform { ctx in
            let lmInput = try await ctx.processor.prepare(input: userInput)
            return (lmInput, ctx)
        }

        let stream = try MLXLMCommon.generate(input: input, parameters: parameters, context: context)

        return AsyncThrowingStream { continuation in
            Task {
                for await generation in stream {
                    if let chunk = generation.chunk {
                        continuation.yield(chunk)
                    }
                }
                continuation.finish()
            }
        }
    }
}
