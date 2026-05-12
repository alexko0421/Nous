import Foundation

actor SourceLearningMemoryScheduler {
    private let service: SourceLearningMemoryService
    private var conversationTails: [UUID: Task<Void, Never>] = [:]
    private var scheduledTasks: [Task<Void, Never>] = []

    init(service: SourceLearningMemoryService) {
        self.service = service
    }

    func enqueue(_ request: SourceLearningDigestRequest) {
        let previous = conversationTails[request.conversationId]
        let task = Task { [service] in
            if let previous {
                await previous.value
            }
            _ = await service.absorb(request)
        }
        conversationTails[request.conversationId] = task
        scheduledTasks.append(task)
    }

    func waitUntilIdle() async {
        let tasks = scheduledTasks
        scheduledTasks = []
        for task in tasks {
            await task.value
        }
    }
}
