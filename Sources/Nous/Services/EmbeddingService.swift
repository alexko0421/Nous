import Foundation
import Hub
import MLX
import MLXEmbedders
import Observation

@Observable
final class EmbeddingService {
    private var model: EmbeddingModel?
    private var tokenizer: Tokenizer?
    private var pooler: Pooling?
    private(set) var isLoaded = false
    private(set) var isLoading = false
    private(set) var downloadProgress: Double = 0

    static let defaultModelId = "sentence-transformers/all-MiniLM-L6-v2"
    static let embeddingDimension = 384

    func loadModel(id: String = defaultModelId) async throws {
        guard !isLoaded && !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let configuration = ModelConfiguration(id: id)
        let (loadedModel, loadedTokenizer) = try await MLXEmbedders.load(
            hub: HubApi(),
            configuration: configuration
        ) { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.downloadProgress = progress.fractionCompleted
            }
        }
        model = loadedModel
        tokenizer = loadedTokenizer
        pooler = Pooling(strategy: .mean)
        isLoaded = true
    }

    func embed(_ text: String) throws -> [Float] {
        guard let model, let tokenizer, let pooler else {
            throw EmbeddingError.modelNotLoaded
        }
        let tokens = tokenizer.encode(text: text)
        // Model expects shape [batch, sequence] — wrap in a batch of 1
        let inputIds = MLXArray(tokens).reshaped([1, tokens.count])
        let output = model(inputIds)
        let pooled = pooler(output)
        // pooled shape is [1, dim] — squeeze to [dim]
        let squeezed = pooled.squeezed(axis: 0)
        eval(squeezed)
        return squeezed.asArray(Float.self)
    }
}

enum EmbeddingError: Error, LocalizedError {
    case modelNotLoaded
    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: return "Embedding model not loaded. Call loadModel() first."
        }
    }
}
