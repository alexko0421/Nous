import Foundation
import Hub
import MLX
import MLXEmbedders
import Observation
import Tokenizers

@Observable
final class EmbeddingService {
    private var model: EmbeddingModel?
    private var tokenizer: Tokenizer?
    private var pooler: Pooling?
    private(set) var isLoaded = false
    private(set) var isLoading = false
    private(set) var downloadProgress: Double = 0

    static let defaultModelId = "intfloat/multilingual-e5-small"
    static let embeddingDimension = 384
    static let currentSignature: String =
        "multilingual-e5-small-384-mean-norm-passage-prefix"

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
        // E5 models expect a "passage: " or "query: " prefix. We use "passage: "
        // for both atoms and queries — atom recall is essentially passage-vs-passage
        // similarity, and consistent prefixing is what the signature records.
        let prefixed = "passage: " + text
        let tokens = tokenizer.encode(text: prefixed)
        // Model expects shape [batch, sequence] — wrap in a batch of 1
        let inputIds = MLXArray(tokens).reshaped([1, tokens.count])
        let output = model(inputIds, positionIds: nil, tokenTypeIds: nil, attentionMask: nil)
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
