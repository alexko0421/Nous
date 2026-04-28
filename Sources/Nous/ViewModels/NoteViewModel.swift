import Foundation
import Observation

@Observable
final class NoteViewModel {

    // MARK: - State

    var currentNote: NousNode?
    var notes: [NousNode] = []
    var title: String = ""
    var content: String = ""
    var relatedNodes: [SearchResult] = []
    var currentProject: Project?

    // MARK: - Dependencies

    private let nodeStore: NodeStore
    private let vectorStore: VectorStore
    private let embeddingService: EmbeddingService
    private let graphEngine: GraphEngine
    private let relationRefinementQueue: GalaxyRelationRefinementQueue?

    // MARK: - Debounce

    private var embedDebounceTask: Task<Void, Never>?

    // MARK: - Init

    init(
        nodeStore: NodeStore,
        vectorStore: VectorStore,
        embeddingService: EmbeddingService,
        graphEngine: GraphEngine,
        relationRefinementQueue: GalaxyRelationRefinementQueue? = nil
    ) {
        self.nodeStore = nodeStore
        self.vectorStore = vectorStore
        self.embeddingService = embeddingService
        self.graphEngine = graphEngine
        self.relationRefinementQueue = relationRefinementQueue
    }

    // MARK: - Note Management

    func loadNotes() {
        notes = (try? nodeStore.fetchAllNodes())?.filter { $0.type == .note } ?? []
    }

    func createNote(projectId: UUID? = nil) throws {
        let node = NousNode(type: .note, title: "Untitled", projectId: projectId)
        try nodeStore.insertNode(node)
        loadNotes()
        openNote(node)
    }

    func openNote(_ node: NousNode) {
        currentNote = node
        title = node.title
        content = node.content
        if let projectId = node.projectId {
            currentProject = try? nodeStore.fetchProject(id: projectId)
        } else {
            currentProject = nil
        }
        loadRelatedNodes()
    }

    func save() {
        guard var node = currentNote else { return }
        node.title = title
        node.content = content
        node.updatedAt = Date()
        try? nodeStore.updateNode(node)
        currentNote = node
        loadNotes()
        scheduleEmbedding()
    }

    func deleteNote() {
        guard let node = currentNote else { return }
        try? nodeStore.deleteNode(id: node.id)
        currentNote = nil
        title = ""
        content = ""
        relatedNodes = []
        loadNotes()
    }

    func onContentChanged() {
        save()
    }

    // MARK: - Embedding

    private func scheduleEmbedding() {
        embedDebounceTask?.cancel()
        embedDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.embedCurrentNote()
        }
    }

    private func embedCurrentNote() async {
        guard let note = currentNote, embeddingService.isLoaded else { return }
        let text = "\(note.title)\n\(note.content)"
        guard let embedding = try? embeddingService.embed(text) else { return }
        try? vectorStore.storeEmbedding(embedding, for: note.id)
        if var updatedNode = try? nodeStore.fetchNode(id: note.id) {
            updatedNode.embedding = embedding
            try? graphEngine.regenerateEdges(for: updatedNode)
            relationRefinementQueue?.enqueue(nodeId: note.id)
            let refreshedNode = updatedNode
            await MainActor.run {
                self.currentNote = refreshedNode
                self.loadRelatedNodes()
            }
        }
    }

    private func loadRelatedNodes() {
        guard let note = currentNote, let embedding = note.embedding else {
            relatedNodes = []
            return
        }
        relatedNodes = (try? vectorStore.search(query: embedding, topK: 5, excludeIds: [note.id])) ?? []
    }
}
